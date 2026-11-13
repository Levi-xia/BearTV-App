import 'dart:async';
import 'package:flutter/foundation.dart';

/// Immutable snapshot of playback state consumed by the UI.
@immutable
class PlayerValue {
  final bool playing;
  final bool buffering;
  final bool ready; // backend initialised (texture available)
  final Duration position;
  final Duration duration;
  final Duration buffered; // how far ahead the stream is cached
  final double speed;

  const PlayerValue({
    this.playing = false,
    this.buffering = false,
    this.ready = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.buffered = Duration.zero,
    this.speed = 1.0,
  });

  double get progress => duration.inMilliseconds == 0
      ? 0
      : position.inMilliseconds / duration.inMilliseconds;

  /// Cached fraction 0..1 for the progress bar's "buffered" (白条) layer.
  double get bufferedProgress => duration.inMilliseconds == 0
      ? 0
      : buffered.inMilliseconds / duration.inMilliseconds;

  PlayerValue copyWith({
    bool? playing,
    bool? buffering,
    bool? ready,
    Duration? position,
    Duration? duration,
    Duration? buffered,
    double? speed,
  }) =>
      PlayerValue(
        playing: playing ?? this.playing,
        buffering: buffering ?? this.buffering,
        ready: ready ?? this.ready,
        position: position ?? this.position,
        duration: duration ?? this.duration,
        buffered: buffered ?? this.buffered,
        speed: speed ?? this.speed,
      );
}

/// Player boundary. A real implementation would wrap video_player (ExoPlayer)
/// or media_kit and render a texture; the UI only depends on this contract.
abstract class PlayerController extends ValueListenable<PlayerValue> {
  Future<void> open(String? url, {Map<String, String>? headers});
  Future<void> play();
  Future<void> pause();
  Future<void> togglePlay();
  Future<void> seekTo(Duration position);
  Future<void> setSpeed(double speed);
  void dispose();
}

/// Fake player: advances position on a 1s timer, matching the HTML demo
/// (starts at 12:40, total duration 01:58:00). No real decoding.
class MockPlayerController extends ChangeNotifier implements PlayerController {
  static const _total = Duration(minutes: 118); // 01:58:00 == 7080s
  PlayerValue _value = const PlayerValue(
    position: Duration(minutes: 12, seconds: 40),
    duration: _total,
  );
  Timer? _timer;

  @override
  PlayerValue get value => _value;

  void _set(PlayerValue v) {
    _value = v;
    notifyListeners();
  }

  @override
  Future<void> open(String? url, {Map<String, String>? headers}) async {
    // TODO(player): hand `url` + `headers` to the real backend and load it.
    _set(_value.copyWith(position: Duration.zero, ready: true));
  }

  @override
  Future<void> play() async {
    if (_value.playing) return;
    _set(_value.copyWith(playing: true));
    _timer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      final next = _value.position + const Duration(seconds: 1);
      _set(_value.copyWith(position: next > _total ? Duration.zero : next));
    });
  }

  @override
  Future<void> pause() async {
    _timer?.cancel();
    _timer = null;
    _set(_value.copyWith(playing: false));
  }

  @override
  Future<void> togglePlay() => _value.playing ? pause() : play();

  @override
  Future<void> seekTo(Duration position) async =>
      _set(_value.copyWith(position: position));

  @override
  Future<void> setSpeed(double speed) async =>
      _set(_value.copyWith(speed: speed));

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
