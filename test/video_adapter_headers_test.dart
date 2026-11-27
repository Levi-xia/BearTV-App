import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:bear_tv/player/video_adapter.dart';

class _Platform extends VideoPlayerPlatform {
  final sources = <DataSource>[];
  final disposed = <int>[];
  @override
  Future<void> init() async {}
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    sources.add(options.dataSource);
    return sources.length;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => Stream.value(VideoEvent(
      eventType: VideoEventType.initialized,
      duration: const Duration(minutes: 1)));
  @override
  Future<void> dispose(int playerId) async => disposed.add(playerId);
  @override
  Future<void> setLooping(int playerId, bool looping) async {}
  @override
  Future<void> setVolume(int playerId, double volume) async {}
  @override
  Future<void> pause(int playerId) async {}
  @override
  Future<void> play(int playerId) async {}
  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}
  @override
  Future<void> setPreventsDisplaySleepDuringVideoPlayback(
      int playerId, bool prevent) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('real networkUrl controller preserves explicitly configured headers',
      () async {
    final previous = VideoPlayerPlatform.instance;
    final platform = _Platform();
    VideoPlayerPlatform.instance = platform;
    final adapter = VideoAdapter(); // Deliberately no controllerFactory.
    addTearDown(() async {
      await adapter.open(null);
      adapter.dispose();
      VideoPlayerPlatform.instance = previous;
    });
    await adapter.open('https://cdn.test/video.m3u8',
        headers: {'Referer': 'https://origin.test/watch'});
    expect(adapter.value.ready, isTrue);
    expect(adapter.raw!.httpHeaders['Referer'], 'https://origin.test/watch');
    final source = platform.sources.single;
    expect(source.sourceType, DataSourceType.network);
    expect(source.uri, 'https://cdn.test/video.m3u8');
    expect(source.httpHeaders, {'Referer': 'https://origin.test/watch'});
  });
  for (final url in [
    'https://cdn.test/video.m3u8',
    'http://127.0.0.1:18765/cache/video.m3u8',
    'file:///tmp/cached-video.m3u8',
  ]) {
    test('default playback preserves native HTTP defaults for $url', () async {
      final previous = VideoPlayerPlatform.instance;
      final platform = _Platform();
      VideoPlayerPlatform.instance = platform;
      final adapter = VideoAdapter();
      addTearDown(() async {
        await adapter.open(null);
        adapter.dispose();
        VideoPlayerPlatform.instance = previous;
      });
      await adapter.open(url);
      expect(adapter.value.ready, isTrue);
      expect(platform.sources.single.httpHeaders, isEmpty);
      expect(
          platform.sources.single.sourceType,
          url.startsWith('file:')
              ? DataSourceType.file
              : DataSourceType.network);
    });
  }
}
