import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:bear_tv/data/config_import.dart';

/// Wrap a secrets-shaped object the way the remote payload does:
/// `[base64(json)]`.
String payload(Map<String, dynamic> secrets) =>
    jsonEncode([base64Encode(utf8.encode(jsonEncode(secrets)))]);

Map<String, dynamic> site(String id, String api, {String? name}) => {
      'id': id,
      'name': name ?? id,
      'api': api,
    };

void main() {
  group('parseConfigImportPayload', () {
    test('decodes the base64 wrapper and all supported sections', () {
      final c = parseConfigImportPayload(payload({
        'TMDB_API_KEY': ' key ',
        'TMDB_PROXY_BASE': 'https://proxy.example',
        'CMS_SITES_JSON': jsonEncode([
          site('s1', 'https://a.example/api'),
          site('s2', 'https://b.example/api'),
        ]),
        'DEFAULT_SELECTED_JSON': jsonEncode(['s2']),
        'DANMAKU_BASE_URL': 'https://dm.example',
        'DANMAKU_TOKEN': 'token',
        'IPTV_PLAYLIST_URL': 'https://tv.example/list.m3u',
        'UNKNOWN_KEY': 'ignored',
      }));

      expect(c.tmdbApiKey, 'key');
      expect(c.tmdbProxyBase, 'https://proxy.example');
      expect(c.cmsSites!.map((s) => s.id), ['s1', 's2']);
      expect(c.selectedSourceIds, ['s2']);
      expect(c.danmakuHosts!.single.baseUrl, 'https://dm.example');
      expect(c.danmakuHosts!.single.name, '默认弹幕源');
      expect(c.danmakuDefaultHostId, 'danmaku_default');
      expect(c.iptvSources!.single.url, 'https://tv.example/list.m3u');
      expect(c.iptvSources!.single.name, '默认直播源');
      expect(c.iptvSelectedSourceId, 'iptv_default_zn');
    });

    test('accepts real JSON arrays as well as stringified ones', () {
      final c = parseConfigImportPayload(payload({
        'CMS_SITES_JSON': [
          site('s1', 'https://a.example/api'),
        ],
        'DEFAULT_SELECTED_JSON': ['s1'],
      }));

      expect(c.cmsSites!.single.id, 's1');
      expect(c.selectedSourceIds, ['s1']);
    });

    test('accepts URL-safe base64 with surrounding whitespace', () {
      final encoded =
          base64Url.encode(utf8.encode(jsonEncode({'TMDB_API_KEY': 'k'})));
      final split = encoded.length ~/ 2;
      final body = jsonEncode([
        '  ${encoded.substring(0, split)}\n'
            '${encoded.substring(split)}  '
      ]);

      expect(parseConfigImportPayload(body).tmdbApiKey, 'k');
    });

    test('rejects a non-array body', () {
      expect(() => parseConfigImportPayload('{"a":1}'),
          throwsA(isA<ConfigImportException>()));
    });

    test('rejects an array with more than one item', () {
      final two = jsonEncode([
        base64Encode(utf8.encode('{}')),
        base64Encode(utf8.encode('{}')),
      ]);
      expect(() => parseConfigImportPayload(two),
          throwsA(isA<ConfigImportException>()));
    });

    test('rejects a non-string array item', () {
      expect(() => parseConfigImportPayload('[{"a":1}]'),
          throwsA(isA<ConfigImportException>()));
    });

    test('rejects invalid base64 and non-JSON decoded content', () {
      expect(() => parseConfigImportPayload('["not!!base64"]'),
          throwsA(isA<ConfigImportException>()));
      final notJson = jsonEncode([base64Encode(utf8.encode('not json'))]);
      expect(() => parseConfigImportPayload(notJson),
          throwsA(isA<ConfigImportException>()));
    });
  });

  group('parseConfigImportSecrets', () {
    test('an explicit empty CMS array clears every source', () {
      final c = parseConfigImportSecrets({'CMS_SITES_JSON': '[]'});
      expect(c.cmsSites, isEmpty);
      expect(c.selectedSourceIds, isEmpty);
    });

    test('a missing selection enables every imported source', () {
      final c = parseConfigImportSecrets({
        'CMS_SITES_JSON': [
          site('s1', 'https://a.example/api'),
          site('s2', 'https://b.example/api'),
        ],
      });
      expect(c.selectedSourceIds, ['s1', 's2']);
    });

    test('stale / unknown selected ids are filtered out', () {
      final c = parseConfigImportSecrets({
        'CMS_SITES_JSON': [
          site('s1', 'https://a.example/api'),
          site('s2', 'https://b.example/api'),
        ],
        'DEFAULT_SELECTED_JSON': ['missing', 's2'],
      });
      expect(c.selectedSourceIds, ['s2']);
    });

    test('a selection made only of stale ids falls back to all', () {
      final c = parseConfigImportSecrets({
        'CMS_SITES_JSON': [site('s1', 'https://a.example/api')],
        'DEFAULT_SELECTED_JSON': ['missing'],
      });
      expect(c.selectedSourceIds, ['s1']);
    });

    test('dedupes by normalized API URL and generates missing ids', () {
      final c = parseConfigImportSecrets({
        'CMS_SITES_JSON': [
          {'id': 'x', 'name': 'X', 'api': 'HTTPS://Example.com/api/'},
          {'name': 'Y', 'api': 'https://other.example/api'},
          {'id': 'dup', 'name': 'Dup', 'api': 'https://example.com/api'},
          {'id': 'bad', 'name': 'Bad', 'api': 'ftp://nope'},
        ],
      });

      expect(c.cmsSites!.map((s) => s.id), ['x', 'cms_2']);
      expect(c.cmsSites![0].api, 'HTTPS://Example.com/api/');
    });

    test('rejects a non-empty CMS array with no usable entry', () {
      expect(
        () => parseConfigImportSecrets({
          'CMS_SITES_JSON': [
            {'id': 'bad', 'api': 'not a url'},
          ],
        }),
        throwsA(isA<ConfigImportException>()),
      );
    });

    test('ignores a selection without a source list', () {
      final c = parseConfigImportSecrets({
        'DEFAULT_SELECTED_JSON': ['s1'],
      });
      expect(c.cmsSites, isNull);
      expect(c.selectedSourceIds, isNull);
    });

    test('danmaku requires both base URL and token', () {
      expect(
        () => parseConfigImportSecrets({'DANMAKU_BASE_URL': 'https://d'}),
        throwsA(isA<ConfigImportException>()),
      );
      expect(
        () => parseConfigImportSecrets({'DANMAKU_TOKEN': 't'}),
        throwsA(isA<ConfigImportException>()),
      );
    });

    test('validates URL-shaped fields', () {
      expect(
        () => parseConfigImportSecrets({'TMDB_PROXY_BASE': 'proxy'}),
        throwsA(isA<ConfigImportException>()),
      );
      expect(
        () => parseConfigImportSecrets({'IPTV_PLAYLIST_URL': 'ftp://x'}),
        throwsA(isA<ConfigImportException>()),
      );
      expect(
        () => parseConfigImportSecrets({
          'DANMAKU_BASE_URL': 'ftp://x',
          'DANMAKU_TOKEN': 't',
        }),
        throwsA(isA<ConfigImportException>()),
      );
    });

    test('an empty / whitespace field is treated as absent', () {
      final c = parseConfigImportSecrets({
        'TMDB_API_KEY': '   ',
        'TMDB_PROXY_BASE': '',
      });
      expect(c.isEmpty, isTrue);
    });
  });
}
