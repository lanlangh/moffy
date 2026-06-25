# 法務文書 — 公開・運用メモ（内部用・非公開）

このフォルダの3文書は**そのまま公開する本文**です（内部向け注記・AI免責は除去済み）。

## 公開する文書（Notion等で公開 → URLを集約）
| 文書 | ファイル | 公開URLの反映先 |
|---|---|---|
| プライバシーポリシー | `privacy_policy.md` | `lib/features/profile/domain/legal_links.dart` の `privacyPolicy` ＋ ストアのプライバシーURL欄 ＋ `docs/ASO.md` |
| 利用規約 | `terms_of_service.md` | `legal_links.dart` の `termsOfService` |
| 特定商取引法に基づく表記 | `tokushoho.md` | `legal_links.dart` の `commercialTransactions`（課金画面で必須） |

`STORE_DATA_SAFETY.md` は**内部資料（非公開）**。Google Play データ安全性フォーム / App Store プライバシー栄養ラベルの回答マッピング。

## 公開方式（TSUZURUと同一）
Notion 公開ページで公開する（TSUZURU も `notion.site` で公開）。手順は本リポジトリのセッション履歴 / オーナー手順参照。
1. Notion で3ページ作成 → 各 `.md` の中身を貼り付け（Notion は Markdown を取り込める）
2. 各ページを「公開（Web で共有）」→ 公開URLをコピー
3. 3つのURLを開発側に渡す → `legal_links.dart` ＋ ストアのプラポリURL欄 ＋ `docs/ASO.md` に反映（プラポリURLはストア掲載と**完全一致**させること。乖離は審査リジェクト要因）

## 運用上の注意（公開前チェック）
- **最終更新日**：本文は 2026年6月25日 時点。提出直前に内容を改訂した場合は3文書の日付を揃えて更新する。
- **ストア申告との整合**：実装（取得データ・第三者SDK）を変更したら、プライバシーポリシー本文・ストアのデータ安全性/栄養ラベルの**双方を必ず同時に更新**する。
- **電話番号**：特商法は「請求があれば遅滞なく開示」方式（番号非掲載）。公開が必要になった場面（EU DSA等）でのみ業務用番号を使う。
- **専門家確認**：本文書はAIによる整理を含む。正式な法的助言ではないため、販売開始前および紛争時は別途専門家に確認すること。
- **問い合わせ到達性**：`info@lan-corp.com` は審査時に受信可能であること（法人運用Gmailへ転送・運用中）。
