import 'package:flutter_test/flutter_test.dart';
import 'package:bear_tv/data/vod/cms_client.dart';
import 'package:bear_tv/data/vod/cms_models.dart';

void main() {
  group('parsePlayUrl', () {
    test('single line, multiple episodes', () {
      final lines = parsePlayUrl(
        '第01集\$http://a.com/1.m3u8#第02集\$http://a.com/2.m3u8',
        playFrom: 'm3u8',
      );
      expect(lines.length, 1);
      expect(lines.first.name, 'm3u8');
      expect(lines.first.episodes.length, 2);
      expect(lines.first.episodes[0].title, '第01集');
      expect(lines.first.episodes[1].url, 'http://a.com/2.m3u8');
    });

    test('multiple lines split by \$\$\$ with aligned play_from names', () {
      final lines = parsePlayUrl(
        '第01集\$http://a.com/1.m3u8\$\$\$第01集\$http://b.com/1.m3u8#第02集\$http://b.com/2.m3u8',
        playFrom: 'lineA\$\$\$lineB',
      );
      expect(lines.length, 2);
      expect(lines[0].name, 'lineA');
      expect(lines[1].name, 'lineB');
      expect(lines[1].episodes.length, 2);
    });

    test('drops non-http episodes and empty lines', () {
      final lines = parsePlayUrl(
        '第01集\$ftp://bad/1\$\$\$第01集\$http://ok.com/1.m3u8',
      );
      // First line has only a non-http url -> dropped entirely.
      expect(lines.length, 1);
      expect(lines.first.episodes.single.url, 'http://ok.com/1.m3u8');
      // Fallback naming when play_from missing.
      expect(lines.first.name, '线路1');
    });

    test('empty / null input', () {
      expect(parsePlayUrl(null), isEmpty);
      expect(parsePlayUrl(''), isEmpty);
    });

    test('floats the m3u8-named line to the front', () {
      final lines = parsePlayUrl(
        '第01集\$http://a.com/1.m3u8\$\$\$第01集\$http://b.com/1.m3u8',
        playFrom: 'ruyi\$\$\$ruyim3u8',
      );
      expect(lines.length, 2);
      // Named "...m3u8" wins even though both carry .m3u8 URLs.
      expect(lines[0].name, 'ruyim3u8');
      expect(lines[1].name, 'ruyi');
    });

    test('sinks a non-m3u8 line below m3u8 ones', () {
      final lines = parsePlayUrl(
        '第01集\$http://a.com/1.mp4\$\$\$第01集\$http://b.com/1.m3u8',
        playFrom: 'mp4line\$\$\$hls',
      );
      expect(lines[0].name, 'hls'); // .m3u8 URL floats up
      expect(lines[1].name, 'mp4line');
    });

    test('preserves original order when no m3u8 signal differs', () {
      final lines = parsePlayUrl(
        '第01集\$http://a.com/1.m3u8\$\$\$第01集\$http://b.com/1.m3u8',
        playFrom: 'lineA\$\$\$lineB',
      );
      expect(lines[0].name, 'lineA');
      expect(lines[1].name, 'lineB');
    });
  });

  group('mapDetail', () {
    test('maps standard vod fields and play lines', () {
      final detail = mapDetail(
        {
          'vod_id': 42,
          'vod_name': '测试影片',
          'vod_pic': 'http://img/p.jpg',
          'vod_content': '<p>一段<br>简介</p>',
          'vod_remarks': '更新至10集',
          'vod_play_from': 'm3u8',
          'vod_play_url': '第01集\$http://a.com/1.m3u8#第02集\$http://a.com/2.m3u8',
        },
        sourceId: 'dyttzy',
        sourceName: '电影天堂资源',
      );
      expect(detail.vodId, '42');
      expect(detail.title, '测试影片');
      expect(detail.desc, '一段 简介'); // tags stripped
      expect(detail.episodeCount, 2);
      expect(detail.firstEpisode!.url, 'http://a.com/1.m3u8');
      expect(detail.key, 'dyttzy:42');
    });

    test('falls back to m3u8 scan in vod_content when no play_url', () {
      final detail = mapDetail(
        {
          'vod_id': 7,
          'vod_name': 'X',
          'vod_content': 'blah \$http://c.com/v.m3u8 more',
          'vod_play_url': '',
        },
        sourceId: 's',
        sourceName: 'S',
      );
      expect(detail.playLines.single.episodes.single.url, 'http://c.com/v.m3u8');
    });
  });

  group('VodDetail helpers', () {
    test('firstEpisode skips empty-url lines', () {
      const detail = VodDetail(
        sourceId: 's',
        sourceName: 'S',
        vodId: '1',
        title: 'T',
        playLines: [
          PlayLine(name: 'a', episodes: [Episode(title: '', url: '')]),
          PlayLine(name: 'b', episodes: [Episode(title: '1', url: 'http://x/1.m3u8')]),
        ],
      );
      expect(detail.firstEpisode!.url, 'http://x/1.m3u8');
      expect(detail.episodeCount, 2);
    });
  });

  group('episode labels', () {
    test('keeps variety episode names verbatim', () {
      const eps = [
        Episode(title: '第1期：初见', url: 'http://x/1.m3u8'),
        Episode(title: '第2期：重逢', url: 'http://x/2.m3u8'),
      ];
      expect(episodeUnit(eps), '期');
      expect(episodeLabel(eps[0].title, 0, unit: episodeUnit(eps)), '第1期：初见');
    });

    test('normalises bare numbers and empty titles', () {
      expect(episodeLabel('1', 0), '第 1 集');
      expect(episodeLabel('', 3), '第 4 集');
      expect(episodeLabel(null, 0, unit: '期'), '第 1 期');
    });

    test('drama lines keep 集 as the unit', () {
      const eps = [
        Episode(title: '第01集', url: 'http://x/1.m3u8'),
        Episode(title: '第02集', url: 'http://x/2.m3u8'),
      ];
      expect(episodeUnit(eps), '集');
      expect(episodeLabel(eps[0].title, 0), '第01集');
    });
  });
}
