import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'download_models.dart';
import 'download_storage.dart';
import 'm3u8_parser.dart';

/// Thrown internally when a download is paused/removed. The manager catches it
/// and keeps the partial files for a later resume.
class DownloadCancelled implements Exception {
  const DownloadCancelled();
}

/// Cooperative cancellation checked between network operations and chunks.
class DownloadCancelToken {
  bool _cancelled = false;

  bool get cancelled => _cancelled;

  void cancel() => _cancelled = true;

  void throwIfCancelled() {
    if (_cancelled) throw const DownloadCancelled();
  }
}

class DownloadProgress {
  final int doneSegments;
  final int totalSegments;
  final int receivedBytes;
  final int totalBytes;

  /// HLS only: duration of the downloaded prefix that the partial playlist
  /// currently exposes, i.e. how much of the episode is playable from disk.
  /// Always matches the `partial.m3u8` on disk, so the playhead can never run
  /// past the segments the player knows about.
  final int playableMs;

  /// HLS only: full episode duration (the prefix's target for 边下边播).
  final int totalMs;

  const DownloadProgress({
    this.doneSegments = 0,
    this.totalSegments = 0,
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.playableMs = 0,
    this.totalMs = 0,
  });

  double get fraction {
    if (totalSegments > 0)
      return (doneSegments / totalSegments).clamp(0.0, 1.0);
    if (totalBytes > 0) {
      return (receivedBytes / totalBytes).clamp(0.0, 1.0);
    }
    return 0;
  }
}

class DownloadResult {
  final String relativePath;
  final bool isHls;
  final int bytes;
  final int durationMs;
  final int bandwidth;

  /// HLS only: number of finished segments (write progress after resume).
  final int totalSegments;

  const DownloadResult({
    required this.relativePath,
    required this.isHls,
    required this.bytes,
    this.durationMs = 0,
    this.bandwidth = 0,
    this.totalSegments = 0,
  });
}

class DownloadException implements Exception {
  final String message;
  final int? statusCode;

  const DownloadException(this.message, {this.statusCode});

  /// Network hiccups, timeouts, 408/429 and 5xx are worth retrying; 4xx (except
  /// 408/429) and the "server ignores Range" case are not.
  bool get retryable {
    final code = statusCode;
    if (code == null) return true;
    return code == 408 || code == 429 || code >= 500;
  }

  @override
  String toString() => message;
}

abstract class DownloadEngine {
  Future<DownloadResult> run(
    DownloadTask task,
    DownloadStorage storage, {
    required DownloadCancelToken cancel,
    required void Function(DownloadProgress) onProgress,
  });

  /// Release any owned HTTP resources.
  void dispose();
}

/// Downloads an episode as a rewritten local HLS playlist or a single file.
///
/// HLS handling: master → highest-bandwidth variant → media playlist. AES-128
/// keys, init maps and BYTERANGE segments are fetched into the task directory
/// and the playlist is rewritten to relative local names. Live playlists and
/// unsupported encryption are rejected with a user-facing message.
class HttpDownloadEngine implements DownloadEngine {
  HttpDownloadEngine({
    http.Client? client,
    this.timeout = const Duration(seconds: 30),
    this.retryDelay = const Duration(milliseconds: 500),
  })  : _client = client ?? http.Client(),
        _ownsClient = client == null;

  static const _userAgent = 'Mozilla/5.0 (Linux; Android 9) BearTV';

  final http.Client _client;
  final bool _ownsClient;
  final Duration timeout;

  /// Base delay between retries (doubles each attempt). Tests set zero.
  final Duration retryDelay;

  @override
  Future<DownloadResult> run(
    DownloadTask task,
    DownloadStorage storage, {
    required DownloadCancelToken cancel,
    required void Function(DownloadProgress) onProgress,
  }) async {
    final dir = await storage.ensureTaskDir(task);
    if (dir == null) {
      throw const DownloadException('存储不可用，无法下载');
    }
    cancel.throwIfCancelled();

    final uri = Uri.tryParse(task.episodeUrl.trim());
    if (uri == null || !uri.hasScheme) {
      throw const DownloadException('播放地址无效');
    }

    if (_looksLikePlaylistUrl(uri)) {
      return _downloadHls(task, dir,
          baseUrl: uri, cancel: cancel, onProgress: onProgress);
    }

    // Unknown extension: sniff the response. A playlist is small, so reading it
    // here costs nothing; a video body is discarded and re-requested by the
    // direct path (which needs Range/resume semantics anyway).
    final sniff = await _open(uri, cancel: cancel);
    final contentType =
        (sniff.response.headers['content-type'] ?? '').toLowerCase();
    if (contentType.contains('mpegurl')) {
      final text = await _readBodyText(sniff.response, cancel);
      return _downloadHls(task, dir,
          baseUrl: sniff.url,
          playlistText: text,
          cancel: cancel,
          onProgress: onProgress);
    }

    final iterator =
        StreamIterator<List<int>>(sniff.response.stream.timeout(timeout));
    try {
      final hasFirst = await iterator.moveNext();
      final first = hasFirst ? <int>[...iterator.current] : <int>[];
      if (_looksLikePlaylistBytes(first)) {
        final buf = BytesBuilder(copy: false)..add(first);
        while (await iterator.moveNext()) {
          cancel.throwIfCancelled();
          buf.add(iterator.current);
        }
        final text = utf8.decode(buf.takeBytes(), allowMalformed: true);
        return await _downloadHls(task, dir,
            baseUrl: sniff.url,
            playlistText: text,
            cancel: cancel,
            onProgress: onProgress);
      }
    } finally {
      // Closes the subscription (and the underlying connection).
      unawaited(iterator.cancel().catchError((_) {}));
    }

    return _downloadDirect(task, dir, uri,
        cancel: cancel, onProgress: onProgress);
  }

  // --- HLS ------------------------------------------------------------------

  Future<DownloadResult> _downloadHls(
    DownloadTask task,
    Directory dir, {
    required Uri baseUrl,
    required DownloadCancelToken cancel,
    required void Function(DownloadProgress) onProgress,
    String? playlistText,
  }) async {
    var base = baseUrl;
    var text = playlistText;
    var bandwidth = 0;

    if (text == null) {
      final fetched = await _readPlaylist(base, cancel: cancel);
      text = fetched.$1;
      base = fetched.$2;
    }

    if (M3u8Parser.isMaster(text)) {
      final master = M3u8Parser.parseMaster(text, base);
      if (master.hasSeparateAudio) {
        throw const M3u8Exception('该资源为分离音轨，暂不支持下载');
      }
      final variant = M3u8Parser.chooseVariant(master.variants);
      if (variant == null) {
        throw const M3u8Exception('未找到可下载的清晰度');
      }
      bandwidth = variant.bandwidth;
      final fetched = await _readPlaylist(variant.uri, cancel: cancel);
      text = fetched.$1;
      base = fetched.$2;
    }

    final playlist = M3u8Parser.parseMedia(text, base);

    // Resume fingerprint: if the segment list changed, drop stale fragments so
    // old files can't be stitched to the new playlist.
    final identities = [
      for (final s in playlist.segments)
        '${s.uri}|${s.rangeStart ?? ''}|${s.rangeLength ?? ''}',
    ];
    final manifest = File(_join(dir.path, 'manifest.json'));
    final previous = await _readManifest(manifest);
    if (!_sameList(previous, identities)) {
      await _clearFragments(dir);
      await manifest.writeAsString(jsonEncode({'segments': identities}),
          flush: true);
    }

    final keyNames = <M3u8Key, String>{};
    var keyIndex = 0;
    for (final key in playlist.keys) {
      if (!key.needsDownload) continue;
      final name = 'key_${keyIndex++}.key';
      final file = File(_join(dir.path, name));
      if (!await _hasBytes(file)) {
        final bytes = await _getBytes(key.uri!, cancel: cancel);
        if (bytes.isEmpty) {
          throw const DownloadException('解密密钥为空');
        }
        await file.writeAsBytes(bytes, flush: true);
      }
      keyNames[key] = name;
    }

    final mapNames = <M3u8Map, String>{};
    var mapIndex = 0;
    for (final map in playlist.maps) {
      final uri = map.uri;
      if (uri == null) continue;
      if (uri.scheme == 'data') {
        // Inline init data: keep the data: URI in the rewritten playlist.
        continue;
      }
      final name =
          'init_${mapIndex++}${_extFor(uri.toString(), fallback: '.mp4')}';
      final file = File(_join(dir.path, name));
      if (!await _hasBytes(file, expected: map.rangeLength)) {
        final bytes = await _getBytes(
          uri,
          start: map.rangeStart,
          length: map.rangeLength,
          cancel: cancel,
        );
        await file.writeAsBytes(bytes, flush: true);
      }
      mapNames[map] = name;
    }

    // Names for every segment up front: the partial playlist written for
    // 边下边播 must reference segments that are still being fetched.
    final segmentNames = <String>[
      for (var i = 0; i < playlist.segments.length; i++)
        _segmentName(i, playlist.segments[i].uri),
    ];
    var done = 0;
    var bytes = 0;
    var prefixMs = 0;
    var writtenMs = 0;
    var wrotePartial = false;
    final partialWatch = Stopwatch()..start();
    for (var i = 0; i < playlist.segments.length; i++) {
      cancel.throwIfCancelled();
      final seg = playlist.segments[i];
      final uri = seg.uri;
      final name = segmentNames[i];
      if (uri == null || name.isEmpty) continue;
      final file = File(_join(dir.path, name));
      if (await _hasBytes(file, expected: seg.rangeLength)) {
        done++;
        bytes += await file.length();
      } else {
        final data = await _getBytes(
          uri,
          start: seg.rangeStart,
          length: seg.rangeLength,
          cancel: cancel,
        );
        if (data.isEmpty) {
          // An empty fragment would leave a hole in the local playlist that the
          // player can't skip over; fail the task instead of marking it done.
          throw const DownloadException('分段数据为空');
        }
        await file.writeAsBytes(data, flush: true);
        done++;
        bytes += data.length;
      }
      prefixMs += (seg.duration * 1000).round();
      // Refresh the playable prefix playlist at most every few seconds: the
      // player only needs it to keep moving forward, and rebuilding an
      // ever-longer playlist per segment is wasted I/O on weak boxes.
      final last = i == playlist.segments.length - 1;
      if (!wrotePartial || last || partialWatch.elapsedMilliseconds >= 3000) {
        final ok = await _writePartialPlaylist(
          dir,
          playlist,
          keyNames: keyNames,
          mapNames: mapNames,
          segmentNames: segmentNames,
          count: i + 1,
          durationMs: prefixMs,
        );
        if (ok) {
          writtenMs = prefixMs;
          wrotePartial = true;
          partialWatch.reset();
        }
      }
      onProgress(DownloadProgress(
        doneSegments: done,
        totalSegments: playlist.segments.length,
        receivedBytes: bytes,
        playableMs: writtenMs,
        totalMs: playlist.durationMs,
      ));
    }

    final rewritten = M3u8Parser.rewrite(
      playlist,
      keyNames: keyNames,
      mapNames: mapNames,
      segmentNames: segmentNames,
    );
    final index = File(_join(dir.path, 'index.m3u8'));
    final tmp = File(_join(dir.path, 'index.m3u8.tmp'));
    await tmp.writeAsString(rewritten, flush: true);
    if (await index.exists()) await index.delete();
    await tmp.rename(index.path);

    // Kept for diagnostics / manual inspection; resume only needs manifest.json.
    try {
      await File(_join(dir.path, 'source.m3u8'))
          .writeAsString(text, flush: true);
    } catch (_) {
      // Best-effort.
    }

    return DownloadResult(
      relativePath: 'index.m3u8',
      isHls: true,
      bytes: bytes,
      durationMs: playlist.durationMs,
      bandwidth: bandwidth,
      totalSegments: playlist.segments.length,
    );
  }

  /// Local file name for segment [index] (0-based). Shared by the downloader
  /// and the partial playlist so both always agree on the layout.
  static String _segmentName(int index, Uri? uri) {
    if (uri == null) return '';
    return 'seg_${(index + 1).toString().padLeft(5, '0')}'
        '${_extFor(uri.toString())}';
  }

  /// Writes `partial.m3u8`: a self-contained VOD playlist for the finished
  /// prefix, so a player can start before the whole episode is on disk
  /// (边下边播). Atomic (tmp + rename) and best-effort — a failed write only
  /// delays the playable prefix, never the download itself.
  Future<bool> _writePartialPlaylist(
    Directory dir,
    M3u8MediaPlaylist playlist, {
    required Map<M3u8Key, String> keyNames,
    required Map<M3u8Map, String> mapNames,
    required List<String> segmentNames,
    required int count,
    required int durationMs,
  }) async {
    try {
      final prefix = M3u8MediaPlaylist(
        segments: playlist.segments.sublist(0, count),
        keys: playlist.keys,
        maps: playlist.maps,
        mediaSequence: playlist.mediaSequence,
        finished: true,
        durationMs: durationMs,
      );
      final text = M3u8Parser.rewrite(
        prefix,
        keyNames: keyNames,
        mapNames: mapNames,
        segmentNames: segmentNames.sublist(0, count),
      );
      final target = File(_join(dir.path, 'partial.m3u8'));
      final tmp = File(_join(dir.path, 'partial.m3u8.tmp'));
      await tmp.writeAsString(text, flush: true);
      try {
        await tmp.rename(target.path);
      } catch (_) {
        // Windows/older POSIX fails to rename over an existing file.
        if (await target.exists()) await target.delete();
        await tmp.rename(target.path);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  // --- Direct files ---------------------------------------------------------
  Future<DownloadResult> _downloadDirect(
    DownloadTask task,
    Directory dir,
    Uri uri, {
    required DownloadCancelToken cancel,
    required void Function(DownloadProgress) onProgress,
  }) async {
    final name = 'video${_extFor(uri.toString(), fallback: '.mp4')}';
    final target = File(_join(dir.path, name));
    final part = File(_join(dir.path, 'video.part'));

    for (var attempt = 0;; attempt++) {
      cancel.throwIfCancelled();
      try {
        if (await target.exists() && await target.length() > 0) {
          return DownloadResult(
            relativePath: name,
            isHls: false,
            bytes: await target.length(),
          );
        }
        var received = 0;
        if (await _hasFile(part)) received = await part.length();
        final extra = <String, String>{};
        if (received > 0) extra['Range'] = 'bytes=$received-';

        final fetched = await _open(uri, extraHeaders: extra, cancel: cancel);
        final status = fetched.response.statusCode;

        if (status == 416 && received > 0) {
          await fetched.response.stream.drain<void>();
          await part.rename(target.path);
          return DownloadResult(
              relativePath: name, isHls: false, bytes: received);
        }
        if (status != 200 && status != 206) {
          await fetched.response.stream.drain<void>();
          throw DownloadException(
            _httpMessage(status),
            statusCode: status,
          );
        }

        final append = status == 206 && received > 0;
        if (!append) received = 0;
        final total = _totalBytes(fetched.response, received);

        final sink =
            part.openWrite(mode: append ? FileMode.append : FileMode.write);
        try {
          await for (final chunk in fetched.response.stream.timeout(timeout)) {
            cancel.throwIfCancelled();
            sink.add(chunk);
            received += chunk.length;
            onProgress(DownloadProgress(
              receivedBytes: received,
              totalBytes: total ?? 0,
            ));
          }
          await sink.flush();
          await sink.close();
        } catch (_) {
          await sink.close();
          rethrow;
        }

        if (await target.exists()) await target.delete();
        await part.rename(target.path);
        return DownloadResult(
            relativePath: name, isHls: false, bytes: received);
      } on DownloadCancelled {
        rethrow;
      } catch (e) {
        if (attempt >= 2 || !_isRetryable(e)) {
          if (e is DownloadException) rethrow;
          throw DownloadException('下载失败：$e');
        }
        await Future<void>.delayed(retryDelay * (1 << attempt));
      }
    }
  }

  // --- HTTP helpers ---------------------------------------------------------

  Future<_Fetched> _open(
    Uri uri, {
    Map<String, String>? extraHeaders,
    required DownloadCancelToken cancel,
  }) async {
    var current = uri;
    for (var hop = 0; hop < 5; hop++) {
      cancel.throwIfCancelled();
      try {
        final request = http.Request('GET', current)
          ..followRedirects = false
          ..headers.addAll({
            'User-Agent': _userAgent,
            'Accept': '*/*',
            'Referer': '${current.scheme}://${current.authority}/',
            ...?extraHeaders,
          });
        final response = await _client.send(request).timeout(timeout);
        final code = response.statusCode;
        final location = response.headers['location'];
        if (code >= 300 && code < 400 && location != null) {
          await response.stream.drain<void>();
          current = current.resolve(location);
          continue;
        }
        return _Fetched(current, response);
      } on DownloadCancelled {
        rethrow;
      } on DownloadException {
        rethrow;
      } on TimeoutException {
        throw const DownloadException('请求超时');
      } catch (_) {
        throw const DownloadException('无法连接资源服务器');
      }
    }
    throw const DownloadException('重定向次数过多');
  }

  Future<List<int>> _getBytes(
    Uri uri, {
    int? start,
    int? length,
    required DownloadCancelToken cancel,
  }) =>
      _retry(() async {
        final extra = <String, String>{};
        if (start != null && length != null) {
          extra['Range'] = 'bytes=$start-${start + length - 1}';
        }
        final fetched = await _open(uri, extraHeaders: extra, cancel: cancel);
        final response = fetched.response;
        final code = response.statusCode;
        if (code < 200 || code >= 300) {
          await response.stream.drain<void>();
          throw DownloadException(_httpMessage(code), statusCode: code);
        }
        if (start != null && code == 200) {
          await response.stream.drain<void>();
          throw const DownloadException('服务器不支持分段下载', statusCode: 200);
        }
        final data = await _collect(response.stream.timeout(timeout));
        if (length != null && data.length != length) {
          throw const DownloadException('分段数据不完整');
        }
        return data;
      }, cancel);

  Future<(String, Uri)> _readPlaylist(
    Uri uri, {
    required DownloadCancelToken cancel,
  }) =>
      _retry(() async {
        final fetched = await _open(uri, cancel: cancel);
        final response = fetched.response;
        if (response.statusCode < 200 || response.statusCode >= 300) {
          await response.stream.drain<void>();
          throw DownloadException(_httpMessage(response.statusCode),
              statusCode: response.statusCode);
        }
        final text = await _readBodyText(response, cancel);
        if (!M3u8Parser.isPlaylist(text)) {
          throw const DownloadException('返回内容不是播放列表');
        }
        return (text, fetched.url);
      }, cancel);

  Future<String> _readBodyText(
      http.StreamedResponse response, DownloadCancelToken cancel) async {
    final data = await _collect(response.stream.timeout(timeout));
    cancel.throwIfCancelled();
    return utf8.decode(data, allowMalformed: true);
  }

  Future<T> _retry<T>(
      Future<T> Function() op, DownloadCancelToken cancel) async {
    for (var attempt = 0;; attempt++) {
      cancel.throwIfCancelled();
      try {
        return await op();
      } on DownloadCancelled {
        rethrow;
      } on M3u8Exception {
        rethrow;
      } catch (e) {
        if (attempt >= 2 || !_isRetryable(e)) {
          if (e is DownloadException) rethrow;
          throw DownloadException('下载失败：$e');
        }
        await Future<void>.delayed(retryDelay * (1 << attempt));
      }
    }
  }

  Future<List<int>> _collect(Stream<List<int>> stream) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  @override
  void dispose() {
    if (_ownsClient) _client.close();
  }
}

class _Fetched {
  final Uri url;
  final http.StreamedResponse response;
  const _Fetched(this.url, this.response);
}

bool _looksLikePlaylistUrl(Uri uri) {
  final path = uri.path.toLowerCase();
  return path.endsWith('.m3u8') || path.endsWith('.m3u');
}

bool _looksLikePlaylistBytes(List<int> bytes) {
  if (bytes.isEmpty) return false;
  var data = bytes;
  if (data.length >= 3 &&
      data[0] == 0xEF &&
      data[1] == 0xBB &&
      data[2] == 0xBF) {
    data = data.sublist(3);
  }
  final head = latin1.decode(data.length > 16 ? data.sublist(0, 16) : data,
      allowInvalid: true);
  return head.trimLeft().startsWith('#EXTM3U');
}

bool _isRetryable(Object e) {
  if (e is DownloadException) return e.retryable;
  return e is TimeoutException ||
      e is SocketException ||
      e is http.ClientException ||
      e is HttpException;
}

String _httpMessage(int code) {
  if (code == 403) return 'HTTP 403 · 资源拒绝访问';
  if (code == 404) return 'HTTP 404 · 资源不存在';
  return 'HTTP $code';
}

int? _totalBytes(http.StreamedResponse response, int received) {
  final range = response.headers['content-range'];
  if (range != null) {
    final slash = range.lastIndexOf('/');
    if (slash >= 0) {
      final total = int.tryParse(range.substring(slash + 1).trim());
      if (total != null && total > 0) return total;
    }
  }
  final length = response.contentLength;
  if (length != null && length > 0) return received + length;
  return null;
}

Future<bool> _hasBytes(File file, {int? expected}) async {
  try {
    if (!await file.exists()) return false;
    final length = await file.length();
    if (expected != null) return length == expected;
    return length > 0;
  } catch (_) {
    return false;
  }
}

Future<bool> _hasFile(File file) async {
  try {
    return await file.exists();
  } catch (_) {
    return false;
  }
}

Future<List<String>> _readManifest(File file) async {
  try {
    if (!await file.exists()) return const [];
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is Map && decoded['segments'] is List) {
      return (decoded['segments'] as List).map((e) => e.toString()).toList();
    }
  } catch (_) {
    // Corrupt manifest: treat as a changed fingerprint.
  }
  return const [];
}

Future<void> _clearFragments(Directory dir) async {
  try {
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final name =
          entity.uri.pathSegments.isEmpty ? '' : entity.uri.pathSegments.last;
      if (name.startsWith('seg_') ||
          name.startsWith('key_') ||
          name.startsWith('init_') ||
          name.startsWith('partial.m3u8') ||
          name == 'index.m3u8.tmp') {
        try {
          await entity.delete();
        } catch (_) {
          // Best-effort.
        }
      }
    }
  } catch (_) {
    // Best-effort.
  }
}

bool _sameList(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

String _extFor(String url, {String fallback = '.ts'}) {
  final uri = Uri.tryParse(url);
  final path = uri?.path ?? '';
  final dot = path.lastIndexOf('.');
  if (dot < 0 || dot == path.length - 1) return fallback;
  final ext = path.substring(dot).toLowerCase();
  const known = {
    '.ts',
    '.m4s',
    '.mp4',
    '.m4v',
    '.aac',
    '.m4a',
    '.mkv',
    '.webm',
    '.flv',
    '.mp3',
  };
  return known.contains(ext) ? ext : fallback;
}

String _join(String a, String b) {
  if (a.endsWith(Platform.pathSeparator)) return '$a$b';
  return '$a${Platform.pathSeparator}$b';
}
