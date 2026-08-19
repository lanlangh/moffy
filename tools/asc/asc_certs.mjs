// App Store Connect: 署名証明書の一覧と失効。
//
// なぜ要るか（2026-08-19）:
//   iOS ビルドは自動プロビジョニング（`-allowProvisioningUpdates`）で署名しており、
//   **ビルドのたびに Apple 側へ新しい開発証明書を作る**。Apple はアカウントごとの
//   証明書数に上限を設けているため、CI を回し続けると枠が尽き、ビルドが
//     "Choose a certificate to revoke. Your account has reached the maximum
//      number of certificates."
//   で失敗する（build 33 で実際に発生）。古い開発証明書を失効させて枠を空ける。
//
// 安全装置:
//   * 既定は **list（読むだけ）**。失効は mode=revoke を明示したときだけ。
//   * 失効できるのは **DEVELOPMENT 系のみ**。DISTRIBUTION（ストア提出用）は
//     コード上で弾く。誤って消すとストアに出せなくなるため。
//   * **最新の1本は必ず残す**（keep）。全部消すと進行中のビルドが即死する。
//
// Usage:
//   node asc_certs.mjs <p8> <keyId> <issuerId> list
//   node asc_certs.mjs <p8> <keyId> <issuerId> revoke [keep]
import fs from 'node:fs';
import crypto from 'node:crypto';

const [, , P8, KEY_ID, ISSUER, MODE = 'list', KEEP_RAW = '1'] = process.argv;
if (!P8 || !KEY_ID || !ISSUER) {
  console.error('args: <p8> <keyId> <issuerId> [list|revoke] [keep]');
  process.exit(2);
}
const KEEP = Math.max(1, Number.parseInt(KEEP_RAW, 10) || 1);

const b64url = (b) =>
  Buffer.from(b).toString('base64').replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_');

function jwt() {
  const pem = fs.readFileSync(P8, 'utf8');
  const now = Math.floor(Date.now() / 1000);
  const si =
    b64url(JSON.stringify({ alg: 'ES256', kid: KEY_ID, typ: 'JWT' })) +
    '.' +
    b64url(JSON.stringify({ iss: ISSUER, iat: now, exp: now + 600, aud: 'appstoreconnect-v1' }));
  return si + '.' + b64url(crypto.sign('SHA256', Buffer.from(si), { key: pem, dsaEncoding: 'ieee-p1363' }));
}

const BASE = 'https://api.appstoreconnect.apple.com';
async function api(method, path) {
  const res = await fetch(BASE + path, {
    method,
    headers: { Authorization: 'Bearer ' + jwt(), 'Content-Type': 'application/json' },
  });
  const text = await res.text();
  let json = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    /* noop */
  }
  return { status: res.status, json, text };
}

/// 失効してよいのは開発用だけ。ストア提出用は絶対に触らない。
const isDevelopment = (type) => String(type || '').toUpperCase().includes('DEVELOPMENT');

(async () => {
  const res = await api('GET', '/v1/certificates?limit=200');
  if (res.status !== 200) {
    console.error('❌ 証明書の取得に失敗: ' + res.status + ' ' + res.text.slice(0, 300));
    process.exit(1);
  }
  const certs = (res.json?.data ?? []).map((c) => ({
    id: c.id,
    type: c.attributes?.certificateType,
    name: c.attributes?.displayName,
    expires: c.attributes?.expirationDate,
    created: c.attributes?.expirationDate, // 作成日は API に無いので有効期限で代用（発行順＝失効順）
  }));

  console.log(`=== 証明書 ${certs.length} 件 ===`);
  for (const c of certs) {
    const mark = isDevelopment(c.type) ? '開発' : '🔒提出用';
    console.log(`  [${mark}] ${c.type}  期限=${c.expires}  name=${c.name}  id=${c.id}`);
  }

  const dev = certs
    .filter((c) => isDevelopment(c.type))
    // 期限が新しい = 直近に発行された。新しい順に並べ、先頭 KEEP 本を残す。
    .sort((a, b) => String(b.expires).localeCompare(String(a.expires)));
  const keep = dev.slice(0, KEEP);
  const target = dev.slice(KEEP);

  console.log('');
  console.log(`開発証明書 ${dev.length} 件 / 残す ${keep.length} 件 / 失効対象 ${target.length} 件`);
  for (const c of keep) console.log(`  残す: ${c.expires}  ${c.id}`);
  for (const c of target) console.log(`  失効: ${c.expires}  ${c.id}`);

  if (MODE !== 'revoke') {
    console.log('');
    console.log('[list] 読むだけで終了しました。失効するには mode=revoke を指定してください。');
    return;
  }
  if (target.length === 0) {
    console.log('失効対象がありません。何もしません。');
    return;
  }

  console.log('');
  console.log('--- 失効を実行 ---');
  let ok = 0;
  for (const c of target) {
    const del = await api('DELETE', `/v1/certificates/${c.id}`);
    if (del.status === 204) {
      ok++;
      console.log(`  ✅ 失効: ${c.id}`);
    } else {
      console.log(`  ❌ 失敗(${del.status}): ${c.id} ${del.text.slice(0, 160)}`);
    }
  }
  console.log('');
  console.log(`完了: ${ok}/${target.length} 件を失効しました。`);

  // 読み直して検証（書いたら読み直す / このリポジトリの運用ルール）
  const after = await api('GET', '/v1/certificates?limit=200');
  const remain = (after.json?.data ?? []).filter((c) =>
    isDevelopment(c.attributes?.certificateType),
  ).length;
  console.log(`検証: 開発証明書は現在 ${remain} 件です。`);
})().catch((e) => {
  console.error('ERR', e.message);
  process.exit(1);
});
