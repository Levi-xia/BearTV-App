/// Human-readable byte size, e.g. `1.2 GB` / `36 MB` / `512 KB`.
///
/// Bytes and KB stay whole; MB and above get one decimal so the number stays
/// short on a TV screen.
String formatBytes(int bytes) {
  if (bytes <= 0) return '0 MB';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final text = unit >= 2 ? value.toStringAsFixed(1) : value.toStringAsFixed(0);
  return '$text ${units[unit]}';
}

/// Human-readable transfer rate, e.g. `3.2 MB/s` / `640 KB/s` / `0 MB/s`.
String formatSpeed(int bytesPerSecond) =>
    bytesPerSecond <= 0 ? '0 MB/s' : '${formatBytes(bytesPerSecond)}/s';
