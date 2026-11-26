#!/usr/bin/env bash
#
# UI smoke test: launch the built app against the demo server and render its
# main pages to PNGs (the app's BRIDGE_SNAPSHOT_DIR mode). Fails when a page
# never renders, comes out blank, or the app dies. CI runs it after the build.
#
#   ./scripts/smoke.sh [path/to/Bridge binary]

set -euo pipefail

PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${1:-$PROJ/dist/Bridge.app/Contents/MacOS/Bridge}"
PORT="${SMOKE_PORT:-4431}"
OUT="$(mktemp -d)"
PAGES="home,board,sessions,inbox,linear,pulls,usage,settings,palette,import,chat,split,messages"
DEMO_DIR="$(mktemp -d)"

cleanup() {
  [[ -n "${APP_PID:-}" ]] && kill "$APP_PID" 2>/dev/null || true
  [[ -n "${DEMO_PID:-}" ]] && kill "$DEMO_PID" 2>/dev/null || true
}
trap cleanup EXIT

BRIDGE_PORT="$PORT" BRIDGE_DEMO_DIR="$DEMO_DIR" node "$PROJ/scripts/demo.js" >"$OUT/demo.log" 2>&1 &
DEMO_PID=$!
for _ in $(seq 1 50); do
  curl -sf -H "Host: 127.0.0.1:$PORT" "http://127.0.0.1:$PORT/api/state" >/dev/null && break
  sleep 0.2
done

BRIDGE_PORT="$PORT" BRIDGE_SNAPSHOT_DIR="$OUT" BRIDGE_SNAPSHOT_PAGES="$PAGES" \
  BRIDGE_SNAPSHOT_CHAT=t-241125-web-124-apple-pay "$BIN" >"$OUT/app.log" 2>&1 &
APP_PID=$!

want=$(($(tr ',' '\n' <<<"$PAGES" | wc -l)))
for _ in $(seq 1 180); do
  have=$(find "$OUT" -name '*.png' ! -name 'usage-popover.png' | wc -l | tr -d ' ')
  [[ "$have" -ge "$want" ]] && break
  if ! kill -0 "$APP_PID" 2>/dev/null; then
    echo "error: the app exited early" >&2
    cat "$OUT/app.log" >&2
    exit 1
  fi
  sleep 1
done
sleep 2

fail=0
for p in ${PAGES//,/ }; do
  f="$OUT/$p.png"
  if [[ ! -s "$f" ]]; then
    echo "error: page '$p' didn't render" >&2
    fail=1
    continue
  fi
  # A blank page compresses to almost nothing; a real one is tens of KB at least.
  size=$(wc -c <"$f" | tr -d ' ')
  if [[ "$size" -lt 20000 ]]; then
    echo "error: page '$p' looks blank ($size bytes)" >&2
    fail=1
  else
    echo "ok   $p ($((size / 1024)) KB)"
  fi
done
if [[ "$fail" -ne 0 ]]; then
  tail -40 "$OUT/app.log" >&2 || true
  exit 1
fi
echo "smoke: $want pages rendered"
