import '../../core/config.dart';
import '../models.dart';

String _img(String? path, String size) =>
    (path == null || path.isEmpty) ? '' : '${Config.tmdbImageBase}/$size$path';

int _year(String? date) {
  if (date == null || date.length < 4) return 0;
  return int.tryParse(date.substring(0, 4)) ?? 0;
}

bool _isRecent(String? date) {
  if (date == null || date.isEmpty) return false;
  final d = DateTime.tryParse(date);
  if (d == null) return false;
  return DateTime.now().difference(d).inDays.abs() <= 45;
}

String _genres(List? ids, Map<int, String> names) {
  if (ids == null) return '';
  final labels = <String>[];
  for (final id in ids) {
    final n = names[id as int];
    if (n != null) labels.add(n);
    if (labels.length == 2) break;
  }
  return labels.join(' / ');
}

/// Maps one TMDB list result (trending / discover) into a [VodItem].
/// Returns null for non-media rows (e.g. `media_type == 'person'`).
VodItem? mapTmdbItem(
  Map<String, dynamic> json, {
  required String fallbackMediaType,
  required Map<int, String> genreNames,
}) {
  final type = (json['media_type'] as String?) ?? fallbackMediaType;
  if (type != 'movie' && type != 'tv') return null;

  final title = (json['title'] ?? json['name'] ?? '') as String;
  final poster = _img(json['poster_path'] as String?, 'w500');
  final backdrop = json['backdrop_path'] as String?;
  final vote = (json['vote_average'] as num?)?.toDouble() ?? 0.0;
  final date = (json['release_date'] ?? json['first_air_date']) as String?;

  return VodItem(
    id: json['id'] as int,
    mediaType: type,
    title: title.isEmpty ? '未命名' : title,
    en: (json['original_title'] ?? json['original_name'] ?? '') as String,
    genre: _genres(json['genre_ids'] as List?, genreNames),
    desc: (json['overview'] as String?)?.trim().isNotEmpty == true
        ? json['overview'] as String
        : '暂无简介。',
    year: _year(date),
    score: vote > 0 ? vote.toStringAsFixed(1) : '—',
    ep: 0,
    hd: vote >= 8.0 ? '4K HDR' : 'HD',
    neu: _isRecent(date),
    bgUrl: _img(backdrop, 'w1280'),
    // Landscape card: prefer backdrop, fall back to poster so it never blanks.
    cardUrl: backdrop != null && backdrop.isNotEmpty
        ? _img(backdrop, 'w780')
        : poster,
    posterUrl: poster.isNotEmpty ? poster : _img(backdrop, 'w780'),
  );
}

/// Maps a full list payload, dropping non-media rows.
List<VodItem> mapTmdbList(
  List? results, {
  required String fallbackMediaType,
  required Map<int, String> genreNames,
}) {
  if (results == null) return const [];
  final out = <VodItem>[];
  for (final r in results) {
    final item = mapTmdbItem(
      r as Map<String, dynamic>,
      fallbackMediaType: fallbackMediaType,
      genreNames: genreNames,
    );
    if (item != null) out.add(item);
  }
  return out;
}
