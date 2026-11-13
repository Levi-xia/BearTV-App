import 'package:bear_tv/core/app_controller.dart';
import 'package:bear_tv/core/app_scope.dart';
import 'package:bear_tv/data/kv_store.dart';
import 'package:bear_tv/data/models.dart';
import 'package:bear_tv/data/settings_store.dart';
import 'package:bear_tv/data/vod/cms_models.dart';
import 'package:bear_tv/player/player_controller.dart';
import 'package:bear_tv/screens/play_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Player with no timers and no I/O, so a widget test can finish cleanly.
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
  id: 1,
  mediaType: 'tv',
  title: '测试剧',
  en: '',
  genre: '剧情',
  desc: '一段剧集简介。',
  year: 2020,
  score: '8.0',
  ep: 20,
  hd: 'HD',
  neu: false,
  bgUrl: '',
  cardUrl: '',
  posterUrl: '',
);

VodDetail _detail({int lines = 1}) => VodDetail(
      sourceId: 'a',
      sourceName: '源A',
      vodId: '1',
      title: '测试剧',
      playLines: [
        for (var l = 0; l < lines; l++)
          PlayLine(
            name: '线路${l + 1}',
            episodes: [
              for (var i = 0; i < 6; i++)
                Episode(title: '第${i + 1}集', url: 'http://x/$l/$i.m3u8'),
            ],
          ),
      ],
    );

AppController _controller({int lines = 1}) {
  final c = AppController(
    settings:
        SettingsStore(seedDefaultKey: false, store: MemoryKeyValueStore()),
    player: _IdlePlayer(),
  );
  c.currentItem = _item;
  c.currentDetail = _detail(lines: lines);
  c.episodeIndex = 0;
  c.page = AppPage.play;
  return c;
}

Future<void> _pump(WidgetTester tester, AppController c) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1920, 1080);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: AppScope(
        controller: c,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: FocusScope(
            child: FocusTraversalGroup(child: PlayScreen()),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Finder _tile(String action) => find.byKey(ValueKey('playAction:$action'));

Future<void> _key(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pump(const Duration(milliseconds: 60));
}

void main() {
  testWidgets('side panel is an icon-only grid; sheets open focused',
      (tester) async {
    final c = _controller();
    addTearDown(c.dispose);
    await _pump(tester, c);

    // One tile per action; 切换资源 stays hidden without lines or alternatives.
    expect(_tile('download'), findsOneWidget);
    expect(_tile('speed'), findsOneWidget);
    expect(_tile('skip'), findsOneWidget);
    expect(_tile('danmaku'), findsOneWidget);
    expect(_tile('sources'), findsNothing);
    // Icon only — the grid carries no text at all.
    for (final t in ['下载', '倍速', '片头片尾', '弹幕']) {
      expect(find.text(t), findsNothing, reason: '$t should be glyph-only');
    }

    // 倍速 opens a modal sheet with no 关闭 button: Back is the way out.
    await tester.tap(_tile('speed'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('倍速'), findsOneWidget);
    expect(find.text('关闭'), findsNothing);

    // Focus is already on the first chip, so OK acts without any arrow press.
    await _key(tester, LogicalKeyboardKey.enter);
    expect(c.speed, 0.5);
    await _key(tester, LogicalKeyboardKey.arrowRight);
    await _key(tester, LogicalKeyboardKey.enter);
    expect(c.speed, 0.75);

    // Back closes only the sheet and keeps the user on the play page.
    c.backFromKey();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('倍速'), findsNothing);
    expect(c.page, AppPage.play);

    // Focus is back on the grid, so OK re-opens a sheet instead of falling into
    // the player behind it. (With one line the first tile is 下载.)
    await _key(tester, LogicalKeyboardKey.select);
    expect(find.text('下载选集'), findsOneWidget);
  });

  testWidgets('线路 lives inside the 切换资源 sheet', (tester) async {
    final c = _controller(lines: 2);
    addTearDown(c.dispose);
    await _pump(tester, c);

    // One entry for both: multiple lines alone are enough to show it.
    expect(_tile('sources'), findsOneWidget);
    await tester.tap(_tile('sources'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('切换资源'), findsOneWidget);
    expect(find.text('线路'), findsOneWidget);
    expect(find.text('线路1'), findsOneWidget);
    expect(find.text('线路2'), findsOneWidget);

    // First chip already has focus, so ↔ + OK switches the line.
    await _key(tester, LogicalKeyboardKey.arrowRight);
    await _key(tester, LogicalKeyboardKey.enter);
    expect(c.lineIndex, 1);
  });

  testWidgets('下载 opens the episode sheet focused — no 下载管理 entry',
      (tester) async {
    final c = _controller();
    addTearDown(c.dispose);
    await _pump(tester, c);

    expect(find.text('下载管理'), findsNothing);
    await tester.tap(_tile('download'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('下载选集'), findsOneWidget);
    // The sheet claims focus on the current episode, so the D-pad works.
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'downloadEpisode0');

    c.backFromKey();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('下载选集'), findsNothing);
    expect(c.page, AppPage.play);
  });

  testWidgets('fullscreen 上键 menu reuses the same action grid', (tester) async {
    final c = _controller(lines: 2);
    addTearDown(c.dispose);
    c.fullscreen = true;
    await _pump(tester, c);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    // One frame to mount the sheet, then the 240ms slide-up.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('播放设置'), findsOneWidget);
    expect(_tile('download'), findsOneWidget);
    expect(_tile('speed'), findsOneWidget);

    await tester.tap(_tile('speed'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('倍速'), findsOneWidget);
    expect(find.text('关闭'), findsNothing);
    await _key(tester, LogicalKeyboardKey.enter);
    expect(c.speed, 0.5);

    // Back closes the sheet, keeps the menu, and puts focus back on the grid:
    // OK then opens the first tile (切换资源).
    c.backFromKey();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('倍速'), findsNothing);
    expect(find.text('播放设置'), findsOneWidget, reason: 'menu stays open');

    await _key(tester, LogicalKeyboardKey.select);
    expect(find.text('切换资源'), findsOneWidget);
    expect(find.text('线路'), findsOneWidget);
    expect(find.text('播放设置'), findsOneWidget);
  });
}
