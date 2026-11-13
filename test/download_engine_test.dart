import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:bear_tv/data/downloads/download_engine.dart';
import 'package:bear_tv/data/downloads/download_models.dart';
import 'package:bear_tv/data/downloads/download_storage.dart';
import 'package:bear_tv/data/downloads/m3u8_parser.dart';
import 'package:bear_tv/data/models.dart';

const _item = VodItem(
  id: 1,
  mediaType: 'tv',
  title: '测试剧',
  en: '',
  genre: '',
  desc: '',
  year: 2020,
  score: '',
  ep: 2,
  hd: 'HD',
  neu: false,
  bgUrl: '',
  cardUrl: '',
  posterUrl: '',
);

DownloadTask _task(String url) => DownloadTask(
      id: 't1',
      itemKey: _item.key,
      item: _item,
      sourceId: 'a',
      sourceName: '源A',
      vodId: '1',
      episodeTitle: '第1集',
      episodeUrl: url,
    );

const _master = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
low/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=4000000,RESOLUTION=1920x1080
hi/index.m3u8
''';

const _media = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:6
#EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x0102030405060708090a0b0c0d0e0f10
#EXTINF:6.000,
seg1.ts
#EXTINF:5.000,
seg2.ts
#EXT-X-ENDLIST
''';

void main() {
  late Directory temp;
  late DownloadStorage storage;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('bear_engine_');
    storage = DownloadStorage(root: temp);
    await storage.init();
  });
  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  Future<DownloadResult> run(
    DownloadEngine engine,
    DownloadTask task, {
    DownloadCancelToken? cancel,
    void Function(DownloadProgress)? onProgress,
  }) =>
      engine.run(task, storage,
          cancel: cancel ?? DownloadCancelToken(),
          onProgress: onProgress ?? (_) {});

  test('downloads the highest-bandwidth HLS variant with key and segments',
      () async {
    final requested = <String>[];
    final client = MockClient((req) async {
      requested.add(req.url.path);
      expect(req.headers['User-Agent'], contains('BearTV'));
      switch (req.url.path) {
        case '/a.m3u8':
          return http.Response(_master, 200,
              headers: {'content-type': 'application/vnd.apple.mpegurl'});
        case '/hi/index.m3u8':
          return http.Response(_media, 200);
        case '/hi/key.bin':
          return http.Response.bytes([9, 9, 9, 9], 200);
        case '/hi/seg1.ts':
          return http.Response.bytes([1, 1, 1], 200);
        case '/hi/seg2.ts':
          return http.Response.bytes([2, 2], 200);
      }
      return http.Response('not found', 404);
    });
    final engine =
        HttpDownloadEngine(client: client, retryDelay: Duration.zero);
    final task = _task('https://cdn.test/a.m3u8');
    final progress = <DownloadProgress>[];

    final result = await run(engine, task, onProgress: progress.add);

    expect(result.isHls, isTrue);
    expect(result.relativePath, 'index.m3u8');
    expect(result.bandwidth, 4000000);
    expect(result.durationMs, 11000);
    expect(requested, isNot(contains('/low/index.m3u8')));
    expect(requested, contains('/hi/seg1.ts'));

    final dir = storage.taskDir(task)!;
    final index = File('${dir.path}/index.m3u8').readAsStringSync();
    expect(index, contains('seg_00001.ts'));
    expect(index, contains('seg_00002.ts'));
    expect(index, contains('key_0.key'));
    expect(index, contains('#EXT-X-ENDLIST'));
    expect(index, isNot(contains('https://')));
    expect(File('${dir.path}/seg_00001.ts').readAsBytesSync(), [1, 1, 1]);
    expect(File('${dir.path}/key_0.key').readAsBytesSync(), [9, 9, 9, 9]);
    expect(File('${dir.path}/manifest.json').existsSync(), isTrue);

    expect(progress, isNotEmpty);
    expect(progress.last.doneSegments, 2);
    expect(progress.last.totalSegments, 2);
    expect(storage.localUrl(task), startsWith('file://'));
  });

  test('relative URIs resolve against the final URL after a redirect',
      () async {
    final requested = <String>[];
    final client = MockClient((req) async {
      requested.add('${req.url.host}${req.url.path}');
      switch ('${req.url.host}${req.url.path}') {
        case 'cdn.test/a.m3u8':
          return http.Response('', 302,
              headers: {'location': 'https://edge.test/dir/play.m3u8'});
        case 'edge.test/dir/play.m3u8':
          return http.Response('''
#EXTM3U
#EXTINF:6,
seg1.ts
#EXT-X-ENDLIST
''', 200);
        case 'edge.test/dir/seg1.ts':
          return http.Response.bytes([7], 200);
      }
      return http.Response('not found', 404);
    });
    final engine =
        HttpDownloadEngine(client: client, retryDelay: Duration.zero);

    await run(engine, _task('https://cdn.test/a.m3u8'));

    expect(requested, contains('edge.test/dir/seg1.ts'));
  });

  test('refuses a live playlist', () async {
    final client = MockClient((_) async => http.Response('''
#EXTM3U
#EXTINF:6,
seg1.ts
''', 200));
    final engine =
        HttpDownloadEngine(client: client, retryDelay: Duration.zero);

    expect(
      () => run(engine, _task('https://cdn.test/live.m3u8')),
      throwsA(isA<M3u8Exception>()
          .having((e) => e.message, 'message', contains('直播'))),
    );
  });

  test('refuses a separate audio rendition', () async {
    final client = MockClient((_) async => http.Response('''
#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",URI="audio.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=1000,AUDIO="a"
v.m3u8
''', 200));
    final engine =
        HttpDownloadEngine(client: client, retryDelay: Duration.zero);

    expect(
      () => run(engine, _task('https://cdn.test/m.m3u8')),
      throwsA(isA<M3u8Exception>()
          .having((e) => e.message, 'message', contains('音轨'))),
    );
  });

  test('retries a 5xx segment, then succeeds', () async {
    var attempts = 0;
    final client = MockClient((req) async {
      if (req.url.path == '/a.m3u8') {
        return http.Response(
            '#EXTM3U\n#EXTINF:6,\ns1.ts\n#EXT-X-ENDLIST\n', 200);
      }
      if (req.url.path == '/s1.ts') {
        attempts++;
        if (attempts < 2) return http.Response('busy', 503);
        return http.Response.bytes([5], 200);
      }
      return http.Response('nope', 404);
    });
    final engine =
        HttpDownloadEngine(client: client, retryDelay: Duration.zero);

    final result = await run(engine, _task('https://cdn.test/a.m3u8'));

    expect(attempts, 2);
    expect(result.isHls, isTrue);
  });

  test('cancellation stops before the next segment and keeps no index',
      () async {
    final client = MockClient((req) async {
      if (req.url.path == '/a.m3u8') {
        return http.Response(
            '#EXTM3U\n#EXTINF:6,\ns1.ts\n#EXTINF:6,\ns2.ts\n#EXT-X-ENDLIST\n',
            200);
      }
      return http.Response.bytes([1], 200);
    });
    final engine =
        HttpDownloadEngine(client: client, retryDelay: Duration.zero);
    final token = DownloadCancelToken();
    final task = _task('https://cdn.test/a.m3u8');

    await expectLater(
      run(engine, task, cancel: token, onProgress: (p) {
        if (p.doneSegments >= 1) token.cancel();
      }),
      throwsA(isA<DownloadCancelled>()),
    );

    final dir = storage.taskDir(task)!;
    expect(File('${dir.path}/index.m3u8').existsSync(), isFalse);
    expect(File('${dir.path}/seg_00001.ts').existsSync(), isTrue);
  });

  test('a second run reuses unchanged segments (resume)', () async {
    var segmentGets = 0;
    final client = MockClient((req) async {
      switch (req.url.path) {
        case '/a.m3u8':
          return http.Response(
              '#EXTM3U\n#EXTINF:6,\ns1.ts\n#EXTINF:6,\ns2.ts\n#EXT-X-ENDLIST\n',
              200);
        case '/s1.ts':
        case '/s2.ts':
          segmentGets++;
          return http.Response.bytes([1, 2, 3], 200);
      }
      return http.Response('nope', 404);
    });
    final engine =
        HttpDownloadEngine(client: client, retryDelay: Duration.zero);
    final task = _task('https://cdn.test/a.m3u8');

    await run(engine, task);
    expect(segmentGets, 2);

    await run(engine, task);
    expect(segmentGets, 2); // nothing re-downloaded
  });

  test('a changed segment list drops the old fragments', () async {
    var version = 1;
    final client = MockClient((req) async {
      if (req.url.path == '/a.m3u8') {
        final name = version == 1 ? 'old.ts' : 'new.ts';
        return http.Response(
            '#EXTM3U\n#EXTINF:6,\n$name\n#EXT-X-ENDLIST\n', 200);
      }
      return http.Response.bytes([version], 200);
    });
    final engine =
        HttpDownloadEngine(client: client, retryDelay: Duration.zero);
    final task = _task('https://cdn.test/a.m3u8');

    await run(engine, task);
    version = 2;
    await run(engine, task);

    final dir = storage.taskDir(task)!;
    final names = Directory(dir.path)
        .listSync()
        .map((e) => e.uri.pathSegments.last)
        .where((n) => n.startsWith('seg_'))
        .toList();
    expect(names, ['seg_00001.ts']);
    expect(
        Directory(dir.path).listSync().whereType<File>().any((f) =>
            f.uri.pathSegments.last == 'seg_00001.ts' &&
            f.readAsBytesSync().single == 2),
        isTrue);
  });

  test('downloads a direct mp4 into video.mp4', () async {
    final body = [0, 1, 2, 3, 4];
    final client = MockClient((req) async {
      expect(req.url.path, '/v.mp4');
      return http.Response.bytes(body, 200,
          headers: {'content-type': 'video/mp4'});
    });
    final engine =
        HttpDownloadEngine(client: client, retryDelay: Duration.zero);
    final task = _task('https://cdn.test/v.mp4');

    final result = await run(engine, task);

    expect(result.isHls, isFalse);
    expect(result.relativePath, 'video.mp4');
    final dir = storage.taskDir(task)!;
    expect(File('${dir.path}/video.mp4').readAsBytesSync(), body);
    expect(storage.localUrl(task), endsWith('video.mp4'));
  });

  test('resumes a direct download with Range', () async {
    final task = _task('https://cdn.test/v.mp4');
    final dir = await storage.ensureTaskDir(task);
    File('${dir!.path}/video.part').writeAsBytesSync([0, 1, 2, 3]);

    final client = MockClient((req) async {
      if (req.headers['Range'] == 'bytes=4-') {
        return http.Response.bytes([4, 5, 6, 7, 8, 9], 206,
            headers: {
              'content-range': 'bytes 4-9/10',
              'content-type': 'video/mp4',
            });
      }
      return http.Response.bytes([0, 1, 2, 3, 4, 5, 6, 7, 8, 9], 200,
          headers: {'content-type': 'video/mp4'});
    });
    final engine =
        HttpDownloadEngine(client: client, retryDelay: Duration.zero);

    await run(engine, task);

    expect(File('${dir.path}/video.mp4').readAsBytesSync(),
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);
    expect(File('${dir.path}/video.part').existsSync(), isFalse);
  });

  test('a server that ignores Range restarts the file instead of appending',
      () async {
    final task = _task('https://cdn.test/v.mp4');
    final dir = await storage.ensureTaskDir(task);
    File('${dir!.path}/video.part').writeAsBytesSync([9, 9, 9, 9]);

    final client = MockClient((req) async => http.Response.bytes([1, 2, 3], 200,
        headers: {'content-type': 'video/mp4'}));
    final engine =
        HttpDownloadEngine(client: client, retryDelay: Duration.zero);

    await run(engine, task);

    expect(File('${dir.path}/video.mp4').readAsBytesSync(), [1, 2, 3]);
  });

  test('surfaces an HTTP 403 with a readable message', () async {
    final client = MockClient((_) async => http.Response('denied', 403));
    final engine =
        HttpDownloadEngine(client: client, retryDelay: Duration.zero);

    await expectLater(
      run(engine, _task('https://cdn.test/v.mp4')),
      throwsA(isA<DownloadException>()
          .having((e) => e.statusCode, 'statusCode', 403)
          .having((e) => e.message, 'message', contains('403'))),
    );
  });

  test('sniffs a playlist served without an .m3u8 extension', () async {
    final client = MockClient((req) async {
      if (req.url.path == '/stream') {
        return http.Response(
            '#EXTM3U\n#EXTINF:6,\nseg.ts\n#EXT-X-ENDLIST\n', 200,
            headers: {'content-type': 'application/vnd.apple.mpegurl'});
      }
      if (req.url.path == '/seg.ts') {
        return http.Response.bytes([4, 2], 200);
      }
      return http.Response('nope', 404);
    });
    final engine =
        HttpDownloadEngine(client: client, retryDelay: Duration.zero);
    final task = _task('https://cdn.test/stream');

    final result = await run(engine, task);

    expect(result.isHls, isTrue);
    final dir = storage.taskDir(task)!;
    expect(File('${dir.path}/index.m3u8').existsSync(), isTrue);
    expect(
        storage
            .isComplete(task.copyWith(isHls: true, relativePath: 'index.m3u8')),
        isTrue);
  });
}
