import 'dart:convert';

import 'package:hive_flutter/hive_flutter.dart';

import 'models.dart';

/// One watch-history record. Keyed by the TMDB [VodItem.key] (stable across
/// sessions) so "继续观看" and resume/skip/speed memory follow the title
/// regardless of which CMS source ends up resolving it.
///
/// Holds both the display item (for the rail) and the last CMS playback
/// reference (source/episode/position) so re-entering a title can resume the
/// same resource at the same spot.
class HistoryEntry {
  final VodItem item;
  final String sourceId;
  final String sourceName;
  final String vodId;
  final int lineIndex;
  final int episodeIndex;

  /// Identity of the episode itself (not just its index) so a cached download
  /// can be matched after a line/episode reorder. Old records read as empty.
  final String episodeTitle;
  final String episodeUrl;

  final int positionMs;
  final int durationMs;
  final int updatedAt; // epoch ms
  final bool skipEnabled;
  final int introSec;
  final int endingSec;
  final double speed;

  const HistoryEntry({
    required this.item,
    this.sourceId = '',
    this.sourceName = '',
    this.vodId = '',
    this.lineIndex = 0,
    this.episodeIndex = 0,
    this.episodeTitle = '',
    this.episodeUrl = '',
    this.positionMs = 0,
    this.durationMs = 0,
    this.updatedAt = 0,
    this.skipEnabled = false,
    this.introSec = 0,
    this.endingSec = 0,
    this.speed = 1.0,
  });

  String get key => item.key;

  /// A stable reference to the last-played CMS resource, or null if none.
  String? get resourceKey => vodId.isEmpty ? null : '$sourceId:$vodId';

  HistoryEntry copyWith({
    VodItem? item,
    String? sourceId,
    String? sourceName,
    String? vodId,
    int? lineIndex,
    int? episodeIndex,
    String? episodeTitle,
    String? episodeUrl,
    int? positionMs,
    int? durationMs,
    int? updatedAt,
    bool? skipEnabled,
    int? introSec,
    int? endingSec,
    double? speed,
  }) =>
      HistoryEntry(
        item: item ?? this.item,
        sourceId: sourceId ?? this.sourceId,
        sourceName: sourceName ?? this.sourceName,
        vodId: vodId ?? this.vodId,
        lineIndex: lineIndex ?? this.lineIndex,
        episodeIndex: episodeIndex ?? this.episodeIndex,
        episodeTitle: episodeTitle ?? this.episodeTitle,
        episodeUrl: episodeUrl ?? this.episodeUrl,
        positionMs: positionMs ?? this.positionMs,
        durationMs: durationMs ?? this.durationMs,
        updatedAt: updatedAt ?? this.updatedAt,
        skipEnabled: skipEnabled ?? this.skipEnabled,
        introSec: introSec ?? this.introSec,
        endingSec: endingSec ?? this.endingSec,
        speed: speed ?? this.speed,
      );

  Map<String, dynamic> toJson() => {
        'item': item.toJson(),
        'sourceId': sourceId,
        'sourceName': sourceName,
        'vodId': vodId,
        'lineIndex': lineIndex,
        'episodeIndex': episodeIndex,
        'episodeTitle': episodeTitle,
        'episodeUrl': episodeUrl,
        'positionMs': positionMs,
        'durationMs': durationMs,
        'updatedAt': updatedAt,
        'skipEnabled': skipEnabled,
        'introSec': introSec,
        'endingSec': endingSec,
        'speed': speed,
      };

  factory HistoryEntry.fromJson(Map<String, dynamic> j) => HistoryEntry(
        item: VodItem.fromJson(j['item'] as Map<String, dynamic>),
        sourceId: (j['sourceId'] as String?) ?? '',
        sourceName: (j['sourceName'] as String?) ?? '',
        vodId: (j['vodId'] as String?) ?? '',
        lineIndex: (j['lineIndex'] as int?) ?? 0,
        episodeIndex: (j['episodeIndex'] as int?) ?? 0,
        episodeTitle: (j['episodeTitle'] as String?) ?? '',
        episodeUrl: (j['episodeUrl'] as String?) ?? '',
        positionMs: (j['positionMs'] as int?) ?? 0,
        durationMs: (j['durationMs'] as int?) ?? 0,
        updatedAt: (j['updatedAt'] as int?) ?? 0,
        skipEnabled: (j['skipEnabled'] as bool?) ?? false,
        introSec: (j['introSec'] as int?) ?? 0,
        endingSec: (j['endingSec'] as int?) ?? 0,
        speed: (j['speed'] as num?)?.toDouble() ?? 1.0,
      );
}

/// Watch history + resume progress + per-title skip/speed memory, persisted in
/// a [Hive] box (`playback`). Each record is stored as a JSON string keyed by
/// [VodItem.key], so nested TMDB maps round-trip without Hive type-cast
/// friction. Supersedes the old `RecentStore` (which only stored the display
/// list). All IO is best-effort so it still works in-memory under
/// `flutter test` (where the Hive/path_provider channels are absent).
class HistoryStore {
  HistoryStore({this.max = 40});

  final int max;

  static const _boxName = 'playback';
  static bool _hiveReady = false;

  Box<String>? _box;

  /// Most-recent first, deduped by [VodItem.key].
  final List<HistoryEntry> _entries = [];

  List<HistoryEntry> get entries => List.unmodifiable(_entries);

  /// Display list for the 最近播放 / 继续观看 rails.
  List<VodItem> get items => [for (final e in _entries) e.item];

  HistoryEntry? entryFor(String vodKey) {
    for (final e in _entries) {
      if (e.key == vodKey) return e;
    }
    return null;
  }

  Future<void> init() async {
    try {
      if (!_hiveReady) {
        await Hive.initFlutter();
        _hiveReady = true;
      }
      _box = await Hive.openBox<String>(_boxName);
      final parsed = <HistoryEntry>[];
      for (final raw in _box!.values) {
        try {
          parsed.add(
              HistoryEntry.fromJson(jsonDecode(raw) as Map<String, dynamic>));
        } catch (_) {
          // Skip a corrupt record rather than failing the whole load.
        }
      }
      // Box iteration order isn't guaranteed; present most-recent first.
      parsed.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      _entries
        ..clear()
        ..addAll(parsed.take(max));
    } catch (_) {
      // No Hive channel (tests / unsupported host): start empty, in-memory.
      _box = null;
    }
  }

  /// Insert or update the entry for [entry.key], moving it to the front.
  void put(HistoryEntry entry) {
    _entries.removeWhere((e) => e.key == entry.key);
    final stamped =
        entry.copyWith(updatedAt: DateTime.now().millisecondsSinceEpoch);
    _entries.insert(0, stamped);

    final evicted = <String>[];
    if (_entries.length > max) {
      for (final e in _entries.sublist(max)) {
        evicted.add(e.key);
      }
      _entries.removeRange(max, _entries.length);
    }

    // Best-effort persistence; the in-memory copy stays authoritative.
    final box = _box;
    if (box != null) {
      box.put(stamped.key, jsonEncode(stamped.toJson()));
      for (final k in evicted) {
        box.delete(k);
      }
    }
  }

  /// Delete the record for [vodKey] (e.g. the user removed it from 最近播放).
  /// Returns true when something was removed. Persistence is best-effort; the
  /// in-memory list stays authoritative.
  bool remove(String vodKey) {
    final before = _entries.length;
    _entries.removeWhere((e) => e.key == vodKey);
    if (_entries.length == before) return false;
    _box?.delete(vodKey);
    return true;
  }
}
