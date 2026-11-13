import 'dart:async';
import 'dart:ui' show ImageFilter, FontFeature;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../core/app_controller.dart';
import '../core/app_scope.dart';
import '../core/theme.dart';
import '../data/nav_config.dart';
import 'focus_fx.dart';
import 'focusable.dart';

/// Fixed top bar: logo, nav tabs, tools, live clock. Gains a blurred
/// solid background + hairline border once the page is scrolled (`body.scrolled`).
///
/// Owns the focus nodes for both the tools (🔍/⚙) and the nav tabs so that
/// vertical D-pad moves between the two rows are explicit and deterministic
/// (Flutter's geometric traversal is unreliable here because the tools sit
/// top-right while the tabs run along the bottom-left):
///   • Up on a tab   → the search tool.
///   • Down on a tool → the active tab (the one you came from).
///   • Returning to home ([AppController.homeFocusRequest]) → the active tab.
class HeaderBar extends StatelessWidget {
  const HeaderBar({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final scrolled = app.scrolled;
    final content = Padding(
      // Two rows: top = logo (left) + tools (right); second = nav tabs, left
      // aligned to the logo so they float over the hero background.
      padding: const EdgeInsets.fromLTRB(AppDims.pad, 18, AppDims.pad, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              _Logo(),
              Spacer(),
              _Tools(),
            ],
          ),
          const SizedBox(height: 14),
          // Category tabs belong to the home page only; on settings/search they
          // add confusing cross-navigation, so hide them there.
          if (app.page == AppPage.home) const _NavTabs(),
        ],
      ),
    );

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: ClipRect(
        child: BackdropFilter(
          filter: scrolled
              ? ImageFilter.blur(sigmaX: 22, sigmaY: 22)
              : ImageFilter.blur(sigmaX: 0.001, sigmaY: 0.001),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 400),
            curve: kEase,
            decoration: BoxDecoration(
              color: scrolled ? const Color(0xD1060912) : null,
              gradient: scrolled
                  ? null
                  : const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0xEB04060D), Color(0x0004060D)],
                    ),
              border: scrolled
                  ? const Border(bottom: BorderSide(color: Color(0x0FFFFFFF)))
                  : null,
            ),
            child: content,
          ),
        ),
      ),
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 26,
          decoration: BoxDecoration(
            gradient: AppColors.logoGradient,
            borderRadius: BorderRadius.circular(6),
            boxShadow: const [
              BoxShadow(color: Color(0x9900E5FF), blurRadius: 18)
            ],
          ),
        ),
        const SizedBox(width: 12),
        // Gradient text (white -> light blue), matching the clipped logo span.
        ShaderMask(
          shaderCallback: (rect) => const LinearGradient(
            colors: [Color(0xFFFFFFFF), Color(0xFF9FD0FF)],
          ).createShader(rect),
          child: const Text(
            '熊熊TV',
            style: TextStyle(
              fontSize: 23,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
              color: Color(0xFFFFFFFF),
              fontFamilyFallback: kFontFallback,
            ),
          ),
        ),
      ],
    );
  }
}

/// Horizontally-scrollable category tabs. Owns a [FocusNode] per tab so that
/// returning to the home page (via [AppController.homeFocusRequest]) can move
/// focus back onto the active tab — keeping the focus ring on-screen.
class _NavTabs extends StatefulWidget {
  const _NavTabs();

  @override
  State<_NavTabs> createState() => _NavTabsState();
}

class _NavTabsState extends State<_NavTabs> {
  // skipTraversal: the tabs must NOT be reachable by geometric D-pad drift from
  // page content (that was silently switching tabs). Focus only ever reaches a
  // tab explicitly — via Left/Right between tabs, or a content/tool crossing
  // that targets the *current* tab.
  final List<FocusNode> _nodes =
      List.generate(kTabs.length, (_) => FocusNode(skipTraversal: true));
  ValueNotifier<int>? _signal;
  AppController? _app;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _app = AppScope.read(context);
    final signal = _app!.homeFocusRequest;
    if (signal != _signal) {
      _signal?.removeListener(_onHomeFocus);
      _signal = signal..addListener(_onHomeFocus);
    }
  }

  /// Return-to-home: focus the active tab. The home layer's ExcludeFocus is
  /// lifting this same frame (the Back handler → notifyListeners guarantees
  /// one), so defer until it has committed.
  void _onHomeFocus() {
    final app = AppScope.read(context);
    if (app.page != AppPage.home) return;
    // When returning from the player with a card to restore (pendingHomeFocusKey
    // set), the home screen focuses that recent card — don't steal focus onto
    // the nav tab here. Read synchronously so we never schedule a competing
    // post-frame focus request.
    if (app.pendingHomeFocusKey != null) return;
    final i = app.currentTab.clamp(0, _nodes.length - 1);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _nodes[i].requestFocus();
    });
  }

  @override
  void dispose() {
    _signal?.removeListener(_onHomeFocus);
    final app = _app;
    if (app != null && _nodes.contains(app.activeTabFocusNode)) {
      app.activeTabFocusNode = null;
    }
    for (final n in _nodes) {
      n.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    // Keep the controller pointed at the current tab's node so content (Up) and
    // the header tools (Down) can cross back onto *this* tab, not a neighbour.
    app.activeTabFocusNode = _nodes[app.currentTab.clamp(0, _nodes.length - 1)];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          // Rendered in display order (kTabOrder: 直播 first), but each tab keeps
          // its logical kTabs index; Left/Right step along the display order.
          for (var pos = 0; pos < kTabOrder.length; pos++)
            _NavTab(
              index: kTabOrder[pos],
              label: kTabs[kTabOrder[pos]],
              active: kTabOrder[pos] == app.currentTab,
              focusNode: _nodes[kTabOrder[pos]],
              leftIndex: pos > 0 ? kTabOrder[pos - 1] : null,
              rightIndex:
                  pos < kTabOrder.length - 1 ? kTabOrder[pos + 1] : null,
              onFocusSibling: (j) => _nodes[j].requestFocus(),
            ),
        ],
      ),
    );
  }
}

class _NavTab extends StatelessWidget {
  const _NavTab({
    required this.index,
    required this.label,
    required this.active,
    required this.onFocusSibling,
    this.leftIndex,
    this.rightIndex,
    this.focusNode,
  });
  final int index;
  final String label;
  final bool active;
  final FocusNode? focusNode;

  /// Logical kTabs indices of the display-order neighbours (null at the ends).
  final int? leftIndex;
  final int? rightIndex;

  /// Requests focus on a sibling tab (whose `onFocused` performs the switch).
  final void Function(int index) onFocusSibling;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.read(context);
    return Focusable(
      focusNode: focusNode,
      // Cold-start focus lands on the active tab (推荐) — never on a content
      // card — so the app opens on the full hero background instead of a
      // focused poster deep in a rail. Only the active tab autofocuses; because
      // its FocusNode persists, this fires just once, on the very first build.
      autofocus: active,
      // TV convention: moving focus onto a tab switches to it immediately
      // (no separate OK press). Feeds are cached per tab so re-focusing a
      // visited tab is cheap. Because the tabs skip geometric traversal, this
      // only ever fires from an intentional move (Left/Right, or a return-to-
      // tab crossing) — content drift can no longer trip it.
      onFocused: () {
        if (index != app.currentTab) app.setTab(index);
        // Focusing a tab always snaps the page back to the top, so the large
        // hero background is shown (rather than staying scrolled down in the
        // grid from before).
        app.homeScrollTopRequest.value++;
      },
      onPressed: () => app.setTab(index),
      // The tab strip owns horizontal movement: Left/Right step between tabs
      // (and switch), consumed at both ends so focus never escapes sideways to
      // the tools. Up/Down fall through to default traversal (tools / content).
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
          return KeyEventResult.ignored;
        }
        final k = event.logicalKey;
        if (k == LogicalKeyboardKey.arrowLeft) {
          if (leftIndex != null) onFocusSibling(leftIndex!);
          return KeyEventResult.handled;
        }
        if (k == LogicalKeyboardKey.arrowRight) {
          if (rightIndex != null) onFocusSibling(rightIndex!);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      builder: (context, focused) {
        // Active or focused → bright label + gradient underline (the "蓝色底").
        // No pill box behind the tab, per design.
        final highlight = active || focused;
        return FocusFx.scale(
          focused,
          Container(
            margin: const EdgeInsets.only(right: 6),
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 20,
                    color:
                        highlight ? const Color(0xFFFFFFFF) : AppColors.textDim,
                    fontWeight: highlight ? FontWeight.w600 : FontWeight.w400,
                    fontFamilyFallback: kFontFallback,
                  ),
                ),
                const SizedBox(height: 4),
                // active/focused underline gradient bar
                Container(
                  height: 3,
                  width: 42,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(3),
                    gradient: highlight ? AppColors.barGradient : null,
                    boxShadow: highlight
                        ? const [
                            BoxShadow(color: AppColors.accent, blurRadius: 14)
                          ]
                        : null,
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

class _Tools extends StatelessWidget {
  const _Tools();

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    // On the player page the search/settings entries are irrelevant and only
    // clutter the overlay, so show just the clock there.
    final showEntries = app.page != AppPage.play;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showEntries) ...[
          _RoundTool(icon: '🔍', onPressed: () => app.openSearch()),
          const SizedBox(width: 14),
          _RoundTool(icon: '⚙', onPressed: () => app.openSettings()),
          const SizedBox(width: 14),
        ],
        const _Clock(),
      ],
    );
  }
}

class _RoundTool extends StatelessWidget {
  const _RoundTool({required this.icon, required this.onPressed});
  final String icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.read(context);
    return Focusable(
      onPressed: onPressed,
      // Down from a tool enters the tab strip on the *current* tab (e.g. 推荐),
      // instead of geometric traversal picking the nearest tab below-right (the
      // last one). Only on home, where the strip exists; elsewhere Down falls
      // through to the page content (search keyboard / settings list).
      onKeyEvent: (node, event) {
        if ((event is KeyDownEvent || event is KeyRepeatEvent) &&
            event.logicalKey == LogicalKeyboardKey.arrowDown &&
            app.focusActiveTab()) {
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      builder: (context, focused) => FocusFx.scale(
        focused,
        Container(
          width: 56,
          height: 56,
          alignment: Alignment.center,
          decoration: focused
              ? FocusFx.pill(focused, radius: 28)
              : BoxDecoration(
                  color: AppColors.glass,
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.hairline),
                ),
          child: Text(icon, style: const TextStyle(fontSize: 22)),
        ),
      ),
    );
  }
}

class _Clock extends StatefulWidget {
  const _Clock();

  @override
  State<_Clock> createState() => _ClockState();
}

class _ClockState extends State<_Clock> {
  Timer? _timer;
  String _time = '--:--';

  @override
  void initState() {
    super.initState();
    _tick();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void _tick() {
    final now = DateTime.now();
    final t =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    if (t != _time && mounted) setState(() => _time = t);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Text(
      _time,
      style: const TextStyle(
        fontSize: 19,
        color: AppColors.textDim,
        fontFeatures: [FontFeature.tabularFigures()],
        fontFamilyFallback: kFontFallback,
      ),
    );
  }
}
