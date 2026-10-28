import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

/// Offline pinyin → 汉字 input method, backed by a bundled dictionary asset
/// (`assets/pinyin_dict.txt`). Fully local — no network — so it works on the
///国内 TV boxes this app targets, where Google/云输入 is unreachable and we can't
/// ship a 3rd-party IME (搜狗 etc.).
///
/// The asset has two sections: `# chars` (syllable → freq-ranked 汉字, primary
/// reading only) and `# words` (concatenated pinyin → freq-ranked 词). Lookup is
/// a plain map get plus a small bounded prefix scan; the whole table is ~135KB
/// and stays comfortably within the low-end memory budget.
///
/// The word table is **film/TV-first**: keys carrying a 影视 term are listed
/// ahead of the general vocabulary, so typing `liu` offers 流浪地球 rather than
/// filling the candidate list with 流传/榴弹. Regenerate it with
/// `python3 tool/build_pinyin_dict.py` after editing `tool/pinyin_terms.txt`.
class PinyinIme {
  PinyinIme._(this._syllables, this._chars, this._words);

  final List<String> _syllables; // sorted syllable keys, for prefix scan
  final Map<String, String> _chars; // syllable -> 汉字 (freq order, packed)
  final Map<String, List<String>> _words; // concat pinyin -> 词 (freq order)

  static PinyinIme? _instance;
  static Future<PinyinIme>? _loading;

  /// Loads (and caches) the IME. Cheap to call repeatedly — the parse runs once.
  static Future<PinyinIme> load() {
    final cached = _instance;
    if (cached != null) return Future.value(cached);
    return _loading ??= _parse();
  }

  static Future<PinyinIme> _parse() async {
    final raw = await rootBundle.loadString('assets/pinyin_dict.txt');
    final chars = <String, String>{};
    final words = <String, List<String>>{};
    var section = '';
    for (final line in const LineSplitter().convert(raw)) {
      if (line.isEmpty) continue;
      if (line.startsWith('#')) {
        if (line.contains('chars')) {
          section = 'c';
        } else if (line.contains('words')) {
          section = 'w';
        }
        continue;
      }
      final tab = line.indexOf('\t');
      if (tab <= 0) continue;
      final key = line.substring(0, tab);
      final val = line.substring(tab + 1);
      if (section == 'c') {
        chars[key] = val;
      } else if (section == 'w') {
        words[key] = val.split(' ');
      }
    }
    final syllables = chars.keys.toList()..sort();
    final ime = PinyinIme._(syllables, chars, words);
    _instance = ime;
    _loading = null;
    return ime;
  }

  /// Candidates for the current pinyin [buffer] (lowercase a–z). Ordering:
  /// exact-word matches → exact-syllable 汉字 → prefix-word matches → 汉字 from
  /// syllables that start with the buffer. Deduped and capped at [limit].
  ///
  /// Prefix matches walk the word table in file order, and that table lists
  /// 影视词 first — so a film/TV title outranks the general vocabulary.
  List<String> candidates(String buffer, {int limit = 40}) {
    if (buffer.isEmpty) return const [];
    final out = <String>[];
    final seen = <String>{};
    void add(String s) {
      if (s.isNotEmpty && seen.add(s)) out.add(s);
    }

    // 1) exact word(s) — highest priority, already freq-ranked.
    final exactWords = _words[buffer];
    if (exactWords != null) exactWords.forEach(add);

    // 2) exact-syllable 汉字.
    final exactChars = _chars[buffer];
    if (exactChars != null) {
      for (final r in exactChars.runes) {
        add(String.fromCharCode(r));
        if (out.length >= limit) return out;
      }
    }

    // 3) prefix-word matches (bounded scan; live feedback while typing a word).
    if (out.length < limit) {
      var scanned = 0;
      for (final e in _words.entries) {
        if (out.length >= limit || scanned++ > 4000) break;
        if (e.key.length > buffer.length && e.key.startsWith(buffer)) {
          for (final w in e.value) {
            add(w);
            if (out.length >= limit) break;
          }
        }
      }
    }

    // 4) 汉字 from syllables that start with the buffer (e.g. "zh" → 之知织…).
    if (out.length < limit) {
      for (final s in _syllables) {
        if (out.length >= limit) break;
        if (s.length > buffer.length && s.startsWith(buffer)) {
          for (final r in (_chars[s] ?? '').runes) {
            add(String.fromCharCode(r));
            if (out.length >= limit) break;
          }
        }
      }
    }
    return out;
  }
}
