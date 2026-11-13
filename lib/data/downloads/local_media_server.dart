import 'dart:async';
import 'dart:io';
import 'dart:math';

/// Loopback HTTP server that exposes the downloads directory to the player.
///
/// Why not `file://`: on the TV boxes the player (fvp/libmdk) opened a local
/// `index.m3u8` but failed while resolving its local segment/key URIs, so every
/// cached episode fell back to the online m3u8 with 「播放失败」. Serving the same
/// files from `127.0.0.1` routes playback through the exact network path that
/// already works for online playlists (and gives us Range support for direct
/// mp4 seeks for free).
///
/// Only files below [root] are served — the path is rebuilt from the URL
/// segments and any `.`/`..` is rejected. A random token in the first path
/// segment keeps other apps on the device from reading the private downloads
/// through the loopback port.
class LocalMediaServer {
  LocalMediaServer._(this._root, this._token);

  final Directory _root;
  final String _token;
  HttpServer? _server;

  int? get port => _server?.port;

  /// Starts on a free loopback port. Returns null when the socket can't be
  /// bound — callers then keep the `file://` transport.
  static Future<LocalMediaServer?> start(Directory root) async {
    final server = LocalMediaServer._(root, _randomToken());
    try {
      final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      http.autoCompress = false;
      server._server = http;
      http.listen(
        server._handle,
        onError: (_) {},
        cancelOnError: false,
      );
      return server;
    } catch (_) {
      return null;
    }
  }

  Future<void> close() async {
    final server = _server;
    _server = null;
    try {
      await server?.close(force: true);
    } catch (_) {
      // Already gone.
    }
  }

  /// Loopback URL for [file] when it lives under [root], else null.
  String? urlForFile(File file) {
    final port = _server?.port;
    if (port == null) return null;
    var path = file.path;
    final root = _root.path;
    if (path == root) return null;
    // Require the separator boundary: `…/downloads2/…` must not look like a
    // child of `…/downloads`.
    final prefix = root.endsWith(Platform.pathSeparator)
        ? root
        : '$root${Platform.pathSeparator}';
    if (!path.startsWith(prefix)) return null;
    path = path.substring(prefix.length);
    if (path.isEmpty) return null;
    final encoded = path
        .split(Platform.pathSeparator)
        .where((s) => s.isNotEmpty)
        .map(Uri.encodeComponent)
        .join('/');
    return 'http://127.0.0.1:$port/$_token/$encoded';
  }

  // --- HTTP ----------------------------------------------------------------

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      if (request.method != 'GET' && request.method != 'HEAD') {
        response.statusCode = HttpStatus.methodNotAllowed;
        await response.close();
        return;
      }
      final file = _resolve(request.uri.pathSegments);
      if (file == null) {
        response.statusCode = HttpStatus.notFound;
        response.contentLength = 0;
        await response.close();
        return;
      }
      await _serve(request, response, file);
    } catch (_) {
      // The player closes connections on seek/stop — never let that kill the
      // server's listen loop.
      try {
        await response.close();
      } catch (_) {}
    }
  }

  File? _resolve(List<String> segments) {
    if (segments.length < 2 || segments.first != _token) return null;
    var path = _root.path;
    for (final segment in segments.skip(1)) {
      if (segment.isEmpty ||
          segment == '.' ||
          segment == '..' ||
          segment.contains('/') ||
          segment.contains(r'\')) {
        return null;
      }
      path = '$path${Platform.pathSeparator}$segment';
    }
    try {
      final file = File(path);
      return file.existsSync() ? file : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _serve(
    HttpRequest request,
    HttpResponse response,
    File file,
  ) async {
    final total = await file.length();
    response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    response.headers.contentType = _contentType(file.path);

    var start = 0;
    var end = total - 1;
    var partial = false;

    final range = request.headers.value(HttpHeaders.rangeHeader);
    if (range != null) {
      final parsed = _parseRange(range, total);
      if (parsed == null) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$total');
        response.contentLength = 0;
        await response.close();
        return;
      }
      start = parsed.$1;
      end = parsed.$2;
      partial = true;
    }

    final length = total == 0 ? 0 : end - start + 1;
    response.statusCode = partial ? HttpStatus.partialContent : HttpStatus.ok;
    if (partial) {
      response.headers
          .set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$total');
    }
    response.contentLength = length;

    if (request.method == 'HEAD' || length == 0) {
      await response.close();
      return;
    }
    await response.addStream(file.openRead(start, end + 1));
    await response.close();
  }
}

/// `bytes=start-end` / `bytes=start-` / `bytes=-suffix` → inclusive range.
(int, int)? _parseRange(String header, int total) {
  final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(header.trim());
  if (match == null || total <= 0) return null;
  final first = match.group(1) ?? '';
  final second = match.group(2) ?? '';
  if (first.isEmpty && second.isEmpty) return null;

  int start;
  int end;
  if (first.isEmpty) {
    final suffix = int.tryParse(second);
    if (suffix == null || suffix <= 0) return null;
    start = total - suffix;
    if (start < 0) start = 0;
    end = total - 1;
  } else {
    final parsedStart = int.tryParse(first);
    if (parsedStart == null) return null;
    start = parsedStart;
    end = second.isEmpty ? total - 1 : (int.tryParse(second) ?? -1);
    if (end < 0) return null;
  }
  if (start > end || start >= total) return null;
  if (end >= total) end = total - 1;
  return (start, end);
}

ContentType _contentType(String path) {
  final dot = path.lastIndexOf('.');
  final ext = dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
  switch (ext) {
    case 'm3u8':
    case 'm3u':
      return ContentType('application', 'vnd.apple.mpegurl');
    case 'ts':
      return ContentType('video', 'mp2t');
    case 'mp4':
    case 'm4s':
    case 'm4v':
      return ContentType('video', 'mp4');
    case 'm4a':
      return ContentType('audio', 'mp4');
    case 'aac':
      return ContentType('audio', 'aac');
    case 'mp3':
      return ContentType('audio', 'mpeg');
    default:
      return ContentType('application', 'octet-stream');
  }
}

String _randomToken() {
  final random = Random.secure();
  final buffer = StringBuffer();
  for (var i = 0; i < 16; i++) {
    buffer.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}
