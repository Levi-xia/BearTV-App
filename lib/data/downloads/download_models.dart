import '../models.dart';
import '../vod/cms_models.dart';
import 'episode_identity.dart';

/// Lifecycle of one downloaded episode.
///
/// `failed` deliberately stays in the 下载中 list so the user can retry it;
/// partially downloaded segments are kept and resumed.
enum DownloadStatus { queued, downloading, paused, completed, failed }

/// "Download these episodes of the current play line", produced by the play
/// page's download sheet.
class DownloadRequest {
  final VodItem item;
  final VodDetail detail;
  final int lineIndex;
  final List<int> episodeIndices;

  const DownloadRequest({
    required this.item,
    required this.detail,
    required this.lineIndex,
    required this.episodeIndices,
  });
}

/// One episode download. Immutable; the manager replaces records via
/// [copyWith] and persists JSON.
class DownloadTask {
  final String id;

  /// [VodItem.key] of the title card the download was started from. Used to
  /// find cached episodes for a title even when the CMS-direct key differs.
  final String itemKey;

  /// Display snapshot for the download manager (poster/title/source).
  final VodItem item;

  final String sourceId;
  final String sourceName;
  final String vodId;
  final String lineName;
  final int lineIndex;
  final int episodeIndex;
  final String episodeTitle;
  final String episodeUrl;

  final DownloadStatus status;

  /// HLS: completed/total segments. Direct files: 0/0.
  final int doneSegments;
  final int totalSegments;

  /// Bytes written / total when known (Content-Length or completed total).
  final int receivedBytes;
  final int totalBytes;

  final String error;

  /// HLS: duration of the contiguous downloaded prefix — how much of the
  /// episode can already be played from disk (边下边播). 0 when unknown and on
  /// direct-file downloads, which can't be played before they finish.
  final int playableMs;

  /// Path relative to the task directory (`index.m3u8` or `video.mp4`), empty
  /// until the download completes.
  final String relativePath;
  final bool isHls;
  final int variantBandwidth;
  final int durationMs;
  final int createdAt;
  final int updatedAt;

  const DownloadTask({
    required this.id,
    required this.itemKey,
    required this.item,
    required this.sourceId,
    required this.sourceName,
    required this.vodId,
    this.lineName = '',
    this.lineIndex = 0,
    this.episodeIndex = 0,
    this.episodeTitle = '',
    required this.episodeUrl,
    this.status = DownloadStatus.queued,
    this.doneSegments = 0,
    this.totalSegments = 0,
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.error = '',
    this.playableMs = 0,
    this.relativePath = '',
    this.isHls = false,
    this.variantBandwidth = 0,
    this.durationMs = 0,
    this.createdAt = 0,
    this.updatedAt = 0,
  });

  /// Aggregation identity: 剧 + 资源来源 (the resource, not the title card).
  String get groupKey => '$sourceId:$vodId';

  bool get isComplete => status == DownloadStatus.completed;
  bool get isRunning => status == DownloadStatus.downloading;
  bool get isQueued => status == DownloadStatus.queued;
  bool get needsRetry => status == DownloadStatus.failed;

  /// Ordering used when several records describe the same episode: a completed
  /// copy always wins over an in-flight/paused/failed one.
  int get priority => switch (status) {
        DownloadStatus.completed => 4,
        DownloadStatus.downloading => 3,
        DownloadStatus.queued => 2,
        DownloadStatus.paused => 1,
        DownloadStatus.failed => 0,
      };

  /// 0..1 for the progress bar. HLS counts finished segments; direct files use
  /// bytes when the server reported a total.
  double get progress {
    if (isComplete) return 1;
    if (totalSegments > 0) {
      return (doneSegments / totalSegments).clamp(0.0, 1.0);
    }
    if (totalBytes > 0) {
      return (receivedBytes / totalBytes).clamp(0.0, 1.0);
    }
    return 0;
  }

  DownloadTask copyWith({
    String? id,
    String? itemKey,
    VodItem? item,
    String? sourceId,
    String? sourceName,
    String? vodId,
    String? lineName,
    int? lineIndex,
    int? episodeIndex,
    String? episodeTitle,
    String? episodeUrl,
    DownloadStatus? status,
    int? doneSegments,
    int? totalSegments,
    int? receivedBytes,
    int? totalBytes,
    String? error,
    int? playableMs,
    String? relativePath,
    bool? isHls,
    int? variantBandwidth,
    int? durationMs,
    int? createdAt,
    int? updatedAt,
  }) =>
      DownloadTask(
        id: id ?? this.id,
        itemKey: itemKey ?? this.itemKey,
        item: item ?? this.item,
        sourceId: sourceId ?? this.sourceId,
        sourceName: sourceName ?? this.sourceName,
        vodId: vodId ?? this.vodId,
        lineName: lineName ?? this.lineName,
        lineIndex: lineIndex ?? this.lineIndex,
        episodeIndex: episodeIndex ?? this.episodeIndex,
        episodeTitle: episodeTitle ?? this.episodeTitle,
        episodeUrl: episodeUrl ?? this.episodeUrl,
        status: status ?? this.status,
        doneSegments: doneSegments ?? this.doneSegments,
        totalSegments: totalSegments ?? this.totalSegments,
        receivedBytes: receivedBytes ?? this.receivedBytes,
        totalBytes: totalBytes ?? this.totalBytes,
        error: error ?? this.error,
        playableMs: playableMs ?? this.playableMs,
        relativePath: relativePath ?? this.relativePath,
        isHls: isHls ?? this.isHls,
        variantBandwidth: variantBandwidth ?? this.variantBandwidth,
        durationMs: durationMs ?? this.durationMs,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'itemKey': itemKey,
        'item': item.toJson(),
        'sourceId': sourceId,
        'sourceName': sourceName,
        'vodId': vodId,
        'lineName': lineName,
        'lineIndex': lineIndex,
        'episodeIndex': episodeIndex,
        'episodeTitle': episodeTitle,
        'episodeUrl': episodeUrl,
        'status': status.name,
        'doneSegments': doneSegments,
        'totalSegments': totalSegments,
        'receivedBytes': receivedBytes,
        'totalBytes': totalBytes,
        'error': error,
        'playableMs': playableMs,
        'relativePath': relativePath,
        'isHls': isHls,
        'variantBandwidth': variantBandwidth,
        'durationMs': durationMs,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };

  factory DownloadTask.fromJson(Map<String, dynamic> j) => DownloadTask(
        id: (j['id'] as String?) ?? '',
        itemKey: (j['itemKey'] as String?) ?? '',
        item: VodItem.fromJson(Map<String, dynamic>.from(j['item'] as Map)),
        sourceId: (j['sourceId'] as String?) ?? '',
        sourceName: (j['sourceName'] as String?) ?? '',
        vodId: (j['vodId'] as String?) ?? '',
        lineName: (j['lineName'] as String?) ?? '',
        lineIndex: (j['lineIndex'] as int?) ?? 0,
        episodeIndex: (j['episodeIndex'] as int?) ?? 0,
        episodeTitle: (j['episodeTitle'] as String?) ?? '',
        episodeUrl: (j['episodeUrl'] as String?) ?? '',
        status: DownloadStatus.values.firstWhere(
          (s) => s.name == j['status'],
          orElse: () => DownloadStatus.paused,
        ),
        doneSegments: (j['doneSegments'] as int?) ?? 0,
        totalSegments: (j['totalSegments'] as int?) ?? 0,
        receivedBytes: (j['receivedBytes'] as int?) ?? 0,
        totalBytes: (j['totalBytes'] as int?) ?? 0,
        error: (j['error'] as String?) ?? '',
        playableMs: (j['playableMs'] as int?) ?? 0,
        relativePath: (j['relativePath'] as String?) ?? '',
        isHls: (j['isHls'] as bool?) ?? false,
        variantBandwidth: (j['variantBandwidth'] as int?) ?? 0,
        durationMs: (j['durationMs'] as int?) ?? 0,
        createdAt: (j['createdAt'] as int?) ?? 0,
        updatedAt: (j['updatedAt'] as int?) ?? 0,
      );
}

/// A download manager row: one resource (剧 + 来源) with its episode tasks.
class DownloadGroup {
  final String key;
  final VodItem item;
  final String sourceId;
  final String sourceName;

  /// Full online detail snapshot taken at enqueue time. Cached playback uses it
  /// as `currentDetail`, so line/episode indices match history even offline.
  final VodDetail snapshot;

  final List<DownloadTask> tasks;

  const DownloadGroup({
    required this.key,
    required this.item,
    required this.sourceId,
    required this.sourceName,
    required this.snapshot,
    required this.tasks,
  });

  int get completedCount =>
      tasks.where((t) => t.status == DownloadStatus.completed).length;

  int get totalCount => tasks.length;

  bool get isActive => tasks.any((t) =>
      t.status == DownloadStatus.downloading ||
      t.status == DownloadStatus.queued);

  int get totalBytes => tasks.fold(0, (sum, t) => sum + t.receivedBytes);

  double get progress {
    if (tasks.isEmpty) return 0;
    final sum = tasks.fold<double>(0, (s, t) => s + t.progress);
    return sum / tasks.length;
  }

  /// First playable episode (for the group's 播放 action), preferring the
  /// lowest episode index so the row starts at the beginning.
  DownloadTask? get firstCompleted {
    DownloadTask? best;
    for (final t in tasks) {
      if (t.status != DownloadStatus.completed) continue;
      if (best == null || t.episodeIndex < best.episodeIndex) best = t;
    }
    return best;
  }
}

/// A resolved play target: the group's resource + the episode to open.
///
/// [task] is the episode's download record when one exists — its status (done,
/// downloading, paused) decides how the play page transports it. It is null for
/// an episode of the group that was never downloaded (e.g. the recorded episode
/// of a resource the user only downloaded other episodes from); the play page
/// then opens [lineIndex]/[episodeIndex] online from the same snapshot.
class DownloadLaunch {
  final DownloadGroup group;
  final DownloadTask? task;
  final int lineIndex;
  final int episodeIndex;

  const DownloadLaunch({
    required this.group,
    this.task,
    this.lineIndex = 0,
    this.episodeIndex = 0,
  });
}

/// A still-downloading episode whose finished prefix can start playing now
/// (边下边播). [playableMs] is the downloaded prefix's duration, i.e. how far
/// the local playback can go before the online stream takes over.
class PartialPlayback {
  final DownloadTask task;
  final List<String> urls;
  final int playableMs;

  const PartialPlayback({
    required this.task,
    required this.urls,
    required this.playableMs,
  });
}

/// Stable id for one episode download. Title-first so a line/episode reorder
/// doesn't duplicate an existing download; index only when the title is empty.
String downloadTaskId({
  required String sourceId,
  required String vodId,
  String? episodeTitle,
  String? episodeUrl,
  int? episodeIndex,
}) {
  final title = normalizeEpisodeTitle(episodeTitle ?? '');
  final identity = title.isNotEmpty
      ? title
      : (episodeUrlPath(episodeUrl ?? '').isNotEmpty
          ? episodeUrlPath(episodeUrl!)
          : 'idx:${episodeIndex ?? 0}');
  return fnv1aHex('$sourceId|$vodId|$identity');
}

/// Build the task records for one [DownloadRequest]. Episodes with an empty URL
/// are skipped (nothing to download).
List<DownloadTask> tasksForRequest(
  DownloadRequest request, {
  required int nowMs,
}) {
  final d = request.detail;
  if (request.lineIndex < 0 || request.lineIndex >= d.playLines.length) {
    return const [];
  }
  final line = d.playLines[request.lineIndex];
  final tasks = <DownloadTask>[];
  for (final idx in request.episodeIndices) {
    if (idx < 0 || idx >= line.episodes.length) continue;
    final ep = line.episodes[idx];
    if (ep.url.trim().isEmpty) continue;
    final id = downloadTaskId(
      sourceId: d.sourceId,
      vodId: d.vodId,
      episodeTitle: ep.title,
      episodeUrl: ep.url,
      episodeIndex: idx,
    );
    tasks.add(DownloadTask(
      id: id,
      itemKey: request.item.key,
      item: request.item,
      sourceId: d.sourceId,
      sourceName: d.sourceName,
      vodId: d.vodId,
      lineName: line.name,
      lineIndex: request.lineIndex,
      episodeIndex: idx,
      episodeTitle: ep.title,
      episodeUrl: ep.url,
      createdAt: nowMs,
      updatedAt: nowMs,
    ));
  }
  return tasks;
}
