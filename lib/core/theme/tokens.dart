/// デザイントークン（DESIGN_SYSTEM v1.0 の単一実装）。
///
/// 原則（DESIGN_SYSTEM §0 / §8）:
///   * 画面側で `Color(0xFF...)` や `EdgeInsets.all(17)` を直書きしない。必ず本ファイルを参照。
///   * 角丸は 12 / 24 / pill / circle のみ。余白は 8pt スケールの倍数のみ。
///   * 数字（時間・pt・達成率）は必ず Baloo 2（[AppType.numHero] 等）。
///   * 影色は黒でなく nest.bark 系。空色（sky）は背景主役にしない。
///   * 署名要素「巣リング」は [NestPanel] で実装（core/widgets）。
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// プリミティブ色（生の色値 / DESIGN_SYSTEM §2-1）。直接は使わず [AppColors] 経由が原則。
abstract final class _Prim {
  // nest / アースカラー
  static const cream = Color(0xFFFBF6EA);
  static const sand = Color(0xFFF0E4CC);
  static const bark = Color(0xFF7A5C3E);
  // warm（主役アクセント）
  static const orange = Color(0xFFFF8A3D);
  static const orangeDeep = Color(0xFFE96F22);
  static const apricot = Color(0xFFFFD7A8);
  // grow（成長・達成）
  static const green = Color(0xFF5CB87A);
  static const greenDeep = Color(0xFF3E9A5E);
  static const leaf = Color(0xFFDCEFD6);
  // sky（上端の空気感のみ）
  static const blue = Color(0xFF8FCDE8);
  static const blueDeep = Color(0xFF5BA9CC);
  // ink（焦げ茶寄りインク。真っ黒は使わない）
  static const ink900 = Color(0xFF3A322B);
  static const ink600 = Color(0xFF7C7269);
  static const ink400 = Color(0xFFA99F94);
  // state
  static const error = Color(0xFFE0604D);
  static const warn = Color(0xFFE8A93C);
  static const offline = Color(0xFF9AA7AD);
  static const white = Color(0xFFFFFFFF);
}

/// セマンティックカラー（DESIGN_SYSTEM §2-2）。画面はこちらを参照する。
abstract final class AppColors {
  static const bg = _Prim.cream;
  static const surface = _Prim.white; // カード
  static const surfaceNest = _Prim.sand; // 巣・主役被写体の土台
  static const sectionFill = _Prim.sand;

  static const primary = _Prim.orange;
  static const primaryDeep = _Prim.orangeDeep;
  static const primarySoft = _Prim.apricot;
  static const onPrimary = _Prim.cream; // orange上の文字はクリーム

  static const success = _Prim.green;
  static const successDeep = _Prim.greenDeep;
  static const successSoft = _Prim.leaf;
  static const progress = _Prim.green; // 削減/成長バー

  static const accentSky = _Prim.blue;
  static const accentSkyDeep = _Prim.blueDeep;

  static const textPrimary = _Prim.ink900;
  static const textSecondary = _Prim.ink600;
  static const textDisabled = _Prim.ink400;

  static const nestBark = _Prim.bark; // 巣の縁・地面影色
  static const divider = Color(0x1F7A5C3E); // nest.bark 12%透過

  static const error = _Prim.error;
  static const warn = _Prim.warn;
  static const offline = _Prim.offline;
}

/// レアリティ色（DESIGN_SYSTEM §2-3。卵・Mofi・図鑑で厳密統一）。
enum RarityToken {
  common(Color(0xFF9BB3A6), Color(0xFFC7D6CC)),
  rare(Color(0xFF5BA9CC), Color(0xFFA9DBEF)),
  // 紫はSRレアリティ表現にだけ許可（背景に使わない＝量産顔回避）
  sr(Color(0xFFA77BD8), Color(0xFFD9C2F0)),
  ssr(Color(0xFFF2B632), Color(0xFFFFE89C));

  final Color main;
  final Color glow;
  const RarityToken(this.main, this.glow);
}

/// スペーシング（8pt基準 / DESIGN_SYSTEM §4）。マジックナンバー禁止。
abstract final class AppSpace {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16; // 標準（画面左右マージン・カード内パディング）
  static const double xl = 24; // セクション間
  static const double xxl = 32;
  static const double xxxl = 48;

  static const double bottomNavHeight = 64;
  static const double tabIcon = 26;
}

/// 角丸（2段階に絞る / DESIGN_SYSTEM §5）。
abstract final class AppRadius {
  static const double sm = 12; // バッジ・小ボタン・入力欄
  static const double lg = 24; // カード・モーダル・主役パネル
  static const double pill = 999; // ピルCTA・通貨バッジ

  static const BorderRadius smR = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius lgR = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius pillR = BorderRadius.all(Radius.circular(pill));
}

/// 影（ごく浅い1〜2段。影色は nest.bark 系 / DESIGN_SYSTEM §5）。
abstract final class AppElevation {
  static const List<BoxShadow> card = [
    BoxShadow(color: Color(0x1A7A5C3E), offset: Offset(0, 2), blurRadius: 8),
  ];
  static const List<BoxShadow> float = [
    BoxShadow(color: Color(0x297A5C3E), offset: Offset(0, 6), blurRadius: 16),
  ];

  /// 巣リングの地面影（署名要素 / nest.bark 18%）。被写体を地面に「置く」。
  static const Color ground = Color(0x2E7A5C3E);
}

/// タイポグラフィ（DESIGN_SYSTEM §3）。
/// 数字は必ず [numHero] / [numLabel]（Baloo 2）を使う。
abstract final class AppType {
  // 見出し/UI = Zen Maru Gothic、本文 = Noto Sans JP、数字 = Baloo 2。
  static TextStyle get display => GoogleFonts.zenMaruGothic(
        fontSize: 28,
        height: 1.3,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.02 * 28,
        color: AppColors.textPrimary,
      );

  static TextStyle get title => GoogleFonts.zenMaruGothic(
        fontSize: 20,
        height: 1.4,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.02 * 20,
        color: AppColors.textPrimary,
      );

  static TextStyle get body => GoogleFonts.notoSansJp(
        fontSize: 15,
        height: 1.7,
        fontWeight: FontWeight.w400,
        color: AppColors.textPrimary,
      );

  static TextStyle get bodyStrong => GoogleFonts.notoSansJp(
        fontSize: 15,
        height: 1.7,
        fontWeight: FontWeight.w700,
        color: AppColors.textPrimary,
      );

  static TextStyle get caption => GoogleFonts.notoSansJp(
        fontSize: 12,
        height: 1.5,
        fontWeight: FontWeight.w400,
        color: AppColors.textSecondary,
      );

  /// 主役の数字（削減時間・孵化までpt）。Baloo 2。
  static TextStyle get numHero => GoogleFonts.baloo2(
        fontSize: 40,
        height: 1.1,
        fontWeight: FontWeight.w800,
        color: AppColors.textPrimary,
      );

  /// バッジ内のpt/ジェム数。Baloo 2。
  static TextStyle get numLabel => GoogleFonts.baloo2(
        fontSize: 16,
        height: 1.2,
        fontWeight: FontWeight.w700,
        color: AppColors.textPrimary,
      );
}
