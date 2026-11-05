import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'danmaku/danmaku_models.dart';
import 'iptv/iptv_models.dart';
import 'vod/cms_models.dart';
import 'vod/cms_sources.dart';

/// Turns a downloaded config payload into a fully validated [ImportedConfig].
///
/// This file is deliberately free of app state: it never writes settings. The
/// caller applies the returned plan atomically, so a malformed payload leaves
/// the existing configuration untouched.
///
/// Wire format (see `secrets.example.json` for the inner shape):
///
/// ```json
/// ["<base64 of a UTF-8 secrets JSON object>"]
/// ```
///
/// An outer array with exactly one string is required. The decoded object uses
/// the same keys as `secrets.json`; `CMS_SITES_JSON` / `DEFAULT_SELECTED_JSON`
/// may be either stringified arrays or real JSON arrays.
class ConfigImportException implements Exception {
  const ConfigImportException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// The validated result of an import. `null` means "this payload does not
/// mention the section" — applying it leaves the current value untouched. An
/// empty list is an explicit clear.
class ImportedConfig {
  final String? tmdbApiKey;
  final String? tmdbProxyBase;
  final List<CmsSite>? cmsSites;
  final List<String>? selectedSourceIds;
  final List<DanmakuHost>? danmakuHosts;
  final String? danmakuDefaultHostId;
  final List<IptvSource>? iptvSources;
  final String? iptvSelectedSourceId;

  const ImportedConfig({
    this.tmdbApiKey,
    this.tmdbProxyBase,
    this.cmsSites,
    this.selectedSourceIds,
    this.danmakuHosts,
    this.danmakuDefaultHostId,
    this.iptvSources,
    this.iptvSelectedSourceId,
  });

  bool get isEmpty =>
      tmdbApiKey == null &&
      tmdbProxyBase == null &&
      cmsSites == null &&
      danmakuHosts == null &&
      iptvSources == null;
}

/// Download [url] (http/https only), then parse it. Throws
/// [ConfigImportException] with a user-facing message on any failure.
Future<ImportedConfig> fetchConfigImport(String url,
    {http.Client? client}) async {
  final uri = Uri.tryParse(url.trim());
  if (uri == null ||
      uri.host.isEmpty ||
      (uri.scheme != 'http' && uri.scheme != 'https')) {
    throw const ConfigImportException('请输入 http/https 开头的导入地址');
  }
  final owned = client == null ? http.Client() : null;
  final c = client ?? owned!;
  try {
    final resp = await c.get(uri, headers: const {
      'Accept': 'application/json'
    }).timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) {
      throw ConfigImportException('导入失败：服务器返回 ${resp.statusCode}');
    }
    if (resp.bodyBytes.length > 512 * 1024) {
      throw const ConfigImportException('导入失败：内容超过 512KB');
    }
    return parseConfigImportPayload(utf8.decode(resp.bodyBytes));
  } on ConfigImportException {
    rethrow;
  } on TimeoutException {
    throw const ConfigImportException('导入失败：请求超时');
  } catch (_) {
    throw const ConfigImportException('导入失败：无法下载配置');
  } finally {
    owned?.close();
  }
}

/// Parse the raw response body. Kept pure so it can be unit-tested offline.
ImportedConfig parseConfigImportPayload(String body) {
  final dynamic outer;
  try {
    outer = jsonDecode(body.trim());
  } catch (_) {
    throw const ConfigImportException('导入失败：内容不是有效 JSON');
  }
  if (outer is! List) {
    throw const ConfigImportException('导入失败：响应应为 JSON 数组');
  }
  if (outer.length != 1) {
    throw const ConfigImportException('导入失败：数组应只包含 1 项');
  }
  final encoded = outer.first;
  if (encoded is! String || encoded.trim().isEmpty) {
    throw const ConfigImportException('导入失败：数组项应为 base64 字符串');
  }

  final String decodedText;
  try {
    // Accept both the standard and URL-safe alphabets and ignore whitespace
    // anywhere in the string; base64.normalize restores missing padding.
    final normalized = encoded
        .replaceAll(RegExp(r'\s+'), '')
        .replaceAll('-', '+')
        .replaceAll('_', '/');
    decodedText = utf8.decode(base64.decode(base64.normalize(normalized)));
  } catch (_) {
    throw const ConfigImportException('导入失败：base64 解码失败');
  }

  final dynamic inner;
  try {
    inner = jsonDecode(decodedText);
  } catch (_) {
    throw const ConfigImportException('导入失败：解码内容不是有效 JSON');
  }
  if (inner is! Map) {
    throw const ConfigImportException('导入失败：解码内容应为 JSON 对象');
  }
  return parseConfigImportSecrets(Map<String, dynamic>.from(inner));
}

/// Parse the decoded secrets-format object (same keys as `secrets.json`).
ImportedConfig parseConfigImportSecrets(Map<String, dynamic> j) {
  String? text(String key) {
    final v = j[key];
    if (v is! String) return null;
    final t = v.trim();
    return t.isEmpty ? null : t;
  }

  // --- CMS sources ----------------------------------------------------------
  List<CmsSite>? cmsSites;
  final cmsRaw = j['CMS_SITES_JSON'];
  if (cmsRaw != null) {
    final rows = _asRows(cmsRaw, 'CMS_SITES_JSON');
    cmsSites = parseCmsSiteRows(rows);
    // An explicitly empty array is a valid "clear everything"; a non-empty
    // array that yields no usable rows is a malformed payload.
    if (rows.isNotEmpty && cmsSites.isEmpty) {
      throw const ConfigImportException('导入失败：CMS_SITES_JSON 中没有有效的资源站');
    }
  }

  // --- Selected ids ---------------------------------------------------------
  List<String>? selected;
  final selectedRaw = j['DEFAULT_SELECTED_JSON'];
  if (selectedRaw != null) {
    selected =
        parseSelectedIdRows(_asRows(selectedRaw, 'DEFAULT_SELECTED_JSON'));
  }
  if (cmsSites != null) {
    final valid = {for (final s in cmsSites) s.id};
    final filtered = selected?.where(valid.contains).toList() ?? <String>[];
    // Missing / empty / all-stale selection selects everything that was
    // imported, so the app is immediately usable.
    selected = filtered.isEmpty ? valid.toList() : filtered;
  } else {
    // A selection without a source list would reference ids we don't have.
    selected = null;
  }

  // --- Danmaku --------------------------------------------------------------
  final dmBase = text('DANMAKU_BASE_URL');
  final dmToken = text('DANMAKU_TOKEN');
  List<DanmakuHost>? hosts;
  String? dmDefaultId;
  if (dmBase != null || dmToken != null) {
    if (dmBase == null || dmToken == null) {
      throw const ConfigImportException(
          '导入失败：DANMAKU_BASE_URL 与 DANMAKU_TOKEN 需同时填写');
    }
    _requireHttp(dmBase, 'DANMAKU_BASE_URL');
    final name = text('DANMAKU_NAME') ?? '默认弹幕源';
    final host = DanmakuHost(
      id: 'danmaku_default',
      name: name,
      baseUrl: dmBase,
      token: dmToken,
    );
    hosts = [host];
    dmDefaultId = host.id;
  }

  // --- IPTV -----------------------------------------------------------------
  final iptvUrl = text('IPTV_PLAYLIST_URL');
  List<IptvSource>? iptv;
  String? iptvSelected;
  if (iptvUrl != null) {
    _requireHttp(iptvUrl, 'IPTV_PLAYLIST_URL');
    final source = IptvSource(
      id: 'iptv_default_zn',
      name: text('IPTV_PLAYLIST_NAME') ?? '默认直播源',
      url: iptvUrl,
    );
    iptv = [source];
    iptvSelected = source.id;
  }

  // --- TMDB -----------------------------------------------------------------
  final apiKey = text('TMDB_API_KEY');
  final proxyBase = text('TMDB_PROXY_BASE');
  if (proxyBase != null) _requireHttp(proxyBase, 'TMDB_PROXY_BASE');

  return ImportedConfig(
    tmdbApiKey: apiKey,
    tmdbProxyBase: proxyBase,
    cmsSites: cmsSites,
    selectedSourceIds: selected,
    danmakuHosts: hosts,
    danmakuDefaultHostId: dmDefaultId,
    iptvSources: iptv,
    iptvSelectedSourceId: iptvSelected,
  );
}

/// Accept either a real JSON array or the stringified array `secrets.json`
/// stores, and reject everything else.
List<dynamic> _asRows(dynamic raw, String field) {
  if (raw is List) return raw;
  if (raw is String) {
    final s = raw.trim();
    if (s.isEmpty) return const [];
    try {
      final decoded = jsonDecode(s);
      if (decoded is List) return decoded;
    } catch (_) {
      // Fall through to the shared error below.
    }
  }
  throw ConfigImportException('导入失败：$field 格式错误');
}

void _requireHttp(String value, String field) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.host.isEmpty ||
      (uri.scheme != 'http' && uri.scheme != 'https')) {
    throw ConfigImportException('导入失败：$field 需为 http/https 地址');
  }
}
