import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
    this.onMenu,
    this.focusNode,
    this.autofocus = false,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;

  /// Optional remote-MENU action (e.g. delete the item this chip represents).
  final VoidCallback? onMenu;
  final FocusNode? focusNode;
  final bool autofocus;

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if ((event is KeyDownEvent || event is KeyRepeatEvent) &&
        event.logicalKey == LogicalKeyboardKey.contextMenu &&
        onMenu != null) {
      onMenu!();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focusable(
      onPressed: onPressed,
      autofocus: autofocus,
      ensureVisibleAlignment: 0.5,
      focusNode: focusNode,
      onKeyEvent: onMenu == null ? null : _handleKey,
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
    this.focusNode,
  });

  final String label;
  final VoidCallback onPressed;
  final bool primary;
  final bool autofocus;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    return Focusable(
      onPressed: onPressed,
      autofocus: autofocus,
      focusNode: focusNode,
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

/// Episode cell in the 选集 grid (`.ep`), with a `current` playing state and
/// optional download [selected] / [badge] (e.g. 「✓ 已缓存」「下载中」).
///
/// The current episode gets a cyan wash, a soft glow and a small play glyph in
/// place of the old text-marker, so "where am I" reads at a glance from the
/// sofa without lengthening the label. All states keep the same footprint
/// (min height + fixed-width parent): focus only animates scale and colours, so
/// the grid never reflows under the D-pad.
///
/// [disabled] greys the cell out (already cached / already in the queue) while
/// keeping its [badge] readable — the download sheet uses it so a cached
/// episode can't be added twice.
class EpisodeCell extends StatelessWidget {
  const EpisodeCell({
    super.key,
    required this.label,
    required this.current,
    required this.onPressed,
    this.selected = false,
    this.badge,
    this.disabled = false,
    this.focusNode,
    this.autofocus = false,
  });

  final String label;
  final bool current;
  final VoidCallback onPressed;
  final bool selected;

  /// Small trailing status label (e.g. 「✓ 已缓存」「下载中」).
  final String? badge;

  /// Dimmed style; the press handler is still wired so focus never lands on a
  /// non-interactive target, but the caller's handler typically does nothing.
  final bool disabled;

  final FocusNode? focusNode;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return Focusable(
      onPressed: onPressed,
      autofocus: autofocus,
      focusNode: focusNode,
      ensureVisibleAlignment: 0.5,
      builder: (context, focused) {
        final active = !disabled && (selected || current);
        final badgeText = (badge ?? '').trim();
        final Color labelColor;
        if (focused) {
          labelColor = AppColors.focusInk;
        } else if (disabled) {
          labelColor = const Color(0x80CDDBEF);
        } else if (active) {
          labelColor = const Color(0xFFEAF8FF);
        } else {
          labelColor = const Color(0xFFCDDBEF);
        }
        final Color accentColor =
            focused ? AppColors.focusInk : AppColors.accent2;

        final base = BoxDecoration(
          // Washed fill + hairline, so the cells read as a deliberate surface
          // rather than floating text on the page gradient.
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: active
                ? const [Color(0x2E00E5FF), Color(0x1200E5FF)]
                : const [Color(0x17FFFFFF), Color(0x0AFFFFFF)],
          ),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: active ? const Color(0x8C00E5FF) : AppColors.hairline,
            width: active ? 1.5 : 1,
          ),
          boxShadow: active
              ? const [
                  BoxShadow(
                      color: Color(0x2E00E5FF),
                      blurRadius: 20,
                      spreadRadius: -8),
                ]
              : null,
        );
        return Opacity(
          opacity: disabled ? 0.55 : 1,
          child: FocusFx.scale(
            focused,
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: kEase,
              constraints: const BoxConstraints(minHeight: 54),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              alignment: Alignment.center,
              decoration: focused ? FocusFx.pill(focused, radius: 14) : base,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (current && !disabled) ...[
                    _CellBadge(
                      icon: Icons.play_arrow_rounded,
                      color: accentColor,
                    ),
                    const SizedBox(width: 6),
                  ] else if (selected && !disabled) ...[
                    _CellBadge(icon: Icons.check_rounded, color: accentColor),
                    const SizedBox(width: 6),
                  ],
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 17,
                        color: labelColor,
                        fontWeight: focused ? FontWeight.w700 : FontWeight.w500,
                        fontFamilyFallback: kFontFallback,
                      ),
                    ),
                  ),
                  if (badgeText.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Text(
                      badgeText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: focused
                            ? const Color(0xB304121F)
                            : (active ? AppColors.accent2 : AppColors.textDim),
                        fontWeight: FontWeight.w600,
                        fontFamilyFallback: kFontFallback,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Tiny circular glyph that marks the current / selected episode.
class _CellBadge extends StatelessWidget {
  const _CellBadge({required this.icon, required this.color});
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 18,
      height: 18,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: 13, color: color),
    );
  }
}
