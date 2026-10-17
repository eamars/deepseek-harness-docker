# DSH comes from the eamars/deepseek-harness fork at the commit Asuna runs
# (branch asuna/0.2.1-rc.1). That branch is the npm 0.2.1-rc.1 release
# plus commits in ui-chat and ui-renderer only, so the image installs the
# release and replaces those two packages with builds from the fork commit.
ARG DSH_VERSION=0.2.1-rc.1
ARG DSH_FORK_REPOSITORY=https://github.com/eamars/deepseek-harness.git
ARG DSH_FORK_COMMIT=d67d7cf4fd17d2810efd7b514fec9e765326da75

FROM node:24-trixie-slim AS dsh-fork

ARG DSH_VERSION
ARG DSH_FORK_REPOSITORY
ARG DSH_FORK_COMMIT

ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0

RUN apt-get update \
 && apt-get install --yes --no-install-recommends ca-certificates git \
 && rm -rf /var/lib/apt/lists/* \
 && corepack enable

WORKDIR /src

# Fetch the pinned commit itself, so a moved branch tip cannot change the build.
# The fork must extend the same DSH release that npm installs below.
RUN git init --quiet \
 && git remote add origin "${DSH_FORK_REPOSITORY}" \
 && git fetch --quiet --depth 1 origin "${DSH_FORK_COMMIT}" \
 && git checkout --quiet FETCH_HEAD \
 && test "$(node -p 'require("./apps/cli/package.json").version')" = "${DSH_VERSION}"

# The same build steps Asuna uses for these packages: frozen dependencies
# without lifecycle scripts, Host contributions before the client typecheck,
# then one bundle per package (they depend on each other).
RUN pnpm install --frozen-lockfile --ignore-scripts \
 && pnpm exec tsc -b tsconfig.host.json --pretty false \
 && pnpm exec tsdown --config-loader native --env.DSH_BUILD_FACE host \
 && pnpm exec tsc -b packages/client/ui-chat/tsconfig.json --pretty false \
 && pnpm --filter @deepseek-ai/dsh-client-ui-renderer bundle \
 && pnpm --filter @deepseek-ai/dsh-client-ui-chat bundle

# Trixie base so the distro python3 tracks the newest supported minor (3.13)
# for node-gyp native builds and in-container development use.
FROM node:24-trixie-slim

ARG DSH_VERSION
ARG DSH_FORK_REPOSITORY
ARG DSH_FORK_COMMIT
ARG DSH_MARKET_VERSION=1.66.22
ARG PNPM_VERSION=12.4.2

LABEL dsh.version="${DSH_VERSION}" \
      dsh.fork.repository="${DSH_FORK_REPOSITORY}" \
      dsh.fork.commit="${DSH_FORK_COMMIT}"

ENV NODE_ENV=production \
    DSH_HOME=/var/lib/dsh \
    HOME=/home/dsh \
    npm_config_python=/usr/bin/python3 \
    DSH_MARKET_VERSION=${DSH_MARKET_VERSION} \
    CCACHE_DIR=/var/cache/ccache

RUN dpkg --add-architecture arm64 \
 && apt-get update \
 && apt-get install --yes --no-install-recommends \
      bash \
      build-essential \
      ca-certificates \
      can-utils \
      ccache \
      cmake \
      curl \
      dnsutils \
      file \
      git \
      gcc-aarch64-linux-gnu \
      g++-aarch64-linux-gnu \
      iproute2 \
      iputils-ping \
      jq \
      less \
      libc6-dev-arm64-cross \
      libgmock-dev:amd64 \
      libgtest-dev:amd64 \
      libspdlog-dev:amd64 \
      libspdlog-dev:arm64 \
      libyaml-cpp-dev:amd64 \
      libyaml-cpp-dev:arm64 \
      netcat-openbsd \
      ninja-build \
      openssh-client \
      pkg-config \
      procps \
      python3 \
      python3-dev \
      python3-pip \
      python3-venv \
      ripgrep \
      rsync \
      tree \
      unzip \
      wget \
      zip \
 && rm -rf /var/lib/apt/lists/*

RUN groupadd --gid 10001 dsh \
 && useradd --uid 10001 --gid 10001 --create-home dsh

# The Harness package includes native dependencies. Keep their reviewed
# install scripts enabled for this global npm install and show their output in
# the build log so native compilation failures remain diagnosable.
RUN npm install --global --no-audit --no-fund --foreground-scripts \
      --allow-scripts=@deepseek-ai/dsh-subprocess-local,koffi,node-pty,@google/genai,protobufjs \
      "@deepseek-ai/dsh@${DSH_VERSION}"

# Replace the two fork-changed packages wherever npm placed them. Each copy
# must be the release the fork extends.
COPY --from=dsh-fork /src/packages/client/ui-chat/lib /tmp/dsh-fork/ui-chat
COPY --from=dsh-fork /src/packages/client/ui-renderer/lib /tmp/dsh-fork/ui-renderer
RUN set -e; \
    for name in ui-chat ui-renderer; do \
      dirs="$(find /usr/local/lib/node_modules -type d -path "*/@deepseek-ai/dsh-client-${name}")"; \
      test -n "${dirs}"; \
      for dir in ${dirs}; do \
        test "$(node -p "require('${dir}/package.json').version")" = "${DSH_VERSION}"; \
        rm -rf "${dir}/lib"; \
        cp -r "/tmp/dsh-fork/${name}" "${dir}/lib"; \
        test -f "${dir}/lib/index.js" && test -f "${dir}/lib/client.js"; \
      done; \
    done; \
    rm -rf /tmp/dsh-fork

# This LAN deployment removes DSH's browser token/cookie gate and reports a
# loopback authority to the browser client; see dsh-lan-patch.mjs.
COPY dsh-lan-patch.mjs /tmp/dsh-lan-patch.mjs
RUN node /tmp/dsh-lan-patch.mjs && rm /tmp/dsh-lan-patch.mjs

# The DSH plugin manager delegates profile installs to pnpm. Pin the tested
# version because its plugin-install behavior is part of the runtime contract.
RUN npm install --global --no-audit --no-fund --allow-scripts=pnpm "pnpm@${PNPM_VERSION}"

RUN mkdir --parents /var/cache/ccache /var/lib/dsh /workspace /opt/dsh \
 && chown --recursive dsh:dsh /var/cache/ccache /var/lib/dsh /workspace /opt/dsh /home/dsh

COPY --chown=dsh:dsh dsh-entrypoint.sh /opt/dsh/dsh-entrypoint.sh

USER dsh
WORKDIR /workspace

EXPOSE 3080

ENTRYPOINT ["bash", "/opt/dsh/dsh-entrypoint.sh"]
