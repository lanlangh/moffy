// 2.1(a) 対応: サブスクを同梱してレビュー再提出する。
// mode=prepare … reviewSubmission を作り、バージョン＋サブスクを item 化して報告（提出しない）。
//   サブスクが item 化できなければ、作った submission を取り消して UI 手順にフォールバックさせる。
// mode=submit  … prepare 済みの submission を submitted=true で送信。
//
// Usage: node asc_resubmit_with_iap.mjs <p8> <keyId> <issuerId> <bundleId> <versionString> <mode>
import fs from 'node:fs';
import crypto from 'node:crypto';
const [, , P8, KEY_ID, ISSUER, BUNDLE_ID, VERSION, MODE = 'prepare'] = process.argv;
const b64url = (b) => Buffer.from(b).toString('base64').replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_');
function jwt() {
  const pem = fs.readFileSync(P8, 'utf8');
  const now = Math.floor(Date.now() / 1000);
  const si = b64url(JSON.stringify({ alg: 'ES256', kid: KEY_ID, typ: 'JWT' })) + '.' +
    b64url(JSON.stringify({ iss: ISSUER, iat: now, exp: now + 600, aud: 'appstoreconnect-v1' }));
  return si + '.' + b64url(crypto.sign('SHA256', Buffer.from(si), { key: pem, dsaEncoding: 'ieee-p1363' }));
}
const BASE = 'https://api.appstoreconnect.apple.com';
async function api(method, path, body) {
  const res = await fetch(BASE + path, {
    method, headers: { Authorization: 'Bearer ' + jwt(), 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  });
  const t = await res.text(); let j = null; try { j = t ? JSON.parse(t) : null; } catch {}
  return { status: res.status, json: j, text: t };
}
function errs(r) { return (r.json?.errors ?? []).map(e => `[${e.code}] ${e.title}: ${e.detail}`).join(' | ') || (r.text || '').slice(0, 300); }

(async () => {
  const apps = await api('GET', `/v1/apps?filter[bundleId]=${encodeURIComponent(BUNDLE_ID)}`);
  const appId = apps.json.data[0].id;
  const vers = await api('GET', `/v1/apps/${appId}/appStoreVersions?filter[versionString]=${encodeURIComponent(VERSION)}&limit=5`);
  const verId = vers.json.data[0].id;
  const vstate = vers.json.data[0].attributes.appStoreState ?? vers.json.data[0].attributes.appVersionState;
  console.log(`version ${VERSION} id=${verId} state=${vstate}`);

  // サブスクID取得
  const groups = await api('GET', `/v1/apps/${appId}/subscriptionGroups?limit=10`);
  const subIds = [];
  for (const g of groups.json?.data ?? []) {
    const subs = await api('GET', `/v1/subscriptionGroups/${g.id}/subscriptions?limit=20`);
    for (const s of subs.json?.data ?? []) subIds.push({ id: s.id, pid: s.attributes.productId, state: s.attributes.state });
  }
  console.log('サブスク:', subIds.map(s => `${s.pid}(${s.state})`).join(', '));

  if (MODE === 'submit') {
    // 既存の未送信 reviewSubmission を探して submit
    const list = await api('GET', `/v1/reviewSubmissions?filter[app]=${appId}&limit=20`);
    const open = (list.json?.data ?? []).find(s => s.attributes.state === 'READY_FOR_REVIEW' && !s.attributes.submittedDate);
    if (!open) { console.error('❌ 送信可能な未送信 reviewSubmission が無い（先に prepare を）'); process.exit(1); }
    const items = await api('GET', `/v1/reviewSubmissions/${open.id}/items?limit=30`);
    console.log(`送信対象 submission id=${open.id} items=${(items.json?.data ?? []).length}`);
    const sent = await api('PATCH', `/v1/reviewSubmissions/${open.id}`, { data: { type: 'reviewSubmissions', id: open.id, attributes: { submitted: true } } });
    if (sent.status !== 200) { console.error('❌ 送信失敗:', errs(sent)); process.exit(1); }
    const after = await api('GET', `/v1/reviewSubmissions/${open.id}`);
    console.log(`✅ 送信しました。state=${after.json?.data?.attributes?.state}`);
    return;
  }

  // ---- prepare ----
  // 既存の未送信 submission があれば再利用、なければ作る
  const list = await api('GET', `/v1/reviewSubmissions?filter[app]=${appId}&limit=20`);
  let sub = (list.json?.data ?? []).find(s => !['COMPLETE', 'CANCELING', 'CANCELED'].includes(s.attributes.state) && !s.attributes.submittedDate);
  if (sub) {
    console.log(`既存の未送信 submission を再利用 id=${sub.id} state=${sub.attributes.state}`);
  } else {
    const created = await api('POST', '/v1/reviewSubmissions', {
      data: { type: 'reviewSubmissions', attributes: { platform: 'IOS' }, relationships: { app: { data: { type: 'apps', id: appId } } } },
    });
    if (created.status !== 201) { console.error('❌ submission 作成失敗:', errs(created)); process.exit(1); }
    sub = created.json.data;
    console.log(`submission 作成 id=${sub.id}`);
  }
  const subId = sub.id;

  // 既存itemを確認
  const curItems = await api('GET', `/v1/reviewSubmissions/${subId}/items?limit=30`);
  const have = (curItems.json?.data ?? []);
  console.log(`現在の item 数=${have.length}`);

  // バージョンを item 化（未追加なら）
  async function addItem(rel) {
    return api('POST', '/v1/reviewSubmissionItems', {
      data: { type: 'reviewSubmissionItems', relationships: { reviewSubmission: { data: { type: 'reviewSubmissions', id: subId } }, ...rel } },
    });
  }
  // version
  const vres = await addItem({ appStoreVersion: { data: { type: 'appStoreVersions', id: verId } } });
  console.log(`version item: ${vres.status===201?'追加OK':('既存/失敗 '+errs(vres))}`);

  // subscriptions を item 化（キー名の候補を順に試す）
  let subAttachOk = true;
  for (const s of subIds) {
    let ok = false, lastErr = '';
    for (const key of ['subscription', 'inAppPurchase', 'inAppPurchaseV2']) {
      const type = key === 'subscription' ? 'subscriptions' : 'inAppPurchases';
      const r = await addItem({ [key]: { data: { type, id: s.id } } });
      if (r.status === 201) { console.log(`subscription item(${s.pid}): 追加OK (key=${key})`); ok = true; break; }
      lastErr = `key=${key}: ${errs(r)}`;
    }
    if (!ok) { console.log(`subscription item(${s.pid}): ❌ ${lastErr}`); subAttachOk = false; }
  }

  const finalItems = await api('GET', `/v1/reviewSubmissions/${subId}/items?limit=30`);
  console.log(`\n最終 item 数=${(finalItems.json?.data ?? []).length}（バージョン1＋サブスク2＝計3が理想）`);

  if (!subAttachOk) {
    // サブスクを API で同梱できない → この test submission が UI 提出を塞がないよう取り消す
    const cancel = await api('PATCH', `/v1/reviewSubmissions/${subId}`, { data: { type: 'reviewSubmissions', id: subId, attributes: { canceled: true } } });
    console.log(`\n⚠️ サブスクを API で item 化できませんでした。作成した submission を取り消し: status=${cancel.status}`);
    console.log('→ 再提出は ASC の UI で行う必要があります（UI ならサブスクが自動同梱される）。');
    process.exit(2);
  }
  console.log('\n✅ prepare 完了。バージョン＋サブスクが同梱されました。mode=submit で送信できます。');
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
