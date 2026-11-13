import 'dart:convert';

import 'package:hive_flutter/hive_flutter.dart';

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

/// Hive-backed store (box `downloads`, one JSON string per key). All IO is
/// best-effort: if the Hive channel is absent (tests) or fails to open, the
/// records simply stay in memory.
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
    await _box?.put(key, value);
  }

  @override
  Future<void> delete(String key) async {
    await _box?.delete(key);
  }
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
      : _persistence = persistence ?? HiveDownloadPersistence();

  static const _taskPrefix = 'task:';
  static const _groupPrefix = 'group:';
  static const _settingPrefix = 'setting:';

  final DownloadPersistence _persistence;

  final Map<String, DownloadTask> _tasks = {};
  final Map<String, VodDetail> _snapshots = {};
  final Map<String, String> _settings = {};

  List<DownloadTask> get tasks => List.unmodifiable(_tasks.values);

  VodDetail? snapshot(String groupKey) => _snapshots[groupKey];

  /// Small manager preferences (e.g. the concurrency setting).
  String? setting(String key) => _settings[key];

  Future<void> saveSetting(String key, String value) async {
    _settings[key] = value;
    await _persistence.put('$_settingPrefix$key', value);
  }

  Future<void> init() async {
    await _persistence.init();
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
    _tasks[task.id] = task;
    await _persistence.put('$_taskPrefix${task.id}', jsonEncode(task.toJson()));
  }

  Future<void> deleteTask(String id) async {
    _tasks.remove(id);
    await _persistence.delete('$_taskPrefix$id');
  }

  Future<void> saveSnapshot(VodDetail detail) async {
    _snapshots[detail.key] = detail;
    await _persistence.put(
        '$_groupPrefix${detail.key}', jsonEncode(detail.toJson()));
  }

  Future<void> deleteSnapshot(String groupKey) async {
    _snapshots.remove(groupKey);
    await _persistence.delete('$_groupPrefix$groupKey');
  }
}
