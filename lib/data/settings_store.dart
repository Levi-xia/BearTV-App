import 'dart:convert';

import '../core/env.dart';
import 'danmaku/danmaku_models.dart';
import 'iptv/iptv_models.dart';
import 'kv_store.dart';
import 'vod/cms_models.dart';
import 'vod/cms_sources.dart';

/// Locally-persisted app settings, backed by a [KeyValueStore]
/// (`shared_preferences` in production). Holds the TMDB API key plus the
/// playback source configuration. Values are stored as individual scalar keys
/// so a corrupt entry never takes down the rest. All access is best-effort: the
/// backing store degrades to in-memory when persistence is unavailable (e.g.
/// under `flutter test`).
class SettingsStore {
  SettingsStore({
    this.seedDefaultKey = true,
    KeyValueStore? store,
    List<IptvSource> Function()? seededIptvSources,
    List<DanmakuHost> Function()? seededDanmakuHosts,
  })  : _store = store ?? SharedPrefsStore(),
        _iptvSeed = seededIptvSources,
        _danmakuSeed = seededDanmakuHosts;

  final KeyValueStore _store;

  /// Overrides for the build-time seeds; tests inject them because the
  /// `String.fromEnvironment` defines are empty under `flutter test`.
  final List<IptvSource> Function()? _iptvSeed;
  final List<DanmakuHost> Function()? _danmakuSeed;

  /// When true (production default), an unset key falls back to
  /// [defaultTmdbApiKey], which is the build-time `TMDB_API_KEY` define. An
  /// open-source/CI build leaves it empty, so the app shows the "填写 API Key"
  /// page. Tests pass false to exercise that same state explicitly.
  final bool seedDefaultKey;

  /// TMDB key seeded from the build-time `TMDB_API_KEY` define (see [Env]).
  /// Empty in an open-source/CI build, so the app shows the "填写 API Key" page
  /// until the user enters their own.
  static String get defaultTmdbApiKey => Env.tmdbApiKey;

  /// Default TMDB reverse-proxy origin from the build-time `TMDB_PROXY_BASE`
  /// define. Empty → direct TMDB endpoints.
  static String get defaultProxyBase => Env.tmdbProxyBase;

  static const _kApiKey = 'tmdbApiKey';
  static const _kSelectedIds = 'selectedSourceIds';
  static const _kCustomSites = 'customSites';
  static const _kProxyEnabled = 'tmdbProxyEnabled';
  static const _kProxyBase = 'tmdbProxyBase';
  static const _kSystemIme = 'searchUseSystemIme';
  static const _kSearchHistory = 'searchHistory';
  static const _kDanmakuConfig = 'danmakuConfig';
  static const _kDanmakuHosts = 'danmakuHosts';
  static const _kDanmakuDefaultHostId = 'danmakuDefaultHostId';
  static const _kIptvSources = 'iptvSources';
  static const _kIptvSelectedSourceId = 'iptvSelectedSourceId';

  /// Load the backing store, then apply the build-time config: a non-empty
  /// `IPTV_PLAYLIST_URL` / `DANMAKU_BASE_URL`+`DANMAKU_TOKEN` overwrites the
  /// saved sources/hosts, so changing `secrets.json` and rebuilding is visible
  /// in Settings. An empty define leaves the user's saved config untouched.
  Future<void> init() async {
    await _store.init();
    final iptv = _defaultIptvSources();
    if (iptv.isNotEmpty) {
      await setIptvSources(iptv);
      await setIptvSelectedSourceId(iptv.first.id);
    }
    final hosts = _defaultDanmakuHosts();
    if (hosts.isNotEmpty) {
      await setDanmakuHosts(hosts);
      await setDanmakuDefaultHostId(hosts.first.id);
    }
  }

  // --- Search input method --------------------------------------------------

  /// Whether the search page uses the device's system IME (a native input +
  /// on-screen system keyboard) instead of the built-in offline pinyin
  /// keyboard. Defaults to `true`: most boxes ship a usable IME and it lets
  /// users type with whatever input method they already know.
  bool get searchUseSystemIme {
    final v = _store.getString(_kSystemIme);
    if (v == null) return true;
    return v == 'true';
  }

  Future<void> setSearchUseSystemIme(bool v) =>
      _store.setString(_kSystemIme, v ? 'true' : 'false');

  // --- Search history -------------------------------------------------------

  /// Recent search queries, most-recent-first. Empty when none / unset or the
  /// stored value is corrupt.
  List<String> get searchHistory {
    final raw = _store.getString(_kSearchHistory);
    if (raw == null) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.map((e) => e.toString()).where((e) => e.isNotEmpty).toList();
      }
    } catch (_) {
      // Corrupt value: treat as empty.
    }
    return const [];
  }

  Future<void> setSearchHistory(List<String> queries) =>
      _store.setString(_kSearchHistory, jsonEncode(queries));


  // --- TMDB network proxy ---------------------------------------------------

  /// Whether TMDB traffic (API + images) is routed through [proxyBase].
  /// Defaults to `true`: the primary target (mainland-China TV boxes) can't
  /// reach themoviedb.org directly, so the app works out of the box.
  bool get proxyEnabled {
    final v = _store.getString(_kProxyEnabled);
    if (v == null) return true;
    return v == 'true';
  }

  Future<void> setProxyEnabled(bool v) =>
      _store.setString(_kProxyEnabled, v ? 'true' : 'false');

  /// Reverse-proxy origin (e.g. `https://your-proxy.example.com`). Falls back
  /// to [defaultProxyBase] when unset or cleared.
  String get proxyBase {
    final v = _store.getString(_kProxyBase)?.trim();
    return (v == null || v.isEmpty) ? defaultProxyBase : v;
  }

  Future<void> setProxyBase(String base) =>
      _store.setString(_kProxyBase, base.trim());

  String get tmdbApiKey {
    final v = _store.getString(_kApiKey);
    if (v == null) return seedDefaultKey ? defaultTmdbApiKey : '';
    return v.trim(); // present-but-empty means the user explicitly cleared it
  }

  Future<void> setTmdbApiKey(String key) => _store.setString(_kApiKey, key.trim());

  // --- Playback source configuration ---------------------------------------

  /// Enabled CMS source ids (built-in + custom). Defaults to
  /// [kDefaultSelected] on first run.
  List<String> get selectedSourceIds {
    final raw = _store.getString(_kSelectedIds);
    if (raw == null) return List<String>.from(kDefaultSelected);
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) return decoded.map((e) => e.toString()).toList();
    } catch (_) {
      // Corrupt value: fall through to defaults.
    }
    return List<String>.from(kDefaultSelected);
  }

  Future<void> setSelectedSourceIds(List<String> ids) =>
      _store.setString(_kSelectedIds, jsonEncode(ids));

  /// User-added custom sources (max [kMaxCustomSites]).
  List<CmsSite> get customSites {
    final raw = _store.getString(_kCustomSites);
    if (raw == null) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded
            .whereType<Map>()
            .map((m) => CmsSite.fromJson(Map<String, dynamic>.from(m)))
            .toList();
      }
    } catch (_) {
      // Corrupt value: treat as no custom sites.
    }
    return const [];
  }

  Future<void> setCustomSites(List<CmsSite> sites) =>
      _store.setString(_kCustomSites, jsonEncode(sites.map((s) => s.toJson()).toList()));

  // --- Danmaku (弹幕) --------------------------------------------------------

  /// Rendering config for the danmaku overlay. Falls back to defaults (enabled,
  /// half-screen, medium size/speed) when unset or corrupt.
  DanmakuConfig get danmakuConfig {
    final raw = _store.getString(_kDanmakuConfig);
    if (raw == null) return const DanmakuConfig();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return DanmakuConfig.fromJson(Map<String, dynamic>.from(decoded));
      }
    } catch (_) {
      // Corrupt value: fall back to defaults.
    }
    return const DanmakuConfig();
  }

  Future<void> setDanmakuConfig(DanmakuConfig c) =>
      _store.setString(_kDanmakuConfig, jsonEncode(c.toJson()));

  /// Configured danmaku hosts. A non-empty build-time `DANMAKU_BASE_URL` +
  /// `DANMAKU_TOKEN` replaces the saved list in [init]; when the build injects
  /// nothing, the saved list is used as-is (empty on first run).
  List<DanmakuHost> get danmakuHosts {
    final raw = _store.getString(_kDanmakuHosts);
    if (raw == null) return _defaultDanmakuHosts();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded
            .whereType<Map>()
            .map((m) => DanmakuHost.fromJson(Map<String, dynamic>.from(m)))
            .where((h) =>
                h.baseUrl.trim().isNotEmpty && h.token.trim().isNotEmpty)
            .toList();
      }
    } catch (_) {
      // Corrupt value: fall back to the build-time default (if any).
    }
    return _defaultDanmakuHosts();
  }

  List<DanmakuHost> _defaultDanmakuHosts() {
    if (_danmakuSeed != null) return _danmakuSeed();
    final d = defaultDanmakuHost();
    return d.baseUrl.isEmpty || d.token.isEmpty ? const [] : [d];
  }

  Future<void> setDanmakuHosts(List<DanmakuHost> hosts) => _store.setString(
      _kDanmakuHosts, jsonEncode(hosts.map((h) => h.toJson()).toList()));

  /// The host id used for auto-matching. Null when the user never picked one
  /// (the first configured host is used) or when there are no hosts at all.
  String? get danmakuDefaultHostId {
    final v = _store.getString(_kDanmakuDefaultHostId)?.trim();
    return (v == null || v.isEmpty) ? null : v;
  }

  Future<void> setDanmakuDefaultHostId(String? id) =>
      _store.setString(_kDanmakuDefaultHostId, id ?? '');

  // --- IPTV (直播) source configuration -------------------------------------

  /// Configured IPTV playlist sources. A non-empty build-time
  /// `IPTV_PLAYLIST_URL` replaces the saved list in [init]; when the build
  /// injects nothing, the saved list is used as-is (empty on first run).
  List<IptvSource> get iptvSources {
    final raw = _store.getString(_kIptvSources);
    if (raw == null) return _defaultIptvSources();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded
            .whereType<Map>()
            .map((m) => IptvSource.fromJson(Map<String, dynamic>.from(m)))
            .where((s) => s.id.isNotEmpty && s.url.isNotEmpty)
            .toList();
      }
    } catch (_) {
      // Corrupt value: fall back to defaults.
    }
    return _defaultIptvSources();
  }

  List<IptvSource> _defaultIptvSources() =>
      _iptvSeed?.call() ?? defaultIptvSources();

  Future<void> setIptvSources(List<IptvSource> sources) => _store.setString(
      _kIptvSources, jsonEncode(sources.map((s) => s.toJson()).toList()));

  /// The last-selected IPTV source id, or null when none is chosen yet.
  String? get iptvSelectedSourceId {
    final v = _store.getString(_kIptvSelectedSourceId)?.trim();
    return (v == null || v.isEmpty) ? null : v;
  }

  Future<void> setIptvSelectedSourceId(String? id) =>
      _store.setString(_kIptvSelectedSourceId, id ?? '');
}
