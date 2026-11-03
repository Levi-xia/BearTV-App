import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bear_tv/core/danmaku_controller.dart';
import 'package:bear_tv/data/danmaku/danmaku_models.dart';
import 'package:bear_tv/player/player_controller.dart';
import 'package:bear_tv/widgets/danmaku_overlay.dart';

/// Player whose position only changes when the test reports it — mimics
/// [VideoAdapter], which polls the backend instead of pushing every frame.
class _PolledPlayer extends ChangeNotifier implements PlayerController {
  PlayerValue _value = const PlayerValue(
    ready: true,
    duration: Duration(minutes: 45),
  );

  @override
  PlayerValue get value => _value;

  /// Publish one poll result, exactly like the adapter's periodic read.
  void report(Duration position, {bool playing = true}) {
    _value = _value.copyWith(position: position, playing: playing);
    notifyListeners();
  }

  @override
  Future<void> open(String? url, {Map<String, String>? headers}) async {}

  @override
  Future<void> play() async => report(_value.position);

  @override
  Future<void> pause() async => report(_value.position, playing: false);

  @override
  Future<void> togglePlay() async {}

  @override
  Future<void> seekTo(Duration position) async => report(position);

  @override
  Future<void> setSpeed(double speed) async {
    _value = _value.copyWith(speed: speed);
    notifyListeners();
  }
}

class _FakeDanmaku extends DanmakuController {
  _FakeDanmaku(this._items);

  final List<DanmakuItem> _items;

  static const _cfg = DanmakuConfig(scrollSeconds: 6, area: 1.0);

  @override
  List<DanmakuItem> get items => _items;

  @override
  DanmakuConfig get config => _cfg;

  @override
  int get epoch => 0;
}

class _FakeClock {
  DateTime _now = DateTime.utc(2026, 1, 1);

  DateTime now() => _now;

  void advance(int ms) => _now = _now.add(Duration(milliseconds: ms));
}

const _frameMs = 400;
const _step = Duration(milliseconds: _frameMs);

const _threeAtStart = [
  DanmakuItem(time: 0.0, text: '一'),
  DanmakuItem(time: 0.1, text: '二'),
  DanmakuItem(time: 0.2, text: '三'),
];

const _withSeek = [
  DanmakuItem(time: 0.0, text: '一'),
  DanmakuItem(time: 0.1, text: '二'),
  DanmakuItem(time: 0.2, text: '三'),
  DanmakuItem(time: 30.0, text: '四'),
];

Future<void> _mount(
  WidgetTester tester,
  _PolledPlayer player,
  _FakeDanmaku danmaku,
  _FakeClock clock,
) async {
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MediaQuery(
      data: const MediaQueryData(size: Size(800, 450), devicePixelRatio: 1.0),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 800,
            height: 450,
            child: DanmakuOverlay(
              player: player,
              danmaku: danmaku,
              clock: clock.now,
            ),
          ),
        ),
      ),
    ),
  );
}

int _active(WidgetTester tester) =>
    (tester.state(find.byType(DanmakuOverlay)) as dynamic).debugActiveCount
        as int;

/// One 400 ms frame with the injected wall clock advanced in lockstep, so the
/// player's reported position and the overlay's interpolated clock share a
/// timeline.
Future<void> _frame(WidgetTester tester, _FakeClock clock) async {
  clock.advance(_frameMs);
  await tester.pump(_step);
}

/// Mount, start playback at 0, and pump until the three comments are flying.
Future<void> _start(WidgetTester tester, _PolledPlayer player,
    _FakeDanmaku danmaku, _FakeClock clock) async {
  await _mount(tester, player, danmaku, clock);
  clock.advance(_frameMs);
  player.report(Duration.zero);
  await tester.pump(_step); // ticker starts here
  await _frame(tester, clock); // the first comments spawn
}

void main() {
  testWidgets('a slow-decoding stretch never wipes the flying set',
      (tester) async {
    final player = _PolledPlayer();
    final danmaku = _FakeDanmaku(_threeAtStart);
    final clock = _FakeClock();
    addTearDown(player.dispose);
    addTearDown(danmaku.dispose);

    await _start(tester, player, danmaku, clock);
    expect(_active(tester), 3);

    final seen = <int>[];
    var videoMs = 0.0;
    for (var i = 0; i < 12; i++) {
      // A weak box decodes at a fraction of wall time for ~3 s: the reported
      // position creeps while the wall clock runs, so the two drift apart
      // without playback ever jumping.
      final slow = i >= 2 && i < 10;
      videoMs += _frameMs * (slow ? 0.35 : 1.0);
      player.report(Duration(milliseconds: videoMs.round()));
      await _frame(tester, clock);
      seen.add(_active(tester));
    }

    // Before the fix the growing drift was read as a seek: every comment was
    // cleared and the cursor re-seeked, so they died about a quarter of the way
    // across and popped back in from the right edge. They must now fly to the
    // end of their traversal untouched.
    expect(seen, everyElement(3), reason: 'comments were wiped mid-flight: $seen');
  });

  testWidgets('a real seek still clears and re-seeks the stream',
      (tester) async {
    final player = _PolledPlayer();
    final danmaku = _FakeDanmaku(_withSeek);
    final clock = _FakeClock();
    addTearDown(player.dispose);
    addTearDown(danmaku.dispose);

    await _start(tester, player, danmaku, clock);
    expect(_active(tester), 3);

    // Jump 30 s ahead: the comments on screen belong to another moment.
    player.report(const Duration(seconds: 30));
    expect(_active(tester), 0);

    await _frame(tester, clock);
    await _frame(tester, clock);
    await _frame(tester, clock);
    // Only the comment at 30 s, and no replay of the earlier ones.
    expect(_active(tester), 1);
  });

  testWidgets('a rebuffer that freezes the position does not clear comments',
      (tester) async {
    final player = _PolledPlayer();
    final danmaku = _FakeDanmaku(_threeAtStart);
    final clock = _FakeClock();
    addTearDown(player.dispose);
    addTearDown(danmaku.dispose);

    await _start(tester, player, danmaku, clock);
    expect(_active(tester), 3);

    // The backend keeps reporting the same position while it rebuffers, so the
    // drift grows while the playback position stands still.
    for (var i = 0; i < 6; i++) {
      player.report(const Duration(milliseconds: 400));
      await _frame(tester, clock);
      expect(_active(tester), 3, reason: 'wiped on rebuffer report #$i');
    }

    // Playback resumes — the comments are still mid-flight.
    player.report(const Duration(milliseconds: 800));
    await _frame(tester, clock);
    expect(_active(tester), 3);
  });
}
