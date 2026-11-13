import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../core/app_controller.dart';
import '../core/app_scope.dart';
import '../core/theme.dart';
import '../data/danmaku/danmaku_models.dart';
import '../data/nav_config.dart';
import '../data/vod/cms_models.dart';
import '../player/player_controller.dart';
import '../player/video_adapter.dart';
import '../widgets/chips.dart';
import '../widgets/danmaku_overlay.dart';
import '../widgets/episode_pager.dart';
import '../widgets/focusable.dart';
import '../widgets/focus_fx.dart';
import '../widgets/net_image.dart';
import '../widgets/on_screen_keyboard.dart';
import 'download_sheet.dart';

String _fmt(Duration d) {
  final h = d.inHours.toString().padLeft(2, '0');
  final m = (d.inMinutes % 60).toString().padLeft(2, '0');
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return '$h:$m:$s';
}

/// Play page: real CMS-resolved player + detail/resource side panel + episode
/// grid, plus a remote-first fullscreen mode.
class PlayScreen extends StatefulWidget {
  const PlayScreen({super.key});

  @override
  State<PlayScreen> createState() => _PlayScreenState();
}

class _PlayScreenState extends State<PlayScreen> {
  // Focus anchor for the first side-panel control. Pressing Right on the player
  // jumps focus here (播放设置), instead of drifting up to the header search.
  final FocusNode _panelNode = FocusNode(debugLabel: 'playSidePanelFirst');

  // Focus anchor for the player surface. On entry we explicitly focus this
  // (not just rely on autofocus) so the D-pad starts on the player — OK then
  // goes fullscreen — rather than drifting onto a side-panel control.
  final FocusNode _playerNode = FocusNode(debugLabel: 'playPlayerSurface');

  // 下载选集 sheet, opened from the side panel / fullscreen menu. Back closes it
  // first.
  bool _downloadOpen = false;
  // Floating control sheet for one side-panel action (线路 / 切换资源 / 倍速 …).
  _PlayAction? _action;
  late final AppController _app;
  late final bool Function() _overlayBackInterceptor;

  @override
  void initState() {
    super.initState();
    _app = AppScope.read(context);
    _overlayBackInterceptor = () {
      if (_downloadOpen) {
        _closeDownloadSheet();
        return true;
      }
      if (_action != null) {
        _closeAction();
        return true;
      }
      return false;
    };
    _app.playOverlayBackInterceptor = _overlayBackInterceptor;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _playerNode.requestFocus();
    });
  }

  void _openAction(_PlayAction action) {
    if (action == _PlayAction.download) {
      if (_downloadOpen) return;
      setState(() => _downloadOpen = true);
      return;
    }
    if (_action == action) return;
    setState(() => _action = action);
  }

  void _closeAction() {
    if (_action == null) return;
    setState(() => _action = null);
    _panelNode.requestFocus();
  }

  void _closeDownloadSheet() {
    if (!_downloadOpen) return;
    setState(() => _downloadOpen = false);
    // Both sheets are opened from a tile, so hand focus back to the grid.
    _panelNode.requestFocus();
  }

  @override
  void dispose() {
    if (_app.playOverlayBackInterceptor == _overlayBackInterceptor) {
      _app.playOverlayBackInterceptor = null;
    }
    _panelNode.dispose();
    _playerNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final item = app.currentItem;
    if (item == null) return const SizedBox.shrink();

    if (app.fullscreen) return const _FullscreenPlayer();

    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF060A14), Color(0xFF0A1020), Color(0xFF060810)],
              stops: [0.0, 0.5, 1.0],
            ),
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      AppDims.pad, 176, AppDims.pad, 56),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        // The player used to fill the whole row (≈1400px wide
                        // at 1080p), which dwarfed the controls. Cap it so the
                        // right panel reads as an equal half of the page.
                        child: Align(
                          alignment: Alignment.topLeft,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 1040),
                            child: AspectRatio(
                                aspectRatio: 16 / 9,
                                child: _Player(
                                    playerNode: _playerNode,
                                    panelNode: _panelNode)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 34),
                      SizedBox(
                        width: AppDims.sideW,
                        child: _SidePanel(
                          panelNode: _panelNode,
                          onOpenAction: _openAction,
                        ),
                      ),
                    ],
                  ),
                ),
                const _Episodes(),
                const SizedBox(height: 80),
              ],
            ),
          ),
        ),
        if (_action != null) _ActionSheet(action: _action!),
        if (_downloadOpen) DownloadSheet(onClose: _closeDownloadSheet),
      ],
    );
  }
}

/// Renders the real video texture when the injected player is a [VideoAdapter]
/// and initialised; otherwise falls back to the poster (tests / not-ready).
class _VideoSurface extends StatelessWidget {
  const _VideoSurface();

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final item = app.currentItem!;
    Widget poster() => Stack(
          fit: StackFit.expand,
          children: [
            NetImage(item.bgUrl),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Color(0xCC000000), Color(0x00000000)],
                  stops: [0.0, 0.45],
                ),
              ),
            ),
          ],
        );

    final p = app.player;
    if (p is! VideoAdapter) return poster();
    return ValueListenableBuilder<PlayerValue>(
      valueListenable: p,
      builder: (context, v, _) {
        final raw = p.raw;
        if (!v.ready || raw == null || !raw.value.isInitialized) {
          return poster();
        }
        return ColoredBox(
          color: const Color(0xFF000000),
          child: Center(
            child: AspectRatio(
              aspectRatio:
                  raw.value.aspectRatio == 0 ? 16 / 9 : raw.value.aspectRatio,
              child: VideoPlayer(raw),
            ),
          ),
        );
      },
    );
  }
}

class _Player extends StatelessWidget {
  const _Player({required this.playerNode, required this.panelNode});
  final FocusNode playerNode;
  final FocusNode panelNode;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return Focusable(
      focusNode: playerNode,
      autofocus: true,
      ensureVisibleAlignment:
          0.5, // keep the player clear of the top header on scroll-up
      onPressed: () => app.setFullscreen(true), // OK on player → fullscreen
      onKeyEvent: (node, event) {
        // Right off the player → 播放设置 side panel (not the header search).
        if ((event is KeyDownEvent || event is KeyRepeatEvent) &&
            event.logicalKey == LogicalKeyboardKey.arrowRight) {
          panelNode.requestFocus();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      builder: (context, focused) {
        return AnimatedContainer(
          duration: kFocusDur,
          curve: kEase,
          decoration: BoxDecoration(
            color: const Color(0xFF000000),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: focused ? AppColors.accent2 : const Color(0x1AFFFFFF),
              width: focused ? 3 : 1,
            ),
            boxShadow: [
              const BoxShadow(
                  color: Color(0x99000000),
                  blurRadius: 80,
                  offset: Offset(0, 34)),
              if (focused)
                const BoxShadow(color: Color(0x5900E5FF), blurRadius: 60),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: Stack(
              fit: StackFit.expand,
              children: const [
                _VideoSurface(),
                _DanmakuLayer(),
                _StatusOverlay(),
                _PlayStateBadge(),
                _CacheBadge(),
                _PlayerControls(),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Centered状态：正在匹配资源 / 无资源错误 / 缓冲中。
class _StatusOverlay extends StatelessWidget {
  const _StatusOverlay();

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    if (app.resolving) return const _CenterNote('正在匹配可播放资源…');
    if (app.playError != null) return _CenterNote(app.playError!);
    return const SizedBox.shrink();
  }
}

class _CenterNote extends StatelessWidget {
  const _CenterNote(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0x66000000),
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 30),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(
            fontSize: 18,
            height: 1.5,
            color: AppColors.text,
            fontFamilyFallback: kFontFallback),
      ),
    );
  }
}

/// Centered playback-state badge (purely visual — focus stays on the player so
/// OK still toggles play / fullscreen). Shows an unambiguous pause glyph +
/// 「已暂停」 while genuinely paused; while the stream is still opening or
/// buffering it shows "缓冲中…" instead, so buffering never looks like a manual
/// pause. Nothing is drawn while playing.
class _PlayStateBadge extends StatelessWidget {
  const _PlayStateBadge();

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    if (app.resolving || app.playError != null) return const SizedBox.shrink();
    return ValueListenableBuilder<PlayerValue>(
      valueListenable: app.player,
      builder: (context, v, _) {
        if (v.playing) return const SizedBox.shrink();
        // Opening or waiting on the network → not a pause; show buffering.
        if (v.buffering || !v.ready) {
          return const Center(
            child: Text('缓冲中…',
                style: TextStyle(
                    fontSize: 16,
                    color: AppColors.textDim,
                    fontFamilyFallback: kFontFallback)),
          );
        }
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 96,
                height: 96,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: const Color(0x73000000),
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0x80FFFFFF), width: 2),
                ),
                child: const Icon(Icons.pause_rounded,
                    size: 54, color: AppColors.text),
              ),
              const SizedBox(height: 14),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                decoration: BoxDecoration(
                  color: const Color(0x59000000),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text('已暂停',
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: AppColors.text,
                        fontFamilyFallback: kFontFallback)),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Top-left pill shown while the player is reading a downloaded file. Purely
/// informational; focus stays on the player.
class _CacheBadge extends StatelessWidget {
  const _CacheBadge();

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    if (!app.playingFromCache) return const SizedBox.shrink();
    return Positioned(
      top: 16,
      left: 16,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
        decoration: BoxDecoration(
          color: const Color(0x99000000),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: const Color(0x5548E08A)),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.offline_pin_rounded, size: 17, color: AppColors.live),
            SizedBox(width: 7),
            Text('正在播放缓存内容',
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppColors.text,
                    fontFamilyFallback: kFontFallback)),
          ],
        ),
      ),
    );
  }
}

/// Bottom overlay: gradient scrim, progress bar, elapsed/total time and a
/// `源名 · 分集 · 倍速` status label.
class _PlayerControls extends StatelessWidget {
  const _PlayerControls();

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return ValueListenableBuilder<PlayerValue>(
      valueListenable: app.player,
      builder: (context, v, _) {
        final eps = app.currentEpisodes;
        final epTitle = (app.episodeIndex >= 0 && app.episodeIndex < eps.length)
            ? episodeLabel(
                eps[app.episodeIndex].title,
                app.episodeIndex,
                unit: eps[app.episodeIndex].title.contains('期') ? '期' : '集',
              )
            : '';
        final srcName = app.currentDetail?.sourceName ?? '';
        final speedLabel = v.speed == 1.0 ? '' : ' · ${v.speed}x';
        final cacheLabel = app.playingFromCache ? ' · 缓存' : '';
        final label =
            [srcName, epTitle].where((s) => s.isNotEmpty).join(' · ') +
                speedLabel +
                cacheLabel;
        return Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: _ControlsBody(value: v, label: label),
        );
      },
    );
  }
}

class _ControlsBody extends StatelessWidget {
  const _ControlsBody({required this.value, required this.label});
  final PlayerValue value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 40, 20, 16),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Color(0xCC000000), Color(0x00000000)],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (label.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 15,
                    color: AppColors.textDim,
                    fontFamilyFallback: kFontFallback),
              ),
            ),
          _ProgressBar(
              progress: value.progress, buffered: value.bufferedProgress),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_fmt(value.position), style: _timeStyle),
              Text(_fmt(value.duration), style: _timeStyle),
            ],
          ),
        ],
      ),
    );
  }
}

const _timeStyle = TextStyle(
    fontSize: 14, color: AppColors.text, fontFamilyFallback: kFontFallback);

/// Thin rounded track with a gradient fill (`.bar`), plus a lighter "buffered"
/// (白条) layer showing how far ahead the stream is cached.
class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.progress, this.buffered = 0});
  final double progress;
  final double buffered;

  @override
  Widget build(BuildContext context) {
    final p = progress.isNaN ? 0.0 : progress.clamp(0.0, 1.0);
    final b = buffered.isNaN ? 0.0 : buffered.clamp(0.0, 1.0);
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: Stack(
        children: [
          Container(height: 6, color: const Color(0x33FFFFFF)),
          // Cached-ahead (白条) sits above the track, below the played fill.
          FractionallySizedBox(
            widthFactor: b,
            child: Container(height: 6, color: const Color(0x80FFFFFF)),
          ),
          FractionallySizedBox(
            widthFactor: p,
            child: Container(
              height: 6,
              decoration: const BoxDecoration(gradient: AppColors.barGradient),
            ),
          ),
        ],
      ),
    );
  }
}

/// Right-hand detail + controls column. Renders safely while a resource is
/// still being resolved (`currentDetail == null`).
///
/// The controls are an [_ActionGrid] of icon tiles; each one opens a floating
/// [_ActionSheet]. The old always-expanded chip lists made this column so tall
/// that half of it ran off screen on a 1080p TV.
class _SidePanel extends StatelessWidget {
  const _SidePanel({required this.panelNode, required this.onOpenAction});
  final FocusNode panelNode;
  final void Function(_PlayAction) onOpenAction;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final item = app.currentItem;
    if (item == null) return const SizedBox.shrink();
    final detail = app.currentDetail;
    final desc =
        (detail != null && detail.desc.isNotEmpty) ? detail.desc : item.desc;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          item.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 30,
            fontWeight: FontWeight.w700,
            color: AppColors.text,
            fontFamilyFallback: kFontFallback,
          ),
        ),
        if (item.en.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            item.en,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                fontSize: 15,
                color: AppColors.textDim,
                fontFamilyFallback: kFontFallback),
          ),
        ],
        const SizedBox(height: 10),
        _ScoreRow(item: item),
        if (desc.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text(
            desc,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                fontSize: 15,
                height: 1.6,
                color: Color(0xFFC5D2E6),
                fontFamilyFallback: kFontFallback),
          ),
        ],
        const _Hr(),
        // The player's Right key lands on the first tile, whatever it is.
        _ActionGrid(firstNode: panelNode, onOpen: onOpenAction),
      ],
    );
  }
}

/// The side panel's controls. One icon tile per action; the grid wraps onto
/// another row when the panel (or the fullscreen dock) is too narrow. Tiles are
/// glyph-only — the sheet each opens names the action — so the whole panel stays
/// one glance wide on a TV.
enum _PlayAction {
  sources('切换资源', Icons.swap_horiz),
  download('下载', Icons.download_rounded),
  speed('倍速', Icons.speed_rounded),
  skip('片头片尾', Icons.skip_next_rounded),
  danmaku('弹幕', Icons.subtitles_rounded);

  const _PlayAction(this.label, this.icon);

  final String label;
  final IconData icon;

  /// Sheet heading — the tile stays short (片头片尾) while the sheet is explicit.
  String get sheetTitle => this == _PlayAction.skip ? '片头片尾跳过' : label;
}

const double _kActionTile = 76;

class _ActionGrid extends StatelessWidget {
  const _ActionGrid({this.firstNode, required this.onOpen});

  final FocusNode? firstNode;
  final void Function(_PlayAction) onOpen;

  static const double _gap = 12;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final detail = app.currentDetail;
    final hasLines = detail != null && detail.playLines.length > 1;
    final actions = <_PlayAction>[
      // 线路 and 其他资源 are the same choice ("what am I watching from?"), so
      // they share one entry; offer it as soon as either has something to pick.
      if (hasLines || app.resourceOptions.isNotEmpty || app.loadingResources)
        _PlayAction.sources,
      _PlayAction.download,
      _PlayAction.speed,
      _PlayAction.skip,
      _PlayAction.danmaku,
    ];
    return Wrap(
      spacing: _gap,
      runSpacing: _gap,
      children: [
        for (var i = 0; i < actions.length; i++)
          _ActionTile(
            key: ValueKey('playAction:${actions[i].name}'),
            action: actions[i],
            focusNode: i == 0 ? firstNode : null,
            onPressed: () => onOpen(actions[i]),
          ),
      ],
    );
  }
}

/// Square icon-only tile: the glyph is the label, so nothing in the grid
/// competes with the artwork for the eye. Focus uses the app's usual glass →
/// gradient-pill language.
class _ActionTile extends StatelessWidget {
  const _ActionTile({
    super.key,
    required this.action,
    required this.onPressed,
    this.focusNode,
  });

  final _PlayAction action;
  final VoidCallback onPressed;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: action.label,
      child: Focusable(
        focusNode: focusNode,
        onPressed: onPressed,
        builder: (context, focused) {
          final base = BoxDecoration(
            color: AppColors.glass,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.hairline),
          );
          return FocusFx.scale(
            focused,
            Container(
              width: _kActionTile,
              height: _kActionTile,
              alignment: Alignment.center,
              decoration: focused ? FocusFx.pill(focused, radius: 16) : base,
              child: Icon(
                action.icon,
                size: 32,
                color: focused ? AppColors.focusInk : AppColors.accent2,
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Floating sheet for one [_PlayAction]. It carries its own [FocusScope] so
/// arrows stay inside while it is open. Back — routed through
/// [AppController.playOverlayBackInterceptor] — closes it, so there is no 关闭
/// button to tab through; the first control takes focus on open.
class _ActionSheet extends StatefulWidget {
  const _ActionSheet({required this.action});

  final _PlayAction action;

  @override
  State<_ActionSheet> createState() => _ActionSheetState();
}

class _ActionSheetState extends State<_ActionSheet> {
  final FocusScopeNode _scope = FocusScopeNode(debugLabel: 'playActionSheet');

  /// True once a leaf inside the sheet took focus. A sheet can open before it
  /// has anything to focus (切换资源 while the cross-source search runs), so
  /// [build] retries until this flips.
  bool _claimed = false;

  @override
  void initState() {
    super.initState();
    // Autofocus on a FocusScope only focuses the scope node itself, which has
    // no action of its own: OK and the arrows did nothing until a leaf was
    // focused. Move into the first control explicitly, after the frame that
    // attaches it.
    WidgetsBinding.instance.addPostFrameCallback((_) => _claimFirstFocus());
  }

  void _claimFirstFocus() {
    if (!mounted || _claimed) return;
    _scope.requestFocus();
    // False when nothing inside is focusable yet; the next build retries.
    _claimed = _scope.nextFocus();
  }

  @override
  void dispose() {
    _scope.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 切换资源 can open while the search is still running: keep claiming focus
    // as results land so the first chip becomes usable without a pointer.
    if (!_claimed) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _claimFirstFocus());
    }
    return Positioned.fill(
      child: ColoredBox(
        color: const Color(0xCC03060E),
        child: FocusScope(
          node: _scope,
          child: FocusTraversalGroup(
            child: Center(
              child: Container(
                width: 720,
                constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(context).height * 0.72),
                padding: const EdgeInsets.fromLTRB(30, 24, 30, 28),
                decoration: BoxDecoration(
                  color: AppColors.cardBg,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: AppColors.hairline),
                  boxShadow: const [
                    BoxShadow(
                        color: Color(0x99000000),
                        blurRadius: 60,
                        offset: Offset(0, 24)),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(widget.action.icon,
                            size: 22, color: AppColors.accent2),
                        const SizedBox(width: 10),
                        Text(
                          widget.action.sheetTitle,
                          style: const TextStyle(
                              fontSize: 21,
                              fontWeight: FontWeight.w700,
                              color: AppColors.text,
                              fontFamilyFallback: kFontFallback),
                        ),
                        const Spacer(),
                        const Text('返回关闭',
                            style: TextStyle(
                                fontSize: 14,
                                color: AppColors.textDim,
                                fontFamilyFallback: kFontFallback)),
                      ],
                    ),
                    const SizedBox(height: 18),
                    Flexible(
                      child: SingleChildScrollView(child: _body()),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body() {
    switch (widget.action) {
      case _PlayAction.sources:
        return const _SwitchResourceSection();
      case _PlayAction.speed:
        return const _SpeedSection(showLabel: false);
      case _PlayAction.skip:
        return const _SkipSection(showLabel: false);
      case _PlayAction.danmaku:
        return const _DanmakuSection(showLabel: false);
      case _PlayAction.download:
        // Handled by PlayScreen: 下载 opens the episode sheet directly.
        return const SizedBox.shrink();
    }
  }
}

class _ScoreRow extends StatelessWidget {
  const _ScoreRow({required this.item});
  final dynamic item;

  @override
  Widget build(BuildContext context) {
    final meta = [
      if (item.year != 0) '${item.year}',
      if ((item.genre as String).isNotEmpty) item.genre as String,
    ].join(' · ');
    return Row(
      children: [
        Text('★ ${item.score}',
            style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppColors.gold,
                fontFamilyFallback: kFontFallback)),
        if (meta.isNotEmpty) ...[
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              meta,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 15,
                  color: AppColors.textDim,
                  fontFamilyFallback: kFontFallback),
            ),
          ),
        ],
      ],
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: AppColors.text,
            fontFamilyFallback: kFontFallback),
      );
}

class _Hr extends StatelessWidget {
  const _Hr();
  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.symmetric(vertical: 18),
        child: DecoratedBox(
          decoration: BoxDecoration(color: AppColors.hairline),
          child: SizedBox(height: 1, width: double.infinity),
        ),
      );
}

/// 切换资源: cross-source candidates. Hidden until at least one is found.
/// 切换资源 sheet body: the current resource's play lines (when it exposes more
/// than one) and the same title offered by other sources, under one entry —
/// both answer the same question, "what am I watching from?".
class _SwitchResourceSection extends StatelessWidget {
  const _SwitchResourceSection();

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final detail = app.currentDetail;
    final lines = detail?.playLines ?? const <PlayLine>[];
    final opts = app.resourceOptions;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (lines.length > 1) ...[
          const _Label('线路'),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (var i = 0; i < lines.length; i++)
                SelectableChip(
                  label: lines[i].name,
                  selected: i == app.lineIndex,
                  onPressed: () => app.selectLine(i),
                ),
            ],
          ),
          const SizedBox(height: 22),
        ],
        Row(
          children: [
            const _Label('其他资源'),
            const SizedBox(width: 10),
            if (app.loadingResources)
              const Text('查找中…',
                  style: TextStyle(
                      fontSize: 13,
                      color: AppColors.textDim,
                      fontFamilyFallback: kFontFallback)),
          ],
        ),
        const SizedBox(height: 10),
        if (opts.isEmpty)
          Text(
            app.loadingResources ? '正在查找其他资源…' : '没有找到其他资源',
            style: const TextStyle(
                fontSize: 14,
                color: AppColors.textDim,
                fontFamilyFallback: kFontFallback),
          )
        else
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (var i = 0; i < opts.length; i++)
                SelectableChip(
                  label: opts[i].episodeCount > 0
                      ? '${opts[i].sourceName} · ${opts[i].episodeCount}集'
                      : opts[i].sourceName,
                  selected: opts[i].isCurrent,
                  onPressed: () => app.switchResource(opts[i]),
                ),
            ],
          ),
      ],
    );
  }
}

/// 倍速 chips. [showLabel] is false inside an [_ActionSheet].
class _SpeedSection extends StatelessWidget {
  const _SpeedSection({this.showLabel = true});
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showLabel) ...[
          const _Label('倍速'),
          const SizedBox(height: 10),
        ],
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (var i = 0; i < kPlaybackRates.length; i++)
              SelectableChip(
                label:
                    kPlaybackRates[i] == 1.0 ? '1.0x' : '${kPlaybackRates[i]}x',
                selected: app.speed == kPlaybackRates[i],
                onPressed: () => app.setSpeed(kPlaybackRates[i]),
              ),
          ],
        ),
        const SizedBox(height: 18),
      ],
    );
  }
}

/// 片头片尾跳过: on/off chip + intro/ending second steppers.
class _SkipSection extends StatelessWidget {
  const _SkipSection({this.showLabel = true});
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showLabel) ...[
          const _Label('片头片尾跳过'),
          const SizedBox(height: 10),
        ],
        SelectableChip(
          label: app.skipEnabled ? '已开启' : '已关闭',
          selected: app.skipEnabled,
          onPressed: () => app.toggleSkip(),
        ),
        if (app.skipEnabled) ...[
          const SizedBox(height: 12),
          _Stepper(
            label: '片头',
            seconds: app.introSec,
            onDelta: (d) => app.setSkip(intro: app.introSec + d),
          ),
          const SizedBox(height: 10),
          _Stepper(
            label: '片尾',
            seconds: app.endingSec,
            onDelta: (d) => app.setSkip(ending: app.endingSec + d),
          ),
        ],
        const SizedBox(height: 18),
      ],
    );
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper(
      {required this.label, required this.seconds, required this.onDelta});
  final String label;
  final int seconds;
  final void Function(int delta) onDelta;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 44,
          child: Text(label,
              style: const TextStyle(
                  fontSize: 15,
                  color: AppColors.textDim,
                  fontFamilyFallback: kFontFallback)),
        ),
        SelectableChip(
            label: '－15s', selected: false, onPressed: () => onDelta(-15)),
        const SizedBox(width: 10),
        SizedBox(
          width: 66,
          child: Text('${seconds}s',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 16,
                  color: AppColors.text,
                  fontFamilyFallback: kFontFallback)),
        ),
        const SizedBox(width: 10),
        SelectableChip(
            label: '＋15s', selected: false, onPressed: () => onDelta(15)),
      ],
    );
  }
}

/// 选集 grid for the current line. Hidden when there are no episodes (e.g.
/// still resolving or a movie with a single stream).
class _Episodes extends StatelessWidget {
  const _Episodes();

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final eps = app.currentEpisodes;
    if (eps.length <= 1) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppDims.pad, 0, AppDims.pad, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              const Text('选集',
                  style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      color: AppColors.text,
                      fontFamilyFallback: kFontFallback)),
              const SizedBox(width: 14),
              Text('共 ${eps.length} ${episodeUnit(eps)}',
                  style: const TextStyle(
                      fontSize: 15,
                      color: AppColors.textDim,
                      fontFamilyFallback: kFontFallback)),
            ],
          ),
          const SizedBox(height: 16),
          EpisodePager(
            episodes: eps,
            currentIndex: app.episodeIndex,
            onPick: app.selectEpisode,
            spacing: 12,
          ),
        ],
      ),
    );
  }
}

/// Remote-first fullscreen layer. A single [Focus] captures the D-pad:
/// OK=play/pause, ←/→=seek ∓10s (with OSD), ↑=settings menu, ↓=选集 drawer
/// (falls back to the progress OSD when there is nothing to pick), BACK=exit
/// fullscreen. While an overlay is open, arrow keys fall through so its chips
/// can be traversed.
class _FullscreenPlayer extends StatefulWidget {
  const _FullscreenPlayer();

  @override
  State<_FullscreenPlayer> createState() => _FullscreenPlayerState();
}

class _FullscreenPlayerState extends State<_FullscreenPlayer> {
  bool _menuOpen = false;
  // 选集 drawer, opened by ↓ — the highest-frequency action while watching.
  bool _episodesOpen = false;
  // 下载选集 sheet, opened from the settings menu.
  bool _downloadOpen = false;
  // Floating control sheet for one action tile, nested inside the menu.
  _PlayAction? _action;
  bool _showProgress = false;
  // Focus anchor for this layer. Overlays push focus into themselves, so when
  // one closes (and unmounts its focused chip) focus goes back here, letting
  // ←/→ seek and OK pause straight away instead of drifting onto page widgets.
  final FocusNode _rootNode = FocusNode(debugLabel: 'fullscreenPlayer');
  // First tile of the settings menu, so closing a nested sheet lands back on
  // the grid instead of nowhere.
  final FocusNode _menuFirstNode = FocusNode(debugLabel: 'fullscreenMenuFirst');
  String? _osd;
  Timer? _osdTimer;
  Timer? _progressTimer;

  /// Back handler registered on the controller so a Back press (whether it
  /// arrives as a key event or a navigation pop) is funnelled through the
  /// single, source-deduped Back path ([AppController.backFromKey] /
  /// [AppController.backFromPop]): an open menu closes first, otherwise
  /// fullscreen exits. Returns true when it consumed the Back.
  late final bool Function() _backIntercept;
  // Cached at initState: dispose() must NOT look up AppScope via context, since
  // the element is already deactivated during unmount (inherited-widget lookups
  // then throw "deactivated widget's ancestor is unsafe").
  late final AppController _app;

  @override
  void initState() {
    super.initState();
    _app = AppScope.read(context);
    _backIntercept = () {
      // A control sheet nested in the menu closes first, keeping the menu open.
      if (_action != null) {
        setState(() => _action = null);
        _menuFirstNode.requestFocus();
        return true;
      }
      if (!_menuOpen && !_episodesOpen && !_downloadOpen) return false;
      _closeOverlays();
      return true;
    };
    _app.fullscreenBackInterceptor = _backIntercept;
  }

  /// Closes whichever overlay is open and hands focus back to the player.
  void _closeOverlays() {
    setState(() {
      _menuOpen = false;
      _episodesOpen = false;
      _downloadOpen = false;
      _action = null;
    });
    _rootNode.requestFocus();
  }

  void _flashOsd(String text) {
    setState(() => _osd = text);
    _osdTimer?.cancel();
    _osdTimer = Timer(const Duration(milliseconds: 1100), () {
      if (mounted) setState(() => _osd = null);
    });
  }

  void _flashProgress() {
    setState(() => _showProgress = true);
    _progressTimer?.cancel();
    _progressTimer = Timer(const Duration(milliseconds: 2600), () {
      if (mounted) setState(() => _showProgress = false);
    });
  }

  @override
  void dispose() {
    if (_app.fullscreenBackInterceptor == _backIntercept) {
      _app.fullscreenBackInterceptor = null;
    }
    _osdTimer?.cancel();
    _progressTimer?.cancel();
    _rootNode.dispose();
    _menuFirstNode.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final app = AppScope.read(context);
    final k = event.logicalKey;

    // Back is handled globally (PopScope / shortcuts → the deduped Back path),
    // so a single press can't be double-counted here. When an overlay is open we
    // let all keys fall through so its chips can traverse / activate.
    if (_menuOpen || _episodesOpen || _downloadOpen || _action != null) {
      return KeyEventResult.ignored;
    }

    if (k == LogicalKeyboardKey.arrowLeft) {
      app.seekBy(const Duration(seconds: -10));
      _flashOsd('⏪ 10s');
      _flashProgress();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight) {
      app.seekBy(const Duration(seconds: 10));
      _flashOsd('10s ⏩');
      _flashProgress();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp) {
      setState(() {
        _episodesOpen = false;
        _action = null;
        _menuOpen = true;
      });
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown) {
      // 选集 gets ↓ because it is the most frequent in-playback action; 播放设置
      // keeps ↑. With nothing to pick (a movie, or a source still resolving)
      // fall back to the progress OSD so ↓ is never a dead key.
      if (app.currentEpisodes.length > 1) {
        setState(() {
          _menuOpen = false;
          _action = null;
          _episodesOpen = true;
        });
      } else {
        _flashProgress();
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter ||
        k == LogicalKeyboardKey.space ||
        k == LogicalKeyboardKey.gameButtonA) {
      app.player.togglePlay();
      _flashProgress();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return Focus(
      autofocus: true,
      focusNode: _rootNode,
      // The root node is a full-screen key receiver, not a navigation target.
      // Without this it also shows up as a directional-traversal candidate, and
      // because its rect spans the whole screen its CENTER is the geometrically
      // "closest" node to the left of any cell in the right half of an overlay —
      // so ← from the 选集 grid (or any menu) focused this invisible node and
      // the highlight simply vanished, dead-ending all further arrows.
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: ColoredBox(
        color: const Color(0xFF000000),
        child: Stack(
          fit: StackFit.expand,
          children: [
            const _VideoSurface(),
            const _DanmakuLayer(),
            const _StatusOverlay(),
            const _PlayStateBadge(),
            const _CacheBadge(),
            // progress / status scrim
            if (_showProgress || !app.player.value.playing)
              const _PlayerControls(),
            if (_osd != null)
              Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 26, vertical: 16),
                  decoration: BoxDecoration(
                    color: const Color(0x99000000),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    _osd!,
                    style: const TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w700,
                        color: AppColors.text,
                        fontFamilyFallback: kFontFallback),
                  ),
                ),
              ),
            if (_menuOpen)
              _FullscreenMenu(
                firstNode: _menuFirstNode,
                onClose: _closeOverlays,
                onOpenDownloads: () => setState(() {
                  _menuOpen = false;
                  _action = null;
                  _downloadOpen = true;
                }),
                onOpenAction: (a) => setState(() => _action = a),
              ),
            if (_menuOpen && _action != null) _ActionSheet(action: _action!),
            if (_episodesOpen) _EpisodeSheet(onClose: _closeOverlays),
            if (_downloadOpen) DownloadSheet(onClose: _closeOverlays),
          ],
        ),
      ),
    );
  }
}

/// Settings sheet shown in fullscreen when ↑ is pressed. It slides up from the
/// bottom edge like the 选集 drawer (a right-docked panel left the tiles
/// squeezed into the corner), and mirrors the page's side panel: the same
/// [_ActionGrid], with each tile opening the same [_ActionSheet] over the video.
class _FullscreenMenu extends StatefulWidget {
  const _FullscreenMenu({
    required this.firstNode,
    required this.onClose,
    required this.onOpenDownloads,
    required this.onOpenAction,
  });
  final FocusNode firstNode;
  final VoidCallback onClose;
  final VoidCallback onOpenDownloads;
  final void Function(_PlayAction) onOpenAction;

  @override
  State<_FullscreenMenu> createState() => _FullscreenMenuState();
}

class _FullscreenMenuState extends State<_FullscreenMenu> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.firstNode.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.bottomCenter,
      // Slide up from the bottom edge, matching the 选集 drawer. The sheet is
      // only inserted while open, so animating the entry (translate 1 → 0) is
      // all it takes; closing unmounts it.
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 1, end: 0),
        duration: const Duration(milliseconds: 240),
        curve: kEase,
        builder: (context, t, child) => FractionalTranslation(
          translation: Offset(0, t),
          child: child,
        ),
        child: Container(
          width: double.infinity,
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.6,
          ),
          padding: const EdgeInsets.fromLTRB(AppDims.pad, 26, AppDims.pad, 34),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [Color(0xFA04070E), Color(0xF2070C18)],
            ),
            borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text('播放设置',
                        style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w700,
                            color: AppColors.text,
                            fontFamilyFallback: kFontFallback)),
                    SizedBox(width: 14),
                    Text('上键呼出 · 下键选集 · 返回关闭',
                        style: TextStyle(
                            fontSize: 14,
                            color: AppColors.textDim,
                            fontFamilyFallback: kFontFallback)),
                  ],
                ),
                const SizedBox(height: 20),
                _ActionGrid(
                  firstNode: widget.firstNode,
                  onOpen: (action) {
                    if (action == _PlayAction.download) {
                      widget.onOpenDownloads();
                    } else {
                      widget.onOpenAction(action);
                    }
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 选集 drawer, opened by ↓ in fullscreen. It slides up from the bottom edge
/// (instead of docking left/right like [_FullscreenMenu]) because the grid is
/// wide and the eye should stay on the video right above it.
///
/// The top row carries a 播放下一集 shortcut. It is shown only while
/// [AppController.hasNextEpisode] holds — a movie, a single-episode source and
/// the last episode of a series all hide it, so the button never offers
/// something that cannot play. It takes focus on open, making "↓ then OK" the
/// two-press way to continue watching.
class _EpisodeSheet extends StatefulWidget {
  const _EpisodeSheet({required this.onClose});
  final VoidCallback onClose;

  @override
  State<_EpisodeSheet> createState() => _EpisodeSheetState();
}

class _EpisodeSheetState extends State<_EpisodeSheet> {
  final FocusNode _nextNode = FocusNode(debugLabel: 'episodeSheetNext');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (AppScope.read(context).hasNextEpisode) {
        _nextNode.requestFocus();
      } else {
        // No shortcut: push focus into the grid (same trick as the settings
        // panel) so arrows operate the sheet rather than the page behind it.
        FocusScope.of(context).nextFocus();
      }
    });
  }

  @override
  void dispose() {
    _nextNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final eps = app.currentEpisodes;
    final unit = episodeUnit(eps);
    final hasNext = app.hasNextEpisode;
    final nextIndex = app.episodeIndex + 1;
    // "第 6 集" already says it is the next one; only sources that send a real
    // episode name get the extra text, so the label never reads 下一集 · 第6集.
    final nextLabel = hasNext
        ? episodeLabel(eps[nextIndex].title, nextIndex, unit: unit)
        : '';
    final nextHint = !hasNext
        ? ''
        : nextLabel == '第 ${nextIndex + 1} $unit'
            ? '下一集'
            : '下一集 · $nextLabel';

    return Align(
      alignment: Alignment.bottomCenter,
      // One-shot slide-up: the drawer is inserted only while open, so animating
      // the entry (translate 1 → 0) is enough; closing just unmounts it.
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 1, end: 0),
        duration: const Duration(milliseconds: 240),
        curve: kEase,
        builder: (context, t, child) => FractionalTranslation(
          translation: Offset(0, t),
          child: child,
        ),
        child: Container(
          width: double.infinity,
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.68,
          ),
          padding: const EdgeInsets.fromLTRB(AppDims.pad, 26, AppDims.pad, 34),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [Color(0xFA04070E), Color(0xF2070C18)],
            ),
            borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Text('选集',
                        style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w700,
                            color: AppColors.text,
                            fontFamilyFallback: kFontFallback)),
                    const SizedBox(width: 14),
                    Text('共 ${eps.length} $unit',
                        style: const TextStyle(
                            fontSize: 15,
                            color: AppColors.textDim,
                            fontFamilyFallback: kFontFallback)),
                    const Spacer(),
                    if (hasNext) ...[
                      Flexible(
                        child: Text(
                          nextHint,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.right,
                          style: const TextStyle(
                              fontSize: 14,
                              color: AppColors.textDim,
                              fontFamilyFallback: kFontFallback),
                        ),
                      ),
                      const SizedBox(width: 14),
                      SizedBox(
                        width: 220,
                        child: ActionButton(
                          label: '▶ 播放下一集',
                          primary: true,
                          focusNode: _nextNode,
                          onPressed: () {
                            widget.onClose();
                            app.nextEpisode();
                          },
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 18),
                EpisodePager(
                  episodes: eps,
                  currentIndex: app.episodeIndex,
                  onPick: (i) {
                    widget.onClose();
                    app.selectEpisode(i);
                  },
                  spacing: 12,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The danmaku render layer, wired to the shared player + [DanmakuController].
/// Paints inert (nothing) while disabled or empty, so it's safe in every Stack.
class _DanmakuLayer extends StatelessWidget {
  const _DanmakuLayer();

  @override
  Widget build(BuildContext context) {
    final app = AppScope.read(context);
    return DanmakuOverlay(player: app.player, danmaku: app.danmaku);
  }
}

// Discrete TV-friendly danmaku presets.
const _kDanmakuOpacities = <double>[0.4, 0.7, 1.0];
const _kDanmakuFontSizes = <double>[18, 22, 26];
const _kDanmakuSpeeds = <double>[12, 9, 6]; // scrollSeconds: 慢 / 中 / 快
const _kDanmakuAreas = <double>[0.25, 0.5, 1.0];

/// 弹幕 controls: master switch + manual match, and (when on) opacity / size /
/// speed / area presets. Listens to [DanmakuController] directly so config and
/// match-status changes repaint without an app-wide notify.
///
/// [showLabel] is false inside an [_ActionSheet]: the header already says
/// 弹幕, so the section only keeps the active host / status line.
class _DanmakuSection extends StatelessWidget {
  const _DanmakuSection({this.showLabel = true});
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final d = app.danmaku;
    return ListenableBuilder(
      listenable: d,
      builder: (context, _) {
        final cfg = d.config;
        final host = d.activeHost?.label;
        final status = d.statusText;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showLabel)
              Row(
                children: [
                  const _Label('弹幕'),
                  if (host != null) ...[
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text('· $host',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 13,
                              color: AppColors.textDim,
                              fontFamilyFallback: kFontFallback)),
                    ),
                  ],
                  const SizedBox(width: 10),
                  if (status != null)
                    Flexible(
                      child: Text(
                        status,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 13,
                            color: AppColors.textDim,
                            fontFamilyFallback: kFontFallback),
                      ),
                    ),
                ],
              )
            else if (host != null || status != null)
              Text(
                [if (host != null) host, if (status != null) status]
                    .join(' · '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.textDim,
                    fontFamilyFallback: kFontFallback),
              ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                SelectableChip(
                  label: cfg.enabled ? '已开启' : '已关闭',
                  selected: cfg.enabled,
                  onPressed: () => app.setDanmakuEnabled(!cfg.enabled),
                ),
                SelectableChip(
                  label: '手动匹配',
                  selected: false,
                  onPressed: () => _manualMatchDanmaku(context, app),
                ),
              ],
            ),
            if (cfg.enabled) ...[
              const SizedBox(height: 14),
              _ChipRow(label: '透明度', children: [
                for (final o in _kDanmakuOpacities)
                  SelectableChip(
                    label: '${(o * 100).round()}%',
                    selected: (cfg.opacity - o).abs() < 0.01,
                    onPressed: () => d.setOpacity(o),
                  ),
              ]),
              const SizedBox(height: 12),
              _ChipRow(label: '字号', children: [
                for (final f in _kDanmakuFontSizes)
                  SelectableChip(
                    label: f == 18 ? '小' : (f == 22 ? '中' : '大'),
                    selected: cfg.fontSize == f,
                    onPressed: () => d.setFontSize(f),
                  ),
              ]),
              const SizedBox(height: 12),
              _ChipRow(label: '速度', children: [
                for (var i = 0; i < _kDanmakuSpeeds.length; i++)
                  SelectableChip(
                    label: const ['慢', '中', '快'][i],
                    selected: cfg.scrollSeconds == _kDanmakuSpeeds[i],
                    onPressed: () => d.setScrollSeconds(_kDanmakuSpeeds[i]),
                  ),
              ]),
              const SizedBox(height: 12),
              _ChipRow(label: '区域', children: [
                for (final a in _kDanmakuAreas)
                  SelectableChip(
                    label: a <= 0.25 ? '1/4屏' : (a <= 0.5 ? '半屏' : '满屏'),
                    selected: (cfg.area - a).abs() < 0.01,
                    onPressed: () => d.setArea(a),
                  ),
              ]),
            ],
            const SizedBox(height: 18),
          ],
        );
      },
    );
  }
}

/// A labelled row of preset chips used by [_DanmakuSection].
class _ChipRow extends StatelessWidget {
  const _ChipRow({required this.label, required this.children});
  final String label;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label,
            style: const TextStyle(
                fontSize: 14,
                color: AppColors.textDim,
                fontFamilyFallback: kFontFallback)),
        const SizedBox(height: 8),
        Wrap(spacing: 10, runSpacing: 10, children: children),
      ],
    );
  }
}

/// Manual danmaku match: prompt for a keyword, run the search, then let the user
/// pick a candidate. Best-effort — a miss just toasts and changes nothing.
Future<void> _manualMatchDanmaku(
    BuildContext context, AppController app) async {
  final kw = await showOnScreenKeyboard(
    context,
    title: '手动匹配弹幕',
    initial: app.danmaku.lastSearchName,
    hint: '输入剧名，如 三体 S01E01',
  );
  if (kw == null || kw.trim().isEmpty) return;
  await app.searchDanmaku(kw);
  if (!context.mounted) return;
  final matches = app.danmaku.matches;
  if (matches.isEmpty) {
    // statusText carries the real reason (timeout / HTTP error / no match).
    app.showToast(app.danmaku.statusText ?? '未找到匹配的弹幕');
    return;
  }
  await showDialog<void>(
    context: context,
    barrierColor: const Color(0xCC03060E),
    builder: (_) => _DanmakuMatchDialog(app: app, matches: matches),
  );
}

/// Modal list of manual-match candidates; picking one loads its comments.
class _DanmakuMatchDialog extends StatelessWidget {
  const _DanmakuMatchDialog({required this.app, required this.matches});
  final AppController app;
  final List<DanmakuMatch> matches;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Material(
        type: MaterialType.transparency,
        child: Container(
          width: 560,
          constraints: const BoxConstraints(maxHeight: 560),
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color: AppColors.cardBg,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppColors.hairline),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('选择弹幕来源',
                  style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: AppColors.text,
                      fontFamilyFallback: kFontFallback)),
              const SizedBox(height: 16),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var i = 0; i < matches.length; i++)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: _MatchTile(
                            label: matches[i].label.isEmpty
                                ? '匹配 ${i + 1}'
                                : matches[i].label,
                            autofocus: i == 0,
                            onPressed: () {
                              app.pickDanmakuMatch(matches[i]);
                              Navigator.of(context).pop();
                            },
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MatchTile extends StatelessWidget {
  const _MatchTile(
      {required this.label, required this.onPressed, this.autofocus = false});
  final String label;
  final VoidCallback onPressed;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return Focusable(
      autofocus: autofocus,
      onPressed: onPressed,
      builder: (context, focused) {
        return AnimatedContainer(
          duration: kFocusDur,
          curve: kEase,
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: focused ? AppColors.accent2 : const Color(0x14FFFFFF),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: focused ? AppColors.accent2 : AppColors.hairline),
          ),
          child: Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 16,
              color: focused ? const Color(0xFF03060E) : AppColors.text,
              fontFamilyFallback: kFontFallback,
            ),
          ),
        );
      },
    );
  }
}
