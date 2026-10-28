import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/app_controller.dart';
import 'core/app_scope.dart';
import 'core/theme.dart';
import 'player/video_adapter.dart';
import 'screens/home_screen.dart';
import 'screens/play_screen.dart';
import 'screens/search_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/splash_screen.dart';
import 'widgets/dynamic_background.dart';
import 'widgets/focusable.dart';
import 'widgets/header_bar.dart';
import 'widgets/toast_host.dart';

/// App root: owns the [AppController] and hosts the dark themed [Shell].
class NebulaApp extends StatefulWidget {
  const NebulaApp({super.key, this.controller});

  /// Test seam: inject a preconfigured controller. When null, one is created
  /// (and disposed) here.
  final AppController? controller;

  @override
  State<NebulaApp> createState() => _NebulaAppState();
}

class _NebulaAppState extends State<NebulaApp> {
  late final AppController _controller;
  late final bool _ownsController;

  // Startup splash: shown once over the shell, then removed after its fade-out.
  bool _showSplash = true;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    // Production uses the real video_player-backed adapter; tests inject their
    // own controller (defaulting to MockPlayerController) via [widget.controller].
    _controller = widget.controller ?? AppController(player: VideoAdapter());
    _controller.init();
  }

  @override
  void dispose() {
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: '熊熊TV',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: AppColors.bg,
        colorScheme: const ColorScheme.dark(
            surface: AppColors.bg, primary: AppColors.accent),
        fontFamilyFallback: kFontFallback,
        useMaterial3: true,
      ),
      home: AppScope(controller: _controller, child: const Shell()),
      // Zoom the whole UI out so more content is visible on a TV screen. The
      // splash is layered on top (outside _UiScale) so it fills the raw screen.
      builder: (context, child) => Stack(
        fit: StackFit.expand,
        children: [
          _UiScale(child: child!),
          if (_showSplash)
            SplashScreen(
              onFinished: () {
                if (mounted) setState(() => _showSplash = false);
              },
            ),
        ],
      ),
    );
  }
}

/// Zooms the entire UI out by [kUiScale] so more content fits on a TV screen:
/// the whole tree lays out against a larger logical canvas (`size / kUiScale`),
/// then is scaled down to exactly fill the physical screen. Text, posters and
/// spacing shrink uniformly without touching any per-widget dimension.
///
/// Why the explicit [OverflowBox] + [Transform] (rather than a bare
/// `Transform.scale` or a `FittedBox`):
///   • [Transform.scale] alone is a paint-time effect that leaves layout
///     constraints untouched, so the inner `SizedBox(logical)` gets squeezed
///     back down to the physical size and, once scaled by `kUiScale`, leaves
///     black bars on the right/bottom.
///   • [FittedBox] only scales-to-fit when it receives *tight* constraints;
///     depending on where it sits it can end up sizing to the child instead,
///     which reintroduces the gap.
/// So: pin the outer box to the real screen size, let [OverflowBox] hand the
/// subtree the (larger) logical size unclamped, then [Transform] scales that
/// down about the top-left to land exactly on the physical bounds. [ClipRect]
/// guards against any sub-pixel overpaint.
class _UiScale extends StatelessWidget {
  const _UiScale({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (kUiScale >= 0.999) return child;
    // Scale against the *actual* box we are handed (constraints.biggest), not
    // MediaQuery.size — on some devices (overscan, insets, rounding) the two
    // differ, and using the wrong number is exactly what leaves a black strip
    // on the right/bottom after the down-scale.
    return LayoutBuilder(
      builder: (context, constraints) {
        final physical = constraints.biggest;
        final logical = physical / kUiScale;
        final mq = MediaQuery.of(context);
        return ClipRect(
          child: OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: logical.width,
            maxWidth: logical.width,
            minHeight: logical.height,
            maxHeight: logical.height,
            child: Transform.scale(
              scale: kUiScale,
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: logical.width,
                height: logical.height,
                child: MediaQuery(
                  data: mq.copyWith(size: logical),
                  child: child,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Top-level layout: animated background, page stack, header, hint bar, toast.
/// Also wires the global remote keys (Back / Esc, F for fullscreen).
class Shell extends StatelessWidget {
  const Shell({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) app.backFromPop();
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyF): () {
            if (app.page == AppPage.play ||
                (app.isLiveTab && app.iptv.currentChannel != null)) {
              app.setFullscreen();
            }
          },
          const SingleActivator(LogicalKeyboardKey.escape): app.backFromKey,
          const SingleActivator(LogicalKeyboardKey.goBack): app.backFromKey,
          const SingleActivator(LogicalKeyboardKey.browserBack): app.backFromKey,
        },
        child: Material(
          // Transparent Material: paints no background (DynamicBackground shows
          // through) but supplies a proper DefaultTextStyle so text isn't drawn
          // with Flutter's "no Material ancestor" yellow underline.
          type: MaterialType.transparency,
          child: ColoredBox(
            color: AppColors.bg,
            // One shared FocusScope for the header + the active page, so D-pad
            // directional traversal can move between page content and the
            // header's tabs/tools. (Each page is a FocusTraversalGroup, not its
            // own FocusScope, otherwise the header — living outside the page
            // scope — would be unreachable by arrow keys on a TV remote.)
            child: FocusScope(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  const DynamicBackground(),
                  Positioned.fill(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _HomeLayer(visible: app.page == AppPage.home),
                        if (app.page == AppPage.play) const _PlayLayer(),
                        if (app.page == AppPage.settings)
                          const _SettingsLayer(),
                        if (app.page == AppPage.search) const _SearchLayer(),
                      ],
                    ),
                  ),
                  if (!app.fullscreen) const HeaderBar(),
                  if (app.exitConfirmVisible) const _ExitConfirmOverlay(),
                  const ToastHost(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Home stays mounted (preserving scroll + focus memory) and cross-fades out.
class _HomeLayer extends StatelessWidget {
  const _HomeLayer({required this.visible});
  final bool visible;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: visible ? 1 : 0,
      duration: kPageDur,
      curve: kEase,
      child: IgnorePointer(
        ignoring: !visible,
        child: ExcludeFocus(
          excluding: !visible,
          child: AnimatedScale(
            scale: visible ? 1.0 : 0.985,
            duration: kPageDur,
            curve: kEase,
            child: FocusTraversalGroup(child: const HomeScreen()),
          ),
        ),
      ),
    );
  }
}

/// Play page is built fresh on entry (so the player auto-focuses) and fades in.
class _PlayLayer extends StatelessWidget {
  const _PlayLayer();

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: kPageDur,
      curve: kEase,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.scale(scale: 0.985 + 0.015 * t, child: child),
      ),
      child: FocusTraversalGroup(child: const PlayScreen()),
    );
  }
}

/// Settings page, faded in over the (dimmed) home background.
class _SettingsLayer extends StatelessWidget {
  const _SettingsLayer();

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: kPageDur,
      curve: kEase,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.scale(scale: 0.985 + 0.015 * t, child: child),
      ),
      child: FocusTraversalGroup(child: const SettingsScreen()),
    );
  }
}

/// Search page (TMDB), faded in over the home background.
class _SearchLayer extends StatelessWidget {
  const _SearchLayer();

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: kPageDur,
      curve: kEase,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.scale(scale: 0.985 + 0.015 * t, child: child),
      ),
      child: FocusTraversalGroup(child: const SearchScreen()),
    );
  }
}

/// Modal "exit app?" confirm, raised by a double-Back on the home page. Focus is
/// trapped here (its own [FocusScope]); 取消 autofocuses so a stray OK cancels.
class _ExitConfirmOverlay extends StatelessWidget {
  const _ExitConfirmOverlay();

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return Positioned.fill(
      child: FocusScope(
        autofocus: true,
        child: ColoredBox(
          color: const Color(0xB3000000),
          child: Center(
            child: Container(
              width: 460,
              padding: const EdgeInsets.fromLTRB(32, 30, 32, 26),
              decoration: BoxDecoration(
                color: AppColors.cardBg,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: AppColors.hairline),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('退出应用？',
                      style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                          color: AppColors.text,
                          fontFamilyFallback: kFontFallback)),
                  const SizedBox(height: 10),
                  const Text('确认后将关闭熊熊TV。',
                      style: TextStyle(
                          fontSize: 16,
                          color: AppColors.textDim,
                          fontFamilyFallback: kFontFallback)),
                  const SizedBox(height: 26),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      _DialogBtn(
                        label: '取消',
                        autofocus: true,
                        onPressed: app.cancelExit,
                      ),
                      const SizedBox(width: 14),
                      _DialogBtn(
                        label: '退出',
                        primary: true,
                        onPressed: () => SystemNavigator.pop(),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A D-pad-focusable button for [_ExitConfirmOverlay].
class _DialogBtn extends StatelessWidget {
  const _DialogBtn({
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
      autofocus: autofocus,
      onPressed: onPressed,
      builder: (context, focused) {
        final active = focused || primary;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 14),
          decoration: BoxDecoration(
            color: focused
                ? AppColors.accent
                : (primary ? const Color(0x334EA8FF) : AppColors.glass),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color:
                    primary || focused ? AppColors.accent : AppColors.hairline),
          ),
          child: Text(label,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: focused
                    ? AppColors.focusInk
                    : (active ? AppColors.text : AppColors.textDim),
                fontFamilyFallback: kFontFallback,
              )),
        );
      },
    );
  }
}
