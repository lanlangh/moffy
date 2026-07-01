import 'dart:typed_data';

import 'package:share_plus/share_plus.dart';

/// Web 実装（dart:io なし）: 一時ファイルは使えないので、メモリ上の XFile を返す。
Future<XFile> buildShareImageFile(
  List<int> bytes, {
  required int stamp,
}) async {
  return XFile.fromData(
    Uint8List.fromList(bytes),
    mimeType: 'image/png',
    name: 'moffy_hatch_$stamp.png',
  );
}
