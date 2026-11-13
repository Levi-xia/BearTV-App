import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:bear_tv/data/danmaku/danmaku_models.dart';
import 'package:bear_tv/data/iptv/iptv_models.dart';
import 'package:bear_tv/data/kv_store.dart';
import 'package:bear_tv/data/settings_store.dart';
import 'package:bear_tv/data/vod/cms_models.dart';

/// Build-time defines and in-app config are one set: a non-empty injected
/// value overwrites the saved config on startup, an empty one leaves it alone.
void main() {
  const comA = CmsSite(id: 'a', name: '源A', api: 'https://a.example/api');
  const comB = CmsSite(id: 'b', name: '源B', api: 'https://b.example/api');
  const mineCms = CmsSite(id: 'mine', name: '我的源', api: 'http://mine/api');

  SettingsStore cmsStore({
    List<CmsSite> seed = const [],
    List<String>? selected,
    KeyValueStore? store,
  }) =>
      SettingsStore(
        store: store ?? MemoryKeyValueStore(),
        seededCmsSites: () => seed,
        seededSelectedIds: selected == null ? null : () => selected,
      );

  group('cmsSites', () {
    test('first run uses the build-time sources and selects them all', () {
      final s = cmsStore(seed: [comA, comB]);
      expect(s.cmsSites.map((v) => v.id), ['a', 'b']);
      expect(s.selectedSourceIds, ['a', 'b']);
    });

    test('first run honours the build-time selection', () {
      final s = cmsStore(seed: [comA, comB], selected: ['b']);
      expect(s.selectedSourceIds, ['b']);
    });

    test('a non-empty build value overwrites the saved list on init', () async {
      final s = cmsStore(seed: [comA, comB], selected: ['b']);
      await s.setCmsSites([mineCms]);
      await s.setSelectedSourceIds(['mine']);

      await s.init();

      expect(s.cmsSites.map((v) => v.id), ['a', 'b']);
      expect(s.selectedSourceIds, ['b']);
    });

    test('an empty build value keeps the saved list on init', () async {
      final s = cmsStore();
      await s.setCmsSites([mineCms]);
      await s.setSelectedSourceIds(['mine']);

      await s.init();

      expect(s.cmsSites.map((v) => v.id), ['mine']);
      expect(s.selectedSourceIds, ['mine']);
    });

    test('deleting every source persists an empty list', () async {
      final s = cmsStore();
      await s.setCmsSites(const []);

      expect(s.cmsSites, isEmpty);
      expect(s.selectedSourceIds, isEmpty);
    });

    test('duplicate API URLs collapse and entries without a usable API drop',
        () {
      final s = cmsStore(seed: const [
        CmsSite(id: 'one', name: '一', api: 'https://dup.example/api/'),
        CmsSite(id: 'two', name: '二', api: 'https://dup.example/api'),
        CmsSite(id: 'bad', name: '坏', api: 'ftp://nope'),
      ]);

      expect(s.cmsSites.map((v) => v.id), ['one']);
    });

    test('legacy custom sources are read when cmsSites was never written', () {
      final store = MemoryKeyValueStore({
        'customSites': jsonEncode([
          {'id': 'old', 'name': '旧源', 'api': 'https://old.example/api'},
        ]),
      });
      final s = cmsStore(store: store);

      expect(s.cmsSites.single.id, 'old');
    });
  });

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

  group('TMDB key and proxy', () {
    test('build-time values are persisted on init so they survive updates',
        () async {
      final store = MemoryKeyValueStore();
      final s = SettingsStore(
        store: store,
        seededTmdbApiKey: 'seed-key',
        seededProxyBase: 'https://proxy.seed',
      );

      await s.init();

      expect(store.getString('tmdbApiKey'), 'seed-key');
      expect(store.getString('tmdbProxyBase'), 'https://proxy.seed');
    });

    test('a later build without defines keeps the persisted values', () async {
      final store = MemoryKeyValueStore();
      await SettingsStore(
        store: store,
        seededTmdbApiKey: 'seed-key',
        seededProxyBase: 'https://proxy.seed',
      ).init();

      // Same on-disk store, new build compiled without secrets.
      final upgraded = SettingsStore(store: store);
      await upgraded.init();

      expect(upgraded.tmdbApiKey, 'seed-key');
      expect(upgraded.proxyBase, 'https://proxy.seed');
      expect(upgraded.proxyEnabled, isTrue);
    });

    test('seeding never overwrites a value the user already saved', () async {
      final store = MemoryKeyValueStore({
        'tmdbApiKey': 'my-key',
        'tmdbProxyBase': 'https://my.proxy',
      });
      final s = SettingsStore(
        store: store,
        seededTmdbApiKey: 'seed-key',
        seededProxyBase: 'https://proxy.seed',
      );

      await s.init();

      expect(s.tmdbApiKey, 'my-key');
      expect(s.proxyBase, 'https://my.proxy');
      expect(store.getString('tmdbApiKey'), 'my-key');
      expect(store.getString('tmdbProxyBase'), 'https://my.proxy');
    });

    test('an explicitly cleared key stays cleared across restarts', () async {
      final store = MemoryKeyValueStore();
      final s = SettingsStore(store: store, seededTmdbApiKey: 'seed-key');
      await s.init();
      await s.setTmdbApiKey('');

      final restarted =
          SettingsStore(store: store, seededTmdbApiKey: 'seed-key');
      await restarted.init();

      expect(restarted.tmdbApiKey, '');
    });

    test('seedDefaultKey=false keeps the build-time key out of the store',
        () async {
      final store = MemoryKeyValueStore();
      final s = SettingsStore(
        store: store,
        seedDefaultKey: false,
        seededTmdbApiKey: 'seed-key',
      );

      await s.init();

      expect(s.tmdbApiKey, '');
      expect(store.getString('tmdbApiKey'), isNull);
    });
  });
}
