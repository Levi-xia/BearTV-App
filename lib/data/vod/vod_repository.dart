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
  VodRepository({CmsClient? client}) : _client = client ?? CmsClient();

  final CmsClient _client;

  void close() {
    _clearMemo();
    _client.close();
  }

  static String _norm(String v) => v.trim().toLowerCase();

  // --- Short-lived request memo --------------------------------------------
  //
  // The TMDB flow runs the same per-source search twice within a few seconds:
  // once in [resolveByTitle] to pick a stream, then again in
  // [loadResourceOptions] to build the 切换资源 list. The second pass also
  // re-fetches details already probed by the first. Memoizing the *future*
  // (not just the result) also dedupes requests that are still in flight when
  // the second pass starts. Everything expires quickly — this is a dedupe
  // window for one playback start, not a catalogue cache.
  static const Duration _memoTtl = Duration(minutes: 2);
  static const int _memoLimit = 96;

  final Map<String, _Pending<List<SearchHit>>> _searchMemo = {};
  final Map<String, _Pending<VodDetail?>> _detailMemo = {};

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
    memo[key] = entry;
    while (memo.length > _memoLimit) {
      memo.remove(memo.keys.first);
    }
  }

  /// Search [query] on [site], sharing an in-flight/just-finished request.
  Future<List<SearchHit>> _search(CmsSite site, String query) {
    final key = '${site.id}\u0000$query';
    final hit = _lookup(_searchMemo, key);
    if (hit != null) return hit.future;
    final f = _client.searchSource(site, query);
    _store(_searchMemo, key, _Pending(f));
    return f;
  }

  /// Detail lookup with the same dedupe. Failures (null) are not memoized, so
  /// a later attempt can still succeed.
  Future<VodDetail?> _detailOf(CmsSite site, String vodId) async {
    final key = '${site.id}\u0000$vodId';
    final hit = _lookup(_detailMemo, key);
    if (hit != null) return hit.future;
    final f = _client.fetchDetail(site, vodId);
    _store(_detailMemo, key, _Pending(f));
    final detail = await f;
    if (detail == null && identical(_detailMemo[key]?.future, f)) {
      _detailMemo.remove(key);
    }
    return detail;
  }

  void _clearMemo() {
    _searchMemo.clear();
    _detailMemo.clear();
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
  /// when no source has an exact hit do we fall back to the remaining hits
  /// (in source order) once every search has answered. Capped attempts keep it
  /// light on low-end hardware.
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

    // Nothing matched exactly. Walk the remaining hits in source order.
    for (final site in sites) {
      for (final hit in restBySite[site.id] ?? const <SearchHit>[]) {
        if (attempts++ >= maxAttempts) return null;
        final detail = await _detailOf(site, hit.vodId);
        if (detail != null && detail.firstEpisode != null) return detail;
      }
    }
    return null;
  }

  /// Build the cross-source "switch resource" candidate list for [title].
  /// One [ResourceOption] per source (its best matching detail).
  ///
  /// [current] is the stream actually playing right now. Its source skips the
  /// search entirely — we already have its detail, and this is the 最近播放
  /// path where no search ran before this pass. It is flagged as current and
  /// floated to the top, and stays in the list even when the source's search
  /// page wouldn't have listed it.
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
}

/// One memoized in-flight/complete request plus when it was issued.
class _Pending<T> {
  _Pending(this.future) : at = DateTime.now();

  final Future<T> future;
  final DateTime at;
}
