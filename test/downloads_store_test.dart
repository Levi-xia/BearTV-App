import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:bear_tv/data/downloads/download_models.dart';
import 'package:bear_tv/data/downloads/downloads_store.dart';
import 'package:bear_tv/data/models.dart';
import 'package:bear_tv/data/vod/cms_models.dart';

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

const _detail = VodDetail(
  sourceId: 'a',
  sourceName: '源A',
  vodId: '1',
  title: '测试剧',
  playLines: [
    PlayLine(name: '线路1', episodes: [
      Episode(title: '第1集', url: 'https://cdn.test/1.m3u8'),
      Episode(title: '第2集', url: 'https://cdn.test/2.m3u8'),
    ]),
  ],
);

DownloadTask _task(
        {String id = 't1', DownloadStatus status = DownloadStatus.queued}) =>
    DownloadTask(
      id: id,
      itemKey: _item.key,
      item: _item,
      sourceId: 'a',
      sourceName: '源A',
      vodId: '1',
      lineName: '线路1',
      lineIndex: 0,
      episodeIndex: 0,
      episodeTitle: '第1集',
      episodeUrl: 'https://cdn.test/1.m3u8',
      status: status,
      doneSegments: 2,
      totalSegments: 10,
      receivedBytes: 2048,
      isHls: true,
      createdAt: 1,
      updatedAt: 2,
    );

void main() {
  test('tasks and snapshots round-trip through a new store instance', () async {
    final persistence = MemoryDownloadPersistence();
    final store = DownloadsStore(persistence: persistence);
    await store.init();
    await store.saveTask(_task(status: DownloadStatus.completed));
    await store.saveSnapshot(_detail);

    final reopened = DownloadsStore(persistence: persistence);
    await reopened.init();

    final task = reopened.tasks.single;
    expect(task.id, 't1');
    expect(task.status, DownloadStatus.completed);
    expect(task.episodeTitle, '第1集');
    expect(task.totalSegments, 10);
    expect(task.isHls, isTrue);
    expect(task.item.title, '测试剧');

    final snap = reopened.snapshot('a:1');
    expect(snap, isNotNull);
    expect(snap!.playLines.single.episodes.length, 2);
    expect(snap.title, '测试剧');
  });

  test('saving the same task id replaces the record', () async {
    final store = DownloadsStore(persistence: MemoryDownloadPersistence());
    await store.init();
    await store.saveTask(_task());
    await store.saveTask(
        _task(status: DownloadStatus.downloading).copyWith(doneSegments: 5));

    expect(store.tasks.single.status, DownloadStatus.downloading);
    expect(store.tasks.single.doneSegments, 5);
  });

  test('deleting a task/snapshot removes it from memory and disk', () async {
    final persistence = MemoryDownloadPersistence();
    final store = DownloadsStore(persistence: persistence);
    await store.init();
    await store.saveTask(_task());
    await store.saveSnapshot(_detail);

    await store.deleteTask('t1');
    await store.deleteSnapshot('a:1');

    expect(store.tasks, isEmpty);
    expect(store.snapshot('a:1'), isNull);

    final reopened = DownloadsStore(persistence: persistence);
    await reopened.init();
    expect(reopened.tasks, isEmpty);
    expect(reopened.snapshot('a:1'), isNull);
  });

  test('corrupt records are skipped without losing valid ones', () async {
    final persistence = MemoryDownloadPersistence({
      'task:t1': jsonEncode(_task().toJson()),
      'task:bad': '{not json',
      'group:a:1': jsonEncode(_detail.toJson()),
      'group:bad': '[]',
      'unrelated': 'x',
    });
    final store = DownloadsStore(persistence: persistence);
    await store.init();

    expect(store.tasks.single.id, 't1');
    expect(store.snapshot('a:1'), isNotNull);
  });

  test('unknown status strings decode as paused (retryable), not completed',
      () async {
    final raw = _task().toJson()..['status'] = 'weird';
    final persistence = MemoryDownloadPersistence({'task:t1': jsonEncode(raw)});
    final store = DownloadsStore(persistence: persistence);
    await store.init();

    expect(store.tasks.single.status, DownloadStatus.paused);
  });
}
