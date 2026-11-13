import 'package:flutter/widgets.dart';

import '../core/theme.dart';
import '../data/models.dart';
import 'media_card.dart';

/// A titled horizontal rail of [MediaCard]s (`.rail-head` + `.rail`).
class Rail extends StatelessWidget {
  const Rail({
    super.key,
    required this.title,
    required this.subtitle,
    required this.items,
    this.onCardFocused,
    this.onCardKeyEvent,
    this.onCardMenu,
    this.autofocusFirst = false,
    this.focusNodeForItem,
    this.progressForItem,
    this.badgeForItem,
    this.timeForItem,
    this.onCardPressed,
  });

  final String title;
  final String subtitle;
  final List<VodItem> items;
  final void Function(VodItem item)? onCardFocused;

  /// Optional raw key hook forwarded to every card — the top rail uses it to
  /// send Up back onto the active nav tab.
  final KeyEventResult Function(FocusNode node, KeyEvent event)? onCardKeyEvent;

  /// Optional MENU-key handler forwarded per card — the 最近播放 rail uses it to
  /// summon a delete-record confirm for the focused item.
  final void Function(VodItem item)? onCardMenu;
  final bool autofocusFirst;

  /// Optional per-item focus node, so the home screen can restore focus to a
  /// specific card (the just-watched title) when returning from the player.
  final FocusNode? Function(VodItem item)? focusNodeForItem;

  /// Optional per-item resume progress (0..1), resource label, and resume-time
  /// text, used by the 最近播放 / 继续观看 rails to overlay progress on cards.
  final double? Function(VodItem item)? progressForItem;
  final String? Function(VodItem item)? badgeForItem;
  final String? Function(VodItem item)? timeForItem;

  /// Overrides the default "open this title" action per card.
  final void Function(VodItem item)? onCardPressed;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: AppDims.pad, bottom: 16),
          child: RailHead(title: title, subtitle: subtitle),
        ),
        SizedBox(
          height: AppDims.cardH + 34,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(
                horizontal: AppDims.pad, vertical: 12),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 22),
            itemBuilder: (context, i) => Center(
              child: MediaCard(
                item: items[i],
                autofocus: autofocusFirst && i == 0,
                focusNode: focusNodeForItem?.call(items[i]),
                onFocused: onCardFocused == null
                    ? null
                    : () => onCardFocused!(items[i]),
                onKeyEvent: onCardKeyEvent,
                onMenu: onCardMenu == null ? null : () => onCardMenu!(items[i]),
                progress: progressForItem?.call(items[i]),
                badge: badgeForItem?.call(items[i]),
                timeLabel: timeForItem?.call(items[i]),
                onPressed: onCardPressed == null
                    ? null
                    : () => onCardPressed!(items[i]),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// `.rail-head`: bold heading + dim caption on the same baseline.
class RailHead extends StatelessWidget {
  const RailHead({super.key, required this.title, required this.subtitle});
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w700,
            color: AppColors.text,
            fontFamilyFallback: kFontFallback,
          ),
        ),
        const SizedBox(width: 16),
        Flexible(
          child: Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 16,
              color: AppColors.textDim,
              fontFamilyFallback: kFontFallback,
            ),
          ),
        ),
      ],
    );
  }
}
