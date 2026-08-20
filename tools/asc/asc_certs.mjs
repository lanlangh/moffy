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

const [, , P8, KEY_ID, ISSUER, MODE = 'list', KEEP_RAW = '1', IDS_RAW = ''] =
  process.argv;
if (!P8 || !KEY_ID || !ISSUER) {
  console.error('args: <p8> <keyId> <issuerId> [list|revoke] [keep]');
  process.exit(2);
}
const KEEP = Math.max(1, Number.parseInt(KEEP_RAW, 10) || 1);
/// 失効する証明書を**ID で明示指定**する（カンマ区切り）。空なら keep 方式。
///
/// なぜ要るか（2026-08-19）: このアカウントには Moffy 以外に4アプリがあり、
/// 開発証明書はアカウント単位なので**他アプリのCIが作ったものが混ざる**。
/// 「古い順に消す」だと他アプリの証明書を巻き込む。Moffy のビルド時刻と
/// 突き合わせて特定した ID だけを消せるようにする。
const IDS = IDS_RAW.split(',').map((x) => x.trim()).filter(Boolean);

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
  // 先にアカウント内のアプリを出す。開発証明書は**アプリ単位ではなくアカウント単位**
  // なので、「Moffy のものか」は証明書からは判定できない。判断材料として、
  // このアカウントに他のアプリがあるかを示す（他が無ければ影響範囲は Moffy だけ）。
  const apps = await api('GET', '/v1/apps?limit=100');
  const list = apps.json?.data ?? [];
  console.log('=== このアカウントのアプリ ' + list.length + ' 件 ===');
  for (const a of list) {
    console.log('  ' + a.attributes?.bundleId + '  ' + a.attributes?.name);
  }
  console.log('');

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
  // 🔴 revoke で ids を省略させない。
  //
  // 以前は ids 未指定なら「最新 KEEP 本だけ残して残り全部を失効」に**黙って切り替わる**作りだった。
  // 2026-08-19 に他アプリの証明書3本を巻き込んで失効させた事故は、この経路。
  // どれが消えるかを人間が数えずに実行できてしまうこと自体が原因なので、
  // **消すものを1本ずつ明示させる**。list（読むだけ）は従来どおり ids 無しで使える。
  if (MODE === 'revoke' && IDS.length === 0) {
    console.error('❌ revoke には ids（消す証明書IDのカンマ区切り）が必須。');
    console.error('   ids を省略すると「最新以外を全部」になり、他アプリを巻き込む。');
    console.error('   まず mode=list で一覧を見て、消すものを1本ずつ指定すること。');
    process.exit(1);
  }

  // ID 指定があればそれだけを対象にする（他アプリの証明書を巻き込まないため）。
  const keep = IDS.length > 0 ? dev.filter((c) => !IDS.includes(c.id)) : dev.slice(0, KEEP);
  const target = IDS.length > 0 ? dev.filter((c) => IDS.includes(c.id)) : dev.slice(KEEP);
  if (IDS.length > 0) {
    const missing = IDS.filter((id) => !dev.some((c) => c.id === id));
    if (missing.length > 0) {
      console.error('❌ 指定IDが見つからない(または開発証明書でない): ' + missing.join(','));
      process.exit(1);
    }
  }

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
