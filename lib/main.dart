import 'package:flutter/material.dart';
import 'package:fvp/fvp.dart' as fvp;

import 'app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Playback backend: route video_player through fvp (libmdk) instead of the
  // platform default (ExoPlayer). The win here is not raw decode performance
  // (hardware MediaCodec is fine) but control over buffering: widen the queue,
  // auto-reconnect on transient HTTP errors, and cache demuxed packet ranges so
  // flaky/slow CMS sources on a weak network stall less.
  //
  // NOTE: `tunnel` is deliberately left off — it outputs the decoder straight
  // to the surface with no OpenGL texture, which would break the `VideoPlayer`
  // texture widget and the danmaku overlay composited on top. Hardware decoding
  // is on by default, so we don't force `video.decoders`.
  fvp.registerWith(options: {
    // DeX on this box outputs 1080p. Cap the GL texture at 1080p so a 4K
    // source does not pay for a 4K GPU copy; decoding still uses the hardware
    // decoder at the source resolution.
    'maxWidth': 1920,
    'maxHeight': 1080,
    'player': {
      // Rebuffer only when the queue drops below 3s; keep filling up to 90s
      // ahead. A larger max rides out longer network dips without a visible
      // stall. Note max only reads further ahead in the background — it does
      // NOT delay start (playback begins once min is buffered), so keeping min
      // at 3s preserves snappy startup / live channel zapping.
      'buffer': '3000+90000',
      // Media unloads after this long without data. The default is 10s, which
      // is short for slow CMS origins answering the first range request; 20s
      // avoids a premature "unload" without hanging forever on a dead source.
      'timeout': '20000',
      // Cache demuxed http(s) byte ranges so a re-watch / small seek doesn't
      // re-download. 32 ranges is cheap in RAM (a 6 GB device) and covers more
      // seek-back positions than the default 16.
      'demux.buffer.ranges': '32',
      'demux.max_errors': '100',
      // Auto-reconnect on dropped/again HTTP reads (FFmpeg http-protocol opts
      // passed via the avio.* prefix) so a brief network hiccup resumes instead
      // of stalling the whole stream. fvp already enables reconnect by default;
      // these extend it to network-level errors and cap the total retry window.
      'avio.reconnect': '1',
      'avio.reconnect_streamed': '1',
      'avio.reconnect_on_network_error': '1',
      'avio.reconnect_delay_max': '5',
      'avio.reconnect_delay_total_max': '60',
      // Abort a hung read after 15s (FFmpeg uses microseconds) instead of
      // blocking the demuxer until the player's overall timeout.
      'avio.rw_timeout': '15000000',
    },
  });
  // Target: low-end Android TV boxes (Android < 10, ~2 GB RAM). Keep the
  // in-memory image cache SMALL so we never OOM — a large cache would evict the
  // OS's whole app before it evicts a poster. 60 MB / 200 entries holds a couple
  // of screens of TMDB artwork; anything off-screen is re-fetched from the HTTP
  // layer rather than kept resident. Do not raise these on this hardware.
  final imageCache = PaintingBinding.instance.imageCache;
  imageCache.maximumSizeBytes = 60 << 20; // 60 MB
  imageCache.maximumSize = 200;
  runApp(const NebulaApp());
}
