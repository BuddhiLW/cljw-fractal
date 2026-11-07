# Wasm module provenance

Both committed `.wasm` files are build artifacts of the first-party,
hand-written [`kernel.zig`](./kernel.zig) in this repo, licensed under
[MIT](./LICENSE). There are no vendored third-party library binaries, module
imports, WASI, or network fetches in either kernel. They are committed so the
app deploys self-contained, without a compiler stage.

The initial app and kernel artifacts were imported from
[BuddhiLW/ClojureWasm](https://github.com/BuddhiLW/ClojureWasm),
`docs/examples/fractal/`, at staging commit
`e5fddbc70fcc302579fa1245e10e69e06591334b`.
The HTTP and kernel checks were ported from `test/e2e/phase16_fractal_server.sh`
and `test/e2e/phase16_fractal_kernel.sh` at the same commit. The standalone
source differs only in path conventions, deployment configuration, health,
and relative browser URLs. The build command paths in `kernel.zig` were
adapted to this repo root; kernel code and committed Wasm bytes are unchanged.

| artifact | source | toolchain and target | use |
|---|---|---|---|
| `kernel.wasm` | `kernel.zig` | Zig 0.16.0, `wasm32-freestanding`, ReleaseFast | browser, zwasm scalar JIT and interpreter |
| `kernel_simd.wasm` | `kernel.zig` | Zig 0.16.0, `wasm32-freestanding`, `generic+simd128`, ReleaseFast | zwasm SIMD JIT and browser-compatible parity oracle |

## Exact build recipes

Run from the repo root with **Zig 0.16.0**. These are the recipes in the
source header, with root-relative source and output paths:

```sh
zig build-exe kernel.zig -target wasm32-freestanding -O ReleaseFast -fstrip -fno-entry -rdynamic -femit-bin=kernel.wasm
zig build-exe kernel.zig -target wasm32-freestanding -mcpu=generic+simd128 -O ReleaseFast -fstrip -fno-entry -rdynamic -femit-bin=kernel_simd.wasm
```

`render_simd` exists in both builds. Zig scalarizes its vector operations in
the default build; only the simd128 artifact uses SIMD instructions. zwasm's
interpreter uses the scalar artifact because it cannot execute SIMD.

## SHA256 of the imported artifacts

```text
a0c1976b8ca112b966f211ae2bdf539ab3b06fa61d291e12e5dc94241af25e41  kernel.wasm
a5efc7e9c1bcc621e3fb675ec22de97d07a599c7475469e14858bb04c0eccd9e  kernel_simd.wasm
```

Each hash was checked against the committed upstream blob, not a text
conversion. `scripts/phase16_fractal_kernel.sh` rebuilds both artifacts in a
scratch directory and requires byte equality with the committed files.
It also compares 18 small frames across scalar JIT, interpreter, and SIMD
JIT. `node verify.mjs` independently checks zero imports, exact scalar/vector
pixels and totals, alpha, odd tails, invalid inputs, and known points using
Node's browser-compatible WebAssembly implementation.

The container's cljw runtime is a separate release artifact, fetched from
BuddhiLW/ClojureWasm and verified with the Dockerfile's `CLJW_SHA256` pin.
Runtime and dependency licensing is separate from the MIT demo sources.
