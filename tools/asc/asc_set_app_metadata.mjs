// App Store Connect: カテゴリと著作権を設定する（どちらも提出必須項目）。
//
// Usage:
//   node asc_set_app_metadata.mjs <p8> <keyId> <issuerId> <bundleId> <version> <primaryCategoryId> <copyright>
// 例:
//   node asc_set_app_metadata.mjs key.p8 K I com.moffy.app 1.0 HEALTH_AND_FITNESS "2026 合同会社Lan"
import fs from 'node:fs';
import crypto from 'node:crypto';

const [, , P8, KEY_ID, ISSUER, BUNDLE_ID, VERSION, PRIMARY_CAT, COPYRIGHT] = process.argv;
if (!P8 || !KEY_ID || !ISSUER || !BUNDLE_ID || !VERSION || !PRIMARY_CAT || !COPYRIGHT) {
  console.error('args: <p8> <keyId> <issuerId> <bundleId> <version> <primaryCategoryId> <copyright>');
  process.exit(2);
}
const b64url = (b) => Buffer.from(b).toString('base64').replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_');
function jwt() {
  const pem = fs.readFileSync(P8, 'utf8');
  const now = Math.floor(Date.now() / 1000);
  const si =
    b64url(JSON.stringify({ alg: 'ES256', kid: KEY_ID, typ: 'JWT' })) + '.' +
    b64url(JSON.stringify({ iss: ISSUER, iat: now, exp: now + 600, aud: 'appstoreconnect-v1' }));
  return si + '.' + b64url(crypto.sign('SHA256', Buffer.from(si), { key: pem, dsaEncoding: 'ieee-p1363' }));
}
const BASE = 'https://api.appstoreconnect.apple.com';
async function api(method, path, body) {
  const res = await fetch(BASE + path, {
    method,
    headers: { Authorization: 'Bearer ' + jwt(), 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { /* noop */ }
  return { status: res.status, json, text };
}
function fail(m, r) {
  console.error('❌ ' + m);
  if (r) {
    console.error('   STATUS ' + r.status);
    for (const e of r.json?.errors ?? []) console.error(`   - [${e.code}] ${e.title}: ${e.detail}`);
    if (!r.json?.errors) console.error('   ' + (r.text || '').slice(0, 500));
  }
  process.exit(1);
}

(async () => {
  // カテゴリIDが実在するか先に確かめる（綴り間違いで無言の失敗を避ける）
  const cats = await api('GET', '/v1/appCategories?filter[platforms]=IOS&limit=200');
  const ids = (cats.json?.data ?? []).map((c) => c.id);
  if (!ids.includes(PRIMARY_CAT)) {
    console.error('利用可能なカテゴリ: ' + ids.join(', '));
    fail(`カテゴリID '${PRIMARY_CAT}' は存在しない`);
  }
  console.log(`カテゴリID '${PRIMARY_CAT}' を確認`);

  const apps = await api('GET', `/v1/apps?filter[bundleId]=${encodeURIComponent(BUNDLE_ID)}`);
  const appId = apps.json?.data?.[0]?.id;
  if (!appId) fail('アプリが見つからない', apps);

  // --- カテゴリ（appInfo 側）---
  const infos = await api('GET', `/v1/apps/${appId}/appInfos?limit=5`);
  // 編集可能な appInfo（公開済み READY_FOR_DISTRIBUTION 以外）を選ぶ
  const editable = (infos.json?.data ?? []).filter((i) => {
    const s = i.attributes?.appStoreState ?? i.attributes?.state;
    return s !== 'READY_FOR_DISTRIBUTION';
  });
  if (!editable.length) fail('編集可能な appInfo が無い', infos);
  for (const inf of editable) {
    const r = await api('PATCH', `/v1/appInfos/${inf.id}`, {
      data: {
        type: 'appInfos',
        id: inf.id,
        relationships: { primaryCategory: { data: { type: 'appCategories', id: PRIMARY_CAT } } },
      },
    });
    if (r.status !== 200) fail(`appInfo ${inf.id} のカテゴリ設定に失敗`, r);
    console.log(`appInfo ${inf.id}: primaryCategory=${PRIMARY_CAT} 設定`);
  }

  // --- 著作権（appStoreVersion 側）---
  const vers = await api('GET', `/v1/apps/${appId}/appStoreVersions?filter[versionString]=${encodeURIComponent(VERSION)}&limit=5`);
  const verId = vers.json?.data?.[0]?.id;
  if (!verId) fail(`バージョン ${VERSION} が無い`, vers);
  const rv = await api('PATCH', `/v1/appStoreVersions/${verId}`, {
    data: { type: 'appStoreVersions', id: verId, attributes: { copyright: COPYRIGHT } },
  });
  if (rv.status !== 200) fail('著作権の設定に失敗', rv);

  // --- 検証（書いたら読んで確かめる）---
  const v2 = await api('GET', `/v1/appStoreVersions/${verId}`);
  const cr = v2.json?.data?.attributes?.copyright;
  if (cr !== COPYRIGHT) fail(`検証失敗: copyright=${JSON.stringify(cr)}（期待 ${JSON.stringify(COPYRIGHT)}）`);
  console.log(`✅ copyright=${JSON.stringify(cr)}`);

  for (const inf of editable) {
    const c = await api('GET', `/v1/appInfos/${inf.id}?include=primaryCategory`);
    const got = c.json?.included?.find((x) => x.type === 'appCategories')?.id;
    if (got !== PRIMARY_CAT) fail(`検証失敗: appInfo ${inf.id} の primaryCategory=${got}（期待 ${PRIMARY_CAT}）`);
    console.log(`✅ appInfo ${inf.id}: primaryCategory=${got}`);
  }
})().catch((e) => { console.error('ERR', e.message); process.exit(1); });
