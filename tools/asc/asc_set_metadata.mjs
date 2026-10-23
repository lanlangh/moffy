// App Store Connect — set Japanese (ja) app metadata via API (Node 24, no deps).
// Reads Team API key (.p8) locally, signs ES256 JWT, PATCH/POST localizations.
//
// Env:
//   ASC_KEY_ID, ASC_ISSUER_ID, ASC_P8_PATH, ASC_BUNDLE_ID
//   DRY_RUN=1  -> read-only: print current state + planned changes, mutate nothing
//   DRY_RUN=0  -> apply changes
//
// The private key is only used to sign JWTs; it is never printed.

import { readFileSync } from 'node:fs';
import { createPrivateKey, createSign } from 'node:crypto';

const KEY_ID = process.env.ASC_KEY_ID;
const ISSUER_ID = process.env.ASC_ISSUER_ID;
const P8_PATH = process.env.ASC_P8_PATH;
const BUNDLE = process.env.ASC_BUNDLE_ID;
const DRY = process.env.DRY_RUN !== '0'; // default safe (dry-run) unless explicitly 0
const IS_FIRST_VERSION = true; // v1.0: do NOT send whatsNew

for (const [k, v] of Object.entries({ ASC_KEY_ID: KEY_ID, ASC_ISSUER_ID: ISSUER_ID, ASC_P8_PATH: P8_PATH, ASC_BUNDLE_ID: BUNDLE })) {
  if (!v) { console.error(`missing env ${k}`); process.exit(2); }
}

// ---------------------------------------------------------------------------
// Metadata to set (ja). Confirmed 2026-07-15. iOS v1.0 = no ads -> no "ad-free"
// bullet in the description.
// ---------------------------------------------------------------------------
// ⚠️ このスクリプトを起動するワークフローは存在しない（2026-08-19 時点）。
// keywords / promotionalText / description の正は tools/asc/ios_store_*.txt で、
// 実際に流し込むのは asc_prepare_version.mjs（asc-prepare-version.yml）。
// 以前はここに同じ文章を直書きしていたが、.txt だけ直されて古い文章が残り、
// 将来動かすと最新版を巻き戻す地雷になっていた（2026-10-23 に 0018 の文言で発覚）。
// → .txt を読む形にして、文章の置き場所を1つにした。
const readTxt = (name) => readFileSync(new URL(`./${name}`, import.meta.url), 'utf8').trim();
const META_JA = {
  // appInfoLocalizations（=名前とサブタイトル。バージョンではなく App 単位）
  // 「モフィ」はここにしか置けない: App Store の検索は説明文をインデックスしないため、
  // カタカナで検索したユーザーに届く唯一の場所が name / subtitle / keywords の3つ。
  name: 'Moffy（モフィ）- SNS減らして卵を育てる',
  subtitle: 'スクリーンタイムが、かわいい図鑑になる育成ゲーム',
  privacyPolicyUrl: 'https://mud-nectarine-0f9.notion.site/Moffy-38a1efa9943a805f8af3d7c7b8ee5753',
  // appStoreVersionLocalizations
  keywords: readTxt('ios_store_keywords.txt'),
  promotionalText: readTxt('ios_store_promotional_text.txt'),
  supportUrl: 'https://mud-nectarine-0f9.notion.site/Moffy-38a1efa9943a80a8b569d2102a2eb48a', // 特商法ページ（連絡先あり）
  description: readTxt('ios_store_description.txt'),
};

// ---------------------------------------------------------------------------
// JWT + fetch
// ---------------------------------------------------------------------------
const b64url = (buf) => Buffer.from(buf).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
function makeJwt() {
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: 'ES256', kid: KEY_ID, typ: 'JWT' };
  const payload = { iss: ISSUER_ID, iat: now, exp: now + 1200, aud: 'appstoreconnect-v1' };
  const signingInput = b64url(JSON.stringify(header)) + '.' + b64url(JSON.stringify(payload));
  const key = createPrivateKey({ key: readFileSync(P8_PATH), format: 'pem' });
  const s = createSign('SHA256'); s.update(signingInput); s.end();
  const sig = s.sign({ key, dsaEncoding: 'ieee-p1363' });
  return signingInput + '.' + b64url(sig);
}
let JWT = makeJwt();
const BASE = 'https://api.appstoreconnect.apple.com';

class ApiError extends Error {
  constructor(status, json, ctx) {
    const errs = json?.errors ?? [];
    const msg = errs.map(e => `[${e.status} ${e.code ?? ''}] ${e.title ?? ''} :: ${e.detail ?? ''}${e.source?.pointer ? ` (@${e.source.pointer})` : ''}`).join('\n') || `HTTP ${status}`;
    super(`${ctx}\n${msg}`); this.status = status; this.errors = errs; this.code = errs[0]?.code;
  }
}
async function api(method, path, body) {
  const res = await fetch(BASE + path, {
    method,
    headers: { Authorization: `Bearer ${JWT}`, ...(body ? { 'Content-Type': 'application/json' } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let json = null; try { json = text ? JSON.parse(text) : null; } catch {}
  if (!res.ok) throw new ApiError(res.status, json, `${method} ${path}`);
  return json;
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------
function assertLimits(m) {
  const cp = s => (s == null ? 0 : [...String(s)].length);
  const chk = (v, max, label) => { if (cp(v) > max) throw new Error(`${label} 上限${max}超過: ${cp(v)}文字`); };
  chk(m.name, 30, 'name'); chk(m.subtitle, 30, 'subtitle');
  chk(m.description, 4000, 'description'); chk(m.promotionalText, 170, 'promotionalText');
  chk(m.keywords, 100, 'keywords');
  if (/,\s/.test(m.keywords || '')) throw new Error('keywords: カンマ後にスペースあり（除去せよ）');
  for (const [k, u] of [['privacyPolicyUrl', m.privacyPolicyUrl], ['supportUrl', m.supportUrl]]) {
    if (u) { try { new URL(u); } catch { throw new Error(`${k} 無効URL: ${u}`); } }
  }
  console.log('検証OK: name=%d/30 subtitle=%d/30 keywords=%d/100 promo=%d/170 desc=%d/4000',
    cp(m.name), cp(m.subtitle), cp(m.keywords), cp(m.promotionalText), cp(m.description));
}

async function mutate(method, path, body, label) {
  if (DRY) { console.log(`  [DRY-RUN] ${method} ${path}\n           → ${label}`); return { data: { id: '(dry-run)', attributes: body.data.attributes } }; }
  const r = await api(method, path, body); console.log(`  ✅ ${method} ${path} — ${label}`); return r;
}

const short = (s, n = 40) => { const a = [...String(s ?? '')]; return a.length > n ? a.slice(0, n).join('') + `…(${a.length}字)` : a.join(''); };

// ---------------------------------------------------------------------------
// Flow
// ---------------------------------------------------------------------------
const EDITABLE_APPINFO = new Set(['PREPARE_FOR_SUBMISSION']);
const EDITABLE_VERSION = new Set(['PREPARE_FOR_SUBMISSION', 'DEVELOPER_REJECTED', 'REJECTED', 'METADATA_REJECTED', 'INVALID_BINARY']);

(async () => {
  console.log(`\n=== ASC metadata ${DRY ? '(DRY-RUN・読むだけ)' : '★★ WRITE ★★'} ===`);
  assertLimits(META_JA);

  // 1) app
  const apps = await api('GET', `/v1/apps?filter[bundleId]=${encodeURIComponent(BUNDLE)}&fields[apps]=bundleId,name`);
  if (!apps.data?.length) throw new Error(`app not found: ${BUNDLE}`);
  const APP_ID = apps.data[0].id;
  console.log(`app: ${APP_ID} (${apps.data[0].attributes.bundleId})  現App名=${JSON.stringify(apps.data[0].attributes.name)}`);

  // --- A: name / subtitle / privacy (appInfoLocalizations) ---
  const appInfos = await api('GET', `/v1/apps/${APP_ID}/appInfos?include=appInfoLocalizations`);
  const appInfo = appInfos.data.find(a => EDITABLE_APPINFO.has(a.attributes.state));
  if (!appInfo) {
    console.log('⚠️ 編集可能な appInfo なし（ライブ/ロック状態）。name/subtitle はスキップ。');
  } else {
    const locs = await api('GET', `/v1/appInfos/${appInfo.id}/appInfoLocalizations`);
    const ja = locs.data.find(l => l.attributes.locale === 'ja');
    console.log(`\n[A] appInfo ${appInfo.id} state=${appInfo.attributes.state} (編集可)`);
    if (ja) {
      console.log(`  現在 ja: name=${JSON.stringify(ja.attributes.name)} subtitle=${JSON.stringify(ja.attributes.subtitle)} privacy=${ja.attributes.privacyPolicyUrl || '(なし)'}`);
      console.log(`  変更後: name=${JSON.stringify(META_JA.name)} subtitle=${JSON.stringify(META_JA.subtitle)} privacy=設定`);
      await mutate('PATCH', `/v1/appInfoLocalizations/${ja.id}`, {
        data: { type: 'appInfoLocalizations', id: ja.id, attributes: { name: META_JA.name, subtitle: META_JA.subtitle, privacyPolicyUrl: META_JA.privacyPolicyUrl } },
      }, 'name/subtitle/privacy を更新');
    } else {
      console.log('  ja localization なし → 新規作成予定');
      await mutate('POST', `/v1/appInfoLocalizations`, {
        data: { type: 'appInfoLocalizations', attributes: { locale: 'ja', name: META_JA.name, subtitle: META_JA.subtitle, privacyPolicyUrl: META_JA.privacyPolicyUrl }, relationships: { appInfo: { data: { type: 'appInfos', id: appInfo.id } } } },
      }, 'ja を新規作成');
    }
  }

  // --- B: description / keywords / promo / support (appStoreVersionLocalizations) ---
  const vers = await api('GET', `/v1/apps/${APP_ID}/appStoreVersions?filter[platform]=IOS&fields[appStoreVersions]=versionString,appStoreState,platform,createdDate`);
  let version = vers.data.find(v => EDITABLE_VERSION.has(v.attributes.appStoreState));
  console.log(`\n[B] iOS versions: ${vers.data.map(v => `${v.attributes.versionString}(${v.attributes.appStoreState})`).join(', ') || '(なし)'}`);
  if (!version) {
    console.log('  編集可能な iOS バージョンなし → 1.0 を作成予定');
    const created = await mutate('POST', `/v1/appStoreVersions`, {
      data: { type: 'appStoreVersions', attributes: { platform: 'IOS', versionString: '1.0' }, relationships: { app: { data: { type: 'apps', id: APP_ID } } } },
    }, 'iOS バージョン1.0を作成');
    version = DRY ? null : created.data;
  } else {
    console.log(`  使用する版: ${version.id} v${version.attributes.versionString} state=${version.attributes.appStoreState}`);
  }

  const verAttrs = { description: META_JA.description, keywords: META_JA.keywords, promotionalText: META_JA.promotionalText, supportUrl: META_JA.supportUrl };
  // (whatsNew は初版のため送らない)

  if (!version) {
    console.log('  [DRY-RUN] 版が未作成のため versionLocalization は本番実行時に設定:');
    console.log(`           keywords=${META_JA.keywords}`);
    console.log(`           promo=${short(META_JA.promotionalText)}`);
    console.log(`           support=${META_JA.supportUrl}`);
    console.log(`           description=${short(META_JA.description, 30)}`);
  } else {
    const vlocs = await api('GET', `/v1/appStoreVersions/${version.id}/appStoreVersionLocalizations`);
    const ja = vlocs.data.find(l => l.attributes.locale === 'ja');
    if (ja) {
      console.log(`  現在 ja: desc=${[...(ja.attributes.description || '')].length}字 keywords=${JSON.stringify(ja.attributes.keywords)} support=${ja.attributes.supportUrl || '(なし)'}`);
      await mutate('PATCH', `/v1/appStoreVersionLocalizations/${ja.id}`, { data: { type: 'appStoreVersionLocalizations', id: ja.id, attributes: verAttrs } }, 'description/keywords/promo/support を更新');
    } else {
      await mutate('POST', `/v1/appStoreVersionLocalizations`, { data: { type: 'appStoreVersionLocalizations', attributes: { locale: 'ja', ...verAttrs }, relationships: { appStoreVersion: { data: { type: 'appStoreVersions', id: version.id } } } } }, 'ja versionLocalization を新規作成');
    }
  }

  console.log(`\n=== 完了 ${DRY ? '(DRY-RUN・何も変更していません)' : '(書き込み実行済み)'} ===`);
})().catch(e => { console.error('\n❌ ERROR:\n' + e.message); process.exit(1); });
