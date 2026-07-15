// App Store Connect API helper (Node 24, built-in crypto + fetch, no deps)
// Usage:
//   node asc_api.mjs <p8Path> <keyId> <issuerId> <command> [args...]
// Commands:
//   apps                         -> list all apps (id, bundleId, name)
//   raw GET <path>               -> GET an arbitrary ASC API path, print JSON
// JWT is ES256 signed locally; the private key is never printed.
import fs from 'node:fs';
import crypto from 'node:crypto';

const [,, P8_PATH, KEY_ID, ISSUER_ID, CMD, ...rest] = process.argv;
if (!P8_PATH || !KEY_ID || !ISSUER_ID || !CMD) {
  console.error('args: <p8Path> <keyId> <issuerId> <command> [...]');
  process.exit(2);
}

const b64url = (buf) =>
  Buffer.from(buf).toString('base64').replace(/=+$/,'').replace(/\+/g,'-').replace(/\//g,'_');

function makeJWT() {
  const pem = fs.readFileSync(P8_PATH, 'utf8');
  const header = { alg: 'ES256', kid: KEY_ID, typ: 'JWT' };
  const now = Math.floor(Date.now() / 1000);
  const payload = { iss: ISSUER_ID, iat: now, exp: now + 600, aud: 'appstoreconnect-v1' };
  const signingInput = b64url(JSON.stringify(header)) + '.' + b64url(JSON.stringify(payload));
  const signature = crypto.sign('SHA256', Buffer.from(signingInput), { key: pem, dsaEncoding: 'ieee-p1363' });
  return signingInput + '.' + b64url(signature);
}

const BASE = 'https://api.appstoreconnect.apple.com';
async function api(method, path, body) {
  const jwt = makeJWT();
  const res = await fetch(BASE + path, {
    method,
    headers: {
      Authorization: 'Bearer ' + jwt,
      'Content-Type': 'application/json',
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { /* non-json */ }
  return { status: res.status, json, text };
}

(async () => {
  if (CMD === 'apps') {
    const r = await api('GET', '/v1/apps?limit=200');
    console.log('STATUS', r.status);
    if (r.json && r.json.data) {
      for (const a of r.json.data) {
        console.log(`- id=${a.id}  bundleId=${a.attributes.bundleId}  name=${JSON.stringify(a.attributes.name)}  primaryLocale=${a.attributes.primaryLocale}  sku=${a.attributes.sku}`);
      }
    } else {
      console.log((r.text || '').slice(0, 800));
    }
  } else if (CMD === 'raw') {
    const method = rest[0];
    const path = rest[1];
    const r = await api(method, path);
    console.log('STATUS', r.status);
    console.log(JSON.stringify(r.json ?? r.text, null, 2).slice(0, 4000));
  } else {
    console.error('unknown command', CMD);
    process.exit(2);
  }
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
