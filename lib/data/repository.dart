import 'models.dart';

/// Data access boundary. The app ships a single networked implementation
/// ([TmdbRepository]); the UI depends only on this interface.
abstract class ContentRepository {
  /// Load one page of a tab's catalogue (for the masonry + derived hero rail).
  /// [sort] is the selected segment chip index (see kSegments): 0=热门, 1=高分,
  /// 2=最新, 3=经典.
  Future<FeedPage> loadFeed(int tabIndex, int page, {int sort = 0});

  /// Load a detail payload for the play screen.
  Future<VodItem> loadDetail(VodItem item);

  /// Resolve a real, playable stream URL (m3u8) for an episode.
  /// TMDB is metadata-only, so this returns null and the mock player fakes it.
  Future<String?> resolvePlayUrl(VodItem item, int episode, {String line = '线路一'});

  /// Search the catalogue by keyword (TMDB `search/multi`). Used by the search
  /// screen; results feed the same `openTitle` → CMS-resolve playback flow as
  /// category cards.
  Future<FeedPage> search(String query, int page);
}
