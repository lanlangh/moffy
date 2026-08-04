// サブスクの「無料トライアル(introductory offer)」と価格が、ストア説明文の記述と
// 一致しているかを検証する。**GET のみ**。
//
// なぜ要るか:
//   `lib/core/constants/pricing.dart` に freeTrialDays=7 があっても、それは
//   **アプリ内の定数**にすぎない。App Store Connect 側に introductory offer が
//   設定されていなければ、ストア説明文の「初回7日間無料」は事実に反する。
//   景表法（有利誤認）と App Store 3.1.2（サブスクの表示要件）の両方に触れる。
//
// Usage: node asc_iap_offers_check.mjs <p8> <keyId> <issuerId> <bundleId>
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
  const t = await res.text();
  let j = null;
  try { j = t ? JSON.parse(t) : null; } catch { /* noop */ }
  return { status: res.status, json: j };
}
const errOf = (r) => (r.json?.errors ?? []).map((e) => `${e.status} ${e.code} ${e.detail ?? ''}`).join(' | ');

(async () => {
  const apps = await get(`/v1/apps?filter[bundleId]=${encodeURIComponent(BUNDLE_ID)}`);
  const appId = apps.json.data[0].id;
  const groups = await get(`/v1/apps/${appId}/subscriptionGroups?limit=10`);

  let missingTrial = 0;
  for (const g of groups.json?.data ?? []) {
    const subs = await get(`/v1/subscriptionGroups/${g.id}/subscriptions?limit=20`);
    for (const s of subs.json?.data ?? []) {
      console.log(`\n● ${s.attributes.productId}  state=${s.attributes.state}`);

      const offers = await get(`/v1/subscriptions/${s.id}/introductoryOffers?limit=20`);
      if (offers.status !== 200) {
        console.log(`  introductoryOffers: HTTP ${offers.status} ${errOf(offers)}`);
      } else {
        const list = offers.json?.data ?? [];
        console.log(`  無料トライアル(introductoryOffers): ${list.length}件`);
        for (const o of list) {
          const a = o.attributes ?? {};
          console.log(`    duration=${a.duration} mode=${a.offerMode} 開始=${a.startDate ?? '-'} 終了=${a.endDate ?? '無期限'}`);
        }
        if (list.length === 0) {
          missingTrial++;
          console.log('    ❌ **未設定**。ストア説明文の「初回7日間無料」は事実に反する。');
        }
      }

      const prices = await get(`/v1/subscriptions/${s.id}/prices?limit=50&include=subscriptionPricePoint`);
      const pts = (prices.json?.included ?? [])
        .filter((x) => x.type === 'subscriptionPricePoints' && x.attributes?.customerPrice)
        .map((x) => x.attributes.customerPrice);
      console.log(`  価格ポイント(${pts.length}件): ${pts.slice(0, 8).join(' / ')}${pts.length > 8 ? ' …' : ''}`);
    }
  }

  console.log('\n=== 判定 ===');
  if (missingTrial > 0) {
    console.log(`❌ 無料トライアル未設定のサブスクが ${missingTrial} 件。`);
    console.log('   → ストア説明文から「初回7日間無料」の記述を削除するか、ASCでトライアルを設定すること。');
  } else {
    console.log('✅ 全サブスクに無料トライアルが設定されている。');
  }
  console.log('\n※ GET のみ。状態は変更していません。');
})().catch((e) => { console.error('ERR', e.message); process.exit(1); });
