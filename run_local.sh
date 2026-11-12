#!/usr/bin/env bash
# Run the fractal demo using a sha256-verified cljw release, never a source build.
# First-run downloads are cached under /tmp, like the container's writable home.
#   ./run_local.sh
#   FRACTAL_PORT=9000 ./run_local.sh
#   CLJW=/path/to/cljw ./run_local.sh
set -euo pipefail
cd "$(dirname "$0")"

CLJW_VERSION="${CLJW_VERSION:-v1.15.8}"
CACHE_DIR="/tmp/cljw-fractal/cljw-$CLJW_VERSION"
CLJW="${CLJW:-$CACHE_DIR/cljw}"

if [[ ! -x "$CLJW" ]]; then
  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) asset=cljw-linux-x86_64.tar.gz ;;
    Darwin-arm64) asset=cljw-macos-aarch64.tar.gz ;;
    *) echo "no prebuilt cljw for $(uname -s)-$(uname -m); set CLJW=/path/to/cljw" >&2; exit 1 ;;
  esac
  url="https://github.com/BuddhiLW/ClojureWasm/releases/download/$CLJW_VERSION/$asset"
  echo "Fetching cljw $CLJW_VERSION ($asset), first run only"
  mkdir -p "$CACHE_DIR"
  work="$(mktemp -d /tmp/cljw-fractal-download.XXXXXX)"
  trap 'rm -rf "$work"' EXIT
  curl -fsSLo "$work/$asset" "$url"
  curl -fsSLo "$work/$asset.sha256" "$url.sha256"
  if command -v sha256sum >/dev/null; then
    (cd "$work" && sha256sum -c "$asset.sha256")
  else
    (cd "$work" && shasum -a 256 -c "$asset.sha256")
  fi
  tar -xzf "$work/$asset" -C "$work" cljw
  install -m 0755 "$work/cljw" "$CACHE_DIR/cljw"
  rm -rf "$work"
  trap - EXIT
fi

export FRACTAL_PORT="${FRACTAL_PORT:-8080}"
export FRACTAL_DIR="${FRACTAL_DIR:-$PWD}"
export HOME=/tmp
export TMPDIR=/tmp

echo "Fractal zoom: http://localhost:$FRACTAL_PORT (cljw: $CLJW)"
exec "$CLJW" server.clj "$@"
