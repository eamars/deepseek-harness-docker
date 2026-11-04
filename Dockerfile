# DSH comes from the eamars/deepseek-harness fork at the commit Asuna runs
# (Asuna's tools/dsh-inline/source.json: branch asuna/0.2.2-alpha.3). That
# branch is the npm 0.2.2-alpha.3 release plus commits in the packages named
# by DSH_FORK_PACKAGES, so the image installs the release and replaces those
# packages' lib with builds from the fork commit. These pins live here only;
# compose passes an override when one is set in the environment.
ARG DSH_VERSION=0.2.2-alpha.3
ARG DSH_FORK_REPOSITORY=https://github.com/eamars/deepseek-harness.git
ARG DSH_FORK_COMMIT=4a4f9f1d77532afeb1fd776019d0f463d0b721cc
ARG DSH_UPSTREAM_REPOSITORY=https://github.com/deepseek-ai/deepseek-harness.git
ARG DSH_FORK_PACKAGES="client/ui-chat client/ui-renderer compaction/compaction-basic"

FROM node:24-trixie-slim AS dsh-fork

ARG DSH_VERSION
ARG DSH_FORK_REPOSITORY
ARG DSH_FORK_COMMIT
ARG DSH_UPSTREAM_REPOSITORY
ARG DSH_FORK_PACKAGES

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

# Every package the fork changes relative to the release tag must be replaced
# below; otherwise the image would quietly run the release copy of it.
RUN git fetch --quiet --depth 1 "${DSH_UPSTREAM_REPOSITORY}" "refs/tags/dsh-v${DSH_VERSION}" \
 && changed="$(git diff --name-only FETCH_HEAD HEAD -- packages | cut -d/ -f2-3 | sort -u)" \
 && echo "Fork packages changed since dsh-v${DSH_VERSION}:" ${changed} \
 && for dir in ${changed}; do \
      case " ${DSH_FORK_PACKAGES} " in \
        *" ${dir} "*) ;; \
        *) echo "packages/${dir} differs from dsh-v${DSH_VERSION} but is not in DSH_FORK_PACKAGES" >&2; exit 1 ;; \
      esac; \
    done

# The same build steps Asuna uses (its tools/build_dsh_inline.mjs): frozen
# dependencies without lifecycle scripts, DSH's own Host library build, the
# client typecheck, then one bundle per client package (they depend on each
# other, so one at a time).
RUN pnpm install --frozen-lockfile --ignore-scripts \
 && pnpm exec tsx scripts/compile-referenced-projects.ts host-libraries \
 && pnpm exec tsc -b packages/client/ui-chat/tsconfig.json --pretty false \
 && pnpm --filter @deepseek-ai/dsh-client-ui-renderer bundle \
 && pnpm --filter @deepseek-ai/dsh-client-ui-chat bundle \
 && for dir in ${DSH_FORK_PACKAGES}; do \
      name="$(node -p "require('./packages/${dir}/package.json').name")" \
      && mkdir -p "/fork-lib/${name}" \
      && cp -r "packages/${dir}/lib/." "/fork-lib/${name}/"; \
    done

# Trixie base so the distro python3 tracks the newest supported minor (3.13)
# for node-gyp native builds and in-container development use.
FROM node:24-trixie-slim

ARG DSH_VERSION
ARG DSH_FORK_REPOSITORY
ARG DSH_FORK_COMMIT
ARG DSH_FORK_PACKAGES
ARG DSH_MARKET_VERSION=1.66.22
ARG PNPM_VERSION=12.4.2

LABEL dsh.version="${DSH_VERSION}" \
      dsh.fork.repository="${DSH_FORK_REPOSITORY}" \
      dsh.fork.commit="${DSH_FORK_COMMIT}" \
      dsh.fork.packages="${DSH_FORK_PACKAGES}"

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

# Replace each fork-changed package's lib wherever npm placed it. Each copy
# must be the release the fork extends, and the fork build must provide every
# top-level entry of the released lib.
COPY --from=dsh-fork /fork-lib /tmp/dsh-fork
RUN set -e; \
    cd /tmp/dsh-fork; \
    for name in @deepseek-ai/*; do \
      dirs="$(find /usr/local/lib/node_modules -type d -path "*/node_modules/${name}")"; \
      test -n "${dirs}" || { echo "${name} is not installed" >&2; exit 1; }; \
      for dir in ${dirs}; do \
        test "$(node -p "require('${dir}/package.json').version")" = "${DSH_VERSION}"; \
        for entry in $(ls "${dir}/lib"); do \
          test -e "/tmp/dsh-fork/${name}/${entry}" || { echo "fork build of ${name} lacks lib/${entry}" >&2; exit 1; }; \
        done; \
        rm -rf "${dir}/lib"; \
        cp -r "/tmp/dsh-fork/${name}" "${dir}/lib"; \
        echo "Replaced ${dir}/lib from the fork"; \
      done; \
    done; \
    cd /; \
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
