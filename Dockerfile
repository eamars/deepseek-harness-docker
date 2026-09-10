# Trixie base so the distro python3 tracks the newest supported minor (3.13)
# for node-gyp native builds and in-container development use.
FROM node:24-trixie-slim

ARG DSH_VERSION=0.1.2-rc.1
ARG DSH_MARKET_VERSION=1.45.1
ARG PNPM_VERSION=10.34.5

ENV NODE_ENV=production \
    DSH_HOME=/var/lib/dsh \
    HOME=/home/dsh \
    npm_config_python=/usr/bin/python3 \
    DSH_MARKET_VERSION=${DSH_MARKET_VERSION}

RUN apt-get update \
 && apt-get install --yes --no-install-recommends \
      bash \
      build-essential \
      ca-certificates \
      curl \
      dnsutils \
      file \
      git \
      iproute2 \
      iputils-ping \
      jq \
      less \
      netcat-openbsd \
      openssh-client \
      pkg-config \
      procps \
      python3 \
      python3-dev \
      python3-pip \
      python3-venv \
      ripgrep \
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

# The DSH web client intentionally keeps settings/credentials on the browser
# loopback origin. This deployment already fronts DSH with Caddy, which rewrites
# the upstream Host/Origin to localhost for the server-side /api fence. To keep
# Settings > Models usable from the LAN HTTPS URL on current DSH versions, also
# tell the browser-side connection that it is on a loopback authority. The LAN
# firewall remains the deployment access boundary, matching this repo's existing
# all-interface design.
RUN node -e '\
  const fs = require("node:fs");\
  const path = require.resolve("@deepseek-ai/dsh-client-connection/client", {\
    paths: ["/usr/local/lib/node_modules/@deepseek-ai/dsh"]\
  });\
  const file = fs.readFileSync(path, "utf8");\
  const pattern = /isLoopback:\s*(?:transport\?\.ownsHost === true \|\| )?pageLocation === void 0 \|\| isLoopbackHostname\(pageLocation\.hostname\),/;\
  if (!pattern.test(file)) {\
    throw new Error("dsh client-connection loopback expression not found; update the Dockerfile patch");\
  }\
  fs.writeFileSync(path, file.replace(pattern, "isLoopback: true,"));\
'

# The DSH plugin manager delegates profile installs to pnpm. Pin the major
# version because pnpm 10's build-script approval behavior is part of the
# plugin install contract.
RUN npm install --global --no-audit --no-fund "pnpm@${PNPM_VERSION}"

RUN mkdir --parents /var/lib/dsh /workspace /opt/dsh \
 && chown --recursive dsh:dsh /var/lib/dsh /workspace /opt/dsh /home/dsh

COPY --chown=dsh:dsh web.cordis.yml /opt/dsh/web.cordis.yml
COPY --chown=dsh:dsh dsh-entrypoint.sh /opt/dsh/dsh-entrypoint.sh

USER dsh
WORKDIR /workspace

EXPOSE 3080

ENTRYPOINT ["bash", "/opt/dsh/dsh-entrypoint.sh"]
