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

  void close() => _client.close();

  static String _norm(String v) => v.trim().toLowerCase();

  /// Direct keyword search across every enabled source, concurrently. Returns
  /// the raw hits in source order (exact-title matches floated to the front
  /// within that order) — one card per hit, so the same title found on several
  /// sources shows up once per source and each can be played directly.
  Future<List<SearchHit>> searchAll(String keyword, List<CmsSite> sites) async {
    final query = keyword.trim();
    if (query.isEmpty || sites.isEmpty) return const [];

    final perSource = await Future.wait(
      sites.map((s) => _client.searchSource(s, query)),
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
      unawaited(_client.fetchDetail(site, hit.vodId).then(
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
      unawaited(_client.searchSource(site, query).then(
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
        final detail = await _client.fetchDetail(site, hit.vodId);
        if (detail != null && detail.firstEpisode != null) return detail;
      }
    }
    return null;
  }

  /// Build the cross-source "switch resource" candidate list for [title].
  /// One [ResourceOption] per source (its best matching detail). [currentKey]
  /// (`sourceId:vodId`) is flagged and floated to the top.
  Future<List<ResourceOption>> loadResourceOptions(
    String title,
    List<CmsSite> sites, {
    String? currentKey,
  }) async {
    final query = title.trim();
    if (query.isEmpty || sites.isEmpty) return const [];

    final options = await Future.wait(sites.map((site) => _candidateFor(site, query, currentKey)));
    final list = options.whereType<ResourceOption>().toList();
    list.sort((a, b) {
      if (a.isCurrent != b.isCurrent) return a.isCurrent ? -1 : 1;
      if (a.available != b.available) return a.available ? -1 : 1;
      return b.episodeCount.compareTo(a.episodeCount);
    });
    return list;
  }

  Future<ResourceOption?> _candidateFor(CmsSite site, String query, String? currentKey) async {
    final hits = await _client.searchSource(site, query);
    if (hits.isEmpty) return null;
    final hit = hits.firstWhere(
      (h) => _norm(h.title) == _norm(query),
      orElse: () => hits.first,
    );
    final detail = await _client.fetchDetail(site, hit.vodId);
    final available = detail?.firstEpisode != null;
    final key = '${site.id}:${hit.vodId}';
    return ResourceOption(
      sourceId: site.id,
      sourceName: site.name,
      vodId: hit.vodId,
      title: detail?.title.isNotEmpty == true ? detail!.title : hit.title,
      episodeCount: detail?.episodeCount ?? 0,
      available: available,
      detail: available ? detail : null,
      isCurrent: currentKey != null && key == currentKey,
    );
  }

  /// Fetch a specific source's detail (used when the user picks a switch option
  /// that wasn't pre-resolved).
  Future<VodDetail?> detail(CmsSite site, String vodId) => _client.fetchDetail(site, vodId);
}
