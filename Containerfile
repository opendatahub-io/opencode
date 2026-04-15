# syntax=docker/dockerfile:1.7
#
# opencode — UBI 9 multi-stage build
#
# Build examples:
#   podman build -t opencode:latest -f Containerfile .
#   podman build --build-arg BUN_VERSION=1.3.11 --build-arg NODE_GYP_VERSION=11.2.0 -f Containerfile .

ARG UBI_IMAGE="registry.access.redhat.com/ubi9/ubi"
ARG UBI_MINIMAL_IMAGE="registry.access.redhat.com/ubi9/ubi-minimal"

# ── Stage 1: Build ────────────────────────────────────────────
FROM ${UBI_IMAGE} AS builder

ARG BUN_VERSION=1.3.11
ARG NODE_VERSION=22.16.0
ARG NODE_GYP_VERSION=11.2.0
ARG RIPGREP_VERSION=14.1.1

ARG NODE_SHA256_X64=f4cb75bb036f0d0eddf6b79d9596df1aaab9ddccd6a20bf489be5abe9467e84e
ARG NODE_SHA256_ARM64=eab80cb88f8fda1e65f5e8d0420c9809bdb320b03fd34976ab7161b6e703b910
ARG BUN_SHA256_X64=8611ba935af886f05a6f38740a15160326c15e5d5d07adef966130b4493607ed
ARG BUN_SHA256_ARM64=d13944da12a53ecc74bf6a720bd1d04c4555c038dfe422365356a7be47691fdf
ARG RIPGREP_SHA256_X64=4cf9f2741e6c465ffdb7c26f38056a59e2a2544b51f7cc128ef28337eeae4d8e
ARG RIPGREP_SHA256_ARM64=c827481c4ff4ea10c9dc7a4022c8de5db34a5737cb74484d62eb94a95841ab2f

USER 0

ENV BUN_INSTALL=/opt/app-root/.bun
ENV NPM_CONFIG_PREFIX=/opt/app-root/.npm-global
ENV PATH=/opt/app-root/.npm-global/bin:/opt/app-root/.bun/bin:${PATH}

RUN dnf install -y --nodocs --disablerepo='*' --enablerepo='ubi-*' \
      gcc g++ git make pkg-config python3 unzip xz && \
    dnf clean all

RUN set -eux; \
    arch=$(uname -m); \
    case "$arch" in \
      x86_64)  node_arch=x64;   node_sha256="${NODE_SHA256_X64}" ;; \
      aarch64) node_arch=arm64; node_sha256="${NODE_SHA256_ARM64}" ;; \
      *) echo "unsupported arch: $arch" && exit 1 ;; \
    esac; \
    curl -fsSLo /tmp/node.tar.xz \
      "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${node_arch}.tar.xz"; \
    echo "${node_sha256}  /tmp/node.tar.xz" | sha256sum -c -; \
    tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1; \
    rm /tmp/node.tar.xz

RUN set -eux; \
    arch=$(uname -m); \
    case "$arch" in \
      x86_64)  bun_arch=x64;      bun_sha256="${BUN_SHA256_X64}" ;; \
      aarch64) bun_arch=aarch64;   bun_sha256="${BUN_SHA256_ARM64}" ;; \
      *) echo "unsupported arch: $arch" && exit 1 ;; \
    esac; \
    curl -fsSLo /tmp/bun.zip \
      "https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/bun-linux-${bun_arch}.zip"; \
    echo "${bun_sha256}  /tmp/bun.zip" | sha256sum -c -; \
    unzip -qo /tmp/bun.zip -d /tmp; \
    mkdir -p /opt/app-root/.bun/bin; \
    mv "/tmp/bun-linux-${bun_arch}/bun" /opt/app-root/.bun/bin/bun; \
    chmod +x /opt/app-root/.bun/bin/bun; \
    rm -rf /tmp/bun*

RUN set -eux; \
    arch=$(uname -m); \
    case "$arch" in \
      x86_64)  rg_arch=x86_64-unknown-linux-musl;  rg_sha256="${RIPGREP_SHA256_X64}" ;; \
      aarch64) rg_arch=aarch64-unknown-linux-gnu;   rg_sha256="${RIPGREP_SHA256_ARM64}" ;; \
      *) echo "unsupported arch: $arch" && exit 1 ;; \
    esac; \
    curl -fsSLo /tmp/rg.tar.gz \
      "https://github.com/BurntSushi/ripgrep/releases/download/${RIPGREP_VERSION}/ripgrep-${RIPGREP_VERSION}-${rg_arch}.tar.gz"; \
    echo "${rg_sha256}  /tmp/rg.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/rg.tar.gz -C /tmp; \
    mv "/tmp/ripgrep-${RIPGREP_VERSION}-${rg_arch}/rg" /usr/local/bin/rg; \
    chmod +x /usr/local/bin/rg; \
    rm -rf /tmp/rg.tar.gz /tmp/ripgrep-*

WORKDIR /build

RUN mkdir -p /build /opt/app-root/.bun/install/cache /opt/app-root/.npm-global && \
    chown -R 1001:0 /build /opt/app-root/.bun /opt/app-root/.npm-global

COPY --chown=1001:0 bun.lock bunfig.toml package.json turbo.json ./
COPY --chown=1001:0 patches/ patches/
COPY --chown=1001:0 packages/ packages/

USER 1001

ENV HOME=/build
ENV ELECTRON_SKIP_BINARY_DOWNLOAD=1

RUN npm install -g --no-audit --no-fund "node-gyp@${NODE_GYP_VERSION}"

RUN --mount=type=cache,id=opencode-bun-cache,target=/opt/app-root/.bun/install/cache,uid=1001,gid=0,sharing=locked \
    bun install --frozen-lockfile

COPY --chown=1001:0 . .

ARG OPENCODE_CHANNEL=latest
ENV OPENCODE_CHANNEL=${OPENCODE_CHANNEL}

RUN cd packages/opencode && bun run script/build.ts --single

# ── Stage 2: Runtime (UBI 9 minimal) ─────────────────────────
FROM ${UBI_MINIMAL_IMAGE}

LABEL org.opencontainers.image.source="https://github.com/anomalyco/opencode" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.title="OpenCode (UBI 9)" \
      org.opencontainers.image.description="AI-powered development tool"

USER 0

RUN microdnf update -y && \
    microdnf install -y --nodocs \
      ca-certificates \
      diffutils \
      findutils \
      git \
      gzip \
      jq \
      make \
      openssh-clients \
      patch \
      procps-ng \
      python3.12 \
      python3.12-pip \
      shadow-utils \
      tar \
      vim-minimal \
      which && \
    microdnf clean all

RUN useradd -u 1001 -g 0 -d /home/opencode -m opencode && \
    mkdir -p /opt/app-root/bin /opt/app-root/venv \
             /home/opencode/.opencode \
             /home/opencode/.cache/opencode/bin \
             /home/opencode/.config/opencode \
             /home/opencode/.local/share/opencode/log && \
    chown -R 1001:0 /home/opencode /opt/app-root && \
    chmod -R g=u /home/opencode /opt/app-root

ARG UV_VERSION=0.11.6
RUN python3.12 -m venv /opt/app-root/venv && \
    /opt/app-root/venv/bin/pip install --no-cache-dir "uv==${UV_VERSION}" && \
    chown -R 1001:0 /opt/app-root/venv

ARG BUN_RUNTIME_TRANSPILER_CACHE_PATH=0
ENV BUN_RUNTIME_TRANSPILER_CACHE_PATH=${BUN_RUNTIME_TRANSPILER_CACHE_PATH}
ENV HOME=/home/opencode
ENV PATH="/opt/app-root/venv/bin:/opt/app-root/bin:${PATH}"

COPY --from=builder /usr/local/bin/rg /opt/app-root/bin/rg
COPY --from=builder --chown=1001:0 \
     /build/packages/opencode/dist/opencode-linux-*/bin/opencode \
     /opt/app-root/bin/opencode

USER 1001

RUN opencode --version

ENTRYPOINT ["opencode"]
