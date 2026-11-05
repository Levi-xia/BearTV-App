/// Data models for the IPTV (直播) feature. Ported from BearTV's
/// `src/services/iptvParser.js` channel shape and source config.
///
/// Kept small and immutable to suit low-end TV boxes. [IptvChannel] is
/// transient (re-parsed from a playlist, never persisted); [IptvSource] is
/// persisted via [SettingsStore] using the same JSON pattern as `CmsSite`.
library;

import '../../core/env.dart';

/// One playable live channel parsed from an M3U/M3U8 playlist entry.
class IptvChannel {
  final String id;
  final String sourceId;
  final String name;
  final String group;
  final String logo;
  final String tvgId;
  final String url;

  const IptvChannel({
    required this.id,
    required this.sourceId,
    required this.name,
    required this.group,
    required this.logo,
    required this.tvgId,
    required this.url,
  });
}

/// A user-configured IPTV playlist source (an M3U/M3U8 URL + display name).
class IptvSource {
  final String id;
  final String name;
  final String url;

  const IptvSource({
    required this.id,
    required this.name,
    required this.url,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
      };

  factory IptvSource.fromJson(Map<String, dynamic> j) => IptvSource(
        id: (j['id'] as String?) ?? '',
        name: (j['name'] as String?) ?? '',
        url: (j['url'] as String?) ?? '',
      );
}

/// Source injected at build time through `IPTV_PLAYLIST_URL` (see [Env]). When
/// non-empty it overwrites the saved source list on startup (see
/// [SettingsStore.init]); a build without the define leaves the user's own
/// sources untouched. The upstream list itself is not committed.
List<IptvSource> defaultIptvSources() {
  final url = Env.iptvPlaylistUrl.trim();
  if (url.isEmpty) return const [];
  final name = Env.iptvPlaylistName.trim();
  return [
    IptvSource(
      id: 'iptv_default_zn',
      name: name.isEmpty ? '默认直播源' : name,
      url: url,
    ),
  ];
}
