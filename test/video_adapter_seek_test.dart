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
  Object? initializeError;
  Completer<void>? initializeGate;
  Completer<void>? disposeGate;
  bool disposed = false;
  int disposeCalls = 0;

  @override
  Future<void> initialize() async {
    await initializeGate?.future;
    if (initializeError != null) throw initializeError!;
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
  Future<void> dispose() async {
    disposeCalls++;
    await disposeGate?.future;
    disposed = true;
  }
}

void main() {
  test('controller factory receives only explicitly configured headers',
      () async {
    Map<String, String>? received;
    final adapter = VideoAdapter(controllerFactory: (_, headers) {
      received = headers;
      return _Player();
    });
    addTearDown(adapter.dispose);
    await adapter.open('https://example.test/video',
        headers: {'user-agent': 'Custom UA', 'Referer': 'https://origin.test'});
    expect(received!['user-agent'], 'Custom UA');
    expect(received!.containsKey('User-Agent'), isFalse);
    expect(received!['Referer'], 'https://origin.test');
    expect(received!.containsKey('Accept'), isFalse);
  });

  test('hung old initialization and cleanup do not block a retry', () async {
    final initializeGate = Completer<void>();
    final cleanupGate = Completer<void>();
    final old = _Player()
      ..initializeGate = initializeGate
      ..disposeGate = cleanupGate;
    final next = _Player();
    var created = 0;
    final adapter = VideoAdapter(
      controllerFactory: (_, headers) => created++ == 0 ? old : next,
      initializeTimeout: const Duration(milliseconds: 15),
      cleanupTimeout: const Duration(milliseconds: 15),
    );
    addTearDown(adapter.dispose);
    await adapter.open('https://example.test/video');
    expect(adapter.value.error, contains('超时'));
    await adapter.open('https://example.test/video');
    expect(created, 2);
    expect(adapter.value.ready, isTrue);
    expect(adapter.value.error, isNull);
    expect(old.disposeCalls, 0);
    initializeGate.complete();
    await Future<void>.delayed(Duration.zero);
    expect(old.disposeCalls, 1);
    cleanupGate.complete();
    await Future<void>.delayed(Duration.zero);
    expect(old.disposed, isTrue);
    expect(adapter.raw, same(next));
  });

  test('a slow active controller cleanup cannot permanently lock new playback',
      () async {
    final cleanupGate = Completer<void>();
    final old = _Player()..disposeGate = cleanupGate;
    final next = _Player();
    var created = 0;
    final adapter = VideoAdapter(
      controllerFactory: (_, headers) => created++ == 0 ? old : next,
      cleanupTimeout: const Duration(milliseconds: 15),
    );
    addTearDown(adapter.dispose);
    await adapter.open('https://example.test/old');
    await adapter.open('https://example.test/next');
    expect(adapter.raw, same(next));
    expect(adapter.value.ready, isTrue);
    expect(adapter.value.error, isNull);
    cleanupGate.complete();
    await Future<void>.delayed(Duration.zero);
    expect(old.disposeCalls, 1);
    expect(old.disposed, isTrue);
  });

  test('initialization failure exposes an error and retry clears it', () async {
    final bad = _Player()..initializeError = StateError('HTTP 403');
    final good = _Player();
    var attempt = 0;
    final adapter = VideoAdapter(
        controllerFactory: (_, headers) => attempt++ == 0 ? bad : good);
    addTearDown(adapter.dispose);
    await adapter.open('https://example.test/video');
    expect(adapter.value.ready, isFalse);
    expect(adapter.value.error, contains('403'));
    await Future<void>.delayed(Duration.zero);
    expect(bad.disposed, isTrue);
    await adapter.open('https://example.test/video');
    expect(adapter.value.ready, isTrue);
    expect(adapter.value.error, isNull);
  });

  test('hung initialization has a bounded timeout and late success is ignored',
      () async {
    final gate = Completer<void>();
    final backend = _Player()..initializeGate = gate;
    final adapter = VideoAdapter(
      controllerFactory: (_, headers) => backend,
      initializeTimeout: const Duration(milliseconds: 15),
    );
    addTearDown(adapter.dispose);
    await adapter.open('https://example.test/video');
    expect(adapter.value.error, contains('超时'));
    expect(adapter.value.ready, isFalse);
    gate.complete();
    await Future<void>.delayed(Duration.zero);
    expect(adapter.value.error, contains('超时'));
    expect(adapter.value.ready, isFalse);
  });

  test('a late initialization failure cannot overwrite a newer open', () async {
    final gate = Completer<void>();
    final old = _Player()
      ..initializeGate = gate
      ..initializeError = StateError('old failure');
    final next = _Player();
    final adapter = VideoAdapter(
        controllerFactory: (url, headers) => url.endsWith('old') ? old : next);
    addTearDown(adapter.dispose);
    final pending = adapter.open('https://example.test/old');
    await Future<void>.delayed(Duration.zero);
    await adapter.open('https://example.test/next');
    gate.complete();
    await pending;
    expect(adapter.value.ready, isTrue);
    expect(adapter.value.error, isNull);
    expect(adapter.raw, same(next));
  });

  test('rapid remote repeats only commit the final target after input settles',
      () async {
    final backend = _Player()..immediateSeek = true;
    final adapter = VideoAdapter(controllerFactory: (_, headers) => backend);
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
    final adapter = VideoAdapter(controllerFactory: (_, headers) => backend);
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
        controllerFactory: (url, headers) =>
            url.endsWith('first') ? first : second);
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
    final adapter = VideoAdapter(controllerFactory: (_, headers) => backend);
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
    final adapter = VideoAdapter(controllerFactory: (_, headers) => backend);
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
