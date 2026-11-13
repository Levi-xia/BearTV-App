import '../models.dart';
import '../repository.dart';
import 'tmdb_api.dart';
import 'tmdb_mappers.dart';

/// TMDB-backed [ContentRepository]. Maps each top-nav tab to a TMDB query and
/// pages through results for infinite scroll. The API key is supplied at
/// construction (from the user's saved settings).
class TmdbRepository implements ContentRepository {
  TmdbRepository({required String apiKey, TmdbApi? api})
      : _api = api ?? TmdbApi(apiKey: apiKey);

  final TmdbApi _api;

  void close() => _api.close();

  @override
  Future<FeedPage> loadFeed(int tabIndex, int page, {int sort = 0}) async {
    // 我的 (tab 0) has no remote catalogue; recent play is local.
    if (tabIndex == 0) return FeedPage.empty;

    final names = await _api.genreMap();
    final (json, fallback) = await _query(tabIndex, page, sort);

    final items = mapTmdbList(
      json['results'] as List?,
      fallbackMediaType: fallback,
      genreNames: names,
    );
    final total = (json['total_pages'] as int?) ?? page;
    // TMDB serves at most 500 pages.
    final hasMore = page < total && page < 500 && items.isNotEmpty;
    return FeedPage(items: items, page: page, hasMore: hasMore);
  }

  Future<(Map<String, dynamic>, String)> _query(
      int tab, int page, int sort) async {
    final (mSort, mExtra) = _movieSort(sort);
    final (tSort, tExtra) = _tvSort(sort);
    switch (tab) {
      case 1: // 推荐：默认用 trending 混合榜；选了排序则退回华语电影发现
        if (sort == 0) return (await _api.trendingAll(page), 'movie');
        return (
          await _api.discoverMovie(page,
              originCountry: 'CN', sortBy: mSort, extra: mExtra),
          'movie'
        );
      case 2: // 电影（偏好中国大陆）
        return (
          await _api.discoverMovie(page,
              originCountry: 'CN', sortBy: mSort, extra: mExtra),
          'movie'
        );
      case 3: // 电视剧（中国大陆）
        return (
          await _api.discoverTv(page,
              originCountry: 'CN', sortBy: tSort, extra: tExtra),
          'tv'
        );
      case 4: // 美剧（US）
        return (
          await _api.discoverTv(page,
              originCountry: 'US', sortBy: tSort, extra: tExtra),
          'tv'
        );
      case 5: // 动漫（国漫：动画 + 大陆）
        return (
          await _api.discoverTv(page,
              genres: '16', originCountry: 'CN', sortBy: tSort, extra: tExtra),
          'tv'
        );
      case 6: // 综艺（真人秀/脱口秀 + 大陆）
        return (
          await _api.discoverTv(page,
              genres: '10764,10767',
              originCountry: 'CN',
              sortBy: tSort,
              extra: tExtra),
          'tv'
        );
      case 7: // 纪录片（纪录 + 大陆）
        return (
          await _api.discoverTv(page,
              genres: '99', originCountry: 'CN', sortBy: tSort, extra: tExtra),
          'tv'
        );
      default:
        return (await _api.trendingAll(page), 'movie');
    }
  }

  /// Segment index → (sort_by, extra filters) for movie discover.
  (String, Map<String, String>) _movieSort(int seg) {
    switch (seg) {
      case 1: // 高分：评分降序，过滤低票数避免异常高分
        return ('vote_average.desc', const {'vote_count.gte': '200'});
      case 2: // 最新：上映日期降序，排除未上映
        return (
          'primary_release_date.desc',
          {'primary_release_date.lte': _today()}
        );
      case 3: // 经典：累计票数最多
        return ('vote_count.desc', const {});
      default: // 热门
        return ('popularity.desc', const {});
    }
  }

  /// Segment index → (sort_by, extra filters) for tv discover.
  (String, Map<String, String>) _tvSort(int seg) {
    switch (seg) {
      case 1:
        return ('vote_average.desc', const {'vote_count.gte': '100'});
      case 2:
        return ('first_air_date.desc', {'first_air_date.lte': _today()});
      case 3:
        return ('vote_count.desc', const {});
      default:
        return ('popularity.desc', const {});
    }
  }

  static String _today() {
    final d = DateTime.now();
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '${d.year}-$m-$day';
  }

  @override
  Future<VodItem> loadDetail(VodItem item) async => item;

  @override
  Future<FeedPage> search(String query, int page) async {
    final q = query.trim();
    if (q.isEmpty) return FeedPage.empty;
    final names = await _api.genreMap();
    final json = await _api.searchMulti(q, page);
    // media_type is present per-row in multi search; 'person' rows are dropped
    // by the mapper. fallback is only used when a row omits media_type.
    final items = mapTmdbList(
      json['results'] as List?,
      fallbackMediaType: 'movie',
      genreNames: names,
    );
    final total = (json['total_pages'] as int?) ?? page;
    final hasMore = page < total && page < 500 && items.isNotEmpty;
    return FeedPage(items: items, page: page, hasMore: hasMore);
  }

  @override
  Future<String?> resolvePlayUrl(VodItem item, int episode,
      {String line = '线路一'}) async {
    // TMDB is metadata-only; playback is resolved via the CMS layer (VodRepository).
    return null;
  }
}
