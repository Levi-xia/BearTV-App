import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'danmaku_models.dart';

/// dandanplay-compatible danmaku client, ported from BearTV
/// `src/services/danmakuClient.js`.
///
/// Two calls:
/// - match:   `POST {base}/{token}/api/v2/match`  body `{"fileName": "剧名 S01E10"}`
///            → JSON `{success,isMatched,matches:[{episodeId,animeTitle,...}]}`
/// - comment: `GET  {base}/{token}/api/v2/comment/{episodeId}?format=xml`
///            → bilibili-style XML `<d p="time,mode,size,color,...">text</d>`
///
/// Every call is best-effort: a failure degrades to an empty result and never
/// interrupts playback.
class DanmakuClient {
  DanmakuClient({http.Client? client, Duration? timeout})
      : _client = client ?? http.Client(),
        _timeout = timeout ?? const Duration(seconds: 8);

  final http.Client _client;
  final Duration _timeout;

  void close() => _client.close();

  /// Match [fileName] to candidate episodes on [host]. [] on any failure.
  Future<List<DanmakuMatch>> match(DanmakuHost host, String fileName) async {
    try {
      final res = await _client
          .post(
            Uri.parse(host.matchUrl),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({'fileName': fileName}),
          )
          .timeout(_timeout);
      if (res.statusCode < 200 || res.statusCode >= 300) return const [];
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      if (decoded is! Map) return const [];
      if (decoded['success'] != true) return const [];
      final matches = decoded['matches'];
      if (matches is! List) return const [];
      return parseMatches(matches);
    } catch (_) {
      return const [];
    }
  }

  /// Fetch + parse all comments for [episodeId] on [host]. [] on any failure.
  Future<List<DanmakuItem>> fetchComments(
      DanmakuHost host, int episodeId) async {
    try {
      final res =
          await _client.get(Uri.parse(host.commentUrl(episodeId))).timeout(_timeout);
      if (res.statusCode < 200 || res.statusCode >= 300) return const [];
      return parseDanmakuXml(utf8.decode(res.bodyBytes));
    } catch (_) {
      return const [];
    }
  }
}

/// Extract [DanmakuMatch]es from the `matches` JSON array. Pure + testable.
List<DanmakuMatch> parseMatches(List<dynamic> matches) {
  final out = <DanmakuMatch>[];
  for (final m in matches) {
    if (m is! Map) continue;
    final id = m['episodeId'];
    final episodeId = id is int ? id : int.tryParse('${id ?? ''}') ?? 0;
    if (episodeId == 0) continue;
    out.add(DanmakuMatch(
      episodeId: episodeId,
      animeTitle: (m['animeTitle'] as String?)?.trim() ?? '',
      episodeTitle: (m['episodeTitle'] as String?)?.trim() ?? '',
    ));
  }
  return out;
}

/// The `<d p="...">text</d>` element matcher. Tolerates extra attributes and
/// multi-line text (dotAll). Pure + used by [parseDanmakuXml].
final RegExp _dTag = RegExp(
  '<d\\s+p="([^"]*)"[^>]*>(.*?)</d>',
  dotAll: true,
);

/// Parse a bilibili-style danmaku XML document into sorted [DanmakuItem]s.
///
/// Each element's `p` attribute is `time,mode,fontSize,color,timestamp,...`.
/// bilibili mode → our mode: 1-3 scroll→0, 5 top→1, 4 bottom→2. Color is a
/// decimal int converted to 0xRRGGBB. Elements without text or with < 4 `p`
/// fields are skipped. Result is sorted by time ascending. Pure + testable.
List<DanmakuItem> parseDanmakuXml(String xml) {
  if (xml.isEmpty) return const [];
  final out = <DanmakuItem>[];
  for (final match in _dTag.allMatches(xml)) {
    final p = (match.group(1) ?? '').split(',');
    if (p.length < 4) continue;
    final text = _unescapeXml((match.group(2) ?? '').trim());
    if (text.isEmpty) continue;
    final time = double.tryParse(p[0]) ?? 0;
    final rawMode = int.tryParse(p[1]) ?? 1;
    final colorValue = int.tryParse(p[3]) ?? 0xFFFFFF;
    var mode = 0;
    if (rawMode == 4) {
      mode = 2; // bottom
    } else if (rawMode == 5) {
      mode = 1; // top
    }
    out.add(DanmakuItem(
      time: time,
      text: text,
      mode: mode,
      color: colorValue & 0xFFFFFF,
    ));
  }
  out.sort((a, b) => a.time.compareTo(b.time));
  return out;
}

/// Unescape the five predefined XML entities found in danmaku text.
String _unescapeXml(String s) {
  if (!s.contains('&')) return s;
  return s
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');
}

/// Strip episode / season / year / bracket noise from a raw [title], mirroring
/// BearTV `formatDanmuSearchName`: each marker removes itself **and any trailing
/// text**, so a subtitle or release tag after the episode number is dropped too.
/// Deliberately conservative — it does NOT strip bare years, fullwidth `（…）`
/// or `季`/season markers, which over-stripping earlier broke otherwise-valid
/// matches. Pure + testable.
String cleanDanmakuTitle(String title) {
  final name = title
      .trim()
      .replaceAll(RegExp(r'\s*第\s*\d+\s*集.*'), '')
      .replaceAll(RegExp(r'\s*第\s*\d+\s*期.*'), '')
      .replaceAll(RegExp(r'\s*[sS]\d+[eE]\d+.*'), '')
      .replaceAll(RegExp(r'\s*\d+集.*'), '')
      .replaceAll(RegExp(r'\s*\(\d{4}\).*'), '')
      .replaceAll(RegExp(r'\s*【.*?】.*'), '');
  return name.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// Build the `/match` fileName for [title] at [episodeIndex] (0-based): clean the
/// title via [cleanDanmakuTitle], then append `S01E{ep}` (ep = episodeIndex + 1,
/// zero-padded). Pure.
String formatDanmakuSearchName(String title, int episodeIndex) {
  final name = cleanDanmakuTitle(title);
  final ep = (episodeIndex + 1).toString().padLeft(2, '0');
  return '$name S01E$ep';
}
