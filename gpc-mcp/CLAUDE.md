# Google Play Console MCP (gpc-mcp)

Google Play Console（Android Publisher API v3）を操作する再利用可能な MCP サーバ。
`gpc-mcp/` フォルダを任意のアプリのリポジトリ直下に置き、setup を一度走らせて
Claude Code を再起動すると、Google Play 操作ツールが使えるようになります。

このフォルダを発見したら、以下を自動で実行してください。

## セットアップ手順

1. `.claude/settings.local.json` に `google-play` の設定があるか確認する
2. なければ次のコマンドを実行する（プロジェクトルートから）:
   ```
   node gpc-mcp/merge-settings.cjs
   ```
   - `mcp-server.mjs` と `package.json` を `.claude/gpc/` にコピーし、
     そこで `npm install --omit=dev`（依存インストール）まで自動実行します。
3. `.claude/settings.local.json` を開き、
   `mcpServers['google-play'].env.GOOGLE_PLAY_SA_JSON_PATH` を
   **実際のサービスアカウント JSON の絶対パス**に書き換える。
   - ⚠️ JSON の「中身」ではなく「パス」を設定します。鍵ファイルは**リポジトリ外**に置くこと。
   - （任意）`GOOGLE_PLAY_PACKAGE_NAME` に既定 packageName（例: `com.moffy.app`）を設定。
4. 完了後、ユーザーに以下を伝える:
   「Google Play の設定が完了しました。`GOOGLE_PLAY_SA_JSON_PATH` を実際の
   サービスアカウント JSON の絶対パスに設定し、**Claude Code を一度再起動**してください。」
5. セットアップ後、`gpc-mcp/` フォルダは削除しても構いません
   （実体は `.claude/gpc/` にコピー済み）。

## セキュリティ（厳守）

- サービスアカウント JSON の**中身は env/ソース/コミットに一切書かない**。**パス渡しのみ**。
- `.claude/settings.local.json` と `.claude/gpc/` は `.gitignore` 済み（自動追記）。
- `gpc-mcp/` 自体に鍵ファイルを置かない。

## 必要なサービスアカウント権限（Google Play Console 側）

1. Google Cloud でサービスアカウントを作成し、JSON 鍵をダウンロード（リポジトリ外に保管）。
2. Google Play Console →「設定」→「API アクセス」でそのサービスアカウントをリンク。
3. アカウントに以下の権限を付与（最低限）:
   - **財務データ、注文、キャンセル調査レポートの閲覧**（レビュー/商品確認に必要）
   - **注文と定期購入の管理**（サブスク/オファーの作成・有効化に必要）
4. 反映に時間がかかる場合があります。`403 permission denied` が出たら権限と反映待ちを確認。

## 認証に使う環境変数

| 変数 | 用途 |
|---|---|
| `GOOGLE_PLAY_SA_JSON_PATH` | サービスアカウント JSON の絶対パス（**最優先**） |
| `GOOGLE_APPLICATION_CREDENTIALS` | 上が無い場合の補助（GoogleAuth 標準変数） |
| `GOOGLE_PLAY_PACKAGE_NAME` | 既定 packageName（任意。各ツールで省略時に使用） |

## 再起動後に使えるツール

| ツール | 対応エンドポイント（Android Publisher v3） | 種別 |
|---|---|---|
| `gpc_list_subscriptions` | GET `/applications/{pkg}/subscriptions` | 参照 |
| `gpc_get_subscription` | GET `/applications/{pkg}/subscriptions/{productId}` | 参照 |
| `gpc_create_subscription` | POST `/applications/{pkg}/subscriptions?productId=` | **破壊的（作成）** |
| `gpc_patch_subscription` | PATCH `/applications/{pkg}/subscriptions/{productId}?updateMask=` | **破壊的（更新）** |
| `gpc_activate_base_plan` | POST `.../subscriptions/{productId}/basePlans/{basePlanId}:activate` | **破壊的（有効化）** |
| `gpc_create_offer` | POST `.../basePlans/{basePlanId}/offers?offerId=` | **破壊的（作成）** |
| `gpc_activate_offer` | POST `.../offers/{offerId}:activate` | **破壊的（有効化）** |
| `gpc_list_inappproducts` | GET `/applications/{pkg}/inappproducts` | 参照 |
| `gpc_list_reviews` | GET `/applications/{pkg}/reviews` | 参照 |

> 破壊的操作（create/patch/activate）は **Google Play に実際に商品を作成/更新/有効化します**。
> 実行前に productId/価格/通貨/地域を必ず確認してください。

## Moffy の具体例

- `packageName` = `com.moffy.app`
- 価格は **micros 単位**（= 円 × 1,000,000）、通貨 `JPY`、地域 `regionCode = JP`
  - 例: ¥480 → `priceMicros = "480000000"`、¥4,800 → `"4800000000"`
- サブスク商品:
  - `moffy_premium_monthly` … ¥480/月（`billingPeriodDuration: "P1M"`）
  - `moffy_premium_yearly` … ¥4,800/年（`billingPeriodDuration: "P1Y"`）
- 無料トライアル: 7 日間（オファーの phase で `duration: "P7D"`、`free: {}`）

### 月額サブスク作成イメージ（`gpc_create_subscription`）

```jsonc
{
  "productId": "moffy_premium_monthly",
  "listings": [
    { "languageCode": "ja-JP", "title": "Moffy プレミアム（月額）",
      "description": "全機能が使い放題。", "benefits": ["広告非表示", "無制限利用"] }
  ],
  "basePlans": [
    {
      "basePlanId": "monthly-autorenew",
      "regionalConfigs": [
        { "regionCode": "JP", "newSubscriberAvailability": true,
          "price": { "currencyCode": "JPY", "units": "480", "nanos": 0 } }
      ],
      "autoRenewingBasePlanType": { "billingPeriodDuration": "P1M" }
    }
  ]
}
```

### 7 日無料トライアルのオファー作成イメージ（`gpc_create_offer`）

```jsonc
{
  "productId": "moffy_premium_monthly",
  "basePlanId": "monthly-autorenew",
  "offerId": "freetrial-7d",
  "regionalConfigs": [ { "regionCode": "JP", "newSubscriberAvailability": true } ],
  "phases": [
    { "duration": "P7D", "recurrenceCount": 1,
      "regionalConfigs": [ { "regionCode": "JP", "free": {} } ] }
  ]
}
```

作成後は `gpc_activate_base_plan` → `gpc_activate_offer` で有効化します。

## ⚠️ 実 API 未検証の注意

本サーバは実 Play API に接続して検証できない環境で作成しています。
リクエスト/レスポンス形状は Android Publisher API v3 公式仕様に合わせていますが、
特に以下は**初回接続時に要確認**です（コード内 `推測` コメント箇所も参照）:

- `:activate` 系（base plan / offer）の **リクエストボディの必須フィールド**
- `gpc_create_subscription` の `basePlans` 内の `price`/`regionalConfigs` の正確なキー名
  （Money は `{ currencyCode, units, nanos }`。`units` は文字列のことがある点に注意）
- オファー phase の無料トライアル表現（`free: {}` vs `price` 指定）

不一致があれば Google API のエラーメッセージ（本サーバはそのまま伝播）を見て調整してください。
```
