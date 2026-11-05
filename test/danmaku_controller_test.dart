import 'package:flutter_test/flutter_test.dart';

import 'package:bear_tv/core/danmaku_controller.dart';
import 'package:bear_tv/data/danmaku/danmaku_client.dart';
import 'package:bear_tv/data/danmaku/danmaku_models.dart';

const _host = DanmakuHost(baseUrl: 'http://dm.test', token: 't');

/// Records the requested file names / episode ids and lets each test script
/// success, an empty answer, or a transport failure.
class _FakeClient extends DanmakuClient {
  _FakeClient();

  final List<String> matchCalls = [];
  final List<int> commentCalls = [];

  DanmakuRequestException? matchError;
  DanmakuRequestException? commentError;
  bool matchedExactly = true;
  List<DanmakuMatch> matches = const [DanmakuMatch(episodeId: 7)];
  List<DanmakuItem> comments = const [DanmakuItem(time: 1, text: 'hi')];

  @override
  Future<DanmakuMatchResult> match(DanmakuHost host, String fileName) async {
    matchCalls.add(fileName);
    if (matchError != null) throw matchError!;
    return DanmakuMatchResult(exact: matchedExactly, matches: matches);
  }

  @override
  Future<List<DanmakuItem>> fetchComments(
      DanmakuHost host, int episodeId) async {
    commentCalls.add(episodeId);
    if (commentError != null) throw commentError!;
    return comments;
  }
}

/// Answers "no match" to the first query and an exact match to the second.
class _ScriptedClient extends _FakeClient {
  @override
  Future<DanmakuMatchResult> match(DanmakuHost host, String fileName) async {
    matchCalls.add(fileName);
    if (matchCalls.length == 1) return DanmakuMatchResult.empty;
    return const DanmakuMatchResult(
      exact: true,
      matches: [DanmakuMatch(episodeId: 7)],
    );
  }
}

DanmakuController _controller(_FakeClient client) =>
    DanmakuController(client: client, host: _host);

void main() {
  test('a transport failure is reported and never cached as "no danmaku"',
      () async {
    final client = _FakeClient()
      ..matchError = DanmakuRequestException('匹配弹幕超时（10 秒）', transient: true);
    final c = _controller(client);

    await c.autoLoad('三体', 0);

    expect(c.loading, isFalse);
    expect(c.items, isEmpty);
    expect(c.statusText, contains('匹配弹幕失败'));
    expect(c.statusText, contains('超时'));

    // Next attempt must hit the network again (the failure was not cached).
    client.matchError = null;
    await c.autoLoad('三体', 0);

    expect(client.matchCalls.length, greaterThan(1));
    expect(c.items, hasLength(1));
    expect(c.statusText, contains('已加载 1 条弹幕'));
  });

  test('a comment fetch failure is reported and retried on the next load',
      () async {
    final client = _FakeClient()
      ..commentError = DanmakuRequestException('获取弹幕失败（HTTP 502）',
          statusCode: 502, transient: true);
    final c = _controller(client);

    await c.autoLoad('三体', 0);

    expect(c.items, isEmpty);
    expect(c.statusText, contains('获取弹幕失败'));
    expect(c.statusText, contains('502'));

    client.commentError = null;
    await c.autoLoad('三体', 0);

    expect(client.commentCalls.length, 2);
    expect(c.items, hasLength(1));
  });

  test('a real "no match" answer stays distinguishable from a failure',
      () async {
    final client = _FakeClient()..matches = const [];
    final c = _controller(client);

    await c.autoLoad('不存在的剧', 0);

    expect(c.statusText, '未找到弹幕');
    expect(c.items, isEmpty);
  });

  test('the CMS detail title is tried before the TMDB title', () async {
    final client = _FakeClient()..matchedExactly = false;
    final c = _controller(client);

    await c.autoLoad('Three-Body Problem', 0, detailTitle: '三体');

    expect(client.matchCalls.first, '三体 S01E01');
    // Fuzzy matches still load, but the status says so.
    expect(c.items, hasLength(1));
    expect(c.statusText, contains('模糊匹配'));
  });

  test('falls back through candidate titles until one matches', () async {
    final client = _ScriptedClient();
    final c = _controller(client);

    await c.autoLoad('三体', 0, detailTitle: '三体 第一季');

    expect(client.matchCalls, [
      '三体 第一季 S01E01', // detail title + episode suffix (answered empty)
      '三体 S01E01', // TMDB title + episode suffix
    ]);
    expect(c.items, hasLength(1));
  });

  test('a cached episode does not re-request the network', () async {
    final client = _FakeClient();
    final c = _controller(client);

    await c.autoLoad('三体', 0);
    await c.autoLoad('三体', 0);

    expect(client.matchCalls.length, 1);
    expect(client.commentCalls.length, 1);
    expect(c.items, hasLength(1));
  });
}
