import 'package:flutter/widgets.dart';

import '../core/theme.dart';

/// Network image backed by the framework [Image.network].
///
/// History: earlier versions used `CachedNetworkImageProvider` for disk
/// caching, but after a tab switch (when the card Elements are disposed and
/// rebuilt) the provider's re-resolution would error, firing [errorBuilder] and
/// painting a bare [AppColors.cardBg] block — the "flash then goes black/blue"
/// bug. The full-bleed hero background used a plain [Image.network] and never
/// exhibited this, so we align the cards with that proven path.
///
/// [Image.gaplessPlayback] keeps the decoded pixels across re-resolves so a
/// rebuild never flashes to black; Flutter's in-memory [ImageCache] (enlarged
/// in main) covers repeat views. Empty URLs (missing TMDB artwork) render as a
/// plain placeholder block.
class NetImage extends StatelessWidget {
  const NetImage(this.url,
      {super.key, this.fit = BoxFit.cover, this.alignment = Alignment.center});

  final String url;
  final BoxFit fit;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    if (url.isEmpty) return const ColoredBox(color: AppColors.cardBg);
    return Image.network(
      url,
      key: ValueKey(url),
      fit: fit,
      alignment: alignment,
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) => const ColoredBox(color: AppColors.cardBg),
    );
  }
}
