import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:bear_tv/data/downloads/download_models.dart';
import 'package:bear_tv/data/downloads/download_storage.dart';
import 'package:bear_tv/data/models.dart';

const _item = VodItem(
  id: 1,
  mediaType: 'tv',
  title: '测试剧',
  en: '',
  genre: '剧情',
  desc: '',
  year: 2020,
  score: '8.0',
  ep: 20,
  hd: 'HD',
  neu: false,
  bgUrl: '',
  cardUrl: '',
  posterUrl: '',
);

DownloadTask _task({
  String id = 'task1',
  String episodeTitle = '第1集',
  String episodeUrl = 'https://cdn.test/1.m3u8',
  bool isHls = true,
  String relativePath = '',
}) =>
    DownloadTask(
      id: id,
      itemKey: _item.key,
      item: _item,
      sourceId: 'a',
      sourceName: '源A',
      vodId: '1',
      lineName: '线路1',
      episodeIndex: 0,
      episodeTitle: episodeTitle,
      episodeUrl: episodeUrl,
      isHls: isHls,
      relativePath: relativePath,
    );

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('bear_dl_storage_');
  });
  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  test('init creates the downloads root under the given directory', () async {
    final s = DownloadStorage(root: temp);
    await s.init();

    expect(s.available, isTrue);
    expect(Directory('${temp.path}/downloads').existsSync(), isTrue);
  });

  test('task directories are hashed and contained under the root', () async {
    final s = DownloadStorage(root: temp);
    await s.init();
    final t = _task();

    final dir = await s.ensureTaskDir(t);
    expect(dir, isNotNull);
    expect(dir!.path, contains('/downloads/'));
    expect(dir.path, contains(t.id));
    expect(dir.path, isNot(contains('a:1'))); // group key is hashed
  });

  test('completed HLS task exposes a file:// entry URL', () async {
    final s = DownloadStorage(root: temp);
    await s.init();
    final t = _task();

    final dir = await s.ensureTaskDir(t);
    await File('${dir!.path}/index.m3u8').writeAsString('#EXTM3U\n');

    expect(s.entryNameFor(t), 'index.m3u8');
    expect(s.isComplete(t), isTrue);
    expect(s.localUrl(t), startsWith('file://'));
    expect(s.localUrl(t), endsWith('index.m3u8'));
  });

  test('empty or missing entry file is not playable', () async {
    final s = DownloadStorage(root: temp);
    await s.init();
    final t = _task();

    expect(s.isComplete(t), isFalse);
    expect(s.localUrl(t), isNull);

    final dir = await s.ensureTaskDir(t);
    await File('${dir!.path}/index.m3u8').writeAsString('');
    expect(s.isComplete(t), isFalse);
  });

  test('direct downloads use video.mp4 (or their recorded path)', () async {
    final s = DownloadStorage(root: temp);
    await s.init();

    expect(
      s.entryNameFor(_task(isHls: false, episodeUrl: 'https://x/1.mp4')),
      'video.mp4',
    );
    expect(
      s.entryNameFor(_task(
          isHls: false,
          episodeUrl: 'https://x/1.mp4',
          relativePath: 'video.mp4')),
      'video.mp4',
    );
  });

  test('deleteTask and deleteGroup remove their files', () async {
    final s = DownloadStorage(root: temp);
    await s.init();
    final t = _task();
    final dir = await s.ensureTaskDir(t);
    await File('${dir!.path}/index.m3u8').writeAsString('#EXTM3U');

    expect(await s.totalSize(), greaterThan(0));
    await s.deleteTask(t);
    expect(Directory(dir.path).existsSync(), isFalse);
    expect(await s.totalSize(), 0);

    final again = await s.ensureTaskDir(t);
    await File('${again!.path}/index.m3u8').writeAsString('#EXTM3U');
    await s.deleteGroup(t.groupKey);
    expect(await s.totalSize(), 0);
  });

  test('unusable storage degrades to unavailable instead of throwing',
      () async {
    final blocker = File('${temp.path}/not_a_dir')..writeAsStringSync('x');
    final s = DownloadStorage(root: Directory(blocker.path));
    await s.init();

    expect(s.available, isFalse);
    expect(s.groupDir('a:1'), isNull);
    expect(await s.ensureTaskDir(_task()), isNull);
    expect(s.localUrl(_task()), isNull);
    expect(await s.totalSize(), 0);
  });

  test('resume-side files (source playlist, manifest, segments) survive',
      () async {
    final s = DownloadStorage(root: temp);
    await s.init();
    final t = _task();
    final dir = await s.ensureTaskDir(t);
    await File('${dir!.path}/source.m3u8').writeAsString('#EXTM3U');
    await File('${dir.path}/manifest.json').writeAsString(jsonEncode({
      'segments': ['a.ts']
    }));
    await File('${dir.path}/seg_00001.ts').writeAsBytes([1, 2, 3]);

    expect(File('${dir.path}/source.m3u8').existsSync(), isTrue);
    expect(await s.totalSize(), greaterThan(3));
  });
}
