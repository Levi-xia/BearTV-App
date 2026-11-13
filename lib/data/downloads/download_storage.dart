import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'download_models.dart';
import 'episode_identity.dart';
import 'local_media_server.dart';

/// On-disk layout for downloads, under the app's private support directory:
///
/// ```
/// <appSupport>/downloads/
///   <hash(sourceId:vodId)>/
///     <taskId>/
///       index.m3u8        HLS entry (written last, atomically)
///       source.m3u8       original media playlist (resume fingerprint)
///       manifest.json     segment identities for resume validation
///       seg_00001.ts ...
///       key_0.key / init_0.mp4
///       video.mp4 / video.mp4.part   direct files
/// ```
///
/// All local file names are generated here — never taken from the remote URL —
/// so a hostile playlist can't escape the task directory. Every method is
/// best-effort: when the directory is unavailable the manager simply reports
/// downloads as unavailable instead of failing app startup.
class DownloadStorage {
  DownloadStorage({Directory? root, String folder = 'downloads'})
      : _rootOverride = root,
        _folder = folder;

  static const MethodChannel _spaceChannel = MethodChannel('bear_tv/storage');

  /// Test seam: an explicit parent directory. Production leaves this null and
  /// [init] resolves the app-private support directory.
  final Directory? _rootOverride;
  final String _folder;

  Directory? _root;

  /// The free-space probe runs whenever the downloads page opens; report a
  /// missing/broken channel once instead of on every refresh.
  bool _spaceFailureLogged = false;

  /// Optional loopback transport owned by [DownloadManager]. When present the
  /// player gets an `http://127.0.0.1` URL instead of `file://`.
  LocalMediaServer? mediaServer;

  bool get available => _root != null;

  Directory? get root => _root;

  Future<void> init() async {
    if (_root != null) return;
    try {
      final base = _rootOverride ?? await getApplicationSupportDirectory();
      final dir = Directory(_join(base.path, _folder));
      await dir.create(recursive: true);
      _root = dir;
    } catch (_) {
      _root = null;
    }
  }

  /// Free bytes on the volume that holds the downloads, or null when the
  /// platform can't answer (tests, desktop, a failed channel call). Native side
  /// is `MainActivity.freeBytes` — `File.usableSpace` on Android.
  Future<int?> freeBytes() async {
    final dir = _root;
    if (dir == null) return null;
    try {
      final bytes = await _spaceChannel
          .invokeMethod<int>('freeBytes', {'path': dir.path});
      return (bytes == null || bytes <= 0) ? null : bytes;
    } catch (e) {
      // Usually a native build that predates the `bear_tv/storage` channel
      // (hot reload updates Dart but not MainActivity), so the header would
      // just show "剩余 —" with no clue why. Log it in debug builds.
      assert(() {
        if (!_spaceFailureLogged) {
          _spaceFailureLogged = true;
          debugPrint('freeBytes(${dir.path}) failed: $e');
        }
        return true;
      }());
      return null;
    }
  }

  /// Per-resource directory (劇 + 来源). Null when storage is unavailable.
  Directory? groupDir(String groupKey) {
    final r = _root;
    if (r == null) return null;
    return Directory(_join(r.path, fnv1aHex(groupKey)));
  }

  /// Per-episode directory. Null when storage is unavailable.
  Directory? taskDir(DownloadTask task) {
    final g = groupDir(task.groupKey);
    if (g == null) return null;
    return Directory(_join(g.path, task.id));
  }

  Future<Directory?> ensureTaskDir(DownloadTask task) async {
    final dir = taskDir(task);
    if (dir == null) return null;
    try {
      await dir.create(recursive: true);
      return dir;
    } catch (_) {
      return null;
    }
  }

  /// Entry file for a completed task: `index.m3u8` for HLS, `video.mp4` for a
  /// direct download.
  String entryNameFor(DownloadTask task) {
    if (task.relativePath.isNotEmpty) return task.relativePath;
    return task.isHls || task.episodeUrl.toLowerCase().contains('.m3u8')
        ? 'index.m3u8'
        : 'video.mp4';
  }

  File? entryFile(DownloadTask task) {
    final dir = taskDir(task);
    if (dir == null) return null;
    return File(_join(dir.path, entryNameFor(task)));
  }

  /// Whether the completed task's entry file still exists and is non-empty.
  bool isComplete(DownloadTask task) {
    final f = entryFile(task);
    try {
      return f != null && f.existsSync() && f.lengthSync() > 0;
    } catch (_) {
      return false;
    }
  }

  /// Playback URLs for a task whose file is present, best transport first.
  ///
  /// The loopback HTTP server is preferred: the native player opens remote
  /// playlists reliably, while `file://` local HLS proved fragile on the TV
  /// boxes (it failed to resolve local segment URIs). `file://` is kept as the
  /// fallback for when the socket can't be bound.
  List<String> localUrls(DownloadTask task) {
    if (!isComplete(task)) return const [];
    final f = entryFile(task);
    if (f == null) return const [];
    final out = <String>[];
    final served = mediaServer?.urlForFile(f);
    if (served != null) out.add(served);
    out.add(Uri.file(f.path).toString());
    return out;
  }

  /// First local playback URL, or null when the file is gone.
  String? localUrl(DownloadTask task) {
    final urls = localUrls(task);
    return urls.isEmpty ? null : urls.first;
  }

  Future<void> deleteTask(DownloadTask task) async {
    final dir = taskDir(task);
    if (dir == null) return;
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {
      // Best-effort: a stuck file is cleared by the next completion check.
    }
  }

  Future<void> deleteGroup(String groupKey) async {
    final dir = groupDir(groupKey);
    if (dir == null) return;
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {
      // Best-effort.
    }
  }

  /// Total bytes currently used by downloads.
  Future<int> totalSize() async {
    final r = _root;
    if (r == null) return 0;
    try {
      if (!await r.exists()) return 0;
      var sum = 0;
      await for (final e in r.list(recursive: true, followLinks: false)) {
        if (e is File) {
          try {
            sum += await e.length();
          } catch (_) {
            // Ignore files that vanished mid-walk.
          }
        }
      }
      return sum;
    } catch (_) {
      return 0;
    }
  }
}

String _join(String a, String b) {
  if (a.endsWith(Platform.pathSeparator)) return '$a$b';
  return '$a${Platform.pathSeparator}$b';
}
