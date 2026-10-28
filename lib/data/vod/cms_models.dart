/// Data models for the MacCMS apiv3 playback layer (ported from BearTV).
///
/// Kept intentionally small and immutable — this runs on low-end TV boxes, so
/// we avoid holding large parsed trees resident longer than needed.
library;

/// A CMS collection source: a built-in one ([isCustom] == false) or a
/// user-added custom source. `detail` marks a special source that needs HTML
/// scraping for its m3u8 links.
class CmsSite {
  final String id;
  final String name;
  final String api;
  final String? detail;
  final bool isCustom;

  const CmsSite({
    required this.id,
    required this.name,
    required this.api,
    this.detail,
    this.isCustom = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'api': api,
        if (detail != null) 'detail': detail,
        'isCustom': isCustom,
      };

  factory CmsSite.fromJson(Map<String, dynamic> j) => CmsSite(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? '',
        api: (j['api'] as String?) ?? '',
        detail: j['detail'] as String?,
        isCustom: (j['isCustom'] as bool?) ?? false,
      );
}

/// One search result row from a source (`list[]` item + source tags).
class SearchHit {
  final String sourceId;
  final String sourceName;
  final String vodId;
  final String title;
  final String cover;
  final String year;
  final String remarks;

  const SearchHit({
    required this.sourceId,
    required this.sourceName,
    required this.vodId,
    required this.title,
    this.cover = '',
    this.year = '',
    this.remarks = '',
  });
}

/// A single episode: display title + playable URL.
class Episode {
  final String title;
  final String url;
  const Episode({required this.title, required this.url});
}

/// A play line (播放线路) — an ordered list of episodes.
class PlayLine {
  final String name;
  final List<Episode> episodes;
  const PlayLine({required this.name, required this.episodes});
}

/// Fully-resolved detail for one source: its play lines + display metadata.
class VodDetail {
  final String sourceId;
  final String sourceName;
  final String vodId;
  final String title;
  final String cover;
  final String desc;
  final String remarks;
  final List<PlayLine> playLines;

  const VodDetail({
    required this.sourceId,
    required this.sourceName,
    required this.vodId,
    required this.title,
    this.cover = '',
    this.desc = '',
    this.remarks = '',
    required this.playLines,
  });

  /// Stable key across sources: `sourceId:vodId` (mirrors BearTV resourceKey).
  String get key => '$sourceId:$vodId';

  int get episodeCount =>
      playLines.fold(0, (total, line) => total + line.episodes.length);

  /// First episode with a non-empty URL across any line, or null.
  Episode? get firstEpisode {
    for (final line in playLines) {
      for (final ep in line.episodes) {
        if (ep.url.isNotEmpty) return ep;
      }
    }
    return null;
  }
}

/// One "switch resource" candidate shown in the play page (BearTV resource
/// switcher). Wraps a [VodDetail] with availability metadata for ranking.
class ResourceOption {
  final String sourceId;
  final String sourceName;
  final String vodId;
  final String title;
  final int episodeCount;
  final bool available;
  final VodDetail? detail; // null when not resolved / unavailable
  final bool isCurrent;

  const ResourceOption({
    required this.sourceId,
    required this.sourceName,
    required this.vodId,
    required this.title,
    this.episodeCount = 0,
    this.available = false,
    this.detail,
    this.isCurrent = false,
  });

  String get key => '$sourceId:$vodId';
}
