import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// モバイル/デスクトップ実装（dart:io あり）: 一時ファイルに書き出して XFile を返す。
/// Web では [share_file_web.dart] が使われる（条件付き import / hatch_share_service）。
Future<XFile> buildShareImageFile(
  List<int> bytes, {
  required int stamp,
}) async {
  final dir = await getTemporaryDirectory();
  final file = File('${dir.path}/moffy_hatch_$stamp.png');
  await file.writeAsBytes(bytes, flush: true);
  return XFile(file.path, mimeType: 'image/png');
}
