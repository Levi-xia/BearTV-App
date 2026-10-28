#!/usr/bin/env python3
# Build a compact offline pinyin->hanzi dictionary asset for the TV search IME.
#
# Regenerate the bundled asset (assets/pinyin_dict.txt) like so:
#   cd /tmp
#   curl -sL https://raw.githubusercontent.com/mozillazg/pinyin-data/master/pinyin.txt -o py_char.txt
#   curl -sL https://raw.githubusercontent.com/mozillazg/phrase-pinyin-data/master/pinyin.txt -o py_phrase.txt
#   curl -sL https://raw.githubusercontent.com/fxsjy/jieba/master/extra_dict/dict.txt.small -o jieba_small.txt
#   python3 tool/gen_pinyin_dict.py
#
# Inputs (downloaded to /tmp): py_char.txt (mozillazg pinyin-data — char→readings),
# py_phrase.txt (mozillazg phrase-pinyin-data — 词→readings), jieba_small.txt
# (jieba word frequency). Output: assets/pinyin_dict.txt with two sections
# ("# chars" syllable→freq-ranked 汉字 primary reading only, "# words"
# concatenated-pinyin→freq-ranked 词). All data is open-source; bundling makes
# the IME fully offline for the 国内 TV boxes this app targets.
import unicodedata
from collections import defaultdict

OUT = "/Users/levi/workspace/TV/BearTv-app/assets/pinyin_dict.txt"
MAX_CHARS_PER_SYLLABLE = 60
MAX_WORDS = 6000

UMLAUT = set("üÜǖǘǚǜ")

def deacc(s: str) -> str:
    out = []
    for ch in s:
        if ch in UMLAUT:
            out.append("v")
            continue
        d = unicodedata.normalize("NFD", ch)
        out.append("".join(c for c in d if not unicodedata.combining(c)))
    return "".join(out).lower()

# --- char -> ascii syllable readings --------------------------------------
char_py = {}
with open("/tmp/py_char.txt", encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        left, _, comment = line.partition("#")
        _, _, pys = left.partition(":")
        comment = comment.strip()
        if not comment:
            continue
        char = comment.split()[0]
        if len(char) != 1:
            continue
        # Use only the PRIMARY (first) reading per char. The full list includes
        # rare literary readings (e.g. 波 as "bei") that pollute the candidate
        # bar; common polyphonic *words* (重庆, 银行) are covered by the word
        # table below, which carries correct contextual pinyin.
        syls = []
        first = pys.strip().split(",")[0].strip()
        a = deacc(first)
        if a.isalpha():
            syls.append(a)
        if syls:
            char_py[char] = syls

# --- word + char frequency from jieba -------------------------------------
char_freq = defaultdict(int)
word_freq = {}
with open("/tmp/jieba_small.txt", encoding="utf-8") as f:
    for line in f:
        parts = line.split()
        if len(parts) < 2:
            continue
        w = parts[0]
        try:
            fr = int(parts[1])
        except ValueError:
            continue
        if fr > word_freq.get(w, 0):
            word_freq[w] = fr
        for c in w:
            char_freq[c] += fr

# --- syllable -> chars (freq-ranked) --------------------------------------
syl = defaultdict(set)
for char, syls in char_py.items():
    for s in syls:
        syl[s].add(char)

char_lines = []
for s in sorted(syl):
    if not s.isalpha():
        continue
    chars = sorted(syl[s], key=lambda c: -char_freq.get(c, 0))
    ranked = [c for c in chars if char_freq.get(c, 0) > 0][:MAX_CHARS_PER_SYLLABLE]
    if not ranked:
        ranked = chars[:20]
    char_lines.append(s + "\t" + "".join(ranked))

# --- word table: phrase-pinyin intersected with jieba freq ----------------
words = []
with open("/tmp/py_phrase.txt", encoding="utf-8") as f:
    for line in f:
        line = line.rstrip("\n")
        if not line or line.startswith("#"):
            continue
        w, _, pys = line.partition(":")
        w = w.strip()
        if not (2 <= len(w) <= 4):
            continue
        fr = word_freq.get(w)
        if not fr:
            continue
        concat = "".join(deacc(p) for p in pys.strip().split())
        if not concat.isalpha():
            continue
        words.append((concat, w, fr))

words.sort(key=lambda t: -t[2])
words = words[:MAX_WORDS]
bykey = defaultdict(list)
for concat, w, fr in words:
    bykey[concat].append((w, fr))

word_lines = []
for k in sorted(bykey):
    ws = [w for w, _ in sorted(bykey[k], key=lambda x: -x[1])]
    word_lines.append(k + "\t" + " ".join(ws))

with open(OUT, "w", encoding="utf-8") as out:
    out.write("# offline pinyin dict — generated; do not edit by hand\n")
    out.write("# chars\n")
    out.write("\n".join(char_lines))
    out.write("\n# words\n")
    out.write("\n".join(word_lines))
    out.write("\n")

print(f"syllables={len(char_lines)} words_keys={len(word_lines)} words_total={len(words)}")
