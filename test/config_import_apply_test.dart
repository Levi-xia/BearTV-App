import 'package:flutter_test/flutter_test.dart';

import 'package:bear_tv/core/app_controller.dart';
import 'package:bear_tv/data/config_import.dart';
import 'package:bear_tv/data/kv_store.dart';
import 'package:bear_tv/data/settings_store.dart';

import 'fakes.dart';

void main() {
  test('applyConfigImport overwrites mentioned sections only', () async {
    final settings =
        SettingsStore(seedDefaultKey: false, store: MemoryKeyValueStore());
    final c = AppController(settings: settings, repository: FakeRepo());
    addTearDown(c.dispose);
    await c.init();

    await settings.setTmdbApiKey('old-key');
    await settings.setProxyEnabled(false);

    await c.applyConfigImport(parseConfigImportSecrets({
      'TMDB_API_KEY': 'new-key',
      'CMS_SITES_JSON': [
        {'id': 's1', 'name': '源1', 'api': 'https://a.example/api'},
      ],
      'DANMAKU_BASE_URL': 'https://dm.example',
      'DANMAKU_TOKEN': 't',
      'IPTV_PLAYLIST_URL': 'https://tv.example/list.m3u',
    }));

    expect(settings.tmdbApiKey, 'new-key');
    // Not mentioned by the payload: untouched.
    expect(settings.proxyEnabled, isFalse);
    expect(settings.proxyBase, SettingsStore.defaultProxyBase);

    expect(settings.cmsSites.single.id, 's1');
    expect(settings.selectedSourceIds, ['s1']);
    expect(c.allSites.single.id, 's1');
    expect(c.danmaku.hosts.single.baseUrl, 'https://dm.example');
    expect(c.iptv.sources.single.url, 'https://tv.example/list.m3u');
  });
}
