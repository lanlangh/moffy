// サブスク膠着の精密診断。**GET のみ**。書き込みは1回も行わない。
//
// 目的: 「古い提出物から外さずに、新しい提出物へサブスクを載せられるか」を、
//       推測でなく Apple の実データで判定する。判定できれば、危険な片道操作を
//       踏まずに突破口があるかが分かる。
//
// Usage: node asc_sub_probe.mjs <p8> <keyId> <issuerId> <bundleId>
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
  const t = await res.text(); let j = null; try { j = t ? JSON.parse(t) : null; } catch {}
  return { status: res.status, json: j, text: t };
}
const errOf = (r) => (r.json?.errors ?? []).map((e) => `${e.status} ${e.code} ${e.title}: ${e.detail ?? ''}`).join(' | ');

(async () => {
  const apps = await get(`/v1/apps?filter[bundleId]=${encodeURIComponent(BUNDLE_ID)}`);
  const appId = apps.json.data[0].id;
  console.log(`app id=${appId}\n`);

  console.log('=== 1. アプリバージョン（受け皿になりうる下書きがあるか）===');
  const vers = await get(`/v1/apps/${appId}/appStoreVersions?limit=20`);
  for (const v of vers.json?.data ?? []) {
    const a = v.attributes;
    console.log(`  ${a.versionString}  appStoreState=${a.appStoreState}  appVersionState=${a.appVersionState}  id=${v.id}`);
  }
  const hasDraft = (vers.json?.data ?? []).some((v) =>
    ['PREPARE_FOR_SUBMISSION', 'DEVELOPER_REJECTED', 'REJECTED'].includes(v.attributes.appVersionState));
  console.log(`  → 編集可能な下書きバージョン: ${hasDraft ? 'あり' : '**なし**（新規作成が必要）'}\n`);

  console.log('=== 2. サブスクの version リソース（本当の状態機械はこちら）===');
  const groups = await get(`/v1/apps/${appId}/subscriptionGroups?limit=10`);
  for (const g of groups.json?.data ?? []) {
    console.log(`  グループ ${g.id} ref=${g.attributes.referenceName}`);
    const gv = await get(`/v1/subscriptionGroups/${g.id}/versions?limit=10`);
    if (gv.status !== 200) console.log(`    versions: HTTP ${gv.status} ${errOf(gv)}`);
    for (const v of gv.json?.data ?? []) {
      console.log(`    groupVersion id=${v.id} state=${v.attributes?.state} version=${v.attributes?.version ?? '-'}`);
    }
    const subs = await get(`/v1/subscriptionGroups/${g.id}/subscriptions?limit=20`);
    for (const s of subs.json?.data ?? []) {
      console.log(`  ● ${s.attributes.productId} id=${s.id} state=${s.attributes.state}`);
      const sv = await get(`/v1/subscriptions/${s.id}/versions?limit=10`);
      if (sv.status !== 200) console.log(`    versions: HTTP ${sv.status} ${errOf(sv)}`);
      for (const v of sv.json?.data ?? []) {
        console.log(`    subVersion id=${v.id} state=${v.attributes?.state} version=${v.attributes?.version ?? '-'}`);
      }
    }
  }
  console.log('');

  console.log('=== 3. 提出物と、その中身が何を指しているか（関連まで展開）===');
  const subsList = await get(`/v1/apps/${appId}/reviewSubmissions?limit=20`);
  for (const s of subsList.json?.data ?? []) {
    const a = s.attributes;
    console.log(`\n  submission ${s.id}`);
    console.log(`    state=${a.state} submitted=${a.submittedDate ?? '-'} platform=${a.platform}`);
    // include を複数試す（対応していない include はエラーになるので個別に落とす）
    for (const inc of ['appStoreVersion', 'subscriptionVersion', 'subscriptionGroupVersion']) {
      const it = await get(`/v1/reviewSubmissions/${s.id}/items?limit=30&include=${inc}`);
      if (it.status !== 200) { console.log(`    [include=${inc}] HTTP ${it.status} ${errOf(it)}`); continue; }
      for (const item of it.json?.data ?? []) {
        const rel = item.relationships?.[inc]?.data;
        if (rel) console.log(`    item state=${item.attributes?.state} → ${inc}=${rel.id}`);
      }
    }
  }
  console.log('');

  console.log('=== 4. 新しい提出物を作れる状態か（GETで判断できる材料）===');
  const open = (subsList.json?.data ?? []).filter((s) =>
    !['COMPLETE', 'CANCELED'].includes(s.attributes.state));
  console.log(`  未完了の提出物: ${open.length}件`);
  for (const s of open) console.log(`    ${s.id} state=${s.attributes.state}`);
  console.log('  → Appleは1プラットフォームにつき進行中の提出物を1つしか許さない場合がある。');
  console.log('    上が0件なら新規作成できる見込み。1件以上ならそれを片付けない限り作れない可能性が高い。');

  console.log('\n=== 5. 許可されている操作の確認（GETを投げてエラー文から読む・状態は変わらない）===');
  const firstItem = await get(`/v1/apps/${appId}/reviewSubmissions?limit=1`);
  const sid = firstItem.json?.data?.[0]?.id;
  if (sid) {
    const items = await get(`/v1/reviewSubmissions/${sid}/items?limit=1`);
    const iid = items.json?.data?.[0]?.id;
    if (iid) {
      const probe = await get(`/v1/reviewSubmissionItems/${iid}`);
      console.log(`  GET /v1/reviewSubmissionItems/{id} → HTTP ${probe.status}`);
      console.log(`    ${errOf(probe) || '(エラーなし)'}`);
    }
  }
  console.log('\n※ このスクリプトは GET しか行っていません。状態は一切変更していません。');
})().catch((e) => { console.error('ERR', e.message); process.exit(1); });
