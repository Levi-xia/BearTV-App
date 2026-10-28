import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

import '../core/app_controller.dart';
import '../core/app_scope.dart';
import '../core/theme.dart';
import '../data/danmaku/danmaku_models.dart';
import '../data/nav_config.dart';
import '../player/player_controller.dart';
import '../player/video_adapter.dart';
import '../widgets/chips.dart';
import '../widgets/danmaku_overlay.dart';
import '../widgets/focusable.dart';
import '../widgets/net_image.dart';
import '../widgets/on_screen_keyboard.dart';

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _playerNode.requestFocus();
    });
  }

  @override
  void dispose() {
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

    return DecoratedBox(
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
              padding: const EdgeInsets.fromLTRB(AppDims.pad, 176, AppDims.pad, 56),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: AspectRatio(aspectRatio: 16 / 9, child: _Player(playerNode: _playerNode, panelNode: _panelNode))),
                  const SizedBox(width: 30),
                  SizedBox(width: AppDims.sideW, child: _SidePanel(panelNode: _panelNode)),
                ],
              ),
            ),
            const _Episodes(),
            const SizedBox(height: 80),
          ],
        ),
      ),
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
        if (!v.ready || raw == null || !raw.value.isInitialized) return poster();
        return ColoredBox(
          color: const Color(0xFF000000),
          child: Center(
            child: AspectRatio(
              aspectRatio: raw.value.aspectRatio == 0 ? 16 / 9 : raw.value.aspectRatio,
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
      ensureVisibleAlignment: 0.5, // keep the player clear of the top header on scroll-up
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
              const BoxShadow(color: Color(0x99000000), blurRadius: 80, offset: Offset(0, 34)),
              if (focused) const BoxShadow(color: Color(0x5900E5FF), blurRadius: 60),
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
        style: const TextStyle(fontSize: 18, height: 1.5, color: AppColors.text, fontFamilyFallback: kFontFallback),
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
                style: TextStyle(fontSize: 16, color: AppColors.textDim, fontFamilyFallback: kFontFallback)),
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
                child: const Icon(Icons.pause_rounded, size: 54, color: AppColors.text),
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
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
            ? eps[app.episodeIndex].title
            : '';
        final srcName = app.currentDetail?.sourceName ?? '';
        final speedLabel = v.speed == 1.0 ? '' : ' · ${v.speed}x';
        final label = [srcName, epTitle].where((s) => s.isNotEmpty).join(' · ') + speedLabel;
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
                style: const TextStyle(fontSize: 15, color: AppColors.textDim, fontFamilyFallback: kFontFallback),
              ),
            ),
          _ProgressBar(progress: value.progress, buffered: value.bufferedProgress),
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

const _timeStyle = TextStyle(fontSize: 14, color: AppColors.text, fontFamilyFallback: kFontFallback);

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
class _SidePanel extends StatelessWidget {
  const _SidePanel({required this.panelNode});
  final FocusNode panelNode;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final item = app.currentItem;
    if (item == null) return const SizedBox.shrink();
    final detail = app.currentDetail;
    final desc = (detail != null && detail.desc.isNotEmpty) ? detail.desc : item.desc;

    // Route the player's Right key onto the topmost control that's actually
    // rendered: 线路 → 切换资源 → 倍速 (倍速 is always present as a fallback).
    final hasLines = detail != null && detail.playLines.length > 1;
    final hasOptions = app.resourceOptions.isNotEmpty;

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
            style: const TextStyle(fontSize: 15, color: AppColors.textDim, fontFamilyFallback: kFontFallback),
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
            style: const TextStyle(fontSize: 15, height: 1.6, color: Color(0xFFC5D2E6), fontFamilyFallback: kFontFallback),
          ),
        ],
        const _Hr(),
        if (hasLines) ...[
          const _Label('线路'),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (var i = 0; i < detail.playLines.length; i++)
                SelectableChip(
                  label: detail.playLines[i].name,
                  selected: i == app.lineIndex,
                  focusNode: i == 0 ? panelNode : null,
                  onPressed: () => app.selectLine(i),
                ),
            ],
          ),
          const SizedBox(height: 18),
        ],
        _SwitchResourceSection(firstNode: (!hasLines && hasOptions) ? panelNode : null),
        _SpeedSection(firstNode: (!hasLines && !hasOptions) ? panelNode : null),
        const _SkipSection(),
        const _DanmakuSection(),
      ],
    );
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
        Text('★ ${item.score}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.gold, fontFamilyFallback: kFontFallback)),
        if (meta.isNotEmpty) ...[
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              meta,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 15, color: AppColors.textDim, fontFamilyFallback: kFontFallback),
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
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.text, fontFamilyFallback: kFontFallback),
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
class _SwitchResourceSection extends StatelessWidget {
  const _SwitchResourceSection({this.firstNode});
  final FocusNode? firstNode;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final opts = app.resourceOptions;
    if (opts.isEmpty) {
      if (app.loadingResources) {
        return const Padding(
          padding: EdgeInsets.only(bottom: 18),
          child: Text('正在查找其他资源…',
              style: TextStyle(fontSize: 14, color: AppColors.textDim, fontFamilyFallback: kFontFallback)),
        );
      }
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            const _Label('切换资源'),
            const SizedBox(width: 10),
            if (app.loadingResources)
              const Text('查找中…', style: TextStyle(fontSize: 13, color: AppColors.textDim, fontFamilyFallback: kFontFallback)),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (var i = 0; i < opts.length; i++)
              SelectableChip(
                label: opts[i].episodeCount > 0 ? '${opts[i].sourceName} · ${opts[i].episodeCount}集' : opts[i].sourceName,
                selected: opts[i].isCurrent,
                focusNode: i == 0 ? firstNode : null,
                onPressed: () => app.switchResource(opts[i]),
              ),
          ],
        ),
        const SizedBox(height: 18),
      ],
    );
  }
}

/// 倍速 chips.
class _SpeedSection extends StatelessWidget {
  const _SpeedSection({this.firstNode});
  final FocusNode? firstNode;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const _Label('倍速'),
        const SizedBox(height: 10),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (var i = 0; i < kPlaybackRates.length; i++)
              SelectableChip(
                label: kPlaybackRates[i] == 1.0 ? '1.0x' : '${kPlaybackRates[i]}x',
                selected: app.speed == kPlaybackRates[i],
                focusNode: i == 0 ? firstNode : null,
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
  const _SkipSection();

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const _Label('片头片尾跳过'),
        const SizedBox(height: 10),
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
  const _Stepper({required this.label, required this.seconds, required this.onDelta});
  final String label;
  final int seconds;
  final void Function(int delta) onDelta;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 44,
          child: Text(label, style: const TextStyle(fontSize: 15, color: AppColors.textDim, fontFamilyFallback: kFontFallback)),
        ),
        SelectableChip(label: '－15s', selected: false, onPressed: () => onDelta(-15)),
        const SizedBox(width: 10),
        SizedBox(
          width: 66,
          child: Text('${seconds}s',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, color: AppColors.text, fontFamilyFallback: kFontFallback)),
        ),
        const SizedBox(width: 10),
        SelectableChip(label: '＋15s', selected: false, onPressed: () => onDelta(15)),
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
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: AppColors.text, fontFamilyFallback: kFontFallback)),
              const SizedBox(width: 14),
              Text('共 ${eps.length} 集',
                  style: const TextStyle(fontSize: 15, color: AppColors.textDim, fontFamilyFallback: kFontFallback)),
            ],
          ),
          const SizedBox(height: 16),
          _EpisodePager(
            count: eps.length,
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
/// OK=play/pause, ←/→=seek ∓10s (with OSD), ↑=settings menu, ↓=show progress,
/// BACK=exit fullscreen. While the menu is open, arrow keys fall through so the
/// menu chips can be traversed.
class _FullscreenPlayer extends StatefulWidget {
  const _FullscreenPlayer();

  @override
  State<_FullscreenPlayer> createState() => _FullscreenPlayerState();
}

class _FullscreenPlayerState extends State<_FullscreenPlayer> {
  bool _menuOpen = false;
  bool _showProgress = false;
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
      if (_menuOpen) {
        setState(() => _menuOpen = false);
        return true;
      }
      return false;
    };
    _app.fullscreenBackInterceptor = _backIntercept;
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
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final app = AppScope.read(context);
    final k = event.logicalKey;

    // Back is handled globally (PopScope / shortcuts → the deduped Back path),
    // so a single press can't be double-counted here. When the menu is open we let
    // all keys fall through so its chips can traverse / activate.
    if (_menuOpen) return KeyEventResult.ignored;

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
      setState(() => _menuOpen = true);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown) {
      _flashProgress();
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
            // progress / status scrim
            if (_showProgress || !app.player.value.playing)
              const _PlayerControls(),
            if (_osd != null)
              Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 16),
                  decoration: BoxDecoration(
                    color: const Color(0x99000000),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    _osd!,
                    style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: AppColors.text, fontFamilyFallback: kFontFallback),
                  ),
                ),
              ),
            if (_menuOpen) _FullscreenMenu(onClose: () => setState(() => _menuOpen = false)),
          ],
        ),
      ),
    );
  }
}
/// Right-docked settings panel shown in fullscreen when ↑ is pressed. Reuses
/// the side-panel sections; focus is pushed into it on open.
class _FullscreenMenu extends StatefulWidget {
  const _FullscreenMenu({required this.onClose});
  final VoidCallback onClose;

  @override
  State<_FullscreenMenu> createState() => _FullscreenMenuState();
}

class _FullscreenMenuState extends State<_FullscreenMenu> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) FocusScope.of(context).nextFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final detail = app.currentDetail;
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        width: 560,
        height: double.infinity,
        padding: const EdgeInsets.fromLTRB(28, 40, 28, 40),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.centerRight,
            end: Alignment.centerLeft,
            colors: [Color(0xF2060A14), Color(0xB3060A14), Color(0x00060A14)],
          ),
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('播放设置',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: AppColors.text, fontFamilyFallback: kFontFallback)),
              const SizedBox(height: 6),
              const Text('上键呼出 · 返回关闭',
                  style: TextStyle(fontSize: 14, color: AppColors.textDim, fontFamilyFallback: kFontFallback)),
              const SizedBox(height: 20),
              if (detail != null && detail.playLines.length > 1) ...[
                const _Label('线路'),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (var i = 0; i < detail.playLines.length; i++)
                      SelectableChip(
                        label: detail.playLines[i].name,
                        selected: i == app.lineIndex,
                        onPressed: () => app.selectLine(i),
                      ),
                  ],
                ),
                const SizedBox(height: 18),
              ],
              const _SwitchResourceSection(),
              const _SpeedSection(),
              const _SkipSection(),
              const _DanmakuSection(),
              const _MenuEpisodes(),
            ],
          ),
        ),
      ),
    );
  }
}
/// Compact 选集 grid used inside the fullscreen menu.
class _MenuEpisodes extends StatelessWidget {
  const _MenuEpisodes();

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final eps = app.currentEpisodes;
    if (eps.length <= 1) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _Label('选集 · 共 ${eps.length} 集'),
        const SizedBox(height: 10),
        _EpisodePager(
          count: eps.length,
          currentIndex: app.episodeIndex,
          onPick: app.selectEpisode,
          spacing: 10,
        ),
      ],
    );
  }
}

/// Number of episodes shown per page in [_EpisodePager].
const int _kEpisodesPerPage = 100;

/// D-pad-friendly, paginated 选集 grid shared by [_Episodes] (inline) and
/// [_MenuEpisodes] (fullscreen menu). Long series — 柯南 runs to thousands of
/// episodes — are both laggy and a focus hazard when every cell is built at
/// once, so episodes are split into pages of [_kEpisodesPerPage]. A
/// horizontally-scrollable row of range chips (1-100, 101-200, …) switches
/// pages and only the active page's cells are built; the selector hides
/// entirely for a single page. On open the view lands on (and scrolls the
/// selector to) the page holding the currently-playing episode.
class _EpisodePager extends StatefulWidget {
  const _EpisodePager({
    required this.count,
    required this.currentIndex,
    required this.onPick,
    required this.spacing,
  });

  final int count;
  final int currentIndex;
  final void Function(int index) onPick;
  final double spacing;

  @override
  State<_EpisodePager> createState() => _EpisodePagerState();
}

class _EpisodePagerState extends State<_EpisodePager> {
  late int _page = widget.currentIndex ~/ _kEpisodesPerPage;
  // Tracks the episode count last reflected in [_page]; a change means a new
  // show was loaded, so the view re-syncs to the current episode's page.
  late int _syncedCount = widget.count;
  // Horizontal scroller for the range chips. We drive it directly (rather than
  // Scrollable.ensureVisible) so revealing the active chip only ever moves THIS
  // row — never the enclosing vertical page / fullscreen menu scroll, which
  // used to get yanked down to 选集 on entry and steal attention from the
  // player / first menu control.
  final ScrollController _chips = ScrollController();
  final GlobalKey _viewportKey = GlobalKey();
  final GlobalKey _activeChipKey = GlobalKey();
  bool _didRevealChip = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealActiveChip());
  }

  @override
  void dispose() {
    _chips.dispose();
    super.dispose();
  }

  /// Scrolls the chip row (and only the chip row) so the active page's chip is
  /// centred — e.g. resuming 柯南 at episode 900 shows the 901-1000 chip rather
  /// than parking at 1-100. Never touches ancestor scrollables.
  void _revealActiveChip() {
    if (!mounted || _didRevealChip || !_chips.hasClients) return;
    final chipBox = _activeChipKey.currentContext?.findRenderObject() as RenderBox?;
    final viewBox = _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (chipBox == null || viewBox == null) return;
    _didRevealChip = true;
    final chipLeft = viewBox.globalToLocal(chipBox.localToGlobal(Offset.zero)).dx;
    final target = _chips.offset +
        chipLeft -
        (viewBox.size.width - chipBox.size.width) / 2;
    _chips.jumpTo(target.clamp(
        _chips.position.minScrollExtent, _chips.position.maxScrollExtent));
  }

  @override
  Widget build(BuildContext context) {
    // A new show (different episode count) resets to the current episode's page.
    if (_syncedCount != widget.count) {
      _syncedCount = widget.count;
      _page = widget.currentIndex ~/ _kEpisodesPerPage;
      _didRevealChip = false;
      WidgetsBinding.instance.addPostFrameCallback((_) => _revealActiveChip());
    }
    final pageCount = (widget.count / _kEpisodesPerPage).ceil();
    final page = _page.clamp(0, pageCount - 1);
    final start = page * _kEpisodesPerPage;
    final end = (start + _kEpisodesPerPage).clamp(0, widget.count);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (pageCount > 1) ...[
          SingleChildScrollView(
            key: _viewportKey,
            controller: _chips,
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (var p = 0; p < pageCount; p++)
                  Padding(
                    key: p == page ? _activeChipKey : null,
                    padding: EdgeInsets.only(right: widget.spacing),
                    child: SelectableChip(
                      label: _rangeLabel(p),
                      selected: p == page,
                      onPressed: () {
                        if (p != page) setState(() => _page = p);
                      },
                    ),
                  ),
              ],
            ),
          ),
          SizedBox(height: widget.spacing + 6),
        ],
        Wrap(
          spacing: widget.spacing,
          runSpacing: widget.spacing,
          children: [
            for (var i = start; i < end; i++)
              SizedBox(
                width: 150,
                child: EpisodeCell(
                  number: i + 1,
                  current: i == widget.currentIndex,
                  onPressed: () => widget.onPick(i),
                ),
              ),
          ],
        ),
      ],
    );
  }

  String _rangeLabel(int p) {
    final first = p * _kEpisodesPerPage + 1;
    final last = ((p + 1) * _kEpisodesPerPage).clamp(0, widget.count);
    return '$first-$last';
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
class _DanmakuSection extends StatelessWidget {
  const _DanmakuSection();

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final d = app.danmaku;
    return ListenableBuilder(
      listenable: d,
      builder: (context, _) {
        final cfg = d.config;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const _Label('弹幕'),
                const SizedBox(width: 10),
                if (d.statusText != null)
                  Flexible(
                    child: Text(
                      d.statusText!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, color: AppColors.textDim, fontFamilyFallback: kFontFallback),
                    ),
                  ),
              ],
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
        Text(label, style: const TextStyle(fontSize: 14, color: AppColors.textDim, fontFamilyFallback: kFontFallback)),
        const SizedBox(height: 8),
        Wrap(spacing: 10, runSpacing: 10, children: children),
      ],
    );
  }
}

/// Manual danmaku match: prompt for a keyword, run the search, then let the user
/// pick a candidate. Best-effort — a miss just toasts and changes nothing.
Future<void> _manualMatchDanmaku(BuildContext context, AppController app) async {
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
    app.showToast('未找到匹配的弹幕');
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
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: AppColors.text, fontFamilyFallback: kFontFallback)),
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
                            label: matches[i].label.isEmpty ? '匹配 ${i + 1}' : matches[i].label,
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
  const _MatchTile({required this.label, required this.onPressed, this.autofocus = false});
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
            border: Border.all(color: focused ? AppColors.accent2 : AppColors.hairline),
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
