// App Store Connect 提出前プリフライト検査。
//
// 目的: 「審査に提出」を押す前に、ASC の実データを API で読み、不備・入力漏れを洗い出す。
// UI の目視は見落とすが、これは実データを機械的に検査する。
//
// Usage:
//   node asc_preflight.mjs <p8Path> <keyId> <issuerId> <bundleId> <versionString>
//
// 判定: ❌=提出ブロッカー / ⚠️=要確認 / ✅=OK。❌が1件でもあれば exit 1。
// 秘密鍵は読み取るだけで出力しない。
import fs from 'node:fs';
import crypto from 'node:crypto';

const [, , P8_PATH, KEY_ID, ISSUER_ID, BUNDLE_ID, VERSION_STRING] = process.argv;
if (!P8_PATH || !KEY_ID || !ISSUER_ID || !BUNDLE_ID || !VERSION_STRING) {
  console.error('args: <p8Path> <keyId> <issuerId> <bundleId> <versionString>');
  process.exit(2);
}

const b64url = (b) => Buffer.from(b).toString('base64').replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_');
function makeJWT() {
  const pem = fs.readFileSync(P8_PATH, 'utf8');
  const now = Math.floor(Date.now() / 1000);
  const si =
    b64url(JSON.stringify({ alg: 'ES256', kid: KEY_ID, typ: 'JWT' })) +
    '.' +
    b64url(JSON.stringify({ iss: ISSUER_ID, iat: now, exp: now + 600, aud: 'appstoreconnect-v1' }));
  return si + '.' + b64url(crypto.sign('SHA256', Buffer.from(si), { key: pem, dsaEncoding: 'ieee-p1363' }));
}
const BASE = 'https://api.appstoreconnect.apple.com';
async function get(path) {
  const res = await fetch(BASE + path, { headers: { Authorization: 'Bearer ' + makeJWT() } });
  const text = await res.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { /* noop */ }
  return { status: res.status, json, text };
}

const problems = [];
const warns = [];
const ok = (m) => console.log('  ✅ ' + m);
const bad = (m) => { problems.push(m); console.log('  ❌ ' + m); };
const warn = (m) => { warns.push(m); console.log('  ⚠️  ' + m); };

(async () => {
  // ---- アプリ ----
  console.log('\n=== アプリ ===');
  const apps = await get(`/v1/apps?filter[bundleId]=${encodeURIComponent(BUNDLE_ID)}`);
  if (apps.status !== 200 || !apps.json?.data?.length) { bad(`アプリが見つからない (${BUNDLE_ID})`); process.exit(1); }
  const app = apps.json.data[0];
  const appId = app.id;
  ok(`id=${appId} name=${JSON.stringify(app.attributes.name)} sku=${app.attributes.sku} locale=${app.attributes.primaryLocale}`);

  // ---- バージョン ----
  console.log('\n=== バージョン ===');
  const vers = await get(`/v1/apps/${appId}/appStoreVersions?filter[versionString]=${encodeURIComponent(VERSION_STRING)}&limit=5`);
  const ver = vers.json?.data?.[0];
  if (!ver) { bad(`バージョン ${VERSION_STRING} が無い`); process.exit(1); }
  const verId = ver.id;
  const a = ver.attributes;
  const state = a.appStoreState ?? a.appVersionState;
  console.log(`  state=${state} releaseType=${a.releaseType} copyright=${JSON.stringify(a.copyright)}`);
  if (state === 'PREPARE_FOR_SUBMISSION' || state === 'READY_FOR_REVIEW') ok(`state=${state}（提出可能な状態）`);
  else if (state === 'WAITING_FOR_REVIEW' || state === 'IN_REVIEW') warn(`state=${state}＝既に提出済みでは？`);
  else bad(`state=${state}（提出できる状態ではない）`);
  if (a.releaseType === 'MANUAL') ok('releaseType=MANUAL（手動リリース）');
  else bad(`releaseType=${a.releaseType}（MANUAL を推奨＝承認後に自動公開されてしまう）`);
  // 著作権は初回提出の必須項目。null のまま提出すると ENTITY_STATE_INVALID で弾かれる
  // （API はどの項目が原因かを教えてくれないので、ここで潰す）。
  if (!a.copyright?.trim()) bad('著作権(copyright)が未入力＝提出できない');
  else ok(`copyright=${JSON.stringify(a.copyright)}`);

  // ---- ビルド ----
  console.log('\n=== ビルド ===');
  const b = await get(`/v1/appStoreVersions/${verId}/build`);
  const bn = b.json?.data?.attributes?.version;
  const bstate = b.json?.data?.attributes?.processingState;
  if (!bn) bad('バージョンにビルドが紐付いていない');
  else if (bstate !== 'VALID') bad(`build ${bn} の processingState=${bstate}（VALID でないと提出できない）`);
  else ok(`build ${bn} 紐付け済 / processingState=VALID`);

  // ---- 輸出コンプライアンス ----
  if (b.json?.data?.id) {
    const bd = await get(`/v1/builds/${b.json.data.id}`);
    const mep = bd.json?.data?.attributes?.usesNonExemptEncryption;
    if (mep === false) ok('usesNonExemptEncryption=false（輸出コンプライアンス回答済＝提出時に聞かれない）');
    else if (mep === null || mep === undefined) warn('usesNonExemptEncryption 未設定＝提出時に「暗号化を使用？」と聞かれる → 「いいえ」を選ぶ');
    else bad(`usesNonExemptEncryption=${mep}（true だと輸出書類が必要）`);
  }

  // ---- ローカライズ（説明文・キーワード等）----
  console.log('\n=== ストア掲載情報 ===');
  const locs = await get(`/v1/appStoreVersions/${verId}/appStoreVersionLocalizations?limit=20`);
  for (const l of locs.json?.data ?? []) {
    const x = l.attributes;
    console.log(`  [${x.locale}]`);
    if (!x.description?.trim()) bad(`${x.locale}: 説明文が空`); else ok(`${x.locale}: 説明文 ${x.description.length}字`);
    if (!x.keywords?.trim()) warn(`${x.locale}: キーワードが空`);
    else if (x.keywords.length > 100) bad(`${x.locale}: キーワード ${x.keywords.length}字（100字上限を超過）`);
    else ok(`${x.locale}: キーワード ${x.keywords.length}字`);
    if (!x.supportUrl?.trim()) bad(`${x.locale}: サポートURLが空（必須）`); else ok(`${x.locale}: supportUrl=${x.supportUrl}`);
    if (x.marketingUrl) ok(`${x.locale}: marketingUrl=${x.marketingUrl}`);
    if (x.promotionalText) ok(`${x.locale}: プロモーションテキスト ${x.promotionalText.length}字`);
    if (x.whatsNew) warn(`${x.locale}: whatsNew が入っている（初版では不要）`);

    // ---- スクリーンショット ----
    const sets = await get(`/v1/appStoreVersionLocalizations/${l.id}/appScreenshotSets?limit=20`);
    const setList = sets.json?.data ?? [];
    if (!setList.length) bad(`${x.locale}: スクリーンショットが1枚も無い`);
    for (const s of setList) {
      const dt = s.attributes.screenshotDisplayType;
      const shots = await get(`/v1/appScreenshotSets/${s.id}/appScreenshots?limit=20`);
      const list = shots.json?.data ?? [];
      const badShots = list.filter((p) => p.attributes.assetDeliveryState?.state !== 'COMPLETE');
      if (!list.length) bad(`${x.locale}/${dt}: 0枚`);
      else if (badShots.length) bad(`${x.locale}/${dt}: ${list.length}枚中 ${badShots.length}枚が未完了(${badShots.map((p) => p.attributes.assetDeliveryState?.state).join(',')})`);
      else ok(`${x.locale}/${dt}: ${list.length}枚 すべて COMPLETE`);
    }
  }

  // ---- App情報（名前・サブタイトル・プラポリ）----
  console.log('\n=== App情報 ===');
  const infos = await get(`/v1/apps/${appId}/appInfos?limit=5`);
  for (const inf of infos.json?.data ?? []) {
    const st = inf.attributes?.appStoreState ?? inf.attributes?.state;
    if (st === 'READY_FOR_DISTRIBUTION') continue; // 公開済みの旧レコード
    console.log(`  appInfo id=${inf.id} state=${st}`);
    const il = await get(`/v1/appInfos/${inf.id}/appInfoLocalizations?limit=20`);
    for (const l of il.json?.data ?? []) {
      const x = l.attributes;
      if (!x.name?.trim()) bad(`${x.locale}: アプリ名が空`); else ok(`${x.locale}: 名前=${JSON.stringify(x.name)} (${x.name.length}字)`);
      if (x.subtitle) ok(`${x.locale}: サブタイトル=${JSON.stringify(x.subtitle)} (${x.subtitle.length}字)`);
      if (!x.privacyPolicyUrl?.trim()) bad(`${x.locale}: プライバシーポリシーURLが空（必須）`);
      else ok(`${x.locale}: privacyPolicyUrl=${x.privacyPolicyUrl}`);
    }
    // 年齢レーティング
    const ar = await get(`/v1/appInfos/${inf.id}/ageRatingDeclaration`);
    if (ar.status === 200 && ar.json?.data) ok('年齢レーティング宣言あり');
    else warn('年齢レーティング宣言が取得できない（UIで確認）');

    // カテゴリ（プライマリは全アプリ必須。未設定だと ENTITY_STATE_INVALID で提出が弾かれる）。
    const cat = await get(`/v1/appInfos/${inf.id}?include=primaryCategory,secondaryCategory`);
    const included = cat.json?.included ?? [];
    const primaryId = cat.json?.data?.relationships?.primaryCategory?.data?.id;
    if (!primaryId) bad('プライマリカテゴリが未設定＝提出できない');
    else ok(`プライマリカテゴリ=${primaryId}`);
    const secondaryId = cat.json?.data?.relationships?.secondaryCategory?.data?.id;
    if (secondaryId) ok(`セカンダリカテゴリ=${secondaryId}`);
    if (included.length) console.log(`     (include: ${included.map((c) => c.id).join(', ')})`);
  }

  // ---- 審査情報 ----
  console.log('\n=== 審査情報（App Review）===');
  const rd = await get(`/v1/appStoreVersions/${verId}/appStoreReviewDetail`);
  if (rd.status !== 200 || !rd.json?.data) {
    bad('審査情報（連絡先）が未入力＝提出できない');
  } else {
    const x = rd.json.data.attributes;
    const missing = ['contactFirstName', 'contactLastName', 'contactPhone', 'contactEmail'].filter((k) => !x[k]?.trim());
    if (missing.length) bad(`審査連絡先の未入力: ${missing.join(', ')}`);
    else ok(`審査連絡先 OK (${x.contactFirstName} ${x.contactLastName} / ${x.contactEmail} / ${x.contactPhone})`);
    if (x.demoAccountRequired) {
      if (!x.demoAccountName?.trim() || !x.demoAccountPassword?.trim()) bad('デモアカウント必須なのに未入力');
      else ok('デモアカウント入力済');
    } else ok('デモアカウント不要（匿名認証のため妥当）');
    if (!x.notes?.trim()) warn('審査メモが空＝Screen Time(Family Controls)の用途説明を入れると往復が減る');
    else ok(`審査メモ ${x.notes.length}字あり`);
  }

  // ---- 価格・配信 ----
  console.log('\n=== 価格・配信 ===');
  const ps = await get(`/v1/apps/${appId}/appPriceSchedule`);
  if (ps.status === 200 && ps.json?.data) ok('価格スケジュールあり');
  else bad('価格スケジュールが無い＝提出できない');

  // ---- サブスク ----
  console.log('\n=== サブスクリプション ===');
  const groups = await get(`/v1/apps/${appId}/subscriptionGroups?limit=10`);
  for (const g of groups.json?.data ?? []) {
    const subs = await get(`/v1/subscriptionGroups/${g.id}/subscriptions?limit=20`);
    for (const s of subs.json?.data ?? []) {
      const x = s.attributes;
      if (x.state === 'READY_TO_SUBMIT' || x.state === 'APPROVED' || x.state === 'WAITING_FOR_REVIEW') ok(`${x.productId}: ${x.state}`);
      else warn(`${x.productId}: state=${x.state}（READY_TO_SUBMIT でないと初回審査に同梱されない）`);
    }
  }

  // ---- 既に提出済みでないか ----
  const sub = await get(`/v1/appStoreVersions/${verId}/appStoreVersionSubmission`);
  if (sub.status === 200 && sub.json?.data) warn('appStoreVersionSubmission が既に存在＝提出済みの可能性');

  // ---- まとめ ----
  console.log('\n================ 結果 ================');
  console.log(`❌ ブロッカー: ${problems.length} 件`);
  problems.forEach((p) => console.log('   - ' + p));
  console.log(`⚠️  要確認: ${warns.length} 件`);
  warns.forEach((p) => console.log('   - ' + p));
  if (problems.length) { console.log('\n提出前に上記❌を解消すること。'); process.exit(1); }
  console.log('\n✅ ブロッカーなし。提出可能。');
})().catch((e) => { console.error('ERR', e.message); process.exit(1); });
