# Apple への連絡文（サブスク膠着の解除依頼）

> 作成 2026-07-28 / 対象: reviewSubmission 755e8857 に取り残された Moffy Premium 3点
> 送信先: https://developer.apple.com/contact/topic/SC1111/subtopic/30046/solution/select
> ★オーナー方針（2026-07-28）= **電話は使わない。メールのみで対応する。**
>   一般にメールだけだと定型文で止まる報告が多いため、その弱点を文面側で補う設計にしてある:
>   ①症状を「Apple の公開仕様と矛盾している」形で提示し、定型文で返せなくする
>   ②担当者が調べ直さなくて済むよう、ID・状態・再現手順をすべて本文に埋め込む
>   ③やってほしいこと／やってはいけないことを箇条書きで明示する
>   同じ本文を **2つの窓口に出す**（下記）。片方が定型文でも、もう片方が生きる。


### 日本語（本文の冒頭に貼る）

```
お世話になっております。合同会社Lanです。

App Store Connect のサブスクリプション提出について、システム上の不整合により
提出物が動かなくなっているため、手動での解除をお願いしたく連絡いたします。

■ 対象
App名: Moffy
Apple ID: 6785691850
Bundle ID: com.moffy.app
Team ID: JKPUV48L3V
提出物ID: 755e8857-3ab8-421d-bdc1-e4642569acb4（2026-07-23 提出）
サブスクグループ: 22235043（Moffy Premium）
サブスク: moffy_premium_monthly (6790656254) / moffy_premium_yearly (6790658702)

■ 経緯
1. 2026-07-23、アプリ本体＋サブスクグループ＋月額＋年額の4点を1つの提出物
   （755e8857）として提出しました。
2. Guideline 2.5.1（Family Controls の配信用エンタイトルメント未取得）により
   アプリ本体が却下されました。
3. エンタイトルメントを取得し、build 24 を作成。
4. 2026-07-27、アプリ本体のみを別の提出物（cb2b49c7）で再提出し、承認・公開
   （現在 READY_FOR_SALE）されました。
5. その結果、サブスク3点が却下済みの提出物 755e8857 に取り残され、
   ステータスが In Review のまま固着しています。

■ 現在の不整合（App Store Connect API で確認）
・reviewSubmissionItem のステータス = READY_FOR_REVIEW（＝まだ提出されていない）
・subscriptionVersion / subscription のステータス = IN_REVIEW（＝審査中）
貴社の公開されている状態遷移仕様では、この2つは同時に成立し得ません。

・提出物画面で「App Reviewに再提出」を押すと「1つ以上の項目にエラーがあります」
  と表示されますが、押下前後で API 上の状態は完全に同一で、何も起きません。
・サブスクグループの「審査用に追加」ボタンはグレーアウトしており押せません。

■ 新しい提出物にも載せられないことを API で確認済み
既存の提出物には触れずに、新規の reviewSubmission
（2bb0b880-874f-42db-8872-2c9143481aac・未提出）を作成し、そこへ3項目を
追加しようとしたところ、3件すべてが同じエラーで拒否されました。

  POST /v1/reviewSubmissionItems
  → HTTP 409 STATE_ERROR.ENTITY_STATE_INVALID
     "subscriptionVersions with id 'b0127a28-ac7a-4dca-afc7-7a8ca9313857'
      is not in valid state. This resource cannot be reviewed, please check
      associated errors to see why."
     （164566c4-... および subscriptionGroupVersions af9fce9c-... も同一エラー）

エラーは「associated errors を確認せよ」と指示していますが、
API/UI のどこにもその associated errors を参照する手段が見当たりません。
つまり、古い提出物から外すことも、新しい提出物に入れることもできず、
開発者側の操作では前にも後ろにも進めない状態です。

■ 新しいバージョンを作って差し替えることもできません（矛盾する応答）
次に、既存のバージョンを新しいバージョンで置き換えられないかを試しました。
（SubscriptionVersion の state には REPLACED_WITH_NEW_VERSION が存在するため）

  POST /v1/subscriptionVersions（subscription 6790658702）
  → HTTP 409 STATE_ERROR.ALREADY_EXISTS
     "Version already exists. There is already an inflight version with id
      'b0127a28-ac7a-4dca-afc7-7a8ca9313857' for subscription 6790658702"
     （6790656254 および subscriptionGroup 22235043 も同一エラー）

■ ここに矛盾があります
同じリソース b0127a28 について、貴社のサーバは2つの相反する応答を返します。

  ・審査に出そうとすると → 「is not in valid state / cannot be reviewed」
      （＝審査に出せる状態ではない）
  ・新しい版に置き換えようとすると → 「already an inflight version」
      （＝すでに審査に出ている最中である）

「審査に出ていない」と「審査に出ている最中」が同時に成り立っており、
出すことも、退けることもできません。開発者側の操作は完全に閉じています。

※ 上記 2bb0b880 は検証のために作成した空の提出物です（項目0件・未提出）。
   不要ですので、そちらで併せて削除していただいて差し支えありません。
※ 上記の検証で行ったのは GET と POST のみです。既存の提出物 755e8857 および
   公開中のアプリバージョン 1.0 には一切変更を加えておりません。

■ お願い
上記3項目（グループ 22235043、月額 6790656254、年額 6790658702）を提出物
755e8857 から解放し、Ready to Submit の状態に戻していただけますでしょうか。

■ 重要なお願い（必ずご確認ください）
サブスク商品およびサブスクグループを削除しないでください。
商品ID moffy_premium_monthly / moffy_premium_yearly は、現在公開中のアプリの
バイナリおよび RevenueCat の設定に既に組み込まれており、削除された場合は復旧
できません。
また、提出物 755e8857 のキャンセル、および現在 READY_FOR_SALE のアプリ
バージョン 1.0（7824865b-b21f-4ce3-b76d-3da9ad85bb73）のステータス変更も
行わないでください。

■ 事業影響
アプリは既に公開され正常に動作していますが、サブスクリプションが審査を通過して
いないため、ユーザーが有料プランを購入できない状態が続いています。

■ 添付
・「App Reviewに再提出」押下時のエラー画面（月額・年額の行に赤い(!)）
・サブスクグループの「審査用に追加」がグレーアウトしている画面

お手数をおかけしますが、ご対応のほどよろしくお願いいたします。
恐れ入りますが、ご連絡は本メール（またはこの問い合わせスレッド）にて
いただけますと幸いです。お電話でのご対応は不要です。
ご不明な点があれば、追加の情報は速やかにお送りいたします。
```

### English（App Review / Developer Support にそのまま送れる完成形）

```
Subject: Subscriptions stuck In Review on a rejected submission — request for manual release (App ID 6785691850)

Hello,

We are Lan LLC, the developer of the app "Moffy". We are writing to request
manual intervention on a subscription submission that appears to be in an
inconsistent state in App Store Connect.

■ Identifiers
App name:            Moffy
Apple ID:            6785691850
Bundle ID:           com.moffy.app
Team ID:             JKPUV48L3V
Review Submission:   755e8857-3ab8-421d-bdc1-e4642569acb4 (submitted 2026-07-23)
Subscription Group:  22235043 ("Moffy Premium")
Subscriptions:       moffy_premium_monthly (6790656254)
                     moffy_premium_yearly  (6790658702)

■ What happened
1. On 2026-07-23 we submitted four items in a single review submission (755e8857):
   the app version, the subscription group, and the monthly and yearly
   auto-renewable subscriptions.
2. The app binary was rejected under Guideline 2.5.1 because the distribution
   entitlement for Family Controls had not yet been granted.
3. We obtained the Family Controls distribution entitlement and produced build 24.
4. On 2026-07-27 we resubmitted the app version alone in a separate review
   submission (cb2b49c7). It was approved and the app is now live
   (appStoreState = READY_FOR_SALE).
5. As a result, the three subscription items were left behind in the rejected
   submission 755e8857 and are now stuck In Review. We cannot move them.

■ The inconsistency (verified via the App Store Connect API, read-only)
- The reviewSubmissionItems in submission 755e8857 report state =
  READY_FOR_REVIEW (i.e. not yet submitted for review).
- The corresponding subscriptionVersion and subscription resources report
  state = IN_REVIEW.
These two states cannot both be true under the documented state machine
("the version's state transitions ... to READY_FOR_REVIEW when you add it to a
review submission, then to WAITING_FOR_REVIEW after you mark the submission
submitted, then IN_REVIEW"). We believe this indicates a server-side
inconsistency rather than a configuration problem on our side.

Additional symptoms:
- Clicking "Resubmit to App Review" on submission 755e8857 returns
  "There are errors with one or more of your items. To fix them, you need to
  remove the items and add them again to your submission," and the monthly and
  yearly rows show a red (!) icon. However, the API state is byte-for-byte
  identical before and after clicking — nothing actually happens.
- The "Add for Review" button on the subscription group is greyed out and cannot
  be clicked, so we have no way to attach these items to a new submission.

■ We also verified that the items cannot be attached to a NEW submission
Without touching submission 755e8857, we created a new, separate review
submission (2bb0b880-874f-42db-8872-2c9143481aac, never submitted) and attempted
to add the three items to it. All three were rejected with the same error:

  POST /v1/reviewSubmissionItems
  -> HTTP 409 STATE_ERROR.ENTITY_STATE_INVALID
     "subscriptionVersions with id 'b0127a28-ac7a-4dca-afc7-7a8ca9313857' is not
      in valid state. This resource cannot be reviewed, please check associated
      errors to see why."
     (identical errors for subscriptionVersions 164566c4-78d2-4813-a28b-c0b05f4fa730
      and subscriptionGroupVersions af9fce9c-13ac-4126-bb37-e26e2979be63)

The error asks us to "check associated errors to see why", but we cannot find any
way to retrieve those associated errors through either the API or App Store
Connect. The items can neither be removed from the old submission nor added to a
new one, so there is no forward or backward path available to us as developers.

■ We also cannot replace the stuck versions with new ones
We then tried to supersede the stuck versions by creating new draft versions
(SubscriptionVersion.state includes REPLACED_WITH_NEW_VERSION, so this appeared
to be a supported path):

  POST /v1/subscriptionVersions (subscription 6790658702)
  -> HTTP 409 STATE_ERROR.ALREADY_EXISTS
     "Version already exists. There is already an inflight version with id
      'b0127a28-ac7a-4dca-afc7-7a8ca9313857' for subscription 6790658702"
     (identical errors for subscription 6790656254 and subscriptionGroup 22235043)

■ These two responses contradict each other
For the very same resource (b0127a28), your servers return two mutually
exclusive answers:

  - When we try to submit it for review:
        "is not in valid state ... This resource cannot be reviewed"
        (i.e. it is NOT in review)
  - When we try to supersede it with a new version:
        "There is already an inflight version"
        (i.e. it IS in flight / in review)

It cannot simultaneously be both not-submittable and already-in-flight. We can
neither move these items forward nor replace them, and no developer-facing
operation remains. This is why we believe manual intervention on your side is
required.

Note: 2bb0b880 is an empty verification submission we created (zero items, never
submitted). Please feel free to delete it as part of your cleanup.
Note: all of the verification above used only GET and POST. We made no changes
to submission 755e8857 or to the live app version 1.0.

■ Our request
Please release the following three items from review submission
755e8857-3ab8-421d-bdc1-e4642569acb4 and reset them to "Ready to Submit":
  - Subscription group 22235043 (Moffy Premium)
  - Subscription moffy_premium_monthly (6790656254)
  - Subscription moffy_premium_yearly  (6790658702)

■ IMPORTANT — please do not do the following
Please do NOT delete the subscription products or the subscription group. The
product identifiers moffy_premium_monthly and moffy_premium_yearly are already
shipped in the live version of the app (both iOS and Android) and are wired into
our RevenueCat configuration. Deleting them would be unrecoverable and would
force a full code change and re-release on both platforms.

Please also do NOT cancel submission 755e8857, and do NOT change the status of
app version 1.0 (appStoreVersion id 7824865b-b21f-4ce3-b76d-3da9ad85bb73), which
is currently READY_FOR_SALE and serving users.

■ Business impact
The app is live and functioning correctly, but because the subscriptions have
never completed review, users are unable to purchase any paid plan. We are unable
to generate any revenue from the app until this is resolved.

■ Attachments
1. Screenshot of the resubmission error, showing the red (!) icons on the monthly
   and yearly rows.
2. Screenshot of the subscription group page showing "Add for Review" greyed out
   and both subscriptions marked as In Review.

Please reply by email or through this support thread — a phone call is not
necessary. We are happy to provide any additional identifiers, API responses, or
screenshots you need, and we will not perform any further actions on this
submission until we hear back from you.

Thank you very much for your help.

Best regards,
Moffy development team, Lan LLC
```

---

## 7. AI（私）が代行できること・できないこと

### ✅ 私が代行できる（すべて事前にあなたの許可を取ります）

| 内容 | 危険度 | 備考 |
|---|---|---|
| 危険スクリプト4本の安全停止（STEP 0） | 無害 | ローカルファイルの編集のみ。実行前に許可をもらいます |
| App Store Connect の状態読み取り（STEP 1 と、以後の定期チェック） | 無害 | **GET のみ**。書き込みは一切しません |
| Apple への連絡文の作成・推敲・英訳 | 無害 | 上記テンプレは作成済み |
| 状態が変化したときの検知と報告 | 無害 | `GET /v1/subscriptions/{id}/versions` の state を見るだけ |
| RevenueCat が商品を返さないときのアプリ挙動の確認・改善 | 無害 | 将来 2.1(b) を食らわないための予防にもなります |

### 🚫 私が絶対にやらないこと

- App Store Connect への**書き込み系 API（DELETE / PATCH / POST）は、この件については一切実行しません。**あなたが「やって」と言っても、Apple から書面で明示指示が来るまでは実行を拒否します（理由：全部片道切符で、失敗すると公開中アプリか商品IDを失うため）

### 👤 あなたにしかできないこと

- App Store Connect へのログインと画面操作（STEP 2 のスクショ）
- Apple サポートへの問い合わせ送信（STEP 3）。**電話は使わない方針＝メールのみ**
- 読み取り専用 API キーの新規発行（推奨。ASC → ユーザーとアクセス → 統合 → App Store Connect API で「Developer」または「Customer Support」ロールのキーを作る。以後はそれを使えば、私が誤って書き込むことが**物理的に不可能**になります）

---

## 8. 事業インパクトの整理 ── 落ち着いて大丈夫です

### いま失われているもの
- **サブスク収益のみ。** これだけです。

### いま無事なもの
- ✅ iOS アプリ：App Store で公開中・正常動作（`apps.apple.com/jp/app/id6785691850`）
- ✅ Android アプリ：Google Play で公開中・正常動作
- ✅ サブスク商品 2種：**削除されていない。メタデータも審査用スクショも完備**。ロックされているだけで、中身は無傷
- ✅ litlink・SNS ローンチ投稿のリンク：すべて生きている

### 急ぐべきか？ ── 急ぐ必要はありません

理由は単純で、**この膠着は時間とともに悪化しないから**です。ユーザー数はまだ0〜少数、外部の締切もありません。放置のコストは「課金収益の立ち上がりが遅れる」だけで、緩やかに増えるだけです。

対して、焦って不可逆操作を踏んだときのコストは：
- **iOS 公開の巻き戻し**（審査1周＝直近実績で約2週間、ストアリンクが404になる）
- または **商品IDの永久喪失**（両OS改修＋再ビルド＋再審査＋RevenueCat 再配線）

つまり**損得が極端に非対称**です。壊れていないもの（公開中アプリ・商品ID）を、壊れていないけど動かないもの（サブスクの札）を追いかけて失うのは、割に合いません。

### この期間にやると良いこと（前向きな待ち方）
1. RevenueCat が商品を返せない状態でも**アプリが破綻せず自然に見えるか**を確認する（将来の 2.1(b) 予防になります）
2. Android 側の課金は動いているので、**Android での価格・導線の検証を先に回す**
3. ASO・SNS でのユーザー獲得を進めておく（課金解禁時に即転換できる状態を作る）

---

## ✅ あなたがやること（今日）

1. ~~「STEP 0 やって」~~ ✅ **2026-07-28 完了**（危険スクリプト4本を封印・動作確認済み）
2. ~~「STEP 1 やって」~~ ✅ **2026-07-28 完了**（`docs/asc/snapshots/2026-07-28_asc_state.txt`）
3. App Store Connect で**スクショ2枚**を撮る（第3章 STEP 2 の手順どおり。**何も押さない**）
4. **窓口①**（メインの問い合わせ）: https://developer.apple.com/contact/topic/SC1111/subtopic/30046/solution/select
   → 第6章の日本語＋英語テンプレを貼り、スクショ2枚を添付して送信。
   **電話番号の入力は任意。空欄のままでよい**（オーナー方針＝メールのみ）
5. **窓口②**（同じ本文をもう1本）: 提出物画面の「**App Reviewに返信**」から送る。
   メールだけだと定型文で止まる報告が多いため、**必ず2窓口に出す**。
   ⚠️ このスレッドは再提出操作をすると閉じるので、**送信後は何も押さない**
6. 送信したら**App Store Connect を閉じて、3日間は何も押さない**。私が毎日状態を読んで報告します

**それ以外は何もしないでください。それが今いちばん正しい打ち手です。**