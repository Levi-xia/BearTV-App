import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'cms_models.dart';

/// MacCMS apiv3 JSON client, ported from BearTV `src/services/cmsClient.js`.
///
/// Protocol:
/// - search: `GET {api}?ac=videolist&wd=<kw>&pg=<n>` → `{list:[...], pagecount}`
/// - detail: `GET {api}?ac=videolist&ids=<id>`       → `list[0].vod_play_url`
///
/// Play URLs are packed as `line1$$$line2`, each line `ep1#ep2`, each ep
/// `标题$URL`. Special sources (those with a `detail` domain) hide their m3u8
/// on an HTML page instead, so we scrape it with a regex fallback.
///
/// Every network call is best-effort: a single source failing (timeout, bad
/// JSON, dead host) degrades silently to an empty result so it never blocks the
/// other sources. Runs on low-end boxes, so we fetch only the first search page
/// (enough for an exact-title match) rather than paginating the whole catalogue.
class CmsClient {
  CmsClient({http.Client? client, Duration? timeout})
      : _client = client ?? http.Client(),
        _timeout = timeout ?? const Duration(seconds: 8);

  final http.Client _client;
  final Duration _timeout;

  void close() => _client.close();

  /// General m3u8 matcher (BearTV `M3U8_PATTERN`): a leading `$` then a URL.
  static final RegExp _m3u8 = RegExp(r'\$https?://[^"' "'" r'\s]+?\.m3u8');
  static final RegExp _ffzy =
      RegExp(r'\$(https?://[^"' "'" r'\s]+?/\d{8}/\d+_[a-f0-9]+/index\.m3u8)');
  static final RegExp _h1 = RegExp(r'<h1[^>]*>([^<]+)</h1>');

  Future<Map<String, dynamic>?> _getJson(Uri uri) async {
    try {
      final res = await _client.get(uri, headers: const {
        'Accept': 'application/json',
      }).timeout(_timeout);
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      // Silent degrade: one dead source must not break the aggregate search.
      return null;
    }
  }

  /// Search a single source. Returns [] on any failure. First page only.
  Future<List<SearchHit>> searchSource(CmsSite site, String query) async {
    final base = site.api;
    final sep = base.contains('?') ? '&' : '?';
    final uri = Uri.parse('$base${sep}ac=videolist&wd=${Uri.encodeQueryComponent(query)}');
    final data = await _getJson(uri);
    final list = data?['list'];
    if (list is! List || list.isEmpty) return const [];
    final out = <SearchHit>[];
    for (final row in list) {
      if (row is! Map) continue;
      final vodId = (row['vod_id'] ?? row['id'])?.toString() ?? '';
      if (vodId.isEmpty) continue;
      out.add(SearchHit(
        sourceId: site.id,
        sourceName: site.name,
        vodId: vodId,
        title: (row['vod_name'] as String?)?.trim() ?? '',
        cover: (row['vod_pic'] as String?) ?? '',
        year: (row['vod_year']?.toString()) ?? '',
        remarks: (row['vod_remarks'] as String?) ?? '',
      ));
    }
    return out;
  }

  /// Resolve full detail (play lines) for [vodId] on [site]. Dispatches to the
  /// HTML scraper for special sources. Returns null on failure.
  Future<VodDetail?> fetchDetail(CmsSite site, String vodId) async {
    if (!RegExp(r'^[\w-]+$').hasMatch(vodId)) return null;
    if (site.detail != null && site.detail!.isNotEmpty) {
      return _fetchScrapedDetail(site, vodId);
    }
    return _fetchStandardDetail(site, vodId);
  }

  Future<VodDetail?> _fetchStandardDetail(CmsSite site, String vodId) async {
    final base = site.api;
    final sep = base.contains('?') ? '&' : '?';
    final uri = Uri.parse('$base${sep}ac=videolist&ids=$vodId');
    final data = await _getJson(uri);
    final list = data?['list'];
    if (list is! List || list.isEmpty) return null;
    final info = list.first;
    if (info is! Map) return null;
    return mapDetail(Map<String, dynamic>.from(info), sourceId: site.id, sourceName: site.name);
  }

  /// Special sources: scrape the HTML detail page for m3u8 links.
  Future<VodDetail?> _fetchScrapedDetail(CmsSite site, String vodId) async {
    final uri = Uri.parse('${site.detail}/index.php/vod/detail/id/$vodId.html');
    String html;
    try {
      final res = await _client.get(uri).timeout(_timeout);
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      html = utf8.decode(res.bodyBytes);
    } catch (_) {
      return null;
    }

    var matches = <String>[];
    if (site.id == 'ffzy') {
      matches = _ffzy.allMatches(html).map((m) => m.group(1) ?? '').where((s) => s.isNotEmpty).toList();
    }
    if (matches.isEmpty) {
      matches = _m3u8.allMatches(html).map((m) {
        final raw = m.group(0)!.substring(1); // strip leading '$'
        final paren = raw.indexOf('(');
        return paren > 0 ? raw.substring(0, paren) : raw;
      }).toList();
    }
    // De-dup, preserve order.
    final seen = <String>{};
    final urls = <String>[];
    for (final u in matches) {
      if (seen.add(u)) urls.add(u);
    }
    if (urls.isEmpty) return null;

    final titleMatch = _h1.firstMatch(html);
    final episodes = <Episode>[
      for (var i = 0; i < urls.length; i++) Episode(title: '第${i + 1}集', url: urls[i]),
    ];
    return VodDetail(
      sourceId: site.id,
      sourceName: site.name,
      vodId: vodId,
      title: titleMatch != null ? titleMatch.group(1)!.trim() : '',
      playLines: [PlayLine(name: '线路一', episodes: episodes)],
    );
  }
}

/// Parse a MacCMS `vod_play_url` string into play lines. Pure + testable.
///
/// Structure: `line1$$$line2`, each line `ep1#ep2`, each ep `标题$URL`. Episodes
/// whose URL is not http(s) are dropped; a line left with no episodes is
/// dropped. Optional [playFrom] (`vod_play_from`, also `$$$`-separated) supplies
/// human line names, aligned by index; otherwise lines are named 线路N.
List<PlayLine> parsePlayUrl(String? vodPlayUrl, {String? playFrom}) {
  if (vodPlayUrl == null || vodPlayUrl.isEmpty) return const [];
  final names = (playFrom == null || playFrom.isEmpty) ? const <String>[] : playFrom.split(r'$$$');
  final rawLines = vodPlayUrl.split(r'$$$');
  final out = <PlayLine>[];
  for (var i = 0; i < rawLines.length; i++) {
    final episodes = <Episode>[];
    for (final ep in rawLines[i].split('#')) {
      final parts = ep.split(r'$');
      final url = parts.length > 1 ? parts[1] : '';
      if (url.startsWith('http://') || url.startsWith('https://')) {
        episodes.add(Episode(title: parts[0].isNotEmpty ? parts[0] : '第${episodes.length + 1}集', url: url));
      }
    }
    if (episodes.isEmpty) continue;
    final name = (i < names.length && names[i].trim().isNotEmpty) ? names[i].trim() : '线路${out.length + 1}';
    out.add(PlayLine(name: name, episodes: episodes));
  }
  return _preferM3u8(out);
}

/// Float m3u8 lines to the front (stable). Many sources expose a parse/player
/// route (e.g. `ruyi`) alongside a raw m3u8 route (e.g. `ruyim3u8`); the latter
/// plays reliably on the native HLS player while the former often can't. This
/// makes the default line (lineIndex 0), [VodDetail.firstEpisode] and the line
/// list all prefer m3u8. Rank: name contains "m3u8" (0) → episode URL is .m3u8
/// (1) → neither (2). List.sort isn't stable, so we bucket to preserve the
/// source's original relative order within each rank.
List<PlayLine> _preferM3u8(List<PlayLine> lines) {
  if (lines.length < 2) return lines;
  final byName = <PlayLine>[]; // rank 0
  final byUrl = <PlayLine>[]; // rank 1
  final rest = <PlayLine>[]; // rank 2
  for (final line in lines) {
    if (line.name.toLowerCase().contains('m3u8')) {
      byName.add(line);
    } else if (line.episodes.isNotEmpty && _isM3u8Url(line.episodes.first.url)) {
      byUrl.add(line);
    } else {
      rest.add(line);
    }
  }
  return [...byName, ...byUrl, ...rest];
}

bool _isM3u8Url(String url) {
  final path = (Uri.tryParse(url)?.path ?? url).toLowerCase();
  return path.endsWith('.m3u8');
}

/// Map a MacCMS detail `list[0]` object into a [VodDetail]. Pure + testable.
/// Falls back to scanning `vod_content` for m3u8 links when there is no
/// structured `vod_play_url`.
VodDetail mapDetail(Map<String, dynamic> info, {required String sourceId, required String sourceName}) {
  var lines = parsePlayUrl(info['vod_play_url'] as String?, playFrom: info['vod_play_from'] as String?);
  if (lines.isEmpty) {
    final content = (info['vod_content'] as String?) ?? '';
    final m3u8 = RegExp(r'\$https?://[^"' "'" r'\s]+?\.m3u8')
        .allMatches(content)
        .map((m) => m.group(0)!.substring(1))
        .toList();
    if (m3u8.isNotEmpty) {
      lines = [
        PlayLine(name: '线路一', episodes: [
          for (var i = 0; i < m3u8.length; i++) Episode(title: '第${i + 1}集', url: m3u8[i]),
        ]),
      ];
    }
  }
  final desc = ((info['vod_content'] as String?) ?? '')
      .replaceAll(RegExp(r'<[^>]+>'), ' ')
      .trim();
  return VodDetail(
    sourceId: sourceId,
    sourceName: sourceName,
    vodId: (info['vod_id'] ?? info['id'])?.toString() ?? '',
    title: (info['vod_name'] as String?)?.trim() ?? '',
    cover: (info['vod_pic'] as String?) ?? '',
    desc: desc,
    remarks: (info['vod_remarks'] as String?) ?? '',
    playLines: lines,
  );
}
