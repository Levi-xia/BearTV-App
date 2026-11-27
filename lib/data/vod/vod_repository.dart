import 'dart:async';

import 'cms_client.dart';
import 'cms_models.dart';

/// Playback resolution layer, ported from BearTV `resourceSwitcher.js` +
/// `useSearch`/`loadCandidate`. It answers two things: "given a title, find a
/// playable stream across the enabled sources" ([resolveByTitle], used by the
/// TMDB → CMS flow) and — for the direct "资源直搜" mode — "given a keyword,
/// list every source's raw search hits" ([searchAll]).
///
/// All multi-source work is concurrent and per-source failures degrade
/// silently, so one dead provider never blocks the rest.
class VodRepository {
  VodRepository({
    CmsClient? client,
    this.resourceConcurrency = 3,
    this.resourceTimeout = const Duration(seconds: 35),
  })  : assert(resourceConcurrency > 0),
        _client = client ?? CmsClient();

  final int resourceConcurrency;
  final Duration resourceTimeout;

  final CmsClient _client;
  bool _closed = false;

  void close() {
    _closed = true;
    _clearMemo();
    _client.close();
  }

  static String _norm(String v) {
    final folded = String.fromCharCodes(
        v.runes.map((r) => r >= 0xFF01 && r <= 0xFF5E ? r - 0xFEE0 : r));
    // Preserve punctuation, years and season numbers: those distinguish works.
    return folded.replaceAll(RegExp(r'\s+'), '').toLowerCase();
  }

  // --- Short-lived request memo --------------------------------------------
  //
  // The TMDB flow runs the same per-source search twice within a few seconds:
  // once in [resolveByTitle] to pick a stream, then again in
  // [loadResourceOptions] to build the 切换资源 list. The second pass also
  // re-fetches details already probed by the first. Memoizing the *future*
  // (not just the result) dedupes in-flight work within a request scope.
  // Completed results are also published under an unscoped key for reuse by
  // later scopes. In-flight work stays isolated so one caller cannot cancel
  // another caller's HTTP request. Everything expires quickly — this is a dedupe
  // window for one playback start, not a catalogue cache.
  static const Duration _memoTtl = Duration(minutes: 2);
  static const int _memoLimit = 96;

  final Map<String, _Pending<List<SearchHit>>> _searchMemo = {};
  final Map<String, _Pending<VodDetail?>> _detailMemo = {};
  final Map<String, Object> _detailVersions = {};

  Object _newDetailVersion(String key) {
    final version = Object();
    _detailVersions.remove(key);
    _detailVersions[key] = version;
    while (_detailVersions.length > _memoLimit) {
      _detailVersions.remove(_detailVersions.keys.first);
    }
    return version;
  }

  void _invalidateDetailMemo(String baseKey) {
    _detailMemo.removeWhere(
        (key, _) => key == baseKey || key.endsWith('\u0000$baseKey'));
  }

  String _scopedKey(String key) {
    final scope = CmsRequestScope.current;
    return scope == null ? key : '${scope.id}\u0000$key';
  }

  _Pending<T>? _lookup<T>(Map<String, _Pending<T>> memo, String key) {
    final entry = memo[key];
    if (entry == null) return null;
    if (DateTime.now().difference(entry.at) > _memoTtl) {
      memo.remove(key);
      return null;
    }
    memo.remove(key);
    memo[key] = entry; // LRU touch
    return entry;
  }

  void _store<T>(Map<String, _Pending<T>> memo, String key, _Pending<T> entry) {
    if (_closed) return;
    memo[key] = entry;
    while (memo.length > _memoLimit) {
      memo.remove(memo.keys.first);
    }
  }

  /// Search [query] on [site], sharing an in-flight/just-finished request.
  Future<List<SearchHit>> _search(CmsSite site, String query) async {
    final baseKey = '${site.id}\u0000$query';
    final key = _scopedKey(baseKey);
    final scope = CmsRequestScope.current;
    final shared = scope == null ? null : _lookup(_searchMemo, baseKey);
    final hit = _lookup(_searchMemo, key) ??
        (shared?.completed == true ? shared : null);
    if (hit != null) return hit.future;
    final f = _client.searchSource(site, query);
    _store(_searchMemo, key, _Pending(f));
    try {
      final hits = await f;
      if (scope?.cancelled != true && hits.isNotEmpty) {
        _store(_searchMemo, baseKey,
            _Pending(Future.value(hits), completed: true));
      } else if (identical(_searchMemo[key]?.future, f)) {
        _searchMemo.remove(key);
      }
      return hits;
    } catch (_) {
      if (identical(_searchMemo[key]?.future, f)) _searchMemo.remove(key);
      rethrow;
    }
  }

  /// Detail lookup with the same dedupe. Failures (null) are not memoized, so
  /// a later attempt can still succeed.
  Future<VodDetail?> _detailOf(CmsSite site, String vodId) async {
    final baseKey = '${site.id}\u0000$vodId';
    final version = _detailVersions[baseKey] ?? _newDetailVersion(baseKey);
    final key = _scopedKey(baseKey);
    final scope = CmsRequestScope.current;
    final shared = scope == null ? null : _lookup(_detailMemo, baseKey);
    final hit = _lookup(_detailMemo, key) ??
        (shared?.completed == true ? shared : null);
    if (hit != null) return hit.future;
    final f = _client.fetchDetail(site, vodId);
    _store(_detailMemo, key, _Pending(f));
    VodDetail? detail;
    try {
      detail = await f;
    } catch (_) {
      if (identical(_detailMemo[key]?.future, f)) _detailMemo.remove(key);
      rethrow;
    }
    if (scope?.cancelled != true &&
        detail != null &&
        identical(version, _detailVersions[baseKey])) {
      _store(_detailMemo, baseKey,
          _Pending(Future.value(detail), completed: true));
    }
    if (detail == null && identical(_detailMemo[key]?.future, f)) {
      _detailMemo.remove(key);
    }
    return detail;
  }

  void _clearMemo() {
    _searchMemo.clear();
    _detailMemo.clear();
    _detailVersions.clear();
  }

  /// Direct keyword search across every enabled source, concurrently. Returns
  /// the raw hits in source order (exact-title matches floated to the front
  /// within that order) — one card per hit, so the same title found on several
  /// sources shows up once per source and each can be played directly.
  Future<List<SearchHit>> searchAll(String keyword, List<CmsSite> sites) async {
    final query = keyword.trim();
    if (query.isEmpty || sites.isEmpty) return const [];

    final perSource = await Future.wait(
      sites.map((s) => _search(s, query)),
    );
    final exact = <SearchHit>[];
    final rest = <SearchHit>[];
    for (final hits in perSource) {
      for (final h in hits) {
        (_norm(h.title) == _norm(query) ? exact : rest).add(h);
      }
    }
    return [...exact, ...rest];
  }

  /// Resolve the best playable [VodDetail] for [title] across [sites].
  ///
  /// Sources are searched concurrently and the first source that returns an
  /// exact-title hit has its detail probed immediately — we return as soon as
  /// any exact hit is playable instead of waiting for the slowest source. Only
  /// when exact probes have no playable result do we fall back to the remaining
  /// hits once every search has answered. Fallback schedules in source order
  /// with at most two concurrent probes and a shared six-attempt limit.
  Future<VodDetail?> resolveByTitle(String title, List<CmsSite> sites) async {
    final query = title.trim();
    if (query.isEmpty || sites.isEmpty) return null;

    final siteById = {for (final s in sites) s.id: s};
    final restBySite = <String, List<SearchHit>>{};
    final done = Completer<VodDetail?>();
    var pendingSearches = sites.length;
    var activeProbes = 0;
    var attempts = 0;
    const maxAttempts = 6;

    void finishIfIdle() {
      if (done.isCompleted) return;
      if (activeProbes == 0 && pendingSearches == 0) done.complete(null);
    }

    void probeExact(SearchHit hit) {
      final site = siteById[hit.sourceId];
      if (done.isCompleted || attempts >= maxAttempts || site == null) return;
      attempts++;
      activeProbes++;
      unawaited(_detailOf(site, hit.vodId).then(
        (detail) {
          activeProbes--;
          if (!done.isCompleted && detail?.firstEpisode != null) {
            done.complete(detail);
          }
          finishIfIdle();
        },
        onError: (_) {
          activeProbes--;
          finishIfIdle();
        },
      ));
    }

    for (final site in sites) {
      unawaited(_search(site, query).then(
        (hits) {
          pendingSearches--;
          if (!done.isCompleted) {
            final rest = <SearchHit>[];
            for (final h in hits) {
              if (_norm(h.title) == _norm(query)) {
                probeExact(h); // don't wait for the other sources
              } else {
                rest.add(h);
              }
            }
            if (rest.isNotEmpty) restBySite[site.id] = rest;
          }
          finishIfIdle();
        },
        onError: (_) {
          pendingSearches--;
          finishIfIdle();
        },
      ));
    }

    final exact = await done.future;
    if (exact != null) return exact;

    // Nothing matched exactly. Probe at most two candidates concurrently,
    // retaining source order for scheduling and the shared total attempt cap.
    final candidates = <(CmsSite, SearchHit)>[];
    for (final site in sites) {
      for (final hit in restBySite[site.id] ?? const <SearchHit>[]) {
        if (candidates.length >= maxAttempts - attempts) break;
        candidates.add((site, hit));
      }
    }
    if (candidates.isEmpty) return null;
    final fallback = Completer<VodDetail?>();
    var cursor = 0;
    var workers = candidates.length < 2 ? candidates.length : 2;
    Future<void> probeRemaining() async {
      try {
        while (!fallback.isCompleted && cursor < candidates.length) {
          final (site, hit) = candidates[cursor++];
          try {
            final detail = await _detailOf(site, hit.vodId);
            if (!fallback.isCompleted && detail?.firstEpisode != null) {
              fallback.complete(detail);
            }
          } catch (_) {
            // One broken provider must not prevent trying the next candidate.
          }
        }
      } finally {
        workers--;
        if (workers == 0 && !fallback.isCompleted) fallback.complete(null);
      }
    }

    for (var i = 0; i < (candidates.length < 2 ? candidates.length : 2); i++) {
      unawaited(probeRemaining());
    }
    return fallback.future;
  }

  /// Build the cross-source "switch resource" candidate list for [title].
  /// One [ResourceOption] per source (its best matching detail).
  ///
  /// [current] is the stream actually playing right now. Its source skips the
  /// search entirely — we already have its detail, and this is the 最近播放
  /// path where no search ran before this pass. It is flagged as current and
  /// floated to the top, and stays in the list even when the source's search
  /// page wouldn't have listed it.
  Stream<List<ResourceOption>> watchResourceOptions(
    String title,
    List<CmsSite> sites, {
    VodDetail? current,
  }) {
    late final StreamController<List<ResourceOption>> controller;
    var cancelled = false;
    var nextSite = 0;
    final scopes = <CmsRequestScope>{};
    final options = <ResourceOption>[];
    void publish() {
      if (cancelled) return;
      options.sort((a, b) {
        if (a.isCurrent != b.isCurrent) return a.isCurrent ? -1 : 1;
        if (a.available != b.available) return a.available ? -1 : 1;
        return b.episodeCount.compareTo(a.episodeCount);
      });
      controller.add(List.unmodifiable(options));
    }

    Future<void> worker() async {
      while (!cancelled && nextSite < sites.length) {
        final site = sites[nextSite++];
        final scope = CmsRequestScope(reportErrors: true);
        scopes.add(scope);
        try {
          final result = await scope
              .run(() => loadResourceOptions(title, [site], current: current))
              .timeout(resourceTimeout);
          if (cancelled) return;
          options.addAll(result);
          publish();
        } catch (error) {
          if (cancelled) return;
          options.add(ResourceOption(
            sourceId: site.id,
            sourceName: site.name,
            vodId: '',
            title: title,
            error: error is TimeoutException
                ? '查询超时'
                : error is CatalogueException
                    ? error.message
                    : '查询失败',
          ));
          publish();
        } finally {
          scope.cancel();
          scopes.remove(scope);
          // Let abort-trigger listeners release the previous transport before
          // this worker starts another source.
          await Future<void>.delayed(Duration.zero);
        }
      }
    }

    controller = StreamController<List<ResourceOption>>(
      onListen: () {
        unawaited(Future<void>(() async {
          final workers = sites.length < resourceConcurrency
              ? sites.length
              : resourceConcurrency;
          await Future.wait(List.generate(workers, (_) => worker()));
          if (!cancelled) await controller.close();
        }));
      },
      onCancel: () {
        cancelled = true;
        for (final scope in scopes.toList()) {
          scope.cancel();
        }
      },
    );
    return controller.stream;
  }

  Future<List<ResourceOption>> loadResourceOptions(
    String title,
    List<CmsSite> sites, {
    VodDetail? current,
  }) async {
    final query = title.trim();
    if (query.isEmpty || sites.isEmpty) return const [];

    final options = await Future.wait(
        sites.map((site) => _candidateFor(site, query, current)));
    final list = options.whereType<ResourceOption>().toList();
    list.sort((a, b) {
      if (a.isCurrent != b.isCurrent) return a.isCurrent ? -1 : 1;
      if (a.available != b.available) return a.available ? -1 : 1;
      return b.episodeCount.compareTo(a.episodeCount);
    });
    return list;
  }

  Future<ResourceOption?> _candidateFor(
      CmsSite site, String query, VodDetail? current) async {
    if (current != null &&
        current.sourceId == site.id &&
        current.firstEpisode != null) {
      return ResourceOption(
        sourceId: site.id,
        sourceName: site.name,
        vodId: current.vodId,
        title: current.title.isNotEmpty ? current.title : query,
        episodeCount: current.episodeCount,
        available: true,
        detail: current,
        isCurrent: true,
      );
    }
    final hits = await _search(site, query);
    if (hits.isEmpty) return null;
    final hit = hits.firstWhere(
      (h) => _norm(h.title) == _norm(query),
      orElse: () => hits.first,
    );
    final detail = await _detailOf(site, hit.vodId);
    final available = detail?.firstEpisode != null;
    return ResourceOption(
      sourceId: site.id,
      sourceName: site.name,
      vodId: hit.vodId,
      title: detail?.title.isNotEmpty == true ? detail!.title : hit.title,
      episodeCount: detail?.episodeCount ?? 0,
      available: available,
      detail: available ? detail : null,
      isCurrent: current != null && '${site.id}:${hit.vodId}' == current.key,
    );
  }

  /// Fetch a specific source's detail (used when the user picks a switch option
  /// that wasn't pre-resolved).
  Future<VodDetail?> detail(CmsSite site, String vodId) =>
      _detailOf(site, vodId);

  /// Bypass the short playback-start memo when updating an offline catalogue.
  Future<VodDetail?> latestDetail(CmsSite site, String vodId) {
    final key = '${site.id}\u0000$vodId';
    final version = _newDetailVersion(key);
    _invalidateDetailMemo(key);
    final future = _client.fetchLatestDetail(site, vodId);
    // Share a successful fresh result with the delayed resource-option lookup.
    // Failures are deliberately not memoized.
    return future.then((detail) {
      if (_closed || !identical(_detailVersions[key], version)) return detail;
      _newDetailVersion(key);
      _invalidateDetailMemo(key);
      if (detail != null) {
        _store(
            _detailMemo, key, _Pending(Future.value(detail), completed: true));
      } else {
        _detailMemo.remove(key);
      }
      return detail;
    });
  }
}

/// One memoized in-flight/complete request plus when it was issued.
class _Pending<T> {
  _Pending(this.future, {this.completed = false}) : at = DateTime.now();

  final Future<T> future;
  final bool completed;
  final DateTime at;
}
