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
import 'package:bear_tv/player/player_controller.dart';
import 'package:bear_tv/screens/download_sheet.dart';

/// Player with no timers and no I/O.
class _IdlePlayer extends ChangeNotifier implements PlayerController {
  PlayerValue _value = const PlayerValue(
    position: Duration(minutes: 12),
    duration: Duration(minutes: 45),
  );

  @override
  PlayerValue get value => _value;

  void _set(PlayerValue v) {
    _value = v;
    notifyListeners();
  }

  @override
  Future<void> open(String? url, {Map<String, String>? headers}) async =>
      _set(_value.copyWith(position: Duration.zero, ready: true));

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

void main() {
  late Directory temp;
  late DownloadStorage storage;
  late DownloadManager manager;
  late AppController controller;
  var closed = 0;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('bear_dl_sheet_');
    storage = DownloadStorage(root: temp);
    manager = DownloadManager(
      store: DownloadsStore(persistence: MemoryDownloadPersistence()),
      storage: storage,
      engine: _InstantEngine(storage),
      // No platform channel in widget tests: answer "unknown" synchronously so
      // the enqueue path stays inside the fake-async zone.
      freeSpaceProbe: () async => null,
    );
    controller = AppController(
      settings:
          SettingsStore(seedDefaultKey: false, store: MemoryKeyValueStore()),
      player: _IdlePlayer(),
      downloads: manager,
    );
    controller.currentItem = _item;
    controller.currentDetail = _detail;
    controller.episodeIndex = 1;
    closed = 0;
  });

  tearDown(() {
    controller.dispose();
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  Future<void> seed(WidgetTester tester, List<int> episodes) async {
    await tester.runAsync(() async {
      await manager.init();
      await manager.enqueue(_request(episodes));
      for (var i = 0; i < 200 && manager.activeCount > 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });
  }

  /// Presses the focused cell with the remote's OK key and lets the enqueue
  /// and the instant engine finish.
  Future<void> pressOk(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    for (var i = 0; i < 40 && manager.activeCount > 0; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> pumpSheet(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1920, 1080);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(
          controller: controller,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: FocusScope(
              child: FocusTraversalGroup(
                child: DownloadSheet(onClose: () => closed++),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('focus lands on the currently playing episode inside the sheet',
      (tester) async {
    await seed(tester, [0]);
    await pumpSheet(tester);

    final focused = tester.binding.focusManager.primaryFocus;
    expect(focused, isNotNull);
    expect(focused!.debugLabel, 'downloadEpisode1');
    expect(find.text('下载选集'), findsOneWidget);
  });

  testWidgets('a cached episode is greyed with a ✓ 已缓存 badge', (tester) async {
    await seed(tester, [0]);
    await pumpSheet(tester);

    expect(find.text('源一 · 线路1 · 已缓存 1/3 集'), findsOneWidget);
    expect(find.textContaining('✓ 已缓存'), findsOneWidget);
  });

  testWidgets('the focused 全部下载 pill is not clipped by the sheet scroller',
      (tester) async {
    await seed(tester, [0]);
    await pumpSheet(tester);

    // 全部下载 is the leftmost widget on its row, i.e. flush with the scroll
    // viewport's clip rect. FocusFx.scale paints 1.06× the layout box, so the
    // scaled box must still fit inside the viewport or the pill's corners get
    // sliced off.
    final clip = tester.getRect(find
        .ancestor(
            of: find.text('全部下载'), matching: find.byType(SingleChildScrollView))
        .first);
    final box = tester.getRect(find
        .ancestor(of: find.text('全部下载'), matching: find.byType(AnimatedScale))
        .first);
    final scaled = Rect.fromCenter(
        center: box.center, width: box.width * 1.06, height: box.height * 1.06);

    expect(clip.contains(scaled.topLeft), isTrue,
        reason: 'top-left $scaled outside $clip');
    expect(clip.contains(scaled.bottomRight), isTrue,
        reason: 'bottom-right $scaled outside $clip');
    // ...and it really is the edge case: the button hugs the clip rect.
    expect(scaled.left, lessThan(clip.left + 20));
  });

  testWidgets('pressing OK on an episode adds it immediately, no confirm step',
      (tester) async {
    await seed(tester, [0]);
    await pumpSheet(tester);

    // Episode 1 (the focused one) is not cached yet.
    await pressOk(tester);

    expect(closed, 0, reason: 'the sheet stays open for more episodes');
    expect(manager.completedCount, 2);
    expect(
      manager.completedTaskFor(
        sourceId: 'src1',
        vodId: 'vod1',
        episodeUrl: 'https://cdn.test/1/ep1.m3u8',
        episodeTitle: '第2集',
        episodeIndex: 1,
      ),
      isNotNull,
    );
    expect(find.text('源一 · 线路1 · 已缓存 2/3 集'), findsOneWidget);
    expect(find.text('开始下载'), findsNothing);
  });

  testWidgets('pressing a cached episode does not queue it again',
      (tester) async {
    await seed(tester, [0, 1, 2]);
    await pumpSheet(tester);

    // Episode 1 is focused and cached — OK is a no-op.
    await pressOk(tester);

    expect(manager.completedCount, 3);
    expect(closed, 0);
    expect(find.text('本线路剧集已全部缓存'), findsOneWidget);
  });

  testWidgets('前往下载管理 closes the sheet and opens the downloads page',
      (tester) async {
    await seed(tester, [0]);
    await pumpSheet(tester);

    await tester.tap(find.text('前往下载管理'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(closed, 1);
    expect(controller.page, AppPage.downloads);
  });
}
