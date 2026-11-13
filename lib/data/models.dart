/// Unified media model. Field names follow the reference HTML `make()` object
/// so that swapping the mock repository for a real one is mechanical.
class VodItem {
  final int id;
  final String mediaType; // 'movie' | 'tv'
  final String title;
  final String en; // original / English title line
  final String genre;
  final String desc;
  final int year;
  final String score; // e.g. "9.2"
  final int ep; // episode count (0 when unknown from a list endpoint)
  final String hd; // "4K HDR" | "1080P" | "HD"
  final bool neu; // "更新" badge (recent release)
  final String bgUrl; // 1280-wide backdrop (hero)
  final String cardUrl; // 780-wide backdrop (landscape card)
  final String posterUrl; // portrait poster (masonry grid)

  const VodItem({
    required this.id,
    this.mediaType = 'movie',
    required this.title,
    required this.en,
    required this.genre,
    required this.desc,
    required this.year,
    required this.score,
    required this.ep,
    required this.hd,
    required this.neu,
    required this.bgUrl,
    required this.cardUrl,
    required this.posterUrl,
  });

  /// Portrait image used by the masonry grid.
  String get masonryUrl => posterUrl;

  /// Stable key across movie/tv id collisions.
  String get key => '$mediaType:$id';

  /// Copy with a different [genre]. Only used for CMS-direct items
  /// (`mediaType` starts with `cms:`), where [genre] carries the source name
  /// and has to follow a 切换资源 — see `AppController._itemWithSource`.
  VodItem withGenre(String genre) => VodItem(
        id: id,
        mediaType: mediaType,
        title: title,
        en: en,
        genre: genre,
        desc: desc,
        year: year,
        score: score,
        ep: ep,
        hd: hd,
        neu: neu,
        bgUrl: bgUrl,
        cardUrl: cardUrl,
        posterUrl: posterUrl,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'mediaType': mediaType,
        'title': title,
        'en': en,
        'genre': genre,
        'desc': desc,
        'year': year,
        'score': score,
        'ep': ep,
        'hd': hd,
        'neu': neu,
        'bgUrl': bgUrl,
        'cardUrl': cardUrl,
        'posterUrl': posterUrl,
      };

  factory VodItem.fromJson(Map<String, dynamic> j) => VodItem(
        id: j['id'] as int,
        mediaType: (j['mediaType'] as String?) ?? 'movie',
        title: j['title'] as String,
        en: (j['en'] as String?) ?? '',
        genre: (j['genre'] as String?) ?? '',
        desc: (j['desc'] as String?) ?? '',
        year: (j['year'] as int?) ?? 0,
        score: (j['score'] as String?) ?? '—',
        ep: (j['ep'] as int?) ?? 0,
        hd: (j['hd'] as String?) ?? 'HD',
        neu: (j['neu'] as bool?) ?? false,
        bgUrl: (j['bgUrl'] as String?) ?? '',
        cardUrl: (j['cardUrl'] as String?) ?? '',
        posterUrl: (j['posterUrl'] as String?) ?? '',
      );
}

/// A page of feed items plus a cursor for infinite scroll.
class FeedPage {
  final List<VodItem> items;
  final int page;
  final bool hasMore;

  const FeedPage(
      {required this.items, required this.page, required this.hasMore});

  static const empty = FeedPage(items: [], page: 0, hasMore: false);
}

/// Aggregated payload for the home screen (first page + derived hero rail).
class HomeData {
  final List<VodItem> hero; // 今日精选
  final List<VodItem> continueWatch; // 继续观看 (local recent play)
  final List<VodItem> library; // 全部片库 (masonry, page 1)
  final bool hasMore;

  const HomeData({
    required this.hero,
    required this.continueWatch,
    required this.library,
    this.hasMore = false,
  });
}
