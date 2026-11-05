import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show FocusNode;

import 'dart:async';

import 'danmaku_controller.dart';
import 'iptv_controller.dart';
import 'live_probe_controller.dart';
import '../data/danmaku/danmaku_models.dart';
import '../data/history_store.dart';
import '../data/iptv/iptv_models.dart';
import '../data/models.dart';
import '../data/nav_config.dart';
import '../data/repository.dart';
import '../data/settings_store.dart';
import '../data/tmdb/tmdb_repository.dart';
import '../data/vod/cms_models.dart';
import '../data/vod/cms_sources.dart';
import '../data/vod/vod_repository.dart';
import '../player/player_controller.dart';
import 'config.dart';
import 'tab_feed.dart';

enum AppPage { home, play, settings, search }

/// How the search page resolves results:
///   • [tmdb] — search TMDB for metadata, then match a playable CMS stream by
///     title when a result is opened (the original behaviour).
///   • [cms]  — search every enabled CMS source directly; each hit is one
///     playable resource that opens straight into the player.
/// Both modes feed the SAME history/继续观看 store.
enum SearchMode { tmdb, cms }

class ToastEvent {
  final String text;
  final int seq;
  const ToastEvent(this.text, this.seq);
}

/// Central UI state + orchestration. Owns per-tab feed caches, infinite-scroll
/// paging, watch history, and the CMS-backed playback pipeline.
///
/// Catalogue/search come from TMDB; playable streams are resolved by title
/// across the enabled CMS sources ([VodRepository]). The mock player is used in
/// tests; production injects the real [VideoAdapter].
class AppController extends ChangeNotifier {
  AppController({
    ContentRepository? repository,
    PlayerController? player,
    HistoryStore? history,
    SettingsStore? settings,
    VodRepository? vod,
    DanmakuController? danmaku,
    IptvController? iptv,
    LiveProbeController? liveProbe,
    DateTime Function()? clock,
  })  : _injectedRepo = repository,
        _clock = clock ?? DateTime.now,
        player = player ?? MockPlayerController(),
        history = history ?? HistoryStore(),
        settings = settings ?? SettingsStore(),
        vodRepo = vod ?? VodRepository(),
        danmaku = danmaku ?? DanmakuController(),
        iptv = iptv ?? IptvController() {
    // Needs the resolved [iptv] to share its HTTP client, so this can't sit in
    // the initializer list above.
    this.liveProbe = liveProbe ?? LiveProbeController(client: this.iptv.client);
  }

  /// Test seam: the wall clock used for progress-save throttling, so a test can
  /// simulate a slow stream open without sleeping.
  final DateTime Function() _clock;

  int _nowMs() => _clock().millisecondsSinceEpoch;

  /// Test seam: a repository passed in directly bypasses the settings/key flow.
  final ContentRepository? _injectedRepo;
  ContentRepository? _builtRepo;

  ContentRepository? get repository => _injectedRepo ?? _builtRepo;

  final PlayerController player;
  final HistoryStore history;
  final SettingsStore settings;
  final VodRepository vodRepo;

  /// Danmaku (弹幕) pipeline for the play page: auto/manual match, config, and
  /// the parsed comment stream the [DanmakuOverlay] renders.
  final DanmakuController danmaku;

  /// IPTV (直播) browsing state: sources, channels, and the current channel.
  /// Playback is driven by [openChannel]; this only tracks selection.
  final IptvController iptv;

  /// Diagnosis of the channel currently being opened: is it actually a live
  /// stream, or a dead host / a finished file / a frozen origin? Runs alongside
  /// playback and keeps nothing. Deliberately its own notifier rather than
  /// state on [AppController] or [iptv] — a verdict update must rebuild only
  /// the small badge, never the home tree or the (non-virtualized) channel list.
  late final LiveProbeController liveProbe;

  /// Whether a usable data source exists (injected repo in tests, or a saved
  /// TMDB key in production).
  bool get hasApiKey => _injectedRepo != null || settings.tmdbApiKey.isNotEmpty;

  // Isolated notifiers for high-frequency / localized updates.
  final ValueNotifier<String?> heroBg = ValueNotifier<String?>(null);
  final ValueNotifier<ToastEvent?> toast = ValueNotifier<ToastEvent?>(null);
  int _toastSeq = 0;

  /// Bumped when returning to the home page so the header can move focus onto
  /// the active nav tab (e.g. 推荐), keeping the focus ring on-screen.
  final ValueNotifier<int> homeFocusRequest = ValueNotifier<int>(0);

  /// Bumped when the home page should scroll back to the very top — e.g. when a
  /// nav tab (re)gains focus — so the large hero background is shown in full.
  final ValueNotifier<int> homeScrollTopRequest = ValueNotifier<int>(0);

  /// When leaving the player back to home, the [VodItem.key] of the title that
  /// was playing. The home screen consumes this on the next [homeFocusRequest]
  /// bump to restore focus onto that title's 继续观看 / 最近播放 card (the just-
  /// watched item floats to the front of the recent rail), instead of the nav
  /// tab. Falls back to the active tab when no matching card is on screen (e.g.
  /// a tab without a recent rail). Cleared by the home screen once handled.
  String? pendingHomeFocusKey;

  /// Where a Back press from the play page should return to. Captured from the
  /// page the player was opened from (home vs. search) at [openTitle] /
  /// [openCmsHit] time, so Back honours the origin instead of always dumping the
  /// user on home. Home is the default (category cards, 最近播放 / 继续观看 rails).
  AppPage _playReturnPage = AppPage.home;

  /// When the player was opened from the search page, the [VodItem.key] of the
  /// opened result. The rebuilt [SearchScreen] consumes this on return to move
  /// focus back onto that result card (and clears it). Null when the origin
  /// wasn't search.
  String? pendingSearchFocusKey;

  final Map<int, TabFeed> _feeds = {};

  int currentTab = 1; // 推荐
  AppPage page = AppPage.home;
  bool fullscreen = false;
  bool scrolled = false;

  /// Registered by the fullscreen player layer so a Back press can be handled
  /// by it first (e.g. close its settings menu) before the app-level back
  /// logic runs. Returns true when it consumed the Back. Only consulted while
  /// [fullscreen] is true; cleared when the fullscreen layer is disposed.
  bool Function()? fullscreenBackInterceptor;

  /// Registered by the inline 直播 page while its channel-switch overlay is open,
  /// so a Back press closes the overlay (instead of leaving the tab) before the
  /// app-level back logic runs. Returns true when it consumed the Back.
  bool Function()? liveMenuBackInterceptor;

  /// A single physical Back press is delivered on up to TWO channels on some
  /// Android TV embeddings: once as a raw key event (goBack/Esc/browserBack via
  /// [backFromKey]) and once as a navigation pop (PopScope via [backFromPop]).
  /// Both must funnel to the same handler, but the duplicate must be dropped —
  /// otherwise one press advances two steps (e.g. fullscreen → straight to home,
  /// skipping the un-fullscreen step).
  ///
  /// The old fix debounced by wall-clock alone, which is fundamentally fragile:
  /// leaving fullscreen triggers a heavy relayout (the video surface resizes),
  /// so the trailing duplicate can land a long frame — and >300ms — after the
  /// first and slip past a short window, while a window long enough to catch it
  /// would also eat a genuine fast second press. We instead dedupe by *source*:
  /// a press fires at most once per channel, so when the OTHER channel just
  /// fired we treat this as its duplicate and absorb it. Rapid *distinct* presses
  /// arrive on the SAME channel (pop,pop or key,key) and are never deduped
  /// against each other, so stepping back quickly still works.
  DateTime? _lastKeyBackAt;
  DateTime? _lastPopBackAt;

  /// How long the twin deliveries of one press may be apart. Generous enough to
  /// survive the fullscreen-exit relayout jank; cross-channel matching keeps it
  /// from swallowing real repeat presses.
  static const Duration _backPairWindow = Duration(milliseconds: 700);

  /// Timestamp of the last Back press while already on the home page. A second
  /// press within 2s raises [exitConfirmVisible] (double-Back to exit).
  DateTime? _lastHomeBackAt;

  /// When true, the Shell renders a modal "exit app?" confirm overlay.
  bool exitConfirmVisible = false;

  /// The [FocusNode] of the currently-active nav tab, registered by the header
  /// tab strip. The tabs are marked `skipTraversal` so geometric D-pad moves
  /// from page content can never *accidentally* land on (and thus switch) a
  /// tab; crossing into the strip is always explicit and always targets the
  /// *current* tab via [focusActiveTab] — never whichever tab happens to sit
  /// geometrically above the focused card. Cleared when the strip is disposed.
  FocusNode? activeTabFocusNode;

  /// Move focus onto the active nav tab. Used by the top content row (Up) and
  /// the header tools (Down) to enter the tab strip deterministically. Returns
  /// true when it took focus (only on the home page, with a live node).
  bool focusActiveTab() {
    final n = activeTabFocusNode;
    if (page != AppPage.home || n == null || !n.canRequestFocus) return false;
    n.requestFocus();
    return true;
  }

  // --- Playback state -------------------------------------------------------
  VodItem? currentItem;
  VodDetail? currentDetail;
  int lineIndex = 0;
  int episodeIndex = 0;
  double speed = 1.0;
  bool resolving = false; // matching a playable CMS resource
  String? playError; // set when no source / no resource found
  List<ResourceOption> resourceOptions = const [];
  bool loadingResources = false;

  // per-title skip profile (mirrors BearTV skipProfiles)
  bool skipEnabled = false;
  int introSec = 0;
  int endingSec = 0;

  // --- Search state ---------------------------------------------------------
  /// TMDB (metadata + title-match) vs. CMS (direct resource) search. In-memory
  /// per session; defaults to TMDB. See [SearchMode].
  SearchMode searchMode = SearchMode.tmdb;
  List<VodItem> searchResults = const []; // TMDB-mode results
  List<SearchHit> cmsResults = const []; // CMS-direct-mode results
  bool searching = false;
  String searchQuery = '';

  /// Recent search queries (most-recent-first, capped at [_kMaxSearchHistory]),
  /// shown below the search box so a term can be re-run with one tap. Loaded
  /// from [SettingsStore] on [init] and persisted on every search. Shared across
  /// both search modes.
  List<String> searchHistory = const [];
  static const int _kMaxSearchHistory = 8;

  // Guards stale async results when the user rapidly re-opens titles.
  int _playToken = 0;
  int _lastSaveMs = 0;
  bool _introSkipHandled = false;
  bool _advancing = false;

  /// True once the player reports the current episode as ready (armed from
  /// [_onTick]). Backing out while the title is still resolving, or after the
  /// stream failed to open, must NOT touch the saved record — see
  /// [_handleBack].
  bool _playStarted = false;

  /// The feed for the visible tab (always non-null after [setTab]).
  TabFeed get feed => _feeds[currentTab]!;

  /// Nullable variant for the very first frame before [init] runs.
  TabFeed? get currentFeed => _feeds[currentTab];

  List<VodItem> get continueWatch => history.items;

  /// The saved watch record for [item], if any — powers the 最近播放 / 继续观看
  /// rails' progress bar + source label (and exact-resource resume).
  HistoryEntry? historyEntryFor(VodItem item) => history.entryFor(item.key);

  /// Delete a watch record (from the 最近播放 MENU-key action). Updates the rail
  /// immediately; persistence is best-effort inside [HistoryStore.remove].
  void removeHistory(String vodKey) {
    if (history.remove(vodKey)) {
      if (pendingHomeFocusKey == vodKey) pendingHomeFocusKey = null;
      notifyListeners();
    }
  }

  // --- Selected CMS sources -------------------------------------------------
  List<CmsSite> get _allSites => [...kBuiltinSites, ...settings.customSites];

  /// The enabled sources, in built-in-then-custom order.
  List<CmsSite> get selectedSites {
    final ids = settings.selectedSourceIds.toSet();
    return _allSites.where((s) => ids.contains(s.id)).toList();
  }

  CmsSite? _siteById(String id) {
    for (final s in _allSites) {
      if (s.id == id) return s;
    }
    return null;
  }

  // --- Current-episode helpers ---------------------------------------------
  List<Episode> _episodesFor(int line) {
    final d = currentDetail;
    if (d == null || line < 0 || line >= d.playLines.length) return const [];
    return d.playLines[line].episodes;
  }

  List<Episode> get currentEpisodes => _episodesFor(lineIndex);

  /// CMS-direct items (`openCmsHit`) have no TMDB genre: their [VodItem.genre]
  /// carries the source name instead. After a 切换资源 that label has to follow
  /// the new source, otherwise the play page's meta row and the history card
  /// keep advertising the first source ever used. TMDB items keep their real
  /// genre untouched. The [VodItem.key] is unaffected, so history/resume stay
  /// keyed to the same title.
  VodItem _itemWithSource(VodItem item, String? sourceName) {
    if (sourceName == null || sourceName.isEmpty) return item;
    if (!item.mediaType.startsWith('cms:')) return item;
    if (item.genre == sourceName) return item;
    return item.withGenre(sourceName);
  }

  Episode? _episodeAt(int line, int ep) {
    final eps = _episodesFor(line);
    if (ep < 0 || ep >= eps.length) return null;
    return eps[ep];
  }

  Future<void> init() async {
    await Future.wait([history.init(), settings.init()]);
    searchHistory = settings.searchHistory;
    danmaku.init(settings);
    iptv.init(settings);
    player.addListener(_onTick);
    _applyProxy();
    _rebuildRepository();
    if (repository != null) {
      await setTab(currentTab, silent: true);
    } else {
      notifyListeners(); // no key yet — the home screen shows the setup prompt
    }
  }

  /// Push the saved proxy settings into [Config] so both the API client and the
  /// image-URL mappers route through the proxy (or direct) consistently.
  void _applyProxy() {
    Config.applyProxy(
        enabled: settings.proxyEnabled, proxyBase: settings.proxyBase);
  }

  /// (Re)build the TMDB repository from the saved key. No-op when a repository
  /// was injected for tests.
  void _rebuildRepository() {
    if (_injectedRepo != null) return;
    final key = settings.tmdbApiKey;
    (_builtRepo as TmdbRepository?)?.close();
    _builtRepo = key.isNotEmpty ? TmdbRepository(apiKey: key) : null;
  }

  /// Persist a new TMDB key, rebuild the repository, drop cached feeds, and
  /// reload the current tab. Called from the Settings page.
  Future<void> saveApiKey(String key) async {
    await settings.setTmdbApiKey(key);
    _rebuildRepository();
    for (final f in _feeds.values) {
      f.dispose();
    }
    _feeds.clear();
    page = AppPage.home;
    if (repository != null) {
      showToast('已保存 · 正在加载内容');
      await setTab(currentTab, silent: true);
    } else {
      showToast('已清除 API Key');
      notifyListeners();
    }
  }

  void openSettings() {
    if (page == AppPage.settings) return;
    if (isLiveTab) player.pause(); // don't leave a live stream playing behind it
    page = AppPage.settings;
    notifyListeners();
  }

  // --- TMDB network proxy ---------------------------------------------------

  bool get proxyEnabled => settings.proxyEnabled;
  String get proxyBase => settings.proxyBase;

  /// Re-apply proxy config, rebuild the repository, drop cached feeds and
  /// reload the current tab. Used whenever the TMDB routing changes.
  Future<void> _reconfigureAndReload(String toastMsg) async {
    _applyProxy();
    _rebuildRepository();
    for (final f in _feeds.values) {
      f.dispose();
    }
    _feeds.clear();
    page = AppPage.home;
    if (repository != null) {
      showToast(toastMsg);
      await setTab(currentTab, silent: true);
    } else {
      notifyListeners();
    }
  }

  /// Toggle routing TMDB through the proxy vs. the direct domain.
  Future<void> setProxyEnabled(bool v) async {
    await settings.setProxyEnabled(v);
    await _reconfigureAndReload(v ? '已开启代理 · 正在重新加载' : '已关闭代理 · 走原域名');
  }

  /// Update the proxy origin. Only reloads when the proxy is currently enabled.
  Future<void> setProxyBase(String base) async {
    await settings.setProxyBase(base);
    if (settings.proxyEnabled) {
      await _reconfigureAndReload('已更新代理地址 · 正在重新加载');
    } else {
      notifyListeners();
    }
  }

  // --- Search input method --------------------------------------------------

  /// Whether the search page uses the system IME (native input + system
  /// keyboard) vs. the built-in offline pinyin keyboard.
  bool get searchUseSystemIme => settings.searchUseSystemIme;

  Future<void> setSearchUseSystemIme(bool v) async {
    await settings.setSearchUseSystemIme(v);
    notifyListeners();
  }

  void openSearch() {
    if (page == AppPage.search) return;
    if (isLiveTab) player.pause();
    page = AppPage.search;
    // Start each visit blank: clear any results/query left from a prior visit,
    // so re-entering search doesn't show the last search's grid. The chosen
    // [searchMode] is kept across visits within the session.
    searchResults = const [];
    cmsResults = const [];
    searchQuery = '';
    searching = false;
    notifyListeners();
  }

  Future<void> setTab(int i, {bool silent = false}) async {
    // Leaving the 直播 tab: stop any live stream so no decoder lingers. The
    // probe verdict is deliberately left alone — it describes
    // [IptvController.currentChannel], which only ever changes via [openChannel]
    // (which re-probes), and the badge only renders inside the live player.
    if (currentTab == kIptvTab && i != kIptvTab) {
      player.pause();
      player.open(null);
    }
    currentTab = i;
    page = AppPage.home;

    // 直播 (IPTV) is not a TMDB feed: render the browser and lazily load the
    // selected source's channels the first time it's opened. Never touches
    // [repository], so it works without a TMDB key.
    if (i == kIptvTab) {
      notifyListeners();
      if (iptv.channels.isEmpty && iptv.error == null && !iptv.loading) {
        await iptv.loadChannels();
      }
      // Auto-play the first channel so 直播 opens straight into video; the
      // user switches from there via the ↑/↓ overlay. Never overrides a channel
      // that's already playing (e.g. returning to the tab).
      if (iptv.currentChannel == null && iptv.filteredChannels.isNotEmpty) {
        await openChannel(iptv.filteredChannels.first);
      }
      return;
    }

    // No data source yet: just switch tabs; the home screen renders the prompt.
    if (repository == null) {
      notifyListeners();
      return;
    }
    final cached = _feeds[i];
    if (cached != null) {
      if (cached.heroBgUrl != null) heroBg.value = cached.heroBgUrl;
      notifyListeners();
      return;
    }
    final f = _feeds[i] = TabFeed(i);
    notifyListeners(); // paint the loading state immediately
    await _loadFirst(f);
  }

  Future<void> _loadFirst(TabFeed f) async {
    final repo = repository;
    if (repo == null) return;
    // 我的 (tab 0) is local-only: recent play, no remote catalogue.
    if (f.tabIndex == 0) {
      f.hasMore = false;
      f.status.value = FeedStatus.end;
      notifyListeners();
      return;
    }
    f.status.value = FeedStatus.loading;
    notifyListeners();
    try {
      final p = await repo.loadFeed(f.tabIndex, 1, sort: f.segIndex);
      f.page = 1;
      f.hero = p.items.take(8).toList();
      f.heroBgUrl = f.hero.isNotEmpty ? f.hero.first.bgUrl : null;
      f.library.value = p.items;
      f.hasMore = p.hasMore;
      f.status.value = p.hasMore ? FeedStatus.idle : FeedStatus.end;
      if (f.heroBgUrl != null && currentTab == f.tabIndex)
        heroBg.value = f.heroBgUrl;
    } catch (_) {
      f.status.value = FeedStatus.error;
    } finally {
      notifyListeners();
    }
  }

  /// Fetch and append the next library page. Deduped via [TabFeed.inFlight];
  /// no-op once [TabFeed.hasMore] is false.
  Future<void> loadMore() async {
    final repo = repository;
    final f = _feeds[currentTab];
    if (repo == null || f == null || f.inFlight || !f.hasMore) return;
    if (f.status.value == FeedStatus.loading) return;
    f.inFlight = true;
    f.status.value = FeedStatus.loadingMore;
    try {
      final next = f.page + 1;
      final p = await repo.loadFeed(f.tabIndex, next, sort: f.segIndex);
      f.page = next;
      f.library.value = [...f.library.value, ...p.items];
      f.hasMore = p.hasMore;
      f.status.value = p.hasMore ? FeedStatus.idle : FeedStatus.end;
    } catch (_) {
      f.status.value = FeedStatus.error;
    } finally {
      f.inFlight = false;
    }
  }

  /// Retry after an error (first page or a failed loadMore).
  Future<void> retry() async {
    final f = _feeds[currentTab];
    if (f == null) return;
    if (f.page == 0) {
      await _loadFirst(f);
    } else {
      f.status.value = FeedStatus.idle;
      await loadMore();
    }
  }

  void setHeroBg(String url) => heroBg.value = url;

  void setScrolled(bool v) {
    if (v == scrolled) return;
    scrolled = v;
    notifyListeners();
  }

  // --- Search (TMDB / CMS-direct) -------------------------------------------

  /// Switch the search page between TMDB-match and CMS-direct modes. Clears the
  /// old mode's results and re-runs the current query (if any) in the new mode.
  void setSearchMode(SearchMode mode) {
    if (searchMode == mode) return;
    searchMode = mode;
    searchResults = const [];
    cmsResults = const [];
    if (searchQuery.isNotEmpty) {
      search(searchQuery);
    } else {
      notifyListeners();
    }
  }

  /// Run a search for [keyword] in the active [searchMode] and populate the
  /// matching result list. TMDB results feed [openTitle] (title → CMS resolve);
  /// CMS results feed [openCmsHit] (direct resource play). Both share history.
  Future<void> search(String keyword) async {
    final q = keyword.trim();
    searchQuery = q;
    if (q.isEmpty) {
      searchResults = const [];
      cmsResults = const [];
      searching = false;
      notifyListeners();
      return;
    }
    _recordSearchHistory(q);
    searching = true;
    searchResults = const [];
    cmsResults = const [];
    notifyListeners();
    try {
      if (searchMode == SearchMode.cms) {
        cmsResults = await vodRepo.searchAll(q, selectedSites);
      } else {
        final repo = repository;
        if (repo != null) {
          final p = await repo.search(q, 1);
          searchResults = p.items;
        }
      }
    } catch (_) {
      searchResults = const [];
      cmsResults = const [];
    } finally {
      searching = false;
      notifyListeners();
    }
  }

  /// Push [q] onto the recent-search list: dedupe case-insensitively, move it to
  /// the front, cap at [_kMaxSearchHistory], and persist (best-effort).
  void _recordSearchHistory(String q) {
    final query = q.trim();
    if (query.isEmpty) return;
    final list = [...searchHistory]
      ..removeWhere((e) => e.toLowerCase() == query.toLowerCase());
    list.insert(0, query);
    if (list.length > _kMaxSearchHistory) {
      list.removeRange(_kMaxSearchHistory, list.length);
    }
    searchHistory = list;
    settings.setSearchHistory(list);
  }

  /// Clear the recent-search list (and its persisted copy).
  void clearSearchHistory() {
    if (searchHistory.isEmpty) return;
    searchHistory = const [];
    settings.setSearchHistory(const []);
    notifyListeners();
  }

  // --- Playback: resolve a title to a real CMS stream -----------------------

  /// Unified entry for BOTH category cards and search results: enter the play
  /// page, then resolve a playable CMS resource by title across [selectedSites]
  /// and auto-play the best match (resuming a saved position when available).
  Future<void> openTitle(VodItem item) async {
    final token = ++_playToken;
    _playStarted = false;
    currentItem = item;
    // Remember where we came from so Back leaves the player back to the right
    // page (search keeps its query + results; home restores the rail card).
    _playReturnPage = page == AppPage.search ? AppPage.search : AppPage.home;
    pendingHomeFocusKey = item.key;
    pendingSearchFocusKey =
        _playReturnPage == AppPage.search ? item.key : null;
    currentDetail = null;
    resourceOptions = const [];
    lineIndex = 0;
    episodeIndex = 0;
    playError = null;
    resolving = true;
    page = AppPage.play;
    fullscreen = false;
    scrolled = true;
    heroBg.value = item.bgUrl;

    // Load per-title memory (skip profile, speed) up front.
    final entry = history.entryFor(item.key);
    skipEnabled = entry?.skipEnabled ?? false;
    introSec = entry?.introSec ?? 0;
    endingSec = entry?.endingSec ?? 0;
    speed = entry?.speed ?? 1.0;
    notifyListeners();

    // 1) Prefer resuming the exact recorded resource. History is keyed by the
    //    TMDB title but also stores the CMS reference (sourceId+vodId), so
    //    re-entering from 播放记录 continues the *same* source rather than
    //    re-searching by title (which could pick a different provider). Mirrors
    //    BearTV, which keys history/progress by `id + sourceId`.
    VodDetail? detail;
    if (entry != null && entry.vodId.isNotEmpty) {
      final site = _siteById(entry.sourceId);
      if (site != null) {
        final recorded = await vodRepo.detail(site, entry.vodId);
        if (token != _playToken) return; // superseded by a newer openTitle
        if (recorded != null && recorded.firstEpisode != null)
          detail = recorded;
      }
    }

    // 2) Otherwise resolve the best playable resource across enabled sources.
    if (detail == null) {
      final sites = selectedSites;
      if (sites.isEmpty) {
        resolving = false;
        playError = '尚未启用任何播放源，请在设置中开启或添加。';
        await player.open(null);
        notifyListeners();
        return;
      }
      detail = await vodRepo.resolveByTitle(item.title, sites);
      if (token != _playToken) return; // superseded by a newer openTitle
    }

    if (detail == null || detail.firstEpisode == null) {
      resolving = false;
      playError = '未找到「${item.title}」的可播放资源，可在设置中添加更多播放源。';
      await player.open(null);
      notifyListeners();
      return;
    }

    currentDetail = detail;
    // Keep a CMS-direct item's source label in step with the resource that
    // actually resolved (title re-resolve may land on a different source).
    currentItem = _itemWithSource(item, detail.sourceName);
    // Resume only when the resolved resource matches the saved one.
    var resumeMs = 0;
    if (entry != null && entry.resourceKey == detail.key) {
      lineIndex = entry.lineIndex.clamp(0, detail.playLines.length - 1);
      final eps = _episodesFor(lineIndex).length;
      episodeIndex = eps == 0 ? 0 : entry.episodeIndex.clamp(0, eps - 1);
      if (entry.positionMs > 5000) resumeMs = entry.positionMs;
    }
    resolving = false;
    notifyListeners();

    // Deliberately NO history write here: merely opening a record (then
    // backing out while it loads) must leave the saved 第N集 · mm:ss intact.
    // The record is only rewritten once the stream is ready (see [_onTick]) or
    // on a guarded exit (see [_handleBack]).
    await _playCurrent(resumeMs: resumeMs);
    _scheduleResourceOptions(); // background: build the switch-resource list
  }

  /// Build a synthetic [VodItem] for a CMS-direct [SearchHit] so it flows
  /// through the same play page, history store and 继续观看 rail as a TMDB
  /// title. The key folds in the source id (`cms:<sourceId>:<id>`) so each
  /// source's resource is distinct and resuming re-enters the same stream.
  VodItem _cmsItemFor(SearchHit hit) {
    final cover = hit.cover;
    return VodItem(
      id: int.tryParse(hit.vodId) ?? hit.vodId.hashCode,
      mediaType: 'cms:${hit.sourceId}',
      title: hit.title,
      en: '',
      genre: hit.sourceName,
      desc: hit.remarks,
      year: int.tryParse(hit.year) ?? 0,
      score: '—',
      ep: 0,
      hd: 'HD',
      neu: false,
      bgUrl: cover,
      cardUrl: cover,
      posterUrl: cover,
    );
  }

  /// Direct-play a CMS search hit (资源直搜 mode): enter the play page and play
  /// the hit's exact source/resource — no title re-matching. Resumes from the
  /// shared history when this same resource was watched before, and still
  /// builds the cross-source 切换资源 list by title.
  Future<void> openCmsHit(SearchHit hit) async {
    final token = ++_playToken;
    _playStarted = false;
    final item = _cmsItemFor(hit);
    currentItem = item;
    _playReturnPage = page == AppPage.search ? AppPage.search : AppPage.home;
    pendingHomeFocusKey = item.key;
    pendingSearchFocusKey =
        _playReturnPage == AppPage.search ? item.key : null;
    currentDetail = null;
    resourceOptions = const [];
    lineIndex = 0;
    episodeIndex = 0;
    playError = null;
    resolving = true;
    page = AppPage.play;
    fullscreen = false;
    scrolled = true;
    heroBg.value = item.bgUrl;

    final entry = history.entryFor(item.key);
    skipEnabled = entry?.skipEnabled ?? false;
    introSec = entry?.introSec ?? 0;
    endingSec = entry?.endingSec ?? 0;
    speed = entry?.speed ?? 1.0;
    notifyListeners();

    final site = _siteById(hit.sourceId);
    final detail = site == null ? null : await vodRepo.detail(site, hit.vodId);
    if (token != _playToken) return; // superseded by a newer open

    if (detail == null || detail.firstEpisode == null) {
      resolving = false;
      playError = '「${hit.title}」在该资源站暂不可用，换一个结果试试。';
      await player.open(null);
      notifyListeners();
      return;
    }

    currentDetail = detail;
    currentItem = _itemWithSource(item, detail.sourceName);
    // Resume only when re-entering the exact same resource we recorded.
    var resumeMs = 0;
    if (entry != null && entry.resourceKey == detail.key) {
      lineIndex = entry.lineIndex.clamp(0, detail.playLines.length - 1);
      final eps = _episodesFor(lineIndex).length;
      episodeIndex = eps == 0 ? 0 : entry.episodeIndex.clamp(0, eps - 1);
      if (entry.positionMs > 5000) resumeMs = entry.positionMs;
    }
    resolving = false;
    notifyListeners();

    // No history write while only opening the page — see [openTitle].
    await _playCurrent(resumeMs: resumeMs);
    _scheduleResourceOptions();
  }

  /// Open the current (lineIndex/episodeIndex) episode in the player.
  Future<void> _playCurrent({int resumeMs = 0}) async {
    _introSkipHandled = false;
    _advancing = false;
    // Not "playing" until the stream is ready AND the resume seek has landed:
    // until then the player reports position 0, and persisting that would wipe
    // the very progress we just resumed from.
    _playStarted = false;
    _lastSaveMs = _nowMs();
    final ep = _episodeAt(lineIndex, episodeIndex);
    // Kick danmaku off first: it's an independent HTTP pipeline and must not
    // queue behind the video open/seek/play calls (it used to start only after
    // `play()`, which put the match round-trips behind the stream startup).
    _loadDanmakuForCurrentEpisode();
    await player.open(ep?.url);
    if (resumeMs > 0) await player.seekTo(Duration(milliseconds: resumeMs));
    // Arm progress saving only once the reported position means something.
    if (player.value.ready) {
      _playStarted = true;
      _lastSaveMs = _nowMs(); // start the throttle window after the seek
    }
    await player.setSpeed(speed);
    await player.play();
  }

  /// Best-effort danmaku match for the current episode (never blocks playback,
  /// and never touches the network when danmaku is disabled).
  void _loadDanmakuForCurrentEpisode() {
    final item = currentItem;
    if (item == null) return;
    // The CMS detail title is usually closer to the release name the danmaku
    // server indexes than the TMDB title; [autoLoad] falls back to [item.title].
    unawaited(danmaku.autoLoad(
      item.title,
      episodeIndex,
      detailTitle: currentDetail?.title,
    ));
  }

  /// Build the cross-source "switch resource" candidates for the current title.
  ///
  /// Deferred a few seconds after start: it runs one search + detail request per
  /// source, and firing that concurrently with the first video segments makes
  /// start-up noticeably slower on a weak network. A newer open supersedes it.
  void _scheduleResourceOptions() {
    _resourceOptionsTimer?.cancel();
    final token = ++_resourceOptionsToken;
    final playToken = _playToken;
    // Show the "正在查找其他资源…" placeholder right away; only the network
    // work is deferred.
    if (currentItem != null) {
      loadingResources = true;
      notifyListeners();
    }
    _resourceOptionsTimer = Timer(const Duration(milliseconds: 2500), () {
      if (token != _resourceOptionsToken || playToken != _playToken) return;
      if (page != AppPage.play) {
        loadingResources = false;
        notifyListeners();
        return;
      }
      _loadResourceOptions();
    });
  }

  Timer? _resourceOptionsTimer;
  int _resourceOptionsToken = 0;

  /// Load the cross-source "switch resource" candidates for the current title.
  Future<void> _loadResourceOptions() async {
    final item = currentItem;
    final token = _playToken;
    if (item == null) return;
    loadingResources = true;
    notifyListeners();
    final opts = await vodRepo.loadResourceOptions(
      item.title,
      selectedSites,
      current: currentDetail,
    );
    if (token != _playToken) return;
    resourceOptions = opts;
    loadingResources = false;
    notifyListeners();
  }

  /// Jump to episode [index] on the current line (0-based).
  Future<void> selectEpisode(int index) async {
    final eps = currentEpisodes;
    if (eps.isEmpty) return;
    episodeIndex = index.clamp(0, eps.length - 1);
    notifyListeners();
    _persistHistory(positionMs: 0, durationMs: 0);
    await _playCurrent(resumeMs: 0);
  }

  /// Switch to play line [index] (keeps at episode 0).
  Future<void> selectLine(int index) async {
    final d = currentDetail;
    if (d == null || index < 0 || index >= d.playLines.length) return;
    lineIndex = index;
    episodeIndex = 0;
    notifyListeners();
    _persistHistory(positionMs: 0, durationMs: 0);
    await _playCurrent(resumeMs: 0);
  }

  /// Whether the current line has an episode after [episodeIndex]. Drives the
  /// 播放下一集 shortcut in the fullscreen 选集 sheet: hidden on a movie, on a
  /// single-episode source and on the last episode, so the button never lies.
  bool get hasNextEpisode {
    final eps = currentEpisodes;
    return eps.length > 1 && episodeIndex >= 0 && episodeIndex + 1 < eps.length;
  }

  /// Play the next episode (auto-continue). Toasts when already at the end.
  Future<void> nextEpisode() async {
    final eps = currentEpisodes;
    if (episodeIndex + 1 < eps.length) {
      showToast('播放下一集');
      await selectEpisode(episodeIndex + 1);
    } else {
      showToast('已经是最后一集');
    }
  }

  /// Switch to another source's resource, preserving the current position.
  Future<void> switchResource(ResourceOption option) async {
    final token = ++_playToken;
    final resumeMs = player.value.position.inMilliseconds;
    var detail = option.detail;
    if (detail == null) {
      final site = _siteById(option.sourceId);
      if (site != null) detail = await vodRepo.detail(site, option.vodId);
    }
    if (token != _playToken) return;
    if (detail == null || detail.firstEpisode == null) {
      showToast('该资源暂不可用');
      return;
    }
    currentDetail = detail;
    final item = currentItem;
    if (item != null) currentItem = _itemWithSource(item, detail.sourceName);
    lineIndex = 0;
    final eps = _episodesFor(0).length;
    episodeIndex = eps == 0 ? 0 : episodeIndex.clamp(0, eps - 1);
    showToast('已切换到「${detail.sourceName}」');
    notifyListeners();
    _persistHistory(positionMs: resumeMs > 5000 ? resumeMs : 0);
    await _playCurrent(resumeMs: resumeMs > 5000 ? resumeMs : 0);
    _scheduleResourceOptions();
  }

  Future<void> setSpeed(double v) async {
    speed = v;
    await player.setSpeed(v);
    notifyListeners();
    _persistHistory(positionMs: player.value.position.inMilliseconds);
  }

  void toggleSkip() {
    skipEnabled = !skipEnabled;
    _introSkipHandled = false;
    notifyListeners();
    _persistHistory(positionMs: player.value.position.inMilliseconds);
    showToast(skipEnabled ? '已开启片头片尾跳过' : '已关闭片头片尾跳过');
  }

  void setSkip({int? intro, int? ending}) {
    if (intro != null) introSec = intro < 0 ? 0 : intro;
    if (ending != null) endingSec = ending < 0 ? 0 : ending;
    if ((introSec > 0 || endingSec > 0) && !skipEnabled) skipEnabled = true;
    _introSkipHandled = false;
    notifyListeners();
    _persistHistory(positionMs: player.value.position.inMilliseconds);
  }

  // --- Danmaku (弹幕) controls ----------------------------------------------

  /// Toggle danmaku. Enabling mid-play kicks off an auto-match for the current
  /// episode (the earlier [autoLoad] no-ops while disabled).
  Future<void> setDanmakuEnabled(bool v) async {
    await danmaku.setEnabled(v);
    final item = currentItem;
    if (v && page == AppPage.play && item != null && danmaku.items.isEmpty) {
      _loadDanmakuForCurrentEpisode();
    }
    showToast(v ? '已开启弹幕' : '已关闭弹幕');
  }

  /// Manual danmaku match: search candidates for a user-typed keyword.
  Future<void> searchDanmaku(String keyword) => danmaku.search(keyword);

  /// Load the danmaku for a user-picked manual match.
  Future<void> pickDanmakuMatch(DanmakuMatch m) => danmaku.loadFromMatch(m);

  /// Relative seek (fullscreen ←/→). Clamps to [0, duration].
  Future<void> seekBy(Duration delta) async {    final v = player.value;
    var target = v.position + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (v.duration > Duration.zero && target > v.duration) target = v.duration;
    await player.seekTo(target);
  }

  /// Player listener: auto-skip intro/outro + throttled progress persistence.
  void _onTick() {
    if (page != AppPage.play || currentItem == null || currentDetail == null)
      return;
    final v = player.value;
    if (!v.ready) return;
    final pos = v.position;
    final dur = v.duration;

    if (skipEnabled && introSec > 0 && !_introSkipHandled) {
      if (pos.inSeconds > 0 && pos.inSeconds < introSec) {
        _introSkipHandled = true;
        player.seekTo(Duration(seconds: introSec));
        return;
      }
      if (pos.inSeconds >= introSec) _introSkipHandled = true;
    }

    if (skipEnabled && endingSec > 0 && dur.inMilliseconds > 0 && !_advancing) {
      if (pos.inMilliseconds >= dur.inMilliseconds - endingSec * 1000) {
        _advancing = true;
        nextEpisode();
        return;
      }
    }

    final now = _nowMs();
    // [_playStarted] guards the window between "the stream reported ready" and
    // "the resume seek landed" — writing there would persist 0:00.
    if (_playStarted && dur.inMilliseconds > 0 && now - _lastSaveMs > 5000) {
      _lastSaveMs = now;
      _persistHistory(
          positionMs: pos.inMilliseconds, durationMs: dur.inMilliseconds);
    }
  }

  /// Upsert the current title's history record from live state. When
  /// [positionMs]/[durationMs] are omitted the previous values are kept.
  void _persistHistory({int? positionMs, int? durationMs}) {
    final item = currentItem;
    if (item == null) return;
    final d = currentDetail;
    final prev = history.entryFor(item.key);
    history.put(HistoryEntry(
      // A CMS-direct item's genre is its source name; persist the currently
      // playing source so the history card's meta line matches the record.
      item: _itemWithSource(item, d?.sourceName),
      sourceId: d?.sourceId ?? prev?.sourceId ?? '',
      sourceName: d?.sourceName ?? prev?.sourceName ?? '',
      vodId: d?.vodId ?? prev?.vodId ?? '',
      lineIndex: lineIndex,
      episodeIndex: episodeIndex,
      positionMs: positionMs ?? prev?.positionMs ?? 0,
      durationMs: durationMs ?? prev?.durationMs ?? 0,
      skipEnabled: skipEnabled,
      introSec: introSec,
      endingSec: endingSec,
      speed: speed,
    ));
  }

  // --- IPTV (直播) playback -------------------------------------------------

  /// True while the 直播 tab is showing (used to render the live layer + pick
  /// live-appropriate fullscreen hints).
  bool get isLiveTab => page == AppPage.home && currentTab == kIptvTab;

  /// Select and start playing a live channel. Live streams have no resume /
  /// speed / history semantics, so this just points the shared player at the
  /// channel URL. Safe to call repeatedly (switching channels).
  Future<void> openChannel(IptvChannel ch) async {
    _channelPreview?.cancel(); // OK/tap flushes any pending debounced surf
    iptv.selectChannel(ch);
    // Diagnose in parallel with the load. The verdict is advisory, so it must
    // never delay or gate playback — this returns immediately and reports back
    // through [liveProbe] when it knows something.
    liveProbe.begin(ch.url);
    await player.open(ch.url);
    await player.play();
  }

  Timer? _channelPreview;

  /// Step to the previous/next channel within the current filtered list (used by
  /// both the inline player's ←/→ and the fullscreen ←/→). Wraps around. Returns
  /// the newly-opened channel, or null when there are no channels.
  IptvChannel? stepChannel(int delta) {
    final list = iptv.filteredChannels;
    if (list.isEmpty) return null;
    final cur = iptv.currentChannel;
    var idx = cur == null ? -1 : list.indexWhere((c) => c.url == cur.url);
    idx = (idx + delta) % list.length;
    if (idx < 0) idx += list.length;
    final next = list[idx];
    openChannel(next);
    return next;
  }

  /// Debounced "channel surfing": focusing a channel row (no OK press) previews
  /// it after a short settle, so fast D-pad scrolling through the list doesn't
  /// hammer the network with loads. The last channel the focus rests on wins.
  void previewChannel(IptvChannel ch) {
    _channelPreview?.cancel();
    if (iptv.currentChannel?.url == ch.url) return; // already the live channel
    _channelPreview = Timer(const Duration(milliseconds: 420), () {
      openChannel(ch);
    });
  }

  // --- CMS source management (settings page) --------------------------------

  bool isSiteSelected(String id) => settings.selectedSourceIds.contains(id);

  Future<void> toggleSite(String id) async {
    final ids = List<String>.from(settings.selectedSourceIds);
    if (ids.contains(id)) {
      ids.remove(id);
    } else {
      ids.add(id);
    }
    await settings.setSelectedSourceIds(ids);
    notifyListeners();
  }

  /// Add a custom source. Returns null on success, else an error message.
  Future<String?> addCustomSite(String name, String api) async {
    final n = name.trim();
    final a = api.trim();
    if (n.isEmpty || a.isEmpty) return '请填写名称与接口地址';
    if (!a.startsWith('http://') && !a.startsWith('https://'))
      return '接口地址需以 http 开头';
    final existing = settings.customSites;
    if (existing.length >= kMaxCustomSites)
      return '自定义源已达上限（$kMaxCustomSites 个）';
    final id = 'custom_${DateTime.now().millisecondsSinceEpoch}';
    final site = CmsSite(id: id, name: n, api: a, isCustom: true);
    await settings.setCustomSites([...existing, site]);
    // Enable it by default.
    await settings.setSelectedSourceIds([...settings.selectedSourceIds, id]);
    notifyListeners();
    return null;
  }

  Future<void> removeCustomSite(String id) async {
    await settings
        .setCustomSites(settings.customSites.where((s) => s.id != id).toList());
    await settings.setSelectedSourceIds(
        settings.selectedSourceIds.where((e) => e != id).toList());
    notifyListeners();
  }

  /// Back arrived as a raw key event (Esc / goBack / browserBack shortcut).
  void backFromKey() => _dispatchBack(fromKey: true);

  /// Back arrived as a navigation pop (hardware Back / PopScope).
  void backFromPop() => _dispatchBack(fromKey: false);

  /// Route both Back channels through one handler, dropping the duplicate of a
  /// single physical press (see [_backPairWindow]). When the *other* channel
  /// fired within the pair window, this is that press's twin — absorb it and
  /// reset both marks so the next real press pairs cleanly.
  void _dispatchBack({required bool fromKey}) {
    final now = DateTime.now();
    final other = fromKey ? _lastPopBackAt : _lastKeyBackAt;
    if (other != null && now.difference(other) < _backPairWindow) {
      _lastKeyBackAt = null;
      _lastPopBackAt = null;
      return;
    }
    if (fromKey) {
      _lastKeyBackAt = now;
    } else {
      _lastPopBackAt = now;
    }
    _handleBack();
  }

  void _handleBack() {
    final now = DateTime.now();

    // A visible exit dialog takes precedence: a fresh Back dismisses it.
    if (exitConfirmVisible) {
      cancelExit();
      return;
    }

    if (fullscreen) {
      // The fullscreen layer gets first refusal (e.g. close its open menu);
      // only if it doesn't consume the Back do we leave fullscreen.
      if (fullscreenBackInterceptor?.call() ?? false) return;
      setFullscreen(false);
      return;
    }
    // The inline 直播 overlay (channel switcher) closes on Back before anything
    // else — otherwise Back would fall through to the leave-tab / exit flow.
    if (liveMenuBackInterceptor?.call() ?? false) return;
    if (page == AppPage.play) {
      // Only a playback that actually started may rewrite the record. Backing
      // out while the title is still resolving (or after the open failed) used
      // to persist episode 0 / position 0 and wipe the saved 第N集 · mm:ss.
      if (_playStarted) {
        _persistHistory(
          positionMs: player.value.position.inMilliseconds,
          durationMs: player.value.duration.inMilliseconds,
        );
      }
      _stopPlayback();
      if (_playReturnPage == AppPage.search) {
        // Return to the search page with its query + results intact (the
        // rebuilt SearchScreen reads searchQuery / pendingSearchFocusKey). Do
        // NOT go through openSearch(), which would wipe the results.
        page = AppPage.search;
        pendingHomeFocusKey = null; // not returning to home
        notifyListeners();
      } else {
        page = AppPage.home;
        scrolled = false;
        notifyListeners();
        homeFocusRequest.value++;
      }
    } else if (page == AppPage.settings || page == AppPage.search) {
      page = AppPage.home;
      notifyListeners();
      homeFocusRequest.value++;
    } else {
      // Already home. If the D-pad focus is somewhere in the page content (not
      // on the nav tab), the first Back returns focus to the active tab — which
      // also scrolls the page to the top so the hero background shows — instead
      // of starting the exit countdown. Only once focus is on the tab does a
      // Back begin the double-Back-to-exit flow.
      final onTab = activeTabFocusNode?.hasFocus ?? false;
      if (!onTab && focusActiveTab()) {
        homeScrollTopRequest.value++;
        return;
      }
      // Focus already on the tab: require a second Back within 2s, then confirm.
      if (_lastHomeBackAt != null &&
          now.difference(_lastHomeBackAt!) < const Duration(seconds: 2)) {
        _lastHomeBackAt = null;
        exitConfirmVisible = true;
        notifyListeners();
      } else {
        _lastHomeBackAt = now;
        showToast('再按一次返回键退出');
      }
    }
  }

  /// Fully stop and release the player, and cancel any in-flight resolve. Called
  /// whenever we leave the play page so no decoder lingers in the background and
  /// a slow title-resolve can't start playing after we've already left.
  void _stopPlayback() {
    _playToken++; // invalidate pending openTitle/switchResource async work
    _playStarted = false;
    resolving = false;
    danmaku.clear();
    player.pause();
    player.open(null); // VideoAdapter disposes the inner controller here
  }

  /// Dismiss the exit-confirm dialog without leaving the app.
  void cancelExit() {
    if (!exitConfirmVisible) return;
    exitConfirmVisible = false;
    _lastHomeBackAt = null;
    notifyListeners();
  }

  void setFullscreen([bool? v]) {
    final next = v ?? !fullscreen;
    if (next == fullscreen) return;
    fullscreen = next;
    if (next) {
      showToast(isLiveTab
          ? '已进入全屏 · 上键频道列表 · 返回退出'
          : '已进入全屏 · 上键菜单 · 左右快进退 · 返回退出');
    }
    notifyListeners();
  }

  int get segIndex => _feeds[currentTab]?.segIndex ?? 0;

  /// Switch the 全部片库 segment and re-fetch the grid from page 1 with the new
  /// TMDB sort. The hero rail is left untouched.
  Future<void> selectSegment(int i) async {
    final f = _feeds[currentTab];
    if (f == null || f.segIndex == i || f.tabIndex == 0) return;
    f.segIndex = i;
    await _reloadLibrary(f);
  }

  Future<void> _reloadLibrary(TabFeed f) async {
    final repo = repository;
    if (repo == null) return;
    f.inFlight = true;
    f.library.value = const [];
    f.status.value = FeedStatus.loading;
    notifyListeners();
    try {
      final p = await repo.loadFeed(f.tabIndex, 1, sort: f.segIndex);
      f.page = 1;
      f.library.value = p.items;
      f.hasMore = p.hasMore;
      f.status.value = p.hasMore ? FeedStatus.idle : FeedStatus.end;
    } catch (_) {
      f.status.value = FeedStatus.error;
    } finally {
      f.inFlight = false;
      notifyListeners();
    }
  }

  void showToast(String text) => toast.value = ToastEvent(text, ++_toastSeq);

  @override
  void dispose() {
    _channelPreview?.cancel();
    _resourceOptionsTimer?.cancel();
    for (final f in _feeds.values) {
      f.dispose();
    }
    (_builtRepo as TmdbRepository?)?.close();
    vodRepo.close();
    heroBg.dispose();
    toast.dispose();
    homeFocusRequest.dispose();
    homeScrollTopRequest.dispose();
    player.removeListener(_onTick);
    player.dispose();
    danmaku.dispose();
    liveProbe.dispose(); // before iptv: it borrows iptv's HTTP client
    iptv.dispose();
    super.dispose();
  }
}
