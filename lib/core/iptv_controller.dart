import 'package:flutter/foundation.dart';

import '../data/iptv/iptv_client.dart';
import '../data/iptv/iptv_models.dart';
import '../data/settings_store.dart';

/// Owns the IPTV (直播) browsing state: configured sources, the selected
/// source's parsed channels, search query, and the current channel. Mirrors
/// BearTV's `iptvStore` and the [DanmakuController] lifecycle — created
/// param-less by [AppController], then wired to persistence via [init].
///
/// Playback itself is orchestrated by [AppController] (which owns the shared
/// player); this controller only tracks *what* is selected. Fetches are cached
/// per source so flipping between sources doesn't re-download each time.
class IptvController extends ChangeNotifier {
  IptvController({IptvClient? client}) : _client = client ?? IptvClient();

  final IptvClient _client;
  SettingsStore? _settings;

  /// Exposed so [LiveProbeController] can share this connection pool. This
  /// controller keeps ownership and closes it in [dispose].
  IptvClient get client => _client;

  List<IptvSource> _sources = const [];
  List<IptvSource> get sources => _sources;

  String? _selectedSourceId;
  String? get selectedSourceId => _selectedSourceId;

  List<IptvChannel> _channels = const [];
  List<IptvChannel> get channels => _channels;

  IptvChannel? currentChannel;
  bool loading = false;
  String? error;

  String _query = '';
  String get query => _query;

  int _loadToken = 0;
  final Map<String, List<IptvChannel>> _cache = {};

  /// The active source (selected, else the first configured one, else null).
  IptvSource? get selectedSource {
    for (final s in _sources) {
      if (s.id == _selectedSourceId) return s;
    }
    return _sources.isNotEmpty ? _sources.first : null;
  }

  /// Channels matching [query] (by name or group). Empty query → all.
  List<IptvChannel> get filteredChannels {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _channels;
    return _channels
        .where((c) =>
            c.name.toLowerCase().contains(q) ||
            c.group.toLowerCase().contains(q))
        .toList();
  }

  /// [filteredChannels] bucketed by `group`, preserving first-seen order.
  Map<String, List<IptvChannel>> get groupedChannels {
    final out = <String, List<IptvChannel>>{};
    for (final c in filteredChannels) {
      (out[c.group] ??= <IptvChannel>[]).add(c);
    }
    return out;
  }

  String? _selectedGroup;

  /// Group names in display order (from the current [groupedChannels]).
  List<String> get groups => groupedChannels.keys.toList();

  /// The group whose channels are shown: the user's pick when still present,
  /// else the first group. Null only when there are no channels.
  String? get activeGroup {
    final gs = groups;
    if (gs.isEmpty) return null;
    if (_selectedGroup != null && gs.contains(_selectedGroup)) {
      return _selectedGroup;
    }
    return gs.first;
  }

  /// Channels within [activeGroup] (empty when there are none).
  List<IptvChannel> get channelsInActiveGroup {
    final g = activeGroup;
    if (g == null) return const [];
    return groupedChannels[g] ?? const [];
  }

  /// Switch the visible group (from the channel-panel group tabs).
  void selectGroup(String group) {
    if (group == _selectedGroup) return;
    _selectedGroup = group;
    notifyListeners();
  }

  /// Load persisted sources/selection. Call once from [AppController.init].
  void init(SettingsStore settings) {
    _settings = settings;
    _sources = settings.iptvSources;
    final saved = settings.iptvSelectedSourceId;
    _selectedSourceId = (saved != null && _sources.any((s) => s.id == saved))
        ? saved
        : (_sources.isNotEmpty ? _sources.first.id : null);
  }

  /// Re-read the source list after it was changed outside this controller (e.g.
  /// a config import). Clears parsed channels/caches; the caller reloads if the
  /// 直播 tab is visible.
  void reloadSources() {
    final settings = _settings;
    if (settings == null) return;
    _sources = settings.iptvSources;
    final saved = settings.iptvSelectedSourceId;
    _selectedSourceId = (saved != null && _sources.any((s) => s.id == saved))
        ? saved
        : (_sources.isNotEmpty ? _sources.first.id : null);
    _cache.clear();
    _channels = const [];
    _selectedGroup = null;
    currentChannel = null;
    loading = false;
    error = null;
    _loadToken++;
    notifyListeners();
  }

  /// Fetch + parse the selected source's playlist. Served from cache unless
  /// [force]. Best-effort: sets [error] instead of throwing.
  Future<void> loadChannels({bool force = false}) async {
    _selectedGroup = null; // new channel set → default back to the first group
    final source = selectedSource;
    if (source == null) {
      _channels = const [];
      loading = false;
      error = '尚未添加直播源，请在设置中添加 M3U 播放列表。';
      notifyListeners();
      return;
    }
    if (!force && _cache.containsKey(source.id)) {
      _channels = _cache[source.id]!;
      loading = false;
      error = _channels.isEmpty ? '该直播源没有可用频道。' : null;
      notifyListeners();
      return;
    }
    final token = ++_loadToken;
    loading = true;
    error = null;
    notifyListeners();
    final list = await _client.fetchChannels(source);
    if (token != _loadToken) return; // superseded by a newer load
    _cache[source.id] = list;
    _channels = list;
    loading = false;
    error = list.isEmpty ? '直播源加载失败或没有可用频道，请检查地址。' : null;
    notifyListeners();
  }

  /// Switch the active source and reload its channels.
  Future<void> selectSource(String id) async {
    if (id == _selectedSourceId) return;
    _selectedSourceId = id;
    currentChannel = null;
    await _settings?.setIptvSelectedSourceId(id);
    notifyListeners();
    await loadChannels();
  }

  void selectChannel(IptvChannel ch) {
    currentChannel = ch;
    notifyListeners();
  }

  void search(String q) {
    if (q == _query) return;
    _query = q;
    _selectedGroup = null; // groups change with the filter → reset selection
    notifyListeners();
  }

  /// Add a source. Returns null on success, else a validation message. Auto-
  /// selects + loads it when it's the only/first source.
  Future<String?> addSource(String name, String url) async {
    final n = name.trim();
    final u = url.trim();
    if (n.isEmpty || u.isEmpty) return '请填写名称与播放列表地址';
    if (!u.startsWith('http://') && !u.startsWith('https://')) {
      return '地址需以 http 开头';
    }
    final id = 'iptv_${DateTime.now().millisecondsSinceEpoch}';
    _sources = [..._sources, IptvSource(id: id, name: n, url: u)];
    await _settings?.setIptvSources(_sources);
    final becameSelected = _selectedSourceId == null;
    if (becameSelected) {
      _selectedSourceId = id;
      await _settings?.setIptvSelectedSourceId(id);
    }
    notifyListeners();
    if (becameSelected) await loadChannels();
    return null;
  }

  /// Remove a source. When it was the selected one, falls back to the first
  /// remaining source (or none) and reloads.
  Future<void> removeSource(String id) async {
    _sources = _sources.where((s) => s.id != id).toList();
    _cache.remove(id);
    await _settings?.setIptvSources(_sources);
    if (_selectedSourceId == id) {
      _selectedSourceId = _sources.isNotEmpty ? _sources.first.id : null;
      await _settings?.setIptvSelectedSourceId(_selectedSourceId);
      currentChannel = null;
      notifyListeners();
      await loadChannels();
    } else {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }
}
