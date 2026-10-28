import 'package:flutter_test/flutter_test.dart';

import 'package:bear_tv/data/pinyin_ime.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('loads bundled dict and returns word + char candidates', () async {
    final ime = await PinyinIme.load();

    // Exact word pinyin → common words come first.
    expect(ime.candidates('beijing'), contains('北京'));
    expect(ime.candidates('zhongguo'), contains('中国'));

    // Exact syllable → 汉字 candidates.
    final zhang = ime.candidates('zhang');
    expect(zhang, contains('张'));
    expect(zhang.length, greaterThan(3));

    // Prefix syllable gives live feedback before a full syllable is typed.
    expect(ime.candidates('zh'), isNotEmpty);

    // Empty buffer → no candidates.
    expect(ime.candidates(''), isEmpty);
  });

  test('film/TV vocabulary outranks the general word list', () async {
    final ime = await PinyinIme.load();

    // Exact title pinyin resolves to the title.
    expect(ime.candidates('kuangbiao'), contains('狂飙'));
    expect(ime.candidates('liulangdiqiu'), contains('流浪地球'));
    expect(ime.candidates('zhenhuanchuan'), contains('甄嬛传'));

    // The 影视 keys are ordered ahead of the general vocabulary, so a short
    // buffer still surfaces titles within the first few candidates.
    expect(ime.candidates('kuangbiao').first, '狂飙');
    expect(ime.candidates('zhenhuanchuan').first, '甄嬛传');
    expect(ime.candidates('santi').first, '三体');
    expect(ime.candidates('liulang').take(3), contains('流浪地球'));

    // Genre / cast terms are searchable too.
    expect(ime.candidates('dongzuo'), contains('动作片'));
    expect(ime.candidates('wujing'), contains('吴京'));

    // Polyphonic titles are reachable under the reading users actually type.
    expect(ime.candidates('changjinhu'), contains('长津湖'));
    expect(ime.candidates('xiji'), contains('西游记'));
  });
}
