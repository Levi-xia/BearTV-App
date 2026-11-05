/// Compile-time configuration, injected with
/// `flutter build ... --dart-define-from-file=secrets.json`.
///
/// The repository ships only empty defaults, so an open-source clone (and every
/// CI build) compiles without any credentials. A local, gitignored
/// `secrets.json` supplies real values; see `secrets.example.json` for the
/// shape and pass it with `--dart-define-from-file=secrets.json`.
///
/// NOTE: `String.fromEnvironment` is a *compile-time* constant. This keeps
/// secrets out of the repository and out of published artifacts, but it is not
/// encryption — values are recoverable from the built binary.
class Env {
  const Env._();

  /// TMDB v3 API key seeded on first run (empty → the app asks the user).
  static const String tmdbApiKey = String.fromEnvironment('TMDB_API_KEY');

  /// Optional TMDB reverse-proxy origin (empty → direct TMDB endpoints).
  static const String tmdbProxyBase = String.fromEnvironment('TMDB_PROXY_BASE');

  /// Built-in MacCMS sources, as a JSON array string:
  /// `[{"id":"...","name":"...","api":"...","detail":"..."}]`.
  static const String cmsSitesJson =
      String.fromEnvironment('CMS_SITES_JSON', defaultValue: '[]');

  /// Source ids enabled on first launch, as a JSON array string.
  /// Empty → every built-in source is selected.
  static const String defaultSelectedJson =
      String.fromEnvironment('DEFAULT_SELECTED_JSON', defaultValue: '[]');

  /// dandanplay-compatible danmaku host. Empty → danmaku is unavailable.
  static const String danmakuBaseUrl =
      String.fromEnvironment('DANMAKU_BASE_URL');
  static const String danmakuToken = String.fromEnvironment('DANMAKU_TOKEN');

  /// Display name seeded for the built-in danmaku host (settings page list).
  static const String danmakuName = String.fromEnvironment(
    'DANMAKU_NAME',
    defaultValue: '默认弹幕源',
  );

  /// Seeded IPTV playlist. Empty → no default channel list.
  static const String iptvPlaylistUrl =
      String.fromEnvironment('IPTV_PLAYLIST_URL');
  static const String iptvPlaylistName = String.fromEnvironment(
    'IPTV_PLAYLIST_NAME',
    defaultValue: '默认直播源',
  );
}
