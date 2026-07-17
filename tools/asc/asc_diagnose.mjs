// App Store Connect: 提出が ENTITY_STATE_INVALID で弾かれたときの診断＋後片付け。
//
// Apple は「This resource cannot be reviewed, please check associated errors」としか返さず、
// 具体的な不足は API で直接取れない。ここでは取れる限りの状態を洗い出し、
// 提出が失敗して残った空の reviewSubmission を取り消す（次の提出の邪魔になるため）。
//
// Usage: node asc_diagnose.mjs <p8> <keyId> <issuerId> <bundleId> <version> [cleanup:true|false]
import fs from 'node:fs';
import crypto from 'node:crypto';

const [, , P8, KEY_ID, ISSUER, BUNDLE_ID, VERSION, CLEANUP] = process.argv;
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

(async () => {
  const apps = await api('GET', `/v1/apps?filter[bundleId]=${encodeURIComponent(BUNDLE_ID)}`);
  const appId = apps.json.data[0].id;
  const vers = await api('GET', `/v1/apps/${appId}/appStoreVersions?filter[versionString]=${encodeURIComponent(VERSION)}&limit=5`);
  const ver = vers.json.data[0];
  const verId = ver.id;

  console.log('=== appStoreVersion の全属性 ===');
  console.log(JSON.stringify(ver.attributes, null, 2));

  console.log('\n=== 年齢レーティング宣言 ===');
  const infos = await api('GET', `/v1/apps/${appId}/appInfos?limit=5`);
  for (const inf of infos.json?.data ?? []) {
    const st = inf.attributes?.appStoreState ?? inf.attributes?.state;
    console.log(`appInfo ${inf.id} state=${st}`);
    console.log('  attributes: ' + JSON.stringify(inf.attributes));
    const ar = await api('GET', `/v1/appInfos/${inf.id}/ageRatingDeclaration`);
    if (ar.json?.data) console.log('  ageRating: ' + JSON.stringify(ar.json.data.attributes));
    // カテゴリ
    const rel = await api('GET', `/v1/appInfos/${inf.id}?include=primaryCategory,secondaryCategory`);
    const inc = rel.json?.included ?? [];
    console.log('  categories: ' + (inc.map((c) => c.id).join(', ') || '(なし)'));
  }

  console.log('\n=== スクリーンショット表示タイプ ===');
  const locs = await api('GET', `/v1/appStoreVersions/${verId}/appStoreVersionLocalizations?limit=20`);
  for (const l of locs.json?.data ?? []) {
    const sets = await api('GET', `/v1/appStoreVersionLocalizations/${l.id}/appScreenshotSets?limit=30`);
    console.log(`  ${l.attributes.locale}: ` + (sets.json?.data ?? []).map((s) => `${s.attributes.screenshotDisplayType}(${s.id.slice(0, 6)})`).join(', '));
  }

  console.log('\n=== App Clip / 付随リソース ===');
  for (const p of ['appStoreVersionPhasedRelease', 'routingAppCoverage', 'appStoreVersionExperiments']) {
    const r = await api('GET', `/v1/appStoreVersions/${verId}/${p}`);
    console.log(`  ${p}: ${r.status}` + (r.json?.data ? ' あり' : ''));
  }

  console.log('\n=== reviewSubmissions（残骸の確認）===');
  const subs = await api('GET', `/v1/reviewSubmissions?filter[app]=${appId}&limit=20`);
  for (const s of subs.json?.data ?? []) {
    console.log(`  id=${s.id} state=${s.attributes.state} platform=${s.attributes.platform} submitted=${s.attributes.submittedDate ?? '-'}`);
    const items = await api('GET', `/v1/reviewSubmissions/${s.id}/items?limit=20`);
    console.log(`     items=${(items.json?.data ?? []).length}`);
    if (CLEANUP === 'true' && !['COMPLETE', 'CANCELING', 'CANCELED'].includes(s.attributes.state)) {
      const items0 = (items.json?.data ?? []).length;
      if (items0 === 0) {
        const c = await api('PATCH', `/v1/reviewSubmissions/${s.id}`, {
          data: { type: 'reviewSubmissions', id: s.id, attributes: { canceled: true } },
        });
        console.log(`     → 空の提出枠を取り消し: status=${c.status}`);
      } else {
        console.log('     → items があるので触らない');
      }
    }
  }
})().catch((e) => { console.error('ERR', e.message); process.exit(1); });
