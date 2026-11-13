import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:bear_tv/core/live_probe_controller.dart';
import 'package:bear_tv/data/iptv/iptv_client.dart';
import 'package:bear_tv/data/iptv/iptv_models.dart';
import 'package:bear_tv/data/iptv/iptv_probe.dart';

/// A rolling live playlist. The shape is taken from 东方卫视, whose
/// MEDIA-SEQUENCE advanced 5920911 → 5920924 between two fetches. Deliberately
/// declares no TARGETDURATION, so a probe driven by it uses the caller's
/// sample gap verbatim and controller tests can run with a zero gap.
String _live({required int seq, required String lastSegment, String? pdt}) =>
    '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-MEDIA-SEQUENCE:$seq
${pdt == null ? '' : '#EXT-X-PROGRAM-DATE-TIME:$pdt\n'}#EXTINF:6.000,
seg_a.ts
#EXTINF:6.000,
$lastSegment
''';

/// 浙江卫视 — and, by the same 2025-12-30 stamp, the whole `ali-m-l.cztv.com`
/// family (channel001, channel006, channel21/CCTV13, …). Structurally a perfect
/// live playlist: no ENDLIST, a TARGETDURATION, three real segments. The only
/// thing wrong with it is that the newest segment is dated nine months ago —
/// the origin's encoder stopped there and its CDN has re-served the identical
/// bytes ever since, which is why it plays "the same thing" every time.
String _cztv({String pdt = '2025-12-30T11:12:11+0800', int seq = 359977910}) =>
    '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-MEDIA-SEQUENCE:$seq
#EXT-X-TARGETDURATION:8
#EXT-X-PROGRAM-DATE-TIME:$pdt
#EXTINF:8.00
1080p/0/000090a4669a13c9_4e437e8_1bcb5c.ts
#EXTINF:8.00
1080p/0/000090a4669a13c9_5000344_1f1d08.ts
#EXTINF:8.00
1080p/0/000090a4669a13c9_51f204c_19917c.ts
''';

/// A fixed "now" for every timestamp assertion, so nothing depends on when the
/// suite runs. Corresponds to the moment the real 浙江卫视 manifest was pulled.
final _now = DateTime.parse('2026-10-12T09:51:20Z');

/// A live playlist that omits MEDIA-SEQUENCE (spec-legal when no segments have
/// been dropped) — the fallback signal is the last segment URI.
String _liveNoSeq({required String lastSegment}) => '''
#EXTM3U
#EXT-X-VERSION:3
#EXTINF:6.000,
seg_a.ts
#EXTINF:6.000,
$lastSegment
''';

/// 湖南卫视: a 2.9h Kuaishou video (2096 segments) served as a channel —
/// `MEDIA-SEQUENCE:0` plus ENDLIST plus a 3-day cache header.
const _vod = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:5
#EXT-X-MEDIA-SEQUENCE:0
#EXT-X-PLAYLIST-TYPE:VOD
#EXTINF:5.000,
5199687338554291078_0.ts
#EXTINF:5.000,
5199687338554291078_2095.ts
#EXT-X-ENDLIST
''';

/// Poll until the controller settles on [want]. The probe is fire-and-forget by
/// design, so tests wait on the observable outcome rather than on a future.
Future<void> _waitFor(LiveProbeController p, LiveVerdict want) async {
  for (var i = 0; i < 300; i++) {
    if (p.verdict == want) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  fail('verdict never became $want (stuck at ${p.verdict})');
}

void main() {
  group('parseManifestInfo', () {
    test('reads the sequence and the last segment of a live playlist', () {
      final info = parseManifestInfo(_live(seq: 5920911, lastSegment: 'b.ts'));
      expect(info.isPlaylist, isTrue);
      expect(info.isVod, isFalse);
      expect(info.mediaSequence, 5920911);
      expect(info.lastSegment, 'b.ts');
    });

    test('treats #EXT-X-ENDLIST as a finished file', () {
      final info = parseManifestInfo(_vod);
      expect(info.isPlaylist, isTrue);
      expect(info.isVod, isTrue);
      expect(info.mediaSequence, 0);
      // The ENDLIST tag must not be mistaken for a segment URI.
      expect(info.lastSegment, '5199687338554291078_2095.ts');
    });

    test('treats #EXT-X-PLAYLIST-TYPE:VOD as a finished file', () {
      final info = parseManifestInfo('''
#EXTM3U
#EXT-X-PLAYLIST-TYPE:VOD
#EXTINF:5.000,
a.ts
''');
      expect(info.isVod, isTrue);
    });

    test('is case-insensitive on tags', () {
      final info = parseManifestInfo('#extm3u\n#ext-x-endlist\n');
      expect(info.isPlaylist, isTrue);
      expect(info.isVod, isTrue);
    });

    test('rejects a body that is not an HLS playlist at all', () {
      // A plain .mp4 served under a channel URL decodes to garbage here.
      final info = parseManifestInfo('<!doctype html><html>404</html>');
      expect(info.isPlaylist, isFalse);
      expect(info.isVod, isFalse);
    });

    test('returns a safe default for empty input', () {
      final info = parseManifestInfo('');
      expect(info.isPlaylist, isFalse);
      expect(info.isVod, isFalse);
      expect(info.mediaSequence, isNull);
      expect(info.lastSegment, isNull);
    });

    test('ignores blank lines and comments when picking the last segment', () {
      final info = parseManifestInfo('''
#EXTM3U
#EXT-X-MEDIA-SEQUENCE:7

#EXTINF:6.000,
http://cdn/x/7.ts

#EXT-X-ENDLIST
''');
      expect(info.lastSegment, 'http://cdn/x/7.ts');
    });

    test('reads the target duration when declared', () {
      final info = parseManifestInfo(
          '#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6.000,\na.ts\n');
      expect(info.targetDuration, 6);
      expect(parseManifestInfo('#EXTM3U\n').targetDuration, isNull);
    });

    test('reads the program date time the cztv origins emit', () {
      // The `+0800` offset form, which is not `Z` and not `+08:00`.
      final info = parseManifestInfo(_cztv());
      expect(info.programDateTime, DateTime.utc(2025, 12, 30, 3, 12, 11));
    });

    test('leaves the program date time null when the playlist omits it', () {
      // The overwhelmingly common case: 39 of 41 reachable channels sampled
      // from the shipped playlist carry no such tag at all.
      expect(
          parseManifestInfo(_live(seq: 1, lastSegment: 'b.ts')).programDateTime,
          isNull);
      expect(parseManifestInfo(_vod).programDateTime, isNull);
    });

    test('keeps the newest stamp when the playlist dates every segment', () {
      // A DVR window dates each segment; only the last one is the live edge.
      final info = parseManifestInfo('''
#EXTM3U
#EXT-X-PROGRAM-DATE-TIME:2026-10-12T09:00:00Z
#EXTINF:6.000,
a.ts
#EXT-X-PROGRAM-DATE-TIME:2026-10-12T09:45:00Z
#EXTINF:6.000,
b.ts
''');
      expect(info.programDateTime, DateTime.utc(2026, 10, 12, 9, 45));
    });

    test('ignores a stamp it cannot parse', () {
      final info = parseManifestInfo(
          '#EXTM3U\n#EXT-X-PROGRAM-DATE-TIME:not-a-date\na.ts\n');
      expect(info.programDateTime, isNull);
    });

    test('survives a 2000-segment playlist', () {
      // Regression guard for the memory blow-up that killed the first design:
      // one manifest of this size is parsed and dropped, never retained.
      final b = StringBuffer('#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:0\n');
      for (var i = 0; i < 2000; i++) {
        b.write('#EXTINF:5.000,\nseg_$i.ts\n');
      }
      final info = parseManifestInfo(b.toString());
      expect(info.isPlaylist, isTrue);
      expect(info.lastSegment, 'seg_1999.ts');
    });
  });

  group('decideVerdict', () {
    test('unreachable is dead', () {
      expect(decideVerdict(first: null), LiveVerdict.dead);
    });

    test('a non-playlist body is a non-live source', () {
      final info = parseManifestInfo('<html>hi</html>');
      expect(decideVerdict(first: info), LiveVerdict.vod);
    });

    test('ENDLIST is a non-live source', () {
      expect(decideVerdict(first: parseManifestInfo(_vod)), LiveVerdict.vod);
    });

    test('one sample alone never accuses a reachable playlist', () {
      // Pass one must be able to say "live" — otherwise every channel would
      // flash a fault for the length of the sample gap.
      final info = parseManifestInfo(_live(seq: 1, lastSegment: 'b.ts'));
      expect(decideVerdict(first: info), LiveVerdict.live);
    });

    test('an advanced sequence is live', () {
      final a = parseManifestInfo(_live(seq: 5920911, lastSegment: 'a2.ts'));
      final b = parseManifestInfo(_live(seq: 5920924, lastSegment: 'a5.ts'));
      expect(decideVerdict(first: a, second: b), LiveVerdict.live);
    });

    test('a sequence that never moves is frozen (浙江卫视)', () {
      final a = parseManifestInfo(_live(seq: 359977910, lastSegment: 'x.ts'));
      final b = parseManifestInfo(_live(seq: 359977910, lastSegment: 'x.ts'));
      expect(decideVerdict(first: a, second: b), LiveVerdict.frozen);
    });

    test('a moved last segment outvotes a stuck sequence', () {
      // Some origins rotate segment names without bumping MEDIA-SEQUENCE;
      // a change there is proof of life, so this must not read as frozen.
      final a = parseManifestInfo(_live(seq: 5, lastSegment: 'old.ts'));
      final b = parseManifestInfo(_live(seq: 5, lastSegment: 'new.ts'));
      expect(decideVerdict(first: a, second: b), LiveVerdict.live);
    });

    test('falls back to the last segment when MEDIA-SEQUENCE is absent', () {
      final same = parseManifestInfo(_liveNoSeq(lastSegment: 'x.ts'));
      expect(decideVerdict(first: same, second: same), LiveVerdict.frozen);

      final moved = parseManifestInfo(_liveNoSeq(lastSegment: 'y.ts'));
      expect(decideVerdict(first: same, second: moved), LiveVerdict.live);
    });

    test('stays live when there is no signal to compare', () {
      const bare = ManifestInfo(isPlaylist: true, isVod: false);
      expect(decideVerdict(first: bare, second: bare), LiveVerdict.live);
    });

    test('a second sample that failed to arrive keeps the pass-one verdict',
        () {
      final a = parseManifestInfo(_live(seq: 1, lastSegment: 'b.ts'));
      expect(decideVerdict(first: a, second: null), LiveVerdict.live);
    });

    test('a stale program date time is frozen on the very first sample', () {
      // The regression this exists for: 浙江卫视 and CCTV13 play "the same
      // thing" forever, but the two-sample check needs a 20s dwell that channel
      // surfing never provides. The timestamp needs no dwell at all.
      final info = parseManifestInfo(_cztv());
      expect(decideVerdict(first: info, now: _now), LiveVerdict.frozen);
    });

    test('a fresh program date time is live on the first sample', () {
      // Same playlist shape, a stamp six minutes old — within the live edge of
      // a slow origin, so this must not be accused.
      final info = parseManifestInfo(_cztv(pdt: '2026-10-12T17:45:00+0800'));
      expect(decideVerdict(first: info, now: _now), LiveVerdict.live);
    });

    test('a rolling sequence outvotes a stale program date time', () {
      // An origin with a drifted clock is still live. Pass two exists so this
      // correction can happen; the badge is wrong for one sample gap, not
      // forever.
      final a = parseManifestInfo(_cztv(pdt: '2020-01-01T00:00:00Z', seq: 10));
      final b = parseManifestInfo(_cztv(pdt: '2020-01-01T00:00:00Z', seq: 11));
      expect(decideVerdict(first: a, second: b, now: _now), LiveVerdict.live);
    });

    test('a stale stamp stands when the second sample agrees', () {
      final a = parseManifestInfo(_cztv());
      final b = parseManifestInfo(_cztv());
      expect(decideVerdict(first: a, second: b, now: _now), LiveVerdict.frozen);
    });

    test('a stale stamp stands when the second sample never arrived', () {
      final a = parseManifestInfo(_cztv());
      expect(
          decideVerdict(first: a, second: null, now: _now), LiveVerdict.frozen);
    });

    test('a stamp in the future is not staleness', () {
      final info = parseManifestInfo(_cztv(pdt: '2027-01-01T00:00:00Z'));
      expect(decideVerdict(first: info, now: _now), LiveVerdict.live);
    });
  });

  group('programDateTimeAge', () {
    test('is null when the playlist carries no stamp', () {
      final info = parseManifestInfo(_live(seq: 1, lastSegment: 'b.ts'));
      expect(programDateTimeAge(info, _now), isNull);
      expect(staleProgramDateTime(info, _now), isFalse);
    });

    test('measures how far behind wall clock the newest segment is', () {
      final info = parseManifestInfo(_cztv());
      expect(programDateTimeAge(info, _now),
          const Duration(hours: 6870, minutes: 39, seconds: 9));
    });

    test('clamps a stamp from the future to zero', () {
      final info = parseManifestInfo(_cztv(pdt: '2027-01-01T00:00:00Z'));
      expect(programDateTimeAge(info, _now), Duration.zero);
    });

    test('tolerates an hour of slack but not much more', () {
      // Real live edges here are seconds old; the slack only exists so a
      // drifted origin clock can't invent a fault. _now is 09:51:20Z, so the
      // threshold sits at 08:51:20Z == 16:51:20+0800.
      ManifestInfo at(String pdt) => parseManifestInfo(_cztv(pdt: pdt));
      expect(
          staleProgramDateTime(at('2026-10-12T17:45:00+0800'), _now), isFalse);
      expect(
          staleProgramDateTime(at('2026-10-12T16:51:20+0800'), _now), isFalse);
      expect(
          staleProgramDateTime(at('2026-10-12T16:51:19+0800'), _now), isTrue);
      expect(
          staleProgramDateTime(at('2026-10-11T17:45:00+0800'), _now), isTrue);
    });
  });

  group('frozenSampleGap', () {
    const fallback = Duration(seconds: 20);

    ManifestInfo withTarget(int? t) =>
        ManifestInfo(isPlaylist: true, isVod: false, targetDuration: t);

    test('keeps the fallback for a fast-rolling playlist', () {
      expect(frozenSampleGap(withTarget(4), fallback), fallback);
      expect(frozenSampleGap(withTarget(6), fallback), fallback);
    });

    test('waits twice the target duration for a slow playlist', () {
      // 12s segments: 20s is not provably enough for the sequence to move, so
      // the wait stretches rather than risk calling a live channel frozen.
      expect(frozenSampleGap(withTarget(12), fallback),
          const Duration(seconds: 24));
    });

    test('falls back when no target is declared', () {
      expect(frozenSampleGap(withTarget(null), fallback), fallback);
      expect(frozenSampleGap(withTarget(0), fallback), fallback);
    });

    test('is capped so a bogus target cannot stall the probe', () {
      expect(frozenSampleGap(withTarget(9999), fallback), maxFrozenSampleGap);
    });
  });

  group('LiveVerdict', () {
    test('only the three source faults are flagged faulty', () {
      expect(LiveVerdict.dead.faulty, isTrue);
      expect(LiveVerdict.vod.faulty, isTrue);
      expect(LiveVerdict.frozen.faulty, isTrue);
      expect(LiveVerdict.live.faulty, isFalse);
      expect(LiveVerdict.checking.faulty, isFalse);
    });

    test('every verdict has a non-empty label and reason', () {
      for (final v in LiveVerdict.values) {
        expect(v.label, isNotEmpty);
        expect(v.reason, isNotEmpty);
      }
      expect(LiveVerdict.live.label, 'LIVE');
    });
  });

  group('readCapped', () {
    test('stops pulling as soon as the cap is reached', () async {
      var chunks = 0;
      Stream<List<int>> endless() async* {
        final chunk = List<int>.filled(4096, 0x23);
        while (true) {
          chunks++;
          yield chunk;
        }
      }

      final bytes = await readCapped(endless(), 10 * 1024);
      expect(bytes.length, 10 * 1024);
      expect(chunks, 3, reason: 'cancelled at the cap, not drained');
    });

    test('returns a short stream whole', () async {
      final bytes =
          await readCapped(Stream.value(List<int>.filled(100, 7)), 1024);
      expect(bytes.length, 100);
      expect(bytes.first, 7);
    });

    test('keeps what arrived when the stream fails part-way', () async {
      Stream<List<int>> failing() async* {
        yield List<int>.filled(50, 7);
        throw const SocketExceptionStub();
      }

      final bytes = await readCapped(failing(), 1024);
      expect(bytes.length, 50);
    });

    test('is empty for an empty stream', () async {
      expect(await readCapped(Stream<List<int>>.empty(), 1024), isEmpty);
    });
  });

  group('namesStaticMediaFile', () {
    test('spots the containers the shipped playlist actually carries', () {
      // 20 .mp4 and 2 .flv channels: 4% of the playlist settled from the URL.
      expect(
          namesStaticMediaFile('https://alimov2.a.kwimgs.com/upic/2023/01/13/'
              '21/BMjAyMzAxMTMyMTE4MzRfNDAzMDAxOTlfOTM1MDY4ODIxOTVfMF8z_b_'
              'B86c4430b82ff5a7f4e8132f6ee558536.mp4'),
          isTrue);
      expect(namesStaticMediaFile('http://x/live/stream.flv'), isTrue);
    });

    test('ignores case, query and fragment', () {
      expect(namesStaticMediaFile('http://x/SHOW.MP4'), isTrue);
      expect(namesStaticMediaFile('http://x/show.mp4?token=abc&t=1'), isTrue);
      expect(namesStaticMediaFile('http://x/show.mp4#t=30'), isTrue);
      expect(namesStaticMediaFile('http://x/show.mp4/'), isTrue);
    });

    test('never fires on a manifest url', () {
      expect(namesStaticMediaFile('http://x/a.m3u8'), isFalse);
      expect(namesStaticMediaFile('http://x/a.m3u8?zxinjd'), isFalse);
      expect(namesStaticMediaFile('http://x/a.m3u'), isFalse);
    });

    test('leaves extensionless urls to the fetch', () {
      // These are 78 of the shipped channels, and they *are* m3u8 — the
      // extension is simply absent, so the URL proves nothing.
      expect(namesStaticMediaFile('https://live.metshop.top/huya/29465849'),
          isFalse);
      expect(namesStaticMediaFile('http://1.2.3.4:8080/live'), isFalse);
      expect(namesStaticMediaFile('http://74.91.26.218:82/live/cctv1hd.m3u8'),
          isFalse);
    });

    test('does not mistake a host or port for an extension', () {
      expect(
          namesStaticMediaFile('http://1.2.3.4:9901/tsfile/live/0001_1.m3u8'),
          isFalse);
      expect(namesStaticMediaFile(''), isFalse);
      expect(namesStaticMediaFile('not a url'), isFalse);
    });

    test('leaves .ts alone — it is as much a live stream as a recording', () {
      expect(namesStaticMediaFile('http://x/live.ts'), isFalse);
    });
  });

  group('IptvClient.probeManifest', () {
    test('parses a 2xx manifest', () async {
      final client = IptvClient(
        client: MockClient((_) async =>
            http.Response(_live(seq: 42, lastSegment: 'z.ts'), 200)),
      );
      addTearDown(client.close);
      final info = await client.probeManifest('http://x/a.m3u8');
      expect(info?.mediaSequence, 42);
      expect(info?.lastSegment, 'z.ts');
    });

    test('a non-2xx response is unreachable', () async {
      final client = IptvClient(
        client: MockClient((_) async => http.Response('nope', 500)),
      );
      addTearDown(client.close);
      expect(await client.probeManifest('http://x/a.m3u8'), isNull);
    });

    test('a transport failure is unreachable, not an exception', () async {
      final client = IptvClient(
        client: MockClient((_) async => throw const SocketExceptionStub()),
      );
      addTearDown(client.close);
      expect(await client.probeManifest('http://x/a.m3u8'), isNull);
    });

    test('an empty url short-circuits', () async {
      final client = IptvClient(
        client: MockClient((_) async => fail('must not be called')),
      );
      addTearDown(client.close);
      expect(await client.probeManifest(''), isNull);
    });

    test('a .mp4 url is judged without any request at all', () async {
      // The point of the URL rule: no fetch, so no 500MB download and no OOM —
      // and the verdict is the one the fetch would have reached anyway.
      final client = IptvClient(
        client: MockClient((_) async => fail('must not be called')),
      );
      addTearDown(client.close);

      final info = await client.probeManifest('http://x/2004年春晚.mp4');
      expect(info, isNotNull);
      expect(decideVerdict(first: info), LiveVerdict.vod);
    });

    test('a misconfigured source url is rejected without a request', () async {
      final client = IptvClient(
        client: MockClient((_) async => fail('must not be called')),
      );
      addTearDown(client.close);
      expect(
          await client.fetchChannels(
              const IptvSource(id: 's', name: 'x', url: 'http://x/movie.mp4')),
          isEmpty);
    });

    test('an endless video stream is cut off, not buffered', () async {
      // The OOM that took the app down on a real box: a channel URL that
      // answers with video rather than a playlist, buffered to completion
      // (`Exhausted heap space, trying to allocate 536870944 bytes`). The read
      // must stop at the cap and drop the socket.
      final client = _EndlessStreamClient();
      final iptv =
          IptvClient(client: client, timeout: const Duration(seconds: 10));
      addTearDown(iptv.close);

      final info = await iptv.probeManifest('http://x/live.ts');
      expect(
          client.bytesServed,
          lessThanOrEqualTo(
              maxManifestBytes + _EndlessStreamClient.defaultChunkSize),
          reason: 'cap plus at most the one chunk already in flight');
      // '#' is not '#EXTM3U' — a raw stream served under a channel URL.
      expect(info?.isPlaylist, isFalse);
      expect(decideVerdict(first: info), LiveVerdict.vod);
    });

    test('an endless source is cut off when loading a playlist too', () async {
      final client = _EndlessStreamClient(chunkSize: 256 * 1024);
      final iptv =
          IptvClient(client: client, timeout: const Duration(seconds: 10));
      addTearDown(iptv.close);

      final channels = await iptv.fetchChannels(
          const IptvSource(id: 's', name: 'x', url: 'http://x/stream.ts'));
      expect(channels, isEmpty);
      expect(
          client.bytesServed, lessThanOrEqualTo(maxPlaylistBytes + 256 * 1024));
    });
  });

  group('LiveProbeController', () {
    IptvClient clientFor(
            Future<http.Response> Function(http.Request) handler) =>
        IptvClient(client: MockClient(handler));

    /// A source whose playlist actually rolls between samples — the healthy
    /// case. A static fixture would (correctly) read as frozen.
    IptvClient rollingClient() {
      var seq = 5920911;
      return IptvClient(client: MockClient((_) async {
        seq++;
        return http.Response(_live(seq: seq, lastSegment: 'seg_$seq.ts'), 200);
      }));
    }

    test('a reachable rolling playlist reports live', () async {
      final client = rollingClient();
      addTearDown(client.close);
      final probe =
          LiveProbeController(client: client, sampleGap: Duration.zero);
      addTearDown(probe.dispose);

      expect(probe.verdict, LiveVerdict.checking);
      probe.begin('http://x/a.m3u8');
      await _waitFor(probe, LiveVerdict.live);
      expect(probe.url, 'http://x/a.m3u8');
    });

    test('a dead host reports dead', () async {
      final client = clientFor((_) async => http.Response('gone', 502));
      addTearDown(client.close);
      final probe =
          LiveProbeController(client: client, sampleGap: Duration.zero);
      addTearDown(probe.dispose);

      probe.begin('http://dead/a.m3u8');
      await _waitFor(probe, LiveVerdict.dead);
    });

    test('a VOD file reports non-live after a single sample', () async {
      var calls = 0;
      final client = clientFor((_) async {
        calls++;
        return http.Response(_vod, 200);
      });
      addTearDown(client.close);
      final probe =
          LiveProbeController(client: client, sampleGap: Duration.zero);
      addTearDown(probe.dispose);

      probe.begin('http://x/vod.m3u8');
      await _waitFor(probe, LiveVerdict.vod);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(calls, 1, reason: 'a non-live verdict needs no second sample');
    });

    test('a stuck sequence reports frozen after the gap', () async {
      final client = clientFor((_) async =>
          http.Response(_live(seq: 359977910, lastSegment: 'x.ts'), 200));
      addTearDown(client.close);
      final probe =
          LiveProbeController(client: client, sampleGap: Duration.zero);
      addTearDown(probe.dispose);

      probe.begin('http://x/frozen.m3u8');
      await _waitFor(probe, LiveVerdict.frozen);
    });

    test('a transient second-sample failure keeps the channel live', () async {
      var calls = 0;
      final client = clientFor((_) async {
        calls++;
        if (calls == 2) return http.Response('boom', 503);
        return http.Response(_live(seq: 1, lastSegment: 'b.ts'), 200);
      });
      addTearDown(client.close);
      final probe =
          LiveProbeController(client: client, sampleGap: Duration.zero);
      addTearDown(probe.dispose);

      probe.begin('http://x/flaky.m3u8');
      await _waitFor(probe, LiveVerdict.live);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(probe.verdict, LiveVerdict.live,
          reason: 'one hiccup must not read as 无法连接');
    });

    test('a superseded probe never publishes its verdict', () async {
      var seq = 0;
      final client = clientFor((req) async {
        if (req.url.path.contains('slow')) {
          await Future<void>.delayed(const Duration(milliseconds: 40));
          return http.Response('gone', 500); // would be `dead` if it landed
        }
        seq++;
        return http.Response(_live(seq: seq, lastSegment: 'seg_$seq.ts'), 200);
      });
      addTearDown(client.close);
      final probe =
          LiveProbeController(client: client, sampleGap: Duration.zero);
      addTearDown(probe.dispose);

      probe.begin('http://x/slow.m3u8');
      probe.begin('http://x/fast.m3u8');
      await _waitFor(probe, LiveVerdict.live);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(probe.verdict, LiveVerdict.live);
      expect(probe.url, 'http://x/fast.m3u8');
    });

    test('switching channels resets the badge before the new verdict lands',
        () async {
      var calls = 0;
      final client = clientFor((_) async {
        calls++;
        if (calls == 1) return http.Response('gone', 502); // dead host
        return http.Response(
            _live(seq: calls, lastSegment: 'seg_$calls.ts'), 200);
      });
      addTearDown(client.close);
      final probe =
          LiveProbeController(client: client, sampleGap: Duration.zero);
      addTearDown(probe.dispose);

      probe.begin('http://x/dead.m3u8');
      await _waitFor(probe, LiveVerdict.dead);

      // The old verdict must not linger over the newly picked channel.
      probe.begin('http://x/good.m3u8');
      expect(probe.verdict, LiveVerdict.checking);
      expect(probe.url, 'http://x/good.m3u8');
      await _waitFor(probe, LiveVerdict.live);
    });

    test('notifies on each verdict change, and not for repeats', () async {
      final client = rollingClient();
      addTearDown(client.close);
      final probe =
          LiveProbeController(client: client, sampleGap: Duration.zero);
      addTearDown(probe.dispose);

      var notifications = 0;
      probe.addListener(() => notifications++);
      probe.begin('http://x/a.m3u8');
      await _waitFor(probe, LiveVerdict.live);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // checking → live, then the second sample confirms live (no re-notify).
      expect(notifications, 1);
    });

    test('a stale-timestamp channel is caught without waiting out the gap',
        () async {
      // The user's report: 浙江卫视 and CCTV13 obviously aren't live, but the
      // two-sample check never fired. It needs an undisturbed dwell, and the
      // picker restarts the probe every time focus moves or OK is pressed, so
      // that dwell never happens. The verdict must therefore come from the
      // first fetch — a 30s gap here would time the test out if it didn't.
      final client = clientFor((_) async => http.Response(_cztv(), 200));
      addTearDown(client.close);
      final probe = LiveProbeController(
          client: client, sampleGap: const Duration(seconds: 30));
      addTearDown(probe.dispose);

      probe.begin(
          'http://ali-m-l.cztv.com/channels/lantian/channel001/1080p.m3u8');
      await _waitFor(probe, LiveVerdict.frozen);
    });

    test('a repeat begin for the same channel does not restart the probe',
        () async {
      var calls = 0;
      final client = clientFor((_) async {
        calls++;
        return http.Response(
            _live(seq: calls, lastSegment: 'seg_$calls.ts'), 200);
      });
      addTearDown(client.close);
      final probe =
          LiveProbeController(client: client, sampleGap: Duration.zero);
      addTearDown(probe.dispose);

      // Exactly what the picker does: preview the row on focus, then open the
      // same channel on OK. Restarting there would reset the sample clock.
      probe.begin('http://x/a.m3u8');
      probe.begin('http://x/a.m3u8');
      await _waitFor(probe, LiveVerdict.live);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(calls, 2, reason: 'two samples of one probe, not two probes');
    });

    test('re-picking a channel after its probe settled checks it again',
        () async {
      var calls = 0;
      final client = clientFor((_) async {
        calls++;
        return http.Response(
            _live(seq: calls, lastSegment: 'seg_$calls.ts'), 200);
      });
      addTearDown(client.close);
      final probe =
          LiveProbeController(client: client, sampleGap: Duration.zero);
      addTearDown(probe.dispose);

      probe.begin('http://x/a.m3u8');
      await _waitFor(probe, LiveVerdict.live);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(calls, 2);

      // Only an *in-flight* probe is deduplicated — the badge has to be able to
      // re-check a channel the viewer comes back to.
      probe.begin('http://x/a.m3u8');
      expect(probe.verdict, LiveVerdict.checking);
      await _waitFor(probe, LiveVerdict.live);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(calls, 4);
    });
  });
}

/// A stand-in for a transport-level failure (`SocketException` lives in
/// `dart:io`, which the widget-test VM does expose, but a local type keeps this
/// test independent of the platform libraries).
class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
}

/// A server that answers with an endless video stream, like the
/// `live.metshop.top` channels in the shipped playlist do. `Client.get` buffers
/// a response like this to completion — the OOM this guards against.
class _EndlessStreamClient extends http.BaseClient {
  _EndlessStreamClient({this.chunkSize = defaultChunkSize});

  static const int defaultChunkSize = 64 * 1024;

  /// Give up once this much has been pushed. The fixed client hangs up at the
  /// cap and never gets near it; a client that drains the stream instead would
  /// otherwise hang the suite (or the box) rather than failing it, so this
  /// turns a regression into a plain assertion failure.
  static const int panicAfter = 64 * 1024 * 1024;

  final int chunkSize;

  /// Bytes the server actually got to push, which is what proves the client
  /// hung up rather than draining it.
  int bytesServed = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    Stream<List<int>> body() async* {
      final chunk = List<int>.filled(chunkSize, 0x23); // '#' — not an m3u8
      while (true) {
        if (bytesServed >= panicAfter) {
          throw StateError(
              'client drained $bytesServed bytes — the read is unbounded');
        }
        bytesServed += chunk.length;
        yield chunk;
      }
    }

    return http.StreamedResponse(body(), 200);
  }
}
