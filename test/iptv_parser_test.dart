import 'package:flutter_test/flutter_test.dart';
import 'package:bear_tv/data/iptv/iptv_parser.dart';

void main() {
  group('parseM3u', () {
    test('parses a full #EXTINF entry with all attributes', () {
      const m3u = '''
#EXTM3U
#EXTINF:-1 tvg-id="cctv1" tvg-name="CCTV1" tvg-logo="http://logo/cctv1.png" group-title="央视",CCTV-1 综合
http://example.com/cctv1.m3u8
''';
      final channels = parseM3u(m3u, 'src');
      expect(channels, hasLength(1));
      final c = channels.first;
      expect(c.name, 'CCTV-1 综合');
      expect(c.group, '央视');
      expect(c.logo, 'http://logo/cctv1.png');
      expect(c.tvgId, 'cctv1');
      expect(c.url, 'http://example.com/cctv1.m3u8');
      expect(c.sourceId, 'src');
      expect(c.id, startsWith('src_0_'));
    });

    test('falls back to defaults when name/group are missing', () {
      const m3u = '''
#EXTINF:-1,
http://example.com/a.ts
#EXTINF:-1
http://example.com/b.ts
''';
      final channels = parseM3u(m3u, 's');
      expect(channels, hasLength(2));
      expect(channels[0].name, '未命名频道');
      expect(channels[0].group, '未分组');
      expect(channels[1].name, '未命名频道');
      expect(channels[1].group, '未分组');
    });

    test('uses tvg-name when the display name after comma is empty', () {
      const m3u = '#EXTINF:-1 tvg-name="备用名",\nhttp://x/y.m3u8';
      final channels = parseM3u(m3u, 's');
      expect(channels.single.name, '备用名');
    });

    test('groups multiple channels and skips comment/blank lines', () {
      const m3u = '''
#EXTM3U

#EXTINF:-1 group-title="新闻",频道A
http://x/a.m3u8

# a stray comment
#EXTINF:-1 group-title="电影",频道B
http://x/b.m3u8
''';
      final channels = parseM3u(m3u, 's');
      expect(channels.map((c) => c.name).toList(), ['频道A', '频道B']);
      expect(channels.map((c) => c.group).toList(), ['新闻', '电影']);
      expect(channels.map((c) => c.url).toList(),
          ['http://x/a.m3u8', 'http://x/b.m3u8']);
    });

    test('associates the URL on the next non-# line with its #EXTINF', () {
      const m3u =
          '#EXTINF:-1 group-title="G",Name\n#EXTVLCOPT:http-user-agent=x\nhttp://x/z.m3u8';
      final channels = parseM3u(m3u, 's');
      expect(channels.single.url, 'http://x/z.m3u8');
      expect(channels.single.group, 'G');
    });

    test('returns empty for blank input', () {
      expect(parseM3u('', 's'), isEmpty);
      expect(parseM3u('   \n\n', 's'), isEmpty);
    });
  });
}
