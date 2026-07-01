import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/observability/log.dart';
import '../domain/egg_models.dart';
// dart:io（一時ファイル）を使う実装は条件付き import で分離。Web ではメモリ XFile を使う。
import 'share_file_io.dart' if (dart.library.html) 'share_file_web.dart';

/// 孵化結果のシェア（S13「グロースの種」/ ARCHITECTURE §1-2 data・副作用の隔離）。
///
/// 色違いの「キラリ」した瞬間をSNSへ共有させ、オーガニックな口コミ拡散の起点にする。
/// プラグイン依存（`share_plus` / `path_provider`）を本サービスへ閉じ込め、
/// プレゼンテーション層（[HatchOverlay] / EggsScreen）は「キャプチャ画像 + 文面」を
/// 渡すだけにする。テストでは [hatchShareServiceProvider] を override して差し替える。
class HatchShareService {
  const HatchShareService();

  /// このプラットフォームでネイティブ共有シートが使えるか。
  ///
  /// share_plus はモバイル（iOS/Android）/ デスクトップ / Web を対象とする。
  /// それ以外（テスト/未対応プラットフォーム）では共有を試みず、呼び出し側の
  /// フォールバック（クリップボードコピー等）に委ねる（プラットフォーム未対応時の分岐）。
  /// share_plus は Web/モバイル/デスクトップ全対応。失敗は shareHatch の try/catch で
  /// 吸収し呼び出し側のフォールバック（コピー）へ委ねるため、常に試行してよい。
  bool get isSupported => true;

  /// 孵化結果を共有する。[imageBytes] があれば画像付き、無ければテキストのみ。
  ///
  /// 戻り値: 共有シートを起動できたら true、起動できなかったら false
  /// （= 呼び出し側がフォールバック〈コピー/トースト〉を出す）。
  /// 失敗（キャンセル/権限/IO/未対応）でも例外は投げない: 抽選・図鑑はサーバー確定済みで、
  /// 共有失敗がコアループを壊さないため（信頼境界 / ベストエフォート）。
  Future<bool> shareHatch({
    required String text,
    String? subject,
    Uint8List? imageBytes,
  }) async {
    // プラットフォーム未対応: 共有を試みず false（呼び出し側がコピーへフォールバック）。
    if (!isSupported) return false;

    try {
      if (imageBytes != null && imageBytes.isNotEmpty) {
        // 画像付きシェア。一時ファイル(io)/メモリXFile(web)は条件付き import で切替。
        final xfile = await buildShareImageFile(
          imageBytes,
          stamp: DateTime.now().millisecondsSinceEpoch,
        );
        await Share.shareXFiles([xfile], text: text, subject: subject);
      } else {
        // 画像生成に失敗した場合のフォールバック（テキストのみでも拡散は成立）。
        await Share.share(text, subject: subject);
      }
      return true;
    } catch (e, st) {
      Log.e('shareHatch failed', error: e, stack: st);
      return false; // 失敗時は呼び出し側のフォールバックへ。
    }
  }
}

/// シェア文面を組み立てる（純粋関数 / 単体テスト対象）。
///
/// 色違いは専用の訴求文にして拡散意欲を高める（S13）。絵文字は最小限に留める。
String buildHatchShareText(HatchResult result) {
  final name = result.species.name;
  final rarity = result.species.rarity.label;
  final headline = result.isShiny
      ? '✨色違いの「$name」($rarity)が孵化！'
      : '「$name」($rarity)が孵化！';
  return '$headline\n削ったスマホ時間でかわいいMofiが育つ #Moffy';
}

/// シェアのメール件名等に使う subject。
String buildHatchShareSubject(HatchResult result) =>
    result.isShiny ? 'Moffyで色違いをゲット！' : 'MoffyでMofiをゲット！';

/// DI（ARCHITECTURE §1-3）。テストで override 可能。
final hatchShareServiceProvider =
    Provider<HatchShareService>((ref) => const HatchShareService());
