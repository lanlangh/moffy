import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/observability/log.dart';
import '../domain/egg_models.dart';

/// 孵化結果のシェア（S13「グロースの種」/ ARCHITECTURE §1-2 data・副作用の隔離）。
///
/// 色違いの「キラリ」した瞬間をSNSへ共有させ、オーガニックな口コミ拡散の起点にする。
/// プラグイン依存（`share_plus` / `path_provider`）を本サービスへ閉じ込め、
/// プレゼンテーション層（[HatchOverlay] / EggsScreen）は「キャプチャ画像 + 文面」を
/// 渡すだけにする。テストでは [hatchShareServiceProvider] を override して差し替える。
class HatchShareService {
  const HatchShareService();

  /// 孵化結果を共有する。[imageBytes] があれば画像付き、無ければテキストのみ。
  ///
  /// 共有はベストエフォート: 失敗（キャンセル/権限/IO）でも例外を投げずログのみ。
  /// 抽選・図鑑はサーバー確定済みで、共有失敗がコアループを壊さないため（信頼境界）。
  Future<void> shareHatch({
    required String text,
    String? subject,
    Uint8List? imageBytes,
  }) async {
    try {
      if (imageBytes != null && imageBytes.isNotEmpty) {
        // 一時ディレクトリにPNGを書き出して画像付きシェア。
        final dir = await getTemporaryDirectory();
        final file = File(
          '${dir.path}/moffy_hatch_${DateTime.now().millisecondsSinceEpoch}.png',
        );
        await file.writeAsBytes(imageBytes, flush: true);
        await Share.shareXFiles(
          [XFile(file.path, mimeType: 'image/png')],
          text: text,
          subject: subject,
        );
      } else {
        // 画像生成に失敗した場合のフォールバック（テキストのみでも拡散は成立）。
        await Share.share(text, subject: subject);
      }
    } catch (e, st) {
      Log.e('shareHatch failed', error: e, stack: st);
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
