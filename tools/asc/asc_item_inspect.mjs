// reviewSubmission の各 item が「何」なのか(バージョン/サブスク/IAP)を生データで判別する。
// Usage: node asc_item_inspect.mjs <p8> <keyId> <issuerId> <bundleId>
import fs from 'node:fs';
import crypto from 'node:crypto';
const [, , P8, KEY_ID, ISSUER, BUNDLE_ID] = process.argv;
const b64url = (b) => Buffer.from(b).toString('base64').replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_');
function jwt() {
  const pem = fs.readFileSync(P8, 'utf8');
  const now = Math.floor(Date.now() / 1000);
  const si = b64url(JSON.stringify({ alg: 'ES256', kid: KEY_ID, typ: 'JWT' })) + '.' +
    b64url(JSON.stringify({ iss: ISSUER, iat: now, exp: now + 600, aud: 'appstoreconnect-v1' }));
  return si + '.' + b64url(crypto.sign('SHA256', Buffer.from(si), { key: pem, dsaEncoding: 'ieee-p1363' }));
}
const BASE = 'https://api.appstoreconnect.apple.com';
async function get(p) {
  const res = await fetch(BASE + p, { headers: { Authorization: 'Bearer ' + jwt() } });
  const t = await res.text(); let j = null; try { j = t ? JSON.parse(t) : null; } catch {}
  return { status: res.status, json: j, text: t };
}
(async () => {
  const apps = await get(`/v1/apps?filter[bundleId]=${encodeURIComponent(BUNDLE_ID)}`);
  const appId = apps.json.data[0].id;
  const subsList = await get(`/v1/reviewSubmissions?filter[app]=${appId}&limit=20`);
  for (const s of subsList.json?.data ?? []) {
    console.log(`\n===== reviewSubmission ${s.id} state=${s.attributes.state} submitted=${s.attributes.submittedDate ?? '-'} =====`);
    // include で関連実体を取得
    const items = await get(`/v1/reviewSubmissions/${s.id}/items?include=appStoreVersion,appEvent,appCustomProductPageVersion&limit=30`);
    const included = items.json?.included ?? [];
    const incMap = {};
    for (const r of included) incMap[`${r.type}:${r.id}`] = r;
    for (const it of items.json?.data ?? []) {
      const rel = it.relationships || {};
      const parts = [];
      for (const [k, v] of Object.entries(rel)) {
        if (v?.data) {
          const ref = incMap[`${v.data.type}:${v.data.id}`];
          let label = `${v.data.type}`;
          if (ref?.attributes?.versionString) label += ` ${ref.attributes.versionString}`;
          if (ref?.attributes?.productId) label += ` ${ref.attributes.productId}`;
          parts.push(`${k}→${label}`);
        }
      }
      // relationships が空の場合、item を個別GETして生で見る
      let raw = '';
      if (!parts.length) {
        const one = await get(`/v1/reviewSubmissionItems/${it.id}`);
        raw = JSON.stringify(one.json?.data?.relationships || {});
      }
      console.log(`  item state=${it.attributes?.state} removed=${it.attributes?.removed ?? '-'} :: ${parts.join(', ') || ('生relationships=' + raw)}`);
    }
  }
  console.log('\n判定: item に appStoreVersions(1.0) と subscriptions(monthly/yearly) の両方があれば下書きは完成。');
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
