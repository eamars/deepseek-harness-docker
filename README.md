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

The image installs pnpm and bootstraps `dshmarket` into the `web` profile on
first start. The bootstrap is idempotent, so an existing `dsh-home` volume is
left intact and market updates made from the Web UI are preserved. The market
package and pnpm versions can be overridden in `.env` with
`DSH_MARKET_VERSION` and `PNPM_VERSION`.

The Web overlay enables the built-in `dsh-schedule` module. The optional
`dsh-time-context` module is intentionally not mounted, so new cycles do not
receive an extra time-context prompt. Schedule reminders remain enabled and
persist in the session event log; they do not depend on time-context.

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
behind the browser-side loopback check. This image patches the served
`dsh-client-connection` client bundle during `docker build` to treat the
browser as loopback (`isLoopback: true`). Combined with Caddy's existing
`header_up Host localhost:3080` / `Origin http://localhost:3080`, both the
server-side and client-side loopback checks pass, so **Settings → Models**
works from the LAN HTTPS URL again without pinning an older DSH version or
using an SSH tunnel.

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
docker compose build --no-cache --progress=plain
docker compose up -d
```

## Stop and upgrade

```powershell
docker compose down
docker compose up --build -d
```

The named volumes are preserved by `docker compose down`. Do not add `-v`
unless you intend to remove the persisted Harness settings, credentials,
sessions, workspace, and local certificate authority.

## Upstream references

- <https://github.com/deepseek-ai/deepseek-harness>
- <https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/user/guide/index.md>
- <https://github.com/deepseek-ai/deepseek-harness/blob/master/apps/cli/reference/README.md>
- <https://github.com/dsh-market/dsh-market>
- <https://caddyserver.com/docs/caddyfile/directives/tls>
