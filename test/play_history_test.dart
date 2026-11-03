import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:bear_tv/core/app_controller.dart';
import 'package:bear_tv/data/history_store.dart';
import 'package:bear_tv/data/kv_store.dart';
import 'package:bear_tv/data/models.dart';
import 'package:bear_tv/data/settings_store.dart';
import 'package:bear_tv/data/vod/cms_models.dart';
import 'package:bear_tv/data/vod/vod_repository.dart';

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

AppController _controller({Future<void>? delay}) {
  final settings = SettingsStore(seedDefaultKey: false, store: MemoryKeyValueStore());
  return AppController(
    settings: settings,
    history: HistoryStore(),
    vod: FakeVod({'1': _detailA, '2': _detailB}, delay: delay),
  );
}

Future<void> _seedSites(AppController c) async {
  await c.settings.setCustomSites([_siteA, _siteB]);
  await c.settings.setSelectedSourceIds(['a', 'b']);
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

    c.history.put(const HistoryEntry(
      item: _item,
      sourceId: 'a',
      sourceName: '源A',
      vodId: '1',
      episodeIndex: 5,
      positionMs: 600000,
      durationMs: 1800000,
    ));

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

  test('back after playback started still saves the episode', () async {
    final c = _controller();
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

  test('switching resource updates the history source name', () async {
    final c = _controller();
    addTearDown(c.dispose);
    await c.init();
    await _seedSites(c);

    await c.openTitle(_item);
    expect(c.currentDetail!.sourceName, '源A');
    expect(c.history.entryFor(_item.key)!.sourceName, '源A');

    await c.switchResource(_switchToB);

    expect(c.history.entryFor(_item.key)!.sourceName, '源B');
    expect(c.currentDetail!.sourceName, '源B');
  });

  test('switching resource relabels a CMS-direct item', () async {
    final c = _controller();
    addTearDown(c.dispose);
    await c.init();
    await _seedSites(c);

    await c.openTitle(_cmsItem);
    expect(c.currentItem!.genre, '源A');

    await c.switchResource(_switchToB);

    // Play page meta row and history card both read item.genre for CMS hits.
    expect(c.currentItem!.genre, '源B');
    expect(c.history.entryFor(_cmsItem.key)!.item.genre, '源B');
    // Identity is unchanged, so resume/history stay on the same record.
    expect(c.history.entryFor(_cmsItem.key)!.key, _cmsItem.key);
  });
}
