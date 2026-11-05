import 'dart:convert';

import '../../core/env.dart';
import 'cms_models.dart';

/// Built-in MacCMS apiv3 collection sources.
///
/// The list is NOT committed: it comes from the build-time
/// `CMS_SITES_JSON` define (see [Env] and `secrets.example.json`). An
/// open-source build therefore ships no third-party endpoints; users add their
/// own in Settings (`kMaxCustomSites`). `detail` (when present) marks a
/// "special" source whose real m3u8 links live on an HTML detail page rather
/// than the JSON `vod_play_url`; [CmsClient] scrapes those with a regex
/// fallback.
final List<CmsSite> kBuiltinSites = _parseSites(Env.cmsSitesJson);

/// Sources enabled on first launch. Empty → every built-in source is enabled.
final List<String> kDefaultSelected = _parseIds(
  Env.defaultSelectedJson,
  fallback: [for (final s in kBuiltinSites) s.id],
);

/// Max custom sources a user may add (BearTV `CUSTOM_API_CONFIG.maxSources`).
const int kMaxCustomSites = 20;

/// Lookup a built-in site by id.
CmsSite? builtinSiteById(String id) {
  for (final s in kBuiltinSites) {
    if (s.id == id) return s;
  }
  return null;
}

/// Parse the build-time source JSON. Malformed entries are skipped rather than
/// crashing startup — a typo in `secrets.json` should not brick the app.
List<CmsSite> _parseSites(String raw) {
  if (raw.trim().isEmpty) return const [];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    final out = <CmsSite>[];
    for (final row in decoded) {
      if (row is! Map) continue;
      try {
        out.add(CmsSite.fromJson(Map<String, dynamic>.from(row)));
      } catch (_) {
        // Skip a single malformed source.
      }
    }
    return out;
  } catch (_) {
    return const [];
  }
}

List<String> _parseIds(String raw, {required List<String> fallback}) {
  if (raw.trim().isEmpty) return fallback;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return fallback;
    final ids = [for (final v in decoded) if (v is String && v.isNotEmpty) v];
    return ids.isEmpty ? fallback : ids;
  } catch (_) {
    return fallback;
  }
}
