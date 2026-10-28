import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../core/app_scope.dart';
import '../core/theme.dart';
import '../data/models.dart';
import 'focusable.dart';
import 'net_image.dart';

/// Landscape rail card (`.card`): poster, gradient scrim, HD / NEW tags and a
/// meta strip that fully reveals on focus. Focus lifts + scales + rings it.
class MediaCard extends StatelessWidget {
  const MediaCard({
    super.key,
    required this.item,
    this.onFocused,
    this.onKeyEvent,
    this.onMenu,
    this.autofocus = false,
    this.focusNode,
    this.progress,
    this.badge,
    this.timeLabel,
  });

  final VodItem item;
  final VoidCallback? onFocused;

  /// Optional raw key hook (see [Focusable.onKeyEvent]) — used by the top rail
  /// to send Up back onto the active nav tab.
  final KeyEventResult Function(FocusNode node, KeyEvent event)? onKeyEvent;

  /// Fired when the remote MENU (context-menu) key is pressed while this card is
  /// focused — the 最近播放 rail uses it to summon a delete-record confirm.
  final VoidCallback? onMenu;
  final bool autofocus;

  /// External focus node, supplied by the 最近播放 / 继续观看 rails so the home
  /// screen can restore focus to a specific card when returning from the player.
  final FocusNode? focusNode;

  /// Watch progress 0..1 for the 最近播放 / 继续观看 rails; null hides the bar.
  final double? progress;

  /// Small label (e.g. resolved source name / episode) shown for history cards.
  final String? badge;

  /// Resume position text (e.g. `看到 12:34`) shown under the source label.
  final String? timeLabel;

  /// Remote MENU first (summon delete on history cards), otherwise defer to the
  /// caller's hook (e.g. top-rail Up → nav tab).
  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if ((event is KeyDownEvent || event is KeyRepeatEvent) &&
        event.logicalKey == LogicalKeyboardKey.contextMenu &&
        onMenu != null) {
      onMenu!();
      return KeyEventResult.handled;
    }
    return onKeyEvent?.call(node, event) ?? KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.read(context);
    return Focusable(
      autofocus: autofocus,
      focusNode: focusNode,
      ensureVisibleAlignment: 0.5,
      onFocused: onFocused,
      onKeyEvent: (onKeyEvent == null && onMenu == null) ? null : _handleKey,
      onPressed: () => app.openTitle(item),
      builder: (context, focused) {
        return AnimatedContainer(
          duration: kFocusDur,
          curve: kEase,
          width: AppDims.cardW,
          height: AppDims.cardH,
          transformAlignment: Alignment.center,
          transform: focused
              ? (Matrix4.identity()
                ..translateByDouble(0.0, -10.0, 0.0, 1.0)
                ..scaleByDouble(1.06, 1.06, 1.06, 1.0))
              : Matrix4.identity(),
          decoration: BoxDecoration(
            color: AppColors.cardBg,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: focused ? const Color(0xE6FFFFFF) : const Color(0x12FFFFFF),
              width: focused ? 3 : 1,
            ),
            boxShadow: focused
                ? const [
                    BoxShadow(color: Color(0xA6000000), blurRadius: 70, offset: Offset(0, 30)),
                    BoxShadow(color: Color(0x804EA8FF), blurRadius: 46),
                  ]
                : const [BoxShadow(color: Color(0x73000000), blurRadius: 34, offset: Offset(0, 14))],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(focused ? 17 : 19),
            child: Stack(
              fit: StackFit.expand,
              children: [
                NetImage(item.cardUrl),
                // top scrim
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [Color(0xF203060E), Color(0x5903060E), Color(0x0003060E)],
                      stops: [0.06, 0.48, 0.78],
                    ),
                  ),
                ),
                _Tag(text: item.hd, left: 12),
                if (item.neu) const _NewTag(),
                if ((badge != null && badge!.isNotEmpty) || (timeLabel != null && timeLabel!.isNotEmpty))
                  _ResourceBadge(source: badge, time: timeLabel),
                _Meta(item: item, focused: focused),
                if (progress != null && progress! > 0) _ProgressStrip(value: progress!),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, required this.left});
  final String text;
  final double left;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 12,
      left: left,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0x99040810),
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: const Color(0x33FFFFFF)),
        ),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: AppColors.text,
            fontFamilyFallback: kFontFallback,
          ),
        ),
      ),
    );
  }
}

class _NewTag extends StatelessWidget {
  const _NewTag();

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 12,
      right: 12,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          gradient: AppColors.newTagGradient,
          borderRadius: BorderRadius.circular(7),
        ),
        child: const Text(
          '更新',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: Color(0xFFFFFFFF),
            fontFamilyFallback: kFontFallback,
          ),
        ),
      ),
    );
  }
}

/// Bottom-right pill for history cards: resource (source · 第N集) on top and the
/// resume position (看到 mm:ss) below. Either line may be omitted.
class _ResourceBadge extends StatelessWidget {
  const _ResourceBadge({this.source, this.time});
  final String? source;
  final String? time;

  @override
  Widget build(BuildContext context) {
    final hasSource = source != null && source!.isNotEmpty;
    final hasTime = time != null && time!.isNotEmpty;
    return Positioned(
      bottom: 14,
      right: 14,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xB3040810),
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: const Color(0x33FFFFFF)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (hasSource)
              Text(
                source!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.text,
                  fontFamilyFallback: kFontFallback,
                ),
              ),
            if (hasTime)
              Text(
                time!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AppColors.accent,
                  fontFamilyFallback: kFontFallback,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Thin resume-progress bar pinned to the card's bottom edge.
class _ProgressStrip extends StatelessWidget {
  const _ProgressStrip({required this.value});
  final double value;

  @override
  Widget build(BuildContext context) {
    final v = value.isNaN ? 0.0 : value.clamp(0.0, 1.0);
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Stack(
        children: [
          Container(height: 4, color: const Color(0x40000000)),
          FractionallySizedBox(
            widthFactor: v,
            child: Container(
              height: 4,
              decoration: const BoxDecoration(gradient: AppColors.barGradient),
            ),
          ),
        ],
      ),
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta({required this.item, required this.focused});
  final VodItem item;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 18,
      right: 18,
      bottom: 15,
      child: AnimatedSlide(
        duration: kFocusDur,
        curve: kEase,
        offset: focused ? Offset.zero : const Offset(0, 0.12),
        child: AnimatedOpacity(
          duration: kFocusDur,
          opacity: focused ? 1 : 0.9,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                item.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: AppColors.text,
                  fontFamilyFallback: kFontFallback,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                '${item.year} · ${item.genre} · ★ ${item.score}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14,
                  color: Color(0xFFA9BBD4),
                  fontFamilyFallback: kFontFallback,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
