import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/config.dart';

/// Thrown for any non-2xx TMDB response or exhausted retries.
class TmdbException implements Exception {
  final String message;
  final int? status;
  TmdbException(this.message, {this.status});
  @override
  String toString() => 'TmdbException($status): $message';
}

/// Thin TMDB v3 REST client. Adds api_key / zh-CN language / region and does
/// bounded retries with exponential backoff. Returns decoded JSON maps.
class TmdbApi {
  TmdbApi({required String apiKey, http.Client? client, String? base})
      : _client = client ?? http.Client(),
        _apiKey = apiKey,
        _base = base ?? Config.tmdbBase;

  final http.Client _client;
  final String _apiKey;
  final String _base;

  static const _timeout = Duration(seconds: 8);
  static const _maxRetries = 2;

  Future<Map<String, dynamic>> _get(String path, [Map<String, String>? query]) async {
    final uri = Uri.parse('$_base$path').replace(queryParameters: {
      'api_key': _apiKey,
      'language': 'zh-CN',
      'include_adult': 'false',
      ...?query,
    });

    Object? lastErr;
    for (var attempt = 0; attempt <= _maxRetries; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(Duration(milliseconds: 300 * (1 << (attempt - 1))));
      }
      try {
        final res = await _client.get(uri).timeout(_timeout);
        if (res.statusCode >= 200 && res.statusCode < 300) {
          return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
        }
        // 4xx (bad key / not found) won't get better on retry — fail fast.
        if (res.statusCode >= 400 && res.statusCode < 500) {
          throw TmdbException('HTTP ${res.statusCode}', status: res.statusCode);
        }
        lastErr = TmdbException('HTTP ${res.statusCode}', status: res.statusCode);
      } on TmdbException {
        rethrow;
      } catch (e) {
        lastErr = e;
      }
    }
    throw TmdbException('request failed: $lastErr');
  }

  Future<Map<String, dynamic>> trendingAll(int page) =>
      _get('/trending/all/week', {'page': '$page', 'region': 'CN'});

  /// Multi search (movie + tv + person). Caller drops `person` rows.
  Future<Map<String, dynamic>> searchMulti(String query, int page) =>
      _get('/search/multi', {'query': query, 'page': '$page'});

  Future<Map<String, dynamic>> discoverMovie(
    int page, {
    String? genres,
    String? originCountry,
    String sortBy = 'popularity.desc',
    Map<String, String>? extra,
  }) =>
      _get(
        '/discover/movie',
        {
          'page': '$page',
          'region': 'CN',
          'sort_by': sortBy,
          if (genres != null) 'with_genres': genres,
          if (originCountry != null) 'with_origin_country': originCountry,
          ...?extra,
        },
      );

  Future<Map<String, dynamic>> discoverTv(
    int page, {
    String? genres,
    String? originCountry,
    String sortBy = 'popularity.desc',
    Map<String, String>? extra,
  }) =>
      _get('/discover/tv', {
        'page': '$page',
        'sort_by': sortBy,
        if (genres != null) 'with_genres': genres,
        if (originCountry != null) 'with_origin_country': originCountry,
        ...?extra,
      });

  /// movie + tv genre id -> Chinese name, fetched once and memoised.
  Map<int, String>? _genreCache;
  Future<Map<int, String>> genreMap() async {
    if (_genreCache != null) return _genreCache!;
    final out = <int, String>{};
    for (final kind in ['movie', 'tv']) {
      try {
        final json = await _get('/genre/$kind/list');
        for (final g in (json['genres'] as List? ?? const [])) {
          out[g['id'] as int] = g['name'] as String;
        }
      } catch (_) {
        // Non-fatal: genre names just fall back to a generic label.
      }
    }
    return _genreCache = out;
  }

  void close() => _client.close();
}
