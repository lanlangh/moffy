// App Store Connect の「下書きバージョンの番号」を書き換える。
//
// 目的:
//   ASC は下書き(PREPARE_FOR_SUBMISSION)のバージョンを同時に1つしか持てない。
//   よって「新しい番号で出したいから新規作成する」ができない場面がある。
//   既にある下書きの versionString を書き換えて再利用するのがこのツール。
//
// 背景（このリポジトリの実例 / 2026-08-10）:
//   Apple のサブスク固着調査（ケース 20000121488355）の指示で 1.0.3 の下書きを作成した。
//   その後 v1.1 をリリースすることになり、アップロード済みビルドの
//   CFBundleShortVersionString が 1.1.0 のため、ASC 側も 1.1.0 でないとビルドを
//   紐付けられない（Apple は両者の一致を要求する）。そこで 1.0.3 → 1.1.0 に改名した。
//
// Usage:
//   node asc_rename_version.mjs <p8Path> <keyId> <issuerId> <bundleId> <from> <to> [apply]
//   （末尾に apply を付けない限り dry-run。実データは変更しない）
//
// 安全装置（誤って公開中のリリースを壊さないため）:
//   1. 対象は appStoreState/appVersionState が **PREPARE_FOR_SUBMISSION のものだけ**。
//      READY_FOR_SALE（公開中）や IN_REVIEW（審査中）は問答無用で拒否する。
//   2. 変更先の番号が既に存在する場合は拒否（重複を作らない）。
//   3. 使う HTTP メソッドは GET と PATCH のみ。**POST も DELETE も実装しない**
//      ＝新規バージョンの作成も、バージョンの削除も、このツールでは起こり得ない。
//   4. 変更後に GET で読み直し、実際に変わったことを確認してから成功終了する。
//
// 秘密鍵は読み取るだけで、出力にも例外メッセージにも載せない。
import fs from 'node:fs';
import crypto from 'node:crypto';

const [, , P8_PATH, KEY_ID, ISSUER_ID, BUNDLE_ID, FROM_VER, TO_VER, MODE] = process.argv;
if (!P8_PATH || !KEY_ID || !ISSUER_ID || !BUNDLE_ID || !FROM_VER || !TO_VER) {
  console.error('args: <p8Path> <keyId> <issuerId> <bundleId> <from> <to> [apply]');
  process.exit(2);
}
const APPLY = MODE === 'apply';

const b64url = (b) =>
  Buffer.from(b).toString('base64').replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_');
function makeJWT() {
  const pem = fs.readFileSync(P8_PATH, 'utf8');
  const now = Math.floor(Date.now() / 1000);
  const si =
    b64url(JSON.stringify({ alg: 'ES256', kid: KEY_ID, typ: 'JWT' })) +
    '.' +
    b64url(JSON.stringify({ iss: ISSUER_ID, iat: now, exp: now + 600, aud: 'appstoreconnect-v1' }));
  return si + '.' + b64url(crypto.sign('SHA256', Buffer.from(si), { key: pem, dsaEncoding: 'ieee-p1363' }));
}

const BASE = 'https://api.appstoreconnect.apple.com';
async function call(method, path, body) {
  // ★安全装置3: GET / PATCH 以外は実装しない（作成・削除を物理的に不可能にする）。
  if (!['GET', 'PATCH'].includes(method)) throw new Error(`禁止メソッド: ${method}`);
  const res = await fetch(BASE + path, {
    method,
    headers: {
      Authorization: 'Bearer ' + makeJWT(),
      ...(body ? { 'Content-Type': 'application/json' } : {}),
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
  const text = await res.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { /* noop */ }
  return { status: res.status, json, text };
}

const DRAFT_STATES = ['PREPARE_FOR_SUBMISSION'];

(async () => {
  console.log(`=== 対象 ===`);
  console.log(`  bundleId = ${BUNDLE_ID}`);
  console.log(`  ${FROM_VER}  →  ${TO_VER}`);
  console.log(`  mode = ${APPLY ? 'apply（実際に変更する）' : 'dry-run（変更しない）'}`);

  const apps = await call('GET', `/v1/apps?filter[bundleId]=${encodeURIComponent(BUNDLE_ID)}`);
  if (apps.status !== 200 || !apps.json?.data?.length) {
    console.error(`❌ アプリが見つからない (${BUNDLE_ID}) status=${apps.status}`);
    process.exit(1);
  }
  const appId = apps.json.data[0].id;
  console.log(`  appId = ${appId}`);

  // 既存バージョンを一覧し、from を特定し、to の重複が無いことを確かめる。
  const vers = await call('GET', `/v1/apps/${appId}/appStoreVersions?limit=50`);
  if (vers.status !== 200) {
    console.error(`❌ バージョン一覧の取得に失敗 status=${vers.status}`);
    process.exit(1);
  }
  console.log(`\n=== 既存のバージョン ===`);
  let target = null;
  let duplicate = null;
  for (const v of vers.json.data) {
    const a = v.attributes;
    const st = a.appStoreState ?? a.appVersionState;
    console.log(`  ${a.versionString.padEnd(8)} ${st}  id=${v.id}`);
    if (a.versionString === FROM_VER) target = { id: v.id, state: st };
    if (a.versionString === TO_VER) duplicate = { id: v.id, state: st };
  }

  if (!target) {
    console.error(`\n❌ 変更元 ${FROM_VER} が見つからない。`);
    process.exit(1);
  }
  // ★安全装置2: 変更先が既にあるなら何もしない。
  if (duplicate) {
    console.error(`\n❌ 変更先 ${TO_VER} が既に存在する (state=${duplicate.state} id=${duplicate.id})。`);
    console.error(`   重複を作らないため中止する。`);
    process.exit(1);
  }
  // ★安全装置1: 下書き以外は絶対に触らない。
  if (!DRAFT_STATES.includes(target.state)) {
    console.error(`\n❌ ${FROM_VER} は state=${target.state} で、下書き(PREPARE_FOR_SUBMISSION)ではない。`);
    console.error(`   公開中/審査中のバージョンは変更しない（このツールの安全装置）。`);
    process.exit(1);
  }

  console.log(`\n✅ 変更対象を特定: id=${target.id} state=${target.state}`);

  if (!APPLY) {
    console.log(`\n[dry-run] ここで versionString を "${FROM_VER}" → "${TO_VER}" に PATCH する。`);
    console.log(`          実行するには末尾に apply を指定すること。`);
    process.exit(0);
  }

  const patch = await call('PATCH', `/v1/appStoreVersions/${target.id}`, {
    data: { type: 'appStoreVersions', id: target.id, attributes: { versionString: TO_VER } },
  });
  if (patch.status !== 200) {
    console.error(`\n❌ 変更に失敗 status=${patch.status}`);
    console.error(patch.text?.slice(0, 800));
    process.exit(1);
  }

  // ★安全装置4: 読み直して実際に変わったことを確認する。
  const after = await call('GET', `/v1/appStoreVersions/${target.id}`);
  const nowVer = after.json?.data?.attributes?.versionString;
  const nowState = after.json?.data?.attributes?.appStoreState ?? after.json?.data?.attributes?.appVersionState;
  if (nowVer !== TO_VER) {
    console.error(`\n❌ 変更後の確認に失敗: versionString=${nowVer}（期待 ${TO_VER}）`);
    process.exit(1);
  }
  console.log(`\n✅ 変更完了: versionString=${nowVer} state=${nowState} id=${target.id}`);
  console.log(`   ※ 下書きは新規作成していない（同じ id のまま番号だけ変えた）。`);
})();
