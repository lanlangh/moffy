// 2.1(a) "missing associated In-App-Purchase elements" の真因確定用診断。
// サブスクの状態・必須メタデータ(ローカライズ/価格/審査用スクショ)・提出への同梱状況を精査する。
// Usage: node asc_iap_diag.mjs <p8> <keyId> <issuerId> <bundleId> <versionString>
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
async function get(p) {
  const res = await fetch(BASE + p, { headers: { Authorization: 'Bearer ' + jwt() } });
  const t = await res.text(); let j = null; try { j = t ? JSON.parse(t) : null; } catch {}
  return { status: res.status, json: j, text: t };
}
(async () => {
  const apps = await get(`/v1/apps?filter[bundleId]=${encodeURIComponent(BUNDLE_ID)}`);
  const appId = apps.json.data[0].id;

  console.log('=== サブスクリプション ===');
  const groups = await get(`/v1/apps/${appId}/subscriptionGroups?limit=10`);
  for (const g of groups.json?.data ?? []) {
    console.log(`グループ id=${g.id} ref=${g.attributes.referenceName}`);
    const subs = await get(`/v1/subscriptionGroups/${g.id}/subscriptions?limit=20&include=subscriptionLocalizations,prices,appStoreReviewScreenshot`);
    for (const s of subs.json?.data ?? []) {
      const a = s.attributes;
      console.log(`\n  ● ${a.productId}  id=${s.id}`);
      console.log(`     state=${a.state} name=${JSON.stringify(a.name)} 期間=${a.subscriptionPeriod}`);
      // ローカライズ
      const loc = await get(`/v1/subscriptions/${s.id}/subscriptionLocalizations?limit=10`);
      console.log(`     ローカライズ: ${(loc.json?.data ?? []).map(l => `${l.attributes.locale}(名:${l.attributes.name?'有':'無'}/説明:${l.attributes.description?'有':'無'})`).join(', ') || '無し'}`);
      // 価格
      const pr = await get(`/v1/subscriptions/${s.id}/prices?limit=5&include=subscriptionPricePoint`);
      console.log(`     価格設定: ${(pr.json?.data ?? []).length}件`);
      // 審査用スクショ（サブスクは必須。これが無いと Missing Metadata）
      const ss = await get(`/v1/subscriptions/${s.id}/appStoreReviewScreenshot`);
      const st = ss.json?.data?.attributes?.assetDeliveryState?.state;
      console.log(`     審査用スクショ: ${ss.status===200 && ss.json?.data ? (st||'あり') : '★無し（サブスクは必須）'}`);
    }
  }

  console.log('\n=== レビュー提出(reviewSubmission)に何が含まれているか ===');
  const subsList = await get(`/v1/reviewSubmissions?filter[app]=${appId}&limit=20`);
  for (const s of subsList.json?.data ?? []) {
    console.log(`\nreviewSubmission id=${s.id} state=${s.attributes.state} submitted=${s.attributes.submittedDate ?? '-'}`);
    const items = await get(`/v1/reviewSubmissions/${s.id}/items?limit=30`);
    for (const it of items.json?.data ?? []) {
      const rel = it.relationships || {};
      const types = Object.keys(rel).filter(k => rel[k]?.data).map(k => `${k}=${rel[k].data.type}:${rel[k].data.id?.slice(0,8)}`);
      console.log(`   item id=${it.id} state=${it.attributes?.state} → ${types.join(', ') || '(関連なし)'}`);
    }
  }

  console.log('\n=== 判定ヒント ===');
  console.log('・全サブスクが state=READY_TO_SUBMIT かつ スクショ「あり」なのに、reviewSubmission の');
  console.log('  item に appStoreVersion しか無い → 真因=「サブスクを提出に同梱していない」＝コード修正不要。');
  console.log('・どれかが Missing Metadata / スクショ無し → そのサブスク自体の不備が真因。');
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
