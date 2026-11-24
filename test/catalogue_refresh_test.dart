import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:bear_tv/data/vod/cms_client.dart';
import 'package:bear_tv/data/vod/cms_models.dart';
import 'package:bear_tv/data/vod/vod_repository.dart';

void main() {
  const site = CmsSite(id: 'test', name: '测试源', api: 'https://test/api');

  for (final entry in <String, Future<http.Response> Function()>{
    'HTTP 503': () async => http.Response('', 503),
    '数据格式异常': () async => http.Response('<html>error</html>', 200),
    '超时': () async => throw TimeoutException('timeout'),
    '无法连接': () async => throw http.ClientException('offline'),
  }.entries) {
    test('refresh reports ${entry.key} while ordinary lookup stays best effort',
        () async {
      final client = CmsClient(client: MockClient((_) => entry.value()));
      addTearDown(client.close);
      expect(await client.fetchDetail(site, '1'), isNull);
      await expectLater(
        client.fetchLatestDetail(site, '1'),
        throwsA(isA<CatalogueException>()
            .having((e) => e.message, 'reason', contains(entry.key))),
      );
    });
  }

  test('empty catalogue is distinguishable from transport failure', () async {
    final client = CmsClient(
        client: MockClient((_) async => http.Response('{"list":[]}', 200)));
    addTearDown(client.close);
    expect(await client.fetchLatestDetail(site, '1'), isNull);
  });

  test('latest detail bypasses memo and replaces it with fresh catalogue',
      () async {
    var requests = 0;
    final repo = VodRepository(
      client: CmsClient(client: MockClient((_) async {
        requests++;
        return http.Response.bytes(
          utf8.encode('{"list":[{"vod_id":"1","vod_name":"test",'
              '"vod_play_url":"第$requests集\$https://test/$requests.m3u8"}]}'),
          200,
        );
      })),
    );
    addTearDown(repo.close);
    expect((await repo.detail(site, '1'))!.firstEpisode!.title, '第1集');
    expect((await repo.latestDetail(site, '1'))!.firstEpisode!.title, '第2集');
    expect((await repo.detail(site, '1'))!.firstEpisode!.title, '第2集');
    expect(requests, 2);
  });
}
