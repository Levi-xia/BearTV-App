import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bear_tv/core/app_controller.dart';
import 'package:bear_tv/data/history_store.dart';
import 'package:bear_tv/data/kv_store.dart';
import 'package:bear_tv/data/models.dart';
import 'package:bear_tv/data/settings_store.dart';
import 'package:bear_tv/data/vod/cms_models.dart';
import 'package:bear_tv/data/vod/vod_repository.dart';
import 'package:bear_tv/player/player_controller.dart';

/// [VodRepository] with canned details and no network. Every lookup is keyed by
/// `vodId` so a test can distinguish "source A's resource" from source B's.
class FakeVod extends VodRepository {
  FakeVod(this.detailsByVodId, {this.delay});

  final Map<String, VodDetail> detailsByVodId;
  final Future<void>? delay;

  @override
  Future<VodDetail?> detail(CmsSite site, String vodId) async {
    if (delay != null) await delay;
    return detailsByVodId[vodId];
  }

  @override
  Future<VodDetail?> resolveByTitle(String title, List<CmsSite> sites) async {
    if (delay != null) await delay;
    return detailsByVodId.values.isEmpty ? null : detailsByVodId.values.first;
  }

  @override
  Future<List<ResourceOption>> loadResourceOptions(
    String title,
    List<CmsSite> sites, {
    VodDetail? current,
  }) async =>
      const [];
}

class _RacingVod extends FakeVod {
  _RacingVod() : super({});
  final recorded = Completer<VodDetail?>();
  final searched = Completer<VodDetail?>();
  int searches = 0;
  int details = 0;
  @override
  Future<VodDetail?> detail(CmsSite site, String vodId) {
    details++;
    return recorded.future;
  }

  @override
  Future<VodDetail?> resolveByTitle(String title, List<CmsSite> sites) {
    searches++;
    return searched.future;
  }
}

/// A player whose [open] stays pending until the test releases [gate], then
/// reports "ready" at position 0 — the same shape as a slow CMS stream in
/// `VideoAdapter` (initialize → ready → the caller seeks to the resume point).
class GatedPlayer extends ChangeNotifier implements PlayerController {
  GatedPlayer(this.gate);

  final Completer<void> gate;
  int plays = 0;
  int speeds = 0;
  final receivedHeaders = <Map<String, String>?>[];
  PlayerValue _value = const PlayerValue();

  @override
  PlayerValue get value => _value;

  void _set(PlayerValue v) {
    _value = v;
    notifyListeners();
  }

  @override
  Future<void> open(String? url, {Map<String, String>? headers}) async {
    receivedHeaders.add(headers);
    _set(const PlayerValue());
    if (url == null || url.isEmpty) return;
    await gate.future;
    _set(const PlayerValue(ready: true, duration: Duration(minutes: 45)));
  }

  @override
  Future<void> seekTo(Duration position) async =>
      _set(_value.copyWith(position: position));

  @override
  Future<void> play() async {
    plays++;
    _set(_value.copyWith(playing: true));
  }

  @override
  Future<void> pause() async => _set(_value.copyWith(playing: false));

  @override
  Future<void> togglePlay() async {}

  @override
  Future<void> setSpeed(double speed) async {
    speeds++;
    _set(_value.copyWith(speed: speed));
  }
}

class _FailingStartupPlayer extends GatedPlayer {
  _FailingStartupPlayer(this.stage) : super(Completer<void>()..complete());
  final String stage;

  @override
  Future<void> seekTo(Duration position) async {
    if (stage == 'seek') throw StateError('seek failed');
    await super.seekTo(position);
  }

  @override
  Future<void> setSpeed(double speed) async {
    if (stage == 'speed') throw StateError('speed failed');
    await super.setSpeed(speed);
  }

  @override
  Future<void> play() async {
    if (stage == 'play') throw StateError('play failed');
    await super.play();
  }
}

/// Controllable wall clock: progress saving is throttled to 5s of *real* time,
/// so tests advance this instead of sleeping.
class _Clock {
  DateTime now = DateTime(2026, 1, 1);
  DateTime call() => now;
  void advance([int seconds = 6]) => now = now.add(Duration(seconds: seconds));
}

const _siteA =
    CmsSite(id: 'a', name: '源A', api: 'https://a.example/api.php/provide/vod');
const _siteB =
    CmsSite(id: 'b', name: '源B', api: 'https://b.example/api.php/provide/vod');

final _detailA = _detail('a', '源A', '1');
final _detailB = _detail('b', '源B', '2');

VodDetail _detail(String sourceId, String sourceName, String vodId) =>
    VodDetail(
      sourceId: sourceId,
      sourceName: sourceName,
      vodId: vodId,
      title: '测试剧',
      playLines: [
        PlayLine(
          name: '线路1',
          episodes: [
            for (var i = 0; i < 20; i++)
              Episode(title: '第${i + 1}集', url: 'http://x/$vodId/$i.m3u8'),
          ],
        ),
      ],
    );

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

/// The synthetic item built by `openCmsHit`: its genre carries the source name.
const _cmsItem = VodItem(
  id: 1,
  mediaType: 'cms:a',
  title: '测试剧',
  en: '',
  genre: '源A',
  desc: '',
  year: 0,
  score: '—',
  ep: 0,
  hd: 'HD',
  neu: false,
  bgUrl: '',
  cardUrl: '',
  posterUrl: '',
);

const _saved = HistoryEntry(
  item: _item,
  sourceId: 'a',
  sourceName: '源A',
  vodId: '1',
  episodeIndex: 5,
  positionMs: 600000,
  durationMs: 1800000,
);

AppController _controller({
  Future<void>? delay,
  PlayerController? player,
  _Clock? clock,
  VodRepository? vod,
  Duration resolveTimeout = const Duration(seconds: 8),
  Duration recordedSourceGrace = const Duration(milliseconds: 800),
}) {
  final settings =
      SettingsStore(seedDefaultKey: false, store: MemoryKeyValueStore());
  return AppController(
    settings: settings,
    history: HistoryStore(),
    vod: vod ?? FakeVod({'1': _detailA, '2': _detailB}, delay: delay),
    player: player,
    clock: clock?.call,
    resolveTimeout: resolveTimeout,
    recordedSourceGrace: recordedSourceGrace,
  );
}

Future<void> _seedSites(AppController c) async {
  await c.settings.setCmsSites([_siteA, _siteB]);
  await c.settings.setSelectedSourceIds(['a', 'b']);
}

/// Simulates one throttled player tick (6s later) at the current position.
Future<void> _tick(AppController c, _Clock clock) async {
  clock.advance();
  await c.player.seekTo(c.player.value.position);
  await pumpEventQueue();
}

final _switchToB = ResourceOption(
  sourceId: 'b',
  sourceName: '源B',
  vodId: '2',
  title: '测试剧',
  episodeCount: 20,
  available: true,
  detail: _detailB,
);

void main() {
  for (final stage in ['seek', 'speed', 'play']) {
    test('startup $stage failure becomes an actionable page error', () async {
      final player = _FailingStartupPlayer(stage);
      final c = _controller(player: player);
      addTearDown(c.dispose);
      await c.init();
      await _seedSites(c);
      c.currentItem = _item;
      c.currentDetail = _detailA;
      c.page = AppPage.play;
      player._set(const PlayerValue(position: Duration(minutes: 1)));
      await c.retryCurrentPlayback();
      expect(c.playError, contains('播放启动失败'));
    });
  }

  test('manual next-line recovery preserves the episode and position',
      () async {
    final gate = Completer<void>()..complete();
    final player = GatedPlayer(gate);
    final c = _controller(player: player);
    addTearDown(c.dispose);
    await c.init();
    await _seedSites(c);
    c.page = AppPage.play;
    c.currentItem = _item;
    c.currentDetail = VodDetail(
      sourceId: 'a',
      sourceName: '源A',
      vodId: '1',
      title: '测试剧',
      playLines: [..._detailA.playLines, ..._detailB.playLines],
    );
    c.episodeIndex = 5;
    player._set(const PlayerValue(
        ready: true,
        position: Duration(minutes: 10),
        duration: Duration(minutes: 45)));
    await c.retryNextLine();
    expect(c.lineIndex, 1);
    expect(c.episodeIndex, 5);
    expect(player.value.position, const Duration(minutes: 10));
    expect(player.value.playing, isTrue);
  });

  test('retry after resolution failure preserves return to search', () async {
    final details = <String, VodDetail>{};
    final c = _controller(vod: FakeVod(details));
    addTearDown(c.dispose);
    await c.init();
    await _seedSites(c);
    c.page = AppPage.search;
    await c.openTitle(_item);
    expect(c.playError, isNotNull);
    details['1'] = _detailA;
    await c.retryCurrentPlayback();
    expect(c.playError, isNull);
    expect(c.player.value.playing, isTrue);
    c.backFromKey();
    expect(c.page, AppPage.search);
  });

  test('title fallback starts in parallel and wins after the recorded grace',
      () async {
    final vod = _RacingVod();
    final c = _controller(
        vod: vod, recordedSourceGrace: const Duration(milliseconds: 10));
    addTearDown(c.dispose);
    await c.init();
    await _seedSites(c);
    c.history.put(_saved);
    final opening = c.openTitle(_item);
    expect(vod.details, 1);
    expect(vod.searches, 1);
    vod.searched.complete(_detailB);
    await opening;
    expect(c.currentDetail!.key, _detailB.key);
    vod.recorded.complete(_detailA);
    await pumpEventQueue();
    expect(c.currentDetail!.key, _detailB.key);
  });

  test('healthy recorded source wins within the preference window', () async {
    final vod = _RacingVod();
    final c = _controller(vod: vod);
    addTearDown(c.dispose);
    await c.init();
    await _seedSites(c);
    c.history.put(_saved);
    final opening = c.openTitle(_item);
    vod.searched.complete(_detailB);
    vod.recorded.complete(_detailA);
    await opening;
    expect(c.currentDetail!.key, _detailA.key);
    expect(c.player.value.position.inMilliseconds, _saved.positionMs);
  });

  test('one total deadline ends resolution and ignores late resources',
      () async {
    final vod = _RacingVod();
    final c =
        _controller(vod: vod, resolveTimeout: const Duration(milliseconds: 20));
    addTearDown(c.dispose);
    await c.init();
    await _seedSites(c);
    c.history.put(_saved);
    await c.openTitle(_item);
    expect(c.resolving, isFalse);
    expect(c.playError, contains('超时'));
    vod.recorded.complete(_detailA);
    vod.searched.complete(_detailB);
    await pumpEventQueue();
    expect(c.currentDetail, isNull);
    expect(c.playError, contains('超时'));
    expect(c.history.entryFor(_item.key)!.positionMs, _saved.positionMs);
  });

  test('rapid episode selection stops old continuation after open', () async {
    final gate = Completer<void>();
    final player = GatedPlayer(gate);
    final c = _controller(player: player);
    addTearDown(c.dispose);
    await c.init();
    await _seedSites(c);
    c.currentItem = _item;
    c.currentDetail = _detailA;
    c.page = AppPage.play;
    final first = c.selectEpisode(3);
    final latest = c.selectEpisode(8);
    gate.complete();
    await Future.wait([first, latest]);
    expect(c.episodeIndex, 8);
    expect(player.plays, 1);
    expect(player.speeds, 1);
  });

  test('configured playback headers reach the stream opener', () async {
    final gate = Completer<void>()..complete();
    final player = GatedPlayer(gate);
    final c = _controller(player: player);
    addTearDown(c.dispose);
    await c.init();
    await c.settings.setCmsSites([
      const CmsSite(
          id: 'a',
          name: 'A',
          api: 'https://a.test/api',
          headers: {'Referer': 'https://a.test/watch'}),
    ]);
    c.currentItem = _item;
    c.currentDetail = _detailA;
    c.page = AppPage.play;
    await c.selectEpisode(0);
    expect(player.receivedHeaders.single, {'Referer': 'https://a.test/watch'});
  });

  test('backing out mid-resolve keeps the saved record', () async {
    final gate = Completer<void>();
    final c = _controller(delay: gate.future);
    addTearDown(c.dispose);
    await c.init();
    await _seedSites(c);
    c.history.put(_saved);

    final open = c.openTitle(_item);
    // Resolve is still pending: leave the play page now.
    expect(c.page, AppPage.play);
    c.backFromKey();
    gate.complete();
    await open;

    final entry = c.history.entryFor(_item.key)!;
    expect(entry.episodeIndex, 5);
    expect(entry.positionMs, 600000);
    expect(entry.sourceName, '源A');
  });

  test('backing out mid-resolve creates no record for a fresh title', () async {
    final gate = Completer<void>();
    final c = _controller(delay: gate.future);
    addTearDown(c.dispose);
    await c.init();
    await _seedSites(c);

    final open = c.openTitle(_item);
    c.backFromKey();
    gate.complete();
    await open;

    expect(c.history.entryFor(_item.key), isNull);
  });

  test('a slow open cannot overwrite the resumed position with 0:00', () async {
    final gate = Completer<void>();
    final clock = _Clock();
    final c = _controller(player: GatedPlayer(gate), clock: clock);
    addTearDown(c.dispose);
    await c.init();
    await _seedSites(c);
    c.history.put(_saved);

    final open = c.openTitle(_item);
    await pumpEventQueue(); // detail resolved, stream still initialising

    // The stream takes 30s to become ready, then reports position 0 before the
    // resume seek lands. That "ready" tick must not be treated as progress.
    clock.advance(30);
    gate.complete();
    await open;

    final entry = c.history.entryFor(_item.key)!;
    expect(entry.positionMs, 600000);
    expect(entry.episodeIndex, 5);
  });

  test('back after playback started still saves the episode', () async {
    final clock = _Clock();
    final c = _controller(clock: clock);
    addTearDown(c.dispose);
    await c.init();
    await _seedSites(c);

    await c.openTitle(_item);
    await c.selectEpisode(3);
    c.backFromKey();

    final entry = c.history.entryFor(_item.key)!;
    expect(entry.episodeIndex, 3);
    expect(entry.sourceName, '源A');
  });

  test('progress is written once playback is running', () async {
    final clock = _Clock();
    final c = _controller(clock: clock);
    addTearDown(c.dispose);
    await c.init();
    await _seedSites(c);
    c.history.put(_saved);

    await c.openTitle(_item);
    await c.player.seekTo(const Duration(seconds: 42));
    await _tick(c, clock);

    expect(c.history.entryFor(_item.key)!.positionMs, 42000);
  });

  test('switching resource updates the history source name', () async {
    final clock = _Clock();
    final c = _controller(clock: clock);
    addTearDown(c.dispose);
    await c.init();
    await _seedSites(c);

    await c.openTitle(_item);
    await _tick(c, clock);
    expect(c.currentDetail!.sourceName, '源A');
    expect(c.history.entryFor(_item.key)!.sourceName, '源A');

    await c.switchResource(_switchToB);

    expect(c.history.entryFor(_item.key)!.sourceName, '源B');
    expect(c.currentDetail!.sourceName, '源B');
  });

  test('switching resource relabels a CMS-direct item', () async {
    final clock = _Clock();
    final c = _controller(clock: clock);
    addTearDown(c.dispose);
    await c.init();
    await _seedSites(c);

    await c.openTitle(_cmsItem);
    await _tick(c, clock);
    expect(c.currentItem!.genre, '源A');

    await c.switchResource(_switchToB);

    // Play page meta row and history card both read item.genre for CMS hits.
    expect(c.currentItem!.genre, '源B');
    expect(c.history.entryFor(_cmsItem.key)!.item.genre, '源B');
    // Identity is unchanged, so resume/history stay on the same record.
    expect(c.history.entryFor(_cmsItem.key)!.key, _cmsItem.key);
  });
}
