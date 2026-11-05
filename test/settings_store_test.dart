import 'package:flutter_test/flutter_test.dart';

import 'package:bear_tv/data/danmaku/danmaku_models.dart';
import 'package:bear_tv/data/iptv/iptv_models.dart';
import 'package:bear_tv/data/kv_store.dart';
import 'package:bear_tv/data/settings_store.dart';

/// Build-time defines and in-app config are one set: a non-empty injected
/// value overwrites the saved config on startup, an empty one leaves it alone.
void main() {
  const seedIptv =
      IptvSource(id: 'iptv_default_zn', name: '默认直播源', url: 'http://seed.m3u');
  const mineIptv = IptvSource(id: 'mine', name: '我的源', url: 'http://mine.m3u');

  SettingsStore iptvStore({List<IptvSource> seed = const []}) => SettingsStore(
        store: MemoryKeyValueStore(),
        seededIptvSources: () => seed,
      );

  const seedHost = DanmakuHost(
      id: 'danmaku_default',
      name: '默认弹幕源',
      baseUrl: 'http://seed',
      token: 'seed-token');
  const mineHost =
      DanmakuHost(id: 'mine', name: '我的源', baseUrl: 'http://mine', token: 't');

  SettingsStore danmakuStore({List<DanmakuHost> seed = const []}) =>
      SettingsStore(
        store: MemoryKeyValueStore(),
        seededDanmakuHosts: () => seed,
      );

  group('iptvSources', () {
    test('first run uses the build-time source', () {
      expect(iptvStore(seed: [seedIptv]).iptvSources.map((s) => s.url),
          ['http://seed.m3u']);
    });

    test('a non-empty build value overwrites the saved list on init', () async {
      final s = iptvStore(seed: [seedIptv]);
      await s.setIptvSources([mineIptv]);
      await s.setIptvSelectedSourceId('mine');

      await s.init();

      expect(s.iptvSources.map((v) => v.url), ['http://seed.m3u']);
      expect(s.iptvSelectedSourceId, 'iptv_default_zn');
    });

    test('an empty build value keeps the saved list on init', () async {
      final s = iptvStore();
      await s.setIptvSources([mineIptv]);

      await s.init();

      expect(s.iptvSources.map((v) => v.id), ['mine']);
    });

    test('deleting every source persists an empty list', () async {
      final s = iptvStore();
      await s.setIptvSources(const []);

      expect(s.iptvSources, isEmpty);
    });

    test('no saved list and no build value → empty', () {
      expect(iptvStore().iptvSources, isEmpty);
    });
  });

  group('danmakuHosts', () {
    test('first run uses the build-time host', () {
      expect(danmakuStore(seed: [seedHost]).danmakuHosts.map((h) => h.baseUrl),
          ['http://seed']);
    });

    test('a non-empty build value overwrites the saved list on init', () async {
      final s = danmakuStore(seed: [seedHost]);
      await s.setDanmakuHosts([mineHost]);
      await s.setDanmakuDefaultHostId('mine');

      await s.init();

      expect(s.danmakuHosts.map((h) => h.baseUrl), ['http://seed']);
      expect(s.danmakuDefaultHostId, 'danmaku_default');
    });

    test('an empty build value keeps the saved list on init', () async {
      final s = danmakuStore();
      await s.setDanmakuHosts([mineHost]);

      await s.init();

      expect(s.danmakuHosts.map((h) => h.id), ['mine']);
    });

    test('deleting every host persists an empty list', () async {
      final s = danmakuStore();
      await s.setDanmakuHosts(const []);

      expect(s.danmakuHosts, isEmpty);
    });

    test('hosts persisted without a token are dropped (token is required)',
        () async {
      final s = danmakuStore();
      await s.setDanmakuHosts(const [
        DanmakuHost(id: 'bad', baseUrl: 'http://bad', token: ''),
        mineHost,
      ]);

      expect(s.danmakuHosts.map((h) => h.id), ['mine']);
    });
  });
}
