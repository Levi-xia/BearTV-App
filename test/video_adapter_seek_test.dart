import 'dart:async';

import 'package:bear_tv/player/video_adapter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';

class _Player extends VideoPlayerController {
  _Player() : super.networkUrl(Uri.parse('https://example.test/video'));

  final targets = <Duration>[];
  final gates = <Completer<void>>[];
  int active = 0;
  int maxActive = 0;
  double effectiveSpeed = 1;
  bool immediateSeek = false;

  @override
  Future<void> initialize() async {
    value = const VideoPlayerValue(
      duration: Duration(hours: 1),
      position: Duration(minutes: 1),
      isInitialized: true,
    );
  }

  @override
  Future<void> setPlaybackSpeed(double speed) async {
    effectiveSpeed = speed;
    value = value.copyWith(playbackSpeed: speed);
  }

  @override
  Future<void> play() async {
    effectiveSpeed = 1; // Simulate a backend resetting rate on playback start.
    value = value.copyWith(isPlaying: true);
  }

  @override
  Future<void> seekTo(Duration position) async {
    targets.add(position);
    active++;
    if (active > maxActive) maxActive = active;
    if (!immediateSeek) {
      final gate = Completer<void>();
      gates.add(gate);
      await gate.future;
    }
    effectiveSpeed = 1; // Simulate a seek resetting native playback rate.
    active--;
    value = value.copyWith(position: position);
  }

  @override
  // No platform player is created by this fake.
  // ignore: must_call_super
  Future<void> dispose() async {}
}

void main() {
  test('rapid remote repeats only commit the final target after input settles',
      () async {
    final backend = _Player()..immediateSeek = true;
    final adapter = VideoAdapter(controllerFactory: (_) => backend);
    addTearDown(adapter.dispose);
    await adapter.open('https://example.test/video');
    Future<void>? pending;
    for (var i = 0; i < 30; i++) {
      pending = adapter
          .seekToDeferred(adapter.value.position + const Duration(seconds: 10));
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(adapter.value.position, const Duration(minutes: 6));
    expect(adapter.value.seeking, isTrue);
    expect(backend.targets, isEmpty);
    await pending;
    expect(backend.targets, [const Duration(minutes: 6)]);
    expect(adapter.value.seeking, isFalse);
    expect(backend.maxActive, 1);
  });

  test('reversing remote direction uses the preview and clamps the target',
      () async {
    final backend = _Player()..immediateSeek = true;
    final adapter = VideoAdapter(controllerFactory: (_) => backend);
    addTearDown(adapter.dispose);
    await adapter.open('https://example.test/video');
    unawaited(adapter.seekToDeferred(const Duration(hours: 2)));
    expect(adapter.value.position, const Duration(hours: 1));
    await adapter
        .seekToDeferred(adapter.value.position - const Duration(seconds: 10));
    expect(backend.targets, [const Duration(seconds: 3590)]);
  });

  test('opening another episode invalidates delayed remote seek', () async {
    final first = _Player()..immediateSeek = true;
    final second = _Player()..immediateSeek = true;
    final adapter = VideoAdapter(
        controllerFactory: (url) => url.endsWith('first') ? first : second);
    addTearDown(adapter.dispose);
    await adapter.open('https://example.test/first');
    final pending = adapter.seekToDeferred(const Duration(minutes: 30));
    await adapter.open('https://example.test/second');
    await pending;
    expect(first.targets, isEmpty);
    expect(second.targets, isEmpty);
    expect(adapter.value.position, const Duration(minutes: 1));
    expect(adapter.value.seeking, isFalse);
  });

  test('remembered rate is reapplied after play starts', () async {
    final backend = _Player();
    final adapter = VideoAdapter(controllerFactory: (_) => backend);
    await adapter.setSpeed(3);
    await adapter.open('https://example.test/video');
    await adapter.play();
    expect(backend.effectiveSpeed, 3);
    expect(adapter.value.speed, 3);
    adapter.dispose();
  });

  test('held-key targets accumulate while seeks serialize and coalesce',
      () async {
    final backend = _Player();
    final adapter = VideoAdapter(controllerFactory: (_) => backend);
    await adapter.open('https://example.test/video');
    final first =
        adapter.seekTo(adapter.value.position + const Duration(seconds: 10));
    await Future<void>.delayed(Duration.zero);
    for (var i = 0; i < 5; i++) {
      unawaited(
          adapter.seekTo(adapter.value.position + const Duration(seconds: 10)));
    }
    expect(adapter.value.position, const Duration(seconds: 120));
    expect(backend.targets, [const Duration(seconds: 70)]);
    backend.gates.first.complete();
    await Future<void>.delayed(Duration.zero);
    expect(backend.targets,
        [const Duration(seconds: 70), const Duration(seconds: 120)]);
    expect(backend.maxActive, 1);
    backend.gates.last.complete();
    await first;
    expect(adapter.value.position, const Duration(seconds: 120));
    adapter.dispose();
  });
}
