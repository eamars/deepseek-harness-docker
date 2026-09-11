#!/usr/bin/env bash
set -Eeuo pipefail

# DSH 0.1.5 renamed the required dsh-persona config key from `text` to
# `prefix`. Agent presets live in the persistent DSH_HOME volume, so an image
# rebuild alone cannot migrate presets created by an older DSH release. Patch
# only persona blocks that still have the old key; all other user config and
# session data stays untouched.
repair_legacy_persona_presets() {
  node <<'NODE'
const fs = require("node:fs");
const path = require("node:path");

const root = path.join(process.env.DSH_HOME, ".agent-presets");
if (!fs.existsSync(root)) process.exit(0);

for (const preset of fs.readdirSync(root, { withFileTypes: true })) {
  if (!preset.isDirectory()) continue;
  const file = path.join(root, preset.name, "agent.cordis.yml");
  if (!fs.existsSync(file)) continue;

  const source = fs.readFileSync(file, "utf8");
  const blockPattern = /(- id: persona\r?\n\s+name:\s+['"]@deepseek-ai\/dsh-persona['"]\s*\r?\n\s+config:\s*\r?\n)([\s\S]*?)(?=\r?\n- id:|\s*$)/;
  const block = source.match(blockPattern);
  if (block === null || /^\s{4}prefix\s*:/m.test(block[2]) || !/^\s{4}text\s*:\s*\|-?/m.test(block[2])) {
    continue;
  }

  const migratedBlock = block[0].replace(/^(\s{4})text(\s*:\s*\|-?)/m, "$1prefix$2");
  fs.writeFileSync(file, source.replace(block[0], migratedBlock));
  process.stdout.write(`Migrated legacy persona config: ${preset.name}\n`);
}
NODE
}

repair_legacy_persona_presets

profile_dir="${DSH_HOME}/profiles/web"
market_manifest="${profile_dir}/node_modules/dshmarket/package.json"
installed_market_version=""

if [[ -f "${market_manifest}" ]]; then
  installed_market_version="$(
    node -e '
      const fs = require("node:fs");
      try {
        const packageJson = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
        process.stdout.write(packageJson.version ?? "");
      } catch {
        process.exitCode = 1;
      }
    ' "${market_manifest}" 2>/dev/null || true
  )"
fi

if [[ "${installed_market_version}" != "${DSH_MARKET_VERSION}" ]]; then
  echo "Installing dsh-market ${DSH_MARKET_VERSION} into the web profile..."
  dsh plugin --profile web add --save-exact "dshmarket@${DSH_MARKET_VERSION}"
fi

if [[ ! -f "${market_manifest}" ]]; then
  echo "dsh-market was not installed into ${profile_dir}" >&2
  exit 1
fi

exec dsh web --patch /opt/dsh/web.cordis.yml "$@"
