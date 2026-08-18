// SNS投稿文の文字数チェッカー。
//
// X は「重み付き文字数」で 280 が上限。半角英数=1、日本語/全角=2 で数えるため
// 日本語だけなら実質 140 文字。URL は実際の長さに関係なく一律 23 として数えられる。
// 目視では絶対に数え間違えるので、投稿前に必ずこれに通す。
//
// Usage:
//   node tools/sns/count_chars.mjs path/to/post.txt
//   echo "本文" | node tools/sns/count_chars.mjs
import fs from 'node:fs';

const LIMITS = { x: 280, threads: 500, instagram: 2200 };

// X の weighted length。既定は重み2、下の範囲だけ重み1。
// 出典: X の twitter-text 設定 v3（defaultWeight:200 / ranges weight:100 を 1/100 したもの）
const LIGHT_RANGES = [
  [0x0000, 0x10ff],
  [0x2000, 0x200d],
  [0x2010, 0x201f],
  [0x2032, 0x2037],
];
const isLight = (cp) => LIGHT_RANGES.some(([lo, hi]) => cp >= lo && cp <= hi);

function xWeightedLength(text) {
  // URL は一律 23 文字として数えられる（t.co 短縮のため）
  const urls = text.match(/https?:\/\/\S+/g) || [];
  const stripped = text.replace(/https?:\/\/\S+/g, '');
  let w = 0;
  for (const ch of stripped) w += isLight(ch.codePointAt(0)) ? 1 : 2;
  return w + urls.length * 23;
}

// 人が数える「文字数」。絵文字や結合文字を1と数える。
const graphemeLength = (t) => [...new Intl.Segmenter('ja', { granularity: 'grapheme' }).segment(t)].length;

const file = process.argv[2];
const text = file ? fs.readFileSync(file, 'utf8') : fs.readFileSync(0, 'utf8');

const xw = xWeightedLength(text);
const g = graphemeLength(text);
const tags = text.match(/(?:^|\s)#[^\s#]+/g) || [];

console.log('--- 文字数 ---');
console.log(`X 重み付き        : ${xw} / ${LIMITS.x}   ${xw <= LIMITS.x ? '✅ OK' : '❌ 超過 ' + (xw - LIMITS.x)}`);
console.log(`  （日本語換算    : ${(xw / 2).toFixed(1)} / 140 文字相当）`);
console.log(`見た目の文字数    : ${g}`);
console.log(`Threads (500)     : ${g <= LIMITS.threads ? '✅ OK' : '❌ 超過 ' + (g - LIMITS.threads)}`);
console.log(`Instagram (2200)  : ${g <= LIMITS.instagram ? '✅ OK' : '❌ 超過 ' + (g - LIMITS.instagram)}`);
console.log(`ハッシュタグ数    : ${tags.length}${tags.length ? '  ' + tags.map((t) => t.trim()).join(' ') : ''}`);
if (tags.length > 5) console.log('  ⚠️ Instagram は 2025-12 以降ハッシュタグ上限5個。3〜5個に絞ること');

// 行頭の空白は端末で崩れる（オーナー指定の禁止事項）
const indented = text.split('\n').map((l, i) => [i + 1, l]).filter(([, l]) => /^[ 　\t]+/.test(l));
console.log('\n--- 体裁 ---');
console.log(indented.length ? `❌ 行頭に空白あり: ${indented.map(([n]) => n + '行目').join(', ')}` : '✅ 行頭の空白なし');
const trailing = text.split('\n').map((l, i) => [i + 1, l]).filter(([, l]) => /[ 　\t]+$/.test(l));
console.log(trailing.length ? `⚠️ 行末に空白あり: ${trailing.map(([n]) => n + '行目').join(', ')}` : '✅ 行末の空白なし');
