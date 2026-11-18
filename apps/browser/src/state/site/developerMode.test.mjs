import assert from "node:assert/strict";
import { test } from "node:test";
import { DEFAULT_SETTINGS, parseSettings } from "../settings/settings.ts";
import { useBrowser } from "../browser/store.ts";
import { isConfigSettingKey } from "../settings/configAllowlist.ts";
import { SYNCED_SETTINGS } from "../sync/settingsAdapter.ts";
import { canChooseDeveloperMode, developerModeHost, developerModeOn, developerModeSitesWith, isLoopbackHost, setDeveloperMode } from "./developerMode.ts";
import { noteDeveloperBarPress, takeDeveloperModeCounts } from "../telemetry/developerModeCounts.ts";

test("local addresses turn Developer Mode on by themselves, and other sites start off", () => {
  for (const url of ["http://localhost:5173/", "http://LOCALHOST:3000/app", "http://127.0.0.1:8080", "http://app.localhost:3000/", "http://my_app.localhost/", "http://[::1]:4000/", "http://0.0.0.0:8000", "https://localhost/"]) {
    assert.equal(developerModeOn({}, url), true, url);
  }
  for (const url of ["https://github.com/", "http://localhost.example.com/", "https://example.com/localhost", "", "about:blank", "file:///tmp/a.html", "ardia://settings", "http://user@github.com/"]) {
    assert.equal(developerModeOn({}, url), false, url);
  }
});

test("a site's choice wins over the default, and is kept per host for every port", () => {
  assert.equal(developerModeOn({ localhost: false }, "http://localhost:5173/"), false);
  assert.equal(developerModeOn({ localhost: false }, "http://localhost:3000/"), false);
  assert.equal(developerModeOn({ localhost: false }, "http://127.0.0.1:3000/"), true);
  assert.equal(developerModeOn({ "staging.example.com": true }, "https://staging.example.com/x"), true);
  assert.equal(developerModeHost("http://user:pw@Example.COM:81/a"), "example.com");
  assert.equal(developerModeHost("http://[::1]:3000/"), "[::1]");
  assert.equal(isLoopbackHost("127.1.2.3"), true);
  assert.equal(canChooseDeveloperMode("chrome://newtab"), false);
  assert.equal(developerModeOn({}, "http://constructor/"), false);
});

test("only choices that differ from the default are saved", () => {
  assert.deepEqual(developerModeSitesWith({}, "localhost", false), { localhost: false });
  assert.deepEqual(developerModeSitesWith({ localhost: false }, "localhost", true), {});
  assert.deepEqual(developerModeSitesWith({}, "example.com", true), { "example.com": true });
  assert.deepEqual(developerModeSitesWith({ "example.com": true }, "example.com", false), {});
  assert.equal(developerModeOn(developerModeSitesWith({}, "__proto__", true), "http://__proto__/"), true);
});

test("the setting syncs, can be set from a config file, and drops malformed values", () => {
  assert.deepEqual(DEFAULT_SETTINGS.developerModeSites, {});
  assert.ok(SYNCED_SETTINGS.includes("developerModeSites"));
  assert.ok(isConfigSettingKey("developerModeSites"));
  for (const value of [null, "localhost", ["localhost"], { localhost: "yes" }]) assert.deepEqual(parseSettings({ developerModeSites: value }).developerModeSites, {});
  assert.deepEqual(parseSettings({ developerModeSites: { "example.com": true } }).developerModeSites, { "example.com": true });
});

test("turning it off and on from Site Controls updates the setting and counts the toggles", () => {
  takeDeveloperModeCounts();
  useBrowser.getState().hydrate({ settings: { developerModeSites: {} } });
  setDeveloperMode("http://localhost:5173/", false);
  assert.deepEqual(useBrowser.getState().settings.developerModeSites, { localhost: false });
  setDeveloperMode("http://localhost:5173/", false);
  setDeveloperMode("http://localhost:3000/", true);
  assert.deepEqual(useBrowser.getState().settings.developerModeSites, {});
  setDeveloperMode("https://example.com/", true);
  noteDeveloperBarPress("console");
  noteDeveloperBarPress("console");
  const counts = takeDeveloperModeCounts();
  assert.equal(counts.developer_mode_turned_on, 2);
  assert.equal(counts.developer_mode_turned_off, 1);
  assert.equal(counts.developer_mode_turned_off_on_local_sites, 1);
  assert.equal(counts.developer_bar_console_opens, 2);
  assert.equal(counts.developer_bar_inspects, 0);
  assert.equal(takeDeveloperModeCounts().developer_bar_console_opens, 0);
});

test("Split View Options adds a pane on the side picked, and is disabled once the split is full", async () => {
  const { shellNativeModules } = await import("../../test-native/shell.ts");
  const { showSplitSidesMenu } = await import("./developerMode.ts");
  const { splitOf, splitTabIds, MAX_SPLIT_PANES } = await import("../splits/splits.ts");
  const { activeTabId } = await import("../browser/model.ts");
  const S = () => useBrowser.getState();
  S().hydrate({});
  const windowId = S().createWindow({ url: "http://localhost:3000/" });
  const tabId = activeTabId(S(), windowId);
  const menus = shellNativeModules.ArdiaMenus;
  const real = menus.showMenu;
  const shown = [];
  menus.showMenu = (items) => {
    shown.push(items);
    return Promise.resolve("left");
  };
  try {
    while (splitTabIds(splitOf(S(), tabId) ?? { slots: [] }).length < MAX_SPLIT_PANES) await showSplitSidesMenu(tabId);
    await showSplitSidesMenu(tabId);
  } finally {
    menus.showMenu = real;
  }
  const actions = (items) => items.filter((it) => it.id).map((it) => [it.id, it.enabled]);
  assert.deepEqual(actions(shown[0]), [["right", true], ["left", true], ["top", true], ["bottom", true]]);
  assert.deepEqual(actions(shown.at(-1)), [["right", false], ["left", false], ["top", false], ["bottom", false]]);
  assert.equal(splitTabIds(splitOf(S(), tabId)).length, MAX_SPLIT_PANES);
  assert.equal(splitTabIds(splitOf(S(), tabId))[0] === tabId, false, "the first pane went to the left");
});
