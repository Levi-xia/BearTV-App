import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

import 'player_controller.dart';

/// Real playback backend wrapping `video_player` (Android = ExoPlayer).
///
/// Chosen for low-end TV boxes: small binary, low memory, native HLS/m3u8/mp4,
/// `setPlaybackSpeed` + `seekTo`. The underlying [VideoPlayerController] is
/// recreated per [open] and disposed promptly so we never keep a decoder
/// resident in the background.
///
/// [raw] exposes the current controller so the play screen can mount a
/// [VideoPlayer] texture; it is null until [open] initialises successfully.
class VideoAdapter extends ChangeNotifier implements PlayerController {
  VideoPlayerController? _vp;
  PlayerValue _value = const PlayerValue();
  double _speed = 1.0;
  int _openToken = 0;

  VideoPlayerController? get raw => _vp;

  @override
  PlayerValue get value => _value;

  @override
  Future<void> open(String? url, {Map<String, String>? headers}) async {
    final token = ++_openToken;
    await _disposeInner();
    _value = PlayerValue(speed: _speed); // not ready yet
    notifyListeners();
    if (url == null || url.isEmpty) return;

    final vp = VideoPlayerController.networkUrl(
      Uri.parse(url),
      httpHeaders: headers ?? const {},
    );
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

  void _onVp() => _sync();

  void _sync({bool? ready}) {
    final vp = _vp;
    if (vp == null) return;
    final v = vp.value;
    _value = _value.copyWith(
      playing: v.isPlaying,
      buffering: v.isBuffering,
      ready: ready ?? v.isInitialized,
      position: v.position,
      duration: v.duration,
      buffered: _bufferedEnd(v),
      speed: _speed,
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
  Future<void> play() async => _vp?.play();

  @override
  Future<void> pause() async => _vp?.pause();

  @override
  Future<void> togglePlay() => _value.playing ? pause() : play();

  @override
  Future<void> seekTo(Duration position) async => _vp?.seekTo(position);

  @override
  Future<void> setSpeed(double speed) async {
    _speed = speed;
    await _vp?.setPlaybackSpeed(speed);
    _sync();
  }

  Future<void> _disposeInner() async {
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
