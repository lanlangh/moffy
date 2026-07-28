// App Store の「マーケティングURL」＝ストアページの「デベロッパWebサイト」だけを設定する。
//
// なぜ要るか:
//   AdMob の app-ads.txt クローラは「**ストア掲載ページに書かれたデベロッパーサイト**」を見に行く
//   （AdMob公式: "The AdMob app-ads.txt crawler checks for your app-ads.txt file based on the
//   developer website in your app's store listing." / "The app store listing must include a
//   developer website."）。
//   実測で `itunes.apple.com/lookup?id=6785691850` の応答に `sellerUrl` が存在しない
//   ＝ iOS 側は未設定。この状態では lan-corp.com に app-ads.txt を置いても
//   **iOS アプリについては永久にクロールされない**。
//   Android(Play) 側は既に https://lan-corp.com が登録済み。
//
// 設計:
//   * 触るのは appStoreVersionLocalizations の `marketingUrl` **1フィールドのみ**。
//     description / keywords / promotionalText / supportUrl には一切触れない
//     （asc_set_metadata.mjs はそれらを一括で書き換えてしまうので、この用途には使えない）。
//   * 既定は **dry-run**（読むだけ）。実際に書くには第6引数に `apply` を渡す。
//   * サブスク膠着の件（reviewSubmission 755e8857）とは無関係のリソースしか触らない。
//
// Usage:
//   node asc_set_marketing_url.mjs <p8> <keyId> <issuerId> <bundleId> <url> [apply]
import fs from 'node:fs';
import crypto from 'node:crypto';

const [, , P8, KEY_ID, ISSUER, BUNDLE_ID, URL_ARG, MODE = 'dry-run'] = process.argv;
const APPLY = MODE === 'apply';

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
  // 安全装置: DELETE は投げられない。
  if (!['GET', 'PATCH'].includes(method)) throw new Error(`禁止メソッド: ${method}`);
  const res = await fetch(BASE + p, {
    method,
    headers: { Authorization: 'Bearer ' + jwt(), 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  });
  const t = await res.text(); let j = null; try { j = t ? JSON.parse(t) : null; } catch {}
  return { status: res.status, json: j, text: t };
}
const errOf = (r) => (r.json?.errors ?? []).map((e) => `[${e.status} ${e.code}] ${e.title} — ${e.detail ?? ''}`).join('\n    ');

(async () => {
  if (!/^https:\/\/[^\s]+$/.test(URL_ARG || '')) throw new Error(`URLが不正: ${URL_ARG}`);

  const apps = await call('GET', `/v1/apps?filter[bundleId]=${encodeURIComponent(BUNDLE_ID)}`);
  const appId = apps.json.data[0].id;

  const vers = await call('GET', `/v1/apps/${appId}/appStoreVersions?limit=20`);
  console.log('=== アプリバージョン ===');
  for (const v of vers.json?.data ?? []) {
    console.log(`  ${v.attributes.versionString} appStoreState=${v.attributes.appStoreState} appVersionState=${v.attributes.appVersionState} id=${v.id}`);
  }
  // 編集対象は「いちばん新しいバージョン」。公開中しか無ければそれを使う。
  const target = (vers.json?.data ?? [])[0];
  if (!target) throw new Error('appStoreVersion が見つからない');
  console.log(`\n対象バージョン: ${target.attributes.versionString} (${target.attributes.appStoreState})\n`);

  const locs = await call('GET', `/v1/appStoreVersions/${target.id}/appStoreVersionLocalizations?limit=20`);
  console.log('=== ローカライズの現在値（marketingUrl / supportUrl のみ表示）===');
  let ja = null;
  for (const l of locs.json?.data ?? []) {
    const a = l.attributes;
    console.log(`  locale=${a.locale}`);
    console.log(`    marketingUrl = ${a.marketingUrl ?? '**未設定**'}`);
    console.log(`    supportUrl   = ${a.supportUrl ?? '(なし)'}`);
    if (a.locale === 'ja') ja = l;
  }
  if (!ja) throw new Error('ja のローカライズが見つからない');

  if (ja.attributes.marketingUrl === URL_ARG) {
    console.log(`\n✅ すでに ${URL_ARG} が設定済み。何もしません。`);
    return;
  }

  if (!APPLY) {
    console.log(`\n[dry-run] marketingUrl を "${ja.attributes.marketingUrl ?? '未設定'}" → "${URL_ARG}" に変更します。`);
    console.log('           実行するには mode=apply を指定してください。');
    return;
  }

  console.log(`\n書き込み: marketingUrl → ${URL_ARG}`);
  const res = await call('PATCH', `/v1/appStoreVersionLocalizations/${ja.id}`, {
    data: { type: 'appStoreVersionLocalizations', id: ja.id, attributes: { marketingUrl: URL_ARG } },
  });
  console.log(`  PATCH → HTTP ${res.status}`);
  if (res.status >= 400) {
    console.log(`    ${errOf(res)}`);
    console.log('\n❌ 書き込めませんでした。公開中バージョンでは編集不可の可能性。');
    console.log('   → 次のバージョン(v1.0.2)を作るときに一緒に設定する。');
    process.exit(1);
  }

  // 書いたら読み直して検証する（このリポジトリの鉄則）
  const after = await call('GET', `/v1/appStoreVersionLocalizations/${ja.id}`);
  const now = after.json?.data?.attributes?.marketingUrl;
  console.log(`\n=== 検証（読み直し）===`);
  console.log(`  marketingUrl = ${now}`);
  if (now === URL_ARG) console.log('  ✅ 反映を確認しました。');
  else { console.log('  ❌ 反映されていません。'); process.exit(1); }

  console.log('\n※ ストアページへの反映には数時間かかることがあります。');
  console.log('   確認方法: https://itunes.apple.com/lookup?id=6785691850 の応答に sellerUrl が現れる');
})().catch((e) => { console.error('ERR', e.message); process.exit(1); });
