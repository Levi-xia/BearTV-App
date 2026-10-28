import 'package:flutter/material.dart';
import 'package:fvp/fvp.dart' as fvp;

import 'app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Playback backend: route video_player through fvp (libmdk) instead of the
  // platform default (ExoPlayer). ExoPlayer's default LoadControl keeps only a
  // tiny buffer and has no network cache, so flaky/slow CMS sources on a weak
  // TV box rebuffer constantly ("进度条白条不走"). libmdk lets us widen the
  // buffer, auto-reconnect on transient HTTP errors, and cache demuxed packets.
  //
  // NOTE: `tunnel` is deliberately left off — it outputs the decoder straight
  // to the surface with no OpenGL texture, which would break the `VideoPlayer`
  // texture widget and the danmaku overlay composited on top. Hardware decoding
  // is on by default, so we don't force `video.decoders`.
  fvp.registerWith(options: {
    'player': {
      // Rebuffer only when the queue drops below 3s; keep filling up to 90s
      // ahead. A larger min = fewer, longer stalls (vs. ExoPlayer's constant
      // micro-stutter); a larger max rides out longer network dips without a
      // visible stall. Tuned for a 6 GB box: ~90s of compressed packets is only
      // ~90 MB for an 8 Mbps 1080p stream, nowhere near memory pressure. Note
      // max only reads further ahead in the background — it does NOT delay start
      // (playback begins once min is buffered), so keeping min at 3s preserves
      // snappy startup / live channel zapping while the big max absorbs dips.
      'buffer': '3000+90000',
      // Cache demuxed http(s) packet ranges so a re-watch / small seek doesn't
      // re-download, and tolerate a run of stream errors instead of aborting.
      'demux.buffer.ranges': '16',
      'demux.max_errors': '100',
      // Auto-reconnect on dropped/again HTTP reads (FFmpeg http-protocol opts
      // passed via the avio.* prefix) so a brief network hiccup resumes instead
      // of stalling the whole stream.
      'avio.reconnect': '1',
      'avio.reconnect_streamed': '1',
      'avio.reconnect_delay_max': '5',
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
