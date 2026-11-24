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
  VideoAdapter({VideoPlayerController Function(String)? controllerFactory})
      : _controllerFactory = controllerFactory;

  final VideoPlayerController Function(String)? _controllerFactory;
  VideoPlayerController? _vp;
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
    _value = PlayerValue(speed: _speed); // not ready yet
    notifyListeners();
    if (url == null || url.isEmpty) return;

    final vp = _controllerFor(url, headers);
    try {
      await vp.initialize();
      if (token != _openToken) {
        // A newer open() superseded this one while we were initialising.
        await vp.dispose();
        return;
      }
      _vp = vp;
      vp.addListener(_onVp);
      await vp.setPlaybackSpeed(_speed);
      _sync(ready: true);
    } catch (_) {
      await vp.dispose();
      if (token == _openToken) {
        _value = PlayerValue(speed: _speed); // stays not-ready → UI shows error
        notifyListeners();
      }
    }
  }

  /// `file:` URLs (downloaded HLS / mp4) use the local-file backend; the
  /// fvp/libmdk player explicitly allows the `file` protocol for local m3u8.
  /// Everything else stays on the network backend.
  VideoPlayerController _controllerFor(
      String url, Map<String, String>? headers) {
    if (_controllerFactory != null) return _controllerFactory(url);
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
    _vp = null;
    if (vp != null) {
      vp.removeListener(_onVp);
      await vp.dispose();
    }
  }

  @override
  void dispose() {
    _disposeInner();
    super.dispose();
  }
}
