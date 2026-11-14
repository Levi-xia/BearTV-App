import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bear_tv/core/app_controller.dart';
import 'package:bear_tv/core/app_scope.dart';
import 'package:bear_tv/data/downloads/download_engine.dart';
import 'package:bear_tv/data/downloads/download_manager.dart';
import 'package:bear_tv/data/downloads/download_models.dart';
import 'package:bear_tv/data/downloads/download_storage.dart';
import 'package:bear_tv/data/downloads/downloads_store.dart';
import 'package:bear_tv/data/kv_store.dart';
import 'package:bear_tv/data/models.dart';
import 'package:bear_tv/data/settings_store.dart';
import 'package:bear_tv/data/vod/cms_models.dart';
import 'package:bear_tv/screens/downloads_screen.dart';

const _item = VodItem(
  id: 7,
  mediaType: 'tv',
  title: '测试剧',
  en: '',
  genre: '剧情',
  desc: '',
  year: 2024,
  score: '8.0',
  ep: 4,
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

DownloadRequest _request(List<int> episodes) => DownloadRequest(
      item: _item,
      detail: _detail,
      lineIndex: 0,
      episodeIndices: episodes,
    );

/// Writes the entry file and completes at once — a finished download.
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
        doneSegments: 4,
        totalSegments: 4,
        receivedBytes: 2048,
        totalBytes: 2048));
    return const DownloadResult(
      relativePath: 'index.m3u8',
      isHls: true,
      bytes: 2048,
      durationMs: 1000,
      totalSegments: 4,
    );
  }

  @override
  void dispose() {}
}

/// Stays pending until cancelled — an in-flight download.
class _HeldEngine implements DownloadEngine {
  final Map<String, Completer<DownloadResult>> _pending = {};
  final Map<String, Timer> _timers = {};
  final Map<String, void Function(DownloadProgress)> _sinks = {};

  @override
  Future<DownloadResult> run(
    DownloadTask task,
    DownloadStorage ignored, {
    required DownloadCancelToken cancel,
    required void Function(DownloadProgress) onProgress,
  }) {
    final completer = Completer<DownloadResult>();
    _pending[task.id] = completer;
    _sinks[task.id] = onProgress;
    onProgress(const DownloadProgress(
        doneSegments: 0, totalSegments: 10, receivedBytes: 0, totalBytes: 100));
    _timers[task.id] = Timer.periodic(const Duration(milliseconds: 1), (timer) {
      if (completer.isCompleted) {
        timer.cancel();
        _timers.remove(task.id);
        return;
      }
      if (cancel.cancelled) {
        timer.cancel();
        _timers.remove(task.id);
        _pending.remove(task.id);
        completer.completeError(const DownloadCancelled());
      }
    });
    return completer.future;
  }

  /// Reports [done] of [total] segments while the task keeps running.
  void emit(int done, int total) {
    for (final sink in _sinks.values) {
      sink(DownloadProgress(
        doneSegments: done,
        totalSegments: total,
        receivedBytes: done * 100,
        totalBytes: total * 100,
      ));
    }
  }

  @override
  void dispose() {
    for (final t in _timers.values) {
      t.cancel();
    }
    _sinks.clear();
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
  late DownloadManager manager;
  late AppController controller;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('bear_dl_screen_');
    storage = DownloadStorage(root: temp);
  });

  tearDown(() {
    controller.dispose();
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  /// Fresh manager + controller pair; [init] resolves storage before seeding.
  Future<void> use(DownloadEngine engine) async {
    manager = DownloadManager(
      store: DownloadsStore(persistence: MemoryDownloadPersistence()),
      storage: storage,
      engine: engine,
    );
    controller = AppController(
      settings:
          SettingsStore(seedDefaultKey: false, store: MemoryKeyValueStore()),
      downloads: manager,
    );
    await manager.init();
  }

  Future<void> pumpScreen(
    WidgetTester tester, {
    Size size = const Size(1920, 1080),
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    controller.openDownloads();
    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(
          controller: controller,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: FocusScope(
              child: FocusTraversalGroup(child: const DownloadsScreen()),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// Manager init + enqueue touch the real file system, so they must run
  /// outside the widget-test fake-async zone.
  Future<void> seed(
    WidgetTester tester,
    DownloadEngine engine,
    List<int> episodes,
  ) async {
    await tester.runAsync(() async {
      await use(engine);
      await manager.enqueue(_request(episodes));
      // The instant engine finishes inside the queue pump, a microtask chain
      // that keeps running after enqueue returns.
      if (engine is _InstantEngine) {
        for (var i = 0; i < 200 && manager.activeCount > 0; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      }
    });
  }

  /// Real (not fake-async) delay so the download engine's cancellation poll
  /// and the manager's continuation can run.
  Future<void> settle(WidgetTester tester) async {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('lists completed episodes and collapses the group on OK',
      (tester) async {
    await seed(tester, _InstantEngine(storage), [0, 1]);
    await pumpScreen(tester);

    expect(find.text('下载管理'), findsOneWidget);
    // The 下载中/已完成 filters are gone: 全部开始/全部暂停 replace them.
    expect(find.text('全部开始'), findsOneWidget);
    expect(find.text('全部暂停'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('测试剧'), findsOneWidget);
    expect(find.text('源一 · 已缓存 2 集'), findsOneWidget);
    // A lone group opens itself, so the finished episodes are visible.
    expect(find.text('第1集'), findsOneWidget);
    expect(find.text('第2集'), findsOneWidget);
    expect(find.text('✓'), findsNWidgets(2));
    // Cached episodes can be resumed straight from the card.
    expect(find.text('去播放'), findsOneWidget);

    // OK on the card header folds it down to a single row.
    await tester.tap(find.text('测试剧'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('第1集'), findsNothing);
    expect(find.text('源一 · 已缓存 2 集'), findsOneWidget);

    // …and opens it again.
    await tester.tap(find.text('测试剧'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('第1集'), findsOneWidget);
  });

  testWidgets('renders an in-flight task and pauses it from its cell',
      (tester) async {
    final engine = _HeldEngine();
    await seed(tester, engine, [2]);
    await pumpScreen(tester);

    expect(find.text('第3集'), findsOneWidget);
    expect(find.text('0%'), findsOneWidget);
    // Counts are plain words, not an x/y fraction that reads like the show's
    // total episode count.
    expect(find.text('源一 · 已缓存 0 集 · 缓存中 1 集'), findsOneWidget);
    // 去播放 is always offered: the play page decides between the partial
    // prefix, cache and the online stream.
    expect(find.text('去播放'), findsOneWidget);
    // The header carries the aggregate throughput while something transfers.
    expect(find.textContaining('速度'), findsOneWidget);

    // Progress paints as a left-anchored wash behind the label. The manager
    // throttles progress notifications to 5 Hz on the wall clock, so let a
    // real 250 ms pass *before* emitting — otherwise the notify is dropped.
    final task = manager.activeTasks.single;
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 250)));
    engine.emit(3, 10);
    expect(manager.activeTasks.single.doneSegments, 3);
    await tester.pump();
    expect(find.text('30%'), findsOneWidget);
    final fill = tester.widget<FractionallySizedBox>(
        find.byKey(ValueKey('downloadProgressFill:${task.id}')));
    expect(fill.widthFactor, closeTo(0.3, 0.001));

    await tester.tap(find.text('第3集'));
    await settle(tester);

    expect(manager.activeTasks.single.status, DownloadStatus.paused);
    expect(find.text('暂停'), findsOneWidget);
    expect(find.text('源一 · 已缓存 0 集 · 已暂停 1 集'), findsOneWidget);

    // Resume from the same cell.
    await tester.tap(find.text('第3集'));
    await settle(tester);
    expect(manager.activeTasks.single.status, DownloadStatus.downloading);
    expect(find.text('0%'), findsOneWidget);

    // Pause again so the fake engine's cancellation poll cancels its timer
    // before the test-binding timer invariant runs.
    await tester.tap(find.text('第3集'));
    await settle(tester);
    expect(manager.activeTasks.single.status, DownloadStatus.paused);
  });

  testWidgets('全部开始 resumes paused work and 全部暂停 stops it', (tester) async {
    await seed(tester, _HeldEngine(), [0, 2]);
    await pumpScreen(tester);
    int downloading() => manager.activeTasks
        .where((t) => t.status == DownloadStatus.downloading)
        .length;
    // The default concurrency (3) starts both episodes at once.
    expect(downloading(), 2);

    await tester.tap(find.text('全部暂停'));
    await settle(tester);
    expect(manager.activeTasks.map((t) => t.status),
        everyElement(DownloadStatus.paused));

    await tester.tap(find.text('全部开始'));
    await settle(tester);
    expect(manager.activeTasks.any((t) => t.status == DownloadStatus.paused),
        isFalse);
    expect(downloading(), 2);

    await tester.tap(find.text('全部暂停'));
    await settle(tester);
  });

  testWidgets('deleting the group asks for confirmation and clears the page',
      (tester) async {
    await seed(tester, _InstantEngine(storage), [0]);
    await pumpScreen(tester);

    await tester.tap(find.text('删除该剧'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('删除整部剧的下载？'), findsOneWidget);

    // 取消 keeps the group.
    await tester.tap(find.text('取消'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(manager.groups, isNotEmpty);

    await tester.tap(find.text('删除该剧'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('删除'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(manager.groups, isEmpty);
    expect(find.text('暂无下载任务'), findsOneWidget);
  });

  testWidgets('MENU on a focused episode cell offers deletion', (tester) async {
    await seed(tester, _InstantEngine(storage), [0, 1]);
    await pumpScreen(tester);

    // Focus lands on the card header; walk it down into the episode grid.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('删除这一集？'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(manager.completedCount, 1);
  });

  testWidgets('设置 picks the simultaneous download count', (tester) async {
    await seed(tester, _InstantEngine(storage), [0]);
    await pumpScreen(tester);
    expect(manager.concurrency, 3);

    await tester.tap(find.text('设置'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('同时下载数'), findsOneWidget);

    // Remote Back arrives through the controller (PopScope / key dispatcher),
    // not as a widget key event: it must dismiss the overlay and keep the page
    // instead of falling through to the page's return page (我的).
    controller.backFromKey();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('同时下载数'), findsNothing);
    expect(controller.page, AppPage.downloads);
    // Focus goes back to the 设置 button, not the page's first card.
    expect(tester.binding.focusManager.primaryFocus?.debugLabel,
        'downloadsSettings');

    await tester.tap(find.text('设置'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('5 集'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('同时下载数'), findsNothing);
    expect(manager.concurrency, 5);
  });

  testWidgets('lays out without overflow at 1280x720', (tester) async {
    await seed(tester, _InstantEngine(storage), [0]);
    await pumpScreen(tester, size: const Size(1280, 720));
    expect(tester.takeException(), isNull);
  });

  testWidgets('lays out without overflow at 960x540', (tester) async {
    await seed(tester, _InstantEngine(storage), [0, 1]);
    await pumpScreen(tester, size: const Size(960, 540));
    expect(tester.takeException(), isNull);
  });
}
