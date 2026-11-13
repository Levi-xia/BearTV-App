/// Data models for the danmaku (弹幕) layer, ported from BearTV's
/// dandanplay-compatible client. Kept small + immutable — this runs on low-end
/// TV boxes where an episode can carry thousands of comments.
library;

import '../../core/env.dart';

/// A dandanplay-protocol danmaku host: `{baseUrl}/{token}/api/v2/...`.
///
/// [id] + [name] make multiple hosts manageable from the settings page; they
/// default to empty so older call sites (and tests) can keep constructing a
/// host from just [baseUrl] + [token]. [token] is required — every request path
/// carries it.
class DanmakuHost {
  final String id;
  final String name;
  final String baseUrl;
  final String token;

  const DanmakuHost({
    this.id = '',
    this.name = '',
    required this.baseUrl,
    required this.token,
  });

  /// User-facing label: the configured name, else the host, else the raw URL.
  String get label {
    final n = name.trim();
    if (n.isNotEmpty) return n;
    final host = Uri.tryParse(baseUrl.trim())?.host ?? '';
    return host.isNotEmpty ? host : baseUrl.trim();
  }

  /// Normalized `{base}/{token}/api/v2` root (no trailing slash on the base).
  String get apiRoot {
    final base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    return '$base/${token.trim()}/api/v2';
  }

  String get matchUrl => '$apiRoot/match';
  String commentUrl(int episodeId) =>
      '$apiRoot/comment/$episodeId?format=xml&duration=true';

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'baseUrl': baseUrl,
        'token': token,
      };

  factory DanmakuHost.fromJson(Map<String, dynamic> j) {
    final baseUrl = (j['baseUrl'] as String?) ?? '';
    final token = (j['token'] as String?) ?? '';
    final id = (j['id'] as String?)?.trim() ?? '';
    return DanmakuHost(
      // Deterministic fallback keeps a legacy entry (no id) addressable across
      // launches, so it can still be selected as the default.
      id: id.isEmpty ? 'dm_${baseUrl}_$token' : id,
      name: (j['name'] as String?) ?? '',
      baseUrl: baseUrl,
      token: token,
    );
  }
}

/// Host injected at build time through `DANMAKU_BASE_URL` / `DANMAKU_TOKEN`
/// (see [Env]). When non-empty it overwrites the saved host list on startup
/// (see [SettingsStore.init]); a build without the defines leaves the user's
/// own hosts untouched.
DanmakuHost defaultDanmakuHost() {
  final name = Env.danmakuName.trim();
  return DanmakuHost(
    id: 'danmaku_default',
    name: name.isEmpty ? '默认弹幕源' : name,
    baseUrl: Env.danmakuBaseUrl.trim(),
    token: Env.danmakuToken.trim(),
  );
}

/// One parsed comment. [time] is the playback second it appears at; [mode] is
/// 0=scroll (right→left) / 1=top / 2=bottom; [color] is a packed 0xRRGGBB int.
class DanmakuItem {
  final double time;
  final String text;
  final int mode;
  final int color; // 0xRRGGBB (no alpha)

  const DanmakuItem({
    required this.time,
    required this.text,
    this.mode = 0,
    this.color = 0xFFFFFF,
  });
}

/// A candidate episode match returned by the `/match` endpoint.
class DanmakuMatch {
  final int episodeId;
  final String animeTitle;
  final String episodeTitle;

  const DanmakuMatch({
    required this.episodeId,
    this.animeTitle = '',
    this.episodeTitle = '',
  });

  /// Human label for the picker list: `番名 · 分集`.
  String get label =>
      [animeTitle, episodeTitle].where((s) => s.trim().isNotEmpty).join(' · ');
}

/// User-tunable rendering config, persisted in [SettingsStore]. All fields have
/// TV-friendly discrete presets exposed in the play page.
class DanmakuConfig {
  /// Master switch.
  final bool enabled;

  /// 0.1..1.0 — text opacity.
  final double opacity;

  /// Logical font size in px (pre global UI scale). Presets: 18 / 22 / 26.
  final double fontSize;

  /// Seconds a scrolling comment takes to cross the screen. This is a
  /// wall-clock duration, independent of video playback speed (fast-forwarding
  /// the video never speeds danmaku up — excess comments are dropped instead).
  /// Smaller = faster. Presets: 12 (慢) / 9 (中) / 6 (快).
  final double scrollSeconds;

  /// Fraction of the player height danmaku may occupy (from the top).
  /// Presets: 0.25 (1/4屏) / 0.5 (半屏) / 1.0 (满屏).
  final double area;

  const DanmakuConfig({
    this.enabled = true,
    this.opacity = 1.0,
    this.fontSize = 22,
    this.scrollSeconds = 12,
    this.area = 0.25,
  });

  DanmakuConfig copyWith({
    bool? enabled,
    double? opacity,
    double? fontSize,
    double? scrollSeconds,
    double? area,
  }) =>
      DanmakuConfig(
        enabled: enabled ?? this.enabled,
        opacity: opacity ?? this.opacity,
        fontSize: fontSize ?? this.fontSize,
        scrollSeconds: scrollSeconds ?? this.scrollSeconds,
        area: area ?? this.area,
      );

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'opacity': opacity,
        'fontSize': fontSize,
        'scrollSeconds': scrollSeconds,
        'area': area,
      };

  factory DanmakuConfig.fromJson(Map<String, dynamic> j) => DanmakuConfig(
        enabled: (j['enabled'] as bool?) ?? true,
        opacity: (j['opacity'] as num?)?.toDouble() ?? 1.0,
        fontSize: (j['fontSize'] as num?)?.toDouble() ?? 22,
        scrollSeconds: (j['scrollSeconds'] as num?)?.toDouble() ?? 12,
        area: (j['area'] as num?)?.toDouble() ?? 0.25,
      );
}
