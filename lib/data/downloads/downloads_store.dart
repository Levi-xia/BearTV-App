import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';

import '../vod/cms_models.dart';
import 'download_models.dart';

/// Key/value persistence seam for download records. Production uses Hive,
/// tests use [MemoryDownloadPersistence]; both behave identically from the
/// manager's point of view.
abstract class DownloadPersistence {
  Future<void> init();
  Map<String, String> readAll();
  Future<void> put(String key, String value);
  Future<void> delete(String key);
}

/// Hive-backed store. Failures must reach the manager rather than silently
/// accepting downloads whose records cannot be saved.
class HiveDownloadPersistence implements DownloadPersistence {
  static const _boxName = 'downloads';

  /// Shared with [HistoryStore]'s flag in spirit: `Hive.initFlutter()` must run
  /// once, and [AppController.init] awaits history before downloads, so this is
  /// only a safety net for direct use.
  static bool _hiveReady = false;

  Box<String>? _box;

  @override
  Future<void> init() async {
    try {
      if (!_hiveReady) {
        await Hive.initFlutter();
        _hiveReady = true;
      }
      _box = await Hive.openBox<String>(_boxName);
    } catch (_) {
      _box = null;
      rethrow;
    }
  }

  @override
  Map<String, String> readAll() {
    final box = _box;
    if (box == null) return const {};
    return {for (final k in box.keys) k.toString(): box.get(k) ?? ''};
  }

  @override
  Future<void> put(String key, String value) async {
    final box = _box;
    if (box == null) throw StateError('下载记录数据库未打开');
    await box.put(key, value);
    await box.flush();
  }

  @override
  Future<void> delete(String key) async {
    final box = _box;
    if (box == null) throw StateError('下载记录数据库未打开');
    await box.delete(key);
    await box.flush();
  }
}

/// Independent per-record copies survive loss of the Hive index. Kept outside
/// media directories so resuming/deleting fragments cannot erase metadata.
/// Writes are serialized; replacing a record never deletes the old file first.
class RecoverableDownloadPersistence implements DownloadPersistence {
  RecoverableDownloadPersistence(this.primary, {Directory? directory})
      : _directory = directory;

  final DownloadPersistence primary;
  Directory? _directory;
  final Map<String, String> _records = {};
  final Set<String> _deleted = {};
  Future<void> _pending = Future.value();

  @override
  Future<void> init() async {
    _directory ??= Directory(
        '${(await getApplicationSupportDirectory()).path}/download_records');
    await _directory!.create(recursive: true);
    await for (final file in _directory!.list(followLinks: false)) {
      if (file is! File || !file.path.endsWith('.json')) continue;
      try {
        final record = jsonDecode(await file.readAsString()) as Map;
        final key = record['key'] as String;
        if (_file(key).path != file.path) continue;
        if (record['value'] == null) {
          _deleted.add(key);
        } else {
          _records[key] = record['value'] as String;
        }
      } catch (e) {
        debugPrint('[downloads] invalid recovery record ${file.path}: $e');
      }
    }
    // If opening Hive fails, readAll still exposes the recovered copies.
    await primary.init();
    final existing = primary.readAll();
    // Recovery records are written before Hive, so they take precedence.
    final toMigrate = Map<String, String>.fromEntries(existing.entries.where(
        (entry) =>
            !_records.containsKey(entry.key) && !_deleted.contains(entry.key)));
    _records.addAll(toMigrate);
    for (final entry in toMigrate.entries) {
      await _writeCopy(entry.key, entry.value);
    }
  }

  File _file(String key) {
    final name = base64Url.encode(utf8.encode(key));
    return File('${_directory!.path}/$name.json');
  }

  Future<void> _writeCopy(String key, String? value) async {
    final target = _file(key);
    final temp = File('${target.path}.tmp');
    await temp.writeAsString(jsonEncode({'key': key, 'value': value}),
        flush: true);
    await temp.rename(target.path);
  }

  Future<void> _serialize(Future<void> Function() action) {
    final operation = _pending.then((_) => action());
    _pending =
        operation.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return operation;
  }

  @override
  Map<String, String> readAll() => Map.unmodifiable(_records);

  @override
  Future<void> put(String key, String value) => _serialize(() async {
        await _writeCopy(key, value);
        _deleted.remove(key);
        _records[key] = value;
        await primary.put(key, value);
      });

  @override
  Future<void> delete(String key) => _serialize(() async {
        // Persist deletion before touching Hive. A power cut between the two
        // writes must not resurrect a deliberately removed download.
        await _writeCopy(key, null);
        _deleted.add(key);
        _records.remove(key);
        await primary.delete(key);
      });
}

/// In-memory persistence for tests.
class MemoryDownloadPersistence implements DownloadPersistence {
  MemoryDownloadPersistence([Map<String, String>? seed]) : _values = {...?seed};

  final Map<String, String> _values;

  @override
  Future<void> init() async {}

  @override
  Map<String, String> readAll() => Map.unmodifiable(_values);

  @override
  Future<void> put(String key, String value) async => _values[key] = value;

  @override
  Future<void> delete(String key) async => _values.remove(key);
}

/// Download tasks + per-resource [VodDetail] snapshots.
///
/// Keys: `task:<id>` for episodes, `group:<sourceId>:<vodId>` for the full
/// detail snapshot of a resource (so cached playback works offline and
/// line/episode indices stay aligned with history).
class DownloadsStore {
  DownloadsStore({DownloadPersistence? persistence})
      : _persistence = persistence ??
            RecoverableDownloadPersistence(HiveDownloadPersistence());

  static const _taskPrefix = 'task:';
  static const _groupPrefix = 'group:';
  static const _settingPrefix = 'setting:';

  final DownloadPersistence _persistence;
  String? error;
  bool get available => error == null;

  final Map<String, DownloadTask> _tasks = {};
  final Map<String, VodDetail> _snapshots = {};
  final Map<String, String> _settings = {};

  List<DownloadTask> get tasks => List.unmodifiable(_tasks.values);

  VodDetail? snapshot(String groupKey) => _snapshots[groupKey];

  /// Small manager preferences (e.g. the concurrency setting).
  String? setting(String key) => _settings[key];

  Future<void> saveSetting(String key, String value) async {
    await _write(() => _persistence.put('$_settingPrefix$key', value));
    _settings[key] = value;
  }

  Future<void> init() async {
    error = null;
    try {
      await _persistence.init();
    } catch (e, stack) {
      error = '下载记录读取失败，已暂停下载，请重启应用后重试';
      debugPrint('[downloads] persistence init failed: $e\n$stack');
    }
    _tasks.clear();
    _snapshots.clear();
    _settings.clear();
    for (final entry in _persistence.readAll().entries) {
      try {
        if (entry.key.startsWith(_settingPrefix)) {
          _settings[entry.key.substring(_settingPrefix.length)] = entry.value;
          continue;
        }
        final decoded = jsonDecode(entry.value);
        if (decoded is! Map) continue;
        final map = Map<String, dynamic>.from(decoded);
        if (entry.key.startsWith(_taskPrefix)) {
          final task = DownloadTask.fromJson(map);
          if (task.id.isNotEmpty) _tasks[task.id] = task;
        } else if (entry.key.startsWith(_groupPrefix)) {
          final detail = VodDetail.fromJson(map);
          if (detail.sourceId.isNotEmpty && detail.vodId.isNotEmpty) {
            _snapshots[detail.key] = detail;
          }
        }
      } catch (_) {
        // Skip a corrupt record rather than failing the whole load.
      }
    }
  }

  Future<void> saveTask(DownloadTask task) async {
    await _write(() =>
        _persistence.put('$_taskPrefix${task.id}', jsonEncode(task.toJson())));
    _tasks[task.id] = task;
  }

  Future<void> deleteTask(String id) async {
    await _write(() => _persistence.delete('$_taskPrefix$id'));
    _tasks.remove(id);
  }

  Future<void> saveSnapshot(VodDetail detail) async {
    await _write(() => _persistence.put(
        '$_groupPrefix${detail.key}', jsonEncode(detail.toJson())));
    _snapshots[detail.key] = detail;
  }

  Future<void> deleteSnapshot(String groupKey) async {
    await _write(() => _persistence.delete('$_groupPrefix$groupKey'));
    _snapshots.remove(groupKey);
  }

  Future<void> _write(Future<void> Function() action) async {
    if (!available) throw StateError(error!);
    try {
      await action();
    } catch (e, stack) {
      error = '下载记录保存失败，已暂停下载，请检查剩余空间并重启应用';
      debugPrint('[downloads] persistence write failed: $e\n$stack');
      rethrow;
    }
  }
}
