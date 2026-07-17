// App Store Connect: バージョンを審査に提出する（reviewSubmissions フロー）。
//
// ⚠️ 不可逆に近い操作。必ず asc_preflight.mjs が緑になってから実行すること。
//
// 手順（現行API）:
//   1. 既存の未完了 reviewSubmission が無いか確認（あると二重提出になる）
//   2. POST /v1/reviewSubmissions            … 提出の「箱」を作る
//   3. POST /v1/reviewSubmissionItems        … 箱に対象バージョンを入れる
//   4. PATCH /v1/reviewSubmissions/{id}      … submitted=true で送信
//   5. 読み直して state を検証
//
// Usage:
//   node asc_submit.mjs <p8> <keyId> <issuerId> <bundleId> <versionString>
import fs from 'node:fs';
import crypto from 'node:crypto';

const [, , P8, KEY_ID, ISSUER, BUNDLE_ID, VERSION] = process.argv;
if (!P8 || !KEY_ID || !ISSUER || !BUNDLE_ID || !VERSION) {
  console.error('args: <p8> <keyId> <issuerId> <bundleId> <versionString>');
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
    for (const e of r.json?.errors ?? []) {
      console.error(`   - [${e.code}] ${e.title}: ${e.detail}`);
    }
    if (!r.json?.errors) console.error('   ' + (r.text || '').slice(0, 800));
  }
  process.exit(1);
}

(async () => {
  const apps = await api('GET', `/v1/apps?filter[bundleId]=${encodeURIComponent(BUNDLE_ID)}`);
  const appId = apps.json?.data?.[0]?.id;
  if (!appId) fail('アプリが見つからない', apps);

  const vers = await api('GET', `/v1/apps/${appId}/appStoreVersions?filter[versionString]=${encodeURIComponent(VERSION)}&limit=5`);
  const ver = vers.json?.data?.[0];
  if (!ver) fail(`バージョン ${VERSION} が無い`, vers);
  const verId = ver.id;
  const state = ver.attributes.appStoreState ?? ver.attributes.appVersionState;
  console.log(`version ${VERSION} id=${verId} state=${state}`);
  if (state !== 'PREPARE_FOR_SUBMISSION' && state !== 'READY_FOR_REVIEW') {
    fail(`state=${state} は提出できる状態ではない（既に提出済みでは？）`);
  }

  // 1. 二重提出の防止
  const existing = await api('GET', `/v1/reviewSubmissions?filter[app]=${appId}&limit=20`);
  const open = (existing.json?.data ?? []).filter(
    (s) => !['COMPLETE', 'CANCELING', 'CANCELED'].includes(s.attributes?.state),
  );
  if (open.length) {
    const s = open[0];
    if (s.attributes.state === 'READY_FOR_REVIEW' || s.attributes.state === 'IN_REVIEW' || s.attributes.state === 'WAITING_FOR_REVIEW') {
      console.log(`⚠️  既に提出済みの reviewSubmission がある: id=${s.id} state=${s.attributes.state}`);
      console.log('   二重提出しない。何もせず終了。');
      process.exit(0);
    }
    console.log(`既存の未送信 reviewSubmission を再利用: id=${s.id} state=${s.attributes.state}`);
    var subId = s.id;
  } else {
    // 2. 箱を作る
    const created = await api('POST', '/v1/reviewSubmissions', {
      data: {
        type: 'reviewSubmissions',
        attributes: { platform: 'IOS' },
        relationships: { app: { data: { type: 'apps', id: appId } } },
      },
    });
    if (created.status !== 201) fail('reviewSubmission の作成に失敗', created);
    var subId = created.json.data.id;
    console.log(`reviewSubmission 作成: id=${subId}`);
  }

  // 3. 対象バージョンを入れる（既に入っていれば飛ばす）
  const items = await api('GET', `/v1/reviewSubmissions/${subId}/items?limit=20`);
  const already = (items.json?.data ?? []).some(
    (i) => i.relationships?.appStoreVersion?.data?.id === verId,
  );
  if (already) {
    console.log('対象バージョンは既に submission に含まれている');
  } else {
    const item = await api('POST', '/v1/reviewSubmissionItems', {
      data: {
        type: 'reviewSubmissionItems',
        relationships: {
          reviewSubmission: { data: { type: 'reviewSubmissions', id: subId } },
          appStoreVersion: { data: { type: 'appStoreVersions', id: verId } },
        },
      },
    });
    if (item.status !== 201) fail('submission への バージョン追加に失敗', item);
    console.log(`submissionItem 追加: id=${item.json.data.id}`);
  }

  // 4. 送信
  const sent = await api('PATCH', `/v1/reviewSubmissions/${subId}`, {
    data: { type: 'reviewSubmissions', id: subId, attributes: { submitted: true } },
  });
  if (sent.status !== 200) fail('提出（submitted=true）に失敗', sent);

  // 5. 検証
  const after = await api('GET', `/v1/reviewSubmissions/${subId}`);
  const st = after.json?.data?.attributes?.state;
  console.log(`\n✅ 提出しました: reviewSubmission id=${subId} state=${st}`);
  const v2 = await api('GET', `/v1/appStoreVersions/${verId}`);
  const vs = v2.json?.data?.attributes?.appStoreState ?? v2.json?.data?.attributes?.appVersionState;
  console.log(`✅ バージョン ${VERSION} state=${vs}`);
  if (!['WAITING_FOR_REVIEW', 'IN_REVIEW', 'READY_FOR_REVIEW', 'PENDING_DEVELOPER_RELEASE'].includes(vs)) {
    console.log(`⚠️  バージョンの state が想定外（${vs}）。ASC の UI で確認すること。`);
  }
})().catch((e) => { console.error('ERR', e.message); process.exit(1); });
