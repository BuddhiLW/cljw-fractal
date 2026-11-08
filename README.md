# Fractal zoom: one kernel.wasm, server and browser

A Mandelbrot explorer where the same WebAssembly module renders in the
browser and on native [ClojureWasm](https://github.com/BuddhiLW/ClojureWasm)
(`cljw`). The page compares engines live: cljw's HTTP server renders tiles
with zwasm while the browser instantiates the identical `kernel.wasm` locally.
No JVM, no Node server, no CDN.

Live at <https://cljw.buddhilw.com/fractal/>. Deployment is managed by the
operator; see [`DEPLOY.md`](./DEPLOY.md).

This standalone demo follows the maintained
[cw-playground](https://github.com/clojurewasm/cw-playground) conventions:
a pinned, sha256-verified cljw release, committed Wasm artifacts, a non-root
container, and daily release-following automation. The runtime pin is cljw
`v1.15.7` (ReleaseSafe with Wasm support). Runtime releases, not source builds,
are used for the image and CI.

## What's inside

| file | role |
|---|---|
| [`kernel.zig`](./kernel.zig) | first-party Mandelbrot kernel; exact build recipes in its header |
| `kernel.wasm` | scalar build, no imports, runs on every engine |
| `kernel_simd.wasm` | simd128 build, for JIT engines only |
| [`server.clj`](./server.clj) | page, kernel, health, and tile server |
| [`index.html`](./index.html) | self-contained browser viewer |
| [`bench.clj`](./bench.clj) | native benchmark with strict cross-engine parity |
| [`verify.mjs`](./verify.mjs) | browser-compatible WebAssembly oracle, run with Node |
| [`scripts/`](./scripts/) | version pins, kernel reproducibility, and HTTP checks |

The committed binaries are self-contained build artifacts, not downloads at
server startup. Their sources, hashes, and rebuild recipe are documented in
[`PROVENANCE.md`](./PROVENANCE.md).

## Run it

### Docker

```sh
docker build -t cljw-fractal .
docker run --rm -p 8080:8080 --read-only --tmpfs /tmp cljw-fractal
```

Open <http://localhost:8080/>. Published images use
`ghcr.io/buddhilw/cljw-fractal:latest` and `:main-<7-char sha>`.
The container runs as UID 10001 and writes only to writable `/tmp`.

### Local cljw

```sh
cljw server.clj                       # default 8080
FRACTAL_PORT=9000 cljw server.clj      # environment-selected port
cljw server.clj 9001                  # CLI port takes precedence
```

Or run `./run_local.sh` to fetch and sha256-verify the pinned release on first
use, cached under `/tmp/cljw-fractal/`. Set `CLJW=/path/to/cljw` to use an
existing binary. App files default to the script directory;
`FRACTAL_DIR=/path/to/app` overrides the page and both kernel paths.
`KERNEL=/path/to/other.wasm` overrides only the scalar module.

The server loads one instance per engine at startup and reuses it. Each
request runs `set_view` then `render` under that instance's lock.

| route | answer |
|---|---|
| `GET /healthz` | `200 ok`, no render or file read |
| `GET /` | the page |
| `GET /kernel.wasm` | scalar kernel bytes, `application/wasm` |
| `GET /engines` | `{"engines":["jit","interp","jit-simd"]}` with both artifacts present |
| `GET /tile?cx=&cy=&scale=&w=&h=&iter=&engine=` | `w*h*4` raw RGBA8 bytes, `X-Render-Ms` and `X-Iters` headers |

`jit` uses the scalar kernel on zwasm's JIT. `jit-simd` uses
`kernel_simd.wasm` on the JIT. `interp` uses the scalar kernel on zwasm's
interpreter, which does not support SIMD instructions. The `jit-simd` engine
is omitted when its artifact is absent. Binary response bodies require
cljw's `feat(http): accept byte-array response bodies` change (commit
`da68e7b131c3d9a5d30c4a2b6fcc864e408b28eb`).

All browser fetch URLs are relative, so a prefix-stripping gateway can serve
the app at `/fractal/` just as at `/`. Redirect `/fractal` to `/fractal/`.

## The page

Mouse wheel zooms around the cursor, drag pans, double-click zooms in, the
slider sets the iteration cap, and Reset returns home. Modes are Browser,
each server engine, and Split (browser left, server right, same view).
Bench renders a fixed view list on every engine and tabulates the results.

- **ms/frame**: browser wall time of `render`; server guest render time only
  (`X-Render-Ms`), excluding network and copy time.
- **Miter/s**: total Mandelbrot iterations divided by render time. Compare
  engines within one view, not different zoom depths or iteration caps.

## The kernel ABI

| export | signature | meaning |
|---|---|---|
| `memory` | | linear memory holding the framebuffer |
| `fb_ptr` | `() -> i32` | byte address of the RGBA8 framebuffer |
| `fb_cap` | `() -> i32` | capacity in pixels (1048576) |
| `set_view` | `(f64 f64 f64) -> i32` | stores cx, cy, scale; 0, or -1 for nonfinite input |
| `render` | `(i32 i32 i32) -> i64` | writes `w*h` pixels; returns total iterations or -1 on invalid input |
| `render_simd` | `(i32 i32 i32) -> i64` | same output, vectorized in the simd128 build, scalarized in the scalar build |

Pixel `(px, py)` is `(cx + (px - w/2) * scale, cy + (py - h/2) * scale)`.
A separate `set_view` returning `i32` avoids cljw's tracked JIT wide-arity and
void-result call-boundary gaps.

## Benchmark and checks

```sh
cljw bench.clj                         # timings and /tmp/cljw-fractal-out.ppm
node verify.mjs                       # independent WebAssembly oracle
bash scripts/check_version_pins.sh
CLJW_BIN=/path/to/cljw bash scripts/phase16_fractal_kernel.sh
CLJW_BIN=/path/to/cljw bash scripts/phase16_fractal_server.sh
```

The kernel check needs Zig 0.16.0. It compares 18 small frames across the
scalar JIT, interpreter, and simd128 JIT, then rebuilds both artifacts from
the header recipes and requires byte equality. The server check exercises
real HTTP, environment configuration, relative URLs, exact kernel bytes,
and identical tile pixels and iteration totals across all three engines.
Set `FRACTAL_BASE_URL=http://127.0.0.1:18080` to check a running container.
There are no performance thresholds. CI downloads the same pinned cljw
release as the image; it never builds the runtime from source.

## License

Demo sources are [MIT](./LICENSE), copyright Pedro Gomes Branquinho.
The ClojureWasm runtime and its dependencies retain their own licenses.
