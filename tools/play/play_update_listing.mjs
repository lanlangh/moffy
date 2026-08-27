// Google Play のストア掲載情報（説明文・スクリーンショット）を更新する。
//
// Usage:
//   node tools/play/play_update_listing.mjs <serviceAccountJson> <packageName> [apply]
//   末尾の apply を付けないと dry-run（読むだけ・既定）
//
// 何を更新するか:
//   * 詳しい説明 … docs/store/play_description.txt
//   * スクリーンショット（スマートフォン）… docs/store/screenshots/01〜05
//
// ⚠️ **タイトルと簡単な説明は触らない。**
//    iOS で名前を変えたが Play は別管理で、変えると検索順位が動く。意図しない変更を避ける。
//
// ⚠️ 変更は edit に溜まり、**commit するまで公開されない**。
//    このスクリプトは掲載情報だけを更新して commit する（AAB とは別の edit）。
import fs from 'node:fs';
import path from 'node:path';
import { loadServiceAccount, getToken, api, must } from './play_api.mjs';

const [, , SA_PATH, PKG, MODE = 'dry-run'] = process.argv;
const APPLY = MODE === 'apply';
if (!SA_PATH || !PKG) {
  console.error('args: <serviceAccountJson> <packageName> [apply]');
  process.exit(2);
}

const LOCALE = 'ja-JP';
const REPO = path.resolve(path.dirname(new URL(import.meta.url).pathname.replace(/^\//, '')), '..', '..');
const DESC_FILE = path.join(REPO, 'docs', 'store', 'play_description.txt');
const SHOTS = ['01_home.png', '02_eggs.png', '03_dex.png', '04_shiny.png', '05_quests.png']
  .map((f) => path.join(REPO, 'docs', 'store', 'screenshots', 'android', f));

const fail = (m, extra) => {
  console.error('❌ ' + m);
  if (extra) console.error('   ' + extra);
  process.exit(1);
};

const chars = (s) => (s ? [...s].length : 0);

function checkDescription(text) {
  const n = chars(text);
  if (n === 0) fail('説明文が空');
  if (n > 4000) fail(`説明文が ${n} 字＝上限4000字を超過`);
  // 実装と食い違う表記・他ストアの記述を弾く（景表法／正確性）
  const ng = [
    ['3種族', '実装は4種族'],
    ['App Store', 'Android の掲載文に iOS の解約先が混ざっている'],
    ['iPhone', 'Android の掲載文に iOS 固有の記述が混ざっている'],
  ].filter(([w]) => text.includes(w));
  if (ng.length) {
    fail('説明文に不適切な記述があります:\n' + ng.map(([w, why]) => `   「${w}」… ${why}`).join('\n'));
  }
  if (!text.includes('4種族')) {
    fail('説明文に「4種族」が含まれていません（実装と一致しているか確認してください）');
  }
  return n;
}

async function main() {
  const desc = fs.readFileSync(DESC_FILE, 'utf8').trim();
  const n = checkDescription(desc);
  console.log(`=== 流し込む説明文 ===\n  ${DESC_FILE}\n  ${n} / 4000字  ✅ 検査通過\n`);

  console.log('=== スクリーンショット ===');
  for (const p of SHOTS) {
    const st = fs.statSync(p);
    console.log(`  ${path.basename(p)}  ${(st.size / 1024).toFixed(0)}KB`);
  }
  console.log('');

  const sa = loadServiceAccount(SA_PATH);
  const token = await getToken(sa);
  const edit = must(await api(token, 'POST', `/androidpublisher/v3/applications/${PKG}/edits`), 'edit の作成');
  const eid = edit.id;
  let committed = false;

  try {
    const cur = must(await api(token, 'GET',
      `/androidpublisher/v3/applications/${PKG}/edits/${eid}/listings/${LOCALE}`), '現在の掲載情報');
    console.log('=== 現在の掲載情報 ===');
    console.log(`  タイトル   : ${cur.title}（変更しません）`);
    console.log(`  簡単な説明 : ${chars(cur.shortDescription)}字（変更しません）`);
    console.log(`  詳しい説明 : ${chars(cur.fullDescription)}字 → ${n}字 に更新`);
    console.log('');

    if (!APPLY) {
      console.log('[dry-run] 読むだけで終了しました。実行するには末尾に apply を指定してください。');
      console.log('          （変更は commit するまで公開されません）');
      return;
    }

    // --- 詳しい説明だけ差し替える。title / shortDescription は現在値をそのまま返す ---
    console.log('--- 説明文を更新 ---');
    const up = await api(token, 'PATCH',
      `/androidpublisher/v3/applications/${PKG}/edits/${eid}/listings/${LOCALE}`,
      { body: { fullDescription: desc } });
    must(up, '説明文の更新');
    console.log('  ✅ 更新');

    // --- スクリーンショットを入れ替える（全消し → 5枚を順に投入）---
    console.log('--- スクリーンショットを入れ替え ---');
    const del = await api(token, 'DELETE',
      `/androidpublisher/v3/applications/${PKG}/edits/${eid}/listings/${LOCALE}/phoneScreenshots`);
    console.log(`  既存を削除 HTTP ${del.status}`);
    for (const p of SHOTS) {
      const buf = fs.readFileSync(p);
      const res = await api(token, 'POST',
        `/upload/androidpublisher/v3/applications/${PKG}/edits/${eid}/listings/${LOCALE}/phoneScreenshots`,
        { body: buf, contentType: 'image/png', query: { uploadType: 'media' } });
      must(res, `${path.basename(p)} のアップロード`);
      console.log(`  ✅ ${path.basename(p)}`);
    }

    // --- 確定（ここで公開される）---
    console.log('');
    console.log('--- 確定（commit）---');
    must(await api(token, 'POST',
      `/androidpublisher/v3/applications/${PKG}/edits/${eid}:commit`), 'commit');
    committed = true;
    console.log('  ✅ 反映しました');

    // --- 書いたら読み直す ---
    const e2 = must(await api(token, 'POST', `/androidpublisher/v3/applications/${PKG}/edits`), '検証用 edit');
    try {
      const after = must(await api(token, 'GET',
        `/androidpublisher/v3/applications/${PKG}/edits/${e2.id}/listings/${LOCALE}`), '読み直し');
      const imgs = await api(token, 'GET',
        `/androidpublisher/v3/applications/${PKG}/edits/${e2.id}/listings/${LOCALE}/phoneScreenshots`);
      console.log('');
      console.log('=== 検証（読み直し）===');
      console.log(`  詳しい説明 : ${chars(after.fullDescription)}字`);
      console.log(`  「3種族」  : ${after.fullDescription.includes('3種族') ? '⚠️ 残っている' : 'なし ✅'}`);
      console.log(`  「4種族」  : ${after.fullDescription.includes('4種族') ? 'あり ✅' : '⚠️ 無い'}`);
      console.log(`  スクショ   : ${(imgs.json?.images ?? []).length} 枚`);
    } finally {
      await api(token, 'DELETE', `/androidpublisher/v3/applications/${PKG}/edits/${e2.id}`);
    }
  } finally {
    if (!committed) {
      // commit していない edit は破棄する（下書きを放置しない）
      await api(token, 'DELETE', `/androidpublisher/v3/applications/${PKG}/edits/${eid}`);
    }
  }
}

main().catch((e) => fail(String(e?.message || e)));
