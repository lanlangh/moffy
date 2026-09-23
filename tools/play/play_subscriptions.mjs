// Google Play の定期購入（サブスクリプション）の状態を **読むだけ** で確認する。
//
// Usage:
//   node tools/play/play_subscriptions.mjs <serviceAccountJson> <packageName>
//
// なぜ要るか（2026-09-23）:
//   Sentry の MOFFY-1 が「購入画面でプランを取得できない」で **8人・15件**。
//   RevenueCat のエラーコード 3（purchaseNotAllowedError）＝Android の
//   BILLING_UNAVAILABLE 相当で、端末側の事情（Playにサインインしていない等）のほかに
//   **商品がストア側で有効になっていない**場合にも起きる。iOS のサブスクは承認済みだが、
//   Android 側は API で確認したことがなかったので、ここで確かめる。
//
// ⚠️ GET しか投げない。商品の作成・変更・価格変更は一切しない。
import { loadServiceAccount, getToken, api, must } from './play_api.mjs';

const [, , SA_PATH, PKG] = process.argv;
if (!SA_PATH || !PKG) {
  console.error('args: <serviceAccountJson> <packageName>');
  process.exit(2);
}

const sa = loadServiceAccount(SA_PATH);
const token = await getToken(sa);

console.log('=== 定期購入（subscriptions）===');
const subs = must(
  await api(token, 'GET', `/androidpublisher/v3/applications/${PKG}/subscriptions`, {
    query: { pageSize: '50' },
  }),
  '定期購入の一覧',
);
const list = subs.subscriptions ?? [];
if (!list.length) {
  console.log('  ⚠️ 1件も登録されていない');
}
for (const s of list) {
  console.log('');
  console.log(`  商品ID: ${s.productId}`);
  const names = (s.listings ?? []).map((l) => `${l.languageCode}:${l.title}`).join(' / ');
  console.log(`    掲載名 : ${names || '(なし)'}`);
  for (const b of s.basePlans ?? []) {
    const regions = (b.regionalConfigs ?? []).length;
    const offers = (b.otherRegionsConfig ? 'その他地域あり' : 'その他地域なし');
    console.log(
      `    基本プラン ${b.basePlanId}: 状態=${b.state ?? '(不明)'} / 自動更新=${b.autoRenewingBasePlanType ? 'あり' : '-'} / 対象地域=${regions}件 / ${offers}`,
    );
  }
}

console.log('');
console.log('=== 判定 ===');
const active = list.flatMap((s) =>
  (s.basePlans ?? []).filter((b) => b.state === 'ACTIVE').map((b) => `${s.productId}/${b.basePlanId}`),
);
if (!list.length) {
  console.log('  ❌ 定期購入が1件も無い＝Android では誰も購入できない');
} else if (!active.length) {
  console.log('  ❌ ACTIVE な基本プランが1つも無い＝Android では誰も購入できない');
  console.log('     （下書き/無効のままだと、アプリからは商品が見えない）');
} else {
  console.log(`  ✅ 販売中の基本プラン: ${active.join(', ')}`);
}
