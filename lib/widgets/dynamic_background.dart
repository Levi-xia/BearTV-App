import 'package:flutter/widgets.dart';

import '../core/app_scope.dart';
import '../core/theme.dart';

/// Full-bleed animated backdrop: cross-fades + subtly zooms between posters,
/// then layers the tint / glow gradients and a scroll-dim, matching `#bg`.
class DynamicBackground extends StatelessWidget {
  const DynamicBackground({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return Positioned.fill(
      child: Stack(
        fit: StackFit.expand,
        children: [
          ValueListenableBuilder<String?>(
            valueListenable: app.heroBg,
            builder: (context, url, _) {
              return AnimatedSwitcher(
                duration: kBgDur,
                switchInCurve: kEase,
                switchOutCurve: kEase,
                transitionBuilder: (child, animation) {
                  return FadeTransition(
                    opacity: animation,
                    child: ScaleTransition(
                      scale: Tween<double>(begin: 1.06, end: 1.0).animate(animation),
                      child: child,
                    ),
                  );
                },
                child: url == null
                    ? const ColoredBox(key: ValueKey('empty'), color: AppColors.bg)
                    : Image.network(
                        url,
                        key: ValueKey(url),
                        fit: BoxFit.cover,
                        alignment: const Alignment(0, -0.6), // center 20%
                        gaplessPlayback: true,
                        errorBuilder: (_, __, ___) =>
                            const ColoredBox(color: AppColors.bg),
                      ),
              );
            },
          ),
          const _TintLayers(),
          // Scroll-dim: the HTML darkens/desaturates the bg once scrolled.
          AnimatedOpacity(
            duration: const Duration(milliseconds: 600),
            opacity: app.scrolled ? 0.5 : 0.0,
            child: const ColoredBox(color: AppColors.bg),
          ),
        ],
      ),
    );
  }
}

class _TintLayers extends StatelessWidget {
  const _TintLayers();

  static const _bg = AppColors.bg;

  @override
  Widget build(BuildContext context) {
    return const IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          // radial blue glow, top-right
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(0.56, -0.76),
                radius: 1.1,
                colors: [Color(0x47005AC8), Color(0x00005AC8)],
                stops: [0.0, 0.6],
              ),
            ),
          ),
          // diagonal wash (100deg)
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment(-0.9, -0.4),
                end: Alignment(0.9, 0.4),
                colors: [_bg, Color(0xD104060D), Color(0x4004060D), Color(0x9904060D)],
                stops: [0.12, 0.42, 0.72, 1.0],
              ),
            ),
          ),
          // bottom-up fade
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [_bg, Color(0x8C04060D), Color(0x0004060D)],
                stops: [0.04, 0.32, 0.7],
              ),
            ),
          ),
          // soft cyan grain glow from bottom
          Opacity(
            opacity: 0.5,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment(0.0, 1.2),
                  radius: 0.9,
                  colors: [Color(0x2E4EA8FF), Color(0x004EA8FF)],
                  stops: [0.0, 0.55],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
