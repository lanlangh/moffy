/// 機能フラグ（v1.0 のスコープ境界を1箇所に集約 / SSOT）。
///
/// 未実装機能を UI に露出させて「準備中」で行き止まりにすると、ストア審査
/// （2.1 App Completeness）でリジェクトされる。MVP に含めない機能はここで
/// false 固定し、各エントリポイントをこのフラグでガードする。実装完了時に
/// ここを true にするだけで再有効化できる（再有効化の単一スイッチ）。
library;

/// アカウント連携（匿名→Apple/Google/メール引き継ぎ / S10）。
///
/// v1.0 では未実装（ネイティブサインインSDKの配線が必要・Apple分はMac必須）。
/// 既定 false の間は連携導線を表示せず、匿名運用（端末内データ・機種変で復元不可）を
/// 明示する。実装完了後に既定を true にすれば導線が復活する。
///
/// 実装は `bool.fromEnvironment`（既定 false）。これにより解析器が「定数 false」と
/// みなして `if` 分岐を dead_code 警告にすることを避けつつ、検証時に
/// `--dart-define=ENABLE_ACCOUNT_LINKING=true` で一時的に有効化もできる。
/// 関連: [account_repository] の `linkProvider`、`AccountLinkScreen`。
const bool kAccountLinkingEnabled =
    bool.fromEnvironment('ENABLE_ACCOUNT_LINKING');

/// 通知（プッシュ/ローカル）の設定導線（S9）。
///
/// v1.1 では未実装。設定画面（[NotificationSettingsScreen]）は 5種類のトグルを
/// 描画して shared_preferences に保存するが、**通知を送る側のコードが1行も無い**
/// （`pubspec.yaml` に通知パッケージ0件・iOS/Android のネイティブ側も0件）。
/// ＝ トグルを操作しても何も起きない空箱で、2.1 App Completeness の対象になりうる。
///
/// false の間はメニューから設定項目を出さず、[kAccountLinkingEnabled] と同じく
/// 「今後のアップデートで対応予定」と正直に案内する（行き止まりを作らない）。
/// 実装完了時にここを true にすれば導線が復活する（再有効化の単一スイッチ）。
///
/// ⚠️ ルート自体（`/settings/notifications`）は残してある。true にするだけで
/// 到達可能に戻るが、**その際は許諾要求と送信の実装が前提**（許諾だけ求めて
/// 何も送らない状態は、隠すより悪い）。
const bool kNotificationsEnabled = bool.fromEnvironment('ENABLE_NOTIFICATIONS');
