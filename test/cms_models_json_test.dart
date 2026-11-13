import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:bear_tv/data/vod/cms_models.dart';

const _detail = VodDetail(
  sourceId: 'a',
  sourceName: '源A',
  vodId: '7',
  title: '测试剧',
  cover: 'https://img/cover.jpg',
  desc: '简介',
  remarks: '更新至2集',
  playLines: [
    PlayLine(name: '线路1', episodes: [
      Episode(title: '第1集', url: 'https://cdn.test/1.m3u8?token=x'),
      Episode(title: '第2集', url: 'https://cdn.test/2.m3u8'),
    ]),
    PlayLine(name: '线路2', episodes: []),
  ],
);

void main() {
  test('VodDetail round-trips through JSON', () {
    final decoded = VodDetail.fromJson(
        jsonDecode(jsonEncode(_detail.toJson())) as Map<String, dynamic>);

    expect(decoded.sourceId, 'a');
    expect(decoded.sourceName, '源A');
    expect(decoded.vodId, '7');
    expect(decoded.title, '测试剧');
    expect(decoded.cover, 'https://img/cover.jpg');
    expect(decoded.desc, '简介');
    expect(decoded.remarks, '更新至2集');
    expect(decoded.playLines.length, 2);
    expect(decoded.playLines[0].name, '线路1');
    expect(decoded.playLines[0].episodes[0].title, '第1集');
    expect(decoded.playLines[0].episodes[0].url,
        'https://cdn.test/1.m3u8?token=x');
    expect(decoded.playLines[1].episodes, isEmpty);
    expect(decoded.key, _detail.key);
  });

  test('missing fields decode to safe defaults', () {
    final d = VodDetail.fromJson({'sourceId': 'a', 'vodId': '1'});
    expect(d.sourceName, '');
    expect(d.title, '');
    expect(d.playLines, isEmpty);
    expect(d.firstEpisode, isNull);
  });

  test('malformed line/episode rows are skipped, not fatal', () {
    final d = VodDetail.fromJson({
      'sourceId': 'a',
      'vodId': '1',
      'playLines': [
        'garbage',
        {
          'name': '线路1',
          'episodes': [
            'nope',
            {'title': '第1集', 'url': 'https://x/1.m3u8'},
          ],
        },
      ],
    });
    expect(d.playLines.length, 1);
    expect(d.playLines.single.episodes.single.url, 'https://x/1.m3u8');
  });
}
