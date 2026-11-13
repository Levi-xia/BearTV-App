import 'package:flutter_test/flutter_test.dart';
import 'package:bear_tv/core/config.dart';
import 'package:bear_tv/data/kv_store.dart';
import 'package:bear_tv/data/settings_store.dart';

void main() {
  group('Config.applyProxy', () {
    tearDown(() => Config.applyProxy(enabled: false, proxyBase: ''));

    test('enabled derives /3 and /t/p from the proxy origin', () {
      Config.applyProxy(enabled: true, proxyBase: 'https://proxy.example.com');
      expect(Config.tmdbBase, 'https://proxy.example.com/3');
      expect(Config.tmdbImageBase, 'https://proxy.example.com/t/p');
    });

    test('trailing slashes on the origin are trimmed', () {
      Config.applyProxy(
          enabled: true, proxyBase: 'https://proxy.example.com//');
      expect(Config.tmdbBase, 'https://proxy.example.com/3');
      expect(Config.tmdbImageBase, 'https://proxy.example.com/t/p');
    });

    test('disabled restores the direct TMDB domains', () {
      Config.applyProxy(enabled: true, proxyBase: 'https://proxy.example.com');
      Config.applyProxy(enabled: false, proxyBase: 'https://proxy.example.com');
      expect(Config.tmdbBase, Config.defaultTmdbBase);
      expect(Config.tmdbImageBase, Config.defaultTmdbImageBase);
    });

    test('enabled with an empty origin falls back to direct', () {
      Config.applyProxy(enabled: true, proxyBase: '   ');
      expect(Config.tmdbBase, Config.defaultTmdbBase);
      expect(Config.tmdbImageBase, Config.defaultTmdbImageBase);
    });
  });

  group('SettingsStore proxy', () {
    test('defaults: enabled=true, base=defaultProxyBase', () {
      final s = SettingsStore(store: MemoryKeyValueStore());
      expect(s.proxyEnabled, isTrue);
      expect(s.proxyBase, SettingsStore.defaultProxyBase);
    });

    test('roundtrips enabled + base', () async {
      final s = SettingsStore(store: MemoryKeyValueStore());
      await s.setProxyEnabled(false);
      await s.setProxyBase('https://my.proxy/');
      expect(s.proxyEnabled, isFalse);
      expect(s.proxyBase, 'https://my.proxy/');
    });

    test('blank base falls back to the default', () async {
      final s = SettingsStore(store: MemoryKeyValueStore());
      await s.setProxyBase('   ');
      expect(s.proxyBase, SettingsStore.defaultProxyBase);
    });
  });
}
