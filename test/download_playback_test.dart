import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:bear_tv/core/app_controller.dart';
import 'package:bear_tv/data/downloads/download_engine.dart';
import 'package:bear_tv/data/downloads/download_manager.dart';
import 'package:bear_tv/data/downloads/download_models.dart';
import 'package:bear_tv/data/downloads/download_storage.dart';
import 'package:bear_tv/data/downloads/downloads_store.dart';
import 'package:bear_tv/data/history_store.dart';
import 'package:bear_tv/data/kv_store.dart';
import 'package:bear_tv/data/models.dart';
import 'package:bear_tv/data/settings_store.dart';
import 'package:bear_tv/data/vod/cms_models.dart';
import 'package:bear_tv/data/vod/vod_repository.dart';
import 'package:bear_tv/player/player_controller.dart';

/// [VodRepository] with one canned detail, no network.
class _FakeVod extends VodRepository {
  @override
  Future<VodDetail?> detail(CmsSite site, String vodId) async => _detail;

  @override
  Future<VodDetail?> resolveByTitle(String title, List<CmsSite> sites) async =>
      _detail;

  @override
  Future<List<ResourceOption>> loadResourceOptions(
    String title,
    List<CmsSite> sites, {
    VodDetail? current,
  }) async =>
      const [];
}

/// A repository that can never answer — offline, or the source is gone.
class _OfflineVod extends VodRepository {
  @override
  Future<VodDetail?> detail(CmsSite site, String vodId) async => null;

  @override
  Future<VodDetail?> resolveByTitle(String title, List<CmsSite> sites) async =>
      null;

  @override
  Future<List<ResourceOption>> loadResourceOptions(
    String title,
    List<CmsSite> sites, {
    VodDetail? current,
  }) async =>
      const [];
}

/// Records every URL handed to the player and reports ready immediately —
/// unless the URL contains [failPattern], which simulates a transport the
/// player can't open.
class _RecordingPlayer extends ChangeNotifier implements PlayerController {
  final List<String> opened = [];
  String? failPattern;
  PlayerValue _value = const PlayerValue();

  @override
  PlayerValue get value => _value;

  void _set(PlayerValue v) {
    _value = v;
    notifyListeners();
  }

  @override
  Future<void> open(String? url, {Map<String, String>? headers}) async {
    final target = url ?? '';
    opened.add(target);
    final fails = failPattern != null && target.contains(failPattern!);
    _set(fails
        ? const PlayerValue()
        : PlayerValue(
            ready: true,
            // A partial playlist only contains the downloaded prefix.
            duration: target.contains('partial.m3u8')
                ? const Duration(minutes: 5)
                : const Duration(minutes: 45),
          ));
  }

  @override
  Future<void> seekTo(Duration position) async =>
      _set(_value.copyWith(position: position));

  @override
  Future<void> play() async => _set(_value.copyWith(playing: true));

  @override
  Future<void> pause() async => _set(_value.copyWith(playing: false));

  @override
  Future<void> togglePlay() async {}

  @override
  Future<void> setSpeed(double speed) async =>
      _set(_value.copyWith(speed: speed));
}

const _site = CmsSite(
  id: 'src1',
  name: '源一',
  api: 'https://src1.example/api.php/provide/vod',
);

const _item = VodItem(
  id: 7,
  mediaType: 'tv',
  title: '测试剧',
  en: '',
  genre: '剧情',
  desc: '',
  year: 2024,
  score: '8.0',
  ep: 3,
  hd: 'HD',
  neu: false,
  bgUrl: '',
  cardUrl: '',
  posterUrl: '',
);

const _detail = VodDetail(
  sourceId: 'src1',
  sourceName: '源一',
  vodId: 'vod1',
  title: '测试剧',
  playLines: [
    PlayLine(name: '线路1', episodes: [
      Episode(title: '第1集', url: 'https://cdn.test/1/ep0.m3u8'),
      Episode(title: '第2集', url: 'https://cdn.test/1/ep1.m3u8'),
      Episode(title: '第3集', url: 'https://cdn.test/1/ep2.m3u8'),
    ]),
  ],
);

/// Writes the entry file and completes at once.
class _InstantEngine implements DownloadEngine {
  _InstantEngine(this.storage);

  final DownloadStorage storage;

  @override
  Future<DownloadResult> run(
    DownloadTask task,
    DownloadStorage ignored, {
    required DownloadCancelToken cancel,
    required void Function(DownloadProgress) onProgress,
  }) async {
    final dir = await storage.ensureTaskDir(task);
    File('${dir!.path}/index.m3u8')
        .writeAsStringSync('#EXTM3U\n#EXT-X-ENDLIST\n');
    onProgress(const DownloadProgress(
        doneSegments: 2,
        totalSegments: 2,
        receivedBytes: 512,
        totalBytes: 512));
    return const DownloadResult(
      relativePath: 'index.m3u8',
      isHls: true,
      bytes: 512,
      durationMs: 1000,
      totalSegments: 2,
    );
  }

  @override
  void dispose() {}
}

/// Engine that keeps its task running: it publishes a `partial.m3u8` and
/// reports a growing playable prefix, so the controller can play from disk
/// while the episode is still downloading.
class _ProgressiveEngine implements DownloadEngine {
  _ProgressiveEngine(this.storage);

  final DownloadStorage storage;
  final Map<String, DownloadTask> _tasks = {};
  final Map<String, void Function(DownloadProgress)> _sinks = {};
  final Map<String, Completer<DownloadResult>> _pending = {};

  static const int totalMs = 45 * 60 * 1000;

  @override
  Future<DownloadResult> run(
    DownloadTask task,
    DownloadStorage ignored, {
    required DownloadCancelToken cancel,
    required void Function(DownloadProgress) onProgress,
  }) async {
    final dir = await storage.ensureTaskDir(task);
    File('${dir!.path}/partial.m3u8')
        .writeAsStringSync('#EXTM3U\n#EXT-X-ENDLIST\n');
    _tasks[task.id] = task;
    _sinks[task.id] = onProgress;
    onProgress(const DownloadProgress(
      doneSegments: 1,
      totalSegments: 20,
      receivedBytes: 10,
      totalBytes: 100,
      playableMs: 300000,
      totalMs: totalMs,
    ));
    final completer = Completer<DownloadResult>();
    _pending[task.id] = completer;
    return completer.future;
  }

  /// Simulates the prefix growing while the player is watching.
  void report(String id, int playableMs) => _sinks[id]!(DownloadProgress(
        doneSegments: 5,
        totalSegments: 20,
        receivedBytes: 50,
        totalBytes: 100,
        playableMs: playableMs,
        totalMs: totalMs,
      ));

  /// Finishes the download: writes the full playlist and completes the task.
  Future<void> finish(String id) async {
    final task = _tasks[id]!;
    final dir = await storage.ensureTaskDir(task);
    File('${dir!.path}/index.m3u8')
        .writeAsStringSync('#EXTM3U\n#EXT-X-ENDLIST\n');
    _pending.remove(id)!.complete(const DownloadResult(
      relativePath: 'index.m3u8',
      isHls: true,
      bytes: 100,
      durationMs: totalMs,
      totalSegments: 20,
    ));
  }

  @override
  void dispose() {
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(const DownloadCancelled());
    }
    _pending.clear();
  }
}

void main() {
  late Directory temp;
  late DownloadStorage storage;
  late DownloadManager manager;
  late _RecordingPlayer player;
  late AppController c;
  _ProgressiveEngine? progressiveEngine;

  /// Seed one cached episode, then build a controller parked where history
  /// says the user left off (episode index 1, 2:00).
  /// Polls until [condition] holds; the download engines in these tests settle
  /// asynchronously, so fixed delays are fragile.
  Future<void> waitUntil(bool Function() condition) async {
    for (var i = 0; i < 400 && !condition(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  Future<void> setUpController({
    required List<int> cachedEpisodes,
    int recordedEpisode = 1,
    bool withHistory = true,
    bool progressive = false,
    VodRepository? vod,
  }) async {
    temp = Directory.systemTemp.createTempSync('bear_dl_play_');
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    storage = DownloadStorage(root: temp);
    progressiveEngine = progressive ? _ProgressiveEngine(storage) : null;
    manager = DownloadManager(
      store: DownloadsStore(persistence: MemoryDownloadPersistence()),
      storage: storage,
      engine: progressiveEngine ?? _InstantEngine(storage),
    );
    player = _RecordingPlayer();
    c = AppController(
      settings:
          SettingsStore(seedDefaultKey: false, store: MemoryKeyValueStore()),
      history: HistoryStore(),
      vod: vod ?? _FakeVod(),
      player: player,
      downloads: manager,
    );
    addTearDown(c.dispose);

    // App init performs real IO (Hive fallback + downloads storage).
    await c.init();
    await c.settings.setCmsSites([_site]);
    await c.settings.setSelectedSourceIds(['src1']);

    if (cachedEpisodes.isNotEmpty) {
      await manager.enqueue(DownloadRequest(
        item: _item,
        detail: _detail,
        lineIndex: 0,
        episodeIndices: cachedEpisodes,
      ));
      if (progressive) {
        await waitUntil(() => manager.activeTasks.isNotEmpty &&
            manager.activeTasks.first.playableMs > 0);
      } else {
        for (var i = 0; i < 200 && manager.activeCount > 0; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      }
    }

    if (withHistory) {
      c.history.put(HistoryEntry(
        item: _item,
        sourceId: 'src1',
        sourceName: '源一',
        vodId: 'vod1',
        episodeIndex: recordedEpisode,
        positionMs: 120000,
        durationMs: 1800000,
        episodeTitle: _detail.playLines[0].episodes[recordedEpisode].title,
        episodeUrl: _detail.playLines[0].episodes[recordedEpisode].url,
      ));
    }
  }

  DownloadTask completed(int episodeIndex) =>
      manager.completedTasks.firstWhere((t) => t.episodeIndex == episodeIndex);

  test('a cached recorded episode plays from the local file', () async {
    await setUpController(cachedEpisodes: [0, 1]);

    await c.openTitle(_item);

    expect(c.page, AppPage.play);
    expect(c.episodeIndex, 1);
    expect(c.playingFromCache, isTrue);
    expect(player.opened.last, startsWith('http://127.0.0.1:'));
    expect(player.opened.last, endsWith('index.m3u8'));
    // Progress was restored from history.
    expect(c.history.entryFor(_item.key)!.positionMs, 120000);
  });

  test('the cached episode is actually served over the loopback transport',
      () async {
    await setUpController(cachedEpisodes: [0, 1]);
    await c.openTitle(_item);

    final response = await http.get(Uri.parse(player.opened.last));

    expect(response.statusCode, 200);
    expect(utf8.decode(response.bodyBytes), contains('#EXTM3U'));
  });

  test('a broken loopback transport falls back to file:// before going online',
      () async {
    await setUpController(cachedEpisodes: [0, 1]);
    player.failPattern = '127.0.0.1';

    await c.openTitle(_item);

    expect(c.playingFromCache, isTrue);
    expect(player.opened.where((u) => u.startsWith('file://')), isNotEmpty);
    expect(player.opened.last, startsWith('file://'));
    expect(player.opened.any((u) => u.startsWith('https://')), isFalse);
  });

  test('deleting the cache then entering from history streams the resource',
      () async {
    await setUpController(cachedEpisodes: [0, 1]);
    await c.openTitle(_item);
    expect(c.playingFromCache, isTrue);
    final local = player.opened.last;

    c.backFromKey();
    await c.deleteDownload(completed(1));
    expect(manager.completedTasks.any((t) => t.episodeIndex == 1), isFalse);

    await c.openTitle(_item);

    expect(c.page, AppPage.play);
    expect(c.playingFromCache, isFalse);
    expect(player.opened.last, isNot(local));
    expect(player.opened.last, 'https://cdn.test/1/ep1.m3u8');
    expect(c.currentDetail!.sourceId, 'src1');
    expect(c.episodeIndex, 1);
  });

  test(
      'a recorded episode without a cache streams instead of switching episode',
      () async {
    // Only episode 0 is cached; history points at episode 1.
    await setUpController(cachedEpisodes: [0]);

    await c.openTitle(_item);

    expect(c.playingFromCache, isFalse);
    expect(c.episodeIndex, 1);
    expect(player.opened.last, 'https://cdn.test/1/ep1.m3u8');
    expect(c.currentDetail!.sourceId, 'src1');
  });

  test('deleting the episode being played falls back online at the same spot',
      () async {
    await setUpController(cachedEpisodes: [1], withHistory: false);
    await c.openTitle(_item);
    await c.selectEpisode(1);
    expect(c.playingFromCache, isTrue);

    await player.seekTo(const Duration(seconds: 60));
    await c.deleteDownload(completed(1));

    expect(c.playingFromCache, isFalse);
    expect(player.opened.last, 'https://cdn.test/1/ep1.m3u8');
    expect(player.value.position.inSeconds, 60);
  });

  test('openDownloads pauses without releasing the player', () async {
    await setUpController(cachedEpisodes: [1], withHistory: false);
    await c.openTitle(_item);
    await c.selectEpisode(1);
    await player.play();
    final openedBefore = player.opened.length;

    c.openDownloads();

    expect(c.page, AppPage.downloads);
    expect(player.opened.length, openedBefore);
    expect(player.value.playing, isFalse);

    c.backFromKey();
    expect(c.page, AppPage.play);
  });

  group('下载管理 · 去播放', () {
    test('opens the recorded episode and Back returns to 下载管理', () async {
      await setUpController(cachedEpisodes: [0, 1]);

      c.openDownloads();
      expect(c.page, AppPage.downloads);
      await c.openTitle(_item);

      expect(c.page, AppPage.play);
      expect(c.episodeIndex, 1);
      expect(c.playingFromCache, isTrue);
      expect(player.opened.last, endsWith('index.m3u8'));

      c.backFromKey();
      expect(c.page, AppPage.downloads);
    });

    test('the play page picks the downloaded prefix while it is in flight',
        () async {
      await setUpController(cachedEpisodes: [1], progressive: true);

      c.openDownloads();
      await c.openTitle(_item);

      expect(c.page, AppPage.play);
      expect(c.playingPartial, isTrue);
      expect(player.opened.last, endsWith('partial.m3u8'));
    });

    test('with no record, an offline open still uses the download snapshot',
        () async {
      await setUpController(
          cachedEpisodes: [0], withHistory: false, vod: _OfflineVod());

      c.openDownloads();
      await c.openTitle(_item);

      expect(c.page, AppPage.play);
      expect(c.playError, isNull);
      expect(c.currentDetail!.sourceId, 'src1');
      expect(c.playingFromCache, isTrue);
      expect(player.opened.last, endsWith('index.m3u8'));
    });
  });

  group('边下边播', () {
    test('a downloading episode starts from its finished prefix', () async {
      await setUpController(cachedEpisodes: [1], progressive: true);

      await c.openTitle(_item);

      expect(c.page, AppPage.play);
      expect(c.episodeIndex, 1);
      expect(c.playingPartial, isTrue);
      expect(c.playingFromCache, isFalse);
      expect(c.partialPlayableMs, 300000);
      // Served over the loopback transport: local-file HLS is unreliable on
      // the TV boxes.
      expect(player.opened.last, startsWith('http://127.0.0.1:'));
      expect(player.opened.last, endsWith('partial.m3u8'));
      // History progress was restored into the prefix.
      expect(player.value.position.inSeconds, 120);
    });

    test('the playhead hands over to the online stream at the frontier',
        () async {
      await setUpController(cachedEpisodes: [1], progressive: true);
      await c.openTitle(_item);
      expect(c.playingPartial, isTrue);

      // Frontier 5:00, hand-over lead 15s.
      await player.seekTo(const Duration(seconds: 285));
      await pumpEventQueue();

      expect(c.playingPartial, isFalse);
      expect(c.playingFromCache, isFalse);
      expect(player.opened.last, 'https://cdn.test/1/ep1.m3u8');
      expect(player.value.position.inSeconds, 285);
    });

    test('seeking past the frontier continues online at the target', () async {
      await setUpController(cachedEpisodes: [1], progressive: true);
      await c.openTitle(_item);

      // 2:00 + 3:20 = 5:20, past the 5:00 prefix.
      await c.seekBy(const Duration(seconds: 200));

      expect(c.playingPartial, isFalse);
      expect(player.opened.last, 'https://cdn.test/1/ep1.m3u8');
      expect(player.value.position.inSeconds, 320);
    });

    test('a small seek stays on the prefix', () async {
      await setUpController(cachedEpisodes: [1], progressive: true);
      await c.openTitle(_item);

      await c.seekBy(const Duration(seconds: 60));

      expect(c.playingPartial, isTrue);
      expect(player.opened.last, endsWith('partial.m3u8'));
      expect(player.value.position.inSeconds, 180);
    });

    test('a finished download swaps to the local copy mid-playback', () async {
      await setUpController(cachedEpisodes: [1], progressive: true);
      await c.openTitle(_item);
      expect(c.playingPartial, isTrue);
      final id = manager.activeTasks.single.id;

      await progressiveEngine!.finish(id);
      await waitUntil(() => manager.completedCount == 1);
      await player.seekTo(const Duration(seconds: 130));
      await pumpEventQueue();

      expect(c.playingPartial, isFalse);
      expect(c.playingFromCache, isTrue);
      expect(player.opened.last, endsWith('index.m3u8'));
      expect(player.value.position.inSeconds, 130);
    });

    test('the prefix is only played when enough of it is downloaded', () async {
      await setUpController(cachedEpisodes: [1], progressive: true);
      // History resumes at 2:00 but the download reports back at 1:00.
      progressiveEngine!.report(manager.activeTasks.single.id, 60000);

      await c.openTitle(_item);

      expect(c.playingPartial, isFalse);
      expect(player.opened.last, 'https://cdn.test/1/ep1.m3u8');
    });

    test('the bar spans the whole episode and grows with the download',
        () async {
      await setUpController(cachedEpisodes: [1], progressive: true);
      await c.openTitle(_item);
      expect(c.playingPartial, isTrue);

      // The player only knows the 5:00 prefix it opened; the bar shows the
      // episode's real 45:00 so it doesn't end (and jump) at the prefix.
      expect(player.value.duration, const Duration(minutes: 5));
      expect(c.playbackDuration, const Duration(minutes: 45));
      expect(c.playbackProgress, closeTo(120 / 2700, 1e-9));
      expect(c.playbackBuffered, closeTo(300 / 2700, 1e-9));

      // The download frontier extends the buffered (白条) layer.
      progressiveEngine!.report(manager.activeTasks.single.id, 600000);
      expect(c.playbackBuffered, closeTo(600 / 2700, 1e-9));
      expect(c.playbackDuration, const Duration(minutes: 45));
      expect(c.playbackProgress, closeTo(120 / 2700, 1e-9));
    });
  });
}
