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
  ///
  /// [title] is the TMDB display title; [detailTitle] is the CMS source's own
  /// title (usually closer to the release name the danmaku server indexes), and
  /// is tried first. Never blocks playback, but a failure is *reported* —
  /// transport errors must not be mistaken for "this show has no danmaku".
  Future<void> autoLoad(
    String title,
    int episodeIndex, {
    String? detailTitle,
  }) async {
    if (!_config.enabled) return;
    if (!_hasHost) {
      statusText = '未配置弹幕服务';
      _replaceItems(const []);
      notifyListeners();
      return;
    }
    final names = _searchNames(title, episodeIndex, detailTitle);
    if (names.isEmpty) {
      statusText = '弹幕搜索标题为空';
      _replaceItems(const []);
      notifyListeners();
      return;
    }
    lastSearchName = names.first;
    final token = ++_loadToken;

    for (final name in names) {
      final cached = _cache[_titleKey(name)];
      if (cached != null) {
        _touch(_titleKey(name));
        matches = const [];
        loading = false;
        statusText = cached.isEmpty ? '未找到弹幕' : '已加载 ${cached.length} 条弹幕';
        _replaceItems(cached);
        notifyListeners();
        return;
      }
    }

    loading = true;
    statusText = '正在匹配弹幕…';
    matches = const [];
    _replaceItems(const []);
    notifyListeners();

    DanmakuRequestException? failure;
    var answered = false; // at least one query got a real (possibly empty) answer
    List<DanmakuMatch> matched = const [];
    List<DanmakuMatch> fuzzy = const [];
    String? fuzzyName;
    String? usedName;
    // A dead host would otherwise spend one full (30s timeout + retry) budget
    // per candidate spelling; stop trying new spellings after this. 60s still
    // leaves room for a slow-but-working host to answer two spellings.
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    for (final name in names) {
      if (DateTime.now().isAfter(deadline)) break;
      try {
        final result = await _client.match(_host, name);
        if (token != _loadToken) return;
        answered = true;
        if (result.matches.isEmpty) continue;
        if (result.exact) {
          matched = result.matches;
          usedName = name;
          break; // a confident hit beats trying further spellings
        }
        // Keep the first fuzzy hit but keep looking for an exact one.
        if (fuzzy.isEmpty) {
          fuzzy = result.matches;
          fuzzyName = name;
        }
      } on DanmakuRequestException catch (e) {
        if (token != _loadToken) return;
        failure = e;
      }
    }
    final matchedExactly = matched.isNotEmpty;
    if (matched.isEmpty && fuzzy.isNotEmpty) {
      matched = fuzzy;
      usedName = fuzzyName;
    }

    if (matched.isEmpty) {
      loading = false;
      statusText = answered ? '未找到弹幕' : '匹配弹幕失败：${failure?.message ?? '未知错误'}';
      notifyListeners();
      return;
    }

    matches = matched;
    loading = true;
    statusText = '加载弹幕中…';
    notifyListeners();

    final List<DanmakuItem> fetched;
    try {
      fetched = await _client.fetchComments(_host, matched.first.episodeId);
    } on DanmakuRequestException catch (e) {
      if (token != _loadToken) return;
      // Do NOT cache: a transient failure must not look like "no danmaku".
      loading = false;
      statusText = '获取弹幕失败：${e.message}';
      notifyListeners();
      return;
    }
    if (token != _loadToken) return;
    final sampled = _sample(fetched);
    final key = _titleKey(usedName ?? names.first);
    _cache[key] = sampled;
    _trim();
    loading = false;
    statusText = sampled.isEmpty
        ? '该集暂无弹幕'
        : '已加载 ${sampled.length} 条弹幕${matchedExactly ? '' : '（模糊匹配，可在手动匹配中更换）'}';
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
    List<DanmakuMatch> ms;
    try {
      ms = (await _client.match(_host, name)).matches;
    } on DanmakuRequestException catch (e) {
      if (token != _loadToken) return;
      loading = false;
      statusText = '搜索失败：${e.message}';
      notifyListeners();
      return;
    }
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
    final cached = _cache[key];
    List<DanmakuItem> items;
    if (cached != null) {
      _touch(key);
      items = cached;
    } else {
      try {
        final fetched = await _client.fetchComments(_host, m.episodeId);
        if (token != _loadToken) return;
        items = _sample(fetched);
      } on DanmakuRequestException catch (e) {
        if (token != _loadToken) return;
        loading = false;
        statusText = '获取弹幕失败：${e.message}';
        notifyListeners();
        return;
      }
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

  /// Candidate `/match` file names, most specific first: the CMS detail title
  /// (usually the release name) then the TMDB title, each as `S01E{nn}`, then
  /// the same titles bare for servers that only index movies / season packs.
  /// Deduplicated, order preserved.
  List<String> _searchNames(String title, int episodeIndex, String? detailTitle) {
    final titles = <String>[
      if (detailTitle != null && detailTitle.trim().isNotEmpty) detailTitle.trim(),
      title,
    ];
    final out = <String>[];
    void add(String v) {
      final s = v.trim();
      if (s.isNotEmpty && !out.contains(s)) out.add(s);
    }

    for (final t in titles) {
      add(formatDanmakuSearchName(t, episodeIndex));
    }
    for (final t in titles) {
      add(cleanDanmakuTitle(t));
    }
    return out;
  }

  /// Mark [key] as most-recently-used (LinkedHashMap move-to-end).
  void _touch(String key) {
    final v = _cache.remove(key);
    if (v != null) _cache[key] = v;
  }

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
