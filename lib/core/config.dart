/// Static, non-secret configuration. The TMDB **API key is NOT here** — it is
/// entered by the user on the in-app Settings page and persisted locally
/// ([SettingsStore]), so it never ships in the binary or the repo.
///
/// The public host/CDN bases live here. Their compile-time defaults can be
/// overridden at build time via --dart-define, and at runtime they can be
/// switched to a reverse proxy (for networks that can't reach TMDB directly,
/// e.g. mainland-China TV boxes) via [applyProxy].
class Config {
  const Config._();

  /// Compile-time default TMDB API host (direct).
  static const String defaultTmdbBase = String.fromEnvironment(
    'TMDB_BASE',
    defaultValue: 'https://api.themoviedb.org/3',
  );

  /// Compile-time default image CDN base (direct).
  static const String defaultTmdbImageBase = String.fromEnvironment(
    'TMDB_IMAGE_BASE',
    defaultValue: 'https://image.tmdb.org/t/p',
  );

  /// Effective TMDB API host. Read by [TmdbApi] at construction time.
  static String tmdbBase = defaultTmdbBase;

  /// Effective image CDN base. Read by the TMDB mappers on every image URL.
  static String tmdbImageBase = defaultTmdbImageBase;

  /// Route TMDB traffic through [proxyBase] when [enabled], else fall back to
  /// the direct defaults. The proxy is expected to mirror TMDB's path layout
  /// (`<proxy>/3/...` for the API, `<proxy>/t/p/...` for images), so we simply
  /// append the well-known prefixes to its origin.
  static void applyProxy({required bool enabled, required String proxyBase}) {
    final origin = proxyBase.trim().replaceAll(RegExp(r'/+$'), '');
    if (enabled && origin.isNotEmpty) {
      tmdbBase = '$origin/3';
      tmdbImageBase = '$origin/t/p';
    } else {
      tmdbBase = defaultTmdbBase;
      tmdbImageBase = defaultTmdbImageBase;
    }
  }
}
