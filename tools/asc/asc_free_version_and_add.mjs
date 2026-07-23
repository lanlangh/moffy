// 却下済み提出に紐づいた本体(appStoreVersion)を外し、未送信の下書きに追加する。
// (バージョンは同時に2つの提出に入れられないため、古い方から外す必要がある)
// 提出はしない。Usage: node asc_free_version_and_add.mjs <p8> <keyId> <issuerId> <bundleId> <versionString>
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
  console.log(`version ${VERSION} id=${verId} state=${vers.json.data[0].attributes.appStoreState}`);

  const list = await api('GET', `/v1/reviewSubmissions?filter[app]=${appId}&limit=20`);
  const submissions = list.json?.data ?? [];

  // (1) 却下/送信済みの提出から version item を外す
  for (const s of submissions) {
    if (!s.attributes.submittedDate) continue; // 送信済みのみ対象
    const items = await api('GET', `/v1/reviewSubmissions/${s.id}/items?include=appStoreVersion&limit=30`);
    for (const it of items.json?.data ?? []) {
      if (it.relationships?.appStoreVersion?.data?.id === verId) {
        console.log(`却下分 ${s.id}(state=${s.attributes.state}) に本体item発見 → 外す`);
        const del = await api('DELETE', `/v1/reviewSubmissionItems/${it.id}`);
        console.log(`   DELETE status=${del.status} ${del.status>=400?errs(del):'(外しました)'}`);
      }
    }
  }

  // (2) 未送信の下書きに version を追加
  const draft = submissions.find(s => !s.attributes.submittedDate && !['COMPLETE','CANCELED','CANCELING'].includes(s.attributes.state));
  if (!draft) { console.error('❌ 未送信の下書きが無い'); process.exit(1); }
  const before = await api('GET', `/v1/reviewSubmissions/${draft.id}/items?include=appStoreVersion&limit=30`);
  const has = (before.json?.data ?? []).some(it => it.relationships?.appStoreVersion?.data?.id === verId);
  if (has) {
    console.log('✅ 本体は既に下書きに入っています');
  } else {
    const add = await api('POST', '/v1/reviewSubmissionItems', {
      data: { type: 'reviewSubmissionItems', relationships: { reviewSubmission: { data: { type: 'reviewSubmissions', id: draft.id } }, appStoreVersion: { data: { type: 'appStoreVersions', id: verId } } } },
    });
    if (add.status !== 201) { console.error('❌ 本体の下書き追加に失敗:', errs(add)); process.exit(1); }
    console.log('✅ 本体(1.0)を下書きに追加しました');
  }

  // (3) 下書きの最終確認
  const after = await api('GET', `/v1/reviewSubmissions/${draft.id}/items?include=appStoreVersion&limit=30`);
  const inc = {}; for (const r of (after.json?.included ?? [])) inc[`${r.type}:${r.id}`] = r;
  console.log(`\n下書き item 数=${(after.json?.data ?? []).length}`);
  for (const it of after.json?.data ?? []) {
    const v = it.relationships?.appStoreVersion?.data;
    console.log(`   - ${v ? ('アプリ本体 ' + (inc[`appStoreVersions:${v.id}`]?.attributes?.versionString || '')) : 'サブスク/その他(API非表示)'}`);
  }
  console.log('\n※ 提出はしていません。ASCのUIで下書きを開き「審査へ提出」を押してください。');
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
