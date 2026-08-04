// 提出物の下ごしらえ: 新バージョン(1.0.2)を新しい提出物に入れ、そこへサブスク3点も
// 載せられるかを試す。**提出（submitted:true）はしない**。
//
// なぜ試す価値があるのか:
//   前回(2026-07-28)にサブスクを載せようとして 409 で弾かれたときは、
//   「アプリバージョンが1つも入っていない空の提出物」に載せようとしていた。
//   Apple のポリシーは「**初回の自動更新サブスクは新しいアプリバージョンと一緒に提出**」なので、
//   アプリバージョンが入った提出物なら結果が変わる可能性がある（未検証の経路）。
//
// 安全策（コードで強制）:
//   * 許可メソッドは GET / POST のみ（DELETE / PATCH は投げられない）
//   * 膠着中の提出物 755e8857 / 公開中の appStoreVersion 7824865b に触れたら即中止
//   * submitted:true / canceled:true は一切書かない（Apple には送らない）
//
// Usage: node asc_build_submission.mjs <p8> <keyId> <issuerId> <bundleId> <versionString>
import fs from 'node:fs';
import crypto from 'node:crypto';

const FORBIDDEN_SUBMISSION = '755e8857-3ab8-421d-bdc1-e4642569acb4';
const FORBIDDEN_VERSION = '7824865b-b21f-4ce3-b76d-3da9ad85bb73';

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

  // 対象バージョン（公開中ではないこと＝下書きであることを必ず確認する）
  const vers = await call('GET', `/v1/apps/${appId}/appStoreVersions?limit=20`);
  const target = (vers.json?.data ?? []).find((v) => v.attributes.versionString === VERSION);
  if (!target) throw new Error(`バージョン ${VERSION} が見つからない`);
  if (target.id === FORBIDDEN_VERSION) throw new Error('公開中バージョンを対象にしようとした。中止。');
  console.log(`対象バージョン: ${VERSION} id=${target.id} state=${target.attributes.appStoreState}/${target.attributes.appVersionState}`);
  const build = await call('GET', `/v1/appStoreVersions/${target.id}/build`);
  console.log(`  紐付いたビルド: ${build.json?.data?.attributes?.version ?? '**未紐付け**'}`);

  // サブスクの version リソース
  const groups = await call('GET', `/v1/apps/${appId}/subscriptionGroups?limit=10`);
  const gid = groups.json.data[0].id;
  const gv = await call('GET', `/v1/subscriptionGroups/${gid}/versions?limit=5`);
  const groupVersionId = gv.json?.data?.[0]?.id;
  const subs = (await call('GET', `/v1/subscriptionGroups/${gid}/subscriptions?limit=20`)).json.data;
  const subVersions = [];
  for (const s of subs) {
    const sv = await call('GET', `/v1/subscriptions/${s.id}/versions?limit=5`);
    const v = sv.json?.data?.[0];
    if (v) subVersions.push({ productId: s.attributes.productId, id: v.id, state: v.attributes?.state });
  }
  console.log(`  groupVersion ${groupVersionId} (${gv.json?.data?.[0]?.attributes?.state})`);
  for (const v of subVersions) console.log(`  subVersion   ${v.id} ${v.productId} (${v.state})`);

  console.log('\n--- STEP A: 使う下書きの提出物 ---');
  const list = await call('GET', `/v1/apps/${appId}/reviewSubmissions?limit=20`);
  let draft = (list.json?.data ?? []).find(
    (s) => s.id !== FORBIDDEN_SUBMISSION && !s.attributes.submittedDate &&
      !['COMPLETE', 'CANCELED', 'CANCELING'].includes(s.attributes.state));
  if (draft) {
    console.log(`  既存の下書きを再利用: ${draft.id} (${draft.attributes.state})`);
  } else {
    const created = await call('POST', '/v1/reviewSubmissions', {
      data: {
        type: 'reviewSubmissions',
        attributes: { platform: 'IOS' },
        relationships: { app: { data: { type: 'apps', id: appId } } },
      },
    });
    console.log(`  POST /v1/reviewSubmissions → HTTP ${created.status}`);
    if (created.status >= 400) { console.log(`      ${errOf(created)}`); process.exit(1); }
    draft = created.json.data;
    console.log(`  ✅ 新規作成: ${draft.id}`);
  }

  console.log('\n--- STEP B: アプリバージョンを箱に入れる ---');
  const existing = await call('GET', `/v1/reviewSubmissions/${draft.id}/items?limit=30&include=appStoreVersion`);
  const already = (existing.json?.data ?? []).some(
    (it) => it.relationships?.appStoreVersion?.data?.id === target.id);
  if (already) {
    console.log('  既に入っている。スキップ。');
  } else {
    const res = await call('POST', '/v1/reviewSubmissionItems', {
      data: {
        type: 'reviewSubmissionItems',
        relationships: {
          reviewSubmission: { data: { type: 'reviewSubmissions', id: draft.id } },
          appStoreVersion: { data: { type: 'appStoreVersions', id: target.id } },
        },
      },
    });
    console.log(`  POST item appStoreVersion → HTTP ${res.status}`);
    if (res.status >= 400) { console.log(`      ${errOf(res)}`); process.exit(1); }
    console.log('  ✅ 入った');
  }

  console.log('\n--- STEP C: ★本命 サブスク3点を同じ箱に入れられるか ---');
  const targets = [
    { label: 'subscriptionGroupVersions', key: 'subscriptionGroupVersion', id: groupVersionId, name: 'グループ' },
    ...subVersions.map((v) => ({ label: 'subscriptionVersions', key: 'subscriptionVersion', id: v.id, name: v.productId })),
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
    console.log(`  ${t.name} → HTTP ${res.status}`);
    if (res.status >= 400) console.log(`      ${errOf(res)}`);
    else ok++;
  }

  console.log('\n--- 箱の最終的な中身 ---');
  for (const inc of ['appStoreVersion', 'subscriptionVersion', 'subscriptionGroupVersion']) {
    const it = await call('GET', `/v1/reviewSubmissions/${draft.id}/items?limit=30&include=${inc}`);
    if (it.status !== 200) continue;
    for (const item of it.json?.data ?? []) {
      const rel = item.relationships?.[inc]?.data;
      if (rel) console.log(`  item state=${item.attributes?.state} → ${inc}=${rel.id}`);
    }
  }

  console.log('\n=== 結果 ===');
  console.log(`  サブスク: ${ok}/${targets.length} 件を同梱できました。`);
  if (ok === targets.length) {
    console.log('  🎉🎉 突破成功。アプリ本体＋サブスク3点が1つの箱に揃いました。');
    console.log('     → あとはオーナーが ASC の UI から「審査へ提出」を押すだけ。');
  } else {
    console.log('  ⚠️ サブスクは同梱できませんでした（固着継続）。');
    console.log('     → アプリ本体だけを提出する。marketingUrl と説明文の修正は取れる。');
    console.log('     → サブスクは Apple のサポートが解放してくれるのを待つ。');
  }
  console.log(`\n使用した提出物: ${draft.id}（**未提出**。Apple には送っていません）`);
})().catch((e) => { console.error('ERR', e.message); process.exit(1); });
