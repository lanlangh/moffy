// リジェクト後の編集可能ウィンドウで、ASO/AIEO差替＋年齢レーティング回答を一括適用する。
//   (1) 対象バージョンの ja ローカライズに keywords / description を差替
//   (2) ageRatingDeclaration の socialMedia を false（＝ソーシャルメディア機能なし）に回答
// ※サブスク同梱の再提出は API 不可（UIで実施）。本スクリプトはメタデータのみ。
// Usage: node asc_apply_batch.mjs <p8> <keyId> <issuerId> <bundleId> <versionString> <keywordsFile> <descFile>
import fs from 'node:fs';
import crypto from 'node:crypto';
const [, , P8, KEY_ID, ISSUER, BUNDLE_ID, VERSION, KW_FILE, DESC_FILE] = process.argv;
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
const errs = (r) => (r.json?.errors ?? []).map(e => `[${e.code}] ${e.title}: ${e.detail}`).join(' | ') || (r.text || '').slice(0, 400);
function fail(m, r) { console.error('❌ ' + m); if (r) console.error('   ' + errs(r)); process.exit(1); }

(async () => {
  const keywords = fs.readFileSync(KW_FILE, 'utf8').trim();
  const description = fs.readFileSync(DESC_FILE, 'utf8').replace(/\s+$/, '');
  console.log(`keywords: ${keywords.length}字 / description: ${description.length}字`);
  if (keywords.length > 100) fail('キーワードが100字超');
  if (description.length > 4000) fail('説明文が4000字超');

  const apps = await api('GET', `/v1/apps?filter[bundleId]=${encodeURIComponent(BUNDLE_ID)}`);
  const appId = apps.json.data[0].id;

  // (1) バージョンローカライズ差替
  const vers = await api('GET', `/v1/apps/${appId}/appStoreVersions?filter[versionString]=${encodeURIComponent(VERSION)}&limit=5`);
  const verId = vers.json.data[0].id;
  const locs = await api('GET', `/v1/appStoreVersions/${verId}/appStoreVersionLocalizations?limit=10`);
  const ja = (locs.json?.data ?? []).find(l => l.attributes.locale === 'ja') || (locs.json?.data ?? [])[0];
  if (!ja) fail('ja ローカライズが見つからない');
  const up = await api('PATCH', `/v1/appStoreVersionLocalizations/${ja.id}`, {
    data: { type: 'appStoreVersionLocalizations', id: ja.id, attributes: { keywords, description } },
  });
  if (up.status !== 200) fail('メタデータ差替に失敗', up);
  // 検証
  const chk = await api('GET', `/v1/appStoreVersionLocalizations/${ja.id}`);
  const gk = chk.json?.data?.attributes?.keywords, gd = chk.json?.data?.attributes?.description;
  if (gk !== keywords) fail('検証失敗: keywords 不一致');
  if (gd !== description) fail('検証失敗: description 不一致');
  console.log(`✅ (1) メタデータ差替＋検証OK（keywords ${gk.length}字 / description ${gd.length}字）`);

  // (2) 年齢レーティング socialMedia=false
  const infos = await api('GET', `/v1/apps/${appId}/appInfos?limit=5`);
  let done = false;
  for (const inf of infos.json?.data ?? []) {
    const st = inf.attributes?.appStoreState ?? inf.attributes?.state;
    if (st === 'READY_FOR_DISTRIBUTION') continue;
    const ar = await api('GET', `/v1/appInfos/${inf.id}/ageRatingDeclaration`);
    const arId = ar.json?.data?.id;
    if (!arId) continue;
    const cur = ar.json.data.attributes?.socialMedia;
    const patch = await api('PATCH', `/v1/ageRatingDeclarations/${arId}`, {
      data: { type: 'ageRatingDeclarations', id: arId, attributes: { socialMedia: false } },
    });
    if (patch.status !== 200) fail('年齢レーティング(socialMedia)更新に失敗', patch);
    const re = await api('GET', `/v1/appInfos/${inf.id}/ageRatingDeclaration`);
    console.log(`✅ (2) socialMedia: ${JSON.stringify(cur)} → ${JSON.stringify(re.json?.data?.attributes?.socialMedia)}（false=ソーシャルメディア機能なし）`);
    done = true;
  }
  if (!done) console.log('⚠️ 編集可能な ageRatingDeclaration が見つからず socialMedia は未設定（UIで回答）');

  console.log('\n✅ 一括適用 完了。次は ASC の UI でサブスクを同梱して再提出。');
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
