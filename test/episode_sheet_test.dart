import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bear_tv/core/app_controller.dart';
import 'package:bear_tv/core/app_scope.dart';
import 'package:bear_tv/data/kv_store.dart';
import 'package:bear_tv/data/models.dart';
import 'package:bear_tv/data/settings_store.dart';
import 'package:bear_tv/data/vod/cms_models.dart';
import 'package:bear_tv/player/player_controller.dart';
import 'package:bear_tv/screens/play_screen.dart';

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
  desc: '',
  year: 2020,
  score: '8.0',
  ep: 20,
  hd: 'HD',
  neu: false,
  bgUrl: '',
  cardUrl: '',
  posterUrl: '',
);

VodDetail _detail(int episodes) => VodDetail(
      sourceId: 'a',
      sourceName: '源A',
      vodId: '1',
      title: '测试剧',
      playLines: [
        PlayLine(
          name: '线路1',
          episodes: [
            for (var i = 0; i < episodes; i++)
              Episode(title: '第${i + 1}集', url: 'http://x/$i.m3u8'),
          ],
        ),
      ],
    );

/// A controller parked in fullscreen on a resolved title.
AppController _controller({int episodes = 20, int episodeIndex = 0}) {
  final c = AppController(
    settings: SettingsStore(seedDefaultKey: false, store: MemoryKeyValueStore()),
    player: _IdlePlayer(),
  );
  c.currentItem = _item;
  c.currentDetail = _detail(episodes);
  c.episodeIndex = episodeIndex;
  c.fullscreen = true;
  return c;
}

Future<void> _pump(WidgetTester tester, AppController c) async {
  // TV-sized surface: a RenderFlex overflow at 1080p would fail the test.
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1920, 1080);
  addTearDown(tester.view.reset);
  // MaterialApp supplies the arrow-key → directional-traversal shortcuts the
  // real app gets from `MaterialApp` in app.dart; without it arrow presses are
  // inert in a widget test. The FocusScope + FocusTraversalGroup mirror Shell's
  // scaffolding so traversal scopes match production.
  await tester.pumpWidget(
    MaterialApp(
      home: AppScope(
        controller: c,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: FocusScope(
            child: FocusTraversalGroup(child: const PlayScreen()),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 260)); // drawer slide-in
}

void main() {
  testWidgets('↓ opens the 选集 drawer with a focused 播放下一集 shortcut',
      (tester) async {
    final c = _controller();
    addTearDown(c.dispose);
    await _pump(tester, c);

    await _press(tester, LogicalKeyboardKey.arrowDown);

    expect(find.text('选集'), findsOneWidget);
    expect(find.text('▶ 播放下一集'), findsOneWidget);
    // "↓ then OK" must be enough to continue watching.
    expect(tester.binding.focusManager.primaryFocus?.debugLabel,
        'episodeSheetNext');

    await _press(tester, LogicalKeyboardKey.select);

    expect(c.episodeIndex, 1);
    expect(find.text('▶ 播放下一集'), findsNothing); // drawer closed
  });

  testWidgets('the shortcut is hidden on the last episode', (tester) async {
    final c = _controller(episodeIndex: 19);
    addTearDown(c.dispose);
    await _pump(tester, c);

    await _press(tester, LogicalKeyboardKey.arrowDown);

    expect(find.text('选集'), findsOneWidget);
    expect(find.text('▶ 播放下一集'), findsNothing);
  });

  testWidgets('↓ falls back to the progress OSD with nothing to pick',
      (tester) async {
    final c = _controller(episodes: 1);
    addTearDown(c.dispose);
    await _pump(tester, c);

    await _press(tester, LogicalKeyboardKey.arrowDown);

    expect(find.text('选集'), findsNothing);
    expect(find.text('00:12:00'), findsOneWidget); // progress elapsed time
  });

  testWidgets('← never leaves the grid for the invisible fullscreen root',
      (tester) async {
    final c = _controller();
    addTearDown(c.dispose);
    await _pump(tester, c);

    final focus = tester.binding.focusManager;
    await _press(tester, LogicalKeyboardKey.arrowDown); // open the sheet
    await _press(tester, LogicalKeyboardKey.arrowDown); // shortcut → grid
    expect(focus.primaryFocus?.debugLabel, isNot('episodeSheetNext'));

    // Walk the row leftwards. Every stop must still be a cell (150 wide); the
    // player's root node is the full 1920-wide screen and must never be hit —
    // landing on it dropped the highlight and dead-ended the D-pad.
    for (var i = 0; i < 12; i++) {
      await _press(tester, LogicalKeyboardKey.arrowLeft);
      final f = focus.primaryFocus;
      expect(f?.debugLabel, isNot('fullscreenPlayer'), reason: 'step $i');
      expect(f!.rect.width, lessThan(400), reason: 'step $i → ${f.rect}');
    }

    // ...and back to the right, same rule.
    for (var i = 0; i < 12; i++) {
      await _press(tester, LogicalKeyboardKey.arrowRight);
      expect(focus.primaryFocus!.rect.width, lessThan(400), reason: 'step $i');
    }
  });

  testWidgets('↑ still opens 播放设置, which no longer hosts 选集',
      (tester) async {
    final c = _controller();
    addTearDown(c.dispose);
    await _pump(tester, c);

    await _press(tester, LogicalKeyboardKey.arrowUp);

    expect(find.text('播放设置'), findsOneWidget);
    expect(find.text('选集'), findsNothing);
  });
}
