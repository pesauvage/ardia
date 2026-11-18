import assert from "node:assert/strict";
import { test } from "node:test";
const stub = await import("../../test-native/index.ts");
const { useBrowser } = await import("../browser/store.ts");
const { startPlugins } = await import("./start.ts");
const { usePlugins, activeManifest } = await import("./store.ts");
const lifecycle = await import("./lifecycle.ts");
const { takePluginCounts } = await import("../telemetry/pluginCounts.ts");
const { consentLines } = await import("./consent.ts");
const { readManifest } = await import("../../lib/pluginManifest.ts");

const S = () => useBrowser.getState();
const P = () => usePlugins.getState();
const host = stub.pluginHost;
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
const settle = async () => {
  for (let i = 0; i < 6; i++) await tick();
};

const AFTER = [["skills", "install", "--auto"], ["skills", "refresh"]];
const CLI = JSON.stringify({
  manifest: 1,
  name: "cli",
  title: "Command Line",
  version: "0.3.0",
  alwaysOn: true,
  permissions: ["control"],
  programs: [{ name: "ardia", path: "bin/ardia", afterUpdate: AFTER }],
});
const OTHER = JSON.stringify({ manifest: 1, name: "other", title: "Other", programs: [{ name: "other-tool", path: "bin/other" }] });
const BUILT_IN = { status: "ok", folderId: "bundled", bundled: true };

function reset() {
  host.links.length = 0;
  host.unlinks.length = 0;
  host.sweeps.length = 0;
  host.removed.length = 0;
  host.linkResult = null;
}

async function scan(folders) {
  host.folders = folders;
  await lifecycle.rescanPlugins();
  await settle();
}

async function turnOn(name) {
  assert.ok(lifecycle.requestPluginConsent(name));
  assert.ok(lifecycle.enablePlugin(name, P().consent.hash));
  await settle();
}

const { setConsentPeriod } = await import("../telemetry/consentPeriod.ts");
setConsentPeriod(true, "test-epoch");
S().hydrate({});
host.linkResult = { ok: true, linked: ["ardia"], refused: {}, binDir: "/home/.local/bin", adopted: true };
host.folders = [{ name: "cli", text: CLI, ...BUILT_IN }, { name: "other", status: "ok", text: OTHER, folderId: "1:2" }];
startPlugins();
await settle();
const launch = { sweeps: host.sweeps.map((s) => [...s]), links: host.links.map((l) => ({ ...l })) };

test("the built-in command line is on from the first scan: linked with no consent, adopting the old home, with its after-update actions", async () => {
  assert.equal(P().consent, null);
  assert.ok(activeManifest(P(), "cli"));
  assert.equal(P().records.cli?.enabled ?? false, false, "always on needs no approval record");
  assert.equal(launch.links.length, 1);
  const [spec] = launch.links;
  assert.deepEqual({ name: spec.name, folderId: spec.folderId, version: spec.version, adopt: spec.adopt }, { name: "cli", folderId: "bundled", version: "0.3.0", adopt: true });
  assert.equal(spec.approved, P().listings.cli.hash);
  assert.deepEqual(spec.programs, [{ name: "ardia", path: "bin/ardia", afterUpdate: AFTER }]);
  assert.deepEqual(P().programs.cli, { state: "linked", hash: spec.approved, linked: ["ardia"], refused: {}, binDir: "/home/.local/bin" });
  assert.deepEqual(launch.sweeps, [["cli"]], "at launch every command of a plugin that isn't on, or isn't there any more, comes off PATH");
  assert.deepEqual(host.unlinks, []);
  host.linkResult = null;
  const counts = takePluginCounts();
  assert.equal(counts.program_links, 1);
  assert.equal(counts.program_adoptions, 1);
});

test("its first link turns control on once, as the first install did, and never again", async () => {
  assert.equal(S().settings.cliControl, true);
  assert.equal(P().records.cli.controlGranted, true);
  S().updateSettings({ cliControl: false });
  reset();
  lifecycle.reconcilePlugins();
  await settle();
  assert.equal(host.links.length, 0, "an unchanged built-in isn't linked again");
  assert.equal(S().settings.cliControl, false, "turning control off sticks");
});

test("nothing turns it off: no consent, no enable, no disable, no remove", async () => {
  reset();
  assert.equal(lifecycle.requestPluginConsent("cli"), false);
  assert.equal(lifecycle.enablePlugin("cli", P().listings.cli.hash), false);
  assert.equal(lifecycle.disablePlugin("cli"), false);
  assert.deepEqual(await lifecycle.removePlugin("cli"), { ok: false, reason: "It's built into Ardia and always on." });
  const { pluginSocketMethod } = await import("./socketMethods.ts");
  assert.deepEqual(pluginSocketMethod("plugins.disable", { name: "cli" }), { error: { code: "refused", message: "cli is built into Ardia and always on." } });
  assert.deepEqual(pluginSocketMethod("plugins.enable", { name: "cli" }), { result: { ok: true } });
  await settle();
  assert.ok(activeManifest(P(), "cli"));
  assert.deepEqual(host.unlinks, []);
  assert.deepEqual(host.removed, []);
});

test("a built-in that asks for control respects a user who turned control off before it first linked", async () => {
  reset();
  S().updateSettings({ cliControl: false });
  const auto = JSON.stringify({ manifest: 1, name: "auto", title: "Auto", alwaysOn: true, permissions: ["control"], programs: [{ name: "auto-tool", path: "bin/auto" }] });
  await scan([{ name: "cli", text: CLI, ...BUILT_IN }, { name: "auto", text: auto, ...BUILT_IN }, { name: "other", status: "ok", text: OTHER, folderId: "1:2" }]);
  assert.equal(P().programs.auto.state, "linked");
  assert.equal(S().settings.cliControl, false);
  assert.equal(P().records.auto.controlGranted, true);
});

test("a plugin you install can't be always on, can't run after-update actions and can't take ardia", async () => {
  const always = JSON.stringify({ manifest: 1, name: "always", title: "Always", alwaysOn: true });
  const after = JSON.stringify({ manifest: 1, name: "after", title: "After", programs: [{ name: "after-tool", path: "bin/a", afterUpdate: [["x"]] }] });
  const impostor = JSON.stringify({ manifest: 1, name: "impostor", title: "Impostor", programs: [{ name: "ardia", path: "bin/ardia" }] });
  await scan([
    { name: "after", status: "ok", text: after, folderId: "5:6" },
    { name: "always", status: "ok", text: always, folderId: "3:4" },
    { name: "cli", text: CLI, ...BUILT_IN },
    { name: "impostor", status: "ok", text: impostor, folderId: "7:8" },
  ]);
  assert.deepEqual(P().listings.always.problems, ["plugin.json: alwaysOn is only for plugins built into Ardia"]);
  assert.deepEqual(P().listings.after.problems, ["plugin.json: programs[0].afterUpdate is only for plugins built into Ardia"]);
  assert.deepEqual(P().listings.impostor.problems, ["plugin.json: programs[0].name: ardia belongs to Ardia's built-in cli plugin"]);
  assert.equal(lifecycle.requestPluginConsent("always"), false);
});

test("a folder you add named cli can't take ardia either, even with no built-in one", async () => {
  await scan([{ name: "cli", status: "ok", text: JSON.stringify({ ...JSON.parse(CLI), alwaysOn: undefined, programs: [{ name: "ardia", path: "bin/ardia" }] }), folderId: "9:9" }]);
  assert.deepEqual(P().listings.cli.problems, ["plugin.json: programs[0].name: ardia belongs to Ardia's built-in cli plugin"]);
  await scan([{ name: "cli", text: CLI, ...BUILT_IN }, { name: "other", status: "ok", text: OTHER, folderId: "1:2" }]);
});

test("a grant that didn't stick (the setting was lost, the user never chose) is applied again; a choice is kept", async () => {
  const { useBrowser: store } = await import("../browser/store.ts");
  assert.equal(P().records.cli.controlGranted, true);
  store.setState((s) => ({ settings: { ...s.settings, cliControl: false }, settingsMeta: { chosen: s.settingsMeta.chosen.filter((k) => k !== "cliControl"), inferred: s.settingsMeta.inferred } }));
  reset();
  host.linkResult = { ok: false, reason: "busy" };
  usePlugins.setState((s) => ({ programs: { ...s.programs, cli: { state: "failed", hash: s.listings.cli.hash, reason: "busy" } } }));
  host.linkResult = null;
  const { relinkPrograms } = await import("./programs.ts");
  relinkPrograms("cli");
  await settle();
  assert.equal(S().settings.cliControl, true);
  S().updateSettings({ cliControl: false });
  usePlugins.setState((s) => ({ programs: { ...s.programs, cli: { state: "failed", hash: s.listings.cli.hash, reason: "busy" } } }));
  relinkPrograms("cli");
  await settle();
  assert.equal(S().settings.cliControl, false, "turning it off yourself sticks");
});

test("a name someone else holds shows with Try Again, and Try Again links it once it's free", async () => {
  reset();
  const { canRelink, relinkPrograms } = await import("./programs.ts");
  usePlugins.setState((s) => ({ programs: { ...s.programs, cli: { state: "linked", hash: s.listings.cli.hash, linked: [], refused: { ardia: "/home/.local/bin/ardia is someone else's; remove it to use this one" }, binDir: "/home/.local/bin" } } }));
  assert.ok(canRelink(P().programs.cli));
  relinkPrograms("cli");
  await settle();
  assert.deepEqual(P().programs.cli.linked, ["ardia"]);
  assert.equal(canRelink(P().programs.cli), false);
});

test("any other plugin's programs still follow consent: on links, off unlinks, and control is granted at Turn On only", async () => {
  await scan([{ name: "cli", text: CLI, ...BUILT_IN }, { name: "other", status: "ok", text: OTHER, folderId: "1:2" }]);
  reset();
  takePluginCounts();
  await turnOn("other");
  assert.equal(host.links.length, 1);
  assert.equal(host.links[0].adopt, false);
  assert.deepEqual(host.links[0].programs, [{ name: "other-tool", path: "bin/other" }], "after-update actions never travel for a plugin you installed");
  assert.equal(P().programs.other.state, "linked");
  assert.ok(lifecycle.disablePlugin("other"));
  await settle();
  assert.deepEqual(host.unlinks, [{ name: "other", programs: ["other-tool"], remove: false }]);
  assert.equal(P().programs.other, undefined);
  assert.equal(takePluginCounts().program_unlinks, 1);
});

test("a stale answer from the native side changes nothing; a refused link is shown with Try Again", async () => {
  reset();
  host.linkResult = { ok: false, stale: true };
  await turnOn("other");
  assert.equal(P().programs.other.state, "linking", "a newer request owns the state");
  lifecycle.disablePlugin("other");
  await settle();
  reset();
  takePluginCounts();
  host.linkResult = { ok: false, reason: "a test instance puts programs on PATH only with ARDIA_INSTANCE cliBinDir set" };
  await turnOn("other");
  assert.deepEqual(P().programs.other, { state: "failed", hash: P().listings.other.hash, reason: host.linkResult.reason });
  assert.equal(takePluginCounts().program_link_failures, 1);
  const { relinkPrograms } = await import("./programs.ts");
  host.linkResult = null;
  relinkPrograms("other");
  await settle();
  assert.equal(P().programs.other.state, "linked");
  lifecycle.disablePlugin("other");
  await settle();
});

test("a link that finishes after the plugin went off doesn't come back", async () => {
  reset();
  let release;
  const gate = new Promise((resolve) => (release = resolve));
  const linkPrograms = stub.shellNativeModules.ArdiaPlugins.linkPrograms;
  stub.shellNativeModules.ArdiaPlugins.linkPrograms = async (spec) => (await gate, linkPrograms(spec));
  try {
    await turnOn("other");
    assert.equal(P().programs.other.state, "linking");
    lifecycle.disablePlugin("other");
    release();
    await settle();
    assert.equal(P().programs.other, undefined);
    assert.deepEqual(host.unlinks, [{ name: "other", programs: ["other-tool"], remove: false }]);
  } finally {
    stub.shellNativeModules.ArdiaPlugins.linkPrograms = linkPrograms;
  }
});

test("a plugin you added has its programs removed with it", async () => {
  reset();
  const removed = await lifecycle.removePlugin("other");
  assert.equal(removed.ok, true);
  assert.deepEqual(host.unlinks.at(-1), { name: "other", programs: ["other-tool"], remove: true });
});

test("what the command line gets, as Settings shows it", () => {
  const texts = consentLines(readManifest(CLI).manifest).map((l) => l.text);
  assert.ok(texts.some((t) => t.startsWith("Puts a command on your PATH: ardia. It runs as you, outside Ardia's sandbox")));
  assert.ok(texts.includes("Adds ~/.local/bin to your PATH in your shell's login file, if it isn't there yet"));
  assert.ok(texts.includes("Runs ardia skills install --auto, then ardia skills refresh, after each update"));
  assert.ok(!texts.some((t) => t.includes("in the background")), "a program-only plugin runs nothing in the background");
});
