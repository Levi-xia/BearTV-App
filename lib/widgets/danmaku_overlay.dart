import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../core/danmaku_controller.dart';
import '../core/theme.dart';
import '../data/danmaku/danmaku_models.dart';
import '../player/player_controller.dart';

/// One on-screen comment. The text+shadow is pre-rasterized into a [ui.Image]
/// once at spawn (see [_Raster]); per frame the painter does a single cheap
/// `drawImageRect` blit — no glyph re-raster and, crucially, no per-frame
/// shadow blur (a MaskFilter blur is not glyph-atlas cached, so repainting it
/// 60×/s for every comment was starving the raster thread and dropping video
/// frames). [width] stays the logical text width for lane/scroll math; [imgW]/
/// [imgH] are the logical blit size (text size + padding for the shadow).
class _Flying {
  final int mode; // 0 scroll / 1 top / 2 bottom
  final double emitAnimT; // wall-clock animation second it was spawned at
  final int lane;
  final double width;
  final ui.Image img;
  final double imgW;
  final double imgH;
  _Flying(this.mode, this.emitAnimT, this.lane, this.width, this.img, this.imgW,
      this.imgH);
}

/// A cached pre-rasterized comment: the [ui.Image] plus the logical text width
/// (for lane math) and the logical image size (for the blit rect).
class _Raster {
  final ui.Image img;
  final double textW;
  final double w;
  final double h;
  const _Raster(this.img, this.textW, this.w, this.h);
}

/// GPU-friendly danmaku layer: a single [Ticker] drives one [CustomPainter]
/// that draws every active comment — no per-comment widgets. Positions are a
/// pure function of playback time, so seek / pause / speed changes are correct
/// for free (a big seek just resets the flying set and re-seeks the cursor).
class DanmakuOverlay extends StatefulWidget {
  const DanmakuOverlay({super.key, required this.player, required this.danmaku});
  final PlayerController player;
  final DanmakuController danmaku;

  @override
  State<DanmakuOverlay> createState() => _DanmakuOverlayState();
}

class _DanmakuOverlayState extends State<DanmakuOverlay>
    with SingleTickerProviderStateMixin {
  static const int _maxActive = 150; // low-end GPU budget
  static const double _topBottomSeconds = 4.0;
  static const double _gapPx = 24;
  static const int _rasterCacheLimit = 400;
  // Padding baked around each rasterized comment so the drop shadow (offset
  // (0,1), blur 1) isn't clipped by the image bounds.
  static const double _imgPad = 3.0;
  // Fraction of the player↔clock drift corrected per position update, capped
  // at a sub-perceptual step so a near-threshold drift can never hop visibly;
  // larger drift just bleeds off over several updates.
  static const double _kClockSlew = 0.1;
  static const double _kMaxSlewStep = 0.02; // seconds per update

  late final Ticker _ticker;
  final ValueNotifier<int> _repaint = ValueNotifier<int>(0);

  final List<_Flying> _active = [];
  final Map<String, _Raster> _rasterCache = {};
  // Reused blit paint; a 1:1 draw at native DPR needs no heavy filtering.
  final Paint _imgPaint = Paint()..filterQuality = FilterQuality.low;
  // Device pixel ratio the cached images were rasterized at (keeps text crisp).
  double _dpr = 1.0;
  int _cursor = 0;
  int _epoch = -1;
  DanmakuConfig? _cfg;
  Size _size = Size.zero;

  // Playback-time interpolation base (drives spawn scheduling only).
  double _baseT = 0;
  int _baseWallMs = 0;
  bool _playing = false;
  double _speed = 1.0;
  double _t = 0; // current interpolated playback second (follows video speed)

  // Scroll/display timeline. A pure wall-clock second count that advances at 1x
  // while playing (never scaled by video speed) and freezes while paused, so a
  // comment always takes exactly `scrollSeconds` real seconds to cross — no
  // matter how fast the video runs. Comments that can't get a lane are dropped.
  double _animT = 0;
  double _animWallMs = 0;
  // Wall-ms that the ticker's `elapsed == 0` maps to. The per-frame clock is
  // derived from the ticker's vsync-aligned `elapsed`, NOT DateTime.now()
  // sampled at callback entry — the latter jitters a few ms frame-to-frame
  // relative to actual frame presentation, which made scrolling danmaku judder
  // ("一顿一顿" / perceived ghosting on sample-and-hold TV panels).
  double _tickerEpochMs = 0;

  // Lane bookkeeping.
  final List<_Flying?> _scrollLane = [];
  final List<double> _topLaneUntil = [];
  final List<double> _bottomLaneUntil = [];

  @override
  void initState() {
    super.initState();
    _cfg = widget.danmaku.config;
    _epoch = widget.danmaku.epoch;
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isNotEmpty) _dpr = views.first.devicePixelRatio;
    _syncFromPlayer();
    widget.player.addListener(_onPlayer);
    widget.danmaku.addListener(_onDanmaku);
    _ticker = createTicker(_onTick);
    _maybeToggleTicker();
  }

  @override
  void dispose() {
    _ticker.dispose();
    widget.player.removeListener(_onPlayer);
    widget.danmaku.removeListener(_onDanmaku);
    _repaint.dispose();
    // Free the rasterized images promptly. Cache and active set can share
    // instances, so dedupe before disposing (double-dispose asserts in debug).
    final imgs = <ui.Image>{};
    for (final r in _rasterCache.values) {
      imgs.add(r.img);
    }
    for (final f in _active) {
      imgs.add(f.img);
    }
    for (final im in imgs) {
      im.dispose();
    }
    _rasterCache.clear();
    _active.clear();
    super.dispose();
  }

  void _onPlayer() {
    final v = widget.player.value;
    final newT = v.position.inMilliseconds / 1000.0;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    // What our smooth clock currently reads (before applying this update).
    final predicted =
        _playing ? _baseT + (nowMs - _baseWallMs) / 1000.0 * _speed : _baseT;
    final drift = newT - predicted;
    if (drift.abs() > 1.0) {
      // Non-linear jump (seek / long stall) → drop the flying set, re-seek,
      // and hard-snap the clock to the player.
      _resetActive();
      _cursor = _seekCursor(newT);
      _baseT = newT;
    } else {
      // Normal playback: the player reports coarse, jittery positions (whole
      // seconds from the mock; quantized/laggy from a real backend). Snapping
      // the anchor to that raw value every tick makes the clock hop backward
      // ~50ms each second. Instead keep it continuous and bleed off the small
      // drift gradually, so danmaku never visibly stutters or jumps back.
      _baseT = predicted + (drift * _kClockSlew).clamp(-_kMaxSlewStep, _kMaxSlewStep);
    }
    _baseWallMs = nowMs;
    _playing = v.playing;
    _speed = v.speed <= 0 ? 1.0 : v.speed;
    if (!_ticker.isActive) {
      _t = _baseT;
      _repaint.value++; // keep the frozen frame in sync while paused
    }
    _maybeToggleTicker();
  }

  void _onDanmaku() {
    final d = widget.danmaku;
    final cfgChanged = !identical(_cfg, d.config);
    // New episode (epoch bump) or a look change → rebuild the stream.
    if (d.epoch != _epoch || cfgChanged) {
      _epoch = d.epoch;
      _cfg = d.config;
      _rasterCache.clear(); // font/opacity may have changed; GC frees old images
      _resetActive();
      _cursor = _seekCursor(_t);
    }
    _maybeToggleTicker();
  }

  void _syncFromPlayer() {
    final v = widget.player.value;
    _baseT = v.position.inMilliseconds / 1000.0;
    _baseWallMs = DateTime.now().millisecondsSinceEpoch;
    _playing = v.playing;
    _speed = v.speed <= 0 ? 1.0 : v.speed;
    _t = _baseT;
    _cursor = _seekCursor(_t);
  }

  void _maybeToggleTicker() {
    final enabled =
        _cfg?.enabled == true && widget.danmaku.items.isNotEmpty;
    final shouldRun = enabled && _playing;
    if (shouldRun && !_ticker.isActive) {
      final now = DateTime.now().millisecondsSinceEpoch;
      _baseWallMs = now; // no paused-time jump
      _animWallMs = now.toDouble(); // don't fold the pause into the scroll timeline
      _tickerEpochMs = now.toDouble(); // start() resets elapsed to ~0
      _ticker.start();
    } else if (!shouldRun && _ticker.isActive) {
      _ticker.stop(); // paused → freeze the last painted frame
    }
    if (!enabled && _active.isNotEmpty) {
      _resetActive();
      _repaint.value++;
    }
  }

  /// First index in the (time-sorted) items whose time >= [t].
  int _seekCursor(double t) {
    final items = widget.danmaku.items;
    var lo = 0, hi = items.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (items[mid].time < t) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  void _resetActive() {
    _active.clear();
    for (var i = 0; i < _scrollLane.length; i++) {
      _scrollLane[i] = null;
    }
    for (var i = 0; i < _topLaneUntil.length; i++) {
      _topLaneUntil[i] = -1e9;
    }
    for (var i = 0; i < _bottomLaneUntil.length; i++) {
      _bottomLaneUntil[i] = -1e9;
    }
  }

  void _onTick(Duration elapsed) {
    final cfg = _cfg;
    if (cfg == null || !cfg.enabled) return;
    // Vsync-aligned frame time (see [_tickerEpochMs]) — uniform per frame, so
    // comments advance by an even step and don't stutter/smear.
    final nowMs = _tickerEpochMs + elapsed.inMicroseconds / 1000.0;
    _t = _playing ? _baseT + (nowMs - _baseWallMs) / 1000.0 * _speed : _baseT;
    // Scroll timeline runs at real 1x (never * _speed), so danmaku keep a
    // constant, readable speed regardless of how fast the video plays.
    if (_playing) _animT += (nowMs - _animWallMs) / 1000.0;
    _animWallMs = nowMs;

    _active.removeWhere((f) => f.mode == 0
        ? (_animT - f.emitAnimT) > cfg.scrollSeconds
        : (_animT - f.emitAnimT) > _topBottomSeconds);

    // Spawn due comments, bounded per frame so a forward jump can't flood.
    final items = widget.danmaku.items;
    var spawned = 0;
    while (_cursor < items.length &&
        items[_cursor].time <= _t &&
        _active.length < _maxActive &&
        spawned < 12) {
      final it = items[_cursor];
      _cursor++;
      if (_t - it.time > 0.6) continue; // stale, don't pop in late
      _spawn(it, cfg);
      spawned++;
    }
    _repaint.value++;
  }

  void _spawn(DanmakuItem it, DanmakuConfig cfg) {
    if (_size.width <= 0 || _size.height <= 0) return;
    final laneH = cfg.fontSize * 1.7;
    final areaH = (_size.height * cfg.area).clamp(laneH, _size.height);
    final laneCount = (areaH / laneH).floor().clamp(1, 40);
    _ensureLanes(laneCount);
    final r = _rasterFor(it, cfg);
    final w = r.textW;
    if (it.mode == 1) {
      final lane = _pickStaticLane(_topLaneUntil);
      if (lane < 0) return;
      _topLaneUntil[lane] = _animT;
      _active.add(_Flying(1, _animT, lane, w, r.img, r.w, r.h));
    } else if (it.mode == 2) {
      final lane = _pickStaticLane(_bottomLaneUntil);
      if (lane < 0) return;
      _bottomLaneUntil[lane] = _animT;
      _active.add(_Flying(2, _animT, lane, w, r.img, r.w, r.h));
    } else {
      final lane = _pickScrollLane(w, cfg);
      if (lane < 0) return; // no room without overlap → drop
      final f = _Flying(0, _animT, lane, w, r.img, r.w, r.h);
      _scrollLane[lane] = f;
      _active.add(f);
    }
  }

  void _ensureLanes(int count) {
    if (_scrollLane.length == count) return;
    _scrollLane
      ..clear()
      ..addAll(List<_Flying?>.filled(count, null));
    _topLaneUntil
      ..clear()
      ..addAll(List<double>.filled(count, -1e9));
    _bottomLaneUntil
      ..clear()
      ..addAll(List<double>.filled(count, -1e9));
  }

  /// Pick a scroll lane whose last comment's tail has cleared the right edge;
  /// -1 when every lane is still occupied (the comment is dropped).
  int _pickScrollLane(double w, DanmakuConfig cfg) {
    for (var i = 0; i < _scrollLane.length; i++) {
      final last = _scrollLane[i];
      if (last == null) return i;
      final entered =
          (_animT - last.emitAnimT) / cfg.scrollSeconds * (_size.width + last.width);
      if (entered - last.width - _gapPx >= 0) return i;
    }
    return -1;
  }

  int _pickStaticLane(List<double> until) {
    for (var i = 0; i < until.length; i++) {
      if (_animT - until[i] >= _topBottomSeconds) return i;
    }
    return -1;
  }

  _Raster _rasterFor(DanmakuItem it, DanmakuConfig cfg) {
    final key =
        '${cfg.fontSize.toInt()}|${cfg.opacity.toStringAsFixed(2)}|${it.color}|${it.text}';
    final cached = _rasterCache[key];
    if (cached != null) return cached;
    final r = (it.color >> 16) & 0xFF;
    final g = (it.color >> 8) & 0xFF;
    final b = it.color & 0xFF;
    final tp = TextPainter(
      text: TextSpan(
        text: it.text,
        style: TextStyle(
          fontSize: cfg.fontSize,
          height: 1.0,
          color: Color.fromRGBO(r, g, b, cfg.opacity.clamp(0.1, 1.0)),
          fontWeight: FontWeight.w600,
          fontFamilyFallback: kFontFallback,
          shadows: const [
            // A tight, low-blur shadow for contrast against bright video. The
            // blur is rasterized into the image ONCE here, so the per-frame
            // draw is a plain blit with no MaskFilter cost.
            Shadow(color: Color(0xCC000000), blurRadius: 1, offset: Offset(0, 1)),
          ],
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final raster = _rasterize(tp);
    if (_rasterCache.length >= _rasterCacheLimit) {
      // Drop the oldest ref; a still-flying comment keeps its own ref alive,
      // and dart:ui's image finalizer frees the native memory on GC.
      _rasterCache.remove(_rasterCache.keys.first);
    }
    _rasterCache[key] = raster;
    return raster;
  }

  /// Bake a laid-out [tp] (glyphs + shadow) into a [ui.Image] at native device
  /// resolution so the per-frame paint is a cheap 1:1 blit.
  _Raster _rasterize(TextPainter tp) {
    final dpr = _dpr <= 0 ? 1.0 : _dpr;
    final w = tp.width + _imgPad * 2;
    final h = tp.height + _imgPad * 2;
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    canvas.scale(dpr);
    tp.paint(canvas, const Offset(_imgPad, _imgPad));
    final pic = rec.endRecording();
    final img = pic.toImageSync((w * dpr).ceil(), (h * dpr).ceil());
    pic.dispose();
    return _Raster(img, tp.width, w, h);
  }

  @override
  Widget build(BuildContext context) {
    // Keep rasters crisp if the display DPR changes (rare); re-rasterize lazily.
    final dpr = MediaQuery.devicePixelRatioOf(context);
    if (dpr > 0 && dpr != _dpr) {
      _dpr = dpr;
      _rasterCache.clear();
    }
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, constraints) {
          _size = Size(constraints.maxWidth, constraints.maxHeight);
          // Isolate the per-frame danmaku repaint into its own layer, so driving
          // the ticker never marks the sibling video surface / controls layer
          // dirty — otherwise the whole play Stack re-paints 60×/s and starves
          // the raster thread, stalling video texture presentation (音画不同步).
          return RepaintBoundary(
            child: CustomPaint(size: _size, painter: _DanmakuPainter(this)),
          );
        },
      ),
    );
  }
}

/// Paints the active set; repaints are driven by the state's [_repaint] ticker
/// notifier, so [shouldRepaint] can stay false.
class _DanmakuPainter extends CustomPainter {
  _DanmakuPainter(this.s) : super(repaint: s._repaint);
  final _DanmakuOverlayState s;

  @override
  void paint(Canvas canvas, Size size) {
    final cfg = s._cfg;
    if (cfg == null || !cfg.enabled) return;
    final t = s._animT;
    final laneH = cfg.fontSize * 1.7;
    for (final f in s._active) {
      double x;
      double y;
      if (f.mode == 0) {
        final progress = (t - f.emitAnimT) / cfg.scrollSeconds;
        x = size.width - progress * (size.width + f.width);
        y = f.lane * laneH;
      } else if (f.mode == 1) {
        x = (size.width - f.width) / 2;
        y = f.lane * laneH;
      } else {
        x = (size.width - f.width) / 2;
        y = size.height - (f.lane + 1) * laneH;
      }
      final src = Rect.fromLTWH(
          0, 0, f.img.width.toDouble(), f.img.height.toDouble());
      // The glyph origin sits at (_imgPad, _imgPad) inside the image, so offset
      // the blit to keep the on-screen position identical to the old direct paint.
      final dst = Rect.fromLTWH(
          x - _DanmakuOverlayState._imgPad,
          y + 2 - _DanmakuOverlayState._imgPad,
          f.imgW,
          f.imgH);
      canvas.drawImageRect(f.img, src, dst, s._imgPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _DanmakuPainter oldDelegate) => false;
}
