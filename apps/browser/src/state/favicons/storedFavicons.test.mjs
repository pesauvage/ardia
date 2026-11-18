import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { test } from "node:test";
import { mount } from "../../test-hooks.mjs";

globalThis.__DEV__ = false;

const native = import.meta.resolve("../../platform/favicons.ts");
const stub = `export * from ${JSON.stringify(native)};
export const faviconsFor = (profile, pages) => globalThis.faviconsForTest(profile, pages);
export const storeFavicon = (...args) => (globalThis.storedFavicons.push(args), Promise.resolve(globalThis.storedFaviconUri(args)));
export const forgetFavicons = (...args) => (globalThis.forgottenFavicons.push(args), Promise.resolve(null));
export const fetchFavicon = (...args) => (globalThis.fetchedFavicons.push(args), Promise.resolve(null));`;
registerHooks({
  resolve(specifier, context, next) {
    if (specifier === "../../platform/favicons" && context.parentURL?.endsWith("/state/favicons/favicons.ts"))
      return { url: `data:text/javascript,${encodeURIComponent(stub)}`, shortCircuit: true };
    return next(specifier, context);
  },
});
const { adoptFavicons, faviconFailed, noteFavicon, pruneEngineFavicons, resolveFavicon, startFavicons, useFavicon, useFavicons } = await import("./favicons.ts");
const { launchFavicons, seedFavicons } = await import("./launchFavicons.ts");
const { useBrowser } = await import("../browser/store.ts");
const { engineProfile } = await import("../browser/model.ts");
const { chromeHistoryEvent } = await import("../../test-native/ardiacore.ts");

const S = () => useBrowser.getState();
const key = () => engineProfile(S(), "default");
const stored = (hash) => `ardia-favicon://icon/${encodeURIComponent(key())}/${hash.padEnd(32, "0")}`;
const cached = (page) => useFavicons.getState().profiles[key()]?.pages[page];
const settle = () => new Promise((resolve) => setTimeout(resolve, 40));
const waitFor = async (check) => {
  for (let i = 0; i < 200 && !check(); i++) await new Promise((resolve) => setTimeout(resolve, 5));
  assert.ok(check(), "reached before the deadline");
};
const answering = (icons) => (profile, pages) => Promise.resolve({ pages: new Map(pages.flatMap((p) => (icons[p] ? [[p, { uri: icons[p], icon: "" }]] : []))), icons: new Map() });

function reset() {
  S().hydrate({});
  useFavicons.setState({ profiles: {}, themes: {} });
  globalThis.storedFavicons = [];
  globalThis.forgottenFavicons = [];
  globalThis.fetchedFavicons = [];
  globalThis.storedFaviconUri = (args) => `data:image/png;base64,${args[3]}`;
  globalThis.faviconsForTest = answering({});
}

function tabOn(page) {
  const windowId = S().createWindow({ url: page });
  const tabId = S().windows[windowId].tabIds[0];
  S().updateTab(tabId, { url: page });
  return tabId;
}

test("an icon the engine already stored for a page with no icon address is shown as it is, with nothing downloaded", async () => {
  reset();
  const page = "https://no-icon-address.test/";
  const tabId = tabOn(page);
  noteFavicon(tabId, stored("a1"));
  await settle();
  assert.equal(resolveFavicon(page, null, "default")?.uri, stored("a1"));
  assert.deepEqual(useFavicons.getState().profiles[key()].srcs, {});
});

test("a stored icon that fails to load is looked up again once, then counts as no icon", async () => {
  reset();
  const page = "https://evicted-from-disk.test/";
  const asked = [];
  globalThis.faviconsForTest = (profile, pages) => (asked.push(...pages), answering({ [page]: stored("b2") })(profile, pages));
  const row = mount(() => useFavicon(page, null, "default"));
  try {
    await waitFor(() => cached(page) === stored("b2"));
    assert.equal(faviconFailed("default", stored("b2")), true);
    await waitFor(() => asked.filter((p) => p === page).length === 2);
    await waitFor(() => cached(page) === stored("b2"));
    assert.equal(faviconFailed("default", stored("b2")), false);
    await settle();
    assert.equal(cached(page), null);
    assert.equal(asked.filter((p) => p === page).length, 2);
  } finally {
    row.unmount();
  }
});

test("icons a saved launch kept inline are swapped for stored ones when the engine has them, and kept when it doesn't", async () => {
  reset();
  const known = "https://seeded-known.test/";
  const unknown = "https://seeded-unknown.test/";
  const src = "https://seeded-known.test/icon.png";
  const asked = [];
  globalThis.faviconsForTest = (profile, pages) => (asked.push(...pages), answering({ [known]: stored("c3") })(profile, pages));
  seedFavicons({ images: ["data:image/png;base64,KNOWN", "data:image/png;base64,UNKNOWN"], profiles: { [key()]: { pages: { [known]: 0, [unknown]: 1 }, srcs: { [src]: 0 } } }, themes: {} });
  assert.equal(cached(known), "data:image/png;base64,KNOWN");
  await waitFor(() => cached(known) === stored("c3"));
  assert.deepEqual(asked.sort(), [known, unknown]);
  assert.equal(cached(unknown), "data:image/png;base64,UNKNOWN");
  assert.equal(useFavicons.getState().profiles[key()].srcs[src], undefined);
  const saved = launchFavicons([{ url: known, favicon: null, profileId: "default" }]);
  assert.deepEqual(saved.images, [stored("c3")]);
});

test("a saved launch that already holds stored icons asks the engine for nothing", async () => {
  reset();
  const page = "https://seeded-stored.test/";
  const asked = [];
  globalThis.faviconsForTest = (profile, pages) => (asked.push(...pages), answering({})(profile, pages));
  seedFavicons({ images: [stored("d4")], profiles: { [key()]: { pages: { [page]: 0 }, srcs: {} } }, themes: {} });
  await settle();
  assert.equal(cached(page), stored("d4"));
  assert.deepEqual(asked, []);
});

test("an imported icon shows at once and is swapped for the stored one when the engine has taken it", async () => {
  reset();
  const page = "https://imported-stored.test/";
  globalThis.storedFaviconUri = () => stored("e5");
  adoptFavicons("default", [{ page, icon: `${page}favicon.png`, png: "AAAA" }]);
  assert.equal(cached(page), "data:image/png;base64,AAAA");
  await waitFor(() => cached(page) === stored("e5"));
  assert.deepEqual(globalThis.storedFavicons[0], [key(), page, `${page}favicon.png`, "AAAA"]);
});

test("deleting history tells the engine to drop every stored icon but the ones still shown, and clearing data drops them all", async () => {
  reset();
  const stop = startFavicons();
  const kept = "https://history-kept.test/";
  const gone = "https://history-gone.test/";
  globalThis.faviconsForTest = answering({ [kept]: stored("f6"), [gone]: stored("a7") });
  const rows = [mount(() => useFavicon(kept, null, "default")), mount(() => useFavicon(gone, null, "default"))];
  try {
    await waitFor(() => cached(kept) === stored("f6") && cached(gone) === stored("a7"));
    useFavicons.setState((f) => ({ ...f, profiles: { ...f.profiles, [key()]: { ...f.profiles[key()], srcs: { "https://history-gone.test/icon.png": stored("a7"), "https://history-kept.test/icon.png": stored("f6") } } } }));
    chromeHistoryEvent({ kind: "deleted", profile: key(), all: false, urls: [gone] });
    await waitFor(() => globalThis.forgottenFavicons.length === 1);
    assert.deepEqual(globalThis.forgottenFavicons, [[key(), [stored("f6")]]]);
    assert.equal(cached(gone), undefined);
    assert.deepEqual(useFavicons.getState().profiles[key()].srcs, { "https://history-kept.test/icon.png": stored("f6") });
    pruneEngineFavicons(key());
    assert.deepEqual(globalThis.forgottenFavicons[1], [key(), []]);
  } finally {
    for (const row of rows) row.unmount();
    stop();
  }
});

test("a plugin page and other internal addresses have no icon: nothing is looked up, fetched or kept for them", async () => {
  reset();
  const asked = [];
  globalThis.faviconsForTest = (profile, pages) => (asked.push(...pages), answering({})(profile, pages));
  const internal = ["ardia://notes/today", "ardia://history", "about:blank", "ARDIA://Notes/"];
  const tabId = tabOn(internal[0]);
  const rows = internal.map((url) => mount(() => useFavicon(url, "https://plugin.test/icon.png", "default")));
  try {
    noteFavicon(tabId, "https://plugin.test/icon.png");
    noteFavicon(tabId, stored("b8"));
    await settle();
    await settle();
    assert.deepEqual(asked.filter((page) => internal.includes(page)), []);
    assert.deepEqual(globalThis.fetchedFavicons, []);
    for (const url of internal) assert.equal(resolveFavicon(url, "https://plugin.test/icon.png", "default"), null);
    for (const url of internal) assert.equal(cached(url), undefined);
    useFavicons.setState({ profiles: { [key()]: { pages: { [internal[0]]: stored("c9") }, srcs: { "https://plugin.test/icon.png": stored("c9") }, appearances: {} } }, themes: {} });
    assert.equal(resolveFavicon(internal[0], "https://plugin.test/icon.png", "default"), null);
  } finally {
    for (const row of rows) row.unmount();
  }
});
