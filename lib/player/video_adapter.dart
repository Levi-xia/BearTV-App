import 'dart:io';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

import 'player_controller.dart';

/// Real playback backend wrapping `video_player` (fvp/libmdk registered in main).
///
/// Chosen for low-end TV boxes: small binary, low memory, native HLS/m3u8/mp4,
/// `setPlaybackSpeed` + `seekTo`. The underlying [VideoPlayerController] is
/// recreated per [open] and disposed promptly so we never keep a decoder
/// resident in the background.
///
/// [raw] exposes the current controller so the play screen can mount a
/// [VideoPlayer] texture; it is null until [open] initialises successfully.
class VideoAdapter extends ChangeNotifier
    implements PlayerController, DeferredSeekPlayer {
  VideoAdapter({
    VideoPlayerController Function(String, Map<String, String>)?
        controllerFactory,
    this.initializeTimeout = const Duration(seconds: 45),
    this.cleanupTimeout = const Duration(seconds: 5),
  }) : _controllerFactory = controllerFactory;

  final VideoPlayerController Function(String, Map<String, String>)?
      _controllerFactory;
  final Duration initializeTimeout;
  final Duration cleanupTimeout;
  VideoPlayerController? _vp;
  VideoPlayerController? _initializing;
  final _disposals = Expando<Future<void>>();
  final _initializations = Expando<Future<void>>();
  PlayerValue _value = const PlayerValue();
  double _speed = 1.0;
  int _openToken = 0;
  String? _url;
  bool? _lastCompleted;
  String? _lastError;
  Duration? _pendingSeek;
  Duration? _seekTarget;
  Future<void>? _seekWorker;
  int _seekGeneration = 0;
  DateTime? _seekAfter;
  static const _remoteSeekDelay = Duration(milliseconds: 350);

  VideoPlayerController? get raw => _vp;

  @override
  PlayerValue get value => _value;

  @override
  Future<void> open(String? url, {Map<String, String>? headers}) async {
    final token = ++_openToken;
    _url = url;
    _lastCompleted = null;
    _lastError = null;
    await _disposeInner();
    if (token != _openToken) return;
    _value = PlayerValue(speed: _speed); // not ready yet
    notifyListeners();
    if (url == null || url.isEmpty) return;

    VideoPlayerController? vp;
    try {
      final uri = Uri.tryParse(url);
      debugPrint('[video] open token=$token scheme=${uri?.scheme} '
          'host=${uri?.host} headers=${headers?.keys.join(',') ?? ''}');
      // Preserve the backend's native HTTP defaults. A synthetic browser UA
      // changes CDN responses and also affects HLS child requests in libmdk.
      // Only forward headers explicitly configured for this source.
      vp = _controllerFor(url, headers);
      _initializing = vp;
      final initialization = vp.initialize();
      _initializations[vp] = initialization;
      await initialization.timeout(initializeTimeout);
      if (identical(_initializing, vp)) _initializing = null;
      if (token != _openToken) {
        // A newer open() superseded this one while we were initialising.
        await _disposeController(vp);
        return;
      }
      _vp = vp;
      vp.addListener(_onVp);
      await vp.setPlaybackSpeed(_speed);
      if (token != _openToken) return;
      _sync(ready: true);
    } catch (e) {
      debugPrint('[video] open failed token=$token current=$_openToken: $e');
      if (identical(_initializing, vp)) _initializing = null;
      if (vp != null && identical(_vp, vp)) {
        vp.removeListener(_onVp);
        _vp = null;
      }
      if (token == _openToken) {
        _value = PlayerValue(
          speed: _speed,
          error: e is TimeoutException
              ? '打开视频超时，请重试或切换线路'
              : '播放器打开失败：${e.toString().replaceFirst('Exception: ', '')}',
        );
        notifyListeners();
      }
      if (vp != null) {
        unawaited(_disposeController(vp).catchError((Object _) {}));
      }
    }
  }

  /// `file:` URLs (downloaded HLS / mp4) use the local-file backend; the
  /// fvp/libmdk player explicitly allows the `file` protocol for local m3u8.
  /// Everything else stays on the network backend.
  VideoPlayerController _controllerFor(
      String url, Map<String, String>? headers) {
    if (_controllerFactory != null) {
      return _controllerFactory(url, headers ?? const {});
    }
    final uri = Uri.tryParse(url);
    if (uri != null && uri.scheme == 'file') {
      return VideoPlayerController.file(File.fromUri(uri));
    }
    if (uri != null && uri.scheme.isEmpty && uri.path.startsWith('/')) {
      return VideoPlayerController.file(File(uri.path));
    }
    return VideoPlayerController.networkUrl(
      Uri.parse(url),
      httpHeaders: headers ?? const {},
    );
  }

  void _onVp() => _sync();

  void _sync({bool? ready}) {
    final vp = _vp;
    if (vp == null) return;
    final v = vp.value;
    final error = v.hasError ? v.errorDescription : null;
    if (v.isCompleted != _lastCompleted || error != _lastError) {
      debugPrint(
        '[video] url=${_url ?? ''} playing=${v.isPlaying} '
        'buffering=${v.isBuffering} positionMs=${v.position.inMilliseconds} '
        'durationMs=${v.duration.inMilliseconds} speed=$_speed '
        'completed=${v.isCompleted} error=${error ?? ''}',
      );
      _lastCompleted = v.isCompleted;
      _lastError = error;
    }
    _value = _value.copyWith(
      playing: v.isPlaying,
      buffering: v.isBuffering,
      ready: ready ?? v.isInitialized,
      position: _seekTarget ?? v.position,
      duration: v.duration,
      buffered: _bufferedEnd(v),
      speed: _speed,
      completed: _seekTarget == null && v.isCompleted,
      seeking: _seekTarget != null,
      error: error,
      clearError: true,
    );
    notifyListeners();
  }

  /// The cached-ahead point for the progress bar's 白条. Prefer the buffered
  /// range that contains the playhead; fall back to the furthest range end.
  /// Empty (not reported by the backend) → zero, so the bar just stays hidden.
  Duration _bufferedEnd(VideoPlayerValue v) {
    final ranges = v.buffered;
    if (ranges.isEmpty) return Duration.zero;
    var end = ranges.last.end;
    for (final r in ranges) {
      if (r.start <= v.position && r.end >= v.position) return r.end;
    }
    return end;
  }

  @override
  Future<void> play() async {
    final vp = _vp;
    if (vp == null) return;
    await vp.play();
    if (identical(vp, _vp)) {
      // Some Android/fvp backends restore their native rate when transitioning
      // from prepared/paused to playing. Apply the requested rate after play,
      // which is the narrow fix for "UI says 2x/3x but playback is 1x".
      await vp.setPlaybackSpeed(_speed);
      _sync();
    }
  }

  @override
  Future<void> pause() async => _vp?.pause();

  @override
  Future<void> togglePlay() => _value.playing ? pause() : play();

  @override
  Future<void> seekTo(Duration position) => _queueSeek(position, Duration.zero);

  @override
  Future<void> seekToDeferred(Duration position) =>
      _queueSeek(position, _remoteSeekDelay);

  Future<void> _queueSeek(Duration position, Duration settleDelay) {
    final vp = _vp;
    if (vp == null) return Future<void>.value();
    var target = position < Duration.zero ? Duration.zero : position;
    if (vp.value.duration > Duration.zero && target > vp.value.duration) {
      target = vp.value.duration;
    }
    if (_seekTarget == target) return _seekWorker ?? Future<void>.value();
    _pendingSeek = target;
    _seekTarget = target;
    _seekAfter = DateTime.now().add(settleDelay);
    // Publish the requested position immediately: relative key repeats must
    // accumulate from this target, not from the decoder's stale position.
    _value = _value.copyWith(position: target, completed: false, seeking: true);
    notifyListeners();
    return _seekWorker ??= _drainSeeks(vp, _seekGeneration);
  }

  Future<void> _drainSeeks(VideoPlayerController vp, int generation) async {
    // Let synchronous requests coalesce before entering the backend.
    await Future<void>.value();
    try {
      while (generation == _seekGeneration && identical(vp, _vp)) {
        final delay = _seekAfter?.difference(DateTime.now()) ?? Duration.zero;
        if (delay > Duration.zero) {
          await Future<void>.delayed(delay);
          continue; // A key repeat may have extended the quiet period.
        }
        final target = _pendingSeek;
        if (target == null) break;
        _pendingSeek = null;
        debugPrint('[video] seek submit targetMs=${target.inMilliseconds}');
        await vp.seekTo(target);
      }
    } finally {
      if (generation == _seekGeneration) {
        _pendingSeek = null;
        _seekTarget = null;
        _seekAfter = null;
        _seekWorker = null;
        _sync();
      }
    }
  }

  @override
  Future<void> setSpeed(double speed) async {
    if (!speed.isFinite || speed <= 0) {
      throw ArgumentError.value(speed, 'speed', 'Must be finite and positive');
    }
    _speed = speed;
    final vp = _vp;
    if (vp != null) await vp.setPlaybackSpeed(speed);
    _sync();
  }

  Future<void> _disposeInner() async {
    _seekGeneration++;
    _pendingSeek = null;
    _seekTarget = null;
    _seekAfter = null;
    _seekWorker = null;
    final vp = _vp;
    final initializing = _initializing;
    _vp = null;
    _initializing = null;
    if (vp != null) {
      vp.removeListener(_onVp);
    }
    if (initializing != null && !identical(initializing, vp)) {
      // An abandoned initialization must clean up when it eventually settles,
      // but must not block a retry or a different source indefinitely.
      unawaited(_disposeController(initializing).catchError((Object _) {}));
    }
    if (vp != null) {
      try {
        await _disposeController(vp).timeout(cleanupTimeout);
      } catch (error) {
        debugPrint(
            '[video] previous controller cleanup pending/failed: $error');
      }
    }
  }

  Future<void> _disposeController(VideoPlayerController controller) {
    final existing = _disposals[controller];
    if (existing != null) return existing;
    final initialization = _initializations[controller];
    final cleanup = () async {
      if (initialization != null) {
        try {
          await initialization;
        } catch (_) {
          // Failed initialization still owns resources that need disposal.
        }
      }
      await controller.dispose();
    }();
    _disposals[controller] = cleanup;
    return cleanup;
  }

  @override
  void dispose() {
    _openToken++;
    unawaited(_disposeInner().catchError((Object _) {}));
    super.dispose();
  }
}
