import { consentToken, stillValid, type ConsentToken } from "./consentPeriod";

const none = () => ({ lookups: 0, pages: 0, msTotal: 0, msMax: 0, heldMax: 0, failures: 0, askedAgain: 0 });

let tally = none();
let period: ConsentToken | null = null;

function counts(consent: ConsentToken | null) {
  if (!stillValid(consent)) return null;
  if (period !== consent) {
    period = consent;
    tally = none();
  }
  return tally;
}

export function noteFaviconLookup(pages: number, ms: number, consent: ConsentToken | null) {
  const counted = counts(consent);
  if (!counted) return;
  counted.lookups++;
  counted.pages += pages;
  counted.msTotal += ms;
  counted.msMax = Math.max(counted.msMax, ms);
}

export function noteFaviconsHeld(held: number, consent: ConsentToken | null) {
  const counted = counts(consent);
  if (counted) counted.heldMax = Math.max(counted.heldMax, held);
}

export function noteFaviconFailure(asksAgain: boolean) {
  const counted = counts(consentToken());
  if (!counted) return;
  counted.failures++;
  if (asksAgain) counted.askedAgain++;
}

export function takeFaviconWorkCounts() {
  const taken = stillValid(period) ? tally : none();
  tally = none();
  return {
    favicon_lookups: taken.lookups,
    favicon_lookup_pages: taken.pages,
    favicon_lookup_ms_total: Math.round(taken.msTotal),
    favicon_lookup_ms_max: Math.round(taken.msMax),
    favicon_pages_held_max: taken.heldMax,
    favicon_load_failures: taken.failures,
    favicon_loads_asked_again: taken.askedAgain,
  };
}
