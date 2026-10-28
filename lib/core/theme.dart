import 'package:flutter/widgets.dart';

/// Design tokens mirrored 1:1 from the reference `tv-opus5.html` (`:root` vars).
class AppColors {
  static const accent = Color(0xFF4EA8FF); // --accent
  static const accent2 = Color(0xFF00E5FF); // --accent-2
  static const text = Color(0xFFF2F6FF); // --text
  static const textDim = Color(0xFFA8B3C7); // --text-dim
  static const bg = Color(0xFF04060D); // page background
  static const cardBg = Color(0xFF0B1020);

  static const glass = Color(0x12FFFFFF); // rgba(255,255,255,.07)
  static const glassBorder = Color(0x24FFFFFF); // rgba(255,255,255,.14)
  static const hairline = Color(0x14FFFFFF); // rgba(255,255,255,.08)

  static const gold = Color(0xFFFFCE4D); // score
  static const live = Color(0xFF48E08A);

  static const focusInk = Color(0xFF04121F); // text color on focused pill

  // Focused pill / chip / button gradient
  static const focusGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xF24EA8FF), Color(0xE600E5FF)],
  );

  // Logo bar gradient
  static const logoGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [accent2, accent],
  );

  // progress bar fill
  static const barGradient = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [accent2, accent],
  );

  static const newTagGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFFF5F6D), Color(0xFFFF9A44)],
  );
}

class AppDims {
  static const double pad = 56; // --pad
  static const double headerHeight = 96;
  static const double cardW = 366;
  static const double cardH = 206;
  static const double sideW = 430;
}

/// Global UI zoom-out factor. The whole app lays out at `size / kUiScale`
/// (a larger logical canvas) and is then scaled down to the physical screen, so
/// text, posters and spacing all shrink uniformly and more content fits on a TV
/// — without touching any per-widget dimension. 1.0 = no scaling. See `_UiScale`
/// in app.dart. Tune here.
const double kUiScale = 0.82;

/// --ease: cubic-bezier(.22,1,.36,1)
const Curve kEase = Cubic(0.22, 1.0, 0.36, 1.0);
const Duration kFocusDur = Duration(milliseconds: 340);
const Duration kPageDur = Duration(milliseconds: 450);
const Duration kBgDur = Duration(milliseconds: 900);

/// System font stack similar to the HTML (PingFang SC / HarmonyOS / YaHei).
const List<String> kFontFallback = [
  'PingFang SC',
  'HarmonyOS Sans SC',
  'Microsoft YaHei',
  'Noto Sans CJK SC',
];
