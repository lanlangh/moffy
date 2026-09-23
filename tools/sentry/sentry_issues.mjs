// Sentry の課題（Issues）を **読むだけ** で一覧する（Node 24 / 依存なし）。
//
// Usage:
//   node tools/sentry/sentry_issues.mjs <tokenFile> [orgSlug] [projectSlug]
//   例: node tools/sentry/sentry_issues.mjs "C:/Users/user/Downloads/m/Secrets/sentry-token.txt"
//
//   orgSlug を省くと、トークンで見える組織とプロジェクトを一覧して終わる（最初の1回向け）。
//
// なぜ要るか（2026-09-23）:
//   1.2.1 で Sentry が本番で動き始めたが、Claude は Sentry の画面を見られないため、
//   オーナーがメールのスクショを送る運用になっていた。これだと
//   「実ユーザーの端末で何が起きているか」の全体像がいつまでも掴めない。
//   件名が MOFFY-8 ＝少なくとも8種類の課題がある。
//
// 必要なスコープ（公式 docs で確認 / 2026-09-23）:
//   * event:read   … 課題の一覧・課題の詳細（docs.sentry.io/api/events/list-an-organizations-issues/）
//   * project:read … プロジェクト/イベント本体の取得
//   ⚠️ Personal Token のスコープは **作成後に変更できない**ので、作るときに両方入れる。
//
// ⚠️ GET しか投げない。課題の解決・削除・設定変更は一切しない。
// ⚠️ トークンは読むだけで、ログにも出力にも絶対に出さない（ASC/Play の道具と同じ作法）。
import fs from 'node:fs';

const [, , TOKEN_FILE, ORG, PROJECT] = process.argv;
if (!TOKEN_FILE) {
  console.error('args: <tokenFile> [orgSlug] [projectSlug]');
  console.error('例: node tools/sentry/sentry_issues.mjs "C:/Users/user/Downloads/m/Secrets/sentry-token.txt"');
  process.exit(2);
}

const BASE = 'https://sentry.io/api/0';

function readToken(path) {
  const raw = fs.readFileSync(path, 'utf8').trim();
  if (!raw) throw new Error('トークンファイルが空です');
  // 「SENTRY_TOKEN=xxx」形式で保存されていても拾えるようにする。
  const m = raw.match(/^[A-Z_]+\s*=\s*(.+)$/);
  return (m ? m[1] : raw).trim();
}

const token = readToken(TOKEN_FILE);

async function get(path, query) {
  const qs = query ? '?' + new URLSearchParams(query) : '';
  const res = await fetch(BASE + path + qs, {
    headers: { Authorization: 'Bearer ' + token },
  });
  const text = await res.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { /* 非JSON */ }
  if (!res.ok) {
    const detail = json?.detail ?? text.slice(0, 200);
    if (res.status === 401) throw new Error(`認証に失敗（401）。トークンが違うか失効しています: ${detail}`);
    if (res.status === 403) throw new Error(`権限不足（403）。event:read と project:read を付けて作り直してください: ${detail}`);
    throw new Error(`GET ${path} が HTTP ${res.status}: ${detail}`);
  }
  return json;
}

const jst = (iso) =>
  iso ? new Date(iso).toLocaleString('ja-JP', { timeZone: 'Asia/Tokyo' }) : '-';

async function main() {
  if (!ORG) {
    console.log('=== このトークンで見える組織 ===');
    const orgs = await get('/organizations/');
    for (const o of orgs ?? []) console.log(`  slug=${o.slug}  name=${o.name}`);
    console.log('');
    for (const o of orgs ?? []) {
      const projects = await get(`/organizations/${o.slug}/projects/`);
      console.log(`=== ${o.slug} のプロジェクト ===`);
      for (const p of projects ?? []) console.log(`  slug=${p.slug}  name=${p.name}`);
    }
    console.log('');
    console.log('次: node tools/sentry/sentry_issues.mjs <tokenFile> <orgSlug> [projectSlug]');
    return;
  }

  // 課題の一覧。query='' で解決済みも含めた全件（既定は is:unresolved のため）。
  const params = { query: '', statsPeriod: '14d', limit: '100' };
  if (PROJECT) params.project = PROJECT;
  const issues = await get(`/organizations/${ORG}/issues/`, params);

  console.log(`=== 課題一覧（直近14日 / ${issues.length} 件）===`);
  console.log('');
  for (const i of issues) {
    console.log(`[${i.shortId}] ${i.level?.toUpperCase() ?? '-'}  ${i.title}`);
    console.log(`    件数=${i.count}  影響ユーザー=${i.userCount}  状態=${i.status}`);
    console.log(`    初回=${jst(i.firstSeen)}  最終=${jst(i.lastSeen)}`);
    if (i.culprit) console.log(`    発生箇所=${i.culprit}`);
    console.log('');
  }

  const byLevel = {};
  let users = 0;
  for (const i of issues) {
    byLevel[i.level ?? '-'] = (byLevel[i.level ?? '-'] ?? 0) + Number(i.count ?? 0);
    users += Number(i.userCount ?? 0);
  }
  console.log('=== まとめ ===');
  console.log(`  レベル別の件数: ${Object.entries(byLevel).map(([k, v]) => `${k}=${v}`).join(' / ') || '(なし)'}`);
  console.log(`  影響ユーザー数の合計（重複あり）: ${users}`);
}

main().catch((e) => {
  console.error('❌ ' + e.message);
  process.exit(1);
});
