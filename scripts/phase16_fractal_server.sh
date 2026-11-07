#!/usr/bin/env bash
# e2e-process-boundary: server.clj over real HTTP. Ported from ClojureWasm phase16.
# Check health, app bytes, relative URLs, engines, and exact tile parity.
# Set FRACTAL_BASE_URL to check an already running container instead.
set -euo pipefail
cd "$(dirname "$0")/.."
DEMO="$(pwd)"
PORT="${FRACTAL_TEST_PORT:-18159}"
BASE="${FRACTAL_BASE_URL:-http://127.0.0.1:$PORT}"
fail() { echo "FAIL fractal-server: $1" >&2; exit 1; }
run_bounded() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"
  else fail "timeout or gtimeout is required"; fi
}
command -v curl >/dev/null 2>&1 || fail "curl is required"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/cljw_fractal_srv_XXXXXX")"
SRV=""
stop_server() {
  if [[ -n "$SRV" ]]; then
    kill "$SRV" 2>/dev/null || true
    wait "$SRV" 2>/dev/null || true
    SRV=""
  fi
}
cleanup() { stop_server; rm -rf "$scratch"; }
trap cleanup EXIT
wait_server() {
  local up=0
  for _ in $(seq 1 100); do
    if curl -fsS --max-time 2 -o /dev/null "$BASE/healthz" 2>/dev/null; then up=1; break; fi
    sleep 0.1
  done
  [[ "$up" == 1 ]] || fail "server did not come up at $BASE; see $scratch/server.log"
}

if [[ -z "${FRACTAL_BASE_URL:-}" ]]; then
  BIN="${CLJW_BIN:-cljw}"
  version="$(run_bounded 10 "$BIN" --version)" || fail "cannot query $BIN"
  grep -q wasm <<<"$version" || fail "cljw needs Wasm support ($version)"
  BIN="$(command -v "$BIN")" || fail "cannot locate $BIN"
  case "$BIN" in /*) ;; *) BIN="$DEMO/$BIN" ;; esac
  mkdir "$scratch/app"
  cp kernel.wasm kernel_simd.wasm index.html "$scratch/app/"
  printf '\n<!-- FRACTAL_DIR override -->\n' >> "$scratch/app/index.html"
  # Different cwd and app root; the CLI port must override FRACTAL_PORT.
  (cd "$scratch" && FRACTAL_DIR="$scratch/app" FRACTAL_PORT="$((PORT + 1))" \
    run_bounded 120 "$BIN" "$DEMO/server.clj" "$PORT") >"$scratch/server.log" 2>&1 &
  SRV=$!
fi
wait_server

health="$(curl -fsS --max-time 10 "$BASE/healthz")"
[[ "$health" == "ok" ]] || fail "/healthz: got '$health'"
echo "PASS fractal-server-healthz -> 200 ok"

curl -fsS --max-time 10 -o "$scratch/page.html" "$BASE/"
if [[ -z "${FRACTAL_BASE_URL:-}" ]]; then
  cmp -s "$scratch/page.html" "$scratch/app/index.html" || fail "FRACTAL_DIR did not select the page"
  echo "PASS fractal-server-config -> FRACTAL_DIR and CLI port override"
else
  cmp -s "$scratch/page.html" "$DEMO/index.html" || fail "/ differs from index.html"
fi
for url in engines kernel.wasm 'tile?'; do
  grep -qF "fetch(\"$url\"" "$scratch/page.html" || fail "missing relative fetch: $url"
done
if grep -qF 'fetch("/' "$scratch/page.html"; then fail "root-relative fetch breaks gateway prefixes"; fi
echo "PASS fractal-server-page -> relative engines, kernel.wasm, tile URLs"

engines="$(curl -fsS --max-time 10 "$BASE/engines")"
[[ "$engines" == '{"engines":["jit","interp","jit-simd"]}' ]] || fail "/engines: got '$engines'"
echo "PASS fractal-server-engines -> $engines"

curl -fsS --max-time 10 -o "$scratch/kernel.wasm" "$BASE/kernel.wasm"
cmp -s "$scratch/kernel.wasm" "$DEMO/kernel.wasm" || fail "/kernel.wasm differs from the committed file"
echo "PASS fractal-server-kernel -> $(wc -c <"$DEMO/kernel.wasm" | tr -d ' ') bytes, identical"

W=64; H=48
ref_iters=""
for e in jit interp jit-simd; do
  curl -fsS --max-time 30 -D "$scratch/h.$e" -o "$scratch/t.$e" \
    "$BASE/tile?cx=-0.5&cy=0&scale=0.05&w=$W&h=$H&iter=128&engine=$e"
  len=$(wc -c <"$scratch/t.$e" | tr -d ' ')
  [[ "$len" == $((W * H * 4)) ]] || fail "/tile $e: $len bytes, want $((W * H * 4))"
  grep -qi '^x-render-ms:' "$scratch/h.$e" || fail "/tile $e: no X-Render-Ms header"
  iters=$(grep -i '^x-iters:' "$scratch/h.$e" | tr -d '\r' | awk '{print $2}')
  [[ "$iters" =~ ^[0-9]+$ && "$iters" -gt 0 ]] || fail "/tile $e: bad X-Iters '$iters'"
  if [[ -z "$ref_iters" ]]; then ref_iters="$iters"
  else
    cmp -s "$scratch/t.$e" "$scratch/t.jit" || fail "/tile $e pixels differ from jit"
    [[ "$iters" == "$ref_iters" ]] || fail "/tile $e X-Iters $iters, jit had $ref_iters"
  fi
done
echo "PASS fractal-server-tiles -> ${W}x${H} RGBA ($((W * H * 4)) bytes) on jit, interp, jit-simd, identical (X-Iters $ref_iters)"

code=$(curl -sS --max-time 10 -o /dev/null -w "%{http_code}" "$BASE/tile?engine=nope")
[[ "$code" == "400" ]] || fail "/tile unknown engine: status $code, want 400"
echo "PASS fractal-server-bad-engine -> 400"

if [[ -z "${FRACTAL_BASE_URL:-}" ]]; then
  stop_server
  # No CLI port or FRACTAL_DIR: read assets relative to the script, not cwd.
  (cd "$scratch" && env -u FRACTAL_DIR FRACTAL_PORT="$PORT" \
    run_bounded 120 "$BIN" "$DEMO/server.clj") >"$scratch/server.log" 2>&1 &
  SRV=$!
  wait_server
  curl -fsS --max-time 10 -o "$scratch/default-page.html" "$BASE/"
  cmp -s "$scratch/default-page.html" "$DEMO/index.html" || fail "script-directory default did not select the page"
  echo "PASS fractal-server-env -> FRACTAL_PORT and script-directory asset default"
fi
