# Android 公開ランブック（v1.0・オーナー操作手順）

最終更新日：2026年7月8日 ／ 対象：Moffy v1.0 Android（**配信国＝日本限定**・課金オンで公開）

> **分担**：Play Console / RevenueCat の**ログイン操作・商品作成・フォーム記入・実購入は Claude では代行不可**（アカウント権限と実機が必要）。Claude は AABビルド・RevenueCatキーの本番注入・各種資料・画面ごとの案内を担当。**詰まったら画面のスクショを Claude に送ってください。**

## キー値（コピペ用・唯一の正＝`lib/core/constants/pricing.dart`）

| 項目 | 値 |
|---|---|
| パッケージ名（applicationId） | `com.moffy.app` |
| 月額サブスク Product ID | `moffy_premium_monthly` |
| 年額サブスク Product ID | `moffy_premium_yearly` |
| 月額 価格 | ¥480 / 月（自動更新） |
| 年額 価格 | ¥4,800 / 年（自動更新・約17%OFF） |
| 無料トライアル | 7日間（両商品） |
| Entitlement（RevenueCat） | `premium` |
| Offering（RevenueCat） | `default` |
| パッケージ識別子 | 月額 `$rc_monthly` / 年額 `$rc_annual` |
| プライバシーポリシーURL | `https://mud-nectarine-0f9.notion.site/Moffy-38a1efa9943a805f8af3d7c7b8ee5753` |
| 利用規約URL | `https://mud-nectarine-0f9.notion.site/Moffy-38a1efa9943a809d8467ca9c8f9bf076` |
| 特商法表記URL | `https://mud-nectarine-0f9.notion.site/Moffy-38a1efa9943a80a8b569d2102a2eb48a` |
| 問い合わせ／削除窓口メール | `info@lan-corp.com` |

---

## ② 課金を動かす

### Step 2-1　署名AABを「内部テスト」にアップロード（＝サブスク作成の解禁キー）
1. **AABは Claude が用意**（`Build AAB` ワークフロー → `moffy-release-aab` をダウンロード）。※「AAB作って」で最新を回す。
2. Play Console → アプリ「Moffy」→ 左メニュー「**テスト → 内部テスト**」→「**新しいリリースを作成**」。
3. AAB をアップロード → 保存 → 「リリースをレビュー」→ **公開（ロールアウト）**。
4. 「テスター」タブで自分のGoogleアカウントを含むテスターリストを設定し、オプトインURLから参加。

> 初回は「アプリの完全性（署名）」「アプリのアクセス権」等の設定を求められることあり。**画面が出たらスクショを送ってください。**

### Step 2-2　サブスク2商品を作成
Play Console →「**収益化 → 商品 → サブスクリプション**」→「サブスクリプションを作成」。上のキー値を**コピペ**（1字も違えない）。
- 月額：ID `moffy_premium_monthly` / 基本プラン=月額 ¥480・自動更新
- 年額：ID `moffy_premium_yearly` / 基本プラン=年額 ¥4,800・自動更新
- 両方に **オファー＝無料トライアル7日間** を追加。
- 商品を **有効化（アクティブ）** にする。

### Step 2-3　RevenueCat 設定
1. RevenueCat → プロジェクト「Moffy」→「Credentials need attention」を解消（Google Play サービスアカウントの権限反映）。
2. **Products**：上の2商品を登録（同じID）。
3. **Entitlement** `premium` を作成 → 2商品を **attach**。
4. **Offering** `default` → パッケージ `$rc_monthly`（月額）/ `$rc_annual`（年額）。
5. **Android の公開SDKキー（`goog_...`）をコピー → Claude に渡す**。→ Claude が GitHub Secret 化して本番ビルドに注入（＝Claude担当）。

### Step 2-4　サンドボックスで実購入テスト（6項目チェックリスト）
1. Play Console →「設定 → ライセンステスト」に自分のGoogleアカウントを登録。
2. RevenueCatキー入りAAB（Claudeが用意）を内部テストで配布 → エミュレータ（Google Play services入り）にインストール。
3. 課金画面から購入し、下を順に確認：

- [ ] **① トライアル開始**：7日無料が開始され、`premium` が**即有効**になる
- [ ] **② 特典解放**：保管枠が **20→200** に解放される（サーバー検証経由）
- [ ] **③ 解約**：解約すると更新停止 → 期間終了後に `premium` が**失効**する
- [ ] **④ 返金/期限切れ**：返金・期限切れで特典が**剥奪**される
- [ ] **⑤ 復元**：別端末で「購入を復元」→ 連携アカウントで `premium` が**復元**される
- [ ] **⑥ Webhook反映**：購入/更新/解約が **サーバー（Supabase entitlements）に反映**される

> サンドボックスは更新が短縮される。⑤⑥は連携アカウント＋Webhook本番接続が前提。

---

## ③ 提出（Play Console）

### 3-1　ストア掲載情報
- **アプリ名／短い説明／詳細な説明**：`docs/ASO.md` の確定文言を使用（価格は説明文にのみ記載可）。
- **スクリーンショット**：`docs/ASO.md` §4 の6枚構成。**価格/「無料」/「割引」/トライアル表記はスクショに一切入れない**（審査2.3.7）。SNSロゴ無断使用も不可。端末枠＝Android 1080×1920系。→ 撮影は Web プレビュー or 内部テストの実画面をキャプチャ。
- **アプリアイコン（512×512 PNG）／フィーチャーグラフィック（1024×500）**：要作成（リポジトリに未存在）。→ Claude が用意可（言ってください）。

### 3-2　アプリのコンテンツ（必須の申告）
- **データ安全性**：`docs/legal/PLAY_DATA_SAFETY_ANSWERS.md` を見て転記するだけ。
- **プライバシーポリシーURL**：上のキー値（Notion）を登録。**アプリ内リンク（`legal_links.dart`）と完全一致**させる。
- **広告の有無**：「**はい、広告が含まれます**」を選択（AdMobバナー）。
- **対象年齢／コンテンツのレーティング**：アンケートに回答（**成人向け**・暴力/性表現なし）。child-directed 扱いにしない。
- **アプリのアクセス権**：ログイン不要（匿名で全機能可）だが、必要に応じてレビュー用の案内を記載。

### 3-3　配信設定
- **配信国＝日本のみ**（UMP未実装の回避・法務決定）。
- 価格：無料アプリ（アプリ内課金あり）。
- 内部テスト → （推奨）クローズドテスト → **本番トラックへ手動リリースで審査提出**。

---

## Claude ができること / できないこと

| できる（Claude） | できない＝オーナー操作 |
|---|---|
| AABビルド（無料CI）／RevenueCat公開キーの本番注入（コード）／本シート・データ安全性回答シート・スクショ/アイコン/フィーチャーグラフィック作成／価格表記の実装一致監査／画面ごとの案内 | Play Console・RevenueCat への**ログイン操作**、AABアップロード・**商品作成**・フォーム記入、端末での**実購入テスト** |

## 残タスク（提出前）
- [ ] RevenueCat 公開SDKキー（`goog_...`）を Claude に渡す → 本番ビルドへ注入（Claude）
- [ ] 本番 AdMob アプリID/ユニットID を発行 → テストIDと差し替え（公開直前・Claudeが差し替えPR）
- [ ] Apple Small Business Program 申請（iOS追従前に先行・承認待ち時間を消化）
- [ ] 512アイコン／1024×500フィーチャーグラフィック作成（Claude）

> 本ランブックはAIによる整理で正式な法的/ストア規約の助言ではありません。提出直前に実機・実画面で最終確認してください。
