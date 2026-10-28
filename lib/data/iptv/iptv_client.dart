import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'iptv_models.dart';
import 'iptv_parser.dart';
import 'iptv_probe.dart';

/// Fetches an IPTV playlist over HTTP and parses it into channels. Modelled on
/// [CmsClient]: an 8s timeout and best-effort semantics — any failure (timeout,
/// non-2xx, decode error) degrades silently to an empty list so a dead source
/// never throws into the UI. No proxy fallback (skipped per product decision).
class IptvClient {
  IptvClient({http.Client? client, Duration? timeout})
      : _client = client ?? http.Client(),
        _timeout = timeout ?? const Duration(seconds: 8);

  final http.Client _client;
  final Duration _timeout;

  void close() => _client.close();

  /// Fetch [source]'s playlist and parse it. Returns [] on any failure.
  Future<List<IptvChannel>> fetchChannels(IptvSource source) async {
    if (source.url.isEmpty) return const [];
    // A source pointing at a media file is misconfigured; say so without
    // pulling megabytes of video down first.
    if (namesStaticMediaFile(source.url)) return const [];
    try {
      final res = await _client
          .send(http.Request('GET', Uri.parse(source.url)))
          .timeout(_timeout);
      if (res.statusCode < 200 || res.statusCode >= 300) return const [];
      final bytes =
          await readCapped(res.stream, maxPlaylistBytes).timeout(_timeout);
      // Playlists carry Chinese channel names; decode as UTF-8 explicitly
      // rather than trusting the (often absent) charset header.
      return parseM3u(utf8.decode(bytes, allowMalformed: true), source.id);
    } catch (_) {
      // Silent degrade: a dead playlist must not break the live page.
      return const [];
    }
  }

  /// Fetch [url]'s HLS manifest for on-demand channel diagnosis. Returns null
  /// when it can't be reached or doesn't answer 2xx — which the probe reads as
  /// "unreachable". Best-effort: never throws.
  ///
  /// A URL whose extension names a media file is answered from the URL alone
  /// ([namesStaticMediaFile]) — 22 of the shipped playlist's channels are
  /// `.mp4`/`.flv` and never need to be fetched.
  ///
  /// Otherwise streamed rather than `Client.get`, because a channel URL is
  /// frequently *not* a playlist — see [maxManifestBytes]. `get` would buffer
  /// an endless video stream until the heap died.
  Future<ManifestInfo?> probeManifest(String url) async {
    if (url.isEmpty) return null;
    if (namesStaticMediaFile(url)) return notAPlaylist;
    try {
      final res = await _client
          .send(http.Request('GET', Uri.parse(url)))
          .timeout(_timeout);
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final bytes =
          await readCapped(res.stream, maxManifestBytes).timeout(_timeout);
      return parseManifestInfo(utf8.decode(bytes, allowMalformed: true));
    } catch (_) {
      return null;
    }
  }
}
