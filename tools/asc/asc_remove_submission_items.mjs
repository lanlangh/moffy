// App Store Connect — 提出物から「指定した項目だけ」を外す（Node 24 / 依存なし）
//
// Usage:
//   node asc_remove_submission_items.mjs <p8> <keyId> <issuerId> <submissionId> <itemIds> [apply]
//   itemIds = カンマ区切りの item ID（base64 の完全な ID）。**省略不可**
//   末尾の apply を付けないと dry-run（読むだけ・既定）
//
// ■ なぜ専用の道具を作ったか（2026-08-24）
//   Apple デベロッパサポート（ケース 20000121488355・野村氏）から明示の指示が来た:
//     「弊社側で該当のアイテムを削除する操作はできかねます。サポート記事
//       『審査からの提出物の削除』をご参照の上、ご自身で対象のアプリ内課金を
//       削除していただきますようお願いいたします」
//   これが _safety_guard.mjs の封印解除条件（= Apple から明示の指示があったとき）に該当する。
//
//   ただし Apple の記事が案内する操作は2つとも**危険**:
//     (1)「このバージョンを審査から削除」→ 提出物の**他の項目すべて**が削除され、
//         アプリが「デベロッパにより却下済み」になる
//     (2)「提出をキャンセル」→ **アプリバージョンが含まれていた場合**、同じく却下済みになる
//   固着提出物 755e8857 には、**公開中の appStoreVersion 1.0 を参照する item が
//   state=REMOVED のまま残っている**。Apple の記事に「REMOVED は対象外」という但し書きは無い。
//   ＝ (1)(2) はどちらも公開中の iOS を取り下げる経路になりうる。
//
//   記事の補足に「App Store Connect API 経由での削除も可能（App Review サブミッション項目の削除）」
//   とあるので、**サブスクの item だけを外し、アプリバージョンの item には一切触れない**
//   この道具を作った。
//
// ■ 既存の asc_free_version_and_add.mjs を使わない理由
//   あれは全提出物を走査して条件に合う item を無条件 DELETE する。
//   COMPLETE の提出物も除外しないため、**公開中リリースを承認した提出物の
//   state=APPROVED な item にも DELETE が飛ぶ**（本人のコメントにそう書いてある）。
//
// ■ この道具の安全装置
//   * 消す item を**1つずつ明示**させる（省略すると即中止）
//   * **アプリバージョンの item（type=6）は、指定されていても拒否して中止**
//   * 指定された提出物**以外**には一切アクセスしない
//   * DELETE 以外の破壊的メソッドを実装しない（キャンセルもバージョン削除もできない）
//   * dry-run が既定。実行後は必ず読み直して結果を表示する
import fs from 'node:fs';
import crypto from 'node:crypto';

const [, , P8, KEY_ID, ISSUER, SUBMISSION_ID, ITEM_IDS_RAW, MODE = 'dry-run'] = process.argv;
const APPLY = MODE === 'apply';
const ITEM_IDS = (ITEM_IDS_RAW || '').split(',').map((s) => s.trim()).filter(Boolean);

if (!P8 || !KEY_ID || !ISSUER || !SUBMISSION_ID) {
  console.error('args: <p8> <keyId> <issuerId> <submissionId> <itemIds(カンマ区切り)> [apply]');
  process.exit(2);
}

const fail = (m, extra) => {
  console.error('❌ ' + m);
  if (extra) console.error('   ' + extra);
  process.exit(1);
};

if (ITEM_IDS.length === 0) {
  fail(
    '消す item の ID が指定されていません。',
    'この道具は「消すものを1つずつ明示する」以外の使い方をしません。まず dry-run で一覧を見てください。',
  );
}

const b64url = (b) =>
  Buffer.from(b).toString('base64').replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_');

function makeJwt() {
  const pem = fs.readFileSync(P8, 'utf8');
  const now = Math.floor(Date.now() / 1000);
  const input =
    b64url(JSON.stringify({ alg: 'ES256', kid: KEY_ID, typ: 'JWT' })) + '.' +
    b64url(JSON.stringify({ iss: ISSUER, iat: now, exp: now + 600, aud: 'appstoreconnect-v1' }));
  return input + '.' + b64url(crypto.sign('SHA256', Buffer.from(input), {
    key: pem, dsaEncoding: 'ieee-p1363',
  }));
}

const BASE = 'https://api.appstoreconnect.apple.com';

async function api(method, path) {
  // 🔴 この道具が投げてよいのは GET と、item への DELETE だけ。
  // 提出物そのものへの DELETE / PATCH（キャンセル）は**実装しない**。
  if (method === 'DELETE' && !path.startsWith('/v1/reviewSubmissionItems/')) {
    fail(`この道具は item 以外に DELETE を投げません: ${path}`);
  }
  if (!['GET', 'DELETE'].includes(method)) fail(`禁止メソッド: ${method}`);

  const res = await fetch(BASE + path, {
    method,
    headers: { Authorization: 'Bearer ' + makeJwt(), 'Content-Type': 'application/json' },
  });
  const text = await res.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { /* 非JSON */ }
  return { status: res.status, json, text };
}

/** item の ID は `submissionId|type|internalId` を base64 で符号化したもの。 */
function decodeItem(id) {
  try {
    const pad = id + '='.repeat((-id.length % 4 + 4) % 4);
    return Buffer.from(pad, 'base64').toString('utf8');
  } catch {
    return null;
  }
}

const TYPE_NAMES = {
  6: 'アプリバージョン',
  18: 'サブスクリプション',
  19: 'サブスクリプショングループ',
};

/** アプリバージョンの item は絶対に消させない。 */
const FORBIDDEN_TYPE = '6';

async function main() {
  console.log(`=== 提出物 ${SUBMISSION_ID} の中身 ===`);
  const items = await api('GET', `/v1/reviewSubmissions/${SUBMISSION_ID}/items?limit=30`);
  if (items.status !== 200) fail(`項目の取得に失敗 HTTP ${items.status}`, items.text?.slice(0, 300));

  const all = items.json?.data ?? [];
  if (all.length === 0) fail('項目が1件もありません。ID を間違えていませんか。');

  const info = new Map();
  for (const it of all) {
    const dec = decodeItem(it.id) || '';
    const parts = dec.split('|');
    const type = parts.length > 1 ? parts[1] : '?';
    const kind = TYPE_NAMES[type] || `不明(type=${type})`;
    const state = it.attributes?.state;
    info.set(it.id, { type, kind, state });
    const mark = ITEM_IDS.includes(it.id) ? ' ← 削除対象' : '';
    console.log(`  ${kind.padEnd(22)} state=${String(state).padEnd(18)}${mark}`);
  }
  console.log('');

  // 指定された ID が実在するか
  const missing = ITEM_IDS.filter((id) => !info.has(id));
  if (missing.length) {
    fail(
      `指定された item がこの提出物にありません: ${missing.length}件`,
      '別の提出物の item を指定していないか確認してください。',
    );
  }

  // 🔴 アプリバージョンの item が混ざっていたら、1件も消さずに中止する
  const forbidden = ITEM_IDS.filter((id) => info.get(id).type === FORBIDDEN_TYPE);
  if (forbidden.length) {
    fail(
      `削除対象に**アプリバージョン**の item が含まれています（${forbidden.length}件）。`,
      'これは公開中のアプリを取り下げる経路になりうるため、この道具では消せません。1件も削除せず中止しました。',
    );
  }

  console.log('=== 削除対象 ===');
  for (const id of ITEM_IDS) {
    const x = info.get(id);
    console.log(`  ${x.kind}  state=${x.state}`);
  }
  console.log('');
  console.log(`  合計 ${ITEM_IDS.length} 件。アプリバージョンの item には触れません。`);
  console.log('');

  if (!APPLY) {
    console.log('[dry-run] 読むだけで終了しました。');
    console.log('          実行するには末尾に apply を指定してください。');
    console.log('');
    console.log('⚠️ 実行は取り消せません。Apple の指示（ケース 20000121488355）に基づく操作です。');
    return;
  }

  console.log('--- 削除を実行 ---');
  let ok = 0;
  const results = [];
  for (const id of ITEM_IDS) {
    const x = info.get(id);
    const del = await api('DELETE', `/v1/reviewSubmissionItems/${id}`);
    const good = del.status >= 200 && del.status < 300;
    if (good) ok += 1;
    results.push({ kind: x.kind, status: del.status, body: del.text?.slice(0, 200) });
    console.log(`  ${good ? '✅' : '❌'} ${x.kind}  HTTP ${del.status}` +
      (good ? '' : `  ${del.text?.slice(0, 200)}`));
  }
  console.log('');
  console.log(`完了: ${ok}/${ITEM_IDS.length} 件`);

  // 書いたら読み直す（このリポジトリの運用ルール）
  console.log('');
  console.log('=== 検証（読み直し）===');
  const after = await api('GET', `/v1/reviewSubmissions/${SUBMISSION_ID}/items?limit=30`);
  for (const it of after.json?.data ?? []) {
    const dec = decodeItem(it.id) || '';
    const type = dec.split('|')[1] || '?';
    console.log(`  ${(TYPE_NAMES[type] || type).padEnd(22)} state=${it.attributes?.state}`);
  }
  const sub = await api('GET', `/v1/reviewSubmissions/${SUBMISSION_ID}`);
  console.log(`  提出物そのもの: state=${sub.json?.data?.attributes?.state}`);
}

main().catch((e) => fail(String(e?.stack || e)));
