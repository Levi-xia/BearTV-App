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
/// A danmaku HTTP call failed — as opposed to succeeding with "no match" / "no
/// comments", which are legitimate empty results. Callers use this to avoid
/// caching failures and to show the user what actually went wrong.
class DanmakuRequestException implements Exception {
  DanmakuRequestException(
    this.message, {
    this.statusCode,
    this.transient = false,
  });

  /// Human-readable, Chinese, e.g. `匹配弹幕超时（30 秒）`.
  final String message;
  final int? statusCode;

  /// True for timeouts / connection errors / 5xx, which are worth one retry.
  final bool transient;

  @override
  String toString() => message;
}

/// Outcome of a `/match` call. [exact] mirrors the server's `isMatched`: when
/// false, [matches] are low-confidence guesses that may belong to another show.
class DanmakuMatchResult {
  const DanmakuMatchResult({required this.exact, required this.matches});

  final bool exact;
  final List<DanmakuMatch> matches;

  static const empty = DanmakuMatchResult(exact: false, matches: []);
}

/// Failures throw [DanmakuRequestException]; a successful call that simply has
/// no match / no comments returns an empty result.
class DanmakuClient {
  DanmakuClient({
    http.Client? client,
    Duration? timeout,
    Duration? matchTimeout,
    Duration? commentTimeout,
  })  : _client = client ?? http.Client(),
        _matchTimeout = timeout ?? matchTimeout ?? const Duration(seconds: 30),
        _commentTimeout =
            timeout ?? commentTimeout ?? const Duration(seconds: 30);

  final http.Client _client;

  /// Both calls run in the background and never block playback, so a long
  /// budget beats giving up on a slow/relayed host.
  final Duration _matchTimeout;

  /// The comment body is a whole episode's XML (can be several MB on a slow
  /// host), so it gets its own knob even though it defaults to the same 30s.
  final Duration _commentTimeout;

  static const Duration _retryBackoff = Duration(milliseconds: 300);

  void close() => _client.close();

  /// Match [fileName] to candidate episodes on [host]. Throws
  /// [DanmakuRequestException] on transport failure; [] when genuinely unmatched.
  Future<DanmakuMatchResult> match(DanmakuHost host, String fileName) async {
    final res = await _request(
      '匹配弹幕',
      () => _client.post(
        Uri.parse(host.matchUrl),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({'fileName': fileName}),
      ),
      _matchTimeout,
    );
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(res.bodyBytes));
    } catch (_) {
      throw DanmakuRequestException('匹配弹幕返回了无法解析的响应');
    }
    if (decoded is! Map) {
      throw DanmakuRequestException('匹配弹幕返回了无法解析的响应');
    }
    // success:false is the server rejecting the request (bad token, upstream
    // error). Surface its message instead of pretending nothing matched.
    if (decoded['success'] != true) {
      final msg = (decoded['errorMessage'] as String?)?.trim() ?? '';
      throw DanmakuRequestException(
        '匹配弹幕失败：${msg.isEmpty ? '服务器拒绝请求' : msg}',
        statusCode: res.statusCode,
      );
    }
    final matches = decoded['matches'];
    if (matches is! List) return DanmakuMatchResult.empty;
    return DanmakuMatchResult(
      exact: decoded['isMatched'] == true,
      matches: parseMatches(matches),
    );
  }

  /// Fetch + parse all comments for [episodeId] on [host]. Throws
  /// [DanmakuRequestException] on transport failure; [] when the episode has none.
  Future<List<DanmakuItem>> fetchComments(
      DanmakuHost host, int episodeId) async {
    final res = await _request(
      '获取弹幕',
      () => _client.get(Uri.parse(host.commentUrl(episodeId))),
      _commentTimeout,
    );
    try {
      return parseDanmakuXml(utf8.decode(res.bodyBytes));
    } catch (_) {
      throw DanmakuRequestException('获取弹幕返回了无法解析的响应');
    }
  }

  /// Run [send] with [timeout]; retry once with a short backoff on transient
  /// failures (timeout, connection error, 5xx/408/429). Throws
  /// [DanmakuRequestException] — never swallows the reason.
  Future<http.Response> _request(
    String label,
    Future<http.Response> Function() send,
    Duration timeout,
  ) async {
    DanmakuRequestException? failure;
    for (var attempt = 0; attempt < 2; attempt++) {
      if (attempt > 0) await Future<void>.delayed(_retryBackoff);
      try {
        final res = await send().timeout(timeout);
        if (res.statusCode >= 200 && res.statusCode < 300) return res;
        final transient = res.statusCode == 408 ||
            res.statusCode == 429 ||
            res.statusCode >= 500;
        failure = DanmakuRequestException(
          '$label失败（HTTP ${res.statusCode}）',
          statusCode: res.statusCode,
          transient: transient,
        );
        if (!transient) break; // a 4xx won't fix itself
      } on TimeoutException {
        failure = DanmakuRequestException(
          '$label超时（${timeout.inSeconds} 秒）',
          transient: true,
        );
      } catch (e) {
        failure = DanmakuRequestException(
          '$label网络错误（${_brief(e)}）',
          transient: true,
        );
      }
    }
    throw failure ?? DanmakuRequestException('$label失败');
  }

  /// Collapse `ClientException with SocketException: Failed host lookup: ...`
  /// into something that fits a one-line status.
  static String _brief(Object e) {
    var s = e.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    final host =
        RegExp(r'(?:host lookup|Failed host lookup)[: ]*(.+)$').firstMatch(s);
    if (host != null) s = '无法解析域名 ${host.group(1)}';
    if (s.length > 60) s = '${s.substring(0, 60)}…';
    return s;
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
