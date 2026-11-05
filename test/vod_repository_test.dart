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
  test('returns the first exact hit without waiting for a slow source',
      () async {
    final client = _FakeClient();
    final slow = Completer<List<SearchHit>>();
    client.searches['a'] = () async => [_hit('a', '三体')];
    client.searches['b'] = () => slow.future; // never answers in this test
    client.details['a'] = (_) async => _detail('a');

    final repo = VodRepository(client: client);
    final detail = await repo
        .resolveByTitle('三体', [_siteA, _siteB])
        .timeout(const Duration(seconds: 2));

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
}
