// LAN access without a login token. This deployment fronts DSH with Caddy,
// which rewrites the upstream Host/Origin to localhost for the server-side /api
// fence; the LAN firewall is the access boundary for this instance.
// - The browser-side connection reports a loopback authority, so DSH's
//   loopback-only settings (Settings > Models) work from the LAN HTTPS URL.
// - Page and RPC authentication accept every request, and the printed URL
//   carries no token.
// Fails the image build when DSH's code no longer matches, so an upgrade
// cannot silently keep or drop the patch.
import fs from 'node:fs';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const paths = ['/usr/local/lib/node_modules/@deepseek-ai/dsh'];

const clientPath = require.resolve('@deepseek-ai/dsh-client-connection/client', { paths });
const client = fs.readFileSync(clientPath, 'utf8');
const loopback = /isLoopback:\s*(?:transport\?\.ownsHost === true \|\| )?pageLocation === void 0 \|\| isLoopbackHostname\(pageLocation\.hostname\),/;
if (!loopback.test(client)) {
  throw new Error('dsh client-connection loopback expression not found; update dsh-lan-patch.mjs');
}
fs.writeFileSync(clientPath, client.replace(loopback, 'isLoopback: true,'));

const serverPath = require.resolve('@deepseek-ai/dsh-client-connection', { paths });
let server = fs.readFileSync(serverPath, 'utf8');
// Replace the body of the first class method of that name (the browser
// authenticator; later ones delegate to it), whatever parameters DSH gives it.
const replaceMethod = (name, body) => {
  const found = new RegExp('\\n\\t' + name + '\\(([A-Za-z_$][\\w$]*)[^)\\n]*\\) \\{').exec(server);
  const end = found ? server.indexOf('\n\t}', found.index) : -1;
  if (!found || end < 0) {
    throw new Error('dsh client-connection ' + name + ' method not found; update dsh-lan-patch.mjs');
  }
  server = server.slice(0, found.index) + found[0] + '\n\t\t' + body(found[1]) + '\n\t}' + server.slice(end + 3);
};
replaceMethod('authenticatedUrl', url => 'const clean = new URL(' + url + '); clean.search = ""; clean.hash = ""; return clean.href;');
replaceMethod('authorizeIndex', () => 'return true;');
replaceMethod('isAuthenticated', () => 'return true;');
fs.writeFileSync(serverPath, server);
