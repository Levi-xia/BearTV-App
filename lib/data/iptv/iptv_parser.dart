import 'iptv_models.dart';

/// Pure M3U/M3U8 playlist parser, ported from BearTV
/// `src/services/iptvParser.js`. No I/O — feed it playlist text and get back a
/// flat list of [IptvChannel]s (grouping is derived later by the controller).
///
/// Format: an `#EXTINF:<meta>,<display name>` line carries attributes
/// (`tvg-name`, `tvg-id`, `tvg-logo`, `group-title`); the next non-`#` line is
/// the stream URL. Missing name/group fall back to 未命名频道 / 未分组.

final RegExp _attr = RegExp(r'([\w-]+)="([^"]*)"');
final RegExp _extinf = RegExp(r'^#EXTINF:', caseSensitive: false);

Map<String, String> _parseAttributes(String raw) {
  final out = <String, String>{};
  for (final m in _attr.allMatches(raw)) {
    out[m.group(1)!] = m.group(2)!;
  }
  return out;
}

class _Meta {
  final String name;
  final String group;
  final String logo;
  final String tvgId;
  const _Meta(this.name, this.group, this.logo, this.tvgId);
}

_Meta _parseExtinf(String line) {
  final content = line.replaceFirst(_extinf, '').trimLeft();
  final commaIndex = content.indexOf(',');
  final meta = commaIndex >= 0 ? content.substring(0, commaIndex) : content;
  final displayName = commaIndex >= 0 ? content.substring(commaIndex + 1).trim() : '';
  final attrs = _parseAttributes(meta);
  final name = displayName.isNotEmpty
      ? displayName
      : (attrs['tvg-name']?.isNotEmpty == true
          ? attrs['tvg-name']!
          : (attrs['tvg-id']?.isNotEmpty == true ? attrs['tvg-id']! : '未命名频道'));
  return _Meta(
    name,
    attrs['group-title']?.isNotEmpty == true ? attrs['group-title']! : '未分组',
    attrs['tvg-logo'] ?? '',
    attrs['tvg-id'] ?? '',
  );
}

/// Parse [content] into channels tagged with [sourceId]. Returns [] for empty
/// or malformed input.
List<IptvChannel> parseM3u(String content, String sourceId) {
  if (content.isEmpty) return const [];
  final channels = <IptvChannel>[];
  _Meta? pending;
  for (final raw in content.split(RegExp(r'\r?\n'))) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (_extinf.hasMatch(line)) {
      pending = _parseExtinf(line);
      continue;
    }
    if (line.startsWith('#')) continue;
    final url = line;
    final meta = pending ?? const _Meta('未命名频道', '未分组', '', '');
    channels.add(IptvChannel(
      id: '${sourceId.isNotEmpty ? sourceId : 'iptv'}_${channels.length}_$url',
      sourceId: sourceId,
      name: meta.name,
      group: meta.group,
      logo: meta.logo,
      tvgId: meta.tvgId,
      url: url,
    ));
    pending = null;
  }
  return channels;
}
