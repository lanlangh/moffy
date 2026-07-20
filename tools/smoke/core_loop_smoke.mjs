// コアループの実サーバー・スモークテスト（提出 → 確定）。
//
// なぜ必要か:
//   本日の修正は「関数は正しいが誰も呼ばない」「実DBでは列権限で必ず 42501」という、
//   **Fake を使った単体テストでは原理的に検出できない**バグを2回続けて踏んだ。
//   だから最後は「実際の Supabase に、アプリと同じ経路（PostgREST + anon key + 匿名JWT）で
//   RPC を投げて、本当に確定するか」を確かめる。
//
// やること:
//   1. 匿名サインイン（アプリの signInAnonymously と同じ経路）
//   2. fn_pending_finalize_date  → サーバーが指す対象日を取得
//   3. fn_submit_and_finalize_day → 提出＋確定
//   4. usage_daily に is_finalized=true の行ができたかを確認
//   5. **必ず**テストユーザーを削除（後片付け / 呼び出し側が psql で実施）
//
// Usage:
//   node core_loop_smoke.mjs <supabaseUrl> <anonKey>
// 出力の最終行に "TEST_USER_ID=<uuid>" を出す（呼び出し側が掃除に使う）。

const [, , URL_BASE, ANON_KEY] = process.argv;
if (!URL_BASE || !ANON_KEY) {
  console.error('args: <supabaseUrl> <anonKey>');
  process.exit(2);
}
const base = URL_BASE.replace(/\/+$/, '');

async function http(path, { method = 'GET', token, body } = {}) {
  const res = await fetch(base + path, {
    method,
    headers: {
      apikey: ANON_KEY,
      Authorization: 'Bearer ' + (token || ANON_KEY),
      'Content-Type': 'application/json',
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { /* noop */ }
  return { status: res.status, json, text };
}

const fail = (m, r) => {
  console.error('❌ ' + m);
  if (r) console.error(`   HTTP ${r.status}: ${(r.text || '').slice(0, 600)}`);
  process.exit(1);
};

(async () => {
  // --- 1. 匿名サインイン ---
  const signup = await http('/auth/v1/signup', { method: 'POST', body: {} });
  if (signup.status !== 200 || !signup.json?.access_token) {
    fail('匿名サインインに失敗（アプリの初回起動と同じ経路が壊れている可能性）', signup);
  }
  const token = signup.json.access_token;
  const uid = signup.json.user?.id;
  console.log(`✅ 1. 匿名サインイン OK  user=${uid}`);
  console.log(`TEST_USER_ID=${uid}`);

  // --- 2. 対象日をサーバーに聞く ---
  const pending = await http('/rest/v1/rpc/fn_pending_finalize_date', { method: 'POST', token, body: {} });
  if (pending.status !== 200) {
    // ここが 404(PGRST202) なら「関数が公開されていない/シグネチャ違い」＝配線ミス。
    fail('fn_pending_finalize_date の呼び出しに失敗', pending);
  }
  const target = pending.json?.target_date;
  if (!target) fail('target_date が返らない', pending);
  console.log(`✅ 2. 対象日=${target} server_today=${pending.json.server_today} already=${pending.json.already_finalized}`);

  // --- 3. 提出＋確定（アプリと同じ引数名・同じ経路）---
  const submit = await http('/rest/v1/rpc/fn_submit_and_finalize_day', {
    method: 'POST',
    token,
    body: {
      p_date: target,
      p_total_minutes: 42,
      p_per_app_minutes: { 'com.instagram.android': 42 },
      p_source_mode: 'exact-minutes',
    },
  });
  if (submit.status !== 200) {
    // 42501 が出るならまさに今日直したはずの列権限バグの再発。
    fail('fn_submit_and_finalize_day の呼び出しに失敗', submit);
  }
  const r = submit.json;
  console.log(`✅ 3. 確定レスポンス: ${JSON.stringify(r)}`);
  if (r?.finalized !== true) {
    fail(`finalized=false（reason=${r?.reason}）＝確定できていない`);
  }
  // 新規ユーザーは baseline が無いので warmup（削減0pt）が正しい挙動。
  if (r.stage !== 'warmup') {
    console.log(`⚠️  stage=${r.stage}（新規ユーザーなので warmup を期待したが、致命的ではない）`);
  }

  // --- 4. 実際に行が確定済みで残っているか（書いたら読んで確かめる）---
  const row = await http(`/rest/v1/usage_daily?usage_date=eq.${target}&select=usage_date,total_minutes,is_finalized,is_anomaly`, { token });
  if (row.status !== 200 || !Array.isArray(row.json) || row.json.length !== 1) {
    fail('usage_daily の行が1件で取れない', row);
  }
  const u = row.json[0];
  console.log(`✅ 4. usage_daily: ${JSON.stringify(u)}`);
  if (u.total_minutes !== 42) fail(`total_minutes=${u.total_minutes}（期待 42）＝サーバーが生データを書けていない`);
  if (u.is_finalized !== true) fail('is_finalized=false ＝確定フラグが立っていない');

  // --- 5. 冪等性: もう一度投げても二重加算されないか ---
  const again = await http('/rest/v1/rpc/fn_submit_and_finalize_day', {
    method: 'POST',
    token,
    body: { p_date: target, p_total_minutes: 42, p_per_app_minutes: {}, p_source_mode: 'exact-minutes' },
  });
  if (again.status !== 200) fail('再送に失敗', again);
  if (again.json?.already_finalized !== true) {
    fail(`再送で already_finalized=true にならない: ${JSON.stringify(again.json)}＝二重確定の恐れ`);
  }
  console.log(`✅ 5. 冪等性OK（再送は already_finalized で弾かれる）`);

  // --- 6. 当日を確定しようとしたら拒否されるか（日付境界のガード）---
  const todayTry = await http('/rest/v1/rpc/fn_submit_and_finalize_day', {
    method: 'POST',
    token,
    body: { p_date: pending.json.server_today, p_total_minutes: 1, p_per_app_minutes: {}, p_source_mode: 'exact-minutes' },
  });
  if (todayTry.json?.reason !== 'wrong_finalize_date') {
    fail(`当日確定が拒否されない: ${JSON.stringify(todayTry.json)}＝満額確定の穴`);
  }
  console.log('✅ 6. 当日確定は wrong_finalize_date で拒否（日付境界のガードが効いている）');

  console.log('\n🎉 コアループのスモークテスト全項目 PASS');
})().catch((e) => { console.error('ERR', e.message); process.exit(1); });
