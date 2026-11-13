/// On-demand diagnosis of a single IPTV channel's HLS manifest.
///
/// The player never rewrites, seeks or resumes a live stream, so when a channel
/// "always shows the same thing" the cause is always the source. This turns a
/// channel's manifest into a verdict the UI can show the moment a channel is
/// picked — no persisted state, nothing swept in the background.
///
/// Three failure classes, all present in the shipped playlist:
///   • [LiveVerdict.dead]   — the host is gone (timeout / non-2xx / DNS).
///   • [LiveVerdict.vod]    — a finished file served as a channel: `ENDLIST` or
///     `PLAYLIST-TYPE:VOD`. 湖南卫视 is a 2.9h Kuaishou video, 2096 segments,
///     `MEDIA-SEQUENCE:0`, `Cache-Control: max-age=259200`.
///   • [LiveVerdict.frozen] — a structurally valid live playlist whose origin
///     encoder died: `MEDIA-SEQUENCE` never moves. 浙江卫视 sits at
///     `PROGRAM-DATE-TIME` 2025-12-30 while its CDN happily re-serves it.
///
/// [LiveVerdict.frozen] is the only class that needs a second look, and waiting
/// for one costs a sample gap the viewer has to sit through — which channel
/// surfing never allows. So the playlist's own `#EXT-X-PROGRAM-DATE-TIME` is
/// checked first: it dates the newest segment, needs no waiting, and an origin
/// that stopped appending long ago carries a timestamp to match. The second
/// sample still runs, so an origin that is genuinely rolling clears itself.
///
/// Kept pure (no I/O) because the project has no HTTP mocking infrastructure —
/// every network decision lives behind a pure function that tests can drive.
library;

import 'dart:async';
import 'dart:typed_data';

/// What the probe concluded about a channel. [checking] is the transient state
/// while the probe is in flight.
enum LiveVerdict { checking, live, vod, frozen, dead }

extension LiveVerdictX on LiveVerdict {
  /// True for the three source-side faults — used to pick the badge colour.
  bool get faulty =>
      this == LiveVerdict.vod ||
      this == LiveVerdict.frozen ||
      this == LiveVerdict.dead;

  /// Short chip label for the player's badge slot (which reads "LIVE" when the
  /// signal is genuinely live).
  String get label => switch (this) {
        LiveVerdict.checking => '检测中',
        LiveVerdict.live => 'LIVE',
        LiveVerdict.vod => '非直播源',
        LiveVerdict.frozen => '信号中断',
        LiveVerdict.dead => '无法连接',
      };

  /// One-line explanation, shown in the poster when the player has nothing to
  /// render — so a broken channel stops looking like an eternal "缓冲中…".
  String get reason => switch (this) {
        LiveVerdict.checking => '正在检测信号…',
        LiveVerdict.live => '直播信号正常',
        LiveVerdict.vod => '该地址不是直播流（点播文件）',
        LiveVerdict.frozen => '直播信号已中断（源站无更新）',
        LiveVerdict.dead => '该频道无法连接',
      };
}

final RegExp _extM3u =
    RegExp(r'^#EXTM3U', caseSensitive: false, multiLine: true);
final RegExp _endList =
    RegExp(r'^#EXT-X-ENDLIST', caseSensitive: false, multiLine: true);
final RegExp _vodType = RegExp(r'^#EXT-X-PLAYLIST-TYPE:\s*VOD',
    caseSensitive: false, multiLine: true);
final RegExp _mediaSeq = RegExp(r'^#EXT-X-MEDIA-SEQUENCE:\s*(\d+)',
    caseSensitive: false, multiLine: true);
final RegExp _targetDur = RegExp(r'^#EXT-X-TARGETDURATION:\s*(\d+)',
    caseSensitive: false, multiLine: true);
final RegExp _progDateTime = RegExp(r'^#EXT-X-PROGRAM-DATE-TIME:\s*(\S+)',
    caseSensitive: false, multiLine: true);

/// The handful of facts we need from one manifest fetch. Everything else in a
/// (possibly 200KB / 2000-segment) playlist is discarded immediately — only one
/// of these is ever alive at a time, which is the point.
class ManifestInfo {
  /// Whether the body is an HLS playlist at all. A plain `.mp4` served under a
  /// channel's URL decodes to garbage here and yields false — which is itself
  /// the answer.
  final bool isPlaylist;

  /// `#EXT-X-ENDLIST` or `#EXT-X-PLAYLIST-TYPE:VOD`: a finished file.
  final bool isVod;

  /// `#EXT-X-MEDIA-SEQUENCE`. Advances as a live origin appends segments.
  final int? mediaSequence;

  /// Last segment URI in the playlist — the fallback signal for origins that
  /// omit `MEDIA-SEQUENCE`.
  final String? lastSegment;

  /// `#EXT-X-TARGETDURATION`, in seconds: how often a conformant live origin
  /// appends a segment. Drives how long the second sample must wait (see
  /// [frozenSampleGap]).
  final int? targetDuration;

  /// Wall-clock time of the playlist's *newest* segment, from
  /// `#EXT-X-PROGRAM-DATE-TIME`. Null for the many origins that emit no such
  /// tag — most of the shipped playlist, including every healthy channel
  /// sampled. See [programDateTimeAge].
  final DateTime? programDateTime;

  const ManifestInfo({
    required this.isPlaylist,
    required this.isVod,
    this.mediaSequence,
    this.lastSegment,
    this.targetDuration,
    this.programDateTime,
  });
}

/// Parse [body] into the facts needed to judge it. Never throws; malformed or
/// non-playlist input degrades to "not a playlist".
ManifestInfo parseManifestInfo(String body) {
  if (body.isEmpty) return notAPlaylist;
  final seq = _mediaSeq.firstMatch(body);
  final target = _targetDur.firstMatch(body);
  String? lastSegment;
  for (final raw in body.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    lastSegment = line;
  }
  return ManifestInfo(
    isPlaylist: _extM3u.hasMatch(body),
    isVod: _endList.hasMatch(body) || _vodType.hasMatch(body),
    mediaSequence: seq == null ? null : int.tryParse(seq.group(1)!),
    lastSegment: lastSegment,
    targetDuration: target == null ? null : int.tryParse(target.group(1)!),
    programDateTime: _newestProgramDateTime(body),
  );
}

/// The *last* `#EXT-X-PROGRAM-DATE-TIME` in [body].
///
/// The tag dates the segment that follows it, so a playlist carrying one per
/// segment (a DVR window) would date the live edge with its last entry, not its
/// first. Both of the shipped playlist's dead origins emit a single tag on the
/// head segment, where first and last coincide.
DateTime? _newestProgramDateTime(String body) {
  DateTime? newest;
  for (final m in _progDateTime.allMatches(body)) {
    // Dart's parser accepts the `+0800` form these origins use, alongside
    // `Z` and `+08:00`. An unparseable stamp is simply no signal.
    final t = DateTime.tryParse(m.group(1)!);
    if (t == null) continue;
    if (newest == null || t.isAfter(newest)) newest = t;
  }
  return newest;
}

/// Upper bound on the wait between samples, so a bogus `#EXT-X-TARGETDURATION`
/// can't stall a probe indefinitely.
const Duration maxFrozenSampleGap = Duration(seconds: 90);

/// How long to wait before taking the second sample of [info].
///
/// A conformant live origin appends a segment every `#EXT-X-TARGETDURATION`
/// seconds, so waiting *twice* that guarantees the sequence has had to move —
/// which is what stops a long-segment channel from being wrongly called frozen.
/// Most sources declare 4–8s, where [fallback] is already generous; this only
/// extends the wait for the slow ones. Playlists that declare no target keep
/// [fallback].
Duration frozenSampleGap(ManifestInfo info, Duration fallback) {
  final t = info.targetDuration;
  if (t == null || t <= 0) return fallback;
  final needed = Duration(seconds: t * 2);
  if (needed <= fallback) return fallback;
  return needed > maxFrozenSampleGap ? maxFrozenSampleGap : needed;
}

/// How far behind wall clock a playlist's newest `#EXT-X-PROGRAM-DATE-TIME` may
/// sit before the origin is presumed dead.
///
/// A live stream's newest segment is seconds old, and even a generously sized
/// DVR window puts the live edge under a couple of minutes back — so an hour is
/// roughly 30× the worst honest case. It is set high because the two failure
/// modes are not symmetric: a threshold that is too tight invents a fault on a
/// working channel (the origin's clock merely drifted), while one that is too
/// loose only means a long-dead origin keeps its `LIVE` badge until the second
/// sample lands.
///
/// Swept over the shipped 544-channel playlist: 75 channels emit the tag at all,
/// and 29 of those are fresh and correctly left live — so this discriminates
/// rather than merely flagging "has a timestamp". The 46 it calls stale were
/// every one of them confirmed non-rolling on a re-sample 20s later.
const Duration maxProgramDateTimeLag = Duration(hours: 1);

/// How long ago the newest segment of [info] was dated, or null when the
/// playlist carries no `#EXT-X-PROGRAM-DATE-TIME` (the common case).
///
/// A stamp in the future reads as zero rather than as a negative age: an
/// origin whose clock runs fast is not evidence of anything.
Duration? programDateTimeAge(ManifestInfo info, DateTime now) {
  final t = info.programDateTime;
  if (t == null) return null;
  final age = now.difference(t);
  return age.isNegative ? Duration.zero : age;
}

/// Whether [info]'s newest segment is dated too long ago to be live. False when
/// the playlist has no timestamp to judge — absence is not evidence.
bool staleProgramDateTime(ManifestInfo info, DateTime now) {
  final age = programDateTimeAge(info, now);
  return age != null && age > maxProgramDateTimeLag;
}

/// Whether two samples prove the playlist is being rewritten. Null when they
/// carry nothing comparable.
bool? _moved(ManifestInfo first, ManifestInfo second) {
  // `MEDIA-SEQUENCE` is the reliable signal; the last segment URI covers
  // origins that omit it. Either one moving means the stream is alive, so this
  // can't cry wolf on a slow-rolling stream that only emits one of the two.
  if (first.mediaSequence != null && second.mediaSequence != null) {
    if (first.mediaSequence != second.mediaSequence) return true;
    if (first.lastSegment != null && second.lastSegment != null) {
      return first.lastSegment != second.lastSegment;
    }
    return false;
  }
  if (first.lastSegment != null && second.lastSegment != null) {
    return first.lastSegment != second.lastSegment;
  }
  return null;
}

/// Judge a channel from one or two manifest samples.
///
/// [first] is null when the URL could not be fetched at all. [second] is a
/// second sample taken [LiveProbeController.defaultSampleGap] later; when it is
/// absent the channel is given the benefit of the doubt, so a transient hiccup
/// never reads as "broken". [now] is injectable for tests.
LiveVerdict decideVerdict({
  ManifestInfo? first,
  ManifestInfo? second,
  DateTime? now,
}) {
  if (first == null) return LiveVerdict.dead;
  if (!first.isPlaylist || first.isVod) return LiveVerdict.vod;

  // Observed movement outranks every timestamp: an origin appending segments is
  // serving live video whatever its clock says.
  if (second != null) {
    final moved = _moved(first, second);
    if (moved != null) {
      return moved ? LiveVerdict.live : LiveVerdict.frozen;
    }
  }

  // No second sample yet, or the two carry nothing comparable — fall back on
  // the timestamp, which settles 浙江卫视 and the rest of the cztv.com family
  // on the first fetch instead of after a sample gap nobody waits out.
  return staleProgramDateTime(first, now ?? DateTime.now())
      ? LiveVerdict.frozen
      : LiveVerdict.live;
}

/// The answer for a URL that cannot be an HLS playlist — either because its
/// extension names a media file ([namesStaticMediaFile]) or because the fetch
/// returned something that isn't a playlist. [decideVerdict] reads it as
/// [LiveVerdict.vod].
const ManifestInfo notAPlaylist = ManifestInfo(isPlaylist: false, isVod: false);

/// Container extensions that name a *file*. None of these can be an HLS
/// playlist, so a channel URL ending in one is settled from the URL alone —
/// no request, and the answer is the same one a fetch would have produced.
///
/// `.ts` is deliberately absent: it is as much a live-transport stream as a
/// recording, and the fetch settles it either way.
const Set<String> _staticMediaExtensions = {
  'mp4',
  'm4v',
  'mkv',
  'avi',
  'mov',
  'wmv',
  'webm',
  'flv',
  'mpg',
  'mpeg',
  'rmvb',
  '3gp',
  'ogv',
  'mp3',
  'm4a',
  'aac',
  'flac',
  'wav',
  'ogg',
};

/// Whether [url] names a static media file rather than a stream manifest.
///
/// Judged on the last path segment with the query and fragment already stripped
/// by [Uri], so `…/show.mp4?token=x` and `…/show.MP4` both count, while a host
/// that merely looks like one (`http://1.2.3.4:8080/live`) does not.
bool namesStaticMediaFile(String url) {
  final path = Uri.tryParse(url)?.path;
  if (path == null) return false;
  final segments = path.split('/').where((s) => s.isNotEmpty);
  if (segments.isEmpty) return false;
  final name = segments.last;
  final dot = name.lastIndexOf('.');
  if (dot < 0) return false;
  return _staticMediaExtensions.contains(name.substring(dot + 1).toLowerCase());
}

// --- Bounded reads -----------------------------------------------------------
//
// A channel URL is not always a playlist, and reading one with `Client.get`
// buffers it to completion. The shipped playlist carries direct `.mp4` entries
// (2004年春晚) and `live.metshop.top` channels that answer with an endless video
// stream — either one grows the heap until the app dies, which is how it went
// down on a real box:
//
//   Exhausted heap space, trying to allocate 536870944 bytes.
//   #0 _ByteCallbackSink.add (dart:convert/byte_conversion.dart:78:19)
//   #14 _HttpParser._doParse (dart:_http/http_parser.dart:923:28)
//
// So every body is read through [readCapped], which stops pulling at a ceiling
// far below anything real and cancels the socket.

/// Ceiling on how much of a *channel* URL is read while diagnosing it.
///
/// 1 MB is ~8× the largest real manifest here: 湖南卫视's 2096-segment Kuaishou
/// playlist, which is the biggest thing in the shipped source at ~126 KB.
const int maxManifestBytes = 1024 * 1024;

/// Ceiling on how much of a *playlist* URL is read. Larger than
/// [maxManifestBytes] because a source is entitled to a long channel list, but
/// still bounded so a misconfigured source can't take the app down. The shipped
/// playlist is 122 KB.
const int maxPlaylistBytes = 4 * 1024 * 1024;

/// Read at most [cap] bytes from [stream], then stop pulling.
///
/// Breaking out of the loop cancels the subscription, which drops the socket —
/// so a live video stream is cut off after one buffer instead of downloaded to
/// completion. Never throws: a truncated read, or a transport error part-way
/// through, still yields whatever arrived, because the head of a playlist is
/// enough to judge it.
Future<List<int>> readCapped(Stream<List<int>> stream, int cap) async {
  final out = BytesBuilder(copy: false);
  try {
    await for (final chunk in stream) {
      final room = cap - out.length;
      if (chunk.length >= room) {
        out.add(chunk.sublist(0, room));
        break; // the rest is video we never wanted
      }
      out.add(chunk);
    }
  } catch (_) {
    // Judge what arrived; a mid-stream failure is not a parse failure.
  }
  return out.takeBytes();
}
