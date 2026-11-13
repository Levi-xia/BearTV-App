/// Episode identity helpers.
///
/// CMS sources reshuffle lines/episodes and hand out signed URLs whose query
/// changes between sessions, so raw indices (and full URLs) are unreliable
/// keys. Downloads and history therefore match an episode by, in order: exact
/// URL, URL path (ignores signed query), normalized title, and only then the
/// raw index.
library;

import 'dart:convert';

import '../vod/cms_models.dart';

final RegExp _whitespace = RegExp(r'\s+');

/// Normalized comparison form of an episode title: full-width digits folded to
/// ASCII, all whitespace removed, lower-cased. `第１集` and `第 1 集` match.
String normalizeEpisodeTitle(String title) {
  final buf = StringBuffer();
  for (final rune in title.runes) {
    // U+FF10..U+FF19 → '0'..'9'
    if (rune >= 0xFF10 && rune <= 0xFF19) {
      buf.writeCharCode(0x30 + (rune - 0xFF10));
    } else {
      buf.writeCharCode(rune);
    }
  }
  return buf.toString().replaceAll(_whitespace, '').toLowerCase();
}

/// The URL without query/fragment. Signed CDN URLs keep the same path across
/// refreshes, so this survives a re-signed history entry. Non-absolute inputs
/// are returned trimmed, so a bare relative path still compares correctly.
String episodeUrlPath(String url) {
  final trimmed = url.trim();
  final uri = Uri.tryParse(trimmed);
  if (uri == null || !uri.hasScheme || uri.path.isEmpty) return trimmed;
  return uri.path;
}

/// Whether two episode references point at the same episode. Empty fields never
/// match (an old history record has no title/URL identity).
bool sameEpisode({
  String? urlA,
  String? titleA,
  String? urlB,
  String? titleB,
}) {
  final ua = urlA?.trim() ?? '';
  final ub = urlB?.trim() ?? '';
  if (ua.isNotEmpty && ua == ub) return true;
  if (ua.isNotEmpty && ub.isNotEmpty) {
    final pa = episodeUrlPath(ua);
    final pb = episodeUrlPath(ub);
    if (pa.isNotEmpty && pa == pb) return true;
  }
  final ta = normalizeEpisodeTitle(titleA ?? '');
  final tb = normalizeEpisodeTitle(titleB ?? '');
  return ta.isNotEmpty && ta == tb;
}

/// A located episode inside a [VodDetail] snapshot.
class EpisodeLocation {
  final int lineIndex;
  final int episodeIndex;
  const EpisodeLocation(this.lineIndex, this.episodeIndex);
}

/// Find the episode described by [episodeUrl] / [episodeTitle] across every
/// play line. Falls back to a clamped [episodeIndex] on line 0 when no identity
/// match exists (legacy history records, or a source that rewrote its titles
/// *and* URLs).
EpisodeLocation? locateEpisode(
  VodDetail detail, {
  String? episodeUrl,
  String? episodeTitle,
  int? episodeIndex,
}) {
  final lines = detail.playLines;
  if (lines.isEmpty) return null;
  final url = episodeUrl?.trim() ?? '';
  final title = normalizeEpisodeTitle(episodeTitle ?? '');

  if (url.isNotEmpty) {
    for (var l = 0; l < lines.length; l++) {
      final eps = lines[l].episodes;
      for (var e = 0; e < eps.length; e++) {
        if (eps[e].url.trim() == url) return EpisodeLocation(l, e);
      }
    }
    final path = episodeUrlPath(url);
    if (path.isNotEmpty) {
      for (var l = 0; l < lines.length; l++) {
        final eps = lines[l].episodes;
        for (var e = 0; e < eps.length; e++) {
          if (episodeUrlPath(eps[e].url) == path) return EpisodeLocation(l, e);
        }
      }
    }
  }

  if (title.isNotEmpty) {
    for (var l = 0; l < lines.length; l++) {
      final eps = lines[l].episodes;
      for (var e = 0; e < eps.length; e++) {
        if (normalizeEpisodeTitle(eps[e].title) == title) {
          return EpisodeLocation(l, e);
        }
      }
    }
  }

  if (episodeIndex != null) {
    for (var l = 0; l < lines.length; l++) {
      final eps = lines[l].episodes;
      if (eps.isEmpty) continue;
      return EpisodeLocation(l, episodeIndex.clamp(0, eps.length - 1));
    }
  }
  return null;
}

/// Stable 64-bit-ish hash (two FNV-1a rounds) rendered as hex. Used for
/// filesystem-safe directory/file names — [String.hashCode] is randomized per
/// process and would orphan downloaded files after a restart.
String fnv1aHex(String input) {
  final bytes = utf8.encode(input);
  var h1 = 0x811c9dc5;
  var h2 = 0x811c9dc5 ^ 0x5bd1e995;
  for (final b in bytes) {
    h1 = ((h1 ^ b) * 0x01000193) & 0xFFFFFFFF;
    h2 = ((h2 ^ b) * 0x01000193) & 0xFFFFFFFF;
  }
  return h1.toRadixString(16).padLeft(8, '0') +
      h2.toRadixString(16).padLeft(8, '0');
}
