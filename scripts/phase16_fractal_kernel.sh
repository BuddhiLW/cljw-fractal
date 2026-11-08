#!/usr/bin/env bash
# e2e-process-boundary: rebuilds Zig wasm artifacts and compares compiler output.
# Correctness gate only: no timing thresholds. Ported from ClojureWasm phase16.
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="${CLJW_BIN:-cljw}"
fail() { echo "FAIL fractal-kernel: $1" >&2; exit 1; }
run_bounded() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"
  else fail "timeout or gtimeout is required"; fi
}

# Use a release binary, never silently build cljw from source or skip parity.
version="$(run_bounded 10 "$BIN" --version)" || fail "cannot query $BIN"
grep -q wasm <<<"$version" || fail "cljw needs Wasm support ($version)"
BIN="$(command -v "$BIN")" || fail "cannot locate $BIN"
case "$BIN" in /*) ;; *) BIN="$(pwd)/$BIN" ;; esac
DEMO="$(pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/cljw_fractal_XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

# Work in scratch, never modify committed artifacts or a contributor's files.
cp "$DEMO/bench.clj" "$DEMO/kernel.zig" "$DEMO/kernel.wasm" "$DEMO/kernel_simd.wasm" "$scratch/"
cp -R "$DEMO/fixtures" "$scratch/"
out="$(cd "$scratch" && FRACTAL_DIR="$scratch" CLJW_FRACTAL_CI=1 run_bounded 60 "$BIN" ./bench.clj 2>&1)" \
  || fail "committed artifact parity failed:
$out"
for marker in "PASS scalar artifact: strict engine and vector-source parity" \
              "PASS simd128 JIT strict parity" \
              "PASS perturbation: byte-identical scalar JIT/interp and simd128 JIT"; do
  grep -qF "$marker" <<<"$out" || fail "missing $marker:
$out"
done
# CI selects reduced views only: 18 plain frames + 9 perturbed (3 views x 3 engines).
[ "$(grep -c '^:.* checksum ' <<<"$out")" -eq 27 ] || fail "expected 27 parity frames:
$out"
echo "PASS fractal-kernel-committed -> 27 frames, scalar JIT/interp and simd128 JIT parity, perturbation included"

[[ "$(zig version)" == "0.16.0" ]] || fail "header recipes require Zig 0.16.0"
rm "$scratch/kernel.wasm" "$scratch/kernel_simd.wasm"
(cd "$scratch" && run_bounded 90 zig build-exe kernel.zig -target wasm32-freestanding -O ReleaseFast -fstrip -fno-entry -rdynamic -femit-bin=kernel.wasm) \
  || fail "scalar header recipe failed"
(cd "$scratch" && run_bounded 90 zig build-exe kernel.zig -target wasm32-freestanding -mcpu=generic+simd128 -O ReleaseFast -fstrip -fno-entry -rdynamic -femit-bin=kernel_simd.wasm) \
  || fail "SIMD header recipe failed"
for artifact in kernel.wasm kernel_simd.wasm; do
  cmp -s "$DEMO/$artifact" "$scratch/$artifact" \
    || fail "$artifact differs from exact header recipe output"
done
echo "PASS fractal-kernel-rebuilt -> both artifacts byte-identical to committed files"
