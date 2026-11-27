import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:bear_tv/data/vod/cms_client.dart';
import 'package:bear_tv/data/vod/cms_models.dart';
import 'package:bear_tv/data/vod/vod_repository.dart';

const _siteA = CmsSite(id: 'a', name: 'A站', api: 'http://a.test/api.php');
const _siteB = CmsSite(id: 'b', name: 'B站', api: 'http://b.test/api.php');

/// Per-site scripted search / detail responses.
class _FakeClient extends CmsClient {
  _FakeClient();

  final Map<String, Future<List<SearchHit>> Function()> searches = {};
  final Map<String, Future<VodDetail?> Function(String)> details = {};

  @override
  Future<List<SearchHit>> searchSource(CmsSite site, String query) =>
      searches[site.id]!();

  @override
  Future<VodDetail?> fetchDetail(CmsSite site, String vodId) =>
      details[site.id]!(vodId);
}

SearchHit _hit(String site, String title, {String vodId = '1'}) => SearchHit(
      sourceId: site,
      sourceName: site,
      vodId: vodId,
      title: title,
    );

VodDetail _detail(String site, {String title = '三体', int eps = 2}) => VodDetail(
      sourceId: site,
      sourceName: site,
      vodId: '1',
      title: title,
      playLines: [
        PlayLine(name: '线路一', episodes: [
          for (var i = 0; i < eps; i++)
            Episode(title: '第${i + 1}集', url: 'http://$site.test/$i.m3u8'),
        ]),
      ],
    );

void main() {
  test('resource stream publishes a fast source before a slow source finishes',
      () async {
    final client = _FakeClient();
    final slow = Completer<List<SearchHit>>();
    client.searches['a'] = () async => [_hit('a', '三体')];
    client.searches['b'] = () => slow.future;
    client.details['a'] = (_) async => _detail('a');
    client.details['b'] = (_) async => _detail('b');
    final repo = VodRepository(client: client);
    addTearDown(repo.close);
    final batches = <List<ResourceOption>>[];
    final first = Completer<void>();
    final done = Completer<void>();
    final subscription =
        repo.watchResourceOptions('三体', [_siteA, _siteB]).listen((batch) {
      batches.add(batch);
      if (!first.isCompleted) first.complete();
    }, onDone: done.complete);
    addTearDown(subscription.cancel);
    await first.future;
    expect(batches.last.map((o) => o.sourceId), ['a']);
    expect(done.isCompleted, isFalse);
    slow.complete([_hit('b', '三体')]);
    await done.future;
    expect(batches.last, hasLength(2));
  });

  test('fallback races two details and stops scheduling after a winner',
      () async {
    final client = _FakeClient();
    final slow = Completer<VodDetail?>();
    final calls = <String>[];
    client.searches['a'] = () async => [
          for (var i = 0; i < 8; i++) _hit('a', '三体 版本$i', vodId: '$i'),
        ];
    client.details['a'] = (id) {
      calls.add(id);
      return id == '0' ? slow.future : Future.value(_detail('a'));
    };
    final repo = VodRepository(client: client);
    final result = await repo.resolveByTitle('三体', [_siteA]);
    expect(result, isNotNull);
    expect(calls, ['0', '1']);
    expect(slow.isCompleted, isFalse);
    slow.complete(null);
    repo.close();
  });

  test('fallback tolerates failures and caps total attempts at six', () async {
    final client = _FakeClient();
    var active = 0, maxActive = 0, calls = 0;
    client.searches['a'] = () async => [
          for (var i = 0; i < 9; i++) _hit('a', '三体 $i', vodId: '$i'),
        ];
    client.details['a'] = (_) async {
      calls++;
      active++;
      if (active > maxActive) maxActive = active;
      await Future<void>.delayed(Duration.zero);
      active--;
      throw StateError('provider failed');
    };
    final repo = VodRepository(client: client);
    expect(await repo.resolveByTitle('三体', [_siteA]), isNull);
    expect(calls, 6);
    expect(maxActive, 2);
    repo.close();
  });

  test('exact match folds width and whitespace without stripping seasons',
      () async {
    final client = _FakeClient();
    final slow = Completer<List<SearchHit>>();
    client.searches['a'] = () async => [_hit('a', ' ＦＯＯ　第２季 ')];
    client.searches['b'] = () => slow.future;
    client.details['a'] = (_) async => _detail('a');
    final repo = VodRepository(client: client);
    expect(await repo.resolveByTitle('foo第2季', [_siteA, _siteB]), isNotNull);
    slow.complete([]);
    repo.close();
  });

  test('returns the first exact hit without waiting for a slow source',
      () async {
    final client = _FakeClient();
    final slow = Completer<List<SearchHit>>();
    client.searches['a'] = () async => [_hit('a', '三体')];
    client.searches['b'] = () => slow.future; // never answers in this test
    client.details['a'] = (_) async => _detail('a');

    final repo = VodRepository(client: client);
    final detail = await repo.resolveByTitle(
        '三体', [_siteA, _siteB]).timeout(const Duration(seconds: 2));

    expect(detail, isNotNull);
    expect(detail!.sourceId, 'a');
    expect(slow.isCompleted, isFalse);
  });

  test('probes a non-exact hit only after every search answered', () async {
    final client = _FakeClient();
    final rest = Completer<List<SearchHit>>();
    var probedEarly = false;
    client.searches['a'] = () async => [_hit('a', '三体 全40集')];
    client.searches['b'] = () => rest.future;
    client.details['a'] = (_) async {
      probedEarly = true;
      return _detail('a');
    };

    final repo = VodRepository(client: client);
    final future = repo.resolveByTitle('三体', [_siteA, _siteB]);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(probedEarly, isFalse, reason: 'fuzzy hits wait for all sources');

    rest.complete(const []);
    final detail = await future.timeout(const Duration(seconds: 2));
    expect(detail, isNotNull);
    expect(detail!.sourceId, 'a');
  });

  test('skips hits whose detail has no playable episode', () async {
    final client = _FakeClient();
    client.searches['a'] = () async => [_hit('a', '三体', vodId: '1')];
    client.details['a'] = (_) async => _detail('a', eps: 0);

    final repo = VodRepository(client: client);
    final detail = await repo.resolveByTitle('三体', [_siteA]);
    expect(detail, isNull);
  });

  test('the switch-resource pass reuses the resolve pass requests', () async {
    final client = _FakeClient();
    var searches = 0;
    var details = 0;
    client.searches['a'] = () async {
      searches++;
      return [_hit('a', '三体')];
    };
    client.details['a'] = (_) async {
      details++;
      return _detail('a');
    };

    final repo = VodRepository(client: client);
    await repo.resolveByTitle('三体', [_siteA]);
    expect(searches, 1);
    expect(details, 1);

    final opts = await repo.loadResourceOptions('三体', [_siteA]);

    expect(opts, hasLength(1));
    expect(opts.single.title, '三体');
    expect(searches, 1, reason: 'the second pass must not search again');
    expect(details, 1, reason: 'the detail was already probed by resolve');
  });

  test('concurrent lookups share one in-flight request', () async {
    final client = _FakeClient();
    var searches = 0;
    client.searches['a'] = () async {
      searches++;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return [_hit('a', '三体')];
    };

    final repo = VodRepository(client: client);
    await Future.wait([
      repo.searchAll('三体', [_siteA]),
      repo.searchAll('三体', [_siteA]),
    ]);

    expect(searches, 1);
  });

  test('the playing resource is listed first without searching its source',
      () async {
    final client = _FakeClient();
    var searches = 0;
    client.searches['a'] = () async {
      searches++;
      return const <SearchHit>[];
    };
    client.searches['b'] = () async {
      searches++;
      return [_hit('b', '三体', vodId: '9')];
    };
    client.details['b'] = (_) async => _detail('b');

    final repo = VodRepository(client: client);
    final opts = await repo.loadResourceOptions(
      '三体',
      [_siteA, _siteB],
      current: _detail('a', title: '三体 (2023)'),
    );

    expect(opts, hasLength(2));
    expect(opts.first.isCurrent, isTrue);
    expect(opts.first.sourceId, 'a');
    expect(opts.first.title, '三体 (2023)');
    expect(searches, 1, reason: 'the current source needs no search');
  });

  test('a failed detail is not memoized, so a retry can succeed', () async {
    final client = _FakeClient();
    var details = 0;
    client.searches['a'] = () async => [_hit('a', '三体')];
    client.details['a'] = (_) async {
      details++;
      return details == 1 ? null : _detail('a');
    };

    final repo = VodRepository(client: client);
    expect(await repo.resolveByTitle('三体', [_siteA]), isNull);
    final again = await repo.detail(_siteA, '1');

    expect(details, 2);
    expect(again, isNotNull);
  });
}
