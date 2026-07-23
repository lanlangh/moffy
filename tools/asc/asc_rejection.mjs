// App Store Connect: 審査リジェクトの内容（Resolution Center のメッセージ）を取得する。
//
// Usage: node asc_rejection.mjs <p8> <keyId> <issuerId> <bundleId> <versionString>
import fs from 'node:fs';
import crypto from 'node:crypto';

const [, , P8, KEY_ID, ISSUER, BUNDLE_ID, VERSION] = process.argv;
if (!P8 || !KEY_ID || !ISSUER || !BUNDLE_ID) {
  console.error('args: <p8> <keyId> <issuerId> <bundleId> [versionString]');
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
async function get(path) {
  const res = await fetch(BASE + path, { headers: { Authorization: 'Bearer ' + jwt() } });
  const text = await res.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { /* noop */ }
  return { status: res.status, json, text };
}

(async () => {
  const apps = await get(`/v1/apps?filter[bundleId]=${encodeURIComponent(BUNDLE_ID)}`);
  const appId = apps.json?.data?.[0]?.id;
  if (!appId) { console.error('アプリが見つからない'); process.exit(1); }

  // バージョンと状態
  const vers = await get(`/v1/apps/${appId}/appStoreVersions?limit=10`);
  for (const v of vers.json?.data ?? []) {
    if (VERSION && v.attributes.versionString !== VERSION) continue;
    const st = v.attributes.appStoreState ?? v.attributes.appVersionState;
    console.log(`\n=== version ${v.attributes.versionString} state=${st} ===`);

    // リジェクト理由の格納先候補を順に叩く（API/権限差でどれかが返る）
    // 1) reviewSubmissions（新フロー）
    const subs = await get(`/v1/reviewSubmissions?filter[app]=${appId}&limit=20`);
    for (const s of subs.json?.data ?? []) {
      console.log(`  reviewSubmission id=${s.id} state=${s.attributes.state} submitted=${s.attributes.submittedDate ?? '-'}`);
      // submissionItems の removed 理由等
      const items = await get(`/v1/reviewSubmissions/${s.id}/items?limit=20`);
      for (const it of items.json?.data ?? []) {
        const a = it.attributes || {};
        if (a.state || a.removed) console.log(`     item state=${a.state} removed=${a.removed} removalReason=${a.removalReason ?? '-'}`);
      }
    }
  }

  // 2) Resolution Center メッセージ（rejection の本文はここ）
  // appStoreReviewDetail 経由 or appStoreVersion の関連。まず version 直下の
  // reviewSubmission → workItems / rejection を探す。ASC APIは版により
  // /v1/appStoreVersions/{id}/appStoreReviewDetail までしか公開しないことがあるため、
  // 取得できた生JSONを可能な限りそのまま出す。
  console.log('\n=== Resolution Center / rejection 生データ探索 ===');
  const targetVer = (vers.json?.data ?? []).find((v) => !VERSION || v.attributes.versionString === VERSION);
  if (targetVer) {
    for (const rel of ['appStoreReviewDetail', 'appStoreVersionSubmission', 'appStoreVersionPhasedRelease']) {
      const r = await get(`/v1/appStoreVersions/${targetVer.id}/${rel}`);
      console.log(`  [${rel}] status=${r.status}`);
      if (r.json?.data) console.log('    ' + JSON.stringify(r.json.data.attributes || {}).slice(0, 500));
    }
  }

  // 3) betaAppReviewSubmission / betaAppReviewDetail（TestFlight審査は別だが念のため）
  // 4) Resolution Center は Public API では取れないことがある。その場合の案内。
  console.log('\n※ リジェクトの詳細メッセージ本文（Guideline番号・審査官コメント）は、ASC API では');
  console.log('  取得できない場合があります。その場合は ASC の「解決センター(Resolution Center)」を');
  console.log('  Webで開いて全文を確認する必要があります（下記手順）。');
})().catch((e) => { console.error('ERR', e.message); process.exit(1); });
