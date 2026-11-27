import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:bear_tv/data/vod/cms_client.dart';
import 'package:bear_tv/data/vod/cms_models.dart';
import 'package:bear_tv/data/vod/vod_repository.dart';

class _AbortingClient extends http.BaseClient {
  final requests = <http.BaseRequest>[];
  int active = 0;
  int peak = 0;
  int aborted = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    active++;
    if (active > peak) peak = active;
    await (request as http.Abortable).abortTrigger;
    active--;
    aborted++;
    throw http.RequestAbortedException(request.url);
  }
}

void main() {
  const site = CmsSite(id: 'a', name: 'A', api: 'https://a.test/api');

  test('API search and detail requests carry default and site-specific headers',
      () async {
    var requests = 0;
    final transport = MockClient((request) async {
      requests++;
      expect(request.headers['user-agent'], 'Site UA');
      expect(request.headers['referer'], 'https://origin.test/');
      expect(request.headers['x-token'], 'token');
      expect(request.headers['accept'], 'application/json');
      return http.Response(
          '{"list":[{"vod_id":"1","vod_name":"test",'
          '"vod_play_url":"ep1\$https://cdn.test/1.m3u8"}]}',
          200);
    });
    final client = CmsClient(client: transport);
    addTearDown(client.close);
    const configured = CmsSite(
        id: 'a',
        name: 'A',
        api: 'https://a.test/api',
        headers: {
          'user-agent': 'Site UA',
          'Referer': 'https://origin.test/',
          'X-Token': 'token'
        });
    await client.searchSource(configured, 'test');
    await client.fetchDetail(configured, '1');
    await client.fetchLatestDetail(configured, '1');
    expect(requests, 3);
  });

  test('HTML detail scraper receives browser UA and configured Referer',
      () async {
    final client = CmsClient(client: MockClient((request) async {
      expect(request.headers['user-agent'], contains('Mozilla/5.0'));
      expect(request.headers['referer'], 'https://origin.test/');
      return http.Response(r'<h1>test</h1>ep1$https://cdn.test/1.m3u8', 200);
    }));
    addTearDown(client.close);
    const configured = CmsSite(
        id: 'a',
        name: 'A',
        api: 'https://a.test/api',
        detail: 'https://a.test',
        headers: {'Referer': 'https://origin.test/'});
    final detail = await client.fetchDetail(configured, '1');
    expect(detail!.firstEpisode, isNotNull);
  });

  test('default API request carries a browser UA for provider compatibility',
      () async {
    final client = CmsClient(client: MockClient((request) async {
      expect(request.headers['user-agent'], contains('Mozilla/5.0'));
      expect(request.headers['accept'], 'application/json');
      return http.Response('{"list":[]}', 200);
    }));
    addTearDown(client.close);
    await client.searchSource(site, 'test');
    await client.fetchDetail(site, '1');
  });

  test('cancelling one resolution aborts its HTTP without affecting another',
      () async {
    final transport = _AbortingClient();
    final repo = VodRepository(client: CmsClient(client: transport));
    addTearDown(repo.close);
    final first = CmsRequestScope();
    final second = CmsRequestScope();
    final one = first.run(() => repo.detail(site, '1'));
    var secondDone = false;
    final two = second.run(() => repo.detail(site, '1'))
      ..then((_) => secondDone = true);
    await Future<void>.delayed(Duration.zero);
    expect(transport.requests.length, 2);
    first.cancel();
    expect(await one, isNull);
    expect(secondDone, isFalse);
    second.cancel();
    expect(await two, isNull);
    final before = transport.requests.length;
    expect(await first.run(() => repo.detail(site, '2')), isNull);
    expect(transport.requests.length, before);
  });

  test('resource workers bound concurrency and abort every timed-out source',
      () async {
    final transport = _AbortingClient();
    final repo = VodRepository(
      client: CmsClient(client: transport),
      resourceConcurrency: 2,
      resourceTimeout: const Duration(milliseconds: 30),
    );
    addTearDown(repo.close);
    final sites = List.generate(
        5, (i) => CmsSite(id: '$i', name: '$i', api: 'https://$i.test/api'));
    final batches = await repo.watchResourceOptions('test', sites).toList();
    await Future<void>.delayed(Duration.zero);
    expect(transport.peak, lessThanOrEqualTo(2));
    expect(transport.requests, hasLength(5));
    expect(transport.aborted, 5);
    expect(batches.last, hasLength(5));
    expect(batches.last.every((option) => option.error == '查询超时'), isTrue);
  });

  test('closing resource list aborts active work without starting queued sites',
      () async {
    final transport = _AbortingClient();
    final repo = VodRepository(
        client: CmsClient(client: transport), resourceConcurrency: 2);
    addTearDown(repo.close);
    final sites = List.generate(
        5, (i) => CmsSite(id: '$i', name: '$i', api: 'https://$i.test/api'));
    final subscription =
        repo.watchResourceOptions('test', sites).listen((_) {});
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(transport.requests, hasLength(2));
    await subscription.cancel();
    await Future<void>.delayed(Duration.zero);
    expect(transport.aborted, 2);
    expect(transport.requests, hasLength(2));
  });

  test('an unscoped in-flight request is not shared with a cancellable scope',
      () async {
    final transport = _AbortingClient();
    final repo = VodRepository(
        client: CmsClient(
            client: transport, timeout: const Duration(milliseconds: 50)));
    addTearDown(repo.close);
    final unscoped = repo.detail(site, '1');
    final scope = CmsRequestScope();
    final scoped = scope.run(() => repo.detail(site, '1'));
    await Future<void>.delayed(Duration.zero);
    expect(transport.requests, hasLength(2));
    scope.cancel();
    expect(await scoped, isNull);
    expect(transport.aborted, 1);
    expect(await unscoped, isNull);
    await Future<void>.delayed(Duration.zero);
    expect(transport.aborted, 2);
  });

  test('completed resolution memo is reused by a later resource stream',
      () async {
    var calls = 0;
    final repo = VodRepository(client: CmsClient(client: MockClient((_) async {
      calls++;
      return http.Response(
          r'{"list":[{"vod_id":"1","vod_name":"test","vod_play_url":"ep1$https://cdn.test/a.m3u8"}]}',
          200);
    })));
    addTearDown(repo.close);
    final scope = CmsRequestScope();
    expect(
        await scope.run(() => repo.resolveByTitle('test', [site])), isNotNull);
    scope.cancel();
    final batches = await repo.watchResourceOptions('test', [site]).toList();
    expect(batches.last.single.available, isTrue);
    expect(calls, 2);
  });

  for (final failure in ['HTTP 503', '超时']) {
    test('resource stream explains inner client failure: $failure', () async {
      final transport = MockClient((_) async {
        if (failure == '超时') throw TimeoutException('inner timeout');
        return http.Response('', 503);
      });
      final repo = VodRepository(client: CmsClient(client: transport));
      addTearDown(repo.close);
      final batches = await repo.watchResourceOptions('test', [site]).toList();
      expect(batches.last.single.error, contains(failure));
      expect(batches.last.single.available, isFalse);
    });
  }

  test('a failed search does not cache an empty result over a successful retry',
      () async {
    var calls = 0;
    final repo = VodRepository(client: CmsClient(client: MockClient((_) async {
      calls++;
      if (calls == 1) return http.Response('', 503);
      return http.Response(
          r'{"list":[{"vod_id":"1","vod_name":"test","vod_play_url":"ep1$https://cdn.test/a.m3u8"}]}',
          200);
    })));
    addTearDown(repo.close);
    expect(await repo.resolveByTitle('test', [site]), isNull);
    expect(await repo.resolveByTitle('test', [site]), isNotNull);
    expect(calls, 3);
  });

  test('request timeout aborts transport and keeps a specific failure reason',
      () async {
    final transport = _AbortingClient();
    final client = CmsClient(
      client: transport,
      timeout: const Duration(milliseconds: 20),
    );
    addTearDown(client.close);
    await expectLater(
      client.fetchLatestDetail(site, '1'),
      throwsA(isA<CatalogueException>()
          .having((e) => e.message, 'reason', contains('超时'))),
    );
    expect(transport.requests, hasLength(1));
  });
}
