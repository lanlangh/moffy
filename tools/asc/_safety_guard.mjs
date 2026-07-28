// App Store Connect に対して「取り返しのつかない書き込み」を行うスクリプトの安全停止。
//
// 背景（2026-07-28）:
//   iOS のサブスク3点が却下済み提出物 755e8857-3ab8-421d-bdc1-e4642569acb4 に取り残され
//   IN_REVIEW で固着している。この提出物の中の「削除済み」item は、**いま App Store で
//   販売中の appStoreVersion 7824865b-b21f-4ce3-b76d-3da9ad85bb73 (READY_FOR_SALE) を
//   今も参照している**。Apple 公式は「提出物にアプリバージョンが含まれていれば、キャンセル
//   時にそのステータスは Developer Rejected になる」と明記しており、item が REMOVED でも
//   除外されるという但し書きは無い。
//   ＝ この提出物へのキャンセル/削除は、公開中の iOS アプリを取り下げる経路になりうる。
//
//   復旧方針は「触らずに Apple のサポートに人力で解除してもらう」に確定済み。
//   → docs/asc/APPLE_SUBSCRIPTION_STUCK_CONTACT.md
//
// 封印を解くのは、Apple から明示の指示があったとき、または方針を変更したときだけ。

const OVERRIDE = 'i-really-mean-it';

/// 破壊的操作を行うスクリプトの冒頭で呼ぶ。許可されていなければ即座に終了する。
export function assertDestructiveAllowed(scriptName) {
  if (process.env.ASC_ALLOW_DESTRUCTIVE === OVERRIDE) {
    console.warn(`⚠️  ${scriptName}: 安全停止を解除して実行します（ASC_ALLOW_DESTRUCTIVE 指定あり）`);
    return;
  }
  console.error('');
  console.error(`⛔ 安全停止: ${scriptName} は現在封印されています。`);
  console.error('');
  console.error('   このスクリプトは reviewSubmission に対して破壊的な書き込み');
  console.error('   (DELETE / PATCH canceled) を行います。膠着中の提出物 755e8857 は');
  console.error('   公開中の iOS 1.0 を今も参照しており、実行すると App Store から');
  console.error('   アプリが取り下げられる可能性があります。');
  console.error('');
  console.error('   → docs/asc/APPLE_SUBSCRIPTION_STUCK_CONTACT.md を読むこと。');
  console.error(`   → どうしても必要なら ASC_ALLOW_DESTRUCTIVE=${OVERRIDE} を明示する。`);
  console.error('');
  process.exit(1);
}
