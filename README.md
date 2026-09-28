# DeepSeek Harness Docker deployment

This directory runs the official DeepSeek Harness Web UI in Docker with the
community dsh-market plugin preconfigured. The
container stores Harness settings, credentials, profiles, and sessions in the
named `dsh-home` volume. The workspace is mounted at `/workspace` and defaults
to the persistent `dsh-workspace` volume.

## Configuration

The workspace source is controlled by the optional `DSH_WORKSPACE` environment
variable. Set it in a `.env` file next to `compose.yaml`, or in the stack
environment in Portainer:

```env
DSH_WORKSPACE=/home/eamars/dsh
```

When `DSH_WORKSPACE` is unset, Docker Compose uses the named `dsh-workspace`
volume. The DSH application data and configuration remain in the separate
`dsh-home` volume mounted at `/var/lib/dsh`.

The image installs pnpm and ensures the pinned `dshmarket` version is installed
in the `web` profile on each start. Existing settings and sessions are retained,
but a different market version installed from the Web UI is replaced by the
image's pin at the next restart. Override `DSH_MARKET_VERSION` and `PNPM_VERSION`
in `.env` (or the Portainer stack environment) and rebuild to change these pins.

The Web overlay enables the built-in `dsh-schedule` module. The optional
`dsh-time-context` module is intentionally not mounted, so new cycles do not
receive an extra time-context prompt. Schedule reminders remain enabled and
persist in the session event log; they do not depend on time-context.

## Raspberry Pi 5 cross compilation

The Harness image includes the AArch64 cross compiler, CMake, Ninja, ccache,
and the `yaml-cpp` and `spdlog` development packages for both amd64 build tools
and arm64 target binaries. The Compose stack keeps ccache data in the
`ccache-cache` volume across container replacements.

The service runs as `linux/amd64` to match the compiler host and native
development packages; deploy it on an amd64 Linux Docker host for native
performance. An arm64 Docker host needs amd64 emulation enabled.

Open a shell in the service:

```sh
docker compose exec deepseek-harness bash
```

From that shell, configure a CMake project for Raspberry Pi 5's 64-bit Linux
userspace and build it with the cross compiler:

```sh
cmake -S /workspace/your-project -B /workspace/your-project/build/rpi5 -G Ninja \
  -DCMAKE_SYSTEM_NAME=Linux \
  -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
  -DCMAKE_C_COMPILER=aarch64-linux-gnu-gcc \
  -DCMAKE_CXX_COMPILER=aarch64-linux-gnu-g++ \
  -DCMAKE_C_COMPILER_LAUNCHER=ccache \
  -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
cmake --build /workspace/your-project/build/rpi5 --parallel
file /workspace/your-project/build/rpi5/your-binary
```

Build and deploy the updated image with `docker compose build deepseek-harness`
followed by `docker compose up -d --no-build --pull never`. The `file` command
should report an ARM aarch64 executable. This toolchain targets 64-bit Raspberry
Pi OS/Linux userspace; it does not execute the result on the Docker host.

## Portainer deployment

Deploy this directory or its Git repository as a stack on a Linux Docker
server. The build context must contain `compose.yaml`, `Dockerfile`,
`dsh-entrypoint.sh`, and `web.cordis.yml`. The Caddy configuration is embedded
in `compose.yaml`, and
the workspace uses a named volume by default, so no additional files or host
directories are required. Set `DSH_WORKSPACE` when a host directory should be
used instead.

Both services use host networking. Harness discovers the Docker server's LAN
interfaces through its built-in all-interface runtime, and Caddy derives the
certificate address from the destination of each TLS connection. No LAN IP
address or hostname is configured in the stack.

## First run

In PowerShell:

```powershell
Copy-Item .env.example .env
docker compose up -d
docker compose logs -f caddy
```

If `DEEPSEEK_API_KEY` is set in `.env`, the container inherits it
automatically. It can also be entered later in the Web UI.

After the first healthy start, open **Settings → Plugin Market** to browse and
install community plugins. The first start needs registry access so the image
entrypoint can install the pinned market package into the persistent profile.

## Session-local scheduling

The model can use `schedule_create`, `schedule_list`, and `schedule_delete` to
create reminders. Schedule supports positive `after_seconds` delays, explicit
absolute `at` targets, and fixed-rate `every_seconds` intervals of at least five
minutes. Absolute local times must include an explicit `UTC` or IANA time zone.
The optional time-context plugin can help interpret browser-local natural
language, but it is disabled in this deployment and never supplies a persistent
default zone.

Reminders belong to their original Harness Session and persist with the
session event log in `dsh-home`. Delivery is session-local: the Session must
be live for an on-time follow-up. If the container or Session is cold, the
reminder remains persisted and is handled when that Session is resumed. This
module is not a general Cron runner and does not send operating-system, email,
SMS, or other external notifications. Recurring reminders are fixed intervals,
not calendar or Cron expressions.

## LAN access

The stack terminates HTTPS with Caddy and proxies to Harness over host
loopback. The Caddy configuration is embedded in `compose.yaml`, and the
Harness workspace uses a Docker-managed volume by default. No companion
Caddyfile or host workspace-directory setup is required unless `DSH_WORKSPACE`
is set. Use:

```text
https://DOCKER-SERVER-IP/
```

Standard HTTP redirects automatically:

```text
http://DOCKER-SERVER-IP/
```

Ports 80, 443, and 3080 must be available on the Docker server. Port 3080 is
the Harness listener used by the local Caddy reverse proxy.

The service uses `pull_policy: build`, so Compose rebuilds the local image each
time the stack is started or refreshed.

## Settings → Models over LAN

Upstream DSH `0.1.2-rc.1` moved settings, credentials, and model discovery
behind loopback checks; DSH `0.1.7-rc.2` also requires a browser token/cookie
for page and RPC access. This image patches the served
`dsh-client-connection` bundle during `docker build`: the browser reports
loopback (`isLoopback: true`), and the server's page/RPC authentication methods
are replaced with the LAN deployment's unauthenticated policy. The patch is
checked against the pinned package's method signatures and fails the build if
upstream changes them. Combined with Caddy's existing `header_up Host
localhost:3080` / `Origin http://localhost:3080`, the server-side Host/Origin
trust check passes and **Settings → Models** works from the LAN HTTPS URL
without an SSH tunnel.

This matches the existing trust posture of this deployment: the LAN firewall
is the access boundary. If you prefer upstream's stricter loopback-only
behavior, remove the client-patch block from `Dockerfile`; you would then need
to use `http://localhost:3080/` on the Docker host or an SSH tunnel for
Settings → Models.

## Model server and API key selection

Open **Settings → Models** from the LAN HTTPS URL. To point the native DeepSeek provider at another endpoint:

1. Open the DeepSeek provider card.
2. Enter the API key.
3. Expand **Custom settings**, set the base URL, and edit the model list.
4. Apply the changes, then select the model in the conversation model picker.

For vLLM, Ollama, LM Studio, or another OpenAI-compatible server, choose
**Add a custom provider** and enter:

- A permanent lowercase provider ID.
- The server's OpenAI-compatible base URL, normally ending in `/v1`.
- The `openai-completions` API protocol.
- The API key and at least one model, or use **Fetch available models**.

Use `http://localhost:PORT/v1` when the model server listens on the same Linux
Docker host. A model server running in another container must publish its API
port on that host. For a model server elsewhere on the LAN, enter that
server's reachable hostname or address instead.

The OpenAI-compatible adapter expects a non-empty key even when the local
server ignores authentication; a placeholder value is sufficient in that
case. Provider settings and UI-entered credentials persist in the `dsh-home`
volume. An inherited `DEEPSEEK_API_KEY` has operator precedence and is
read-only in the UI, so leave that environment value empty when the Models
page should own the official DeepSeek credential.

### Vision models

DSH only offers image attachment for models that explicitly declare image
input. OpenAI-compatible `/v1/models` discovery does not provide all of DSH's
per-model capability and request-compatibility fields. For each Qwen3.8
Flash-Next FreeToken vision model, keep a distinct model ID and set
`input: [text, image]`, `contextWindow: 262144`, reasoning efforts `low`,
`medium`, and `xhigh`, and `compat.supportsDeveloperRole: false`. Keep the
provider's `defaultInput: [text]` when text-only models share that provider.
These model fields persist in `dsh-home`; do not replace the provider's model
array when adding a vision entry.

### Local certificate

Caddy uses its internal certificate authority because private LAN addresses
cannot use a publicly trusted certificate. Install its root certificate once
on each browser client. On a Windows client, run PowerShell:

```powershell
$server = Read-Host 'Docker server IP address'
Invoke-WebRequest -Uri "http://$server/caddy-local-root.crt" -OutFile .\caddy-local-root.crt
Import-Certificate -FilePath .\caddy-local-root.crt -CertStoreLocation Cert:\CurrentUser\Root
```

Restart the browser after importing the certificate. Firefox installations
that use their own certificate store require importing the same file through
Firefox settings. Caddy's certificate storage is persisted in the
`caddy-data` volume.

For a clean rebuild with detailed build output:

```powershell
docker compose --progress plain build --no-cache
if ($LASTEXITCODE -eq 0) { docker compose up -d --no-build --pull never }
```

## Stop and upgrade

Build before replacing the running containers, so a failed build does not take
the existing application offline:

```powershell
docker compose build
if ($LASTEXITCODE -eq 0) { docker compose up -d --no-build --pull never }
```

Back up `dsh-home` before an upgrade: the entrypoint may migrate persistent
presets and install a new market version. Stop the stack separately with
`docker compose down` when needed.

The named volumes are preserved by `docker compose down`. Do not add `-v`
unless you intend to remove the persisted Harness settings, credentials,
sessions, workspace, and local certificate authority.

## Health checks and failed builds

Keep `init: true` on both services. Caddy's BusyBox HTTPS health check can leave
an orphaned `ssl_client` helper; Docker's init process reaps it. Without init,
repeated checks can accumulate zombie processes that retain seccomp/BPF kernel
resources. This can eventually break unrelated container execution and builds,
even while the web application still answers requests.

If both containers become unhealthy and `docker exec` reports
`error loading seccomp filter into kernel` / `errno 524`, inspect the health
logs and process tree before changing application dependencies:

```sh
docker inspect --format '{{json .State.Health}}' deepseek-harness-https
docker top deepseek-harness-https -eo pid,ppid,stat,comm
```

For this specific failure, update the stack to include Caddy's `init: true`
and recreate only Caddy using its existing local image:

```sh
docker compose up -d --no-deps --no-build --pull never --force-recreate caddy
```

Run this with the original Compose project name and environment (including
`--env-file stack.env` for a Portainer-generated environment file, if using
the CLI). Recreating Caddy briefly interrupts HTTPS but preserves its named
certificate volumes. Confirm that `docker exec deepseek-harness /bin/true`
works again, then retry the build. A restart alone releases the accumulated
resources but does not enable init; recreating with the fixed configuration
prevents recurrence. Do not disable seccomp to hide this failure.

## Upstream references

- <https://github.com/deepseek-ai/deepseek-harness>
- <https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/user/guide/index.md>
- <https://github.com/deepseek-ai/deepseek-harness/blob/master/apps/cli/reference/README.md>
- <https://github.com/dsh-market/dsh-market>
- <https://caddyserver.com/docs/caddyfile/directives/tls>
