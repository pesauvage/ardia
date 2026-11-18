#!/usr/bin/env bash
set -euo pipefail

usage="usage: scripts/release/cli-bootstrap-smoke.sh <Ardia.app> <version>
Launches a hidden instance of <Ardia.app> on a fresh scratch data folder with a scratch bin folder and checks what a
new user gets with no action: the built-in Command Line plugin links ardia there (so its copy passed the signed
digest check), it is <version>, control is on, and ardia tabs answers."
case "${1:-}" in -h | --help | "") echo "$usage"; [ -n "${1:-}" ] && exit 0 || exit 64 ;; esac
app="$(cd "$1" && pwd -P)"
version="${2:?$usage}"
case "$app" in /Applications/*) echo "error: never an installed app" >&2; exit 1 ;; esac
work="$(cd "$(mktemp -d /tmp/ac-cli.XXXXXX)" && pwd -P)"
data="$work/d"
bin="$work/bin"
mkdir -p "$data" "$bin"
pid=""
cleanup() {
  [ -n "$pid" ] && { kill "$pid" 2>/dev/null; for _ in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done; kill -KILL "$pid" 2>/dev/null; } || true
  rm -rf "$work"
}
trap cleanup EXIT

status=0
check() {
  if [ "$2" = 1 ]; then echo "PASS  $1"; else echo "FAIL  $1${3:+  ($3)}"; status=1; fi
}

echo '{"version":1,"completedAt":1}' >"$data/onboarding.json"
open -g -n --env ARDIA_BACKGROUND=1 --env "ARDIA_DATA_DIR=$data" --env "ARDIA_INSTANCE=cliBinDir=$bin" \
  --stdout "$data/app.out.log" --stderr "$data/app.out.log" "$app"
for _ in $(seq 1 100); do pid="$(pgrep -n -f "^$app/Contents/MacOS/Ardia" || true)"; [ -n "$pid" ] && break; sleep 0.1; done
for _ in $(seq 1 300); do [ -L "$bin/ardia" ] && break; sleep 0.2; done
check "a fresh data folder gets ardia with no action" "$([ -L "$bin/ardia" ] && echo 1 || echo 0)"
got="$("$bin/ardia" --version 2>&1 || true)"
check "it is the release's ardia" "$([ "$got" = "ardia $version" ] && echo 1 || echo 0)" "$got"
control="$data/Chromium/ArdiaControl.json"
for _ in $(seq 1 150); do [ -s "$control" ] && break; sleep 0.2; done
check "its first link turned control on" "$([ -s "$control" ] && echo 1 || echo 0)"
tabs="$(env -i HOME="$HOME" PATH="$bin:/usr/bin:/bin" ARDIA_DATA_DIR="$data" ARDIA_TELEMETRY=off ardia tabs 2>&1)" && ok=1 || ok=0
check "ardia tabs answers" "$ok" "$tabs"
exit "$status"
