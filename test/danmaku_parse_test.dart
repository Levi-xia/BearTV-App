import 'package:flutter_test/flutter_test.dart';
import 'package:bear_tv/data/danmaku/danmaku_client.dart';
import 'package:bear_tv/data/danmaku/danmaku_models.dart';

void main() {
  group('formatDanmakuSearchName', () {
    test('appends a zero-padded S01E marker (1-based)', () {
      expect(formatDanmakuSearchName('三体', 0), '三体 S01E01');
      expect(formatDanmakuSearchName('庆余年', 9), '庆余年 S01E10');
    });

    test('strips brackets, year and existing season/episode noise', () {
      expect(formatDanmakuSearchName('三体【4K】（2023）第01集', 0), '三体 S01E01');
      expect(formatDanmakuSearchName('Foo S02E05', 2), 'Foo S01E03');
      expect(formatDanmakuSearchName('剧名 12集', 0), '剧名 S01E01');
    });

    test('collapses whitespace', () {
      expect(formatDanmakuSearchName('  多   空格  ', 0), '多 空格 S01E01');
    });

    test('drops everything after the episode/bracket marker', () {
      // A trailing subtitle/tag after the marker must not leak into the query.
      expect(formatDanmakuSearchName('灵笼 第01集 抢先版', 0), '灵笼 S01E01');
      expect(formatDanmakuSearchName('剧名【4K修复】导演剪辑', 4), '剧名 S01E05');
    });

    test('keeps season / fullwidth-year noise (BearTV parity, avoids over-strip)',
        () {
      // Earlier over-stripping of 季 / fullwidth（）broke otherwise-valid matches.
      expect(formatDanmakuSearchName('庆余年 第二季', 0), '庆余年 第二季 S01E01');
      expect(formatDanmakuSearchName('三体（2023）', 0), '三体（2023） S01E01');
    });
  });

  group('cleanDanmakuTitle', () {
    test('yields the bare title used for the auto-match fallback', () {
      expect(cleanDanmakuTitle('狂飙 S01E05'), '狂飙');
      expect(cleanDanmakuTitle('三体【4K】第01集'), '三体');
      expect(cleanDanmakuTitle('  庆余年  '), '庆余年');
    });
  });

  group('parseDanmakuXml', () {
    test('maps bilibili mode → internal mode', () {
      const xml = '<i>'
          '<d p="1.0,1,25,16777215,0">scroll</d>'
          '<d p="2.0,4,25,16777215,0">bottom</d>'
          '<d p="3.0,5,25,16777215,0">top</d>'
          '</i>';
      final items = parseDanmakuXml(xml);
      expect(items.map((e) => e.mode).toList(), [0, 2, 1]);
      expect(items.map((e) => e.text).toList(), ['scroll', 'bottom', 'top']);
    });

    test('sorts by time ascending', () {
      const xml = '<i>'
          '<d p="5.0,1,25,16777215,0">b</d>'
          '<d p="1.0,1,25,16777215,0">a</d>'
          '</i>';
      final items = parseDanmakuXml(xml);
      expect(items.map((e) => e.text).toList(), ['a', 'b']);
      expect(items.first.time, 1.0);
    });

    test('converts decimal color to 0xRRGGBB and masks alpha', () {
      const xml = '<i><d p="1.0,1,25,16711680,0">red</d></i>';
      final items = parseDanmakuXml(xml);
      expect(items.single.color, 0xFF0000);
    });

    test('unescapes XML entities and skips empty / malformed rows', () {
      const xml = '<i>'
          '<d p="1.0,1,25,16777215,0">a &lt;b&gt; &amp; c</d>'
          '<d p="2.0,1,25,16777215,0">   </d>'
          '<d p="3.0,1">too few fields</d>'
          '</i>';
      final items = parseDanmakuXml(xml);
      expect(items.length, 1);
      expect(items.single.text, 'a <b> & c');
    });

    test('empty input → empty list', () {
      expect(parseDanmakuXml(''), isEmpty);
    });
  });

  group('parseMatches', () {
    test('keeps entries with a valid episodeId, trims titles', () {
      final out = parseMatches([
        {'episodeId': 12, 'animeTitle': ' A ', 'episodeTitle': ' E1 '},
        {'episodeId': 0, 'animeTitle': 'skip'},
        {'animeTitle': 'no id'},
        {'episodeId': '34', 'animeTitle': 'B'},
      ]);
      expect(out.length, 2);
      expect(out[0].episodeId, 12);
      expect(out[0].animeTitle, 'A');
      expect(out[0].episodeTitle, 'E1');
      expect(out[0].label, 'A · E1');
      expect(out[1].episodeId, 34);
    });
  });

  group('DanmakuHost', () {
    test('builds match / comment URLs', () {
      const h = DanmakuHost(baseUrl: 'https://x.com', token: 'tok');
      expect(h.matchUrl, 'https://x.com/tok/api/v2/match');
      expect(h.commentUrl(9),
          'https://x.com/tok/api/v2/comment/9?format=xml&duration=true');
    });

    test('tolerates a trailing slash', () {
      const h = DanmakuHost(baseUrl: 'https://x.com/', token: 'tok');
      expect(h.matchUrl, 'https://x.com/tok/api/v2/match');
      expect(h.commentUrl(9),
          'https://x.com/tok/api/v2/comment/9?format=xml&duration=true');
    });

    test('label falls back from name to host', () {
      const named =
          DanmakuHost(name: '我的源', baseUrl: 'https://x.com', token: 'tok');
      expect(named.label, '我的源');
      const unnamed = DanmakuHost(baseUrl: 'https://x.com', token: 'tok');
      expect(unnamed.label, 'x.com');
    });

    test('round-trips id / name through json', () {
      const h = DanmakuHost(
          id: 'dm_1', name: '源', baseUrl: 'https://x.com', token: 'tok');
      final back = DanmakuHost.fromJson(h.toJson());
      expect(back.id, 'dm_1');
      expect(back.name, '源');
      expect(back.baseUrl, 'https://x.com');
      expect(back.token, 'tok');
    });
  });

  group('DanmakuConfig', () {
    test('round-trips through json', () {
      const c = DanmakuConfig(
          enabled: false, opacity: 0.7, fontSize: 26, scrollSeconds: 6, area: 1.0);
      final back = DanmakuConfig.fromJson(c.toJson());
      expect(back.enabled, false);
      expect(back.opacity, 0.7);
      expect(back.fontSize, 26);
      expect(back.scrollSeconds, 6);
      expect(back.area, 1.0);
    });
  });
}
