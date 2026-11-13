import 'package:flutter_test/flutter_test.dart';

import 'package:bear_tv/data/downloads/m3u8_parser.dart';

const _base = 'https://cdn.test/path/master.m3u8';

void main() {
  group('master', () {
    const master = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
low/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=4500000,AVERAGE-BANDWIDTH=4000000,RESOLUTION=1920x1080
hi/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=1500000,RESOLUTION=1280x720
mid/index.m3u8
''';

    test('lists variants with resolved URIs', () {
      final m = M3u8Parser.parseMaster(master, Uri.parse(_base));
      expect(m.variants.map((v) => v.bandwidth), [800000, 4500000, 1500000]);
      expect(
          m.variants[1].uri.toString(), 'https://cdn.test/path/hi/index.m3u8');
      expect(m.variants[1].width, 1920);
      expect(m.hasSeparateAudio, isFalse);
    });

    test('chooses the highest bandwidth, resolution as tie-break', () {
      final m = M3u8Parser.parseMaster(master, Uri.parse(_base));
      expect(M3u8Parser.chooseVariant(m.variants)!.uri.toString(),
          endsWith('/hi/index.m3u8'));

      final tie = M3u8Parser.parseMaster('''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=1000,RESOLUTION=1280x720
a.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=1000,RESOLUTION=1920x1080
b.m3u8
''', Uri.parse(_base));
      expect(M3u8Parser.chooseVariant(tie.variants)!.uri.toString(),
          endsWith('/b.m3u8'));
    });

    test('flags a separate audio rendition', () {
      final m = M3u8Parser.parseMaster('''
#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="zh",URI="audio/zh.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=1000,AUDIO="aud"
v.m3u8
''', Uri.parse(_base));
      expect(m.hasSeparateAudio, isTrue);
    });

    test('ignores i-frame streams and other tags between tag and URI', () {
      final m = M3u8Parser.parseMaster('''
#EXTM3U
#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=9000000,URI="iframe.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=1000
#EXT-X-DISCONTINUITY
v.m3u8
''', Uri.parse(_base));
      expect(m.variants.single.uri.toString(), endsWith('/v.m3u8'));
    });
  });

  group('media', () {
    const media = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:6
#EXT-X-MEDIA-SEQUENCE:0
#EXTINF:6.000,
seg1.ts
#EXTINF:5.500,
seg2.ts
#EXT-X-ENDLIST
''';

    test('collects segments, durations and VOD state', () {
      final p = M3u8Parser.parseMedia(media, Uri.parse(_base));
      expect(p.segments.length, 2);
      expect(p.segments.first.uri.toString(), 'https://cdn.test/path/seg1.ts');
      expect(p.segments.first.duration, 6.0);
      expect(p.durationMs, 11500);
      expect(p.finished, isTrue);
    });

    test('a live playlist (no ENDLIST / VOD type) is refused', () {
      expect(
        () => M3u8Parser.parseMedia('''
#EXTM3U
#EXTINF:6,
seg1.ts
''', Uri.parse(_base)),
        throwsA(isA<M3u8Exception>()
            .having((e) => e.message, 'message', contains('直播'))),
      );
    });

    test('PLAYLIST-TYPE:VOD is accepted without ENDLIST', () {
      final p = M3u8Parser.parseMedia('''
#EXTM3U
#EXT-X-PLAYLIST-TYPE:VOD
#EXTINF:6,
seg1.ts
''', Uri.parse(_base));
      expect(p.segments.length, 1);
    });

    test('I-frame-only playlists are refused', () {
      expect(
        () => M3u8Parser.parseMedia(
            '#EXTM3U\n#EXT-X-I-FRAMES-ONLY\n#EXTINF:6,\ns.ts\n#EXT-X-ENDLIST\n',
            Uri.parse(_base)),
        throwsA(isA<M3u8Exception>()),
      );
    });

    test('empty playlists are refused', () {
      expect(
        () => M3u8Parser.parseMedia(
            '#EXTM3U\n#EXT-X-ENDLIST\n', Uri.parse(_base)),
        throwsA(isA<M3u8Exception>()),
      );
    });
  });

  group('encryption', () {
    test('AES-128 key URI is resolved and kept with its IV', () {
      final p = M3u8Parser.parseMedia('''
#EXTM3U
#EXT-X-MEDIA-SEQUENCE:7
#EXT-X-KEY:METHOD=AES-128,URI="../keys/k1.bin",IV=0x1234
#EXTINF:6,
s1.ts
#EXT-X-ENDLIST
''', Uri.parse(_base));
      final key = p.keys.single;
      expect(key.method, 'AES-128');
      expect(key.uri.toString(), 'https://cdn.test/keys/k1.bin');
      expect(key.iv, '0x1234');
      expect(p.segments.single.key, same(key));

      final text = M3u8Parser.rewrite(p,
          keyNames: {key: 'key_0.key'},
          mapNames: const {},
          segmentNames: const ['seg_00001.ts']);
      expect(text, contains('METHOD=AES-128,URI="key_0.key",IV=0x1234'));
      expect(text, contains('#EXT-X-MEDIA-SEQUENCE:7'));
      expect(text, contains('seg_00001.ts'));
    });

    test('data: keys stay inline', () {
      final p = M3u8Parser.parseMedia('''
#EXTM3U
#EXT-X-KEY:METHOD=AES-128,URI="data:text/plain;base64,AAAA"
#EXTINF:6,
s1.ts
#EXT-X-ENDLIST
''', Uri.parse(_base));
      final key = p.keys.single;
      expect(key.needsDownload, isFalse);
      final text = M3u8Parser.rewrite(p,
          keyNames: const {},
          mapNames: const {},
          segmentNames: const ['s1.ts']);
      expect(text, contains('URI="data:text/plain;base64,AAAA"'));
    });

    test('SAMPLE-AES is refused', () {
      expect(
        () => M3u8Parser.parseMedia('''
#EXTM3U
#EXT-X-KEY:METHOD=SAMPLE-AES,URI="k"
#EXTINF:6,
s.ts
#EXT-X-ENDLIST
''', Uri.parse(_base)),
        throwsA(isA<M3u8Exception>()
            .having((e) => e.message, 'message', contains('SAMPLE-AES'))),
      );
    });

    test('METHOD=NONE resets a previous key in the rewrite', () {
      final p = M3u8Parser.parseMedia('''
#EXTM3U
#EXT-X-KEY:METHOD=AES-128,URI="k"
#EXTINF:6,
s1.ts
#EXT-X-KEY:METHOD=NONE
#EXTINF:6,
s2.ts
#EXT-X-ENDLIST
''', Uri.parse(_base));
      final text = M3u8Parser.rewrite(p,
          keyNames: {p.keys.single: 'key_0.key'},
          mapNames: const {},
          segmentNames: const ['s1.ts', 's2.ts']);
      expect(text, contains('#EXT-X-KEY:METHOD=NONE'));
    });
  });

  group('byterange and maps', () {
    test('explicit offsets are parsed and removed from the rewrite', () {
      final p = M3u8Parser.parseMedia('''
#EXTM3U
#EXTINF:6,
#EXT-X-BYTERANGE:1000@0
all.ts
#EXTINF:6,
#EXT-X-BYTERANGE:500@1000
all.ts
#EXT-X-ENDLIST
''', Uri.parse(_base));
      expect(p.segments.length, 2);
      expect(p.segments[0].rangeStart, 0);
      expect(p.segments[0].rangeLength, 1000);
      expect(p.segments[1].rangeStart, 1000);
      expect(p.segments[1].rangeLength, 500);

      final text = M3u8Parser.rewrite(p,
          keyNames: const {},
          mapNames: const {},
          segmentNames: const ['a.ts', 'b.ts']);
      expect(text, isNot(contains('#EXT-X-BYTERANGE')));
    });

    test('implicit offsets follow the previous sub-range of the same URI', () {
      final p = M3u8Parser.parseMedia('''
#EXTM3U
#EXTINF:6,
#EXT-X-BYTERANGE:800@0
all.ts
#EXTINF:6,
#EXT-X-BYTERANGE:200
all.ts
#EXT-X-ENDLIST
''', Uri.parse(_base));
      expect(p.segments[1].rangeStart, 800);
      expect(p.segments[1].rangeLength, 200);
    });

    test('EXT-X-MAP is collected and rewritten to a local file', () {
      final p = M3u8Parser.parseMedia('''
#EXTM3U
#EXT-X-MAP:URI="init.mp4",BYTERANGE="720@0"
#EXTINF:6,
s1.m4s
#EXTINF:6,
s2.m4s
#EXT-X-ENDLIST
''', Uri.parse(_base));
      final map = p.maps.single;
      expect(map.uri.toString(), 'https://cdn.test/path/init.mp4');
      expect(map.rangeStart, 0);
      expect(map.rangeLength, 720);

      final text = M3u8Parser.rewrite(p,
          keyNames: const {},
          mapNames: {map: 'init_0.mp4'},
          segmentNames: const ['s1.m4s', 's2.m4s']);
      expect(text, contains('#EXT-X-MAP:URI="init_0.mp4"'));
      expect(text, isNot(contains('BYTERANGE="720@0"')));
      // The map tag is emitted once for the whole run.
      expect('#EXT-X-MAP'.allMatches(text).length, 1);
    });
  });

  group('attributes', () {
    test('quoted commas and bare values parse correctly', () {
      final attrs = parseAttributes(
          'BANDWIDTH=1000,CODECS="avc1.4d401f,mp4a.40.2",NAME="高清"');
      expect(attrs['BANDWIDTH'], '1000');
      expect(attrs['CODECS'], 'avc1.4d401f,mp4a.40.2');
      expect(attrs['NAME'], '高清');
    });
  });
}
