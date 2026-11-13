import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../core/app_scope.dart';
import '../core/theme.dart';
import '../data/models.dart';
import 'focusable.dart';
import 'net_image.dart';

/// `.mcard`: portrait poster + gradient + title/rating overlay. Sized by its
/// parent grid cell (uniform height for clean DPAD navigation).
class MasonryCard extends StatelessWidget {
  const MasonryCard(
      {super.key, required this.item, this.onFocused, this.focusNode});
  final VodItem item;

  /// Fired when this cell gains focus — used to trigger infinite-scroll paging
  /// as focus approaches the last rows.
  final VoidCallback? onFocused;

  /// Optional external focus node so the home grid can restore focus to a
  /// specific card (the just-watched title) when returning from the player.
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.read(context);
    return Focusable(
      focusNode: focusNode,
      ensureVisibleAlignment: 0.5,
      onFocused: onFocused,
      onPressed: () => app.openTitle(item),
      // Grid movement uses reading-order next/prev so Right at the row end
      // wraps to the next row's first card (and Left to the previous row's
      // last) instead of stalling or drifting up into the tab strip. Up/Down
      // stay geometric (row above / below, then chips / footer at the edges).
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
          return KeyEventResult.ignored;
        }
        final k = event.logicalKey;
        if (k == LogicalKeyboardKey.arrowRight) {
          FocusManager.instance.primaryFocus?.nextFocus();
          return KeyEventResult.handled;
        }
        if (k == LogicalKeyboardKey.arrowLeft) {
          FocusManager.instance.primaryFocus?.previousFocus();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      builder: (context, focused) {
        return AnimatedContainer(
          duration: kFocusDur,
          curve: kEase,
          transformAlignment: Alignment.center,
          transform: focused
              ? (Matrix4.identity()..scaleByDouble(1.05, 1.05, 1.05, 1.0))
              : Matrix4.identity(),
          decoration: BoxDecoration(
            color: AppColors.cardBg,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color:
                  focused ? const Color(0xE6FFFFFF) : const Color(0x12FFFFFF),
              width: focused ? 3 : 1,
            ),
            boxShadow: focused
                ? const [
                    BoxShadow(
                        color: Color(0x804EA8FF),
                        blurRadius: 40,
                        offset: Offset(0, 16))
                  ]
                : null,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(focused ? 15 : 17),
            child: Stack(
              fit: StackFit.expand,
              children: [
                NetImage(item.masonryUrl),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [
                        Color(0xEB03060E),
                        Color(0x1A03060E),
                        Color(0x0003060E)
                      ],
                      stops: [0.0, 0.55, 1.0],
                    ),
                  ),
                ),
                Positioned(
                  left: 14,
                  right: 14,
                  bottom: 12,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          color: AppColors.text,
                          fontFamilyFallback: kFontFallback,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '★ ${item.score} · ${item.genre}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          color: Color(0xFF9DB0CB),
                          fontFamilyFallback: kFontFallback,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
