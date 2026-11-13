/// Minimal, dependency-free HLS playlist parser + rewriter used by the
/// offline downloader.
///
/// Only what a VOD download needs: master variant selection, media playlist
/// segments, AES-128 key tags, init maps and byte ranges. Everything is parsed
/// into absolute URIs against the playlist's final URL, then rewritten to
/// reference local file names.
library;

/// Thrown when a playlist can't be downloaded offline (live stream, unsupported
/// encryption, separate audio rendition, …).
class M3u8Exception implements Exception {
  final String message;
  const M3u8Exception(this.message);
  @override
  String toString() => message;
}

class M3u8Variant {
  final int bandwidth;
  final int width;
  final int height;
  final Uri uri;

  const M3u8Variant({
    required this.bandwidth,
    required this.uri,
    this.width = 0,
    this.height = 0,
  });

  int get pixels => width * height;
}

class M3u8Master {
  final List<M3u8Variant> variants;

  /// True when the master declares a separate audio rendition. v1 refuses these
  /// (downloading only the video playlist would produce a silent file).
  final bool hasSeparateAudio;

  const M3u8Master({required this.variants, this.hasSeparateAudio = false});
}

class M3u8Key {
  final String method;

  /// Null for `METHOD=NONE`; a `data:` URI is kept inline and never fetched.
  final Uri? uri;
  final String? iv;
  final String keyFormat;

  const M3u8Key({
    required this.method,
    this.uri,
    this.iv,
    this.keyFormat = 'identity',
  });

  bool sameAs(M3u8Key other) =>
      method == other.method &&
      uri?.toString() == other.uri?.toString() &&
      iv == other.iv &&
      keyFormat == other.keyFormat;

  bool get needsDownload =>
      uri != null && uri!.scheme != 'data' && method != 'NONE';
}

class M3u8Map {
  final Uri? uri;
  final int? rangeStart;
  final int? rangeLength;

  const M3u8Map({this.uri, this.rangeStart, this.rangeLength});

  bool sameAs(M3u8Map other) =>
      uri?.toString() == other.uri?.toString() &&
      rangeStart == other.rangeStart &&
      rangeLength == other.rangeLength;
}

class M3u8Segment {
  final Uri? uri;

  /// Absolute byte range when `#EXT-X-BYTERANGE` applies (inclusive end).
  final int? rangeStart;
  final int? rangeLength;
  final double duration;
  final String durationText;
  final M3u8Key? key;
  final M3u8Map? map;

  const M3u8Segment({
    required this.uri,
    required this.duration,
    required this.durationText,
    this.rangeStart,
    this.rangeLength,
    this.key,
    this.map,
  });

  bool get hasRange => rangeStart != null && rangeLength != null;
}

class M3u8MediaPlaylist {
  final List<M3u8Segment> segments;

  /// Unique key/map objects, also referenced by the segments above, so the
  /// downloader can assign one local file per object.
  final List<M3u8Key> keys;
  final List<M3u8Map> maps;

  final int mediaSequence;
  final bool finished;
  final int durationMs;

  const M3u8MediaPlaylist({
    required this.segments,
    required this.keys,
    required this.maps,
    required this.mediaSequence,
    required this.finished,
    required this.durationMs,
  });
}

class M3u8Parser {
  static bool isPlaylist(String body) => body.trimLeft().startsWith('#EXTM3U');

  static bool isMaster(String body) => body.contains('#EXT-X-STREAM-INF');

  /// Parse a master playlist. Relative variant URIs resolve against [base]
  /// (the final URL the playlist was served from).
  static M3u8Master parseMaster(String body, Uri base) {
    final lines = _lines(body);
    final variants = <M3u8Variant>[];
    var hasSeparateAudio = false;

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.startsWith('#EXT-X-STREAM-INF:')) {
        final attrs =
            parseAttributes(line.substring('#EXT-X-STREAM-INF:'.length));
        var j = i + 1;
        while (j < lines.length &&
            (lines[j].isEmpty || lines[j].startsWith('#'))) {
          j++;
        }
        if (j >= lines.length) continue;
        final uri = _resolve(base, lines[j]);
        i = j;
        if (uri == null) continue;
        final bandwidth =
            _int(attrs['BANDWIDTH']) ?? _int(attrs['AVERAGE-BANDWIDTH']) ?? 0;
        final res = attrs['RESOLUTION'];
        var w = 0;
        var h = 0;
        if (res != null) {
          final parts = res.toLowerCase().split('x');
          if (parts.length == 2) {
            w = _int(parts[0]) ?? 0;
            h = _int(parts[1]) ?? 0;
          }
        }
        variants.add(
            M3u8Variant(bandwidth: bandwidth, width: w, height: h, uri: uri));
      } else if (line.startsWith('#EXT-X-MEDIA:')) {
        final attrs = parseAttributes(line.substring('#EXT-X-MEDIA:'.length));
        if (attrs['TYPE']?.toUpperCase() == 'AUDIO' &&
            (attrs['URI']?.trim().isNotEmpty ?? false)) {
          hasSeparateAudio = true;
        }
      }
    }
    return M3u8Master(variants: variants, hasSeparateAudio: hasSeparateAudio);
  }

  /// Highest-bandwidth variant (resolution tie-break). The single place the
  /// bitrate policy lives: a resolution cap can be added here later.
  static M3u8Variant? chooseVariant(List<M3u8Variant> variants) {
    if (variants.isEmpty) return null;
    var best = variants.first;
    for (final v in variants.skip(1)) {
      if (v.bandwidth > best.bandwidth ||
          (v.bandwidth == best.bandwidth && v.pixels > best.pixels)) {
        best = v;
      }
    }
    return best;
  }

  /// Parse a media playlist. Throws [M3u8Exception] for streams that can't be
  /// downloaded (live / unfinished, SAMPLE-AES, I-frame-only).
  static M3u8MediaPlaylist parseMedia(String body, Uri base) {
    final lines = _lines(body);
    final segments = <M3u8Segment>[];
    final keys = <M3u8Key>[];
    final maps = <M3u8Map>[];

    M3u8Key? currentKey;
    M3u8Map? currentMap;
    var mediaSequence = 0;
    var ended = false;
    var vodType = false;
    var totalMs = 0;
    String? pendingRange;
    String? pendingDuration;
    // Implicit BYTERANGE offsets follow the previous sub-range of the same URI.
    final lastRangeEnd = <String, int>{};

    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty) continue;

      if (line.startsWith('#EXT-X-I-FRAMES-ONLY')) {
        throw const M3u8Exception('该资源为 I-frame 切片，暂不支持下载');
      }
      if (line.startsWith('#EXT-X-ENDLIST')) {
        ended = true;
        continue;
      }
      if (line.startsWith('#EXT-X-PLAYLIST-TYPE:')) {
        vodType = line.toUpperCase().contains('VOD');
        continue;
      }
      if (line.startsWith('#EXT-X-MEDIA-SEQUENCE:')) {
        mediaSequence =
            _int(line.substring('#EXT-X-MEDIA-SEQUENCE:'.length)) ?? 0;
        continue;
      }
      if (line.startsWith('#EXTINF:')) {
        final rest = line.substring('#EXTINF:'.length);
        final comma = rest.indexOf(',');
        pendingDuration = comma < 0 ? rest.trim() : rest.substring(0, comma);
        continue;
      }
      if (line.startsWith('#EXT-X-BYTERANGE:')) {
        pendingRange = line.substring('#EXT-X-BYTERANGE:'.length).trim();
        continue;
      }
      if (line.startsWith('#EXT-X-KEY:')) {
        final attrs = parseAttributes(line.substring('#EXT-X-KEY:'.length));
        final method = (attrs['METHOD'] ?? 'NONE').toUpperCase();
        if (method == 'NONE') {
          currentKey = const M3u8Key(method: 'NONE');
          continue;
        }
        if (method == 'SAMPLE-AES' || method == 'SAMPLE-AES-CTR') {
          throw const M3u8Exception('该资源使用 SAMPLE-AES 加密，暂不支持下载');
        }
        if (method != 'AES-128') {
          throw M3u8Exception('不支持的加密方式：$method');
        }
        final keyFormat = attrs['KEYFORMAT'] ?? 'identity';
        if (keyFormat != 'identity') {
          throw M3u8Exception('不支持的密钥格式：$keyFormat');
        }
        final keyUri = _resolve(base, attrs['URI']);
        if (keyUri == null) {
          throw const M3u8Exception('播放列表缺少解密密钥地址');
        }
        final key = M3u8Key(
          method: method,
          uri: keyUri,
          iv: attrs['IV'],
          keyFormat: keyFormat,
        );
        currentKey = key;
        if (!keys.any(key.sameAs)) keys.add(key);
        continue;
      }
      if (line.startsWith('#EXT-X-MAP:')) {
        final attrs = parseAttributes(line.substring('#EXT-X-MAP:'.length));
        final uri = _resolve(base, attrs['URI']);
        final range = parseRange(attrs['BYTERANGE']);
        final map = M3u8Map(
          uri: uri,
          rangeStart: range?.$1,
          rangeLength: range?.$2,
        );
        currentMap = map;
        if (!maps.any(map.sameAs)) maps.add(map);
        continue;
      }
      if (line.startsWith('#')) continue; // other tags are not needed

      final uri = _resolve(base, line);
      if (uri == null) continue;
      final durationText = pendingDuration ?? '0';
      final duration = double.tryParse(durationText) ?? 0;
      pendingDuration = null;

      int? rangeStart;
      int? rangeLength;
      if (pendingRange != null) {
        final parsed = parseRange(pendingRange);
        if (parsed != null) {
          rangeLength = parsed.$2;
          final uriKey = uri.toString();
          rangeStart = parsed.$1 ?? lastRangeEnd[uriKey] ?? 0;
          lastRangeEnd[uriKey] = rangeStart + rangeLength;
        }
        pendingRange = null;
      }

      totalMs += (duration * 1000).round();
      segments.add(M3u8Segment(
        uri: uri,
        duration: duration,
        durationText: durationText,
        rangeStart: rangeStart,
        rangeLength: rangeLength,
        key: currentKey,
        map: currentMap,
      ));
    }

    if (segments.isEmpty) {
      throw const M3u8Exception('播放列表为空，无法下载');
    }
    if (!ended && !vodType) {
      throw const M3u8Exception('直播或未结束的播放列表不支持离线下载');
    }
    return M3u8MediaPlaylist(
      segments: segments,
      keys: keys,
      maps: maps,
      mediaSequence: mediaSequence,
      finished: true,
      durationMs: totalMs,
    );
  }

  /// Rebuild a media playlist that references only local file names.
  ///
  /// [keyNames] / [mapNames] are keyed by object identity (the unique objects
  /// returned in [playlist]); [segmentNames] is parallel to the segments.
  static String rewrite(
    M3u8MediaPlaylist playlist, {
    required Map<M3u8Key, String> keyNames,
    required Map<M3u8Map, String> mapNames,
    required List<String> segmentNames,
  }) {
    final out = StringBuffer()
      ..writeln('#EXTM3U')
      ..writeln('#EXT-X-VERSION:3')
      ..writeln('#EXT-X-PLAYLIST-TYPE:VOD')
      ..writeln('#EXT-X-MEDIA-SEQUENCE:${playlist.mediaSequence}');

    var maxDuration = 0.0;
    for (final s in playlist.segments) {
      if (s.duration > maxDuration) maxDuration = s.duration;
    }
    out.writeln('#EXT-X-TARGETDURATION:${maxDuration.ceil()}');

    String? lastKeySig;
    String? lastMapSig;
    for (var i = 0; i < playlist.segments.length; i++) {
      final seg = playlist.segments[i];
      final key = seg.key;
      if (key != null) {
        final sig = '${key.method}|${key.uri}|${key.iv}|${key.keyFormat}';
        if (sig != lastKeySig) {
          if (key.method == 'NONE') {
            out.writeln('#EXT-X-KEY:METHOD=NONE');
          } else {
            final uri = _inlineKeyUri(key, keyNames);
            if (uri != null) {
              out.write('#EXT-X-KEY:METHOD=${key.method},URI="$uri"');
              if (key.iv != null && key.iv!.isNotEmpty) {
                out.write(',IV=${key.iv}');
              }
              out.writeln();
            }
          }
          lastKeySig = sig;
        }
      }
      final map = seg.map;
      if (map != null) {
        final sig = '${map.uri}|${map.rangeStart}|${map.rangeLength}';
        if (sig != lastMapSig) {
          final localName = mapNames[map];
          final name = localName ??
              (map.uri?.scheme == 'data' ? map.uri.toString() : null);
          if (name != null) out.writeln('#EXT-X-MAP:URI="$name"');
          lastMapSig = sig;
        }
      }
      out.writeln('#EXTINF:${seg.durationText},');
      final name = i < segmentNames.length ? segmentNames[i] : '';
      out.writeln(name);
    }
    out.writeln('#EXT-X-ENDLIST');
    return out.toString();
  }

  static String? _inlineKeyUri(M3u8Key key, Map<M3u8Key, String> names) {
    final uri = key.uri?.toString();
    if (uri == null || uri.isEmpty) return null;
    if (uri.startsWith('data:')) return uri;
    return names[key];
  }

  static Uri? _resolve(Uri base, String? value) {
    final v = value?.trim() ?? '';
    if (v.isEmpty) return null;
    if (v.startsWith('data:')) {
      final u = Uri.tryParse(v);
      return u;
    }
    try {
      return base.resolve(v);
    } catch (_) {
      return null;
    }
  }

  static int? _int(String? s) {
    final v = s?.trim();
    if (v == null || v.isEmpty) return null;
    return int.tryParse(v);
  }

  static List<String> _lines(String body) {
    var text = body;
    if (text.startsWith('﻿')) text = text.substring(1);
    return text.split(RegExp(r'\r?\n')).map((l) => l.trim()).toList();
  }
}

/// Parse `#EXT-X-BYTERANGE:length[@offset]` → `(offset?, length)`.
(int?, int)? parseRange(String? raw) {
  final v = raw?.trim();
  if (v == null || v.isEmpty) return null;
  final at = v.indexOf('@');
  final lenText = at < 0 ? v : v.substring(0, at);
  final len = int.tryParse(lenText.trim());
  if (len == null || len <= 0) return null;
  if (at < 0) return (null, len);
  final start = int.tryParse(v.substring(at + 1).trim());
  return (start, len);
}

/// Parse an HLS attribute list (`KEY=VALUE,KEY="quoted, value"`).
Map<String, String> parseAttributes(String input) {
  final out = <String, String>{};
  var i = 0;
  while (i < input.length) {
    var eq = input.indexOf('=', i);
    if (eq < 0) break;
    final key = input.substring(i, eq).trim();
    var j = eq + 1;
    String value;
    if (j < input.length && input[j] == '"') {
      final end = input.indexOf('"', j + 1);
      if (end < 0) {
        value = input.substring(j + 1);
        j = input.length;
      } else {
        value = input.substring(j + 1, end);
        j = end + 1;
      }
    } else {
      var comma = input.indexOf(',', j);
      if (comma < 0) comma = input.length;
      value = input.substring(j, comma).trim();
      j = comma;
    }
    if (key.isNotEmpty) out[key] = value;
    final next = input.indexOf(',', j);
    if (next < 0) break;
    i = next + 1;
  }
  return out;
}
