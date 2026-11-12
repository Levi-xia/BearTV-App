import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'cms_client.dart';
import 'cms_models.dart';

/// One source probe's verdict, shown in the settings-page speed-test overlay.
enum CmsSpeedStatus {
  /// Queued or in flight.
  pending,

  /// API answered with valid apiv3 JSON and acceptable latency.
  ok,

  /// API answered, but took long enough to explain a slow 起播.
  slow,

  /// Answered, but not the `{list: [...]}` shape the app expects.
  badData,

  /// No response within the probe's timeout.
  timeout,

  /// Connection refused / DNS failure / HTTP error.
  failed,
}

/// Latency above this is flagged as [CmsSpeedStatus.slow]. A healthy apiv3 list
/// page answers in well under 500ms on any usable line; 1.2s means every search
/// and detail fetch in the app will feel laggy, and playback will start late.
const Duration kCmsSlowLatency = Duration(milliseconds: 1200);

/// Verdict for the play CDN behind a source — the m3u8 host, which is what
/// actually decides whether 起播 is fast once the API has answered.
///
/// A source can have a snappy API and a dead/slow CDN: the two numbers are
/// measured independently so the overlay can show exactly that.
@immutable
class CmsCdnProbe {
  const CmsCdnProbe({
    required this.status,
    this.latency,
    this.detail,
  });

  final CmsSpeedStatus status;

  /// Time to the m3u8 response headers.
  final Duration? latency;

  /// Short user-facing reason for a failure.
  final String? detail;
}

/// Result of probing one [CmsSite].
@immutable
class CmsSpeedResult {
  const CmsSpeedResult._({
    required this.site,
    required this.status,
    this.latency,
    this.itemCount = 0,
    this.detail,
    this.m3u8Url,
    this.cdn,
    this.cdnPending = false,
  });

  /// Queued / in-flight placeholder.
  const CmsSpeedResult.pending(CmsSite site)
      : this._(site: site, status: CmsSpeedStatus.pending);

  final CmsSite site;
  final CmsSpeedStatus status;

  /// Time until the response headers arrived (≈ time to first byte).
  final Duration? latency;

  /// Number of entries in the returned list (0 when unknown / empty).
  final int itemCount;

  /// Short user-facing reason for [CmsSpeedStatus.failed] / `badData`.
  final String? detail;

  /// First playable m3u8 found in the list response; null when the source
  /// doesn't expose one there.
  final String? m3u8Url;

  /// CDN verdict. Null when there was nothing to probe (API failed / no m3u8).
  final CmsCdnProbe? cdn;

  /// True between "m3u8 found" and "CDN probe finished" — keeps [finished]
  /// honest so the overlay's progress counter doesn't complete early.
  final bool cdnPending;

  bool get finished => status != CmsSpeedStatus.pending && !cdnPending;

  /// Same result, with the CDN phase marked in flight.
  CmsSpeedResult withCdnPending() => CmsSpeedResult._(
        site: site,
        status: status,
        latency: latency,
        itemCount: itemCount,
        detail: detail,
        m3u8Url: m3u8Url,
        cdnPending: true,
      );

  /// Same result, with the CDN verdict attached.
  CmsSpeedResult withCdn(CmsCdnProbe cdn) => CmsSpeedResult._(
        site: site,
        status: status,
        latency: latency,
        itemCount: itemCount,
        detail: detail,
        m3u8Url: m3u8Url,
        cdn: cdn,
      );

  /// Sort order for the overlay: usable sources first (fastest first), then
  /// malformed, then dead. Stable for equal ranks (caller keeps input order).
  int get sortRank => switch (status) {
        CmsSpeedStatus.ok => 0,
        CmsSpeedStatus.slow => 1,
        CmsSpeedStatus.badData => 2,
        CmsSpeedStatus.timeout => 3,
        CmsSpeedStatus.failed => 4,
        CmsSpeedStatus.pending => 5,
      };
}

/// The lightweight apiv3 endpoint used for the probe. `ac=videolist&pg=1` is the
/// cheapest meaningful call: it hits the same host/route the app uses for
/// search and detail (`ac=videolist&wd=…` / `ids=…`) without paying for a query.
Uri cmsProbeUri(CmsSite site) {
  final base = site.api;
  final sep = base.contains('?') ? '&' : '?';
  return Uri.parse('$base${sep}ac=videolist&pg=1');
}

/// Probe one source. Never throws: every failure is folded into a result.
///
/// [CmsSpeedResult.latency] is measured to response headers, so it reflects
/// network + server queueing rather than how much JSON the source happens to
/// return. The body is still read (and parsed) to distinguish "host is up" from
/// "host returns something this app can actually use".
Future<CmsSpeedResult> probeCmsSite(
  CmsSite site, {
  required http.Client client,
  Duration timeout = const Duration(seconds: 8),
}) async {
  final sw = Stopwatch()..start();
  try {
    final request = http.Request('GET', cmsProbeUri(site))
      ..headers['Accept'] = 'application/json';
    final res = await client.send(request).timeout(timeout);
    final latency = sw.elapsed;

    if (res.statusCode < 200 || res.statusCode >= 300) {
      unawaited(res.stream.drain<void>().catchError((_) {}));
      return CmsSpeedResult._(
        site: site,
        status: CmsSpeedStatus.failed,
        latency: latency,
        detail: 'HTTP ${res.statusCode}',
      );
    }

    final bytes = await res.stream.toBytes().timeout(timeout);
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
    } on FormatException {
      return CmsSpeedResult._(
        site: site,
        status: CmsSpeedStatus.badData,
        latency: latency,
        detail: '响应不是 JSON',
      );
    }
    if (decoded is! Map || decoded['list'] is! List) {
      return CmsSpeedResult._(
        site: site,
        status: CmsSpeedStatus.badData,
        latency: latency,
        detail: '返回格式异常',
      );
    }
    final list = decoded['list'] as List;
    return CmsSpeedResult._(
      site: site,
      status: latency > kCmsSlowLatency
          ? CmsSpeedStatus.slow
          : CmsSpeedStatus.ok,
      latency: latency,
      itemCount: list.length,
      m3u8Url: _firstM3u8Url(list),
    );
  } on TimeoutException {
    return CmsSpeedResult._(
      site: site,
      status: CmsSpeedStatus.timeout,
      latency: sw.elapsed,
      detail: '超时',
    );
  } catch (_) {
    return CmsSpeedResult._(
      site: site,
      status: CmsSpeedStatus.failed,
      latency: sw.elapsed,
      detail: '无法连接',
    );
  }
}

/// First playable m3u8 in an apiv3 list, or null. Most sources include
/// `vod_play_url` in the list response, so this costs no extra request. The
/// parser already floats m3u8 lines to the front (see [parsePlayUrl]).
String? _firstM3u8Url(List list) {
  for (final row in list) {
    if (row is! Map) continue;
    final raw = row['vod_play_url'];
    if (raw is! String || raw.isEmpty) continue;
    for (final line in parsePlayUrl(raw)) {
      for (final ep in line.episodes) {
        if (ep.url.toLowerCase().contains('.m3u8')) return ep.url;
      }
    }
  }
  return null;
}

/// Probe the play CDN by fetching the first m3u8's headers. The playlist itself
/// is a few KB, so this measures the path to the CDN (DNS + TCP + TLS + origin
/// queueing) — the part that makes 起播 slow — without downloading a segment.
///
/// Many small CDNs reject requests without a browser-ish User-Agent, so send
/// one; a 403 here means "reachable but refuses this client", which is still
/// useful signal, not an app bug.
Future<CmsCdnProbe> probeCdnLatency(
  String url, {
  required http.Client client,
  Duration timeout = const Duration(seconds: 8),
}) async {
  final sw = Stopwatch()..start();
  try {
    final request = http.Request('GET', Uri.parse(url))
      ..headers['Accept'] = '*/*'
      ..headers['User-Agent'] = 'Mozilla/5.0 (Linux; Android 9) BearTV';
    final res = await client.send(request).timeout(timeout);
    final latency = sw.elapsed;
    if (res.statusCode < 200 || res.statusCode >= 300) {
      unawaited(res.stream.drain<void>().catchError((_) {}));
      return CmsCdnProbe(
        status: CmsSpeedStatus.failed,
        latency: latency,
        detail: 'HTTP ${res.statusCode}',
      );
    }
    final bytes = await res.stream.toBytes().timeout(timeout);
    final head = utf8.decode(bytes, allowMalformed: true).trimLeft();
    if (!head.startsWith('#EXTM3U')) {
      return CmsCdnProbe(
        status: CmsSpeedStatus.badData,
        latency: latency,
        detail: '不是 m3u8',
      );
    }
    return CmsCdnProbe(
      status:
          latency > kCmsSlowLatency ? CmsSpeedStatus.slow : CmsSpeedStatus.ok,
      latency: latency,
    );
  } on TimeoutException {
    return CmsCdnProbe(
      status: CmsSpeedStatus.timeout,
      latency: sw.elapsed,
      detail: '超时',
    );
  } catch (_) {
    return CmsCdnProbe(
      status: CmsSpeedStatus.failed,
      latency: sw.elapsed,
      detail: '无法连接',
    );
  }
}

/// Runs [probeCmsSite] for a list of sources concurrently and exposes the
/// results as they land.
///
/// Concurrency matters: the settings page should feel like one action, not N
/// waits. The per-source timeout bounds the whole run, so [running] flips false
/// within [timeout] no matter how many sources are dead. [run] supersedes any
/// in-flight run (the overlay's 重新测速 stays responsive).
class CmsSpeedTester extends ChangeNotifier {
  CmsSpeedTester({
    http.Client? client,
    this.timeout = const Duration(seconds: 8),
  })  : _client = client ?? http.Client(),
        _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;
  final Duration timeout;

  List<CmsSite> _sites = const [];
  final Map<String, CmsSpeedResult> _results = {};
  bool _running = false;
  bool _disposed = false;
  int _token = 0;

  bool get running => _running;

  /// Results in the order [run] was given, pending included.
  List<CmsSpeedResult> get results => [
        for (final site in _sites)
          _results[site.id] ?? CmsSpeedResult.pending(site),
      ];

  int get doneCount => results.where((r) => r.finished).length;

  /// Probe every site in [sites]. Completes when all probes have settled (or a
  /// newer [run] superseded this one).
  Future<void> run(List<CmsSite> sites) async {
    final token = ++_token;
    _sites = List<CmsSite>.unmodifiable(sites);
    _results
      ..clear()
      ..addEntries([
        for (final site in sites)
          MapEntry(site.id, CmsSpeedResult.pending(site)),
      ]);
    _running = sites.isNotEmpty;
    _notify();
    if (sites.isEmpty) return;

    await Future.wait([
      for (final site in sites) _probe(site, token),
    ]);
    if (token != _token) return;
    _running = false;
    _notify();
  }

  Future<void> _probe(CmsSite site, int token) async {
    var result = await probeCmsSite(site, client: _client, timeout: timeout);
    if (token != _token || _disposed) return;
    _results[site.id] = result;
    _notify();

    // Phase two: the API answered and pointed at an m3u8 — follow it to the
    // play CDN. Published separately so the row is already useful while this
    // runs (and so a slow CDN doesn't hide a healthy API).
    final url = result.m3u8Url;
    if (url == null) return;
    result = result.withCdnPending();
    _results[site.id] = result;
    _notify();

    final cdn = await probeCdnLatency(url, client: _client, timeout: timeout);
    if (token != _token || _disposed) return;
    _results[site.id] = result.withCdn(cdn);
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _token++;
    if (_ownsClient) _client.close();
    super.dispose();
  }
}
