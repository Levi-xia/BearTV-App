import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:bear_tv/data/downloads/download_engine.dart';
import 'package:bear_tv/data/downloads/download_foreground.dart';
import 'package:bear_tv/data/downloads/download_manager.dart';
import 'package:bear_tv/data/downloads/download_models.dart';
import 'package:bear_tv/data/downloads/download_storage.dart';
import 'package:bear_tv/data/downloads/downloads_store.dart';
import 'package:bear_tv/data/models.dart';
import 'package:bear_tv/data/vod/cms_models.dart';

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
    ]),
  ],
);

DownloadRequest _request(List<int> episodes) => DownloadRequest(
      item: _item,
      detail: _detail,
      lineIndex: 0,
      episodeIndices: episodes,
    );

/// Records the platform side of the keep-alive service.
class _FakeForeground implements DownloadForeground {
  _FakeForeground({this.accept = true});

  /// Whether the platform accepts the start call.
  bool accept;

  /// Whether the service is still up when [update] is called.
  bool alive = true;

  int starts = 0;
  int updates = 0;
  int stops = 0;
  String lastText = '';
  int? lastProgress;

  @override
  Future<bool> start({
    required String title,
    required String text,
    int? progress,
    int? max,
  }) async {
    starts++;
    lastText = text;
    lastProgress = progress;
    return accept;
  }

  @override
  Future<bool> update({
    required String title,
    required String text,
    int? progress,
    int? max,
  }) async {
    updates++;
    lastText = text;
    lastProgress = progress;
    return alive;
  }

  @override
  Future<void> stop() async => stops++;
}

/// Engine whose runs stay open until the test completes them, so the queue
/// status is stable while lifecycle events are exercised.
class _GatedEngine implements DownloadEngine {
  _GatedEngine(this.storage);

  final DownloadStorage storage;
  final Map<String, DownloadTask> _tasks = {};
  final Map<String, void Function(DownloadProgress)> _sinks = {};
  final Map<String, Completer<DownloadResult>> _pending = {};
  final Map<String, Timer> _timers = {};

  @override
  Future<DownloadResult> run(
    DownloadTask task,
    DownloadStorage ignored, {
    required DownloadCancelToken cancel,
    required void Function(DownloadProgress) onProgress,
  }) {
    _tasks[task.id] = task;
    _sinks[task.id] = onProgress;
    onProgress(const DownloadProgress(
      doneSegments: 1,
      totalSegments: 10,
      receivedBytes: 100,
      totalBytes: 1000,
    ));
    final completer = Completer<DownloadResult>();
    _pending[task.id] = completer;
    // Like the real engine: a cancellation finishes the run, so the manager
    // frees its slot and can start the task again on resume.
    _timers[task.id] = Timer.periodic(const Duration(milliseconds: 1), (timer) {
      if (!cancel.cancelled) return;
      timer.cancel();
      _timers.remove(task.id);
      _pending.remove(task.id);
      _sinks.remove(task.id);
      if (!completer.isCompleted) {
        completer.completeError(const DownloadCancelled());
      }
    });
    return completer.future;
  }

  /// Reports a new byte count, like the real engine does per segment.
  void progress(int receivedBytes) {
    for (final sink in _sinks.values) {
      sink(DownloadProgress(
        doneSegments: 2,
        totalSegments: 10,
        receivedBytes: receivedBytes,
        totalBytes: 1000,
      ));
    }
  }

  Future<void> complete(String id) async {
    final task = _tasks[id]!;
    _timers.remove(id)?.cancel();
    _sinks.remove(id);
    final dir = await storage.ensureTaskDir(task);
    File('${dir!.path}/index.m3u8')
        .writeAsStringSync('#EXTM3U\n#EXT-X-ENDLIST\n');
    _pending.remove(id)!.complete(const DownloadResult(
          relativePath: 'index.m3u8',
          isHls: true,
          bytes: 1000,
          durationMs: 1000,
          totalSegments: 10,
        ));
  }

  @override
  void dispose() {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(const DownloadCancelled());
    }
    _pending.clear();
  }
}

void main() {
  late Directory temp;
  late DownloadStorage storage;
  late _FakeForeground foreground;
  late _GatedEngine engine;
  late DownloadManager manager;
  var now = 1700000000000;

  Future<void> setUpManager({bool accept = true}) async {
    temp = Directory.systemTemp.createTempSync('bear_fg_');
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    storage = DownloadStorage(root: temp);
    foreground = _FakeForeground(accept: accept);
    engine = _GatedEngine(storage);
    manager = DownloadManager(
      store: DownloadsStore(persistence: MemoryDownloadPersistence()),
      storage: storage,
      engine: engine,
      foreground: foreground,
      clock: () => DateTime.fromMillisecondsSinceEpoch(now),
    );
    addTearDown(manager.dispose);
    await manager.init();
    await manager.setConcurrency(1);
  }

  /// Real (not microtask-only) delay: enqueue/resume persist asynchronously
  /// before the queue pumps the next run.
  Future<void> settle() async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await pumpEventQueue();
  }

  test('starting a download brings up the keep-alive service', () async {
    await setUpManager();

    await manager.enqueue(_request([0, 1]));
    await settle();

    expect(foreground.starts, 1);
    expect(foreground.lastText, contains('正在下载 1 集'));
    expect(foreground.lastText, contains('队列中 1 集'));
    expect(manager.backgroundKeepAlive, isTrue);

    // Aggregated progress on the notification's 0–1000 scale, once the engine
    // has reported sizes and the 1 s refresh window has passed.
    now += 1100;
    engine.progress(100);
    await settle();
    expect(foreground.lastProgress, 100);
  });

  test('backgrounding with the service up keeps the transfers running',
      () async {
    await setUpManager();
    await manager.enqueue(_request([0]));
    await settle();

    manager.handleAppBackgrounded();
    await settle();

    expect(manager.activeTasks.single.status, DownloadStatus.downloading);
    expect(foreground.stops, 0);
  });

  test('the service goes away once the queue finishes', () async {
    await setUpManager();
    await manager.enqueue(_request([0]));
    await settle();
    expect(manager.backgroundKeepAlive, isTrue);

    await engine.complete(manager.activeTasks.single.id);
    await settle();

    expect(manager.completedCount, 1);
    expect(foreground.stops, 1);
    expect(manager.backgroundKeepAlive, isFalse);
  });

  test('progress refreshes the notification at most once a second', () async {
    await setUpManager();
    await manager.enqueue(_request([0]));
    await settle();
    final pushed = foreground.updates;

    // 0.5 s after the last push: too soon for another notification.
    now += 500;
    engine.progress(200);
    await settle();
    expect(foreground.updates, pushed);

    now += 600;
    engine.progress(300);
    await settle();
    expect(foreground.updates, pushed + 1);
    expect(foreground.lastProgress, 300);

    // Same tick: still throttled.
    engine.progress(400);
    await settle();
    expect(foreground.updates, pushed + 1);
  });

  test('a refused service falls back to pausing in the background', () async {
    await setUpManager(accept: false);

    await manager.enqueue(_request([0]));
    await settle();
    expect(foreground.starts, 1);
    expect(manager.backgroundKeepAlive, isFalse);

    manager.handleAppBackgrounded();
    await settle();
    expect(manager.activeTasks.single.status, DownloadStatus.paused);

    manager.handleAppForegrounded();
    await settle();
    expect(manager.activeTasks.single.status, DownloadStatus.downloading);
    // Coming back to the foreground retries the start even inside the
    // cooldown that a refusal imposes.
    expect(foreground.starts, 2);
  });

  test('a service that died under us drops back to pausing', () async {
    await setUpManager();
    await manager.enqueue(_request([0]));
    await pumpEventQueue();
    expect(manager.backgroundKeepAlive, isTrue);

    foreground.alive = false;
    now += 1100;
    engine.progress(200);
    await pumpEventQueue();
    expect(manager.backgroundKeepAlive, isFalse);

    manager.handleAppBackgrounded();
    await pumpEventQueue();
    expect(manager.activeTasks.single.status, DownloadStatus.paused);
  });

  test('detaching pauses the queue and stops the service', () async {
    await setUpManager();
    await manager.enqueue(_request([0]));
    await pumpEventQueue();

    manager.handleAppDetached();
    await pumpEventQueue();

    expect(manager.activeTasks.single.status, DownloadStatus.paused);
    expect(foreground.stops, 1);
    expect(manager.backgroundKeepAlive, isFalse);
  });

  test('platforms without a service always use the pause fallback', () async {
    final fg = defaultDownloadForeground();
    expect(fg, isA<NoopDownloadForeground>());
    expect(await fg.start(title: 't', text: 'x'), isFalse);
    expect(await fg.update(title: 't', text: 'x'), isFalse);
  });
}
