import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/iptv/iptv_client.dart';
import '../data/iptv/iptv_probe.dart';

/// Diagnoses the *currently selected* live channel, on demand: one channel at a
/// time, two small manifest fetches, nothing remembered.
///
/// This replaces an earlier "probe the whole playlist, cache the verdicts and
/// grey the bad channels out" design. That one OOM'd on a real TV box: it held
/// a manifest per channel and re-notified the UI every 200ms while a ~500-row,
/// deliberately *non-virtualized* channel list rebuilt (with logos) each time.
/// Here the cost is bounded by whatever the user actually clicked, and the
/// channel list is never in the rebuild path — [LiveProbeController] is its own
/// notifier precisely so that parking the verdict on [IptvController] can't
/// drag the list back in.
///
/// Diagnosis runs alongside playback, never gating it: [begin] returns
/// immediately and the verdict lands later via [notifyListeners].
class LiveProbeController extends ChangeNotifier {
  /// [client] is owned by [IptvController] (which closes it) — sharing it keeps
  /// live traffic on one connection pool.
  LiveProbeController({
    required IptvClient client,
    this.sampleGap = defaultSampleGap,
  }) : _client = client;

  /// How long to wait between the two manifest samples when hunting a frozen
  /// origin, for playlists that don't declare a `#EXT-X-TARGETDURATION` (or
  /// declare a short one). Real live playlists roll their `MEDIA-SEQUENCE`
  /// within a few target durations (typically under 30s), so a playlist that
  /// hasn't moved in this window has a dead encoder upstream. Long enough not
  /// to cry wolf on a slow origin, short enough that a viewer who parks on a
  /// channel gets an answer while still watching it. See [frozenSampleGap] for
  /// how a slow-declaring playlist extends this.
  static const Duration defaultSampleGap = Duration(seconds: 20);
  final Duration sampleGap;

  final IptvClient _client;

  LiveVerdict _verdict = LiveVerdict.checking;

  /// What the probe concluded about [url]. Starts at [LiveVerdict.checking].
  LiveVerdict get verdict => _verdict;

  /// The channel URL [verdict] describes; null until the first [begin].
  String? url;

  int _token = 0;
  bool _disposed = false;

  /// The URL the newest probe is still working on, cleared when it settles.
  /// Guards against the picker's focus-preview and its OK press both calling
  /// [begin] for the same channel: restarting there would reset the sample
  /// clock, and a viewer who OKs the row they just focused would never let the
  /// second sample land.
  String? _runningUrl;

  /// Start (or restart) diagnosis of [channelUrl]. Returns immediately — the
  /// caller loads the stream in parallel. A call for a *different* channel
  /// supersedes the one in flight, so channel surfing leaves at most one probe
  /// running.
  void begin(String channelUrl) {
    if (channelUrl == _runningUrl) return; // already diagnosing this one
    final token = ++_token;
    _runningUrl = channelUrl;
    url = channelUrl;
    _set(LiveVerdict.checking);
    unawaited(_run(channelUrl, token));
  }

  Future<void> _run(String channelUrl, int token) async {
    try {
      final first = await _client.probeManifest(channelUrl);
      if (token != _token) return; // superseded by a newer channel
      if (first == null) {
        _set(LiveVerdict.dead);
        return;
      }

      // Sample one already settles the two unambiguous classes, so publish it
      // now and let the badge be useful within a second instead of after the
      // gap. `frozen` here means a stale `#EXT-X-PROGRAM-DATE-TIME` — a hint
      // strong enough to show, but not to stop on: the second sample still
      // runs so an origin that turns out to be rolling can clear itself.
      final immediate = decideVerdict(first: first);
      _set(immediate);
      if (immediate == LiveVerdict.vod) return; // a finished file is settled

      await Future<void>.delayed(frozenSampleGap(first, sampleGap));
      if (token != _token) return;
      final second = await _client.probeManifest(channelUrl);
      if (token != _token) return;
      // A failed second fetch is transient, not evidence: keep the pass-one
      // verdict rather than flipping a working channel to "无法连接".
      if (second == null) return;
      _set(decideVerdict(first: first, second: second));
    } finally {
      if (token == _token) _runningUrl = null;
    }
  }

  void _set(LiveVerdict v) {
    if (_disposed || _verdict == v) return;
    _verdict = v;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _token++;
    super.dispose();
  }
}
