import 'package:flutter/widgets.dart';

import '../core/theme.dart';

/// Slack the focus "pop" needs inside a scroll viewport, in logical px.
///
/// [FocusFx.scale] grows a widget 6% (≈3% per side), and [FocusFx.pill] paints a
/// glow outside the box too. Scroll views clip their child at the viewport edge,
/// so a CTA or episode cell laid out flush against that edge (the first row of
/// a sheet, the last row of a scrolled grid, a chip at the end of a row) gets
/// its focused corners sliced off. Inset the scroll content by this much and
/// trim the enclosing panel padding by the same amount: the outer layout is
/// unchanged, the clip rect merely moves outward.
const double kFocusSlack = 14;

/// Shared "focused pill" visuals used by tabs, tools, chips, buttons and
/// episodes — the common `.on` rule from the reference CSS:
/// cyan/blue gradient fill, dark ink text, glow shadow + inner white ring,
/// scaled to 1.06.
class FocusFx {
  static BoxDecoration pill(bool focused,
      {required double radius, BoxDecoration? base}) {
    if (!focused) return base ?? const BoxDecoration();
    return BoxDecoration(
      gradient: AppColors.focusGradient,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: const Color(0x8CFFFFFF), width: 2),
      boxShadow: const [
        BoxShadow(
            color: Color(0x73009EFF), blurRadius: 34, offset: Offset(0, 10)),
      ],
    );
  }

  /// Wraps [child] with the focus scale animation (1.0 -> 1.06).
  static Widget scale(bool focused, Widget child, {double to = 1.06}) {
    return AnimatedScale(
      scale: focused ? to : 1.0,
      duration: kFocusDur,
      curve: kEase,
      child: child,
    );
  }
}
