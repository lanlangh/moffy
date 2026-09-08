// Google Play のストア掲載情報（説明文・スクリーンショット）を更新する。
//
// Usage:
//   node tools/play/play_update_listing.mjs <serviceAccountJson> <packageName> [apply|apply-hold]
//   末尾に何も付けないと dry-run（読むだけ・既定）
//   apply-hold … 保存はするが **審査には出さない**（commit?changesNotSentForReview=true）。
//                Play Console の「審査のために送信」を押すまで公開されない。
//                オーナーが最終ボタンを押す運用のときはこちら。
//   apply      … 保存して**そのまま審査に出す**。
//
// 何を更新するか:
//   * 詳しい説明 … docs/store/play_description.txt
//   * スクリーンショット（スマートフォン）… docs/store/screenshots/android/01〜05
//   * ストアアイコン … docs/store/store_icon_512.png
//     【2026-09-08 追加】アプリのアイコンを8月に変えたのに Play の掲載アイコンだけ
//     7月のオレンジ背景版のまま取り残されていた。このツールが説明文とスクショしか
//     触らなかったのが原因。以後アイコンもここで面倒を見る。
//     中身が同じなら何もしない（無意味な審査を発生させないため）。
//
// ⚠️ **タイトルと簡単な説明は触らない。**
//    iOS で名前を変えたが Play は別管理で、変えると検索順位が動く。意図しない変更を避ける。
//
// ⚠️ 変更は edit に溜まり、**commit するまで公開されない**。
//    このスクリプトは掲載情報だけを更新して commit する（AAB とは別の edit）。
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { loadServiceAccount, getToken, api, must } from './play_api.mjs';

const [, , SA_PATH, PKG, MODE = 'dry-run'] = process.argv;
// HOLD=審査に出さずに保存だけ。APPLY はどちらのモードでも書き込みを行う。
const HOLD = MODE === 'apply-hold';
const APPLY = MODE === 'apply' || HOLD;
if (!SA_PATH || !PKG) {
  console.error('args: <serviceAccountJson> <packageName> [apply]');
  process.exit(2);
}

const LOCALE = 'ja-JP';
const REPO = path.resolve(path.dirname(new URL(import.meta.url).pathname.replace(/^\//, '')), '..', '..');
const DESC_FILE = path.join(REPO, 'docs', 'store', 'play_description.txt');
const SHOTS = ['01_home.png', '02_eggs.png', '03_dex.png', '04_shiny.png', '05_quests.png']
  .map((f) => path.join(REPO, 'docs', 'store', 'screenshots', 'android', f));
const ICON_FILE = path.join(REPO, 'docs', 'store', 'store_icon_512.png');

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

  // ストアアイコン: Play の仕様は 512x512 / PNG / 1MB以下。書き込む前に弾く。
  const iconBuf = fs.readFileSync(ICON_FILE);
  if (iconBuf.toString('ascii', 1, 4) !== 'PNG') fail('store_icon_512.png が PNG ではない');
  const iw = iconBuf.readUInt32BE(16);
  const ih = iconBuf.readUInt32BE(20);
  if (iw !== 512 || ih !== 512) fail(`アイコンが ${iw}x${ih}＝512x512 ではない`);
  if (iconBuf.length > 1024 * 1024) fail(`アイコンが ${(iconBuf.length / 1024).toFixed(0)}KB＝上限1MB超過`);
  const iconSha = crypto.createHash('sha256').update(iconBuf).digest('hex');
  console.log('=== ストアアイコン ===');
  console.log(`  ${iw}x${ih}  ${(iconBuf.length / 1024).toFixed(0)}KB  ✅ 検査通過`);
  console.log('');

  const sa = loadServiceAccount(SA_PATH);
  const token = await getToken(sa);
  const edit = must(await api(token, 'POST', `/androidpublisher/v3/applications/${PKG}/edits`), 'edit の作成');
  const eid = edit.id;
  let committed = false;

  try {
    const cur = must(await api(token, 'GET',
      `/androidpublisher/v3/applications/${PKG}/edits/${eid}/listings/${LOCALE}`), '現在の掲載情報');
    // 現在のアイコンと中身を比べる。同じなら触らない（審査を無駄に発生させない）。
    const curIcon = await api(token, 'GET',
      `/androidpublisher/v3/applications/${PKG}/edits/${eid}/listings/${LOCALE}/icon`);
    const remoteIconSha = (curIcon.json?.images ?? [])[0]?.sha256 ?? null;
    const iconNeedsUpdate = remoteIconSha !== iconSha;

    console.log('=== 現在の掲載情報 ===');
    console.log(`  タイトル   : ${cur.title}（変更しません）`);
    console.log(`  簡単な説明 : ${chars(cur.shortDescription)}字（変更しません）`);
    console.log(`  詳しい説明 : ${chars(cur.fullDescription)}字 → ${n}字 に更新`);
    console.log(`  アイコン   : ${iconNeedsUpdate ? '⚠️ 中身が違う → 差し替える' : '同じ → 触らない'}`);
    console.log('');

    if (!APPLY) {
      console.log('[dry-run] 読むだけで終了しました。');
      console.log('          apply-hold … 保存するが審査には出さない（Console で送信ボタンを押すまで公開されない）');
      console.log('          apply      … 保存してそのまま審査に出す');
      return;
    }
    console.log(HOLD
      ? '※ モード: apply-hold（保存のみ・審査には出しません）'
      : '※ モード: apply（保存して審査に出します）');

    // --- 詳しい説明だけ差し替える。title / shortDescription は現在値をそのまま返す ---
    console.log('--- 説明文を更新 ---');
    const up = await api(token, 'PATCH',
      `/androidpublisher/v3/applications/${PKG}/edits/${eid}/listings/${LOCALE}`,
      { body: { fullDescription: desc } });
    must(up, '説明文の更新');
    console.log('  ✅ 更新');

    // --- ストアアイコン（中身が違うときだけ）---
    if (iconNeedsUpdate) {
      console.log('--- ストアアイコンを差し替え ---');
      const dIcon = await api(token, 'DELETE',
        `/androidpublisher/v3/applications/${PKG}/edits/${eid}/listings/${LOCALE}/icon`);
      console.log(`  既存を削除 HTTP ${dIcon.status}`);
      must(await api(token, 'POST',
        `/upload/androidpublisher/v3/applications/${PKG}/edits/${eid}/listings/${LOCALE}/icon`,
        { body: iconBuf, contentType: 'image/png', query: { uploadType: 'media' } }),
        'アイコンのアップロード');
      console.log('  ✅ 差し替え');
    } else {
      console.log('--- ストアアイコンは中身が同じなので触らない ---');
    }

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
    console.log(HOLD ? '--- 確定（commit・審査には出さない）---' : '--- 確定（commit・審査に出す）---');
    must(await api(token, 'POST',
      `/androidpublisher/v3/applications/${PKG}/edits/${eid}:commit`,
      // changesNotSentForReview=true を付けると、変更は保存されるが審査には送られない。
      // Play Console の「審査のために送信」を押すまで公開されない（公式: edits.commit）。
      HOLD ? { query: { changesNotSentForReview: 'true' } } : undefined), 'commit');
    committed = true;
    console.log(HOLD
      ? '  ✅ 保存しました（まだ審査には出していません）'
      : '  ✅ 審査に出しました');

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
      const ic2 = await api(token, 'GET',
        `/androidpublisher/v3/applications/${PKG}/edits/${e2.id}/listings/${LOCALE}/icon`);
      const gotIcon = (ic2.json?.images ?? [])[0]?.sha256 ?? null;
      console.log(`  アイコン   : ${gotIcon === iconSha ? 'ローカルと一致 ✅' : '⚠️ 一致しない'}`);
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
