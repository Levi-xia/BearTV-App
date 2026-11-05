import 'dart:convert';

import '../../core/env.dart';
import 'cms_models.dart';

/// Build-time injected CMS sources (`CMS_SITES_JSON`), parsed once. An empty
/// define yields no sources. From [SettingsStore.init] a non-empty value
/// overwrites the saved source list, so changing `secrets.json` and rebuilding
/// is visible in Settings — exactly like IPTV and danmaku.
List<CmsSite> buildTimeCmsSites() =>
    _buildTimeCmsSites ??= parseCmsSiteList(Env.cmsSitesJson);

List<CmsSite>? _buildTimeCmsSites;

/// Source ids enabled by the build-time `DEFAULT_SELECTED_JSON`. Empty means
/// "every configured source is selected".
List<String> buildTimeSelectedIds() =>
    _buildTimeSelectedIds ??= parseSelectedIds(Env.defaultSelectedJson);

List<String>? _buildTimeSelectedIds;

/// Parse a JSON array string into sources. Malformed entries are skipped rather
/// than crashing startup — a typo in `secrets.json` should not brick the app.
/// Entries without a usable API URL are dropped, duplicate API URLs are
/// collapsed (first wins), and a missing/duplicate id gets a stable generated
/// one. Display names fall back to the API host.
List<CmsSite> parseCmsSiteList(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return const [];
  try {
    final decoded = jsonDecode(text);
    return decoded is List ? parseCmsSiteRows(decoded) : const [];
  } catch (_) {
    return const [];
  }
}

/// Parse already-decoded source rows (accepts both `secrets.json`'s stringified
/// array and a real JSON array, which is what the import payload carries).
List<CmsSite> parseCmsSiteRows(List<dynamic> rows) {
  final out = <CmsSite>[];
  final ids = <String>{};
  final apis = <String>{};
  var index = 0;
  for (final row in rows) {
    index++;
    if (row is! Map) continue;
    final site = CmsSite.fromJson(Map<String, dynamic>.from(row));
    final apiKey = normalizeCmsApi(site.api);
    if (apiKey == null) continue; // missing / non-http api
    var id = site.id;
    if (id.isEmpty || ids.contains(id)) {
      // Keep a stable, unique id: imported selections reference these ids.
      var n = index;
      while (ids.contains('cms_$n')) {
        n++;
      }
      id = 'cms_$n';
    }
    if (!apis.add(apiKey)) continue; // duplicate URL: first one wins
    ids.add(id);
    out.add(CmsSite(
      id: id,
      name: site.name.isEmpty
          ? (Uri.tryParse(site.api)?.host ?? '资源站 $index')
          : site.name,
      api: site.api,
      detail: site.detail,
    ));
  }
  return out;
}

/// Parse a JSON array string of selected source ids.
List<String> parseSelectedIds(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return const [];
  try {
    final decoded = jsonDecode(text);
    return decoded is List ? parseSelectedIdRows(decoded) : const [];
  } catch (_) {
    return const [];
  }
}

/// Parse already-decoded selected-id rows, dropping non-strings / blanks.
List<String> parseSelectedIdRows(List<dynamic> rows) => [
      for (final v in rows)
        if (v is String && v.trim().isNotEmpty) v.trim(),
    ];
