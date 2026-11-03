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
    String? currentKey,
  }) async =>
      const [];
}

/// A player whose [open] stays pending until the test releases [gate], then
/// reports "ready" at position 0 — the same shape as a slow CMS stream in
/// `VideoAdapter` (initialize → ready → the caller seeks to the resume point).
class GatedPlayer extends ChangeNotifier implements PlayerController {
  GatedPlayer(this.gate);

  final Completer<void> gate;
  PlayerValue _value = const PlayerValue();

  @override
  PlayerValue get value => _value;

  void _set(PlayerValue v) {
    _value = v;
    notifyListeners();
  }

  @override
  Future<void> open(String? url, {Map<String, String>? headers}) async {
    _set(const PlayerValue());
    if (url == null || url.isEmpty) return;
    await gate.future;
    _set(const PlayerValue(ready: true, duration: Duration(minutes: 45)));
  }

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

/// Controllable wall clock: progress saving is throttled to 5s of *real* time,
/// so tests advance this instead of sleeping.
class _Clock {
  DateTime now = DateTime(2026, 1, 1);
  DateTime call() => now;
  void advance([int seconds = 6]) => now = now.add(Duration(seconds: seconds));
}

const _siteA = CmsSite(id: 'a', name: '源A', api: 'https://a.example/api.php/provide/vod');
const _siteB = CmsSite(id: 'b', name: '源B', api: 'https://b.example/api.php/provide/vod');

final _detailA = _detail('a', '源A', '1');
final _detailB = _detail('b', '源B', '2');

VodDetail _detail(String sourceId, String sourceName, String vodId) => VodDetail(
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
}) {
  final settings = SettingsStore(seedDefaultKey: false, store: MemoryKeyValueStore());
  return AppController(
    settings: settings,
    history: HistoryStore(),
    vod: FakeVod({'1': _detailA, '2': _detailB}, delay: delay),
    player: player,
    clock: clock?.call,
  );
}

Future<void> _seedSites(AppController c) async {
  await c.settings.setCustomSites([_siteA, _siteB]);
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
