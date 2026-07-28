// サブスク膠着の「安全に試せる唯一の一手」。
//
// やること: **新しい** reviewSubmission を作り、そこへ subscriptionVersion /
//           subscriptionGroupVersion を追加できるかを試す（POST のみ）。
//           ASC API 4.4.1 で subscriptionVersion 関連付けが追加されたため、
//           以前「不可能」とされた経路が現在は通る可能性がある。
//
// やらないこと（コードレベルで禁止）:
//   * 既存の提出物 755e8857 には一切触らない（DELETE も PATCH もしない）
//   * 公開中の appStoreVersion 7824865b には一切触らない
//   * submitted:true にしない（=Appleに送らない。あくまで「入るか」を試すだけ）
//   * canceled:true にしない
//
// 失敗した場合: POST が 4xx を返すだけで、状態は変わらない。
// 成功した場合: サブスクを載せる箱ができる（提出は別途・オーナー判断）。
//
// Usage: node asc_sub_attach_try.mjs <p8> <keyId> <issuerId> <bundleId>
import fs from 'node:fs';
import crypto from 'node:crypto';

const FORBIDDEN_SUBMISSION = '755e8857-3ab8-421d-bdc1-e4642569acb4'; // 膠着中。触ると公開中アプリを失いうる
const FORBIDDEN_VERSION = '7824865b-b21f-4ce3-b76d-3da9ad85bb73';    // 公開中の 1.0

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
async function call(method, p, body) {
  // 安全装置: 許可するメソッドは GET と POST のみ。DELETE/PATCH/PUT は物理的に投げられない。
  if (!['GET', 'POST'].includes(method)) throw new Error(`禁止メソッド: ${method}`);
  // 安全装置: 禁止IDがURLにもボディにも含まれないこと。
  const payload = body ? JSON.stringify(body) : '';
  for (const bad of [FORBIDDEN_SUBMISSION, FORBIDDEN_VERSION]) {
    if (p.includes(bad) || payload.includes(bad)) throw new Error(`禁止ID ${bad} に触れようとした。中止。`);
  }
  const res = await fetch(BASE + p, {
    method,
    headers: { Authorization: 'Bearer ' + jwt(), 'Content-Type': 'application/json' },
    body: body ? payload : undefined,
  });
  const t = await res.text(); let j = null; try { j = t ? JSON.parse(t) : null; } catch {}
  return { status: res.status, json: j, text: t };
}
const errOf = (r) => (r.json?.errors ?? []).map((e) => `[${e.status} ${e.code}] ${e.title} — ${e.detail ?? ''}`).join('\n      ');

(async () => {
  const apps = await call('GET', `/v1/apps?filter[bundleId]=${encodeURIComponent(BUNDLE_ID)}`);
  const appId = apps.json.data[0].id;

  // 対象の version リソースを取得
  const groups = await call('GET', `/v1/apps/${appId}/subscriptionGroups?limit=10`);
  const gid = groups.json.data[0].id;
  const gv = await call('GET', `/v1/subscriptionGroups/${gid}/versions?limit=5`);
  const groupVersionId = gv.json?.data?.[0]?.id;
  const subs = await call('GET', `/v1/subscriptionGroups/${gid}/subscriptions?limit=20`);
  const subVersions = [];
  for (const s of subs.json?.data ?? []) {
    const sv = await call('GET', `/v1/subscriptions/${s.id}/versions?limit=5`);
    const v = sv.json?.data?.[0];
    if (v) subVersions.push({ productId: s.attributes.productId, id: v.id, state: v.attributes?.state });
  }
  console.log('対象:');
  console.log(`  groupVersion ${groupVersionId} (${gv.json?.data?.[0]?.attributes?.state})`);
  for (const v of subVersions) console.log(`  subVersion   ${v.id} ${v.productId} (${v.state})`);

  // 既存の下書き提出物があれば再利用（無ければ新規作成）
  console.log('\n--- STEP A: 使える下書きの提出物を探す/作る ---');
  const list = await call('GET', `/v1/apps/${appId}/reviewSubmissions?limit=20`);
  let draft = (list.json?.data ?? []).find(
    (s) => s.id !== FORBIDDEN_SUBMISSION && !s.attributes.submittedDate &&
      !['COMPLETE', 'CANCELED', 'CANCELING'].includes(s.attributes.state));
  if (draft) {
    console.log(`  既存の下書きを再利用: ${draft.id} (state=${draft.attributes.state})`);
  } else {
    const created = await call('POST', '/v1/reviewSubmissions', {
      data: {
        type: 'reviewSubmissions',
        attributes: { platform: 'IOS' },
        relationships: { app: { data: { type: 'apps', id: appId } } },
      },
    });
    console.log(`  POST /v1/reviewSubmissions → HTTP ${created.status}`);
    if (created.status >= 400) {
      console.log(`      ${errOf(created)}`);
      console.log('\n❌ 新しい提出物を作れない。＝膠着中の提出物を片付けない限り前に進めない。');
      console.log('   → 自力ルートはここで終わり。Apple への問い合わせが必要。');
      return;
    }
    draft = created.json.data;
    console.log(`  ✅ 新規作成: ${draft.id}`);
  }

  // 本番: subscriptionVersion / subscriptionGroupVersion を item 化できるか
  console.log('\n--- STEP B: サブスクを新しい箱に入れられるか（本命） ---');
  const targets = [
    { label: 'subscriptionGroupVersions', id: groupVersionId, key: 'subscriptionGroupVersion' },
    ...subVersions.map((v) => ({ label: 'subscriptionVersions', id: v.id, key: 'subscriptionVersion', name: v.productId })),
  ];
  let ok = 0;
  for (const t of targets) {
    const res = await call('POST', '/v1/reviewSubmissionItems', {
      data: {
        type: 'reviewSubmissionItems',
        relationships: {
          reviewSubmission: { data: { type: 'reviewSubmissions', id: draft.id } },
          [t.key]: { data: { type: t.label, id: t.id } },
        },
      },
    });
    const tag = t.name ? `${t.key}(${t.name})` : t.key;
    console.log(`  POST item ${tag} → HTTP ${res.status}`);
    if (res.status >= 400) console.log(`      ${errOf(res)}`);
    else ok++;
  }

  console.log('\n--- 結果 ---');
  console.log(`  ${ok}/${targets.length} 件を新しい提出物に載せられました。`);
  if (ok === targets.length) {
    console.log('  🎉 突破口あり。あとは v1.0.2 のバージョンを同じ箱に入れて提出すれば通る見込み。');
    console.log('     ※ このスクリプトは提出（submitted:true）はしていません。');
  } else if (ok === 0) {
    console.log('  ❌ 1件も載らない。IN_REVIEW で固着しているため新しい箱にも入らない。');
    console.log('     → 自力では解けない。Apple への問い合わせが必要。');
  } else {
    console.log('  ⚠️ 一部だけ載った。上のエラー内容を確認すること。');
  }
  console.log(`\n使用した下書き提出物: ${draft.id}（未提出のまま。Appleには送っていません）`);
})().catch((e) => { console.error('ERR', e.message); process.exit(1); });
