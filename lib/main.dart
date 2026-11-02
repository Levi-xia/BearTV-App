import 'package:flutter/material.dart';

import 'app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
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
