# ClojureWasm fractal zoom: container image (self-contained, root-context).
#
# cljw comes from the pinned GitHub release tarball of BuddhiLW/ClojureWasm
# (ReleaseSafe, -Dwasm, -Dcpu=baseline), verified against CLJW_SHA256. No Zig,
# no from-source build. The Wasm modules are committed artifacts; see
# DEPLOY.md and PROVENANCE.md. No Node/JDK/frontend build stage either.
#
# .github/workflows/cljw-bump.yml rewrites the two ARG defaults below when a new
# cljw release appears; keep each on its own `ARG NAME=value` line.

# --- Stage 1: fetch + verify the cljw release binary ---
FROM debian:bookworm-slim AS cljw
ARG CLJW_VERSION=v1.15.5
ARG CLJW_SHA256=ff7bf54f867fdf4cee3638462d56ab43a8ca804e1b7e419488af6a981adc419a
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl && rm -rf /var/lib/apt/lists/*
WORKDIR /dl
RUN curl -fsSLo cljw.tar.gz \
      "https://github.com/BuddhiLW/ClojureWasm/releases/download/${CLJW_VERSION}/cljw-linux-x86_64.tar.gz" && \
    echo "${CLJW_SHA256}  cljw.tar.gz" | sha256sum -c - && \
    tar -xzf cljw.tar.gz cljw && \
    install -m 0755 cljw /usr/local/bin/cljw && \
    /usr/local/bin/cljw --version

# --- Stage 2: runtime (cljw + the committed app: server + page + wasm) ---
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates && rm -rf /var/lib/apt/lists/* && \
    groupadd --gid 10001 app && \
    useradd --uid 10001 --gid 10001 --no-create-home --home-dir /tmp \
        --shell /usr/sbin/nologin app
WORKDIR /app
COPY --from=cljw /usr/local/bin/cljw /usr/local/bin/cljw
COPY server.clj index.html kernel.wasm kernel_simd.wasm ./

# Read-only root filesystem: the runtime must mount /tmp writable.
ENV FRACTAL_PORT=8080 \
    FRACTAL_DIR=/app \
    HOME=/tmp \
    TMPDIR=/tmp

USER 10001:10001
EXPOSE 8080
# run-server binds 0.0.0.0:FRACTAL_PORT.
CMD ["cljw", "server.clj"]
