import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bear_tv/app.dart';
import 'package:bear_tv/core/app_controller.dart';
import 'package:bear_tv/data/models.dart';

import 'fakes.dart';

/// The rect of whatever currently holds the D-pad focus, in test (post-scale)
/// coordinates — the same space as `tester.getRect`.
Rect _focusRect() => FocusManager.instance.primaryFocus!.rect;

/// True when the focused box overlaps [finder]'s text/element box.
bool _focusIsOn(Finder finder) {
  final focus = _focusRect();
  for (final element in finder.evaluate()) {
    final box = element.renderObject;
    if (box is! RenderBox || !box.hasSize) continue;
    if (focus.overlaps(box.localToGlobal(Offset.zero) & box.size)) return true;
  }
  return false;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

/// Boots the real shell (splash + first feed) so the header and page chrome are
/// laid out exactly as on a device.
Future<void> _boot(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

/// Sends one remote press and lets the focus-scale animation finish, so the
/// next move measures settled rects.
Future<void> _press(WidgetTester tester, LogicalKeyboardKey key,
    {int times = 1}) async {
  for (var i = 0; i < times; i++) {
    await tester.sendKeyEvent(key);
    await tester.pump(const Duration(milliseconds: 400));
  }
}

const _hint = '输入片名 / 关键词（按确定呼出键盘）';

VodItem _item(int i) => VodItem(
      id: i,
      title: '条目 $i',
      en: 'ITEM $i',
      genre: '剧情',
      desc: '简介',
      year: 2020,
      score: '8.0',
      ep: 12,
      hd: 'HD',
      neu: false,
      bgUrl: '',
      cardUrl: '',
      posterUrl: '',
    );

/// Opens the search page on a 1080p canvas.
///
/// [history] seeds the recent-search strip; [systemIme] picks the native-input
/// panel instead of the built-in pinyin keypad; [results] fills the grid.
Future<AppController> _openSearch(
  WidgetTester tester, {
  List<String> history = const [],
  bool systemIme = false,
  List<VodItem> results = const [],
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1920, 1080);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  final c = AppController(repository: FakeRepo());
  addTearDown(c.dispose);
  await tester.pumpWidget(NebulaApp(controller: c));
  await _boot(tester);

  await c.setSearchUseSystemIme(systemIme);
  c.searchHistory = history;
  c.openSearch();
  if (results.isNotEmpty) {
    c.searchQuery = '测试';
    c.searchResults = results;
    c.notifyListeners();
  }
  await _settle(tester);
  return c;
}

void main() {
  /// The reported problem: Up from the keypad's top-right key skipped the
  /// recent-search strip and landed on the mode chips, because nothing
  /// overlapped that column and the default policy falls back to horizontal
  /// distance. Up must climb the rows in order instead.
  testWidgets('Up from the keypad climbs the rows above it', (tester) async {
    await _openSearch(tester, history: const ['三体', '狂飙', '漫长的季节']);

    expect(_focusIsOn(find.text('1')), isTrue, reason: 'entry focus is key 1');
    await _press(tester, LogicalKeyboardKey.arrowRight, times: 9);
    expect(_focusIsOn(find.text('0')), isTrue, reason: 'top-right key');

    // Nearest element of the history row (the strip is left-aligned, the key is
    // at the right edge, so it is the last chip).
    await _press(tester, LogicalKeyboardKey.arrowUp);
    expect(_focusIsOn(find.text('漫长的季节')), isTrue);
    expect(_focusIsOn(find.text('资源直搜')), isFalse,
        reason: 'the history row sits between the keypad and the mode chips');

    // The strip's own 清空 action (first match in tree order: the history one).
    await _press(tester, LogicalKeyboardKey.arrowUp);
    expect(_focusIsOn(find.text('清空').first), isTrue);

    await _press(tester, LogicalKeyboardKey.arrowUp);
    expect(_focusIsOn(find.text('TMDB 匹配')), isTrue);

    // Sideways stays on the chip row (the two chips are one row, not two).
    await _press(tester, LogicalKeyboardKey.arrowRight);
    expect(_focusIsOn(find.text('资源直搜')), isTrue);
    await _press(tester, LogicalKeyboardKey.arrowLeft);
    expect(_focusIsOn(find.text('TMDB 匹配')), isTrue);

    await _press(tester, LogicalKeyboardKey.arrowUp);
    expect(_focusIsOn(find.text('🔍')), isTrue);
  });

  testWidgets('with no history, Up goes straight to the mode chips',
      (tester) async {
    await _openSearch(tester);

    await _press(tester, LogicalKeyboardKey.arrowUp);
    expect(_focusIsOn(find.text('TMDB 匹配')), isTrue);

    await _press(tester, LogicalKeyboardKey.arrowUp);
    expect(_focusIsOn(find.text('🔍')), isTrue);
  });

  /// Same rule downwards: every row is one press away, and the column is kept
  /// (the default policy already did this inside the keypad — the regression
  /// here is only that the banded rule must not break it).
  testWidgets('Down from the keypad follows the same column', (tester) async {
    await _openSearch(tester);

    await _press(tester, LogicalKeyboardKey.arrowRight, times: 9);
    expect(_focusIsOn(find.text('0')), isTrue);

    await _press(tester, LogicalKeyboardKey.arrowDown);
    expect(_focusIsOn(find.text('p')), isTrue);

    await _press(tester, LogicalKeyboardKey.arrowDown);
    expect(_focusIsOn(find.text('l')), isTrue);

    await _press(tester, LogicalKeyboardKey.arrowDown);
    expect(_focusIsOn(find.text('m')), isTrue);

    // Last row: the action keys. The page heading is also "搜索", so take the
    // last one (built after it, in the keypad).
    await _press(tester, LogicalKeyboardKey.arrowDown);
    expect(_focusIsOn(find.text('搜索').last), isTrue);
  });

  /// The two halves are separate lanes: a vertical press on a poster must not
  /// land on the left panel's chips, and the grid must keep its column.
  testWidgets('the result grid keeps its column and leaves upward to the header',
      (tester) async {
    await _openSearch(tester, results: [for (var i = 0; i < 16; i++) _item(i)]);

    await _press(tester, LogicalKeyboardKey.arrowRight, times: 10);
    expect(_focusIsOn(find.text('条目 0')), isTrue);

    await _press(tester, LogicalKeyboardKey.arrowRight);
    expect(_focusIsOn(find.text('条目 1')), isTrue);

    final before = _focusRect();
    await _press(tester, LogicalKeyboardKey.arrowDown);
    final after = _focusRect();
    expect(after.top, greaterThan(before.top), reason: 'moved to a lower row');
    expect(after.center.dx, closeTo(before.center.dx, 24),
        reason: 'the column is preserved');
    expect(_focusIsOn(find.text('TMDB 匹配')), isFalse,
        reason: 'vertical moves stay inside the grid lane');

    // Back up to the same card, then out of the grid to the header.
    await _press(tester, LogicalKeyboardKey.arrowUp);
    expect(_focusIsOn(find.text('条目 1')), isTrue);
    await _press(tester, LogicalKeyboardKey.arrowUp);
    expect(_focusIsOn(find.text('🔍')), isTrue);
  });

  /// The native-input panel is the default on phones; it must walk the same
  /// ladder (box → history → submit) rather than jumping around.
  testWidgets('the system-IME panel walks box → history → submit',
      (tester) async {
    await _openSearch(
      tester,
      systemIme: true,
      history: const ['三体', '狂飙', '漫长的季节'],
    );

    expect(_focusIsOn(find.text(_hint)), isTrue, reason: 'entry focus is the box');

    await _press(tester, LogicalKeyboardKey.arrowDown);
    expect(_focusIsOn(find.text('清空').first), isTrue);

    await _press(tester, LogicalKeyboardKey.arrowDown);
    expect(_focusIsOn(find.text('狂飙')), isTrue);

    await _press(tester, LogicalKeyboardKey.arrowDown);
    expect(_focusIsOn(find.text('搜索').last), isTrue);

    // And back up the same way.
    await _press(tester, LogicalKeyboardKey.arrowUp);
    expect(_focusIsOn(find.text('漫长的季节')), isTrue,
        reason: 'the chip nearest the submit button, not the first one');
    await _press(tester, LogicalKeyboardKey.arrowUp);
    expect(_focusIsOn(find.text('清空').first), isTrue);
    await _press(tester, LogicalKeyboardKey.arrowUp);
    expect(_focusIsOn(find.text(_hint)), isTrue);
  });
}
