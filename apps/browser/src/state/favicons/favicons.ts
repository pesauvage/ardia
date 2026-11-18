import { faviconsFor, fetchFavicon, forgetFavicons, isStoredFavicon, storeFavicon } from "../../platform/favicons";
import { withoutFragment } from "../../lib/url";
import { onHistoryChanged } from "../../platform/history";
import { useEffect } from "react";
import { useBrowser } from "../browser/store";
import { ALL, useKeyed, watchAppDark } from "../browser/keyedWatch";
import { isIncognitoProfile } from "../browser/model";
import { DEFAULT_PROFILE_ID } from "../settings/settings";
import { webviews } from "../../platform/webviews";
import { changedPages, pagesWrittenSince, withPages, type PagesPair } from "./pagesWritten";
import { onProfilesOpened, profileOpened } from "../profiles/profileLoading";
import { consentToken } from "../telemetry/client";
import { warnFor } from "../telemetry/logs";
import { fetchFailedBefore, forgetAsked, markAsked, noteFetchFailed, unmarkAsked } from "./askedFavicons";
import { removeLegacyFaviconFiles } from "./legacyFaviconFiles";
import { cacheKey, capped, EMPTY_ICONS, faviconChangesQueued, flushFaviconChanges, hasNoIcon, MAX_ICONS, queueFaviconChange, updateIcons as update, useFavicons, type Favicons } from "./faviconStore";
import { noteFaviconFailure, noteFaviconLookup, noteFaviconsHeld } from "../telemetry/faviconWork";

export { cacheKey, EMPTY_ICONS, knownFaviconTheme, useFavicons, type Favicons } from "./faviconStore";
export { isStoredFavicon };

const APPEARANCE_SWAP_MS = 5000;
const LOOKUP_DELAY_MS = 16;
const LOOKUP_BATCH = 200;
let appearanceChangedAt = -Infinity;

const siteOf = (url: string) => /^[a-z][\w+.-]*:\/\/[^/?#]*/i.exec(url)?.[0].toLowerCase() ?? "";
export const faviconOutlived = (iconPage: string | null, url: string) => !!iconPage && !!url && siteOf(iconPage) !== siteOf(url);

let watching = false;

const queued = new Map<string, Set<string>>();
let writeSeq = 0;
const inFlight = new Map<string, { lookups: number; wrote?: number }>();
const wrote = (key: string, page: string) => {
  const pending = inFlight.get(`${key}|${page}`);
  if (pending) pending.wrote = ++writeSeq;
};
let lookupTimer: ReturnType<typeof setTimeout> | undefined;

function ask(key: string, page: string) {
  if (isIncognitoProfile(key) || !markAsked(key, page)) return;
  if (!queued.has(key)) queued.set(key, new Set());
  queued.get(key)!.add(page);
  lookupTimer ??= setTimeout(lookUp, LOOKUP_DELAY_MS);
}

function lookUp() {
  lookupTimer = undefined;
  const batches = [...queued];
  queued.clear();
  for (const [key, pages] of batches) {
    const all = [...pages];
    for (let i = 0; i < all.length; i += LOOKUP_BATCH) lookUpPages(key, all.slice(i, i + LOOKUP_BATCH));
  }
}

function lookUpPages(key: string, list: string[], refresh = false) {
  const consent = consentToken();
  const pending = list.map((page) => {
    const id = `${key}|${page}`;
    const entry = inFlight.get(id) ?? { lookups: 0 };
    entry.lookups++;
    inFlight.set(id, entry);
    return { id, entry, started: entry.wrote };
  });
  void faviconsFor(key, list)
    .then((found) => {
      const started = performance.now();
      update(key, (icons) => {
        const writes: [string, string | null][] = [];
        let stored = false;
        for (const [i, page] of list.entries()) {
          if (pending[i]!.entry.wrote !== pending[i]!.started) continue;
          const uri = found.pages.get(page)?.uri ?? null;
          if (uri && isStoredFavicon(uri)) stored = true;
          if (icons.pages[page] !== uri && (uri || !refresh)) writes.push([page, uri]);
        }
        const srcs = refresh && stored ? withoutInlineIcons(icons.srcs) : icons.srcs;
        return writes.length || srcs !== icons.srcs ? { ...icons, srcs, pages: writes.length ? withPages(icons.pages, writes) : icons.pages } : icons;
      }, true);
      noteFaviconLookup(list.length, performance.now() - started, consent);
      noteFaviconsHeld(Object.keys(useFavicons.getState().profiles[key]?.pages ?? EMPTY_ICONS.pages).length, consent);
    })
    .catch((error) => {
      if (!refresh) for (const page of list) unmarkAsked(key, page);
      warnFor(consent, "[favicons] lookup failed", error);
    })
    .finally(() => {
      for (const { id, entry } of pending) if (--entry.lookups === 0) inFlight.delete(id);
    });
}

const INLINE_ICON = "data:image/";

function withoutInlineIcons(srcs: Record<string, string>): Record<string, string> {
  const kept = Object.entries(srcs).filter(([, uri]) => !uri.startsWith(INLINE_ICON));
  return kept.length === Object.keys(srcs).length ? srcs : Object.fromEntries(kept);
}

const seededInline = new Map<string, Set<string>>();

export function refreshInlineSeeds(key: string, pages: string[]) {
  if (!pages.length) return;
  const waiting = seededInline.get(key) ?? new Set<string>();
  for (const page of pages) waiting.add(page);
  seededInline.set(key, waiting);
  refreshSeeded();
}

function refreshSeeded() {
  for (const [key, pages] of [...seededInline]) {
    if (!profileOpened(key)) continue;
    seededInline.delete(key);
    const all = [...pages];
    for (let i = 0; i < all.length; i += LOOKUP_BATCH) lookUpPages(key, all.slice(i, i + LOOKUP_BATCH), true);
  }
}

const inflight = new Map<string, Promise<string | null>>();

export function noteFavicon(tabId: string, src: string) {
  const tab = useBrowser.getState().tabs[tabId];
  if (!tab?.url || !src || hasNoIcon(tab.url)) return;
  const key = cacheKey(tab.profileId);
  const page = withoutFragment(tab.url);
  if (isStoredFavicon(src)) return remember(key, page, "", src);
  const known = useFavicons.getState().profiles[key]?.srcs[src];
  if (known) return remember(key, page, src, known);
  const handle = webviews.get(tabId);
  if (!handle) return;
  const id = `${key}|${src}`;
  let pending = inflight.get(id);
  if (!pending) {
    pending = handle
      .downloadFavicon(src)
      .then((image) => image?.uri ?? null)
      .catch(() => null);
    inflight.set(id, pending);
    void pending.finally(() => inflight.delete(id));
  }
  void pending.then((uri) => uri && remember(key, page, src, uri));
}

function remember(key: string, page: string, src: string, uri: string) {
  const icons = faviconChangesQueued() ? undefined : useFavicons.getState().profiles[key];
  if (icons && icons.pages[page] === uri && (!src || icons.srcs[src] === uri)) return;
  const dark = useBrowser.getState().ui.appDark;
  const swapped = Date.now() - appearanceChangedAt < APPEARANCE_SWAP_MS;
  wrote(key, page);
  update(key, (icons) => {
    const previous = icons.pages[page];
    if (previous === uri && (!src || icons.srcs[src] === uri)) return icons;
    let appearances = icons.appearances;
    if (swapped && previous && previous !== uri) appearances = { ...appearances, [page]: dark ? [previous, uri] : [uri, previous] };
    const startsOver = Object.keys(icons.pages).length >= MAX_ICONS;
    const pages = startsOver ? { [page]: uri } : withPages(icons.pages, [[page, uri]]);
    if (startsOver) forgetAsked(key, pages);
    return { pages, srcs: !src || icons.srcs[src] === uri ? icons.srcs : capped(icons.srcs, src, uri), appearances };
  });
}

export type KnownFavicon = { page: string; icon: string; png: string };

const PNG_DATA_URI = "data:image/png;base64,";

export function adoptFavicons(profileId: string, known: KnownFavicon[]) {
  if (isIncognitoProfile(profileId) || !known.length) return;
  const key = cacheKey(profileId);
  const found = new Map(known.map((f) => [withoutFragment(f.page), f]));
  for (const page of found.keys()) wrote(key, page);
  update(key, (icons) => {
    const fresh = [...found].filter(([page]) => !icons.pages[page]);
    if (!fresh.length) return icons;
    const startsOver = Object.keys(icons.pages).length + fresh.length > MAX_ICONS;
    const writes = fresh.map(([page, f]): [string, string] => [page, `${PNG_DATA_URI}${f.png}`]);
    const pages = startsOver ? Object.fromEntries(writes) : withPages(icons.pages, writes);
    if (startsOver) forgetAsked(key, pages);
    return { ...icons, pages };
  }, true);
  void (async () => {
    for (const [page, f] of found) {
      const inline = `${PNG_DATA_URI}${f.png}`;
      const uri = await storeFavicon(key, page, f.icon, f.png).catch(() => null);
      if (uri && uri !== inline) update(key, (icons) => (icons.pages[page] === inline ? { ...icons, pages: withPages(icons.pages, [[page, uri]]) } : icons));
    }
  })();
}

function fetchMissing(profileId: string, url: string, src: string) {
  const key = cacheKey(profileId);
  if (isIncognitoProfile(profileId) || !/^https?:/i.test(src) || !profileOpened(key)) return;
  const id = `${key}|${src}`;
  if (inflight.has(id) || fetchFailedBefore(id)) return;
  const pending = fetchFavicon(src, key, withoutFragment(url))
    .then((image) => {
      if (image?.uri.startsWith(PNG_DATA_URI)) void storeFavicon(key, withoutFragment(url), src, image.uri.slice(PNG_DATA_URI.length)).catch(() => null);
      return image?.uri ?? null;
    })
    .catch(() => null);
  inflight.set(id, pending);
  void pending.then((uri) => {
    inflight.delete(id);
    if (uri) remember(key, withoutFragment(url), src, uri);
    else noteFetchFailed(id, MAX_ICONS);
  });
}

const askedAgain = new Set<string>();

export function faviconFailed(profileId: string, uri: string): boolean {
  const key = cacheKey(profileId);
  const again = isStoredFavicon(uri) && !askedAgain.has(uri) && !isIncognitoProfile(key);
  if (again) {
    if (askedAgain.size >= MAX_ICONS) askedAgain.clear();
    askedAgain.add(uri);
  }
  noteFaviconFailure(again);
  update(key, (icons) => {
    if (!Object.values(icons.pages).includes(uri) && !Object.values(icons.srcs).includes(uri)) return icons;
    const lost = Object.keys(icons.pages).filter((page) => icons.pages[page] === uri);
    if (again) for (const page of lost) unmarkAsked(key, page);
    const gone = new Set(lost);
    return {
      pages: again
        ? Object.fromEntries(Object.entries(icons.pages).filter(([page]) => !gone.has(page)))
        : Object.fromEntries(Object.entries(icons.pages).map(([page, u]) => [page, u === uri ? null : u])),
      srcs: Object.fromEntries(Object.entries(icons.srcs).filter(([, u]) => u !== uri)),
      appearances: icons.appearances,
    };
  });
  return again;
}

export type ResolvedFavicon = { uri: string; profileId: string };

function lookupIn(key: string, url: string, src: string | null | undefined): string | undefined {
  const icons = useFavicons.getState().profiles[key];
  if (!icons) return undefined;
  const page = withoutFragment(url);
  const pair = icons.appearances[page];
  if (pair) return pair[useBrowser.getState().ui.appDark ? 1 : 0];
  return (src ? icons.srcs[src] : undefined) ?? icons.pages[page] ?? undefined;
}

function lookupOrder(profileId?: string): string[] {
  if (profileId && !isIncognitoProfile(profileId)) return [profileId];
  return [...new Set([...(profileId ? [profileId] : []), DEFAULT_PROFILE_ID, ...useBrowser.getState().profileOrder])];
}

export function resolveFavicon(url: string, src?: string | null, profileId?: string): ResolvedFavicon | null {
  if (!url || hasNoIcon(url)) return null;
  for (const id of lookupOrder(profileId)) {
    const uri = lookupIn(cacheKey(id), url, src);
    if (uri) return { uri, profileId: id };
  }
  return null;
}

export const useAppearanceDark = () => useKeyed(watchAppDark, ALL, () => useBrowser.getState().ui.appDark);

function answered(url: string, profileId?: string): boolean {
  const { profiles } = useFavicons.getState();
  const page = withoutFragment(url);
  return lookupOrder(profileId).every((id) => !askable(id) || profiles[cacheKey(id)]?.pages[page] !== undefined);
}

const askable = (id: string) => !isIncognitoProfile(id) && profileOpened(cacheKey(id));

type Watcher = { url: string; src?: string | null; profileId?: string; known?: boolean };
const watchers = new Map<string, Set<Watcher>>();

function check(w: Watcher) {
  const known = answered(w.url, w.profileId);
  if (known === w.known) return;
  w.known = known;
  if (!known) {
    for (const id of lookupOrder(w.profileId)) if (askable(id)) ask(cacheKey(id), withoutFragment(w.url));
  } else if (w.src && w.profileId && !resolveFavicon(w.url, w.src, w.profileId)) fetchMissing(w.profileId, w.url, w.src);
}

function onFavicons(f: Favicons, prev: Favicons) {
  if (f.profiles === prev.profiles || !watchers.size) return;
  const pairs = changedPages(f, prev);
  if (!pairs.length) return;
  const due = new Set<Set<Watcher>>();
  const unknown: PagesPair[] = [];
  for (const pair of pairs) {
    const written = pair.now && pagesWrittenSince(pair.now, pair.before ?? EMPTY_ICONS.pages);
    if (!written) unknown.push(pair);
    else
      for (const page of written) {
        const set = watchers.get(page);
        if (set) due.add(set);
      }
  }
  if (unknown.length)
    watchers.forEach((set, page) => {
      for (let i = 0; i < unknown.length; i++)
        if (unknown[i]!.now?.[page] !== unknown[i]!.before?.[page]) {
          due.add(set);
          return;
        }
    });
  for (const set of due) for (const w of [...set]) check(w);
}

function watch(w: Watcher) {
  if (!watching) {
    watching = true;
    useFavicons.subscribe(onFavicons);
  }
  const page = withoutFragment(w.url);
  let set = watchers.get(page);
  if (!set) watchers.set(page, (set = new Set()));
  set.add(w);
  check(w);
  return () => {
    set.delete(w);
    if (!set.size && watchers.get(page) === set) watchers.delete(page);
  };
}

export function useFavicon(url: string, src?: string | null, profileId?: string): ResolvedFavicon | null {
  const key = useFavicons(() => {
    const found = resolveFavicon(url, src, profileId);
    return found ? `${found.profileId} ${found.uri}` : null;
  });
  const missing = !!url && !key && !hasNoIcon(url);
  const order = missing ? lookupOrder(profileId).join(" ") : "";
  useEffect(() => (missing ? watch({ url, src, profileId }) : undefined), [missing, order, profileId, url, src]);
  const split = key?.indexOf(" ") ?? -1;
  return key ? { profileId: key.slice(0, split), uri: key.slice(split + 1) } : null;
}

function forget(key: string) {
  forgetAsked(key);
  for (const [id, pending] of inFlight) if (id.startsWith(`${key}|`)) pending.wrote = ++writeSeq;
  update(key, () => EMPTY_ICONS, true);
  dropStored(key);
}

function dropStored(key: string) {
  flushFaviconChanges();
  const icons = useFavicons.getState().profiles[key] ?? EMPTY_ICONS;
  const held = [...Object.values(icons.pages), ...Object.values(icons.srcs), ...Object.values(icons.appearances).flat()];
  void forgetFavicons(key, [...new Set(held.filter((uri): uri is string => !!uri && isStoredFavicon(uri)))]).catch(() => null);
}

export const pruneEngineFavicons = (engine: string) => forget(engine);

export function startFavicons() {
  removeLegacyFaviconFiles(useBrowser.getState(), consentToken());
  const history = onHistoryChanged((change) => {
    if (change.kind !== "deleted") return;
    if (change.all) return forget(change.profile);
    const gone = new Set(change.urls.map(withoutFragment));
    const key = change.profile;
    for (const page of gone) unmarkAsked(key, page);
    const shown = new Set(Object.values(useBrowser.getState().tabs).map((t) => t.favicon));
    update(key, (icons) => {
      if (!Object.keys(icons.pages).some((page) => gone.has(page))) return icons;
      const pages = Object.fromEntries(Object.entries(icons.pages).filter(([page]) => !gone.has(page)));
      const kept = new Set(Object.values(pages));
      const lost = new Set(Object.entries(icons.pages).flatMap(([page, uri]) => (gone.has(page) && uri && !kept.has(uri) ? [uri] : [])));
      return { ...icons, pages, srcs: Object.fromEntries(Object.entries(icons.srcs).filter(([src, uri]) => shown.has(src) || !lost.has(uri))) };
    });
    dropStored(key);
  });
  const opened = onProfilesOpened(() => {
    refreshSeeded();
    for (const set of [...watchers.values()])
      for (const w of [...set]) {
        w.known = undefined;
        check(w);
      }
  });
  const stop = useBrowser.subscribe((s, prev) => {
    if (s.ui.appDark !== prev.ui.appDark) appearanceChangedAt = Date.now();
    if (s.windows !== prev.windows && (faviconChangesQueued() || Object.keys(useFavicons.getState().profiles).some(isIncognitoProfile))) {
      const open = new Set(Object.values(s.windows).map((w) => w.profileId));
      for (const t of Object.values(s.tabs)) open.add(t.profileId);
      queueFaviconChange((f) => {
        const gone = Object.keys(f.profiles).filter((id) => isIncognitoProfile(id) && !open.has(id));
        for (const id of gone) void forgetFavicons(id, []).catch(() => null);
        return gone.length ? { ...f, profiles: Object.fromEntries(Object.entries(f.profiles).filter(([id]) => !gone.includes(id))) } : f;
      }, true);
    }
  });
  refreshSeeded();
  return () => {
    history.remove();
    opened();
    stop();
  };
}
