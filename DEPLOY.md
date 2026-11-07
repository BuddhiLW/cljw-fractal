# Running and deploying the ClojureWasm fractal demo

The app is self-contained. `cljw` is the pinned release binary of
[BuddhiLW/ClojureWasm](https://github.com/BuddhiLW/ClojureWasm/releases)
(`v1.15.5`, ReleaseSafe with the Wasm FFI), checked against a pinned sha256.
The page and both Wasm kernels are committed artifacts, with no frontend build
or cljw source build in the image. See [`PROVENANCE.md`](./PROVENANCE.md).

## Local

```sh
./run_local.sh                       # fetch once into /tmp, serve :8080
FRACTAL_PORT=9000 ./run_local.sh       # override the environment
CLJW=/path/to/cljw ./run_local.sh     # use an existing release binary
cljw server.clj 9001                  # CLI port overrides FRACTAL_PORT
```

Rebuild kernels only when changing them, with Zig 0.16.0 and the exact
commands in the source header or `PROVENANCE.md`. Commit the artifacts too.

## Container image

`ghcr.io/buddhilw/cljw-fractal`, tags `main-<7-char sha>` and `latest`.
`.github/workflows/image.yml` builds and pushes on every push to `main`, on
demand, and as a reusable workflow. It uses the same pinned action SHAs and
two-stage `debian:bookworm-slim` shape as the maintained cw-playground demo.
`.github/workflows/cljw-bump.yml` checks daily for a newer cljw release,
verifies its checksum and available attestation, rewrites all pins, runs the
HTTP checks before committing, then publishes through the reusable image
workflow. A `GITHUB_TOKEN` push alone does not start another workflow.

```sh
docker build -t cljw-fractal .
docker run --rm --name cljw-fractal -p 8080:8080 \
  --read-only --tmpfs /tmp cljw-fractal
```

The image runs as UID/GID 10001 and works with a read-only root filesystem.
Only `/tmp` is writable, and `HOME` and `TMPDIR` point there. The server does
not write files. The runtime image contains only cljw and the app files:
`server.clj`, `index.html`, `kernel.wasm`, `kernel_simd.wasm`.

| env | default in image | meaning |
|---|---|---|
| `FRACTAL_PORT` | `8080` | listen port, binds 0.0.0.0; CLI port wins |
| `FRACTAL_DIR` | `/app` | page and kernel root; outside Docker defaults to script dir |
| `KERNEL` | unset | optional scalar kernel override |
| `HOME` | `/tmp` | writable runtime home |
| `TMPDIR` | `/tmp` | writable temporary directory |

To verify the read-only container from the host:

```sh
FRACTAL_BASE_URL=http://127.0.0.1:8080 bash scripts/phase16_fractal_server.sh
```

## Kubernetes

Served at <https://cljw.buddhilw.com/fractal/>. The gateway strips the
`/fractal` prefix, so the server sees `/`, `/engines`, `/kernel.wasm`, and
`/tile`. All page fetch URLs are relative. The gateway should redirect
`/fractal` to `/fractal/` so the browser retains the prefix.

This app is deployed by the operator's cluster manifests. The operator
maintains those separately in the private presentations repository under
`k8s/cljw-demos`; this public repo does not carry cluster manifests or
credentials.

- Probes: `GET /healthz` returns `200 ok`, without rendering or file access.
- Container port: `8080`.
- Security context: `runAsNonRoot: true`, `runAsUser: 10001`,
  `runAsGroup: 10001`, `readOnlyRootFilesystem: true`.
- Mount a writable `emptyDir` at `/tmp`.
- Use immutable `main-<7-char sha>` image tags for reproducible rollouts.
