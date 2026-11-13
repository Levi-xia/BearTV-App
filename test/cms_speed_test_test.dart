import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:bear_tv/data/vod/cms_models.dart';
import 'package:bear_tv/data/vod/cms_speed_test.dart';

const _site = CmsSite(
  id: 'a',
  name: 'A站',
  api: 'https://a.test/api.php/provide/vod',
);

void main() {
  test('probe URI reuses the apiv3 list call and handles existing query', () {
    expect(cmsProbeUri(_site).queryParameters, {'ac': 'videolist', 'pg': '1'});
    const withQuery =
        CmsSite(id: 'b', name: 'B', api: 'https://b.test/api.php?token=x');
    expect(cmsProbeUri(withQuery).queryParameters,
        {'token': 'x', 'ac': 'videolist', 'pg': '1'});
  });

  test('healthy source reports ok, latency and list size', () async {
    final client = MockClient((req) async {
      expect(req.url.host, 'a.test');
      expect(req.headers['Accept'], 'application/json');
      return http.Response(
          jsonEncode({
            'list': [
              {'vod_id': 1},
              {'vod_id': 2},
            ],
          }),
          200);
    });

    final r = await probeCmsSite(_site, client: client);

    expect(r.status, CmsSpeedStatus.ok);
    expect(r.latency, isNotNull);
    expect(r.itemCount, 2);
    expect(r.finished, isTrue);
  });

  test('empty list is still an available source', () async {
    final client =
        MockClient((_) async => http.Response(jsonEncode({'list': []}), 200));
    final r = await probeCmsSite(_site, client: client);
    expect(r.status, CmsSpeedStatus.ok);
    expect(r.itemCount, 0);
  });

  test('HTTP error is a failure with the status code', () async {
    final client = MockClient((_) async => http.Response('nope', 503));
    final r = await probeCmsSite(_site, client: client);
    expect(r.status, CmsSpeedStatus.failed);
    expect(r.detail, 'HTTP 503');
  });

  test('non-JSON body is bad data', () async {
    final client =
        MockClient((_) async => http.Response('<html>oops</html>', 200));
    final r = await probeCmsSite(_site, client: client);
    expect(r.status, CmsSpeedStatus.badData);
    expect(r.detail, '响应不是 JSON');
  });

  test('JSON in an unexpected shape is bad data', () async {
    final client = MockClient(
        (_) async => http.Response(jsonEncode({'code': 1, 'msg': 'ok'}), 200));
    final r = await probeCmsSite(_site, client: client);
    expect(r.status, CmsSpeedStatus.badData);
    expect(r.detail, '返回格式异常');
  });

  test('an unanswered request times out instead of hanging', () async {
    final client = MockClient((_) async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      return http.Response('{}', 200);
    });
    final r = await probeCmsSite(_site,
        client: client, timeout: const Duration(milliseconds: 30));
    expect(r.status, CmsSpeedStatus.timeout);
  });

  test('connection errors are folded into a failed result', () async {
    final client = MockClient(
        (_) async => throw http.ClientException('connection refused'));
    final r = await probeCmsSite(_site, client: client);
    expect(r.status, CmsSpeedStatus.failed);
    expect(r.detail, '无法连接');
  });

  test('picks the first m3u8 out of the list response', () async {
    final client = MockClient((_) async => http.Response.bytes(
        utf8.encode(jsonEncode({
          'list': [
            {
              'vod_id': 1,
              'vod_play_url':
                  '第1集\$https://cdn.test/a.m3u8#第2集\$https://cdn.test/b.m3u8',
            },
          ],
        })),
        200));

    final r = await probeCmsSite(_site, client: client);
    expect(r.status, CmsSpeedStatus.ok);
    expect(r.m3u8Url, 'https://cdn.test/a.m3u8');
    expect(r.cdn, isNull); // phase two is the tester's job
  });

  test('CDN probe measures the m3u8 and validates its content', () async {
    final client = MockClient(
        (_) async => http.Response('#EXTM3U\n#EXT-X-VERSION:3\n', 200));

    final cdn =
        await probeCdnLatency('https://cdn.test/a.m3u8', client: client);
    expect(cdn.status, CmsSpeedStatus.ok);
    expect(cdn.latency, isNotNull);
  });

  test('CDN probe flags a non-playlist response', () async {
    final client = MockClient((_) async => http.Response('<html>', 200));
    final cdn =
        await probeCdnLatency('https://cdn.test/a.m3u8', client: client);
    expect(cdn.status, CmsSpeedStatus.badData);
    expect(cdn.detail, '不是 m3u8');
  });

  test('CDN probe surfaces refusals instead of hiding them', () async {
    final client = MockClient((_) async => http.Response('denied', 403));
    final cdn =
        await probeCdnLatency('https://cdn.test/a.m3u8', client: client);
    expect(cdn.status, CmsSpeedStatus.failed);
    expect(cdn.detail, 'HTTP 403');
  });

  test('tester follows the list m3u8 to the play CDN', () async {
    final client = MockClient((req) async {
      if (req.url.host == 'cdn.test') {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return http.Response('#EXTM3U\n', 200);
      }
      return http.Response.bytes(
          utf8.encode(jsonEncode({
            'list': [
              {'vod_play_url': '第1集\$https://cdn.test/a.m3u8'},
            ],
          })),
          200);
    });
    final tester = CmsSpeedTester(client: client);
    addTearDown(tester.dispose);

    final done = tester.run(const [_site]);
    expect(tester.running, isTrue);
    await done;

    final r = tester.results.single;
    expect(r.finished, isTrue);
    expect(r.cdn?.status, CmsSpeedStatus.ok);
    expect(tester.running, isFalse);
  });

  test('tester probes every site concurrently and settles', () async {
    final client = MockClient((req) async {
      final host = req.url.host;
      if (host == 'slow.test') {
        return http.Response(jsonEncode({'list': []}), 200);
      }
      return http.Response('down', 500);
    });
    final tester = CmsSpeedTester(client: client);
    addTearDown(tester.dispose);

    const sites = [
      _site,
      CmsSite(id: 'b', name: 'B站', api: 'https://slow.test/api.php'),
      CmsSite(id: 'c', name: 'C站', api: 'https://dead.test/api.php'),
    ];

    final done = tester.run(sites);
    expect(tester.running, isTrue);
    expect(tester.doneCount, 0);
    expect(tester.results.length, 3);

    await done;

    expect(tester.running, isFalse);
    expect(tester.doneCount, 3);
    expect(tester.results.map((r) => r.site.id), ['a', 'b', 'c']);
    expect(tester.results.map((r) => r.status), [
      CmsSpeedStatus.failed,
      CmsSpeedStatus.ok,
      CmsSpeedStatus.failed,
    ]);
    expect(tester.results[1].sortRank, 0);
    expect(tester.results[0].sortRank, 4);
  });

  test('a newer run supersedes an in-flight one', () async {
    final client = MockClient((req) async {
      if (req.url.host == 'old.test') {
        await Future<void>.delayed(const Duration(milliseconds: 80));
      }
      return http.Response(jsonEncode({'list': []}), 200);
    });
    final tester = CmsSpeedTester(client: client);
    addTearDown(tester.dispose);

    final first = tester.run(const [
      CmsSite(id: 'old', name: '旧', api: 'https://old.test/api.php'),
    ]);
    await tester.run(const [
      CmsSite(id: 'new', name: '新', api: 'https://new.test/api.php'),
    ]);
    await first;

    expect(tester.results.map((r) => r.site.id), ['new']);
    expect(tester.running, isFalse);
  });
}
