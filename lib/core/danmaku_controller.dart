import 'package:flutter/foundation.dart';

import '../data/danmaku/danmaku_client.dart';
import '../data/danmaku/danmaku_models.dart';
import '../data/settings_store.dart';

/// Owns the danmaku pipeline for the play page: config, the current episode's
/// comments, and the manual-match candidate list. Mirrors BearTV's
/// `danmakuStore` — auto-match by formatted title, an LRU cache, density
/// sampling for huge episodes, and a manual search/pick path.
///
/// The rendering widget ([DanmakuOverlay]) listens to this: it resets its
/// flying set whenever [epoch] changes (a new load / clear) and reads [config].
class DanmakuController extends ChangeNotifier {
  DanmakuController({DanmakuClient? client, DanmakuHost? host})
      : _client = client ?? DanmakuClient(),
        _host = host ?? defaultDanmakuHost();

  final DanmakuClient _client;
  final DanmakuHost _host;

  /// False when no danmaku host was configured at build time — every network
  /// entry point degrades to a no-op instead of hitting a blank URL.
  bool get _hasHost => _host.baseUrl.isNotEmpty && _host.token.isNotEmpty;
  SettingsStore? _settings;

  DanmakuConfig _config = const DanmakuConfig();
  DanmakuConfig get config => _config;

  List<DanmakuItem> _items = const [];
  List<DanmakuItem> get items => _items;

  /// Bumped whenever [_items] is replaced/cleared, so the overlay knows to reset.
  int _epoch = 0;
  int get epoch => _epoch;

  List<DanmakuMatch> matches = const [];
  bool loading = false;
  String? statusText;

  /// The last formatted/typed search string, pre-filled into the manual dialog.
  String lastSearchName = '';

  int _loadToken = 0;

  // Small LRU keyed by search-name / episode-id → parsed items.
  final Map<String, List<DanmakuItem>> _cache = {};
  static const int _cacheLimit = 16;
  // Above this many comments per episode we downsample (low-end GPU budget).
  static const int _sampleThreshold = 10000;

  /// Load persisted config. Call once from [AppController.init].
  void init(SettingsStore settings) {
    _settings = settings;
    _config = settings.danmakuConfig;
  }

  String _titleKey(String name) => 'name::$name';
  String _epKey(int id) => 'ep::$id';

  void _replaceItems(List<DanmakuItem> v) {
    _items = v;
    _epoch++;
  }

  /// Auto-match + load for a title/episode. No-op when danmaku is disabled.
  /// Silent on failure (a toast/status is enough — never blocks playback).
  Future<void> autoLoad(String title, int episodeIndex) async {
    if (!_config.enabled) return;
    if (!_hasHost) {
      statusText = '未配置弹幕服务';
      _replaceItems(const []);
      notifyListeners();
      return;
    }
    final name = formatDanmakuSearchName(title, episodeIndex);
    lastSearchName = name;
    final token = ++_loadToken;

    final cached = _cache[_titleKey(name)];
    if (cached != null) {
      matches = const [];
      loading = false;
      statusText = cached.isEmpty ? '未找到弹幕' : '已加载 ${cached.length} 条弹幕';
      _replaceItems(cached);
      notifyListeners();
      return;
    }

    loading = true;
    statusText = '正在匹配弹幕…';
    matches = const [];
    _replaceItems(const []);
    notifyListeners();

    final ms = await _client.match(_host, name);
    if (token != _loadToken) return;
    // Fallback: the `S01Exx` suffix can miss when the server only indexes the
    // bare title (e.g. movies / single-season shows). Retry with just the
    // cleaned title before giving up.
    var matched = ms;
    if (matched.isEmpty) {
      final bare = cleanDanmakuTitle(title);
      if (bare.isNotEmpty && bare != name) {
        matched = await _client.match(_host, bare);
        if (token != _loadToken) return;
      }
    }
    if (matched.isEmpty) {
      loading = false;
      statusText = '未找到弹幕';
      notifyListeners();
      return;
    }
    matches = matched;
    final fetched = await _client.fetchComments(_host, matched.first.episodeId);
    if (token != _loadToken) return;
    final sampled = _sample(fetched);
    _cache[_titleKey(name)] = sampled;
    _trim();
    loading = false;
    statusText = sampled.isEmpty ? '未找到弹幕' : '已加载 ${sampled.length} 条弹幕';
    _replaceItems(sampled);
    notifyListeners();
  }

  /// Manual search: fill [matches] from a user-typed [keyword] (no auto-pick).
  Future<void> search(String keyword) async {
    final name = keyword.trim();
    if (name.isEmpty) return;
    if (!_hasHost) {
      statusText = '未配置弹幕服务';
      matches = const [];
      notifyListeners();
      return;
    }
    lastSearchName = name;
    final token = ++_loadToken;
    loading = true;
    statusText = '搜索中…';
    matches = const [];
    notifyListeners();
    final ms = await _client.match(_host, name);
    if (token != _loadToken) return;
    loading = false;
    matches = ms;
    statusText = ms.isEmpty ? '未找到匹配的弹幕' : '找到 ${ms.length} 个匹配，请选择';
    notifyListeners();
  }

  /// Load comments for a user-picked match.
  Future<void> loadFromMatch(DanmakuMatch m) async {
    final token = ++_loadToken;
    loading = true;
    statusText = '加载弹幕中…';
    notifyListeners();
    final key = _epKey(m.episodeId);
    var items = _cache[key];
    if (items == null) {
      final fetched = await _client.fetchComments(_host, m.episodeId);
      if (token != _loadToken) return;
      items = _sample(fetched);
      _cache[key] = items;
      _trim();
    }
    if (token != _loadToken) return;
    loading = false;
    statusText = items.isEmpty ? '该匹配没有弹幕' : '已加载 ${items.length} 条弹幕';
    _replaceItems(items);
    notifyListeners();
  }

  /// Drop the current episode's danmaku (called when leaving the play page).
  void clear() {
    _loadToken++;
    matches = const [];
    loading = false;
    statusText = null;
    _replaceItems(const []);
    notifyListeners();
  }

  // --- Config setters (persist + notify) ------------------------------------

  Future<void> _save(DanmakuConfig c) async {
    _config = c;
    notifyListeners();
    await _settings?.setDanmakuConfig(c);
  }

  Future<void> setEnabled(bool v) => _save(_config.copyWith(enabled: v));
  Future<void> setOpacity(double v) => _save(_config.copyWith(opacity: v));
  Future<void> setFontSize(double v) => _save(_config.copyWith(fontSize: v));
  Future<void> setScrollSeconds(double v) =>
      _save(_config.copyWith(scrollSeconds: v));
  Future<void> setArea(double v) => _save(_config.copyWith(area: v));

  // --- Internals ------------------------------------------------------------

  /// Uniformly thin a very large (already time-sorted) list down to roughly
  /// [_sampleThreshold] items, preserving order and even time distribution.
  List<DanmakuItem> _sample(List<DanmakuItem> items) {
    if (items.length <= _sampleThreshold) return items;
    final ratio = _sampleThreshold / items.length;
    final out = <DanmakuItem>[];
    var acc = 0.0;
    for (final it in items) {
      acc += ratio;
      if (acc >= 1.0) {
        acc -= 1.0;
        out.add(it);
      }
    }
    return out;
  }

  void _trim() {
    while (_cache.length > _cacheLimit) {
      _cache.remove(_cache.keys.first);
    }
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }
}
