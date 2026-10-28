import 'dart:ui';

import 'package:flutter/material.dart';

import '../core/theme.dart';

/// App startup splash. Shows the hero photo as a full-bleed, proportion-aware
/// background (BoxFit.cover + slow Ken-Burns zoom), layered with a depth-of-
/// field vignette and a dark scrim so the centered title reads cleanly. The
/// title gently floats to feel like it hovers above the photo. Calls
/// [onFinished] once the minimum display time has elapsed, then cross-fades out.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key, required this.onFinished});

  /// Invoked after the splash has finished its exit fade.
  final VoidCallback onFinished;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  // Drives the slow background zoom/drift ("hero" feel) for the whole lifetime.
  late final AnimationController _ken;
  // Drives the gentle, endless vertical bob of the title ("floating" feel).
  late final AnimationController _float;

  late final Animation<double> _scale; // background zoom
  late final Animation<Offset> _drift; // background parallax drift
  late final Animation<double> _bob; // title vertical float (px)

  bool _leaving = false;
  double _rootOpacity = 1.0;

  @override
  void initState() {
    super.initState();

    _ken = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..forward();

    _scale = Tween(begin: 1.06, end: 1.16)
        .animate(CurvedAnimation(parent: _ken, curve: Curves.easeOut));
    _drift = Tween(
      begin: const Offset(-0.015, -0.02),
      end: const Offset(0.015, 0.02),
    ).animate(CurvedAnimation(parent: _ken, curve: Curves.easeInOut));

    _float = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3500),
    )..repeat(reverse: true);
    _bob = Tween(begin: -7.0, end: 7.0)
        .animate(CurvedAnimation(parent: _float, curve: Curves.easeInOut));

    // Hold the splash for a minimum, then fade the whole thing out.
    Future.delayed(const Duration(milliseconds: 3300), _beginExit);
  }

  void _beginExit() {
    if (!mounted || _leaving) return;
    setState(() {
      _leaving = true;
      _rootOpacity = 0.0;
    });
  }

  @override
  void dispose() {
    _ken.dispose();
    _float.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: _rootOpacity,
      duration: const Duration(milliseconds: 650),
      curve: kEase,
      onEnd: () {
        if (_leaving) widget.onFinished();
      },
      child: Material(
        // The splash is hosted in MaterialApp.builder, OUTSIDE the Navigator's
        // Material. Without a Material ancestor, Flutter paints its debug
        // "yellow underline" under text — hence the stray lines/boxes under the
        // title & author. A transparent Material supplies the ancestor (and a
        // proper DefaultTextStyle) without painting any surface.
        type: MaterialType.transparency,
        child: ColoredBox(
          color: AppColors.bg,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 1) Hero photo — covers the screen (ratio preserved via cover)
              //    with a slow zoom + drift so it feels alive rather than
              //    static, and a soft blur so the whole frame reads as a dreamy,
              //    out-of-focus backdrop (depth of field) behind the title.
              AnimatedBuilder(
                animation: _ken,
                builder: (context, child) {
                  return Transform.scale(
                    scale: _scale.value,
                    child: FractionalTranslation(
                      translation: _drift.value,
                      child: child,
                    ),
                  );
                },
                child: ImageFiltered(
                  imageFilter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
                  child: const Image(
                    image: AssetImage('assets/images/splash_bg.jpg'),
                    fit: BoxFit.cover,
                    filterQuality: FilterQuality.medium,
                    gaplessPlayback: true,
                  ),
                ),
              ),

              // 2) Depth-of-field vignette: a strong radial falloff keeps the
              //    center subject bright and in-focus while the edges sink into
              //    darkness — the photo reads with real depth, no flat blur veil.
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment.center,
                    radius: 1.05,
                    colors: [
                      Color(0x00000000),
                      Color(0x4D04060D),
                      Color(0xD904060D),
                    ],
                    stops: [0.30, 0.68, 1.0],
                  ),
                ),
              ),

              // 3) Scrim: a soft vertical gradient so the title sits on calm
              //    darkness without washing the photo out.
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0x4D04060D),
                      Color(0x00000000),
                      Color(0x8004060D),
                    ],
                    stops: [0.0, 0.45, 1.0],
                  ),
                ),
              ),

              // 4) Centered title + author line — rendered fully on first frame
              //    (no entry animation) so it's already there at a glance, and
              //    gently bobbing so it feels like it floats above the photo.
              Center(
                child: AnimatedBuilder(
                  animation: _bob,
                  builder: (context, child) => Transform.translate(
                    offset: Offset(0, _bob.value),
                    child: child,
                  ),
                  child: const _SplashContent(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SplashContent extends StatelessWidget {
  const _SplashContent();

  // Brand gradient, unified with the header logo (white → light blue), carried
  // down into the app accent so the big title reads bright at the top and
  // settles into the brand blue — grand without drifting off-palette.
  static const LinearGradient _brand = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      Color(0xFFFFFFFF), // crisp white
      Color(0xFF9FD0FF), // header light blue
      Color(0xFF4EA8FF), // app accent
    ],
    stops: [0.0, 0.55, 1.0],
  );

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Single-line title: brand gradient, heavy weight and wide tracking for
        // a grand, expansive feel. Sans (kFontFallback) to match the whole app.
        ShaderMask(
          shaderCallback: (rect) => _brand.createShader(rect),
          blendMode: BlendMode.srcIn,
          child: const Text(
            '熊熊TV，随时随地看好剧',
            textAlign: TextAlign.center,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.visible,
            style: TextStyle(
              fontSize: 50,
              fontWeight: FontWeight.w800,
              color: Colors.white, // masked by the gradient
              letterSpacing: 6,
              height: 1.0,
              fontFamilyFallback: kFontFallback,
              shadows: [
                Shadow(color: Color(0x804EA8FF), blurRadius: 40),
                Shadow(color: Color(0x7304060D), blurRadius: 16, offset: Offset(0, 4)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 28),
        // Accent divider, centered — the app's standard accent gradient.
        Container(
          width: 108,
          height: 2,
          decoration: BoxDecoration(
            gradient: AppColors.barGradient,
            borderRadius: BorderRadius.circular(3),
            boxShadow: const [
              BoxShadow(color: Color(0x8000E5FF), blurRadius: 14),
            ],
          ),
        ),
        const SizedBox(height: 22),
        // Author credit — muted brand-blue ink, sans to match the app.
        const Text(
          'Levi倾情打造',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w400,
            color: AppColors.textDim,
            letterSpacing: 6,
            fontFamilyFallback: kFontFallback,
            shadows: [
              Shadow(color: Color(0x9904060D), blurRadius: 12, offset: Offset(0, 2)),
            ],
          ),
        ),
      ],
    );
  }
}
