import 'package:flutter_test/flutter_test.dart';
import 'package:bear_tv/data/tmdb/tmdb_mappers.dart';

/// Pure-function tests for the TMDB JSON → VodItem mapping. No network, no
/// dart-define required (image base falls back to the public CDN default).
void main() {
  const genreNames = {18: '剧情', 53: '惊悚', 16: '动画', 99: '纪录'};

  Map<String, dynamic> movieJson() => {
        'id': 550,
        'media_type': 'movie',
        'title': '搏击俱乐部',
        'original_title': 'Fight Club',
        'overview': '一个失眠的上班族遇到了肥皂商人。',
        'poster_path': '/poster.jpg',
        'backdrop_path': '/backdrop.jpg',
        'vote_average': 8.4,
        'release_date': '1999-10-15',
        'genre_ids': [18, 53],
      };

  test('maps a movie row into a VodItem', () {
    final v = mapTmdbItem(movieJson(), fallbackMediaType: 'movie', genreNames: genreNames)!;
    expect(v.id, 550);
    expect(v.mediaType, 'movie');
    expect(v.title, '搏击俱乐部');
    expect(v.en, 'Fight Club');
    expect(v.year, 1999);
    expect(v.score, '8.4');
    expect(v.genre, '剧情 / 惊悚');
    expect(v.hd, '4K HDR'); // vote >= 8.0
    expect(v.posterUrl, 'https://image.tmdb.org/t/p/w500/poster.jpg');
    expect(v.bgUrl, 'https://image.tmdb.org/t/p/w1280/backdrop.jpg');
    expect(v.cardUrl, 'https://image.tmdb.org/t/p/w780/backdrop.jpg');
  });

  test('maps a tv row using name / first_air_date fallbacks', () {
    final v = mapTmdbItem({
      'id': 1396,
      'media_type': 'tv',
      'name': '绝命毒师',
      'original_name': 'Breaking Bad',
      'overview': '',
      'poster_path': '/bb.jpg',
      'vote_average': 7.2,
      'first_air_date': '2008-01-20',
      'genre_ids': [18],
    }, fallbackMediaType: 'tv', genreNames: genreNames)!;
    expect(v.mediaType, 'tv');
    expect(v.title, '绝命毒师');
    expect(v.en, 'Breaking Bad');
    expect(v.year, 2008);
    expect(v.score, '7.2');
    expect(v.hd, 'HD'); // vote < 8.0
    expect(v.desc, '暂无简介。'); // empty overview → placeholder
  });

  test('uses fallbackMediaType when media_type is absent (discover endpoints)', () {
    final json = movieJson()..remove('media_type');
    final v = mapTmdbItem(json, fallbackMediaType: 'movie', genreNames: genreNames)!;
    expect(v.mediaType, 'movie');
  });

  test('poster falls back to backdrop when poster_path is missing', () {
    final json = movieJson()..remove('poster_path');
    final v = mapTmdbItem(json, fallbackMediaType: 'movie', genreNames: genreNames)!;
    expect(v.posterUrl, 'https://image.tmdb.org/t/p/w780/backdrop.jpg');
  });

  test('missing score renders an em-dash', () {
    final json = movieJson()..['vote_average'] = 0;
    final v = mapTmdbItem(json, fallbackMediaType: 'movie', genreNames: genreNames)!;
    expect(v.score, '—');
  });

  test('non-media rows (person) map to null', () {
    final v = mapTmdbItem({'id': 1, 'media_type': 'person', 'name': '演员'},
        fallbackMediaType: 'movie', genreNames: genreNames);
    expect(v, isNull);
  });

  test('mapTmdbList drops non-media rows', () {
    final list = mapTmdbList([
      movieJson(),
      {'id': 2, 'media_type': 'person', 'name': '演员'},
      {'id': 3, 'media_type': 'tv', 'name': '剧', 'vote_average': 6.0},
    ], fallbackMediaType: 'movie', genreNames: genreNames);
    expect(list.length, 2);
    expect(list.map((e) => e.id), [550, 3]);
  });
}
