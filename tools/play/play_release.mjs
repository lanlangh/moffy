// Google Play へ AAB・スクリーンショット・説明文を **1回でまとめて** 公開する。
//
// Usage:
//   node tools/play/play_release.mjs <serviceAccountJson> <packageName> <aabPath> <versionName> [apply]
//   末尾の apply を付けないと dry-run（読むだけ・既定）
//
// なぜ「まとめて」か:
//   掲載情報だけ先に更新すると、**まだ配信していない機能が書かれた状態**になる。
//   逆に AAB だけ先に出すと、審査中ずっと古い説明文（「3種族」等）が出続ける。
//   Play の edit は複数の変更を溜めて **commit で一斉に反映**できるので、それを使う。
//
// この1つの edit に入れるもの:
//   1. AAB のアップロード（bundles.upload）
//   2. 製品版トラックへのリリース登録（versionCode / リリース名 / リリースノート）
//   3. 詳しい説明の差し替え（docs/store/play_description.txt）
//   4. スクリーンショット5枚の入れ替え（docs/store/screenshots/01〜05）
//   → commit で全部いっしょに審査へ出る
//
// ⚠️ **タイトルと簡単な説明は触らない。** Play は iOS と別管理で、変えると検索順位が動く。
// ⚠️ commit していない edit は必ず破棄する（下書きを放置しない）。
import fs from 'node:fs';
import path from 'node:path';
import { loadServiceAccount, getToken, api, must } from './play_api.mjs';

const [, , SA_PATH, PKG, AAB, VERSION_NAME, MODE = 'dry-run'] = process.argv;
const APPLY = MODE === 'apply';
if (!SA_PATH || !PKG || !AAB || !VERSION_NAME) {
  console.error('args: <serviceAccountJson> <packageName> <aabPath> <versionName> [apply]');
  process.exit(2);
}

const LOCALE = 'ja-JP';
const TRACK = 'production';
const REPO = path.resolve(path.dirname(new URL(import.meta.url).pathname.replace(/^\//, '')), '..', '..');
const DESC_FILE = path.join(REPO, 'docs', 'store', 'play_description.txt');
const NOTES_FILE = path.join(REPO, 'docs', 'store', 'play_release_notes.txt');
const SHOTS = ['01_home.png', '02_eggs.png', '03_dex.png', '04_shiny.png', '05_quests.png']
  .map((f) => path.join(REPO, 'docs', 'store', 'screenshots', f));

const fail = (m, extra) => {
  console.error('❌ ' + m);
  if (extra) console.error('   ' + extra);
  process.exit(1);
};
const chars = (s) => (s ? [...s].length : 0);

/** 実装と食い違う表記・他ストアの記述を、書き込む前に弾く。 */
function checkDescription(text) {
  const n = chars(text);
  if (n === 0) fail('説明文が空');
  if (n > 4000) fail(`説明文が ${n} 字＝上限4000字を超過`);
  const ng = [
    ['3種族', '実装は4種族'],
    ['App Store', 'Android の掲載文に iOS の解約先が混ざっている'],
    ['iPhone', 'Android の掲載文に iOS 固有の記述が混ざっている'],
  ].filter(([w]) => text.includes(w));
  if (ng.length) fail('説明文に不適切な記述:\n' + ng.map(([w, y]) => `   「${w}」… ${y}`).join('\n'));
  if (!text.includes('4種族')) fail('説明文に「4種族」がありません（実装と一致するか確認）');
  return n;
}

async function main() {
  const desc = fs.readFileSync(DESC_FILE, 'utf8').trim();
  const nDesc = checkDescription(desc);
  const notes = fs.readFileSync(NOTES_FILE, 'utf8').trim();
  if (chars(notes) > 500) fail(`リリースノートが ${chars(notes)} 字＝Play の上限500字を超過`);
  const aabBuf = fs.readFileSync(AAB);

  console.log('=== 出すもの ===');
  console.log(`  AAB          : ${path.basename(AAB)}  ${(aabBuf.length / 1024 / 1024).toFixed(1)}MB`);
  console.log(`  リリース名   : ${VERSION_NAME}`);
  console.log(`  リリースノート: ${chars(notes)} / 500字`);
  console.log(`  詳しい説明   : ${nDesc} / 4000字  ✅ 検査通過`);
  console.log(`  スクショ     : ${SHOTS.length}枚`);
  console.log('');

  const sa = loadServiceAccount(SA_PATH);
  const token = await getToken(sa);
  const edit = must(await api(token, 'POST', `/androidpublisher/v3/applications/${PKG}/edits`), 'edit の作成');
  const eid = edit.id;
  let committed = false;

  try {
    const tr = await api(token, 'GET',
      `/androidpublisher/v3/applications/${PKG}/edits/${eid}/tracks/${TRACK}`);
    const cur = (tr.json?.releases ?? [])[0];
    console.log('=== いま配信中 ===');
    console.log(`  ${cur ? `${cur.name} / versionCode ${(cur.versionCodes ?? []).join(',')} / ${cur.status}` : '（なし）'}`);
    console.log('');

    if (!APPLY) {
      console.log('[dry-run] 読むだけで終了しました。');
      console.log('          実行するには末尾に apply を指定してください。');
      console.log('          ⚠️ apply すると AAB・説明文・スクショが**まとめて審査に出ます**。');
      return;
    }

    // 1) AAB をアップロード
    console.log('--- AAB をアップロード（数分かかります）---');
    const up = await api(token, 'POST',
      `/upload/androidpublisher/v3/applications/${PKG}/edits/${eid}/bundles`,
      { body: aabBuf, contentType: 'application/octet-stream', query: { uploadType: 'media' } });
    const bundle = must(up, 'AAB のアップロード');
    const versionCode = bundle.versionCode;
    console.log(`  ✅ versionCode ${versionCode}`);

    // 2) 製品版トラックに登録
    console.log('--- 製品版トラックに登録 ---');
    must(await api(token, 'PUT',
      `/androidpublisher/v3/applications/${PKG}/edits/${eid}/tracks/${TRACK}`,
      { body: {
        track: TRACK,
        releases: [{
          name: VERSION_NAME,
          versionCodes: [String(versionCode)],
          status: 'completed',           // 段階配信せず全員へ
          releaseNotes: [{ language: LOCALE, text: notes }],
        }],
      } }), 'トラックへの登録');
    console.log('  ✅ 登録');

    // 3) 詳しい説明（title / shortDescription は送らない＝現状維持）
    console.log('--- 説明文を更新 ---');
    must(await api(token, 'PATCH',
      `/androidpublisher/v3/applications/${PKG}/edits/${eid}/listings/${LOCALE}`,
      { body: { fullDescription: desc } }), '説明文の更新');
    console.log('  ✅ 更新');

    // 4) スクリーンショット
    console.log('--- スクリーンショットを入れ替え ---');
    const del = await api(token, 'DELETE',
      `/androidpublisher/v3/applications/${PKG}/edits/${eid}/listings/${LOCALE}/images/phoneScreenshots`);
    console.log(`  既存を削除 HTTP ${del.status}`);
    for (const p of SHOTS) {
      must(await api(token, 'POST',
        `/upload/androidpublisher/v3/applications/${PKG}/edits/${eid}/listings/${LOCALE}/images/phoneScreenshots`,
        { body: fs.readFileSync(p), contentType: 'image/png', query: { uploadType: 'media' } }),
        `${path.basename(p)} のアップロード`);
      console.log(`  ✅ ${path.basename(p)}`);
    }

    // 5) 確定（ここで一斉に審査へ出る）
    console.log('');
    console.log('--- 確定（commit）---');
    must(await api(token, 'POST',
      `/androidpublisher/v3/applications/${PKG}/edits/${eid}:commit`), 'commit');
    committed = true;
    console.log('  ✅ 送信しました');

    // 6) 書いたら読み直す
    const e2 = must(await api(token, 'POST', `/androidpublisher/v3/applications/${PKG}/edits`), '検証用 edit');
    try {
      const t2 = await api(token, 'GET',
        `/androidpublisher/v3/applications/${PKG}/edits/${e2.id}/tracks/${TRACK}`);
      const l2 = must(await api(token, 'GET',
        `/androidpublisher/v3/applications/${PKG}/edits/${e2.id}/listings/${LOCALE}`), '読み直し');
      const i2 = await api(token, 'GET',
        `/androidpublisher/v3/applications/${PKG}/edits/${e2.id}/listings/${LOCALE}/images/phoneScreenshots`);
      console.log('');
      console.log('=== 検証（読み直し）===');
      for (const r of (t2.json?.releases ?? [])) {
        console.log(`  リリース   : ${r.name} / versionCode ${(r.versionCodes ?? []).join(',')} / ${r.status}`);
      }
      console.log(`  詳しい説明 : ${chars(l2.fullDescription)}字 / 「3種族」${l2.fullDescription.includes('3種族') ? '⚠️残存' : 'なし ✅'} / 「4種族」${l2.fullDescription.includes('4種族') ? 'あり ✅' : '⚠️無い'}`);
      console.log(`  スクショ   : ${(i2.json?.images ?? []).length} 枚`);
    } finally {
      await api(token, 'DELETE', `/androidpublisher/v3/applications/${PKG}/edits/${e2.id}`);
    }
  } finally {
    if (!committed) {
      await api(token, 'DELETE', `/androidpublisher/v3/applications/${PKG}/edits/${eid}`);
      console.log('（未確定の下書きは破棄しました）');
    }
  }
}

main().catch((e) => fail(String(e?.message || e)));
