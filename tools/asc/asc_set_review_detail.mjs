// App Store Connect: 審査情報（App Review Detail）のうち、**個人情報でない項目**を設定する。
//
// 設定するもの:
//   * notes              … 審査メモ（ファイルから読む / リポジトリで版管理・レビュー可能に）
//   * demoAccountRequired… デモアカウントの要否
//
// ⚠️ 連絡先（氏名・電話・メール）はここでは触らない。個人情報はオーナーが UI で入力する。
//    既存の連絡先が入っていることを前提とし、入っていなければ失敗させる。
//
// Usage:
//   node asc_set_review_detail.mjs <p8> <keyId> <issuerId> <bundleId> <version> <notesFile> <demoRequired:true|false>
import fs from 'node:fs';
import crypto from 'node:crypto';

const [, , P8, KEY_ID, ISSUER, BUNDLE_ID, VERSION, NOTES_FILE, DEMO_REQUIRED] = process.argv;
if (!P8 || !KEY_ID || !ISSUER || !BUNDLE_ID || !VERSION || !NOTES_FILE || !DEMO_REQUIRED) {
  console.error('args: <p8> <keyId> <issuerId> <bundleId> <version> <notesFile> <demoRequired:true|false>');
  process.exit(2);
}
const demoRequired = DEMO_REQUIRED === 'true';

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
const fail = (m, r) => { console.error('❌ ' + m); if (r) console.error('   ' + r.status + ' ' + (r.text || '').slice(0, 500)); process.exit(1); };

(async () => {
  const notes = fs.readFileSync(NOTES_FILE, 'utf8').trim();
  if (!notes) fail('審査メモが空');
  console.log(`notes: ${notes.length} 字`);

  const apps = await api('GET', `/v1/apps?filter[bundleId]=${encodeURIComponent(BUNDLE_ID)}`);
  const appId = apps.json?.data?.[0]?.id;
  if (!appId) fail('アプリが見つからない', apps);

  const vers = await api('GET', `/v1/apps/${appId}/appStoreVersions?filter[versionString]=${encodeURIComponent(VERSION)}&limit=5`);
  const verId = vers.json?.data?.[0]?.id;
  if (!verId) fail(`バージョン ${VERSION} が無い`, vers);

  const cur = await api('GET', `/v1/appStoreVersions/${verId}/appStoreReviewDetail`);
  if (cur.status !== 200 || !cur.json?.data) {
    fail('審査情報がまだ存在しない。連絡先（氏名・電話・メール）を先に ASC の UI で入力すること（個人情報のためスクリプトでは入れない）', cur);
  }
  const id = cur.json.data.id;
  const a = cur.json.data.attributes;

  // 連絡先が入っていることを確認（ここは触らないが、欠けていたら提出できないので落とす）
  const missing = ['contactFirstName', 'contactLastName', 'contactPhone', 'contactEmail'].filter((k) => !a[k]?.trim());
  if (missing.length) fail(`連絡先が未入力: ${missing.join(', ')}（ASC の UI で入力すること）`);
  console.log(`連絡先: 入力済（このスクリプトでは変更しない）`);

  const patch = await api('PATCH', `/v1/appStoreReviewDetails/${id}`, {
    data: { type: 'appStoreReviewDetails', id, attributes: { notes, demoAccountRequired: demoRequired } },
  });
  if (patch.status !== 200) fail('審査情報の更新に失敗', patch);

  // 書いたら読んで確かめる
  const after = await api('GET', `/v1/appStoreVersions/${verId}/appStoreReviewDetail`);
  const x = after.json?.data?.attributes;
  if (x?.notes?.trim() !== notes) fail('検証失敗: 審査メモが反映されていない');
  if (x?.demoAccountRequired !== demoRequired) fail(`検証失敗: demoAccountRequired=${x?.demoAccountRequired}（期待 ${demoRequired}）`);
  console.log(`✅ 審査メモ ${x.notes.length} 字 / demoAccountRequired=${x.demoAccountRequired} を設定・検証`);
})().catch((e) => { console.error('ERR', e.message); process.exit(1); });
