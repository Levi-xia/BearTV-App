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

/// The action tile that currently owns the D-pad focus, if any.
String? _focusedAction() {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context is! Element) return null;
  String? found;
  context.visitAncestorElements((element) {
    final key = element.widget.key;
    if (key is ValueKey<String> && key.value.startsWith('playAction:')) {
      found = key.value.substring('playAction:'.length);
      return false;
    }
    return true;
  });
  return found;
}

void main() {
  testWidgets('an error already present on entry keeps focus on retry',
      (tester) async {
    final c = _controller();
    addTearDown(c.dispose);
    c.playError = 'entry failed';
    await _pump(tester, c);
    expect(FocusManager.instance.primaryFocus?.debugLabel,
        'playbackFailureAction:0');
    await _key(tester, LogicalKeyboardKey.arrowRight);
    expect(FocusManager.instance.primaryFocus?.debugLabel,
        'playbackFailureAction:2');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final action in ['episode', 'line']) {
    testWidgets('switching $action clears the previous playback error overlay',
        (tester) async {
      final c = _controller(lines: 2);
      addTearDown(c.dispose);
      c.playError = 'previous failure';
      await _pump(tester, c);
      expect(find.textContaining('previous failure'), findsOneWidget);
      if (action == 'episode') {
        await c.selectEpisode(1);
      } else {
        await c.selectLine(1);
      }
      await tester.pump();
      expect(c.playError, isNull);
      expect(c.player.value.playing, isTrue);
      expect(find.textContaining('previous failure'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('playback error remains visible while backend reports playing',
      (tester) async {
    final c = _controller(lines: 2);
    addTearDown(c.dispose);
    final player = c.player as _IdlePlayer;
    player._set(
        player.value.copyWith(ready: true, playing: true, error: 'HTTP 403'));
    await _pump(tester, c);
    expect(find.textContaining('HTTP 403'), findsOneWidget);
    expect(find.text('重试当前播放'), findsOneWidget);
    expect(find.text('尝试下一线路'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final fullscreen in [false, true]) {
    testWidgets(
        'failure actions own focus and support remote navigation fullscreen=$fullscreen',
        (tester) async {
      final c = _controller(lines: 2);
      c.fullscreen = fullscreen;
      addTearDown(c.dispose);
      await _pump(tester, c);
      final player = c.player as _IdlePlayer;
      player._set(player.value.copyWith(error: 'open failed'));
      await tester.pump();
      await tester.pump();
      expect(FocusManager.instance.primaryFocus?.debugLabel,
          'playbackFailureAction:0');
      await _key(tester, LogicalKeyboardKey.arrowRight);
      expect(FocusManager.instance.primaryFocus?.debugLabel,
          'playbackFailureAction:1');
      await _key(tester, LogicalKeyboardKey.arrowRight);
      expect(FocusManager.instance.primaryFocus?.debugLabel,
          'playbackFailureAction:2');
      await _key(tester, LogicalKeyboardKey.arrowLeft);
      await _key(tester, LogicalKeyboardKey.enter);
      expect(c.lineIndex, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('buffering is visible even when backend reports playing',
      (tester) async {
    final c = _controller();
    addTearDown(c.dispose);
    final player = c.player as _IdlePlayer;
    player._set(
        player.value.copyWith(ready: true, playing: true, buffering: true));
    await _pump(tester, c);
    expect(find.text('缓冲中…'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('held Right enters the action grid without skipping tiles',
      (tester) async {
    final c = _controller();
    addTearDown(c.dispose);
    await _pump(tester, c);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    for (var i = 0; i < 5; i++) {
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
    expect(_focusedAction(), 'download');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('closing a tool restores the tile that opened it',
      (tester) async {
    final c = _controller();
    addTearDown(c.dispose);
    await _pump(tester, c);
    await _key(tester, LogicalKeyboardKey.arrowRight);
    await _key(tester, LogicalKeyboardKey.arrowRight);
    expect(_focusedAction(), 'speed');
    await _key(tester, LogicalKeyboardKey.enter);
    c.backFromKey();
    await tester.pump();
    expect(_focusedAction(), 'speed');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final action in ['speed', 'danmaku', 'sources', 'skip']) {
    testWidgets('nested $action sheet suspends menu idle timeout',
        (tester) async {
      final c = _controller(lines: 2);
      addTearDown(c.dispose);
      c.fullscreen = true;
      await _pump(tester, c);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(seconds: 4));
      await tester.tap(_tile(action));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(seconds: 10));
      expect(find.text('播放设置'), findsOneWidget);
      // Returning to the menu starts a fresh five-second interval.
      c.fullscreenBackInterceptor!();
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));
      expect(find.text('播放设置'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('播放设置'), findsNothing);
      expect(c.fullscreen, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('fullscreen menu idle timeout resets on consumed chip keys',
      (tester) async {
    final c = _controller();
    addTearDown(c.dispose);
    c.fullscreen = true;
    await _pump(tester, c);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('播放设置'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('播放设置'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('播放设置'), findsNothing);
    expect(c.fullscreen, isTrue);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'fullscreenPlayer');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('fullscreen episode drawer closes after five idle seconds',
      (tester) async {
    final c = _controller();
    addTearDown(c.dispose);
    c.fullscreen = true;
    await _pump(tester, c);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(c.fullscreenBackInterceptor!(), isTrue);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    expect(c.fullscreenBackInterceptor!(), isFalse);
    expect(c.fullscreen, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('holding left/right accumulates repeated ten-second seeks',
      (tester) async {
    final c = _controller();
    addTearDown(c.dispose);
    c.fullscreen = true;
    await _pump(tester, c);
    final start = c.player.value.position;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
    for (var i = 0; i < 5; i++) {
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
    expect(c.player.value.position, start + const Duration(seconds: 60));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowLeft);
    for (var i = 0; i < 2; i++) {
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowLeft);
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);
    expect(c.player.value.position, start + const Duration(seconds: 30));
    await tester.pumpWidget(const SizedBox.shrink());
  });

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

    // Focus opens on the rate already in use (1.0x), so OK is a no-op …
    await _key(tester, LogicalKeyboardKey.enter);
    expect(c.speed, 1.0);
    // … and the arrows move relative to it.
    await _key(tester, LogicalKeyboardKey.arrowLeft);
    await _key(tester, LogicalKeyboardKey.enter);
    expect(c.speed, 0.75);
    // Picking a rate keeps the sheet usable — focus stays on the chip grid.
    await _key(tester, LogicalKeyboardKey.arrowRight);
    await _key(tester, LogicalKeyboardKey.enter);
    expect(c.speed, 1.0);

    // Back closes only the sheet and keeps the user on the play page.
    c.backFromKey();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('倍速'), findsNothing);
    expect(c.page, AppPage.play);

    // Return to the tile that opened the sheet, including pointer activation.
    // OK opens speed again instead of jumping to the grid's first tile.
    expect(_focusedAction(), 'speed');
    await _key(tester, LogicalKeyboardKey.select);
    expect(find.text('倍速'), findsOneWidget);
  });

  testWidgets('Right walks the panel one tile per press — no dead press',
      (tester) async {
    final c = _controller(lines: 2);
    addTearDown(c.dispose);
    await _pump(tester, c);

    // Entry: the player owns focus, and nothing on the panel is highlighted.
    expect(_focusedAction(), isNull);

    // Player → first tile (切换资源), then exactly one tile per press — the
    // shared-node re-parenting used to cost a dead press right here.
    await _key(tester, LogicalKeyboardKey.arrowRight);
    expect(_focusedAction(), 'sources');
    await _key(tester, LogicalKeyboardKey.arrowRight);
    expect(_focusedAction(), 'download');
    await _key(tester, LogicalKeyboardKey.arrowRight);
    expect(_focusedAction(), 'speed');
    // Left walks back the same way.
    await _key(tester, LogicalKeyboardKey.arrowLeft);
    expect(_focusedAction(), 'download');
    await _key(tester, LogicalKeyboardKey.arrowLeft);
    expect(_focusedAction(), 'sources');
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

  testWidgets('切换资源 opens on the line being played', (tester) async {
    final c = _controller(lines: 2);
    addTearDown(c.dispose);
    c.lineIndex = 1;
    await _pump(tester, c);

    await tester.tap(_tile('sources'));
    await tester.pump(const Duration(milliseconds: 300));
    // Focus starts on 线路2 (the line in use): OK re-selects it, one ← moves
    // to 线路1.
    await _key(tester, LogicalKeyboardKey.enter);
    expect(c.lineIndex, 1);
    await _key(tester, LogicalKeyboardKey.arrowLeft);
    await _key(tester, LogicalKeyboardKey.enter);
    expect(c.lineIndex, 0);
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
    // Opens on the current rate (1.0x); ← then picks 0.75x.
    await _key(tester, LogicalKeyboardKey.arrowLeft);
    await _key(tester, LogicalKeyboardKey.enter);
    expect(c.speed, 0.75);

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
