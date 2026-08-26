// Google Play の現状を **読むだけ** で確認する（Node 24 / 依存なし）。
//
// Usage:
//   node tools/play/play_diagnose.mjs <serviceAccountJson> <packageName>
//
// 何を見るか:
//   * サービスアカウントで認証が通るか（＝権限が正しく付いたか）
//   * いま製品版で配信されている versionCode
//   * ストア掲載情報（タイトル・簡単な説明・詳しい説明の字数）
//   * スクリーンショットの枚数
//
// ⚠️ 書き込みは一切しない。edits も **作らない**（読み取りは edits なしで可能なものだけ）。
//    ただし Play API は多くの読み取りにも edit が要るため、必要な場合は
//    **作って即座に破棄する**（insert → get → delete）。delete は自分が作った edit のみ。
import { loadServiceAccount, getToken, api, must } from './play_api.mjs';

const [, , SA_PATH, PKG] = process.argv;
if (!SA_PATH || !PKG) {
  console.error('args: <serviceAccountJson> <packageName>');
  console.error('例: node tools/play/play_diagnose.mjs secrets/play-sa.json com.moffy.app');
  process.exit(2);
}

const fail = (m, extra) => {
  console.error('❌ ' + m);
  if (extra) console.error('   ' + extra);
  process.exit(1);
};

async function main() {
  const sa = loadServiceAccount(SA_PATH);
  console.log('=== サービスアカウント ===');
  console.log(`  ${sa.client_email}`);
  console.log('');

  let token;
  try {
    token = await getToken(sa);
  } catch (e) {
    fail('認証に失敗しました。', String(e.message).slice(0, 300));
  }
  console.log('✅ 認証OK（アクセストークンを取得）');
  console.log('');

  // --- edit を作る（読み取りに必要。最後に必ず破棄する）---
  const ins = await api(token, 'POST', `/androidpublisher/v3/applications/${PKG}/edits`);
  if (ins.status === 401 || ins.status === 403) {
    fail(
      'Play Console 側の権限が足りません。',
      'Play Console → ユーザーと権限 で、このサービスアカウントに\n' +
      '   「本番環境へのリリース…」と「ストアの表示を管理」を付けてください。',
    );
  }
  const edit = must(ins, 'edit の作成');
  const editId = edit.id;

  try {
    console.log('=== 製品版で配信中のもの ===');
    const tr = await api(token, 'GET',
      `/androidpublisher/v3/applications/${PKG}/edits/${editId}/tracks/production`);
    if (tr.status === 200) {
      const rel = tr.json?.releases ?? [];
      if (!rel.length) console.log('  （リリースなし）');
      for (const r of rel) {
        const codes = (r.versionCodes ?? []).join(', ');
        console.log(`  name=${r.name ?? '(名前なし)'}  versionCode=${codes}  status=${r.status}` +
          (r.userFraction != null ? `  配信割合=${Math.round(r.userFraction * 100)}%` : ''));
      }
    } else {
      console.log(`  取得できず HTTP ${tr.status}`);
    }
    console.log('');

    console.log('=== ストア掲載情報（ja-JP）===');
    const li = await api(token, 'GET',
      `/androidpublisher/v3/applications/${PKG}/edits/${editId}/listings/ja-JP`);
    if (li.status === 200) {
      const a = li.json ?? {};
      const n = (s) => (s ? [...s].length : 0);
      console.log(`  タイトル     : ${a.title ?? '(なし)'} (${n(a.title)}/30)`);
      console.log(`  簡単な説明   : ${n(a.shortDescription)}/80字`);
      console.log(`  詳しい説明   : ${n(a.fullDescription)}/4000字`);
      const d = a.fullDescription ?? '';
      const ng = ['3種族', 'App Store', 'iPhone'].filter((w) => d.includes(w));
      console.log(`  iOS向けの記述: ${ng.length ? '⚠️ ' + ng.join(', ') : 'なし'}`);
    } else {
      console.log(`  取得できず HTTP ${li.status}`);
    }
    console.log('');

    console.log('=== スクリーンショット（ja-JP / スマートフォン）===');
    const im = await api(token, 'GET',
      `/androidpublisher/v3/applications/${PKG}/edits/${editId}/listings/ja-JP/phoneScreenshots`);
    if (im.status === 200) {
      const imgs = im.json?.images ?? [];
      console.log(`  ${imgs.length} 枚`);
    } else {
      console.log(`  取得できず HTTP ${im.status}`);
    }
  } finally {
    // 読むだけなので必ず破棄する（下書きを放置しない）
    await api(token, 'DELETE', `/androidpublisher/v3/applications/${PKG}/edits/${editId}`);
    console.log('');
    console.log('（読み取り用の下書きは破棄しました。書き込みは一切していません）');
  }
}

main().catch((e) => fail(String(e?.message || e)));
