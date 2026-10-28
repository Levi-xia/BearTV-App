import 'package:flutter/widgets.dart';

import '../core/theme.dart';

/// Shared "focused pill" visuals used by tabs, tools, chips, buttons and
/// episodes — the common `.on` rule from the reference CSS:
/// cyan/blue gradient fill, dark ink text, glow shadow + inner white ring,
/// scaled to 1.06.
class FocusFx {
  static BoxDecoration pill(bool focused, {required double radius, BoxDecoration? base}) {
    if (!focused) return base ?? const BoxDecoration();
    return BoxDecoration(
      gradient: AppColors.focusGradient,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: const Color(0x8CFFFFFF), width: 2),
      boxShadow: const [
        BoxShadow(color: Color(0x73009EFF), blurRadius: 34, offset: Offset(0, 10)),
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
