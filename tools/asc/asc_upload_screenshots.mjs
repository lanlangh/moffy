// App Store Connect — upload iPhone App Store screenshots via API (Node 24, no deps).
// Reuses the same Team API key auth as asc_set_metadata.mjs (ES256 JWT, key never printed).
//
// Hierarchy: app -> appStoreVersion(IOS) -> appStoreVersionLocalization(locale)
//            -> appScreenshotSet(screenshotDisplayType) -> appScreenshot
//
// Upload flow per screenshot (Apple asset upload protocol):
//   1) POST /v1/appScreenshots {fileName,fileSize, rel:appScreenshotSet} -> uploadOperations[]
//   2) For each uploadOperation: <method> <url> with the byte slice [offset,offset+length)
//      using ONLY op.requestHeaders (NO Authorization header on the pre-signed URL).
//   3) PATCH /v1/appScreenshots/{id} {uploaded:true, sourceFileChecksum:<md5-hex>}
//   4) Poll GET /v1/appScreenshots/{id} until attributes.assetDeliveryState.state == COMPLETE
//
// Env:
//   ASC_KEY_ID, ASC_ISSUER_ID, ASC_P8_PATH, ASC_BUNDLE_ID   (required)
//   DISPLAY_TYPE   default APP_IPHONE_67  (confirmed-valid ASC API enum; accepts 1290x2796;
//                  ASC maps this folder to the required iPhone 6.9" tier. APP_IPHONE_69 is
//                  NOT a confirmed API enum as of 2026 and may error on set creation.)
//   LOCALE         default ja
//   SHOTS_DIR      default <repo>/docs/store/screenshots/ios
//   REPLACE        1 -> delete existing screenshots in the target set first (idempotent re-run)
//   DRY_RUN=1      (default) read-only discovery, mutate nothing
//   DRY_RUN=0      apply (reserve + upload + commit)
//
import { readFileSync, statSync } from 'node:fs';
import { createPrivateKey, createSign, createHash } from 'node:crypto';
import { basename } from 'node:path';

const KEY_ID = process.env.ASC_KEY_ID;
const ISSUER_ID = process.env.ASC_ISSUER_ID;
const P8_PATH = process.env.ASC_P8_PATH;
const BUNDLE = process.env.ASC_BUNDLE_ID;
const DISPLAY_TYPE = process.env.DISPLAY_TYPE || 'APP_IPHONE_67';
const LOCALE = process.env.LOCALE || 'ja';
const REPLACE = process.env.REPLACE === '1';
const DRY = process.env.DRY_RUN !== '0';

for (const [k, v] of Object.entries({ ASC_KEY_ID: KEY_ID, ASC_ISSUER_ID: ISSUER_ID, ASC_P8_PATH: P8_PATH, ASC_BUNDLE_ID: BUNDLE })) {
  if (!v) { console.error(`missing env ${k}`); process.exit(2); }
}

// Ordered screenshot files (display order = array order).
const SHOTS_DIR = process.env.SHOTS_DIR
  || new URL('../../docs/store/screenshots/ios/', import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1');
const FILES = [
  'ios_01_home.png',
  'ios_02_eggs.png',
  'ios_03_dex.png',
  'ios_04_shiny.png',
  'ios_05_quests.png',
];

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
    headers: { Authorization: `Bearer ${makeJwt()}`, ...(body ? { 'Content-Type': 'application/json' } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let json = null; try { json = text ? JSON.parse(text) : null; } catch {}
  if (!res.ok) throw new ApiError(res.status, json, `${method} ${path}`);
  return json;
}

const sleep = (ms) => new Promise(r => setTimeout(r, ms));

// ---------------------------------------------------------------------------
// State machines / helpers
// ---------------------------------------------------------------------------
const EDITABLE_VERSION = new Set(['PREPARE_FOR_SUBMISSION', 'DEVELOPER_REJECTED', 'REJECTED', 'METADATA_REJECTED', 'INVALID_BINARY', 'WAITING_FOR_REVIEW']);

function md5hex(buf) { return createHash('md5').update(buf).digest('hex'); }

// Execute a single upload operation (PUT the byte slice to the pre-signed URL).
async function runUploadOperation(op, buf) {
  const slice = buf.subarray(op.offset, op.offset + op.length);
  const headers = {};
  for (const h of (op.requestHeaders || [])) headers[h.name] = h.value;
  const res = await fetch(op.url, { method: op.method || 'PUT', headers, body: slice });
  if (!res.ok) {
    const t = await res.text().catch(() => '');
    throw new Error(`uploadOperation ${op.method} failed HTTP ${res.status} (offset=${op.offset} len=${op.length}) ${t.slice(0, 300)}`);
  }
}

async function pollAsset(id, label) {
  for (let i = 0; i < 40; i++) {
    const r = await api('GET', `/v1/appScreenshots/${id}`);
    const st = r.data?.attributes?.assetDeliveryState || {};
    const state = st.state;
    if (state === 'COMPLETE') { console.log(`     ✅ ${label} assetDeliveryState=COMPLETE`); return r.data; }
    if (state === 'FAILED') {
      const errs = (st.errors || []).map(e => `${e.code}: ${e.description}`).join('; ');
      const warns = (st.warnings || []).map(e => `${e.code}: ${e.description}`).join('; ');
      throw new Error(`${label} assetDeliveryState=FAILED — errors:[${errs}] warnings:[${warns}]`);
    }
    await sleep(2000);
  }
  console.log(`     ⚠️ ${label} still processing after poll window (assetDeliveryState not COMPLETE) — check ASC UI later.`);
}

// ---------------------------------------------------------------------------
// Flow
// ---------------------------------------------------------------------------
(async () => {
  console.log(`\n=== ASC screenshot upload ${DRY ? '(DRY-RUN・読むだけ)' : '★★ WRITE ★★'} ===`);
  console.log(`displayType=${DISPLAY_TYPE} locale=${LOCALE} replace=${REPLACE}`);
  console.log(`shotsDir=${SHOTS_DIR}`);

  // Validate local files + dimensions up front.
  const shots = FILES.map(fn => {
    const path = SHOTS_DIR.replace(/\/?$/, '/') + fn;
    const buf = readFileSync(path);
    if (buf.length < 24 || buf.toString('ascii', 1, 4) !== 'PNG') throw new Error(`${fn}: not a PNG`);
    const w = buf.readUInt32BE(16), h = buf.readUInt32BE(20);
    return { fn, path, buf, size: statSync(path).size, w, h };
  });
  console.log('\nローカル画像:');
  for (const s of shots) console.log(`  ${s.fn}  ${s.w}x${s.h}  ${(s.size / 1024 / 1024).toFixed(2)}MB`);

  // 1) app
  const apps = await api('GET', `/v1/apps?filter[bundleId]=${encodeURIComponent(BUNDLE)}&fields[apps]=bundleId,name`);
  if (!apps.data?.length) throw new Error(`app not found: ${BUNDLE}`);
  const APP_ID = apps.data[0].id;
  console.log(`\napp: ${APP_ID} (${apps.data[0].attributes.bundleId}) name=${JSON.stringify(apps.data[0].attributes.name)}`);

  // 2) editable iOS version
  const vers = await api('GET', `/v1/apps/${APP_ID}/appStoreVersions?filter[platform]=IOS&fields[appStoreVersions]=versionString,appStoreState,platform`);
  console.log(`iOS versions: ${vers.data.map(v => `${v.attributes.versionString}(${v.attributes.appStoreState})`).join(', ') || '(なし)'}`);
  const version = vers.data.find(v => EDITABLE_VERSION.has(v.attributes.appStoreState));
  if (!version) throw new Error('編集可能な iOS バージョンが見つからない（先に asc_set_metadata で 1.0 を作成/編集可能状態に）');
  console.log(`使用する版: ${version.id} v${version.attributes.versionString} state=${version.attributes.appStoreState}`);

  // 3) localization (per-locale) — screenshots hang off appStoreVersionLocalizations
  const vlocs = await api('GET', `/v1/appStoreVersions/${version.id}/appStoreVersionLocalizations?fields[appStoreVersionLocalizations]=locale`);
  const loc = vlocs.data.find(l => l.attributes.locale === LOCALE);
  if (!loc) throw new Error(`locale ${LOCALE} のローカライズがない（先にメタデータ投入で ${LOCALE} を作成）。存在: ${vlocs.data.map(l => l.attributes.locale).join(', ')}`);
  console.log(`localization: ${loc.id} locale=${loc.attributes.locale}`);

  // 4) find/create the appScreenshotSet for DISPLAY_TYPE
  const sets = await api('GET', `/v1/appStoreVersionLocalizations/${loc.id}/appScreenshotSets?include=appScreenshots&limit=50`);
  const existingByType = {};
  for (const s of sets.data) existingByType[s.attributes.screenshotDisplayType] = s;
  console.log(`\n既存 screenshotSet: ${sets.data.map(s => `${s.attributes.screenshotDisplayType}(${(s.relationships?.appScreenshots?.data || []).length}枚)`).join(', ') || '(なし)'}`);

  let set = existingByType[DISPLAY_TYPE];
  if (set) {
    console.log(`対象セット既存: ${set.id} ${DISPLAY_TYPE}`);
  } else if (DRY) {
    console.log(`  [DRY-RUN] ${DISPLAY_TYPE} のセットを新規作成予定（loc=${loc.id}）`);
  } else {
    const created = await api('POST', `/v1/appScreenshotSets`, {
      data: { type: 'appScreenshotSets', attributes: { screenshotDisplayType: DISPLAY_TYPE }, relationships: { appStoreVersionLocalization: { data: { type: 'appStoreVersionLocalizations', id: loc.id } } } },
    });
    set = created.data;
    console.log(`  ✅ セット作成: ${set.id} ${DISPLAY_TYPE}`);
  }

  // 4b) existing screenshots in the set
  let existingShots = [];
  if (set && set.id) {
    const cur = await api('GET', `/v1/appScreenshotSets/${set.id}/appScreenshots?fields[appScreenshots]=fileName,assetDeliveryState&limit=50`);
    existingShots = cur.data;
    if (existingShots.length) {
      console.log(`  既存スクショ ${existingShots.length}枚: ${existingShots.map(s => s.attributes.fileName).join(', ')}`);
      if (!REPLACE) {
        console.log(`  ⚠️ 既にスクショあり。重複を避けるため、置き換えるなら REPLACE=1 で再実行。今回はアップロードをスキップ対象。`);
      } else if (!DRY) {
        for (const s of existingShots) { await api('DELETE', `/v1/appScreenshots/${s.id}`); console.log(`  🗑️ 削除: ${s.attributes.fileName}`); }
        existingShots = [];
      } else {
        console.log(`  [DRY-RUN] REPLACE=1 → 既存${existingShots.length}枚を削除予定`);
      }
    }
  }

  // 5) upload each screenshot
  const willUpload = REPLACE || existingShots.length === 0;
  if (!willUpload) {
    console.log('\n既存スクショがあり REPLACE 未指定のためアップロードは行いません。');
  }
  const uploadedIds = [];
  if (DRY) {
    console.log('\n[DRY-RUN] アップロード計画:');
    for (const s of shots) console.log(`  reserve ${s.fn} (${s.size}B) → uploadOperations PUT → commit md5=${md5hex(s.buf).slice(0, 8)}…`);
    console.log('\n=== DRY-RUN 完了・何も変更していません ===');
    return;
  }

  if (willUpload) {
    for (const s of shots) {
      console.log(`\n▶ ${s.fn}`);
      const reserved = await api('POST', `/v1/appScreenshots`, {
        data: { type: 'appScreenshots', attributes: { fileName: basename(s.path), fileSize: s.size }, relationships: { appScreenshotSet: { data: { type: 'appScreenshotSets', id: set.id } } } },
      });
      const id = reserved.data.id;
      const ops = reserved.data.attributes.uploadOperations || [];
      console.log(`   reserved id=${id}  uploadOperations=${ops.length}`);
      for (const op of ops) await runUploadOperation(op, s.buf);
      await api('PATCH', `/v1/appScreenshots/${id}`, {
        data: { type: 'appScreenshots', id, attributes: { uploaded: true, sourceFileChecksum: md5hex(s.buf) } },
      });
      console.log(`   committed (uploaded=true, md5=${md5hex(s.buf).slice(0, 8)}…)`);
      await pollAsset(id, s.fn);
      uploadedIds.push(id);
    }

    // 6) enforce display order = FILES order
    if (uploadedIds.length) {
      await api('PATCH', `/v1/appScreenshotSets/${set.id}/relationships/appScreenshots`, {
        data: uploadedIds.map(id => ({ type: 'appScreenshots', id })),
      });
      console.log(`\n✅ 表示順を ${FILES.join(' → ')} に設定`);
    }
  }

  console.log(`\n=== 完了 ${uploadedIds.length}枚アップロード ===`);
})().catch(e => { console.error('\n❌ ERROR:\n' + e.message); process.exit(1); });
