import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../core/app_controller.dart';
import '../core/format.dart';
import '../core/app_scope.dart';
import '../core/tab_feed.dart';
import '../core/theme.dart';
import '../data/downloads/download_manager.dart';
import '../data/nav_config.dart';
import '../data/models.dart';
import '../widgets/chips.dart';
import '../widgets/focus_fx.dart';
import '../widgets/focusable.dart';
import '../widgets/masonry.dart';
import '../widgets/rail.dart';
import 'iptv_screen.dart';

/// Resume fraction (0..1) for a 最近播放 / 继续观看 card, or null when there's
/// no saved position/duration yet.
double? _recentProgress(dynamic app, VodItem item) {
  final e = app.historyEntryFor(item);
  if (e == null || e.durationMs <= 0) return null;
  final p = e.positionMs / e.durationMs;
  return p.isFinite ? p.clamp(0.0, 1.0) : null;
}

/// Resource label (source name + episode for series) for a history card.
String? _recentBadge(dynamic app, VodItem item) {
  final e = app.historyEntryFor(item);
  if (e == null) return null;
  final src = (e.sourceName as String).trim();
  if (src.isEmpty) return null;
  return e.episodeIndex > 0 ? '$src · 第${e.episodeIndex + 1}集' : src;
}

/// "看到 mm:ss" (or h:mm:ss) resume position for a history card — the concrete
/// progress fallback when the total duration (hence percentage) is unknown.
String? _recentTime(dynamic app, VodItem item) {
  final e = app.historyEntryFor(item);
  if (e == null || (e.positionMs as int) <= 0) return null;
  final total = Duration(milliseconds: e.positionMs as int);
  final h = total.inHours;
  final m = total.inMinutes % 60;
  final s = total.inSeconds % 60;
  final mm = m.toString().padLeft(2, '0');
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '看到 $h:$mm:$ss' : '看到 $mm:$ss';
}

/// Home page. Per-tab: 我的 = 最近播放 only; 推荐 = hero + 今日精选 + 继续观看 +
/// 全部片库; other tabs = hero + 今日精选 + 全部片库. The library grid pages in
/// on scroll/focus reaching the bottom; scroll offset is restored per tab.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ScrollController _scroll = ScrollController();
  TabFeed? _shownFeed;
  VodItem? _heroItem;
  ValueNotifier<int>? _scrollTopSignal;
  ValueNotifier<int>? _homeFocusSignal;

  /// Per-item focus nodes for the 最近播放 / 继续观看 rail cards, keyed by
  /// [VodItem.key], so returning from the player can refocus the exact card
  /// that was played (see [_onHomeFocusRequest]).
  final Map<String, FocusNode> _recentNodes = {};

  FocusNode _recentNode(String key) =>
      _recentNodes.putIfAbsent(key, () => FocusNode());

  /// A single shared node lent to whichever 全部片库 grid card matches the
  /// just-watched title ([AppController.pendingHomeFocusKey]) on the current
  /// build, so returning from the player can refocus that grid card too — not
  /// only the recent rails. One node (not one per item) keeps memory flat on
  /// the low-end box; only ever one grid card carries it at a time.
  final FocusNode _gridRestoreNode = FocusNode();

  /// The 最近播放 record a MENU press asked to delete; drives the confirm overlay.
  VodItem? _deleteTarget;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = AppScope.read(context);
    // Subscribe to "scroll home to top" requests (raised when a nav tab gains
    // focus) so the hero background comes back into view.
    final scrollSignal = app.homeScrollTopRequest;
    if (scrollSignal != _scrollTopSignal) {
      _scrollTopSignal?.removeListener(_onScrollTopRequest);
      _scrollTopSignal = scrollSignal..addListener(_onScrollTopRequest);
    }
    // Subscribe to "focus home" requests (raised on return to home) so a card
    // just played can reclaim focus (pendingHomeFocusKey) before the header
    // falls back to the active nav tab.
    final focusSignal = app.homeFocusRequest;
    if (focusSignal != _homeFocusSignal) {
      _homeFocusSignal?.removeListener(_onHomeFocusRequest);
      _homeFocusSignal = focusSignal..addListener(_onHomeFocusRequest);
    }
  }

  void _onScrollTopRequest() {
    if (!mounted || !_scroll.hasClients) return;
    if (_scroll.offset <= 0) return;
    _scroll.animateTo(0, duration: kPageDur, curve: kEase);
  }

  /// Return-to-home focus restore: if a title was just played
  /// ([AppController.pendingHomeFocusKey]), move focus onto its recent-rail
  /// card. Deferred to the next frame so the card (and its node) is built, and
  /// its [Focusable] scrolls it into view. Falls back to the active nav tab
  /// when no such card is on screen (e.g. a tab without a recent rail).
  void _onHomeFocusRequest() {
    final app = AppScope.read(context);
    final key = app.pendingHomeFocusKey;
    if (key == null) return; // header handles the plain active-tab focus
    // Keep pendingHomeFocusKey set through this synchronous phase so the header's
    // listener (order with ours is not guaranteed) sees it and bows out instead
    // of racing us for focus. We clear it in the post-frame callback below.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (app.pendingHomeFocusKey == key) app.pendingHomeFocusKey = null;
      if (app.page != AppPage.home) return;
      final node = _recentNodes[key];
      if (node != null && node.context != null && node.canRequestFocus) {
        node.requestFocus();
      } else if (_gridRestoreNode.context != null &&
          _gridRestoreNode.canRequestFocus) {
        // No rail card for it (e.g. a content tab with no 继续观看 rail): the
        // matching 全部片库 grid card carries the restore node — focus that.
        _gridRestoreNode.requestFocus();
      } else {
        app.focusActiveTab();
      }
    });
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final app = AppScope.read(context);
    app.setScrolled(_scroll.offset > 120);
    // Near the bottom: pull the next page (scroll-driven trigger).
    if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 800) {
      app.loadMore();
    }
  }

  @override
  void dispose() {
    _scrollTopSignal?.removeListener(_onScrollTopRequest);
    _homeFocusSignal?.removeListener(_onHomeFocusRequest);
    for (final n in _recentNodes.values) {
      n.dispose();
    }
    _gridRestoreNode.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onHeroFocused(VodItem item) {
    AppScope.read(context).setHeroBg(item.bgUrl);
    if (item != _heroItem) setState(() => _heroItem = item);
  }

  /// Up from the top rail crosses back onto the *active* nav tab (rather than
  /// letting geometric traversal pick the tab above the focused card, which
  /// could be a different one). Only the topmost rail on a page wires this.
  KeyEventResult _topRailUp(FocusNode node, KeyEvent event) {
    if ((event is KeyDownEvent || event is KeyRepeatEvent) &&
        event.logicalKey == LogicalKeyboardKey.arrowUp &&
        AppScope.read(context).focusActiveTab()) {
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// On tab switch, land the incoming tab at the very top so the big hero
  /// background is the first thing shown (rather than restoring a previous
  /// scrolled-down position that hides it).
  void _syncTab(TabFeed feed) {
    if (identical(_shownFeed, feed)) return;
    _shownFeed = feed;
    _heroItem = feed.hero.isNotEmpty ? feed.hero.first : null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(0);
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    // 直播 (IPTV) tab: a self-contained browser that doesn't use TMDB, so it
    // sits above the API-key / feed-loading checks below.
    if (app.currentTab == kIptvTab) return const IptvBrowser();
    // 我的 is fully local (downloads + history) and works without a TMDB key,
    // so it sits above the API-key gate.
    if (app.currentTab == 0) return _minePage(app);
    if (!app.hasApiKey) return _needKeyPage(app);
    final feed = app.currentFeed;
    if (feed == null) return _loader();
    _syncTab(feed);

    if (feed.hero.isEmpty) {
      if (feed.status.value == FeedStatus.error) return _errorPage(app);
      return _loader();
    }
    return _contentPage(app, feed);
  }

  // --- 我的 (tab 0): recent play only ---------------------------------------
  Widget _minePage(dynamic app) {
    final recent = app.continueWatch as List<VodItem>;
    // A pending delete target may have just been removed elsewhere — drop a
    // stale overlay rather than confirming against a gone record.
    final target = _deleteTarget;
    final showDelete = target != null && recent.any((e) => e.key == target.key);
    return Stack(
      children: [
        SingleChildScrollView(
          controller: _scroll,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 190),
              if (recent.isEmpty)
                _emptyState('暂无最近播放', '去「推荐」挑一部开始观看吧')
              else
                Rail(
                  title: '最近播放',
                  subtitle: '继续未看完的内容 · 菜单键删除记录',
                  items: recent,
                  autofocusFirst: true,
                  onCardKeyEvent: _topRailUp,
                  onCardMenu: (item) => setState(() => _deleteTarget = item),
                  focusNodeForItem: (item) => _recentNode(item.key),
                  progressForItem: (item) => _recentProgress(app, item),
                  badgeForItem: (item) => _recentBadge(app, item),
                  timeForItem: (item) => _recentTime(app, item),
                ),
              const SizedBox(height: 36),
              _MineDownloadsEntry(app: app, autofocus: recent.isEmpty),
              const SizedBox(height: 80),
            ],
          ),
        ),
        if (showDelete)
          _RecentDeleteOverlay(
            item: target,
            onCancel: _closeDelete,
            onConfirm: () {
              final key = target.key;
              app.removeHistory(key);
              _recentNodes.remove(key)?.dispose();
              _closeDelete();
            },
          ),
      ],
    );
  }

  /// Dismiss the delete confirm and park focus on a surviving recent card (or
  /// the nav tab), since the overlay's trapped focus scope is going away.
  void _closeDelete() {
    setState(() => _deleteTarget = null);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final app = AppScope.read(context);
      final recent = app.continueWatch as List;
      if (recent.isNotEmpty) {
        _recentNode(recent.first.key as String).requestFocus();
      } else {
        app.focusActiveTab();
      }
    });
  }

  // --- content tabs ---------------------------------------------------------
  Widget _contentPage(dynamic app, TabFeed feed) {
    final screenW = MediaQuery.of(context).size.width;
    final cols = screenW < 1500 ? 4 : 5;
    final recent = app.continueWatch as List<VodItem>;
    final showContinue = app.currentTab == 1 && recent.isNotEmpty;

    return AnimatedBuilder(
      animation: Listenable.merge([feed.library, feed.status]),
      builder: (context, _) {
        final items = feed.library.value;
        return CustomScrollView(
          controller: _scroll,
          slivers: [
            SliverToBoxAdapter(child: _heroBlock(feed)),
            if (showContinue)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(top: 26),
                  child: Rail(
                    title: '继续观看',
                    subtitle: '为你保留播放进度',
                    items: recent,
                    focusNodeForItem: (item) => _recentNode(item.key),
                    progressForItem: (item) => _recentProgress(app, item),
                    badgeForItem: (item) => _recentBadge(app, item),
                    timeForItem: (item) => _recentTime(app, item),
                  ),
                ),
              ),
            SliverToBoxAdapter(child: _libraryHeader(app)),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: AppDims.pad),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: cols,
                  mainAxisSpacing: 22,
                  crossAxisSpacing: 22,
                  childAspectRatio: 2 / 3,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, i) => MasonryCard(
                    key: ValueKey(items[i].id),
                    item: items[i],
                    focusNode: items[i].key == app.pendingHomeFocusKey
                        ? _gridRestoreNode
                        : null,
                    onFocused: () {
                      // Focus-driven paging: entering the last two rows loads more.
                      if (i >= items.length - 2 * cols) app.loadMore();
                    },
                  ),
                  childCount: items.length,
                ),
              ),
            ),
            SliverToBoxAdapter(child: _footer(app, feed.status.value)),
          ],
        );
      },
    );
  }

  Widget _heroBlock(TabFeed feed) {
    final screenH = MediaQuery.of(context).size.height;
    final hero = _heroItem ?? feed.hero.first;
    return SizedBox(
      height: math.max(screenH * 0.94, 880),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 34),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(
                  left: AppDims.pad, right: AppDims.pad, top: 190),
              child: HeroInfo(item: hero),
            ),
            const Spacer(),
            Rail(
              title: '今日精选',
              subtitle: '左右切换 · 大屏视觉享受',
              items: feed.hero,
              onCardFocused: _onHeroFocused,
              onCardKeyEvent: _topRailUp,
            ),
          ],
        ),
      ),
    );
  }

  Widget _libraryHeader(dynamic app) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppDims.pad, 26, AppDims.pad, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const RailHead(title: '全部片库', subtitle: '浏览更多'),
          const SizedBox(height: 18),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (var i = 0; i < kSegments.length; i++)
                SelectableChip(
                  label: kSegments[i],
                  selected: app.segIndex == i,
                  onPressed: () {
                    app.selectSegment(i);
                  },
                ),
            ],
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _footer(dynamic app, FeedStatus status) {
    Widget wrap(Widget child) => Padding(
          padding: const EdgeInsets.fromLTRB(AppDims.pad, 28, AppDims.pad, 80),
          child: Center(child: child),
        );
    switch (status) {
      case FeedStatus.loadingMore:
        return wrap(_hint('加载中…'));
      case FeedStatus.end:
        return wrap(_hint('没有更多了'));
      case FeedStatus.error:
        return wrap(
          Focusable(
            onPressed: () => app.retry(),
            builder: (context, focused) => Container(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
              decoration: FocusFx.pill(focused, radius: 12),
              child: Text(
                '加载失败，点此重试',
                style: TextStyle(
                  fontSize: 16,
                  color: focused ? AppColors.focusInk : AppColors.text,
                  fontFamilyFallback: kFontFallback,
                ),
              ),
            ),
          ),
        );
      case FeedStatus.idle:
      case FeedStatus.loading:
        return const SizedBox(height: 80);
    }
  }

  Widget _loader() => const Center(
        child: Text('加载中…',
            style: TextStyle(
                color: AppColors.textDim,
                fontSize: 18,
                fontFamilyFallback: kFontFallback)),
      );

  /// Shown when no TMDB API key is configured — points the user to Settings.
  Widget _needKeyPage(dynamic app) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('🔑', style: TextStyle(fontSize: 54)),
            const SizedBox(height: 20),
            const Text('尚未配置 TMDB API Key',
                style: TextStyle(
                    color: AppColors.text,
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                    fontFamilyFallback: kFontFallback)),
            const SizedBox(height: 12),
            const Text('内容目录来自 TMDB，请先在设置中填入你的 API Key',
                style: TextStyle(
                    color: AppColors.textDim,
                    fontSize: 17,
                    fontFamilyFallback: kFontFallback)),
            const SizedBox(height: 28),
            Focusable(
              autofocus: true,
              onPressed: () => app.openSettings(),
              builder: (context, focused) => Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 30, vertical: 15),
                decoration: FocusFx.pill(focused, radius: 12),
                child: Text('前往设置',
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: focused ? AppColors.focusInk : AppColors.text,
                        fontFamilyFallback: kFontFallback)),
              ),
            ),
          ],
        ),
      );

  Widget _errorPage(dynamic app) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('内容加载失败',
                style: TextStyle(
                    color: AppColors.text,
                    fontSize: 22,
                    fontFamilyFallback: kFontFallback)),
            const SizedBox(height: 16),
            Focusable(
              autofocus: true,
              onPressed: () => app.retry(),
              builder: (context, focused) => Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 26, vertical: 14),
                decoration: FocusFx.pill(focused, radius: 12),
                child: Text('重试',
                    style: TextStyle(
                        fontSize: 17,
                        color: focused ? AppColors.focusInk : AppColors.text,
                        fontFamilyFallback: kFontFallback)),
              ),
            ),
          ],
        ),
      );

  Widget _emptyState(String title, String sub) => Padding(
        padding:
            const EdgeInsets.symmetric(horizontal: AppDims.pad, vertical: 60),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    color: AppColors.text,
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    fontFamilyFallback: kFontFallback)),
            const SizedBox(height: 10),
            Text(sub,
                style: const TextStyle(
                    color: AppColors.textDim,
                    fontSize: 16,
                    fontFamilyFallback: kFontFallback)),
          ],
        ),
      );

  Widget _hint(String text) => Text(text,
      style: const TextStyle(
          color: AppColors.textDim,
          fontSize: 15,
          fontFamilyFallback: kFontFallback));
}

class HeroInfo extends StatelessWidget {
  const HeroInfo({super.key, required this.item});
  final VodItem item;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 480),
      // Sequential (not simultaneous) cross-fade: the outgoing text fully fades
      // out during the first half, the incoming fades in during the second — so
      // the two hero blocks never overlap. A plain cross-fade stacked two big
      // 62px titles on top of each other mid-switch, which read as messy.
      // (switchOutCurve is the outgoing child's reverse curve: Interval(.5,1)
      // makes it reach 0 by the midpoint; switchInCurve holds the incoming at 0
      // until the midpoint.)
      switchInCurve: const Interval(0.5, 1.0, curve: kEase),
      switchOutCurve: const Interval(0.5, 1.0, curve: kEase),
      transitionBuilder: (child, anim) => FadeTransition(
        opacity: anim,
        child: SlideTransition(
          position:
              Tween<Offset>(begin: const Offset(0, 0.05), end: Offset.zero)
                  .animate(anim),
          child: child,
        ),
      ),
      layoutBuilder: (current, previous) => Stack(
          alignment: Alignment.topLeft,
          children: [...previous, if (current != null) current]),
      child: ConstrainedBox(
        key: ValueKey(item.id),
        constraints: const BoxConstraints(maxWidth: 640),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('◆ 本周热度 TOP ${item.id % 9 + 1}',
                style: const TextStyle(
                    fontSize: 15,
                    letterSpacing: 3,
                    color: AppColors.accent2,
                    fontWeight: FontWeight.w600,
                    fontFamilyFallback: kFontFallback)),
            const SizedBox(height: 16),
            Text(item.title,
                style: const TextStyle(
                    fontSize: 62,
                    height: 1.08,
                    fontWeight: FontWeight.w800,
                    color: AppColors.text,
                    fontFamilyFallback: kFontFallback)),
            const SizedBox(height: 8),
            Text(item.en,
                style: const TextStyle(
                    fontSize: 20,
                    letterSpacing: 4,
                    color: Color(0xBFCFE0F7),
                    fontFamilyFallback: kFontFallback)),
            const SizedBox(height: 20),
            _HeroMeta(item: item),
            const SizedBox(height: 16),
            Text(item.desc,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 19,
                    height: 1.75,
                    color: Color(0xFFC3CFE2),
                    fontFamilyFallback: kFontFallback)),
          ],
        ),
      ),
    );
  }
}

class _HeroMeta extends StatelessWidget {
  const _HeroMeta({required this.item});
  final VodItem item;

  @override
  Widget build(BuildContext context) {
    const dim = TextStyle(
        fontSize: 17,
        color: AppColors.textDim,
        fontFamilyFallback: kFontFallback);
    return Wrap(
      spacing: 14,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text('★ ${item.score}',
            style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: AppColors.gold,
                fontFamilyFallback: kFontFallback)),
        const _Dot(),
        Text('${item.year}', style: dim),
        const _Dot(),
        Text(item.genre, style: dim),
        _Badge(text: item.hd),
        if (item.ep > 0) _Badge(text: '全 ${item.ep} 集'),
      ],
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot();
  @override
  Widget build(BuildContext context) => Container(
        width: 5,
        height: 5,
        decoration: const BoxDecoration(
            color: Color(0xFF5C6B85), shape: BoxShape.circle),
      );
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: const Color(0x47FFFFFF)),
        ),
        child: Text(text,
            style: const TextStyle(
                fontSize: 13,
                color: Color(0xFFE6EFFF),
                fontFamilyFallback: kFontFallback)),
      );
}

/// 我的 → 下载管理 section, sitting below 最近播放: the same `RailHead` title
/// treatment as the history rail, with a single entry row underneath.
///
/// A plain row rather than a rail: downloads are a management surface, not a
/// content feed. Shares the history section's glass/hairline card language and
/// rebuilds in isolation so progress updates don't repaint the page.
class _MineDownloadsEntry extends StatelessWidget {
  const _MineDownloadsEntry({required this.app, this.autofocus = false});

  final AppController app;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(left: AppDims.pad, bottom: 16),
          child: RailHead(
            title: '我的下载',
            subtitle: '离线也能看 · 按 剧 · 来源 管理',
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppDims.pad),
          child: ListenableBuilder(
            listenable: app.downloads,
            builder: (context, _) => _entry(app.downloads),
          ),
        ),
      ],
    );
  }

  Widget _entry(DownloadManager downloads) {
    var bytes = 0;
    for (final group in downloads.groups) {
      bytes += group.totalBytes;
    }
    final active = downloads.activeCount;
    final done = downloads.completedCount;

    final String detail;
    if (!downloads.available) {
      detail = '本地存储不可用，下载功能暂不可用';
    } else if (active == 0 && done == 0) {
      detail = '还没有下载 · 在播放页选择「下载选集」';
    } else {
      detail = [
        if (active > 0) '下载中 $active 集',
        if (done > 0) '已缓存 $done 集',
      ].join(' · ');
    }

    return Focusable(
      onPressed: app.openDownloads,
      autofocus: autofocus,
      ensureVisibleAlignment: 0.5,
      builder: (context, focused) {
        final base = BoxDecoration(
          color: AppColors.glass,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.hairline),
        );
        final ink = focused ? AppColors.focusInk : AppColors.text;
        final dim = focused ? const Color(0xB304121F) : AppColors.textDim;
        return FocusFx.scale(
          focused,
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            decoration: focused ? FocusFx.pill(focused, radius: 16) : base,
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '下载管理',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: ink,
                          fontFamilyFallback: kFontFallback,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15,
                          color: dim,
                          fontFamilyFallback: kFontFallback,
                        ),
                      ),
                    ],
                  ),
                ),
                if (bytes > 0) ...[
                  const SizedBox(width: 20),
                  Text(
                    '占用 ${formatBytes(bytes)}',
                    style: TextStyle(
                      fontSize: 15,
                      color: dim,
                      fontFamilyFallback: kFontFallback,
                    ),
                  ),
                ],
                const SizedBox(width: 16),
                Text(
                  '›',
                  style: TextStyle(
                    fontSize: 26,
                    height: 1,
                    color: focused ? AppColors.focusInk : AppColors.textDim,
                    fontFamilyFallback: kFontFallback,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Modal "delete this record?" confirm raised by a MENU press on a 最近播放
/// card. Traps focus in its own [FocusScope] with 取消 autofocused, so a stray
/// OK cancels rather than deletes.
class _RecentDeleteOverlay extends StatelessWidget {
  const _RecentDeleteOverlay({
    required this.item,
    required this.onCancel,
    required this.onConfirm,
  });
  final VodItem item;
  final VoidCallback onCancel;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: FocusScope(
        autofocus: true,
        child: ColoredBox(
          color: const Color(0xB3000000),
          child: Center(
            child: Container(
              width: 460,
              padding: const EdgeInsets.fromLTRB(32, 30, 32, 26),
              decoration: BoxDecoration(
                color: AppColors.cardBg,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: AppColors.hairline),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('删除播放记录？',
                      style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                          color: AppColors.text,
                          fontFamilyFallback: kFontFallback)),
                  const SizedBox(height: 10),
                  Text('将从「最近播放」移除《${item.title}》，不影响已缓存内容。',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 16,
                          color: AppColors.textDim,
                          fontFamilyFallback: kFontFallback)),
                  const SizedBox(height: 26),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      _DeleteBtn(
                          label: '取消', autofocus: true, onPressed: onCancel),
                      const SizedBox(width: 14),
                      _DeleteBtn(
                          label: '删除', danger: true, onPressed: onConfirm),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A D-pad-focusable button for [_RecentDeleteOverlay].
class _DeleteBtn extends StatelessWidget {
  const _DeleteBtn({
    required this.label,
    required this.onPressed,
    this.danger = false,
    this.autofocus = false,
  });
  final String label;
  final VoidCallback onPressed;
  final bool danger;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return Focusable(
      autofocus: autofocus,
      onPressed: onPressed,
      builder: (context, focused) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 14),
          decoration: BoxDecoration(
            color: focused
                ? (danger ? const Color(0xFFE5484D) : AppColors.accent)
                : (danger ? const Color(0x33E5484D) : AppColors.glass),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: danger
                    ? const Color(0xFFE5484D)
                    : (focused ? AppColors.accent : AppColors.hairline)),
          ),
          child: Text(label,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: focused
                    ? AppColors.focusInk
                    : (danger ? const Color(0xFFFF8A8D) : AppColors.text),
                fontFamilyFallback: kFontFallback,
              )),
        );
      },
    );
  }
}
