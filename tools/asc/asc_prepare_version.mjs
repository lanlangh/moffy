// 新しい appStoreVersion を作り、公開中バージョンでは編集できなかった項目を設定する。
//
// 背景:
//   公開中(READY_FOR_SALE)のバージョンでは marketingUrl も description も
//   `409 Attribute ... cannot be edited at this time` で編集できない。
//   よって新バージョン(下書き)を作らないと以下が永久に直せない:
//     * marketingUrl … これが無いと AdMob は iOS の app-ads.txt を**永久にクロールできない**
//       (クローラは「ストア掲載ページのデベロッパーサイト」を見に行くため)
//     * description の「3種族」… 実装は4種族。景表法上の不正確な表示
//
// 安全策:
//   * 許可メソッドは GET / POST / PATCH のみ（DELETE は投げられない）
//   * 膠着中の提出物 755e8857 / 公開中の appStoreVersion 7824865b に触れたら即中止
//   * 既定は dry-run。書き込むには mode=apply
//   * 書いたら読み直して検証する
//
// Usage:
//   node asc_prepare_version.mjs <p8> <keyId> <issuerId> <bundleId> <versionString> [apply]
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

const FORBIDDEN_SUBMISSION = '755e8857-3ab8-421d-bdc1-e4642569acb4';
const FORBIDDEN_VERSION = '7824865b-b21f-4ce3-b76d-3da9ad85bb73';
const MARKETING_URL = 'https://lan-corp.com';

const [, , P8, KEY_ID, ISSUER, BUNDLE_ID, VERSION, MODE = 'dry-run'] = process.argv;
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
  if (!['GET', 'POST', 'PATCH'].includes(method)) throw new Error(`禁止メソッド: ${method}`);
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
const cp = (s) => [...(s ?? '')].length;

(async () => {
  const here = path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1'));
  const rd = (f) => fs.readFileSync(path.join(here, f), 'utf8').replace(/\r\n/g, '\n').trim();
  const desc = rd('ios_store_description.txt');
  const keywords = fs.readFileSync(path.join(here, 'ios_store_keywords.txt'), 'utf8').trim();
  const promo = rd('ios_store_promotional_text.txt');
  const whatsNew = rd('ios_store_whats_new.txt');

  console.log('=== 流し込む内容の検証 ===');
  console.log(`  description      = ${cp(desc)} / 4000字`);
  console.log(`  keywords         = ${cp(keywords)} / 100字`);
  console.log(`  promotionalText  = ${cp(promo)} / 170字`);
  console.log(`  whatsNew         = ${cp(whatsNew)} / 4000字`);
  if (cp(desc) > 4000) throw new Error('description が4000字超');
  if (cp(keywords) > 100) throw new Error('keywords が100字超');
  if (/,\s/.test(keywords)) throw new Error('keywords: カンマ後にスペースあり');
  // promotionalText は Apple の上限が 170。改行も1文字として数えられる。
  if (cp(promo) > 170) throw new Error(`promotionalText が170字超（${cp(promo)}字）`);
  if (cp(whatsNew) > 4000) throw new Error('whatsNew が4000字超');
  for (const [name, t] of [['description', desc], ['promotionalText', promo], ['whatsNew', whatsNew]]) {
    if (t.includes('3種族')) throw new Error(`❌ ${name} にまだ「3種族」が残っている（実装は4種族）`);
  }
  console.log(`  「4種族」を含む(description): ${desc.includes('4種族') ? '✅' : '❌'}`);
  console.log('');

  const apps = await call('GET', `/v1/apps?filter[bundleId]=${encodeURIComponent(BUNDLE_ID)}`);
  const appId = apps.json.data[0].id;

  console.log('=== 既存のバージョン ===');
  const vers = await call('GET', `/v1/apps/${appId}/appStoreVersions?limit=20`);
  let target = null;
  for (const v of vers.json?.data ?? []) {
    const a = v.attributes;
    console.log(`  ${a.versionString}  ${a.appStoreState} / ${a.appVersionState}  id=${v.id}`);
    if (a.versionString === VERSION) target = v;
  }
  console.log('');

  if (target) {
    console.log(`✅ ${VERSION} は既に存在（id=${target.id} / ${target.attributes.appStoreState}）。作成はスキップ。`);
  } else if (!APPLY) {
    console.log(`[dry-run] appStoreVersion ${VERSION} を新規作成します（platform=IOS / releaseType=MANUAL）。`);
    console.log('          実行するには mode=apply を指定してください。');
    return;
  } else {
    console.log(`--- appStoreVersion ${VERSION} を作成 ---`);
    const created = await call('POST', '/v1/appStoreVersions', {
      data: {
        type: 'appStoreVersions',
        attributes: { platform: 'IOS', versionString: VERSION, releaseType: 'MANUAL' },
        relationships: { app: { data: { type: 'apps', id: appId } } },
      },
    });
    console.log(`  POST → HTTP ${created.status}`);
    if (created.status >= 400) { console.log(`      ${errOf(created)}`); process.exit(1); }
    target = created.json.data;
    console.log(`  ✅ 作成: ${target.id}`);
  }

  console.log('\n=== ローカライズの現在値 ===');
  const locs = await call('GET', `/v1/appStoreVersions/${target.id}/appStoreVersionLocalizations?limit=20`);
  let ja = null;
  for (const l of locs.json?.data ?? []) {
    const a = l.attributes;
    console.log(`  locale=${a.locale}`);
    console.log(`    marketingUrl = ${a.marketingUrl ?? '**未設定**'}`);
    console.log(`    description  = ${cp(a.description)}字 / 「3種族」${(a.description ?? '').includes('3種族') ? '**あり(要修正)**' : 'なし'}`);
    if (a.locale === 'ja') ja = l;
  }
  if (!ja) throw new Error('ja のローカライズが見つからない');

  if (!APPLY) {
    console.log('\n[dry-run] ここで marketingUrl と description/keywords を更新します。');
    return;
  }

  console.log('\n--- ja ローカライズを更新（marketingUrl / description / keywords / promotionalText / whatsNew）---');
  const patched = await call('PATCH', `/v1/appStoreVersionLocalizations/${ja.id}`, {
    data: {
      type: 'appStoreVersionLocalizations',
      id: ja.id,
      attributes: {
        marketingUrl: MARKETING_URL,
        description: desc,
        keywords,
        promotionalText: promo,
        whatsNew,
      },
    },
  });
  console.log(`  PATCH → HTTP ${patched.status}`);
  if (patched.status >= 400) { console.log(`      ${errOf(patched)}`); process.exit(1); }

  // 書いたら読み直して検証する（このリポジトリの鉄則）
  console.log('\n=== 検証（読み直し）===');
  const after = await call('GET', `/v1/appStoreVersionLocalizations/${ja.id}`);
  const a = after.json?.data?.attributes ?? {};
  const okUrl = a.marketingUrl === MARKETING_URL;
  const okDesc = (a.description ?? '').includes('4種族') && !(a.description ?? '').includes('3種族');
  const okPromo = cp(a.promotionalText) > 0 && cp(a.promotionalText) <= 170;
  const okNew = cp(a.whatsNew) > 0;
  console.log(`  marketingUrl    = ${a.marketingUrl}  ${okUrl ? '✅' : '❌'}`);
  console.log(`  description     = ${cp(a.description)}字 / 4種族=${(a.description ?? '').includes('4種族')} 3種族=${(a.description ?? '').includes('3種族')}  ${okDesc ? '✅' : '❌'}`);
  console.log(`  keywords        = ${a.keywords}`);
  console.log(`  promotionalText = ${cp(a.promotionalText)}字 / 170  ${okPromo ? '✅' : '❌'}`);
  console.log(`  whatsNew        = ${cp(a.whatsNew)}字 / 4000  ${okNew ? '✅' : '❌'}`);
  if (!okUrl || !okDesc || !okPromo || !okNew) { console.log('\n❌ 反映されていない項目がある'); process.exit(1); }
  console.log('\n🎉 新バージョンの下ごしらえ完了。次: build を紐付け → 提出物にサブスクを載せられるか試す。');
})().catch((e) => { console.error('ERR', e.message); process.exit(1); });
