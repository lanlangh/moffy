// PostHog のイベントを **読むだけ** で集計する（Node 24 / 依存なし）。
//
// Usage:
//   node tools/posthog/posthog_query.mjs <keyFile> <projectId> [日数] [HogQL]
//   例: node tools/posthog/posthog_query.mjs "C:/Users/user/Downloads/m/Secrets/posthog-key.txt" 12345 30
//
// なぜ要るか（2026-09-23）:
//   Sentry は「壊れたもの」しか映さない。「35人来て0人課金」の理由は
//   **どこで離脱しているか**にあるはずで、それは PostHog にしか無い。
//   アプリは app_opened → onboarding_completed → … → paywall_viewed → purchase_completed
//   のファネルを送っている（analytics_events.dart）。
//
// 必要な権限（公式 docs で確認 / 2026-09-23）:
//   * Query API の実行に **「Query Read」**（キー作成画面の表示名）
//   * 接続先は US クラウドの**プライベート**側 `https://us.posthog.com`
//     （アプリが送る先 `https://us.i.posthog.com` とは別。docs の overview に明記）
//
// ⚠️ 読み取りのみ。イベントの削除・書き換え・設定変更はしない。
// ⚠️ キーは読むだけで、ログにも出力にも出さない。
import fs from 'node:fs';

const [, , KEY_FILE, PROJECT_ID, DAYS_ARG, CUSTOM_HOGQL] = process.argv;
if (!KEY_FILE || !PROJECT_ID) {
  console.error('args: <keyFile> <projectId> [日数] [HogQL]');
  process.exit(2);
}
const DAYS = Number(DAYS_ARG ?? 30);
const HOST = 'https://us.posthog.com';

function readKey(path) {
  const raw = fs.readFileSync(path, 'utf8').trim();
  if (!raw) throw new Error('キーのファイルが空です');
  const m = raw.match(/^[A-Z_]+\s*=\s*(.+)$/); // KEY=xxx 形式でも拾う
  return (m ? m[1] : raw).trim();
}
const key = readKey(KEY_FILE);

async function hogql(query, name) {
  const res = await fetch(`${HOST}/api/projects/${PROJECT_ID}/query/`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: 'Bearer ' + key,
    },
    body: JSON.stringify({ query: { kind: 'HogQLQuery', query }, name }),
  });
  const text = await res.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { /* 非JSON */ }
  if (!res.ok) {
    const detail = json?.detail ?? text.slice(0, 250);
    if (res.status === 401) throw new Error(`認証に失敗（401）。キーが違うか失効しています: ${detail}`);
    if (res.status === 403) throw new Error(`権限不足（403）。キーに「Query Read」を付けてください: ${detail}`);
    if (res.status === 404) throw new Error(`プロジェクトIDが違うかもしれません（404）: ${detail}`);
    throw new Error(`HTTP ${res.status}: ${detail}`);
  }
  return json?.results ?? [];
}

// ファネルの想定順（analytics_events.dart）。存在しないイベントは 0 で出す。
const FUNNEL = [
  ['app_opened', 'アプリ起動'],
  ['onboarding_completed', 'オンボーディング完了'],
  ['usage_permission_granted', '利用時間の権限を許可'],
  ['welcome_completed', 'ようこそ完了'],
  ['first_egg_granted', '最初の卵を受取'],
  ['day_finalized', '1日の集計が確定'],
  ['egg_hatched', '卵が孵化'],
  ['dex_registered', '図鑑に登録'],
  ['shiny_hatched', '色違いが出た'],
  ['quest_claimed', 'クエスト報酬を受取'],
  ['paywall_viewed', '購入画面を見た'],
  ['purchase_completed', '購入した'],
];

async function main() {
  if (CUSTOM_HOGQL) {
    const rows = await hogql(CUSTOM_HOGQL, 'custom');
    for (const r of rows) console.log('  ' + r.join('  |  '));
    return;
  }

  console.log(`=== 直近${DAYS}日のイベント（件数 / 人数）===`);
  const rows = await hogql(
    `SELECT event, count() AS c, count(DISTINCT distinct_id) AS u
       FROM events
      WHERE timestamp >= now() - INTERVAL ${DAYS} DAY
      GROUP BY event
      ORDER BY c DESC`,
    `moffy events last ${DAYS}d`,
  );
  const byEvent = new Map(rows.map((r) => [r[0], { c: r[1], u: r[2] }]));
  for (const r of rows) {
    console.log(`  ${String(r[0]).padEnd(26)} ${String(r[1]).padStart(6)}件  ${String(r[2]).padStart(5)}人`);
  }

  console.log('');
  console.log('=== ファネル（人数）===');
  const top = byEvent.get('app_opened')?.u ?? 0;
  for (const [ev, label] of FUNNEL) {
    const u = byEvent.get(ev)?.u ?? 0;
    const pct = top ? ((u / top) * 100).toFixed(0) : '-';
    const bar = '#'.repeat(top ? Math.round((u / top) * 30) : 0);
    console.log(`  ${label.padEnd(20)} ${String(u).padStart(4)}人 ${String(pct).padStart(3)}%  ${bar}`);
  }

  console.log('');
  console.log('=== 日ごとのアクティブ人数 ===');
  const daily = await hogql(
    `SELECT toDate(timestamp) AS d, count(DISTINCT distinct_id) AS u
       FROM events
      WHERE timestamp >= now() - INTERVAL ${DAYS} DAY
      GROUP BY d ORDER BY d`,
    `moffy dau last ${DAYS}d`,
  );
  for (const r of daily) console.log(`  ${r[0]}  ${String(r[1]).padStart(4)}人`);
}

main().catch((e) => {
  console.error('❌ ' + e.message);
  process.exit(1);
});
