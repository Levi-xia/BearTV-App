import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:bear_tv/data/downloads/local_media_server.dart';

void main() {
  late Directory temp;
  late LocalMediaServer server;
  late List<int> segment;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('bear_srv_');
    Directory('${temp.path}/group/task').createSync(recursive: true);
    File('${temp.path}/group/task/index.m3u8').writeAsStringSync(
        '#EXTM3U\n#EXTINF:6.0,\nseg_00001.ts\n#EXT-X-ENDLIST\n');
    segment = List<int>.generate(1024, (i) => i % 256);
    File('${temp.path}/group/task/seg_00001.ts').writeAsBytesSync(segment);
    final started = await LocalMediaServer.start(temp);
    expect(started, isNotNull, reason: 'the loopback socket should bind');
    server = started!;
  });

  tearDown(() async {
    await server.close();
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  String urlOf(String relative) {
    final url = server.urlForFile(File('${temp.path}/$relative'));
    expect(url, isNotNull);
    return url!;
  }

  test('serves the playlist with an HLS content type', () async {
    final url = urlOf('group/task/index.m3u8');
    expect(url, startsWith('http://127.0.0.1:${server.port}/'));

    final response = await http.get(Uri.parse(url));

    expect(response.statusCode, 200);
    expect(response.headers['content-type'], contains('mpegurl'));
    expect(response.headers['accept-ranges'], 'bytes');
    expect(utf8.decode(response.bodyBytes), contains('seg_00001.ts'));
    expect(utf8.decode(response.bodyBytes), contains('#EXT-X-ENDLIST'));
  });

  test('a relative segment resolves next to the served playlist', () async {
    final playlistUrl = Uri.parse(urlOf('group/task/index.m3u8'));
    final segmentUrl = playlistUrl.resolve('seg_00001.ts');

    final response = await http.get(segmentUrl);

    expect(response.statusCode, 200);
    expect(response.headers['content-type'], 'video/mp2t');
    expect(response.bodyBytes, segment);
  });

  test('range requests return the requested slice', () async {
    final url = urlOf('group/task/seg_00001.ts');

    final response = await http.get(
      Uri.parse(url),
      headers: {'range': 'bytes=100-199'},
    );

    expect(response.statusCode, 206);
    expect(response.headers['content-range'], 'bytes 100-199/1024');
    expect(response.bodyBytes, segment.sublist(100, 200));
  });

  test('an unsatisfiable range is rejected', () async {
    final url = urlOf('group/task/seg_00001.ts');

    final response =
        await http.get(Uri.parse(url), headers: {'range': 'bytes=9000-'});

    expect(response.statusCode, 416);
    expect(response.headers['content-range'], 'bytes */1024');
  });

  test('a wrong token or a traversal path is not served', () async {
    final good = Uri.parse(urlOf('group/task/index.m3u8'));
    final badToken = good.replace(
        pathSegments: ['not-the-token', 'group', 'task', 'index.m3u8']);
    expect((await http.get(badToken)).statusCode, 404);

    final traversal = Uri.parse(
        'http://127.0.0.1:${server.port}/${good.pathSegments.first}/..%2F..%2Fetc%2Fpasswd');
    expect((await http.get(traversal)).statusCode, 404);
  });

  test('urlForFile only maps files below the downloads root', () async {
    final outside = Directory.systemTemp.createTempSync('bear_outside_');
    addTearDown(() => outside.deleteSync(recursive: true));
    final file = File('${outside.path}/index.m3u8')..writeAsStringSync('x');

    expect(server.urlForFile(file), isNull);

    // A sibling directory that merely shares the root's prefix is not a child.
    final sibling = Directory('${temp.path}2')..createSync();
    addTearDown(() => sibling.deleteSync(recursive: true));
    final siblingFile = File('${sibling.path}/index.m3u8')
      ..writeAsStringSync('x');
    expect(server.urlForFile(siblingFile), isNull);
  });

  test('HEAD reports the length without a body', () async {
    final request =
        http.Request('HEAD', Uri.parse(urlOf('group/task/seg_00001.ts')));
    final response = await http.Client().send(request);

    expect(response.statusCode, 200);
    expect(response.contentLength, 1024);
    expect(await response.stream.toBytes(), isEmpty);
  });
}
