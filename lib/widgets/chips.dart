import 'package:flutter/widgets.dart';

import '../core/theme.dart';
import 'focus_fx.dart';
import 'focusable.dart';

/// Rounded selectable chip (清晰度 / 播放资源 / 片库分段). Three states:
/// idle glass, selected (accent tint), focused (gradient pill).
class SelectableChip extends StatelessWidget {
  const SelectableChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onPressed,
    this.focusNode,
    this.autofocus = false,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;
  final FocusNode? focusNode;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return Focusable(
      onPressed: onPressed,
      autofocus: autofocus,
      ensureVisibleAlignment: 0.5,
      focusNode: focusNode,
      builder: (context, focused) {
        // Keep the layout footprint identical across states so a focused chip
        // never grows and reflows a Wrap row (pushing the last chip to the next
        // line). The focus "pop" is a paint-only AnimatedScale; the border is a
        // constant 2px, and the label weight stays w600 in every state. Only
        // colors/gradient/scale change on focus.
        final base = BoxDecoration(
          color: selected ? const Color(0x294EA8FF) : AppColors.glass,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected ? const Color(0x994EA8FF) : AppColors.hairline,
            width: 2,
          ),
        );
        return FocusFx.scale(
          focused,
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
            decoration: focused ? FocusFx.pill(focused, radius: 999) : base,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 16,
                color: focused
                    ? AppColors.focusInk
                    : (selected ? AppColors.text : AppColors.textDim),
                fontWeight: FontWeight.w600,
                fontFamilyFallback: kFontFallback,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Quick-action button (`.btn`), optionally `primary`.
class ActionButton extends StatelessWidget {
  const ActionButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.primary = false,
    this.autofocus = false,
  });

  final String label;
  final VoidCallback onPressed;
  final bool primary;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return Focusable(
      onPressed: onPressed,
      autofocus: autofocus,
      builder: (context, focused) {
        final base = BoxDecoration(
          gradient: primary
              ? const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0x4D4EA8FF), Color(0x2E00E5FF)],
                )
              : null,
          color: primary ? null : const Color(0x17FFFFFF),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: primary ? const Color(0x6600E5FF) : const Color(0x24FFFFFF),
          ),
        );
        return FocusFx.scale(
          focused,
          Container(
            padding: const EdgeInsets.symmetric(vertical: 15),
            alignment: Alignment.center,
            decoration: focused ? FocusFx.pill(focused, radius: 14) : base,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: focused ? AppColors.focusInk : AppColors.text,
                fontFamilyFallback: kFontFallback,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Episode cell in the 选集 grid (`.ep`), with a `current` playing state.
class EpisodeCell extends StatelessWidget {
  const EpisodeCell({
    super.key,
    required this.number,
    required this.current,
    required this.onPressed,
  });

  final int number;
  final bool current;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Focusable(
      onPressed: onPressed,
      ensureVisibleAlignment: 0.5,
      builder: (context, focused) {
        final base = BoxDecoration(
          color: current ? const Color(0x1F00E5FF) : AppColors.glass,
          borderRadius: BorderRadius.circular(13),
          border: Border.all(
            color: current ? const Color(0x8C00E5FF) : AppColors.hairline,
          ),
        );
        return FocusFx.scale(
          focused,
          Container(
            padding: const EdgeInsets.symmetric(vertical: 16),
            alignment: Alignment.center,
            decoration: focused ? FocusFx.pill(focused, radius: 13) : base,
            child: Text(
              current ? '第 $number 集 ▶' : '第 $number 集',
              style: TextStyle(
                fontSize: 17,
                color: focused
                    ? AppColors.focusInk
                    : (current ? AppColors.text : const Color(0xFFCDDBEF)),
                fontWeight: focused ? FontWeight.w700 : FontWeight.w400,
                fontFamilyFallback: kFontFallback,
              ),
            ),
          ),
        );
      },
    );
  }
}
