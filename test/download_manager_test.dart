import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:bear_tv/data/downloads/download_engine.dart';
import 'package:bear_tv/data/downloads/download_manager.dart';
import 'package:bear_tv/data/downloads/download_models.dart';
import 'package:bear_tv/data/downloads/download_storage.dart';
import 'package:bear_tv/data/downloads/downloads_store.dart';
import 'package:bear_tv/data/history_store.dart';
import 'package:bear_tv/data/models.dart';
import 'package:bear_tv/data/vod/cms_models.dart';

const _item = VodItem(
  id: 7,
  mediaType: 'tv',
  title: '测试剧',
  en: '',
  genre: '源一',
  desc: '',
  year: 2024,
  score: '',
  ep: 4,
  hd: 'HD',
  neu: false,
  bgUrl: '',
  cardUrl: '',
  posterUrl: '',
);

VodDetail _detail() => const VodDetail(
      sourceId: 'src1',
      sourceName: '源一',
      vodId: 'vod1',
      title: '测试剧',
      playLines: [
        PlayLine(name: '线路1', episodes: [
          Episode(title: '第1集', url: 'https://cdn.test/1/ep0.m3u8'),
          Episode(title: '第2集', url: 'https://cdn.test/1/ep1.m3u8'),
          Episode(title: '第3集', url: 'https://cdn.test/1/ep2.m3u8'),
          Episode(title: '第4集', url: 'https://cdn.test/1/ep3.m3u8'),
        ]),
        PlayLine(name: '线路2', episodes: [
          Episode(title: '第1集', url: 'https://cdn2.test/2/ep0.m3u8'),
          Episode(title: '第2集', url: 'https://cdn2.test/2/ep1.m3u8'),
        ]),
      ],
    );

DownloadRequest _request({
  int line = 0,
  List<int> episodes = const [0],
}) =>
    DownloadRequest(
      item: _item,
      detail: _detail(),
      lineIndex: line,
      episodeIndices: episodes,
    );

const _itemB = VodItem(
  id: 8,
  mediaType: 'tv',
  title: '另一部剧',
  en: '',
  genre: '源二',
  desc: '',
  year: 2023,
  score: '',
  ep: 3,
  hd: 'HD',
  neu: false,
  bgUrl: '',
  cardUrl: '',
  posterUrl: '',
);

VodDetail _detailB() => const VodDetail(
      sourceId: 'src2',
      sourceName: '源二',
      vodId: 'vod2',
      title: '另一部剧',
      playLines: [
        PlayLine(name: '线路1', episodes: [
          Episode(title: '第1集', url: 'https://cdn2.test/1/ep0.m3u8'),
          Episode(title: '第2集', url: 'https://cdn2.test/1/ep1.m3u8'),
          Episode(title: '第3集', url: 'https://cdn2.test/1/ep2.m3u8'),
        ]),
      ],
    );

DownloadRequest _requestB({List<int> episodes = const [0]}) => DownloadRequest(
      item: _itemB,
      detail: _detailB(),
      lineIndex: 0,
      episodeIndices: episodes,
    );

/// Engine whose runs are gated by the test: it records start order, honours
/// cancellation by polling the token (like the real engine), and only writes
/// the entry file when the test calls [complete].
class FakeEngine implements DownloadEngine {
  FakeEngine(this.storage);

  final DownloadStorage storage;
  final List<DownloadTask> started = [];
  final Map<String, Completer<DownloadResult>> _pending = {};
  final Map<String, void Function(DownloadProgress)> _sinks = {};

  @override
  Future<DownloadResult> run(
    DownloadTask task,
    DownloadStorage ignored, {
    required DownloadCancelToken cancel,
    required void Function(DownloadProgress) onProgress,
  }) {
    started.add(task);
    final completer = Completer<DownloadResult>();
    _pending[task.id] = completer;
    Timer.periodic(const Duration(milliseconds: 1), (timer) {
      if (completer.isCompleted) {
        timer.cancel();
        return;
      }
      if (cancel.cancelled) {
        timer.cancel();
        _pending.remove(task.id);
        completer.completeError(const DownloadCancelled());
      }
    });
    _sinks[task.id] = onProgress;
    onProgress(const DownloadProgress(
        doneSegments: 0, totalSegments: 2, receivedBytes: 10, totalBytes: 100));
    return completer.future;
  }

  Future<void> complete(String id) async {
    final task = started.firstWhere((t) => t.id == id);
    final dir = await storage.ensureTaskDir(task);
    File('${dir!.path}/index.m3u8')
        .writeAsStringSync('#EXTM3U\n#EXT-X-ENDLIST\n');
    final completer = _pending.remove(id);
    completer!.complete(const DownloadResult(
      relativePath: 'index.m3u8',
      isHls: true,
      bytes: 30,
      durationMs: 6000,
      totalSegments: 2,
    ));
    await _settle();
  }

  /// Simulates the engine reporting [bytes] transferred so far.
  void emit(String id, int bytes) {
    _sinks[id]!(DownloadProgress(
      doneSegments: 1,
      totalSegments: 2,
      receivedBytes: bytes,
      totalBytes: 1000,
    ));
  }

  /// Simulates the engine reporting how much of the episode is playable yet.
  void emitPlayable(String id, int playableMs, {int totalMs = 2700000}) {
    _sinks[id]!(DownloadProgress(
      doneSegments: 3,
      totalSegments: 20,
      receivedBytes: 300,
      totalBytes: 1000,
      playableMs: playableMs,
      totalMs: totalMs,
    ));
  }

  void fail(String id, String message) {
    _pending.remove(id)!.completeError(DownloadException(message));
  }

  @override
  void dispose() {
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(const DownloadCancelled());
    }
    _pending.clear();
  }
}

/// Let timer-driven cancellation and microtask continuations run.
Future<void> _settle() async {
  await Future<void>.delayed(const Duration(milliseconds: 20));
  await pumpEventQueue();
}

void main() {
  late Directory temp;
  late DownloadStorage storage;
  late MemoryDownloadPersistence persistence;
  late DownloadsStore store;
  late FakeEngine engine;
  late DownloadManager manager;
  var now = 1700000000000;

  DownloadManager makeManager({
    DownloadsStore? withStore,
    DownloadStorage? withStorage,
    DownloadEngine? withEngine,
  }) =>
      DownloadManager(
        store: withStore ?? store,
        storage: withStorage ?? storage,
        engine: withEngine ?? engine,
        clock: () => DateTime.fromMillisecondsSinceEpoch(now),
      );

  setUp(() async {
    now = 1700000000000;
    temp = Directory.systemTemp.createTempSync('bear_mgr_');
    storage = DownloadStorage(root: temp);
    persistence = MemoryDownloadPersistence();
    store = DownloadsStore(persistence: persistence);
    engine = FakeEngine(storage);
    manager = makeManager();
    await manager.init();
    // Most tests assert the queue strictly in enqueue order; the concurrency
    // tests below opt into more slots explicitly.
    await manager.setConcurrency(1);
  });

  tearDown(() {
    manager.dispose();
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  test('downloads one episode at a time, in enqueue order', () async {
    final added = await manager.enqueue(_request(episodes: [0, 1]));
    expect(added, 2);
    await pumpEventQueue();

    expect(engine.started.length, 1);
    expect(engine.started.single.episodeIndex, 0);
    expect(manager.activeCount, 2);
    expect(manager.activeTasks.where((t) => t.isRunning).length, 1);

    await engine.complete(engine.started.single.id);
    expect(engine.started.length, 2);
    expect(engine.started.last.episodeIndex, 1);

    await engine.complete(engine.started.last.id);
    expect(manager.completedCount, 2);
    expect(manager.activeTasks, isEmpty);

    final done = manager.completedTasks.first;
    expect(done.status, DownloadStatus.completed);
    expect(done.isHls, isTrue);
    expect(done.relativePath, 'index.m3u8');
    expect(done.totalSegments, 2);
    expect(done.progress, 1);
    expect(storage.localUrl(done), startsWith('http://127.0.0.1:'));
  });

  test('the default is three concurrent downloads, chosen by the user',
      () async {
    final db = MemoryDownloadPersistence();
    final ownStore = DownloadsStore(persistence: db);
    final ownStorage = DownloadStorage(root: temp);
    final ownEngine = FakeEngine(ownStorage);
    final m = DownloadManager(
      store: ownStore,
      storage: ownStorage,
      engine: ownEngine,
      clock: () => DateTime.fromMillisecondsSinceEpoch(now),
    );
    addTearDown(m.dispose);
    await m.init();
    expect(m.concurrency, 3);

    await m.enqueue(_request(episodes: [0, 1, 2, 3]));
    await pumpEventQueue();
    expect(ownEngine.started.length, 3);

    // Raising the limit starts the queued episode right away…
    await m.setConcurrency(5);
    await pumpEventQueue();
    expect(ownEngine.started.length, 4);

    // …and the choice survives a restart.
    expect(db.readAll()['setting:concurrency'], '5');
    final reloaded = DownloadManager(
      store: DownloadsStore(persistence: db),
      storage: DownloadStorage(root: temp),
      engine: FakeEngine(ownStorage),
      clock: () => DateTime.fromMillisecondsSinceEpoch(now),
    );
    addTearDown(reloaded.dispose);
    await reloaded.init();
    expect(reloaded.concurrency, 5);

    // Values outside 1/3/5/10 are ignored.
    await m.setConcurrency(2);
    expect(m.concurrency, 5);
  });

  test('enqueue keeps a reserve of free space on the volume', () async {
    DownloadManager withSpace(Future<int?> Function() probe) => DownloadManager(
          store: DownloadsStore(persistence: MemoryDownloadPersistence()),
          storage: DownloadStorage(root: temp),
          engine: FakeEngine(storage),
          clock: () => DateTime.fromMillisecondsSinceEpoch(now),
          freeSpaceProbe: probe,
        );

    final tight = withSpace(() async => 64 * 1024 * 1024);
    addTearDown(tight.dispose);
    await tight.init();
    await expectLater(
        tight.enqueue(_request()), throwsA(isA<DownloadException>()));
    expect(tight.activeCount, 0);
    expect(tight.freeSpaceBytes, 64 * 1024 * 1024);

    final roomy = withSpace(() async => 8 * 1024 * 1024 * 1024);
    addTearDown(roomy.dispose);
    await roomy.init();
    expect(await roomy.enqueue(_request()), 1);
    expect(roomy.freeSpaceBytes, 8 * 1024 * 1024 * 1024);
  });

  test('reports per-group and total speed, decaying when a transfer stalls',
      () async {
    await manager.setConcurrency(3);
    await manager.enqueue(_request(episodes: [0]));
    await manager.enqueue(_requestB(episodes: [0]));
    await pumpEventQueue();

    final a = engine.started.firstWhere((t) => t.groupKey == 'src1:vod1');
    final b = engine.started.firstWhere((t) => t.groupKey == 'src2:vod2');
    expect(manager.runningCount, 2);

    // The engine's start event (10 bytes) is the t0 baseline.
    now += 1000;
    engine.emit(a.id, 10 + 1024 * 1024);
    engine.emit(b.id, 10 + 512 * 1024);

    expect(manager.groupSpeed('src1:vod1'), closeTo(1024 * 1024, 4096));
    expect(manager.groupSpeed('src2:vod2'), closeTo(512 * 1024, 4096));
    expect(manager.totalSpeed, closeTo(1536 * 1024, 8192));
    // A group with nothing downloading reports nothing.
    expect(manager.groupSpeed('src9:vod9'), 0);

    // A finished episode drops out of both figures.
    await engine.complete(b.id);
    expect(manager.groupSpeed('src2:vod2'), 0);
    expect(manager.totalSpeed, closeTo(1024 * 1024, 4096));

    // No progress within the window: report 0 rather than a stale number.
    now += DownloadManager.speedStaleMs + 1000;
    expect(manager.totalSpeed, 0);
  });

  test('cards keep their order until an episode is added to them', () async {
    await manager.enqueue(_request(episodes: [0]));
    await pumpEventQueue();
    now += 1000;
    await manager.enqueue(_requestB(episodes: [0]));
    await pumpEventQueue();

    // The newest resource is on top.
    expect(manager.groups.map((g) => g.key), ['src2:vod2', 'src1:vod1']);

    // Progress/state changes on the older card must not reshuffle the list.
    await engine.complete(engine.started.single.id);
    await pumpEventQueue();
    expect(manager.groups.map((g) => g.key), ['src2:vod2', 'src1:vod1']);

    // Only adding an episode promotes a card again.
    now += 1000;
    await manager.enqueue(_request(episodes: [1]));
    expect(manager.groups.map((g) => g.key), ['src1:vod1', 'src2:vod2']);
  });

  test('enqueue dedupes completed and in-flight episodes', () async {
    await manager.enqueue(_request(episodes: [0]));
    await pumpEventQueue();

    // Episode 0 is downloading, episode 1 is new.
    expect(await manager.enqueue(_request(episodes: [0, 1])), 1);

    await engine.complete(engine.started.single.id);
    await engine.complete(engine.started.last.id);
    expect(await manager.enqueue(_request(episodes: [0, 1])), 0);
    expect(manager.completedCount, 2);
  });

  test('pause cancels the run and resume restarts it', () async {
    await manager.enqueue(_request(episodes: [0]));
    await pumpEventQueue();
    final id = engine.started.single.id;

    await manager.pause(id);
    await _settle();
    expect(manager.activeTasks.single.status, DownloadStatus.paused);
    expect(engine.started.length, 1);

    await manager.resume(id);
    await pumpEventQueue();
    expect(manager.activeTasks.single.status, DownloadStatus.downloading);
    expect(engine.started.length, 2);
  });

  test('resumeAll restarts every paused task without the caller filtering',
      () async {
    await manager.enqueue(_request(episodes: [0, 1]));
    await pumpEventQueue();
    expect(engine.started.length, 1);

    await manager.pauseAll();
    await _settle();
    expect(manager.activeTasks.map((t) => t.status),
        everyElement(DownloadStatus.paused));

    // One button, no filtering: the paused episode restarts and the second
    // one waits its turn again.
    await manager.resumeAll();
    await pumpEventQueue();
    expect(manager.activeTasks.any((t) => t.status == DownloadStatus.paused),
        isFalse);
    expect(engine.started.length, 2);
    expect(manager.activeTasks.map((t) => t.status),
        contains(DownloadStatus.downloading));
  });

  test('removing a running task cancels it, deletes files and pumps next',
      () async {
    await manager.enqueue(_request(episodes: [0, 1]));
    await pumpEventQueue();
    final first = engine.started.single;
    final dir = await storage.ensureTaskDir(first);
    File('${dir!.path}/seg_00001.ts').writeAsBytesSync([1]);

    await manager.remove(first.id);
    await _settle();

    expect(manager.activeTasks.length, 1);
    expect(manager.activeTasks.single.episodeIndex, 1);
    expect(dir.existsSync(), isFalse);
    expect(store.tasks.any((t) => t.id == first.id), isFalse);
    // The next queued episode started.
    expect(engine.started.length, 2);
  });

  test('a failed task stays visible with its error and can be retried',
      () async {
    await manager.enqueue(_request(episodes: [0]));
    await pumpEventQueue();
    final id = engine.started.single.id;

    engine.fail(id, 'HTTP 403：资源禁止访问');
    await _settle();

    final failed = manager.activeTasks.single;
    expect(failed.status, DownloadStatus.failed);
    expect(failed.error, contains('403'));

    await manager.resume(id);
    await pumpEventQueue();
    expect(engine.started.length, 2);
    expect(manager.activeTasks.single.status, DownloadStatus.downloading);
  });

  test('groups by resource and keeps the detail snapshot', () async {
    await manager.enqueue(_request(episodes: [0, 1]));
    await pumpEventQueue();
    await engine.complete(engine.started.single.id);
    await engine.complete(engine.started.last.id);

    final group = manager.groups.single;
    expect(group.key, 'src1:vod1');
    expect(group.sourceName, '源一');
    expect(group.item.title, '测试剧');
    expect(group.completedCount, 2);
    expect(group.totalCount, 2);
    expect(group.snapshot.playLines.length, 2);
    expect(group.snapshot.playLines[1].episodes.length, 2);
    expect(group.snapshot.playLines[0].episodes[0].title, '第1集');
  });

  test('launchFor is episode-scoped, not whole-show', () async {
    await manager.enqueue(_request(episodes: [0, 1]));
    await pumpEventQueue();
    await engine.complete(engine.started.single.id);
    await engine.complete(engine.started.last.id);

    final fresh = manager.launchFor(item: _item);
    expect(fresh, isNotNull);
    expect(fresh!.task!.episodeIndex, 0);

    final ep1 = manager.launchFor(
      item: _item,
      entry: const HistoryEntry(
        item: _item,
        sourceId: 'src1',
        sourceName: '源一',
        vodId: 'vod1',
        lineIndex: 0,
        episodeIndex: 1,
        episodeTitle: '第2集',
        episodeUrl: 'https://cdn.test/1/ep1.m3u8?sig=abc',
      ),
    );
    expect(ep1, isNotNull);
    expect(ep1!.task!.episodeIndex, 1);

    // Episode 2 isn't downloaded: must fall back to online, not switch show.
    final ep2 = manager.launchFor(
      item: _item,
      entry: const HistoryEntry(
        item: _item,
        sourceId: 'src1',
        sourceName: '源一',
        vodId: 'vod1',
        lineIndex: 0,
        episodeIndex: 2,
        episodeTitle: '第3集',
        episodeUrl: 'https://cdn.test/1/ep2.m3u8',
      ),
    );
    expect(ep2, isNull);
  });

  test('fresh launchFor requires the first episode to be cached', () async {
    await manager.enqueue(_request(episodes: [1]));
    await pumpEventQueue();
    await engine.complete(engine.started.single.id);

    expect(manager.launchFor(item: _item), isNull);
    expect(
      manager.launchFor(
        item: _item,
        entry: const HistoryEntry(
          item: _item,
          sourceId: 'src1',
          vodId: 'vod1',
          episodeTitle: '第2集',
        ),
      ),
      isNotNull,
    );
  });

  group('launchForGroup (下载管理 · 去播放)', () {
    test('without a record it opens a finished episode of this group',
        () async {
      await manager.enqueue(_request(episodes: [1]));
      await pumpEventQueue();
      await engine.complete(engine.started.single.id);

      final launch = manager.launchForGroup(manager.groups.single);

      expect(launch, isNotNull);
      expect(launch!.group.sourceId, 'src1');
      expect(launch.task!.episodeIndex, 1);
    });

    test('without a record a finished episode beats an in-flight prefix',
        () async {
      await manager.enqueue(_request(episodes: [1]));
      await pumpEventQueue();
      await engine.complete(engine.started.single.id);
      await manager.enqueue(_request(episodes: [0]));
      await pumpEventQueue();
      final inFlight = engine.started.last;
      final dir = await storage.ensureTaskDir(inFlight);
      File('${dir!.path}/partial.m3u8')
          .writeAsStringSync('#EXTM3U\n#EXT-X-ENDLIST\n');
      engine.emitPlayable(inFlight.id, DownloadManager.minPartialMs + 30000);

      final launch = manager.launchForGroup(manager.groups.single);

      expect(launch!.task!.episodeIndex, 1);
    });

    test('without a record only the in-flight prefix is playable', () async {
      await manager.enqueue(_request(episodes: [0]));
      await pumpEventQueue();
      final task = engine.started.single;
      final dir = await storage.ensureTaskDir(task);
      File('${dir!.path}/partial.m3u8')
          .writeAsStringSync('#EXTM3U\n#EXT-X-ENDLIST\n');
      engine.emitPlayable(task.id, DownloadManager.minPartialMs + 30000);

      final launch = manager.launchForGroup(manager.groups.single);

      expect(launch!.task!.episodeIndex, 0);
      expect(launch.task!.playableMs, greaterThan(DownloadManager.minPartialMs));
    });

    test('a task with no prefix yet is still returned (online fallback)',
        () async {
      await manager.enqueue(_request(episodes: [0]));
      await pumpEventQueue();

      final launch = manager.launchForGroup(manager.groups.single);

      expect(launch!.task!.episodeIndex, 0);
    });

    test('a record on this resource pins its undownloaded episode', () async {
      await manager.enqueue(_request(episodes: [0]));
      await pumpEventQueue();
      await engine.complete(engine.started.single.id);

      final launch = manager.launchForGroup(
        manager.groups.single,
        entry: const HistoryEntry(
          item: _item,
          sourceId: 'src1',
          sourceName: '源一',
          vodId: 'vod1',
          episodeIndex: 2,
          episodeTitle: '第3集',
          episodeUrl: 'https://cdn.test/1/ep2.m3u8',
        ),
      );

      expect(launch!.task, isNull);
      expect(launch.lineIndex, 0);
      expect(launch.episodeIndex, 2);
    });

    test('a record from another resource does not pin the episode', () async {
      await manager.enqueue(_request(episodes: [0]));
      await pumpEventQueue();
      await engine.complete(engine.started.single.id);

      final launch = manager.launchForGroup(
        manager.groups.single,
        entry: const HistoryEntry(
          item: _item,
          sourceId: 'src2',
          sourceName: '源二',
          vodId: 'vod9',
          episodeIndex: 1,
          episodeTitle: '第2集',
          episodeUrl: 'https://other.test/ep1.m3u8',
        ),
      );

      expect(launch!.task!.episodeIndex, 0);
    });
  });

  test('completedTaskFor matches signed URLs and titles', () async {
    await manager.enqueue(_request(episodes: [0]));
    await pumpEventQueue();
    await engine.complete(engine.started.single.id);

    final byPath = manager.completedTaskFor(
      sourceId: 'src1',
      vodId: 'vod1',
      episodeUrl: 'https://cdn.test/1/ep0.m3u8?token=expires',
    );
    expect(byPath, isNotNull);

    final byTitle = manager.completedTaskFor(
      sourceId: 'src1',
      vodId: 'vod1',
      episodeTitle: '第 1 集',
    );
    expect(byTitle, isNotNull);

    expect(
      manager.completedTaskFor(
        sourceId: 'src1',
        vodId: 'vod1',
        episodeUrl: 'https://cdn.test/1/ep2.m3u8',
        episodeTitle: '第3集',
      ),
      isNull,
    );
  });

  test('a running download exposes its finished prefix for 边下边播', () async {
    await manager.enqueue(_request(episodes: [0]));
    await pumpEventQueue();
    final task = engine.started.single;
    final dir = await storage.ensureTaskDir(task);
    File('${dir!.path}/partial.m3u8')
        .writeAsStringSync('#EXTM3U\n#EXT-X-ENDLIST\n');

    PartialPlayback? lookup() => manager.partialFor(
          sourceId: 'src1',
          vodId: 'vod1',
          episodeUrl: 'https://cdn.test/1/ep0.m3u8',
          episodeTitle: '第1集',
          episodeIndex: 0,
        );

    expect(lookup(), isNull); // nothing downloaded yet
    engine.emitPlayable(task.id, DownloadManager.minPartialMs - 1000);
    expect(lookup(), isNull);

    engine.emitPlayable(task.id, DownloadManager.minPartialMs + 30000);
    final partial = lookup();
    expect(partial, isNotNull);
    expect(partial!.playableMs, DownloadManager.minPartialMs + 30000);
    expect(partial.urls.single, startsWith('http://127.0.0.1:'));
    expect(partial.urls.single, endsWith('partial.m3u8'));
    // The full episode duration is tracked for the history record.
    expect(manager.taskById(task.id)!.durationMs, 2700000);

    // Once the download completes, the completed copy takes over.
    await engine.complete(task.id);
    expect(lookup(), isNull);
  });

  test('init pauses interrupted downloads and drops vanished completed files',
      () async {
    final interrupted = tasksForRequest(_request(episodes: [0]), nowMs: now)
        .single
        .copyWith(status: DownloadStatus.downloading);
    final vanished = tasksForRequest(_request(episodes: [1]), nowMs: now)
        .single
        .copyWith(status: DownloadStatus.completed, relativePath: 'index.m3u8');
    await store.saveTask(interrupted);
    await store.saveTask(vanished);
    await store.saveSnapshot(_detail());

    final store2 = DownloadsStore(persistence: persistence);
    final storage2 = DownloadStorage(root: temp);
    final manager2 = makeManager(
      withStore: store2,
      withStorage: storage2,
      withEngine: FakeEngine(storage2),
    );
    await manager2.init();

    final tasks = manager2.groups.single.tasks;
    expect(tasks.length, 1);
    expect(tasks.single.id, interrupted.id);
    expect(tasks.single.status, DownloadStatus.paused);
    expect(store2.tasks.any((t) => t.id == vanished.id), isFalse);
    manager2.dispose();
  });

  test('clearCompleted removes records and files but keeps active tasks',
      () async {
    await manager.enqueue(_request(episodes: [0, 1]));
    await pumpEventQueue();
    await engine.complete(engine.started.single.id);

    final done = manager.completedTasks.single;
    final dir = storage.taskDir(done)!;
    expect(dir.existsSync(), isTrue);

    await manager.clearCompleted();
    await _settle();

    expect(manager.completedTasks, isEmpty);
    expect(dir.existsSync(), isFalse);
    expect(manager.activeTasks.length, 1);
    expect(manager.activeTasks.single.episodeIndex, 1);
  });

  test('lifecycle pause resumes only auto-paused tasks', () async {
    await manager.enqueue(_request(episodes: [0, 1]));
    await pumpEventQueue();
    final firstId = engine.started.single.id;

    manager.pauseActiveForLifecycle();
    await _settle();
    expect(manager.activeTasks.every((t) => t.status == DownloadStatus.paused),
        isTrue);

    manager.resumeAutoPaused();
    await pumpEventQueue();
    expect(engine.started.length, 2);
    expect(engine.started.last.id, firstId);
    final running = manager.activeTasks.firstWhere((t) => t.isRunning);
    expect(running.episodeIndex, 0);

    // A task paused by the user must not come back with the next lifecycle
    // round (only ids recorded by pauseActiveForLifecycle are resumed).
    await manager.pause(running.id);
    await _settle();
    manager.pauseActiveForLifecycle();
    await _settle();
    manager.resumeAutoPaused();
    await _settle();
    expect(
      manager.activeTasks.firstWhere((t) => t.id == running.id).status,
      DownloadStatus.paused,
    );
  });
}
