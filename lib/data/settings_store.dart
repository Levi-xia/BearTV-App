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
  SettingsStore({this.seedDefaultKey = true, KeyValueStore? store})
      : _store = store ?? SharedPrefsStore();

  final KeyValueStore _store;

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
  static const _kIptvSources = 'iptvSources';
  static const _kIptvSelectedSourceId = 'iptvSelectedSourceId';

  Future<void> init() => _store.init();

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

  // --- IPTV (直播) source configuration -------------------------------------

  /// Configured IPTV playlist sources. On first run seeds the build-time
  /// default (if any), otherwise starts empty and the user adds a playlist.
  List<IptvSource> get iptvSources {
    final raw = _store.getString(_kIptvSources);
    if (raw == null) return defaultIptvSources();
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
    return defaultIptvSources();
  }

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
