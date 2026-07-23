// 既存の未送信 reviewSubmission(下書き)に、アプリ本体(appStoreVersion)を item として追加する。
// サブスクは触らない・提出もしない・取り消しもしない。追加後に中身を報告するだけ。
// Usage: node asc_add_version_to_draft.mjs <p8> <keyId> <issuerId> <bundleId> <versionString>
import fs from 'node:fs';
import crypto from 'node:crypto';
const [, , P8, KEY_ID, ISSUER, BUNDLE_ID, VERSION] = process.argv;
const b64url = (b) => Buffer.from(b).toString('base64').replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_');
function jwt() {
  const pem = fs.readFileSync(P8, 'utf8');
  const now = Math.floor(Date.now() / 1000);
  const si = b64url(JSON.stringify({ alg: 'ES256', kid: KEY_ID, typ: 'JWT' })) + '.' +
    b64url(JSON.stringify({ iss: ISSUER, iat: now, exp: now + 600, aud: 'appstoreconnect-v1' }));
  return si + '.' + b64url(crypto.sign('SHA256', Buffer.from(si), { key: pem, dsaEncoding: 'ieee-p1363' }));
}
const BASE = 'https://api.appstoreconnect.apple.com';
async function api(method, path, body) {
  const res = await fetch(BASE + path, { method, headers: { Authorization: 'Bearer ' + jwt(), 'Content-Type': 'application/json' }, body: body ? JSON.stringify(body) : undefined });
  const t = await res.text(); let j = null; try { j = t ? JSON.parse(t) : null; } catch {}
  return { status: res.status, json: j, text: t };
}
const errs = (r) => (r.json?.errors ?? []).map(e => `[${e.code}] ${e.title}: ${e.detail}`).join(' | ') || (r.text || '').slice(0, 300);

(async () => {
  const apps = await api('GET', `/v1/apps?filter[bundleId]=${encodeURIComponent(BUNDLE_ID)}`);
  const appId = apps.json.data[0].id;
  const vers = await api('GET', `/v1/apps/${appId}/appStoreVersions?filter[versionString]=${encodeURIComponent(VERSION)}&limit=5`);
  const verId = vers.json.data[0].id;
  const vstate = vers.json.data[0].attributes.appStoreState ?? vers.json.data[0].attributes.appVersionState;
  console.log(`version ${VERSION} id=${verId} state=${vstate}`);
  if (vstate === 'REJECTED') { console.error('❌ まだ REJECTED。編集を保存して 審査準備完了 にしてから再実行。'); process.exit(1); }

  // 未送信の下書きを特定（submittedDate が無い / COMPLETE でない）
  const list = await api('GET', `/v1/reviewSubmissions?filter[app]=${appId}&limit=20`);
  const draft = (list.json?.data ?? []).find(s => !s.attributes.submittedDate && !['COMPLETE', 'CANCELED', 'CANCELING'].includes(s.attributes.state));
  if (!draft) { console.error('❌ 未送信の下書きが見つからない'); process.exit(1); }
  console.log(`下書き id=${draft.id} state=${draft.attributes.state}`);

  // 既に version item があるか
  const before = await api('GET', `/v1/reviewSubmissions/${draft.id}/items?include=appStoreVersion&limit=30`);
  const hasVer = (before.json?.data ?? []).some(it => it.relationships?.appStoreVersion?.data?.id === verId);
  if (hasVer) {
    console.log('✅ アプリ本体は既に下書きに入っています。');
  } else {
    const add = await api('POST', '/v1/reviewSubmissionItems', {
      data: { type: 'reviewSubmissionItems', relationships: { reviewSubmission: { data: { type: 'reviewSubmissions', id: draft.id } }, appStoreVersion: { data: { type: 'appStoreVersions', id: verId } } } },
    });
    if (add.status !== 201) { console.error('❌ アプリ本体の追加に失敗:', errs(add)); process.exit(1); }
    console.log('✅ アプリ本体(1.0)を下書きに追加しました。');
  }

  // 最終確認（何が入っているか）
  const after = await api('GET', `/v1/reviewSubmissions/${draft.id}/items?include=appStoreVersion&limit=30`);
  const inc = {}; for (const r of (after.json?.included ?? [])) inc[`${r.type}:${r.id}`] = r;
  console.log(`\n下書きの item 数=${(after.json?.data ?? []).length}`);
  for (const it of after.json?.data ?? []) {
    const v = it.relationships?.appStoreVersion?.data;
    const label = v ? `アプリ本体 ${inc[`appStoreVersions:${v.id}`]?.attributes?.versionString || ''}` : 'サブスク/その他(API非表示)';
    console.log(`   - ${label} (state=${it.attributes?.state})`);
  }
  console.log('\n※ 提出はしていません。ASCのUIで「審査へ提出」を押してください。');
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
