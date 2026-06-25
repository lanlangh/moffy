'use strict';
// gpc-mcp ドロップインセットアップ
//   1. mcp-server.mjs と package.json を .claude/gpc/ にコピー
//   2. .claude/gpc/ で `npm install --omit=dev` を実行（依存: SDK / google-auth-library / zod）
//   3. .claude/settings.local.json の mcpServers['google-play'] を登録（秘密情報はパスのみ）
//   4. .gitignore に .claude/settings.local.json と .claude/gpc/ を追記
//
// ⚠️ セキュリティ: サービスアカウント JSON の「中身」は一切書かない。パスのプレースホルダのみ。

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const projectRoot = process.argv[2] || process.cwd();
const scriptDir = __dirname;

const claudeDir = path.join(projectRoot, '.claude');
const gpcDir = path.join(claudeDir, 'gpc');
const serverDst = path.join(gpcDir, 'mcp-server.mjs');
const serverSrc = path.join(scriptDir, 'mcp-server.mjs');
const pkgDst = path.join(gpcDir, 'package.json');
const pkgSrc = path.join(scriptDir, 'package.json');
const settingsPath = path.join(claudeDir, 'settings.local.json');
const gitignorePath = path.join(projectRoot, '.gitignore');

// 設定エントリ。秘密情報は書かず、パスのプレースホルダのみ。
const SA_PATH_PLACEHOLDER = '<ここにサービスアカウントJSONの絶対パスを記入>';
const mcpEntry = {
  command: 'node',
  args: [serverDst],
  env: {
    // サービスアカウント JSON の絶対パス（中身は書かない。ユーザーが手で設定）
    GOOGLE_PLAY_SA_JSON_PATH: SA_PATH_PLACEHOLDER,
    // 既定 packageName（任意。例: com.moffy.app）
    GOOGLE_PLAY_PACKAGE_NAME: '',
  },
};

// --- 1. .claude/gpc/ を作成しファイルをコピー -------------------------------
fs.mkdirSync(gpcDir, { recursive: true });
fs.copyFileSync(serverSrc, serverDst);
fs.copyFileSync(pkgSrc, pkgDst);
console.log('Copied mcp-server.mjs and package.json to .claude/gpc/');

// --- 2. 依存をインストール ---------------------------------------------------
console.log('Installing dependencies in .claude/gpc/ (npm install --omit=dev) ...');
const npmCmd = process.platform === 'win32' ? 'npm.cmd' : 'npm';
const install = spawnSync(npmCmd, ['install', '--omit=dev'], {
  cwd: gpcDir,
  stdio: 'inherit',
  shell: process.platform === 'win32', // Windows では npm.cmd 解決のため shell:true
});
if (install.status !== 0) {
  console.error('\n[ERROR] npm install に失敗しました。');
  console.error(`  ディレクトリ: ${gpcDir}`);
  console.error('  Node 18+ と npm が利用可能か確認し、手動で次を実行してください:');
  console.error(`    cd "${gpcDir}" && npm install --omit=dev`);
  process.exit(install.status || 1);
}
console.log('Dependencies installed.');

// --- 3. settings.local.json をマージ ----------------------------------------
let settings = {};
if (fs.existsSync(settingsPath)) {
  try {
    let content = fs.readFileSync(settingsPath, 'utf8');
    if (content.charCodeAt(0) === 0xfeff) content = content.slice(1); // Strip UTF-8 BOM
    settings = JSON.parse(content);
    console.log('Existing settings.local.json loaded.');
  } catch (e) {
    fs.copyFileSync(settingsPath, settingsPath + '.bak');
    console.error('Could not parse existing settings.local.json.');
    console.error('Backed up to settings.local.json.bak — please check manually.');
    settings = {};
  }
}

if (!settings.mcpServers) settings.mcpServers = {};

if (settings.mcpServers['google-play']) {
  console.log("Already configured (mcpServers['google-play']). Skipping settings update.");
} else {
  settings.mcpServers['google-play'] = mcpEntry;
  fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2), 'utf8');
  console.log("Added Google Play MCP to settings.local.json (mcpServers['google-play']).");
}

// --- 4. .gitignore 追記 ------------------------------------------------------
const gitignoreEntries = ['.claude/settings.local.json', '.claude/gpc/'];
let gitignoreContent = '';
if (fs.existsSync(gitignorePath)) {
  gitignoreContent = fs.readFileSync(gitignorePath, 'utf8');
}
// 既存エントリは「行単位の完全一致」で判定する（includes の部分一致だと、
// 否定パターン(!...) やコメント行を誤検出し、肝心の無視設定を追記し損ねて
// 鍵を保護できない恐れがある / QA H2）。appendFileSync はファイル不在時に新規作成する。
const existingLines = new Set(gitignoreContent.split(/\r?\n/).map((l) => l.trim()));
const toAppend = gitignoreEntries.filter((e) => !existingLines.has(e));
if (toAppend.length) {
  const prefix = gitignoreContent && !gitignoreContent.endsWith('\n') ? '\n' : '';
  fs.appendFileSync(gitignorePath, prefix + toAppend.join('\n') + '\n');
  console.log(`Updated .gitignore (${toAppend.join(', ')})`);
}

// --- 完了案内 ----------------------------------------------------------------
console.log('\n========================================================');
console.log('Done! 次の手順を必ず実施してください:');
console.log('');
console.log('  1) .claude/settings.local.json を開き、');
console.log("     mcpServers['google-play'].env.GOOGLE_PLAY_SA_JSON_PATH を");
console.log('     実際のサービスアカウント JSON の「絶対パス」に書き換える。');
console.log(`     （現在は仮値: "${SA_PATH_PLACEHOLDER}"）`);
console.log('     ※ JSON の中身ではなくパスを設定。鍵ファイルはリポジトリ外に置くこと。');
console.log('');
console.log('  2) （任意）GOOGLE_PLAY_PACKAGE_NAME に既定 packageName を設定（例: com.moffy.app）。');
console.log('');
console.log('  3) Claude Code を一度再起動すると Google Play ツールが使えます。');
console.log('========================================================');
