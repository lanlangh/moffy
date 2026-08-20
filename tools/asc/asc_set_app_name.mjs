// App Store Connect — アプリ名とサブタイトルだけを差し替える（Node 24 / 依存なし）
//
// Usage:
//   node asc_set_app_name.mjs <p8Path> <keyId> <issuerId> <bundleId> [apply]
//   （末尾の apply を省略すると dry-run＝読むだけ・既定）
//
// ■ なぜ専用の道具を作ったか（2026-08-20）
//   アプリ名・サブタイトルは appInfoLocalizations（＝アプリ単位）に住んでおり、
//   説明文やキーワード（appStoreVersionLocalizations＝バージョン単位）とは別のリソース。
//   そのため asc_prepare_version.mjs では書けない。
//   唯一書ける asc_set_metadata.mjs は **使ってはいけない**:
//     * 埋め込みの description が 1442字（ios_store_description.txt は 2309字）＝
//       走らせると説明文が古い版まで巻き戻る
//     * 編集可能なバージョンが無いと versionString:'1.0' を勝手に POST する
//   → 「名前と副題だけ」を触る最小の道具として、これを作った。
//
// ■ 公開中の表示を壊さないための作り
//   ASC は appInfo を2つ持つ:
//     READY_FOR_DISTRIBUTION … いま App Store に出ている掲載。触ると即座に表示が変わる
//     PREPARE_FOR_SUBMISSION … 次の提出用・編集可。ここだけ書けば公開中は無傷で、
//                              新バージョンが承認・リリースされた瞬間に切り替わる
//   さらに ASC は **同じ appInfo に2つのキーを返し、値が違う**（実測）:
//     appStoreState = "READY_FOR_SALE" / state = "READY_FOR_DISTRIBUTION"
//   片方だけ見て「READY_FOR_DISTRIBUTION ではない＝編集可」と判定すると
//   **公開中のレコードを掴む**。実際に asc_set_app_metadata.mjs がこの穴を持っていた。
//   → ここでは **許可方式**。PREPARE_FOR_SUBMISSION と明示的に分かるものだけ触る。
//
//   編集用レコードは **下書きバージョンが存在するときだけ現れる**。
//   つまり先に appStoreVersion を作っておく必要がある（asc_prepare_version.mjs）。
import fs from 'node:fs';
import crypto from 'node:crypto';

// ── 入れる値。どちらも上限30字（ASC の仕様）──
const NAME = 'Moffy（モフィ）- SNS減らして卵を育てる';
const SUBTITLE = 'スクリーンタイムが、かわいい図鑑になる育成ゲーム';
const LOCALE = 'ja';
const LIMIT = 30;

// 公開中の appInfo。取り違え防止の保険（本体は下の許可方式の判定）。
const FORBIDDEN_APPINFO = 'd53c70fa-4152-4537-8724-79b44e61bf07';

const [, , P8, KEY_ID, ISSUER, BUNDLE_ID, MODE = 'dry-run'] = process.argv;
const APPLY = MODE === 'apply';
if (!P8 || !KEY_ID || !ISSUER || !BUNDLE_ID) {
  console.error('args: <p8Path> <keyId> <issuerId> <bundleId> [apply]');
  process.exit(2);
}

const b64url = (b) =>
  Buffer.from(b).toString('base64').replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_');

function makeJwt() {
  const pem = fs.readFileSync(P8, 'utf8');
  const now = Math.floor(Date.now() / 1000);
  const head = b64url(JSON.stringify({ alg: 'ES256', kid: KEY_ID, typ: 'JWT' }));
  const body = b64url(JSON.stringify({
    iss: ISSUER, iat: now, exp: now + 600, aud: 'appstoreconnect-v1',
  }));
  const input = head + '.' + body;
  const sig = crypto.sign('SHA256', Buffer.from(input), {
    key: pem, dsaEncoding: 'ieee-p1363',
  });
  return input + '.' + b64url(sig);
}

const BASE = 'https://api.appstoreconnect.apple.com';
const fail = (m, extra) => {
  console.error('❌ ' + m);
  if (extra) console.error('   ' + extra);
  process.exit(1);
};

async function api(method, path, body) {
  // この道具は DELETE を絶対に投げない（消す操作は取り返しがつかない）。
  if (!['GET', 'PATCH'].includes(method)) fail(`禁止メソッド: ${method}`);
  if (path.includes(FORBIDDEN_APPINFO)) {
    fail(`公開中の appInfo (${FORBIDDEN_APPINFO}) に触れようとした。中止。`);
  }
  const res = await fetch(BASE + path, {
    method,
    headers: {
      Authorization: 'Bearer ' + makeJwt(),
      'Content-Type': 'application/json',
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { /* 非JSON */ }
  return { status: res.status, json, text };
}

/** 公開系の状態名。どちらか一方のキーでもこれなら触らない。 */
const PUBLISHED = ['READY_FOR_DISTRIBUTION', 'READY_FOR_SALE'];

async function main() {
  console.log(`=== 入れる値の検証 ===`);
  for (const [label, v] of [['アプリ名', NAME], ['サブタイトル', SUBTITLE]]) {
    const n = [...v].length; // 絵文字・結合文字を1文字として数える
    console.log(`  ${label} = ${JSON.stringify(v)}  ${n} / ${LIMIT}字`);
    if (n > LIMIT) fail(`${label}が ${n} 字＝上限 ${LIMIT} 字を超過。ASC に触る前に中止する。`);
    if (!v.trim()) fail(`${label}が空`);
  }
  console.log('');

  const apps = await api('GET', `/v1/apps?filter[bundleId]=${encodeURIComponent(BUNDLE_ID)}`);
  const app = apps.json?.data?.[0];
  if (!app) fail('アプリが見つからない', apps.text?.slice(0, 300));
  console.log(`=== アプリ ===\n  id=${app.id} name=${JSON.stringify(app.attributes?.name)}\n`);

  const infos = await api('GET', `/v1/apps/${app.id}/appInfos?fields[appInfos]=state,appStoreState&limit=10`);
  const all = infos.json?.data ?? [];
  console.log('=== appInfo の一覧 ===');
  for (const i of all) {
    const a = i.attributes ?? {};
    console.log(`  id=${i.id}  state=${a.state}  appStoreState=${a.appStoreState}`);
  }
  console.log('');

  // 🔴 許可方式。「公開系でない」ではなく「PREPARE_FOR_SUBMISSION である」ことを要求する。
  const editable = all.filter((i) => {
    const a = i.attributes ?? {};
    if (PUBLISHED.includes(a.state) || PUBLISHED.includes(a.appStoreState)) return false;
    return a.state === 'PREPARE_FOR_SUBMISSION' || a.appStoreState === 'PREPARE_FOR_SUBMISSION';
  });
  if (editable.length !== 1) {
    fail(
      `編集可能な appInfo が ${editable.length} 件（1件であるべき）。`,
      '0件なら下書きバージョンが無い（先に asc_prepare_version.mjs で作る）。2件以上なら手で確認すること。',
    );
  }
  const target = editable[0];
  console.log(`=== 書き込み先 ===\n  appInfo id=${target.id}（PREPARE_FOR_SUBMISSION＝次の提出用）\n`);

  const locs = await api('GET', `/v1/appInfos/${target.id}/appInfoLocalizations?limit=20`);
  const loc = (locs.json?.data ?? []).find((l) => l.attributes?.locale === LOCALE);
  if (!loc) fail(`${LOCALE} のローカライズが無い`, locs.text?.slice(0, 300));

  const before = loc.attributes ?? {};
  console.log('=== 現在の値 ===');
  console.log(`  name     = ${JSON.stringify(before.name)}`);
  console.log(`  subtitle = ${JSON.stringify(before.subtitle)}`);
  console.log('');

  if (before.name === NAME && before.subtitle === SUBTITLE) {
    console.log('✅ 既に同じ値。何もしない（冪等）。');
    return;
  }

  if (!APPLY) {
    console.log('=== [dry-run] 実行すると次のようになる ===');
    console.log(`  name     : ${JSON.stringify(before.name)}\n           → ${JSON.stringify(NAME)}`);
    console.log(`  subtitle : ${JSON.stringify(before.subtitle)}\n           → ${JSON.stringify(SUBTITLE)}`);
    console.log('');
    console.log('  公開中の掲載（1.1.1）は変わらない。新バージョンが承認・リリースされた時点で切り替わる。');
    console.log('  実行するには末尾に apply を指定すること。');
    return;
  }

  // name / subtitle 以外は送らない。privacyPolicyUrl 等を巻き込まないため。
  const r = await api('PATCH', `/v1/appInfoLocalizations/${loc.id}`, {
    data: {
      type: 'appInfoLocalizations',
      id: loc.id,
      attributes: { name: NAME, subtitle: SUBTITLE },
    },
  });
  if (r.status !== 200) fail(`PATCH 失敗 HTTP ${r.status}`, r.text?.slice(0, 500));
  console.log(`  PATCH → HTTP ${r.status}`);

  // 読み直して、実際に入ったことを確認する（送ったつもりで入っていない事故を防ぐ）。
  const after = await api('GET', `/v1/appInfoLocalizations/${loc.id}`);
  const x = after.json?.data?.attributes ?? {};
  console.log('\n=== 検証（読み直し）===');
  console.log(`  name     = ${JSON.stringify(x.name)}     ${x.name === NAME ? '✅' : '❌'}`);
  console.log(`  subtitle = ${JSON.stringify(x.subtitle)} ${x.subtitle === SUBTITLE ? '✅' : '❌'}`);
  if (x.name !== NAME || x.subtitle !== SUBTITLE) fail('読み直しが一致しない。ASC の画面で確認すること。');
  console.log('\n🎉 アプリ名・サブタイトルを差し替えた（公開中の掲載は無傷）。');
}

main().catch((e) => fail(String(e?.stack || e)));
