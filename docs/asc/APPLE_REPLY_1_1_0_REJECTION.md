# App Review への返信（1.1.0 / Guideline 5.1.1(iv) リジェクト）

> 提出物 `cbafabe3-ea6c-4dae-aa75-0991852d3593` / Review date 2026-08-10 / 1.1.0 (26)
> 送信場所: **ASC → Moffy → 1.1.0 → 解決センター → 「App Review に返信」**

## 🎯 この返信の狙い

Apple のメッセージ冒頭に **Bug Fix Submissions** の案内がある:

> The issues we've identified below are eligible to be resolved on your next update.
> If this submission includes bug fixes and you'd like to have it approved at this time,
> reply to this message and let us know. **You do not need to resubmit your app for us to proceed.**

v1.1 は **100% バグ修正リリース**（whatsNew の全項目が不具合修正）なので、この提案に乗れる。
＝ **再ビルド・再提出なしで 1.1.0 を承認してもらう。** 5.1.1(iv) の修正は 1.1.1 で出す。

## ⚠️ 送信前の注意

- **「提出をキャンセル」を押さないこと。** 押すとこの提出物が消え、Bug Fix Submissions の
  経路そのものを失う。押すのは「App Review に返信」だけ。
- 7/23 の古い提出物 `755e8857` には**一切触らない**（公開中 iOS を失う経路 / 既知）。

---

## 送信する本文（英語・そのままコピー）

```
Hello,

Thank you for the review and for the clear explanation of the issue.

Yes, this submission (1.1.0, build 26) is a bug fix update, and we would be very
grateful if you could approve it at this time under the Bug Fix Submissions policy.

Every item in this version's release notes is a fix for a defect in the currently
live version 1.0.2:

- Daily reduction points were not always applied to the egg's growth, so users saw
  their points increase while the egg did not grow.
- The profile screen displayed placeholder statistics instead of the user's real
  records (total reduced time, collection progress, streak).
- On iPhone, users who skipped app selection during onboarding had no way to select
  target apps afterwards, so their usage was never measured at all. This version adds
  a "Target Apps" entry to the menu so they can recover.
- The screen shown after account deletion could return to a broken state.
- The menu could fail to render when statistics could not be loaded, which also hid
  the account deletion and legal links.

Regarding Guideline 5.1.1(iv), we understand the issue and we will resolve it in our
next update (1.1.1). Specifically, on the explanation screen that appears before the
Screen Time permission request we will:

1. Change the button label from "許可する" ("Allow") to "次へ" ("Next"), so that our
   own UI does not ask for permission on behalf of the system dialog.
2. Remove the "あとで設定する" ("Set up later") option from that screen, so that the
   user always proceeds to the system permission request after reading the explanation.

Thank you very much for your help.
```

---

## 日本語訳（送信用ではなく、内容確認のため）

こんにちは。

審査と、問題点の明確なご説明をありがとうございます。

はい、この提出（1.1.0 / build 26）はバグ修正アップデートです。Bug Fix Submissions の
方針に基づき、この提出を今回承認していただけますと大変助かります。

本バージョンのリリースノートの全項目が、公開中の 1.0.2 の不具合修正です:

- 毎日の削減ポイントが卵の成長に反映されない日があり、ポイントは増えるのに卵が育たなかった
- プロフィール画面が実際の記録ではなくプレースホルダの数値を表示していた
- iPhone でオンボーディング時にアプリ選択をスキップすると、後から選ぶ手段が無く、
  利用時間が一切計測されなかった。本バージョンでメニューに「対象アプリ」を追加した
- アカウント削除後の画面が壊れた状態に戻ることがあった
- 統計が読み込めないときメニュー全体が表示できず、アカウント削除と法務リンクも隠れていた

Guideline 5.1.1(iv) については内容を理解しており、次のアップデート（1.1.1）で解消します。
具体的には、スクリーンタイムの権限要求の前に出る説明画面について:

1. ボタンのラベルを「許可する」から「次へ」に変更し、システムのダイアログに代わって
   当社の UI が許可を求めることのないようにします
2. 同画面から「あとで設定する」を削除し、説明を読んだユーザーが必ずシステムの権限要求へ
   進むようにします

よろしくお願いいたします。

---

## 送信後にやること

1. **承認通知が来たら ASC で「このバージョンをリリース」を押す**（releaseType=MANUAL＝
   承認されただけでは公開されない）
2. 1.1.1（5.1.1(iv) 修正）を出す。修正はすでに `v1.1-fixes` に実装済み
3. もし Apple が Bug Fix Submissions を断ってきた場合は、1.1.1 の修正を build 27 として
   ビルドし、1.1.0 に差し替えて再提出する（＝結果は同じ、順番が変わるだけ）
