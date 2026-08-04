// 下ごしらえ済みの提出物を App Review へ送る（submitted:true）。
//
// ⚠️ これは**外向きで取り消しの効きにくい操作**なので、送る前に中身を機械的に検証する。
//
// 安全装置（コードで強制）:
//   * 膠着中の提出物 755e8857 は対象にできない（IDが一致したら即中止）
//   * 提出物の中に**公開中の appStoreVersion 7824865b が含まれていたら中止**
//     （公開中バージョンを巻き込んで Developer Rejected に落とす事故の防止）
//   * 期待するバージョン(引数)以外の appStoreVersion が入っていたら中止
//   * items が0件なら中止
//   * 許可メソッドは GET / PATCH のみ（DELETE・POST は投げられない）
//   * 既定は dry-run。実際に送るには mode=submit
//   * 送ったら読み直して state を検証する
//
// Usage: node asc_submit_version.mjs <p8> <keyId> <issuerId> <bundleId> <versionString> [submit]
import fs from 'node:fs';
import crypto from 'node:crypto';

const FORBIDDEN_SUBMISSION = '755e8857-3ab8-421d-bdc1-e4642569acb4';
const LIVE_VERSION = '7824865b-b21f-4ce3-b76d-3da9ad85bb73';

const [, , P8, KEY_ID, ISSUER, BUNDLE_ID, VERSION, MODE = 'dry-run'] = process.argv;
const SUBMIT = MODE === 'submit';

const b64url = (b) => Buffer.from(b).toString('base64').replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_');
function jwt() {
  const pem = fs.readFileSync(P8, 'utf8');
  const now = Math.floor(Date.now() / 1000);
  const si = b64url(JSON.stringify({ alg: 'ES256', kid: KEY_ID, typ: 'JWT' })) + '.' +
    b64url(JSON.stringify({ iss: ISSUER, iat: now, exp: now + 600, aud: 'appstoreconnect-v1' }));
  return si + '.' + b64url(crypto.sign('SHA256', Buffer.from(si), { key: pem, dsaEncoding: 'ieee-p1363' }));
}
const BASE = 'https://api.appstoreconnect.apple.com';
async function call(method, p, body) {
  if (!['GET', 'PATCH'].includes(method)) throw new Error(`禁止メソッド: ${method}`);
  if (p.includes(FORBIDDEN_SUBMISSION)) throw new Error('膠着中の提出物に触れようとした。中止。');
  const res = await fetch(BASE + p, {
    method,
    headers: { Authorization: 'Bearer ' + jwt(), 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  });
  const t = await res.text(); let j = null; try { j = t ? JSON.parse(t) : null; } catch { /* noop */ }
  return { status: res.status, json: j };
}
const errOf = (r) => (r.json?.errors ?? []).map((e) => `[${e.status} ${e.code}] ${e.title} — ${e.detail ?? ''}`).join('\n    ');

(async () => {
  const apps = await call('GET', `/v1/apps?filter[bundleId]=${encodeURIComponent(BUNDLE_ID)}`);
  const appId = apps.json.data[0].id;

  const vers = await call('GET', `/v1/apps/${appId}/appStoreVersions?limit=20`);
  const target = (vers.json?.data ?? []).find((v) => v.attributes.versionString === VERSION);
  if (!target) throw new Error(`バージョン ${VERSION} が見つからない`);
  if (target.id === LIVE_VERSION) throw new Error('公開中バージョンを提出しようとした。中止。');
  console.log(`対象: ${VERSION} id=${target.id} state=${target.attributes.appStoreState}`);

  const list = await call('GET', `/v1/apps/${appId}/reviewSubmissions?limit=20`);
  const draft = (list.json?.data ?? []).find(
    (s) => s.id !== FORBIDDEN_SUBMISSION && !s.attributes.submittedDate &&
      !['COMPLETE', 'CANCELED', 'CANCELING'].includes(s.attributes.state));
  if (!draft) throw new Error('未提出の下書きが見つからない');
  console.log(`提出物: ${draft.id} state=${draft.attributes.state}\n`);

  // ---- 中身の検証（ここを通らないと絶対に送らない）----
  console.log('=== 中身の検証 ===');
  const items = await call('GET', `/v1/reviewSubmissions/${draft.id}/items?limit=30&include=appStoreVersion`);
  const data = items.json?.data ?? [];
  if (data.length === 0) throw new Error('items が0件。空の提出物は送らない。');
  let versionItems = 0;
  for (const it of data) {
    const vid = it.relationships?.appStoreVersion?.data?.id;
    console.log(`  item state=${it.attributes?.state} appStoreVersion=${vid ?? '-'}`);
    if (vid === LIVE_VERSION) throw new Error('❌ 公開中バージョンが入っている。送ると取り下げられる。中止。');
    if (vid && vid !== target.id) throw new Error(`❌ 想定外のバージョン ${vid} が入っている。中止。`);
    if (vid === target.id) versionItems++;
  }
  if (versionItems !== 1) throw new Error(`❌ 対象バージョンの item が ${versionItems} 件（1件であるべき）。中止。`);
  console.log(`  ✅ items=${data.length}件 / 対象バージョンのみ / 公開中バージョンは含まれない`);

  if (!SUBMIT) {
    console.log('\n[dry-run] 検証は通りました。実際に送るには mode=submit を指定してください。');
    return;
  }

  console.log('\n--- App Review へ送信 ---');
  const res = await call('PATCH', `/v1/reviewSubmissions/${draft.id}`, {
    data: { type: 'reviewSubmissions', id: draft.id, attributes: { submitted: true } },
  });
  console.log(`  PATCH submitted:true → HTTP ${res.status}`);
  if (res.status >= 400) { console.log(`    ${errOf(res)}`); process.exit(1); }

  // 送ったら読み直して検証する
  console.log('\n=== 検証（読み直し）===');
  const after = await call('GET', `/v1/reviewSubmissions/${draft.id}`);
  const st = after.json?.data?.attributes?.state;
  const sd = after.json?.data?.attributes?.submittedDate;
  console.log(`  state=${st} submittedDate=${sd ?? '-'}`);
  const v2 = await call('GET', `/v1/apps/${appId}/appStoreVersions?filter[versionString]=${encodeURIComponent(VERSION)}&limit=5`);
  console.log(`  バージョン state=${v2.json?.data?.[0]?.attributes?.appStoreState}`);
  if (sd) console.log('\n🎉 提出しました。審査結果を待ちます。');
  else { console.log('\n❌ submittedDate が入っていない。提出できていない可能性。'); process.exit(1); }
})().catch((e) => { console.error('ERR', e.message); process.exit(1); });
