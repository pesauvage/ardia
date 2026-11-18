import { call } from "./engine/call";

export type FaviconImage = { uri: string; width: number; height: number };

const PNG_DATA_URI = "data:image/png;base64,";
const uriOf = (found: { uri?: string; png?: string }) => found.uri ?? `${PNG_DATA_URI}${found.png}`;

export async function faviconsFor(profile: string, pages: string[], icons: string[] = [], size = 32) {
  const result = await call("favicons.get", { profile, pages, icons, size });
  return {
    pages: new Map(Object.entries(result.pages).map(([page, r]) => [page, { uri: uriOf(r), icon: r.icon }])),
    icons: new Map(Object.entries(result.icons).map(([icon, r]) => [icon, uriOf(r)])),
  };
}

export async function storeFavicon(profile: string, page: string, icon: string, png: string): Promise<string> {
  const { uri } = await call("favicons.set", { profile, page, icon, png });
  return uri ?? `${PNG_DATA_URI}${png}`;
}

export const fetchFavicon = (url: string, profile: string, page?: string) => call("favicons.fetch", page ? { profile, url, page } : { profile, url });

export const forgetFavicons = (profile: string, keeping: string[]) => call("favicons.forget", { profile, keeping });

export const isStoredFavicon = (uri: string) => uri.startsWith("ardia-favicon:");
