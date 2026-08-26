// Google Play Developer API の共通部品（Node 24 / 依存なし）。
//
// 認証: サービスアカウントの JSON 鍵で JWT(RS256) を作り、OAuth2 のトークンに交換する。
//       秘密鍵は署名にしか使わず、ログには一切出さない（tools/asc/ と同じ作法）。
//
// なぜ自作か: 公式の googleapis パッケージを入れると依存が増える。このリポジトリの
//   ASC 側ツールも依存なしで JWT を組んでいるので、同じ作法に揃える。
//
// 使い方（他のスクリプトから import する）:
//   import { getToken, api } from './play_api.mjs';
import fs from 'node:fs';
import crypto from 'node:crypto';

const SCOPE = 'https://www.googleapis.com/auth/androidpublisher';
const TOKEN_URL = 'https://oauth2.googleapis.com/token';
export const BASE = 'https://androidpublisher.googleapis.com';

const b64url = (b) =>
  Buffer.from(b).toString('base64').replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_');

/** サービスアカウント JSON を読む。パスは環境変数 or 引数。 */
export function loadServiceAccount(path) {
  const raw = fs.readFileSync(path, 'utf8');
  const sa = JSON.parse(raw);
  for (const k of ['client_email', 'private_key']) {
    if (!sa[k]) throw new Error(`サービスアカウントJSONに ${k} がありません`);
  }
  return sa;
}

/** OAuth2 のアクセストークンを取る（JWT Bearer フロー）。 */
export async function getToken(sa) {
  const now = Math.floor(Date.now() / 1000);
  const header = b64url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
  const claim = b64url(JSON.stringify({
    iss: sa.client_email,
    scope: SCOPE,
    aud: TOKEN_URL,
    iat: now,
    exp: now + 3600,
  }));
  const input = header + '.' + claim;
  const sig = crypto.sign('RSA-SHA256', Buffer.from(input), sa.private_key);
  const assertion = input + '.' + b64url(sig);

  const res = await fetch(TOKEN_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion,
    }),
  });
  const j = await res.json().catch(() => null);
  if (!res.ok || !j?.access_token) {
    throw new Error(`トークン取得に失敗 HTTP ${res.status}: ${JSON.stringify(j)?.slice(0, 300)}`);
  }
  return j.access_token;
}

/** API を叩く。body が Buffer ならそのまま送る（AAB アップロード用）。 */
export async function api(token, method, path, { body, contentType, query } = {}) {
  const qs = query ? '?' + new URLSearchParams(query) : '';
  const headers = { Authorization: 'Bearer ' + token };
  let payload;
  if (body instanceof Buffer || body instanceof Uint8Array) {
    headers['Content-Type'] = contentType || 'application/octet-stream';
    payload = body;
  } else if (body !== undefined) {
    headers['Content-Type'] = 'application/json';
    payload = JSON.stringify(body);
  }
  const res = await fetch(BASE + path + qs, { method, headers, body: payload });
  const text = await res.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { /* 非JSON */ }
  return { status: res.status, json, text };
}

/** 失敗を分かりやすく落とす。 */
export function must(res, what) {
  if (res.status >= 200 && res.status < 300) return res.json;
  const msg = res.json?.error?.message || res.text?.slice(0, 400) || '';
  throw new Error(`${what} に失敗 HTTP ${res.status}: ${msg}`);
}
