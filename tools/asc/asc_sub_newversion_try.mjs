// 膠着突破の第2案: サブスクの「新しいバージョン」を作って、それを箱に入れる。
//
// 発想: 止まっているのは subscriptionVersion(version=1) であって、subscription 本体
//       (productId) ではない。Apple には POST /v1/subscriptionVersions
//       「現在のローカライズ情報と審査用画像を引き継いだ下書きバージョンを作る」API があり、
//       state に REPLACED_WITH_NEW_VERSION（新版に置き換えられた）が存在する。
//       ＝新版を作れば、それが新品の下書きとして箱に入る可能性がある。
//
// やらないこと（コードで強制）:
//   * メソッドは GET と POST のみ（DELETE/PATCH/PUT は例外で停止）
//   * 膠着中の提出物 755e8857 / 公開中の appStoreVersion 7824865b に触れない
//   * subscription 本体（商品ID）は作らない・消さない・変更しない
//   * submitted:true にしない（Appleには送らない）
//
// Usage: node asc_sub_newversion_try.mjs <p8> <keyId> <issuerId> <bundleId>
import fs from 'node:fs';
import crypto from 'node:crypto';

const FORBIDDEN_SUBMISSION = '755e8857-3ab8-421d-bdc1-e4642569acb4';
const FORBIDDEN_VERSION = '7824865b-b21f-4ce3-b76d-3da9ad85bb73';

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
  if (!['GET', 'POST'].includes(method)) throw new Error(`禁止メソッド: ${method}`);
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
  const groups = await call('GET', `/v1/apps/${appId}/subscriptionGroups?limit=10`);
  const gid = groups.json.data[0].id;
  const subs = (await call('GET', `/v1/subscriptionGroups/${gid}/subscriptions?limit=20`)).json.data;

  console.log('=== STEP 1: サブスクグループの新しいバージョンを作れるか ===');
  const newIds = { group: null, subs: [] };
  const gRes = await call('POST', '/v1/subscriptionGroupVersions', {
    data: {
      type: 'subscriptionGroupVersions',
      relationships: { subscriptionGroup: { data: { type: 'subscriptionGroups', id: gid } } },
    },
  });
  console.log(`  POST /v1/subscriptionGroupVersions → HTTP ${gRes.status}`);
  if (gRes.status >= 400) console.log(`      ${errOf(gRes)}`);
  else { newIds.group = gRes.json.data.id; console.log(`      ✅ 新バージョン ${newIds.group} state=${gRes.json.data.attributes?.state}`); }

  console.log('\n=== STEP 2: 各サブスクの新しいバージョンを作れるか ===');
  for (const s of subs) {
    const res = await call('POST', '/v1/subscriptionVersions', {
      data: {
        type: 'subscriptionVersions',
        relationships: { subscription: { data: { type: 'subscriptions', id: s.id } } },
      },
    });
    console.log(`  ${s.attributes.productId} → HTTP ${res.status}`);
    if (res.status >= 400) console.log(`      ${errOf(res)}`);
    else {
      newIds.subs.push({ productId: s.attributes.productId, id: res.json.data.id });
      console.log(`      ✅ 新バージョン ${res.json.data.id} state=${res.json.data.attributes?.state}`);
    }
  }

  if (!newIds.group && newIds.subs.length === 0) {
    console.log('\n❌ 新しいバージョンを1つも作れない。この経路も塞がっている。');
    console.log('   → 自力ルートは完全に終わり。Apple への問い合わせが必須。');
    return;
  }

  console.log('\n=== STEP 3: 作った新バージョンを、新しい箱に入れられるか（本命） ===');
  const list = await call('GET', `/v1/apps/${appId}/reviewSubmissions?limit=20`);
  const draft = (list.json?.data ?? []).find(
    (s) => s.id !== FORBIDDEN_SUBMISSION && !s.attributes.submittedDate &&
      !['COMPLETE', 'CANCELED', 'CANCELING'].includes(s.attributes.state));
  if (!draft) { console.log('  使える下書きの箱が無い。中止。'); return; }
  console.log(`  使う箱: ${draft.id}`);

  const targets = [];
  if (newIds.group) targets.push({ label: 'subscriptionGroupVersions', key: 'subscriptionGroupVersion', id: newIds.group, name: 'グループ' });
  for (const v of newIds.subs) targets.push({ label: 'subscriptionVersions', key: 'subscriptionVersion', id: v.id, name: v.productId });

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
    console.log(`  ${t.name} → HTTP ${res.status}`);
    if (res.status >= 400) console.log(`      ${errOf(res)}`);
    else ok++;
  }

  console.log('\n=== STEP 4: 商品が無傷か確認（GETのみ）===');
  for (const s of subs) {
    const cur = await call('GET', `/v1/subscriptions/${s.id}`);
    console.log(`  ${s.attributes.productId} state=${cur.json?.data?.attributes?.state}`);
    const vs = await call('GET', `/v1/subscriptions/${s.id}/versions?limit=10`);
    for (const v of vs.json?.data ?? []) console.log(`     version=${v.attributes?.version} state=${v.attributes?.state} id=${v.id}`);
  }

  console.log('\n--- 結果 ---');
  console.log(`  ${ok}/${targets.length} 件を新しい箱に載せられました。`);
  if (ok === targets.length && ok > 0) {
    console.log('  🎉🎉 突破しました。あとは v1.0.2 を同じ箱に入れて提出すれば通る見込み。');
    console.log('     ※ 提出（submitted:true）はしていません。オーナーの判断待ちです。');
  } else if (ok === 0) {
    console.log('  ❌ 新バージョンでも載らない。Apple への問い合わせが必須。');
  }
})().catch((e) => { console.error('ERR', e.message); process.exit(1); });
