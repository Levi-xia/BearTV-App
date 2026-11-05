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
      // Start once 1s is queued (not 3s — the extra wait made startup feel
      // slower than the web player, where playback begins on the first
      // fragment), then fill up to 90s ahead. Max only reads further ahead in
      // the background and does NOT delay start.
      'buffer': '1000+90000',
      // Network/unload timeout. The default is 10s; 20s made a dead or slow
      // origin hang the play page for that long before surfacing an error.
      'timeout': '10000',
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
      // Cap the whole retry window: 60s meant a source that was actually dead
      // kept the player "connecting" for a minute. 20s still rides out a real
      // hiccup, then fails fast so the user can pick another resource.
      'avio.reconnect_delay_total_max': '20',
      // Abort a hung read after 8s (FFmpeg uses microseconds) instead of
      // blocking the demuxer until the player's overall timeout.
      'avio.rw_timeout': '8000000',
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
