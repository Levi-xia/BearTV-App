import 'package:flutter_test/flutter_test.dart';

import 'package:bear_tv/data/downloads/episode_identity.dart';
import 'package:bear_tv/data/vod/cms_models.dart';

VodDetail _detail() => const VodDetail(
      sourceId: 'a',
      sourceName: '源A',
      vodId: '1',
      title: '测试剧',
      playLines: [
        PlayLine(name: '线路1', episodes: [
          Episode(title: '第1集', url: 'https://cdn.test/a/1.m3u8?token=1'),
          Episode(title: '第2集', url: 'https://cdn.test/a/2.m3u8?token=1'),
        ]),
        PlayLine(name: '线路2', episodes: [
          Episode(title: '第１集', url: 'https://cdn.other/b/1.m3u8'),
          Episode(title: '第2集', url: 'https://cdn.other/b/2.m3u8'),
        ]),
      ],
    );

void main() {
  test('normalizes titles: full-width digits, whitespace, case', () {
    expect(normalizeEpisodeTitle('  第１集 '), '第1集');
    expect(normalizeEpisodeTitle('EP 01'), 'ep01');
    expect(normalizeEpisodeTitle('第  2   集'), '第2集');
    expect(normalizeEpisodeTitle(''), '');
  });

  test('url path drops signed query and fragment', () {
    expect(
        episodeUrlPath('https://cdn.test/a/1.m3u8?token=x#t=3'), '/a/1.m3u8');
    expect(episodeUrlPath('not a url'), 'not a url');
    expect(episodeUrlPath(''), '');
  });

  test('identity prefers URL, falls back to path, then title', () {
    expect(
      sameEpisode(urlA: 'https://x/1.m3u8?a=1', urlB: 'https://x/1.m3u8?a=2'),
      isTrue,
    );
    expect(
      sameEpisode(
          urlA: 'https://x/1.m3u8',
          titleA: '第1集',
          urlB: 'https://y/1.m3u8',
          titleB: '第１集'),
      isTrue,
    );
    expect(
      sameEpisode(urlA: 'https://x/1.m3u8', urlB: 'https://x/2.m3u8'),
      isFalse,
    );
    expect(sameEpisode(titleA: '', titleB: ''), isFalse);
    expect(
      sameEpisode(
          urlA: 'https://x/1.m3u8',
          titleA: '第1集',
          urlB: 'https://x/2.m3u8',
          titleB: '第2集'),
      isFalse,
    );
  });

  test('locateEpisode prefers the exact URL across lines', () {
    final d = _detail();
    final hit = locateEpisode(d, episodeUrl: 'https://cdn.other/b/2.m3u8');
    expect(hit!.lineIndex, 1);
    expect(hit.episodeIndex, 1);
  });

  test('locateEpisode matches a re-signed URL by path', () {
    final d = _detail();
    final hit = locateEpisode(d,
        episodeUrl: 'https://cdn.test/a/2.m3u8?token=999&expires=1');
    expect(hit!.lineIndex, 0);
    expect(hit.episodeIndex, 1);
  });

  test('locateEpisode matches by normalized title when the URL changed', () {
    final d = _detail();
    final hit = locateEpisode(d,
        episodeTitle: '第 1 集', episodeUrl: 'https://new/anything.m3u8');
    expect(hit!.lineIndex, 0);
    expect(hit.episodeIndex, 0);
  });

  test('locateEpisode falls back to a clamped index for legacy entries', () {
    final d = _detail();
    final hit = locateEpisode(d, episodeIndex: 99);
    expect(hit!.lineIndex, 0);
    expect(hit.episodeIndex, 1);
  });

  test('locateEpisode returns null with no detail lines', () {
    const empty = VodDetail(
        sourceId: 'a', sourceName: 'A', vodId: '1', title: '', playLines: []);
    expect(locateEpisode(empty, episodeIndex: 0), isNull);
  });

  test('fnv1aHex is stable, filesystem-safe and distinct', () {
    final a = fnv1aHex('a|1|第1集');
    expect(a, fnv1aHex('a|1|第1集'));
    expect(a, matches(RegExp(r'^[0-9a-f]{16}$')));
    expect(a, isNot(fnv1aHex('a|1|第2集')));
  });
}
