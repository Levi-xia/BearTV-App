import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/format.dart';
import '../history_store.dart';
import '../models.dart';
import '../vod/cms_models.dart';
import 'download_engine.dart';
import 'download_foreground.dart';
import 'download_models.dart';
import 'download_storage.dart';
import 'downloads_store.dart';
import 'episode_identity.dart';
import 'local_media_server.dart';
import 'm3u8_parser.dart';

/// Owns the download queue, task state and on-disk files.
///
/// Up to [concurrency] tasks download at once (default 3, user-selectable 1/3/
/// 5/10 on the downloads page). Every mutation is persisted best-effort; the
/// in-memory map is authoritative for the UI.
class DownloadManager extends ChangeNotifier {
  DownloadManager({
    DownloadsStore? store,
    DownloadStorage? storage,
    DownloadEngine? engine,
    DateTime Function()? clock,
    Future<int?> Function()? freeSpaceProbe,
    DownloadForeground? foreground,
  })  : _store = store ?? DownloadsStore(),
        storage = storage ?? DownloadStorage(),
        _engine = engine ?? HttpDownloadEngine(),
        _clock = clock ?? DateTime.now,
        _freeSpaceProbe = freeSpaceProbe,
        _foreground = foreground ?? defaultDownloadForeground();

  /// Concurrency choices offered on the downloads page.
  static const concurrencyOptions = [1, 3, 5, 10];
  static const defaultConcurrency = 3;

  /// Never queue a download when the volume would be left with less than this
  /// much room — a full disk corrupts in-flight writes and breaks the app's
  /// own caches (history, settings, update APKs).
  static const reserveBytes = 512 * 1024 * 1024;

  /// Minimum downloaded prefix before 边下边播 starts — about a minute of
  /// content, enough that playback doesn't immediately reach the frontier.
  static const minPartialMs = 60 * 1000;

  final DownloadsStore _store;
  final DownloadStorage storage;
  final DownloadEngine _engine;
  final DateTime Function() _clock;

  /// Android foreground service that keeps the process alive while the queue
  /// has work (see [DownloadForeground]).
  final DownloadForeground _foreground;

  /// Overrides [DownloadStorage.freeBytes] in tests.
  final Future<int?> Function()? _freeSpaceProbe;

  final Map<String, DownloadTask> _tasks = {};
  final Map<String, DownloadCancelToken> _tokens = {};

  /// Loopback media transport for cached playback (see [LocalMediaServer]).
  LocalMediaServer? _mediaServer;

  /// Tasks deleted while their engine run is still unwinding. Their files are
  /// removed once the run exits, so a late write can't resurrect them.
  final Set<String> _removed = {};

  /// Ids paused automatically when the app went to the background; resumed when
  /// it comes back (if still paused).
  final Set<String> _autoPaused = {};

  /// Whether the keep-alive service is up. False on platforms without one and
  /// when the system refused to start it.
  bool _foregroundOn = false;
  bool _foregroundStarting = false;

  /// Wall clock of the last notification push, so progress refreshes stay at
  /// ~1 Hz even though the UI updates much faster.
  int _foregroundPushedAt = 0;

  /// Don't hammer the platform after it refused to start the service.
  int _foregroundRetryAt = 0;
  static const foregroundPushIntervalMs = 1000;
  static const foregroundRetryIntervalMs = 30000;
  static const _foregroundTitle = '熊熊TV · 后台下载';

  final Stopwatch _notifyWatch = Stopwatch()..start();

  bool _initialized = false;
  bool _disposed = false;
  bool _available = false;

  /// How many tasks may download at once. Persisted as `setting:concurrency`.
  int _concurrency = defaultConcurrency;

  /// Number of engine runs in flight right now.
  int _running = 0;

  /// Last reported free space on the downloads volume (null = unknown).
  int? _freeSpaceBytes;

  /// Latest speed reading per in-flight task, smoothed across progress events.
  final Map<String, _Speed> _speeds = {};

  /// A task with no progress for this long reports 0 B/s, so the UI doesn't
  /// keep showing a stale figure after the connection dies.
  static const speedStaleMs = 5000;

  int get _nowMs => _clock().millisecondsSinceEpoch;

  bool get available => _initialized && _available;

  /// Tasks allowed to download simultaneously (1 / 3 / 5 / 10).
  int get concurrency => _concurrency;

  /// Free bytes on the downloads volume, as of the last [refreshFreeSpace].
  int? get freeSpaceBytes => _freeSpaceBytes;

  /// Episodes transferring right now — the tasks the speed figures cover.
  int get runningCount =>
      _tasks.values.where((t) => t.status == DownloadStatus.downloading).length;

  /// Aggregate speed of all in-flight downloads, in bytes per second.
  int get totalSpeed {
    final now = _nowMs;
    var sum = 0.0;
    for (final task in _tasks.values) {
      if (task.status != DownloadStatus.downloading) continue;
      sum += _speedFor(task.id, now);
    }
    return sum.round();
  }

  /// Speed of one 剧 + 来源 group in bytes per second (0 when it isn't
  /// downloading).
  int groupSpeed(String groupKey) {
    final now = _nowMs;
    var sum = 0.0;
    for (final task in _tasks.values) {
      if (task.status != DownloadStatus.downloading) continue;
      if (task.groupKey != groupKey) continue;
      sum += _speedFor(task.id, now);
    }
    return sum.round();
  }

  /// Fold a progress event into the task's speed. HLS reports once per
  /// segment, so the instantaneous rate is exponentially smoothed: the number
  /// stays visible between segments instead of flickering to zero.
  void _recordSpeed(String id, int receivedBytes) {
    final now = _nowMs;
    final state = _speeds[id];
    if (state == null) {
      _speeds[id] = _Speed(at: now, bytes: receivedBytes, bps: 0);
      return;
    }
    final elapsed = now - state.at;
    final gained = receivedBytes - state.bytes;
    if (elapsed > 0) {
      final instant = gained > 0 ? gained * 1000 / elapsed : 0.0;
      state.bps = state.bps <= 0 ? instant : state.bps * 0.6 + instant * 0.4;
    }
    state.at = now;
    state.bytes = receivedBytes;
  }

  double _speedFor(String id, int now) {
    final state = _speeds[id];
    if (state == null) return 0;
    if (now - state.at > speedStaleMs) return 0;
    return state.bps;
  }

  /// Query the platform for free space and notify only when it changed. Safe
  /// to call often; returns null when the platform can't answer.
  Future<int?> refreshFreeSpace() async {
    final probe = _freeSpaceProbe ?? storage.freeBytes;
    final bytes = await probe();
    if (_disposed) return bytes;
    if (bytes != _freeSpaceBytes) {
      _freeSpaceBytes = bytes;
      _notify(force: true);
    }
    return bytes;
  }

  /// Persist + apply a new concurrency. Extra slots start queued work at once;
  /// lowering it never cancels an in-flight task (it just stops starting new
  /// ones until the count drops).
  Future<void> setConcurrency(int value) async {
    if (!concurrencyOptions.contains(value) || value == _concurrency) return;
    _concurrency = value;
    await _store.saveSetting('concurrency', '$value');
    _notify(force: true);
    _pump();
  }

  int get activeCount => _tasks.values
      .where((t) =>
          t.status == DownloadStatus.queued ||
          t.status == DownloadStatus.downloading ||
          t.status == DownloadStatus.paused ||
          t.status == DownloadStatus.failed)
      .length;

  int get completedCount =>
      _tasks.values.where((t) => t.status == DownloadStatus.completed).length;

  /// 下载中 list: queued/downloading/paused/failed, oldest first.
  List<DownloadTask> get activeTasks {
    final list = _tasks.values
        .where((t) => t.status != DownloadStatus.completed)
        .toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return List.unmodifiable(list);
  }

  /// 已完成 list, most recently finished first.
  List<DownloadTask> get completedTasks {
    final list = _tasks.values
        .where((t) => t.status == DownloadStatus.completed)
        .toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return List.unmodifiable(list);
  }

  /// Groups by 剧 + 资源来源, most recently touched first.
  List<DownloadGroup> get groups {
    final byKey = <String, List<DownloadTask>>{};
    for (final task in _tasks.values) {
      byKey.putIfAbsent(task.groupKey, () => []).add(task);
    }
    final out = <DownloadGroup>[];
    for (final entry in byKey.entries) {
      final tasks = entry.value
        ..sort((a, b) => a.episodeIndex.compareTo(b.episodeIndex));
      final first = tasks.first;
      final snapshot =
          _store.snapshot(entry.key) ?? _synthesizeSnapshot(entry.key, tasks);
      out.add(DownloadGroup(
        key: entry.key,
        item: first.item,
        sourceId: first.sourceId,
        sourceName: first.sourceName,
        snapshot: snapshot,
        tasks: List.unmodifiable(tasks),
      ));
    }
    // Newest download first, but keyed on creation time — progress updates
    // bump `updatedAt` constantly, and sorting on that made cards jump around
    // while downloading. A card only rises when an episode is added to it.
    out.sort((a, b) {
      final au =
          a.tasks.fold<int>(0, (m, t) => t.createdAt > m ? t.createdAt : m);
      final bu =
          b.tasks.fold<int>(0, (m, t) => t.createdAt > m ? t.createdAt : m);
      final byCreation = bu.compareTo(au);
      return byCreation != 0 ? byCreation : a.key.compareTo(b.key);
    });
    return List.unmodifiable(out);
  }

  DownloadGroup? groupForTask(String taskId) {
    final task = _tasks[taskId];
    if (task == null) return null;
    for (final g in groups) {
      if (g.key == task.groupKey) return g;
    }
    return null;
  }

  Future<void> init() async {
    await _store.init();
    await storage.init();
    _available = storage.available;
    final savedConcurrency = int.tryParse(_store.setting('concurrency') ?? '');
    if (savedConcurrency != null &&
        concurrencyOptions.contains(savedConcurrency)) {
      _concurrency = savedConcurrency;
    }
    await _startMediaServer();

    for (final stored in _store.tasks) {
      var task = stored;
      // A queued/downloading record survived a process kill: keep the partial
      // files, but pause until the user resumes.
      if (task.status == DownloadStatus.queued ||
          task.status == DownloadStatus.downloading) {
        task = task.copyWith(
          status: DownloadStatus.paused,
          updatedAt: _nowMs,
        );
      }
      // A completed record whose file vanished (user cleanup, uninstall of an
      // old build, corrupt write) must not masquerade as a cache hit.
      if (task.status == DownloadStatus.completed &&
          !storage.isComplete(task)) {
        await _store.deleteTask(task.id);
        continue;
      }
      _tasks[task.id] = task;
      if (!identical(task, stored)) await _store.saveTask(task);
    }
    _initialized = true;
    _notify(force: true);
  }

  /// Bind the loopback transport for cached playback. Failure is harmless —
  /// [DownloadStorage.localUrls] then just hands the player `file://` URLs.
  Future<void> _startMediaServer() async {
    final root = storage.root;
    if (!_available || root == null || _mediaServer != null) return;
    final server = await LocalMediaServer.start(root);
    if (server == null) return;
    if (_disposed) {
      await server.close();
      return;
    }
    _mediaServer = server;
    storage.mediaServer = server;
  }

  // --- Enqueue / queue ------------------------------------------------------

  /// Add the requested episodes. Returns how many new/requeued tasks were
  /// added; already completed or in-flight episodes are skipped.
  Future<int> enqueue(DownloadRequest request) async {
    if (!available) throw const DownloadException('存储不可用，无法下载');
    final tasks = tasksForRequest(request, nowMs: _nowMs);
    if (tasks.isEmpty) throw const DownloadException('没有可下载的剧集');

    // Keep a safety margin on the volume: a full disk corrupts the partial
    // segments and starves the rest of the app.
    final free = await refreshFreeSpace();
    if (free != null && free < reserveBytes) {
      throw DownloadException(
        '存储空间不足：剩余 ${formatBytes(free)}，'
        '至少需预留 ${formatBytes(reserveBytes)}',
      );
    }

    await _store.saveSnapshot(request.detail);

    var added = 0;
    for (final task in tasks) {
      final existing = _tasks[task.id];
      if (existing != null) {
        if (existing.status == DownloadStatus.completed ||
            existing.status == DownloadStatus.queued ||
            existing.status == DownloadStatus.downloading) {
          continue;
        }
        final requeued = existing.copyWith(
          status: DownloadStatus.queued,
          error: '',
          updatedAt: _nowMs,
        );
        _tasks[task.id] = requeued;
        await _store.saveTask(requeued);
        added++;
        continue;
      }
      _tasks[task.id] = task;
      await _store.saveTask(task);
      added++;
    }
    _notify(force: true);
    if (added > 0) _pump();
    return added;
  }

  void _pump() {
    if (_disposed || !_available) return;
    while (_running < _concurrency) {
      DownloadTask? next;
      for (final task in _tasks.values) {
        if (task.status != DownloadStatus.queued) continue;
        if (next == null || task.createdAt < next.createdAt) next = task;
      }
      if (next == null) return;
      _running++;
      unawaited(_run(next));
    }
  }

  Future<void> _run(DownloadTask task) async {
    final cancel = DownloadCancelToken();
    _tokens[task.id] = cancel;
    var current = task.copyWith(
      status: DownloadStatus.downloading,
      error: '',
      updatedAt: _nowMs,
    );
    _tasks[task.id] = current;
    await _store.saveTask(current);
    // Baseline for the speed read-out, so the first progress event measures a
    // real delta instead of looking like a burst from zero.
    _speeds[task.id] = _Speed(at: _nowMs, bytes: current.receivedBytes, bps: 0);
    _notify(force: true);

    final persistWatch = Stopwatch()..start();
    void onProgress(DownloadProgress p) {
      final t = _tasks[task.id];
      if (t == null || t.status != DownloadStatus.downloading) return;
      _recordSpeed(task.id, p.receivedBytes);
      final next = t.copyWith(
        doneSegments: p.doneSegments,
        totalSegments: p.totalSegments,
        receivedBytes: p.receivedBytes,
        totalBytes: p.totalBytes,
        playableMs: p.playableMs,
        durationMs: p.totalMs > 0 ? p.totalMs : t.durationMs,
        updatedAt: _nowMs,
      );
      _tasks[task.id] = next;
      if (persistWatch.elapsedMilliseconds > 2000) {
        persistWatch.reset();
        unawaited(_store.saveTask(next));
      }
      _notify();
    }

    try {
      final result = await _engine.run(
        current,
        storage,
        cancel: cancel,
        onProgress: onProgress,
      );
      if (_disposed) return;
      if (_removed.contains(task.id)) {
        await _deleteFilesAndRecord(task);
        return;
      }
      final done = (_tasks[task.id] ?? current).copyWith(
        status: DownloadStatus.completed,
        relativePath: result.relativePath,
        isHls: result.isHls,
        receivedBytes: result.bytes,
        totalBytes: result.bytes,
        doneSegments: result.totalSegments,
        totalSegments: result.totalSegments,
        durationMs: result.durationMs,
        playableMs: result.durationMs,
        variantBandwidth: result.bandwidth,
        error: '',
        updatedAt: _nowMs,
      );
      _tasks[task.id] = done;
      await _store.saveTask(done);
      unawaited(refreshFreeSpace());
    } on DownloadCancelled {
      final t = _tasks[task.id];
      if (t != null && t.status == DownloadStatus.downloading) {
        final paused = t.copyWith(status: DownloadStatus.paused);
        _tasks[task.id] = paused;
        await _store.saveTask(paused);
      }
    } on M3u8Exception catch (e) {
      await _fail(task, e.message);
    } on DownloadException catch (e) {
      await _fail(task, e.message);
    } catch (e) {
      await _fail(task, '下载失败：$e');
    } finally {
      _tokens.remove(task.id);
      _speeds.remove(task.id);
      if (_removed.remove(task.id)) {
        await _deleteFilesAndRecord(task);
      }
      _running--;
      if (!_disposed) {
        _notify(force: true);
        _pump();
      }
    }
  }

  Future<void> _fail(DownloadTask task, String message) async {
    if (_disposed || _removed.contains(task.id)) return;
    final t = _tasks[task.id];
    if (t == null) return;
    final failed = t.copyWith(
      status: DownloadStatus.failed,
      error: message,
      updatedAt: _nowMs,
    );
    _tasks[task.id] = failed;
    await _store.saveTask(failed);
  }

  Future<void> _deleteFilesAndRecord(DownloadTask task) async {
    _tasks.remove(task.id);
    await _store.deleteTask(task.id);
    await storage.deleteTask(task);
    unawaited(refreshFreeSpace());
  }

  // --- User actions ---------------------------------------------------------

  Future<void> pause(String id) async {
    final task = _tasks[id];
    if (task == null) return;
    if (task.status == DownloadStatus.downloading) {
      _tokens[id]?.cancel();
    } else if (task.status != DownloadStatus.queued) {
      return;
    }
    final paused = task.copyWith(status: DownloadStatus.paused);
    _tasks[id] = paused;
    await _store.saveTask(paused);
    _notify(force: true);
  }

  Future<void> resume(String id) async {
    final task = _tasks[id];
    if (task == null || !_available) return;
    if (task.status != DownloadStatus.paused &&
        task.status != DownloadStatus.failed) {
      return;
    }
    final queued = task.copyWith(
      status: DownloadStatus.queued,
      error: '',
      updatedAt: _nowMs,
    );
    _tasks[id] = queued;
    await _store.saveTask(queued);
    _notify(force: true);
    _pump();
  }

  Future<void> pauseAll() async {
    for (final task in _tasks.values.toList()) {
      if (task.status == DownloadStatus.downloading ||
          task.status == DownloadStatus.queued) {
        await pause(task.id);
      }
    }
  }

  /// Resume every paused/failed task — the counterpart of [pauseAll]. The UI
  /// button doesn't need to know which tasks are resumable.
  Future<void> resumeAll() async {
    for (final task in _tasks.values.toList()) {
      if (task.status == DownloadStatus.paused ||
          task.status == DownloadStatus.failed) {
        await resume(task.id);
      }
    }
  }

  /// Remove one episode (and its files). Returns the removed task so the
  /// controller can fall back to online playback if it was playing.
  Future<DownloadTask?> remove(String id) async {
    final task = _tasks.remove(id);
    if (task == null) return null;
    _removed.add(id);
    _tokens[id]?.cancel();
    await _store.deleteTask(id);
    _notify(force: true);
    if (!_tokens.containsKey(id)) {
      await storage.deleteTask(task);
      _removed.remove(id);
      unawaited(refreshFreeSpace());
    }
    return task;
  }

  Future<void> removeGroup(String groupKey) async {
    final ids = [
      for (final t in _tasks.values)
        if (t.groupKey == groupKey) t.id,
    ];
    for (final id in ids) {
      await remove(id);
    }
    await _store.deleteSnapshot(groupKey);
    _notify(force: true);
  }

  Future<void> clearCompleted() async {
    final ids = [
      for (final t in _tasks.values)
        if (t.status == DownloadStatus.completed) t.id,
    ];
    for (final id in ids) {
      await remove(id);
    }
  }

  // --- Cache lookup ---------------------------------------------------------

  /// Current record for [id] — the play page polls this while 边下边播 to see
  /// how far the downloaded prefix has grown.
  DownloadTask? taskById(String id) => _tasks[id];

  /// Stored detail snapshot for a resource (used as an offline fallback when the
  /// CMS detail request fails).
  VodDetail? snapshotFor(String sourceId, String vodId) =>
      sourceId.isEmpty || vodId.isEmpty
          ? null
          : _store.snapshot('$sourceId:$vodId');

  VodDetail? snapshotForEntry(HistoryEntry? entry) {
    if (entry == null) return null;
    return snapshotFor(entry.sourceId, entry.vodId);
  }

  /// Snapshot of any group belonging to [itemKey]. 下载管理 can open a show that
  /// was downloaded but never watched, so there is no playback record to supply
  /// a source id — this keeps such a show playable offline.
  VodDetail? snapshotForItem(String itemKey) {
    DownloadGroup? best;
    for (final g in groups) {
      if (g.item.key != itemKey) continue;
      // Prefer the group with the most finished episodes: it is the one the
      // user is most likely to watch.
      if (best == null || g.completedCount > best.completedCount) best = g;
    }
    return best?.snapshot;
  }

  /// Any task (queued/downloading/paused/failed/completed) for an episode,
  /// matched by URL/path/title with an index fallback. Used by the download
  /// sheet to label cells (「已下载」「下载中」) and disable re-adds.
  DownloadTask? taskForEpisode({
    required String sourceId,
    required String vodId,
    String? episodeUrl,
    String? episodeTitle,
    int? episodeIndex,
  }) {
    final groupKey = '$sourceId:$vodId';
    final hasIdentity = (episodeUrl ?? '').trim().isNotEmpty ||
        (episodeTitle ?? '').trim().isNotEmpty;
    DownloadTask? best;
    for (final task in _tasks.values) {
      if (task.groupKey != groupKey) continue;
      final match = hasIdentity
          ? sameEpisode(
              urlA: task.episodeUrl,
              titleA: task.episodeTitle,
              urlB: episodeUrl,
              titleB: episodeTitle,
            )
          : task.episodeIndex == episodeIndex;
      if (!match) continue;
      // Prefer a richer state (completed / running) over a stale failed one.
      if (best == null || task.priority > best.priority) best = task;
    }
    return best;
  }

  /// Completed task for the current play page episode. Matches by URL/path/
  /// title, falling back to the index only when the caller has no identity.
  DownloadTask? completedTaskFor({
    required String sourceId,
    required String vodId,
    String? episodeUrl,
    String? episodeTitle,
    int? episodeIndex,
  }) {
    final groupKey = '$sourceId:$vodId';
    final hasIdentity = (episodeUrl ?? '').trim().isNotEmpty ||
        (episodeTitle ?? '').trim().isNotEmpty;
    for (final task in _tasks.values) {
      if (task.groupKey != groupKey || !task.isComplete) continue;
      if (!storage.isComplete(task)) continue;
      final match = hasIdentity
          ? sameEpisode(
              urlA: task.episodeUrl,
              titleA: task.episodeTitle,
              urlB: episodeUrl,
              titleB: episodeTitle,
            )
          : task.episodeIndex == episodeIndex;
      if (match) return task;
    }
    return null;
  }

  /// Local playback URLs for a cached episode, best transport first (loopback
  /// HTTP, then `file://`). Empty when the episode has no usable local copy.
  List<String> localUrlsFor({
    required String sourceId,
    required String vodId,
    String? episodeUrl,
    String? episodeTitle,
    int? episodeIndex,
  }) {
    final task = completedTaskFor(
      sourceId: sourceId,
      vodId: vodId,
      episodeUrl: episodeUrl,
      episodeTitle: episodeTitle,
      episodeIndex: episodeIndex,
    );
    return task == null ? const [] : storage.localUrls(task);
  }

  /// A still-downloading episode whose finished prefix can be watched now
  /// (边下边播). Only HLS tasks qualify: a partial `video.mp4` is not seekable
  /// and its moov atom may still be missing.
  ///
  /// The prefix must be at least [minPartialMs] long and its `partial.m3u8`
  /// must exist — that playlist is written as segments land and is what the
  /// player reads. Paused tasks qualify too: after an app restart a task is
  /// paused, yet the prefix on disk is perfectly playable.
  PartialPlayback? partialFor({
    required String sourceId,
    required String vodId,
    String? episodeUrl,
    String? episodeTitle,
    int? episodeIndex,
  }) {
    final task = taskForEpisode(
      sourceId: sourceId,
      vodId: vodId,
      episodeUrl: episodeUrl,
      episodeTitle: episodeTitle,
      episodeIndex: episodeIndex,
    );
    if (task == null) return null;
    if (task.status != DownloadStatus.downloading &&
        task.status != DownloadStatus.paused) {
      return null;
    }
    if (task.playableMs < minPartialMs) return null;
    final urls = storage.partialUrls(task);
    if (urls.isEmpty) return null;
    return PartialPlayback(
      task: task,
      urls: urls,
      playableMs: task.playableMs,
    );
  }

  /// Whether the episode currently on screen is cached (drives the 已缓存 chip).
  bool isEpisodeCached({
    required String sourceId,
    required String vodId,
    String? episodeUrl,
    String? episodeTitle,
    int? episodeIndex,
  }) =>
      completedTaskFor(
        sourceId: sourceId,
        vodId: vodId,
        episodeUrl: episodeUrl,
        episodeTitle: episodeTitle,
        episodeIndex: episodeIndex,
      ) !=
      null;

  /// The cache to open for [item]. Episode-scoped by design:
  ///   • a history entry only launches when *that* episode is downloaded;
  ///   • a fresh open only when episode 0 of that group is downloaded.
  /// Never switches a whole show to a downloaded source because other episodes
  /// happen to be cached.
  DownloadLaunch? launchFor({required VodItem item, HistoryEntry? entry}) {
    final recordedGroup =
        entry == null ? null : '${entry.sourceId}:${entry.vodId}';
    final candidates = <DownloadGroup>[];
    for (final group in groups) {
      final sameTitle = group.tasks.any((t) => t.itemKey == item.key);
      final sameRecorded = recordedGroup != null && group.key == recordedGroup;
      if (sameTitle || sameRecorded) candidates.add(group);
    }
    if (candidates.isEmpty) return null;

    if (entry != null && entry.vodId.isNotEmpty) {
      for (final group in candidates) {
        final loc = locateEpisode(
          group.snapshot,
          episodeUrl: entry.episodeUrl,
          episodeTitle: entry.episodeTitle,
          episodeIndex: entry.episodeIndex,
        );
        if (loc == null) continue;
        final task =
            _completedForLocation(group, loc.lineIndex, loc.episodeIndex);
        if (task != null) return DownloadLaunch(group: group, task: task);
      }
      return null;
    }

    // Fresh open: only a cached first episode is safe to auto-select.
    for (final group in candidates) {
      final task = _completedForLocation(group, 0, 0);
      if (task != null) return DownloadLaunch(group: group, task: task);
    }
    return null;
  }

  DownloadTask? _completedForLocation(
      DownloadGroup group, int lineIndex, int episodeIndex) {
    for (final task in group.tasks) {
      if (task.status != DownloadStatus.completed) continue;
      if (task.lineIndex != lineIndex || task.episodeIndex != episodeIndex) {
        continue;
      }
      if (storage.isComplete(task)) return task;
    }
    // The snapshot may have been refreshed/reordered; fall back to identity.
    return completedTaskFor(
      sourceId: group.sourceId,
      vodId: group.snapshot.vodId,
      episodeUrl: _episodeUrlAt(group.snapshot, lineIndex, episodeIndex),
      episodeTitle: _episodeTitleAt(group.snapshot, lineIndex, episodeIndex),
    );
  }

  String? _episodeUrlAt(VodDetail detail, int line, int ep) {
    if (line < 0 || line >= detail.playLines.length) return null;
    final eps = detail.playLines[line].episodes;
    if (ep < 0 || ep >= eps.length) return null;
    return eps[ep].url;
  }

  String? _episodeTitleAt(VodDetail detail, int line, int ep) {
    if (line < 0 || line >= detail.playLines.length) return null;
    final eps = detail.playLines[line].episodes;
    if (ep < 0 || ep >= eps.length) return null;
    return eps[ep].title;
  }

  VodDetail _synthesizeSnapshot(String groupKey, List<DownloadTask> tasks) {
    final first = tasks.first;
    final byLine = <int, List<DownloadTask>>{};
    for (final task in tasks) {
      byLine.putIfAbsent(task.lineIndex, () => []).add(task);
    }
    final lines = <PlayLine>[];
    final lineIndices = byLine.keys.toList()..sort();
    for (final lineIndex in lineIndices) {
      final lineTasks = byLine[lineIndex]!
        ..sort((a, b) => a.episodeIndex.compareTo(b.episodeIndex));
      lines.add(PlayLine(
        name: lineTasks.first.lineName,
        episodes: [
          for (final t in lineTasks)
            Episode(title: t.episodeTitle, url: t.episodeUrl),
        ],
      ));
      // Keep line indices aligned with the downloaded line for history.
      while (lines.length - 1 < lineIndex) {
        lines.add(const PlayLine(name: '', episodes: []));
      }
    }
    return VodDetail(
      sourceId: first.sourceId,
      sourceName: first.sourceName,
      vodId: first.vodId,
      title: first.item.title,
      playLines: lines,
    );
  }

  // --- Lifecycle ------------------------------------------------------------

  /// Whether the Android foreground service is currently keeping the process
  /// alive for the queue.
  bool get backgroundKeepAlive => _foregroundOn;

  /// The app left the foreground. With the keep-alive service up the transfers
  /// simply continue; without one (non-Android, system refusal, old devices)
  /// pause, because a background kill would truncate an in-flight segment.
  void handleAppBackgrounded() {
    if (_foregroundOn) return;
    pauseActiveForLifecycle();
  }

  /// The app came back: resume whatever the previous backgrounding auto-paused
  /// and make sure the service reflects the queue (it may have died while the
  /// app was suspended).
  void handleAppForegrounded() {
    resumeAutoPaused();
    // A service start refused in the background deserves a retry now that the
    // app is visible again.
    _foregroundRetryAt = 0;
    _syncForeground(force: true);
  }

  /// The engine is going away (activity destroyed). Nothing can continue, so
  /// stop the service instead of leaving its notification behind.
  void handleAppDetached() {
    pauseActiveForLifecycle();
    _stopForeground();
  }

  /// Called when the app goes to the background. No foreground service means an
  /// in-flight write can be killed, so pause (keeping partial files).
  void pauseActiveForLifecycle() {
    for (final task in _tasks.values.toList()) {
      if (task.status == DownloadStatus.downloading ||
          task.status == DownloadStatus.queued) {
        _autoPaused.add(task.id);
        pause(task.id);
      }
    }
  }

  /// Called when the app comes back. Resumes only the tasks auto-paused by the
  /// previous lifecycle event (never one the user paused deliberately).
  void resumeAutoPaused() {
    final ids = _autoPaused.toList();
    _autoPaused.clear();
    for (final id in ids) {
      final task = _tasks[id];
      if (task != null && task.status == DownloadStatus.paused) {
        resume(id);
      }
    }
  }

  // --- Foreground service ---------------------------------------------------

  /// Start, refresh or stop the keep-alive service so it matches the queue:
  /// up while any task is queued/downloading, gone once everything finished,
  /// paused or failed.
  void _syncForeground({bool force = false}) {
    if (_disposed || _foregroundStarting) return;
    final busy = _tasks.values.any((t) =>
        t.status == DownloadStatus.queued ||
        t.status == DownloadStatus.downloading);
    if (!busy) {
      if (!_foregroundOn) return;
      _foregroundOn = false;
      _foregroundPushedAt = 0;
      unawaited(_foreground.stop());
      return;
    }
    final now = _nowMs;
    if (_foregroundOn) {
      if (!force && now - _foregroundPushedAt < foregroundPushIntervalMs) {
        return;
      }
      _foregroundPushedAt = now;
      unawaited(_refreshForeground());
      return;
    }
    if (now < _foregroundRetryAt) return;
    _foregroundStarting = true;
    _foregroundPushedAt = now;
    unawaited(_startForeground());
  }

  Future<void> _refreshForeground() async {
    final progress = _foregroundProgress();
    final updated = await _foreground.update(
      title: _foregroundTitle,
      text: _foregroundText(),
      progress: progress,
      max: progress == null ? null : 1000,
    );
    if (updated || _disposed || !_foregroundOn) return;
    // The service went away under us (killed with the process). Treat the queue
    // as unprotected again so backgrounding pauses instead.
    _foregroundOn = false;
    _foregroundPushedAt = 0;
  }

  Future<void> _startForeground() async {
    final progress = _foregroundProgress();
    var started = false;
    try {
      started = await _foreground.start(
        title: _foregroundTitle,
        text: _foregroundText(),
        progress: progress,
        max: progress == null ? null : 1000,
      );
    } catch (_) {
      // A service we can't start just means "pause in the background" again.
      started = false;
    }
    _foregroundStarting = false;
    if (_disposed) {
      if (started) unawaited(_foreground.stop());
      return;
    }
    _foregroundOn = started;
    if (started) {
      // The queue may have emptied while the service was starting, and the
      // first notification should carry the current progress.
      _syncForeground(force: true);
    } else {
      _foregroundRetryAt = _nowMs + foregroundRetryIntervalMs;
    }
  }

  void _stopForeground() {
    if (!_foregroundOn && !_foregroundStarting) return;
    _foregroundOn = false;
    _foregroundPushedAt = 0;
    unawaited(_foreground.stop());
  }

  /// "正在下载 2 集 · 队列中 1 集 · 3.1 MB/s" for the notification body.
  String _foregroundText() {
    var running = 0;
    var queued = 0;
    for (final t in _tasks.values) {
      if (t.status == DownloadStatus.downloading) running++;
      if (t.status == DownloadStatus.queued) queued++;
    }
    final speed = totalSpeed;
    final parts = <String>[
      if (running > 0) '正在下载 $running 集',
      if (queued > 0) '队列中 $queued 集',
      if (speed > 0) formatSpeed(speed),
    ];
    return parts.isEmpty ? '准备中' : parts.join(' · ');
  }

  /// Aggregate progress of the running tasks on a 0–1000 scale, or null while
  /// the total size is still unknown (the notification then shows a spinner).
  int? _foregroundProgress() {
    var received = 0;
    var total = 0;
    for (final t in _tasks.values) {
      if (t.status != DownloadStatus.downloading || t.totalBytes <= 0) continue;
      received += t.receivedBytes;
      total += t.totalBytes;
    }
    if (total <= 0) return null;
    final value = received * 1000 ~/ total;
    return value > 1000 ? 1000 : value;
  }

  void _notify({bool force = false}) {
    if (_disposed) return;
    // Keep the foreground service in step with the queue; it throttles its own
    // notification updates, so the fast progress stream stays cheap.
    _syncForeground(force: force);
    if (!force && _notifyWatch.elapsedMilliseconds < 200) return;
    _notifyWatch.reset();
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _stopForeground();
    for (final token in _tokens.values) {
      token.cancel();
    }
    _tokens.clear();
    _engine.dispose();
    storage.mediaServer = null;
    unawaited(_mediaServer?.close());
    _mediaServer = null;
    super.dispose();
  }
}

/// Rolling speed reading for one in-flight task.
class _Speed {
  _Speed({required this.at, required this.bytes, required this.bps});

  /// [DownloadManager._nowMs] of the last progress event.
  int at;

  /// Bytes received as of [at].
  int bytes;

  /// Smoothed bytes per second.
  double bps;
}
