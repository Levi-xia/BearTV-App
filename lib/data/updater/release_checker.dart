import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// The version the repository's `main` branch currently declares. `pubspec.yaml`
/// on GitHub is the source of truth for "is there a newer version"; the APK
/// itself is fetched from the matching GitHub release (`v<baseVersion>` tag,
/// `--split-per-abi` naming), see [GitHubReleaseChecker.apkDownloadUrl].
class ReleaseInfo {
  const ReleaseInfo({required this.version});

  /// Full version from pubspec, e.g. `0.1.3+3` (no leading `v`).
  final String version;

  /// Version without the `+build` suffix — what release tags and APK names use.
  String get baseVersion {
    final plus = version.indexOf('+');
    return plus >= 0 ? version.substring(0, plus) : version;
  }

  /// Release tag for this version (`v0.1.3`).
  String get tagName => 'v$baseVersion';
}

/// A user-facing upgrade failure. [message] is already localized and safe to
/// show in a toast / status line.
class ReleaseCheckException implements Exception {
  const ReleaseCheckException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// ABIs the release pipeline can produce (see README: `--split-per-abi`).
const List<String> kKnownAbis = ['arm64-v8a', 'armeabi-v7a', 'x86_64'];

/// Picks the ABI to download: the device's first supported ABI that a release
/// APK exists for (`Build.SUPPORTED_ABIS` is already in preference order).
/// Null = this device has no matching build.
String? pickAbi(List<String> deviceAbis) {
  for (final abi in deviceAbis) {
    if (kKnownAbis.contains(abi)) return abi;
  }
  return null;
}

/// Compares two version strings component by component, numerically:
/// `0.1.10 > 0.1.9`. Tolerates a leading `v` and a `+build` suffix
/// (`v0.1.3+3` == `0.1.3`), and pads short versions (`0.1` == `0.1.0`).
/// Returns <0 / 0 / >0 like [Comparable.compareTo].
int compareVersions(String a, String b) {
  List<int> parse(String raw) {
    var s = raw.trim();
    if (s.startsWith('v')) s = s.substring(1);
    final plus = s.indexOf('+');
    if (plus >= 0) s = s.substring(0, plus);
    return [
      for (final p in s.split('.')) int.tryParse(p.trim()) ?? 0,
    ];
  }

  final pa = parse(a);
  final pb = parse(b);
  final n = pa.length > pb.length ? pa.length : pb.length;
  for (var i = 0; i < n; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}

/// Reads the version from the repository's `main` branch (raw `pubspec.yaml`,
/// no GitHub API / rate limit) and derives the release APK download URL.
/// Pure HTTP + parsing — the platform bits (package info, install intent)
/// live in `UpdaterPlatform`.
class GitHubReleaseChecker {
  GitHubReleaseChecker({
    http.Client? client,
    this.repository = 'Levi-xia/BearTV-App',
    this.branch = 'main',
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final String repository;
  final String branch;

  /// The checked-in pubspec on [branch] — the build-time version.
  String get pubspecUrl =>
      'https://raw.githubusercontent.com/$repository/$branch/pubspec.yaml';

  /// The release APK for [info]'s tag and [abi]. Relies on the release
  /// following the `v<version>` tag + `--split-per-abi` file naming.
  String apkDownloadUrl(ReleaseInfo info, String abi) =>
      'https://github.com/$repository/releases/download/${info.tagName}'
      '/app-$abi-release.apk';

  /// Extracts the top-level `version: x.y.z+build` line. Returns null when the
  /// body has no usable version.
  static String? parsePubspecVersion(String body) {
    final m = RegExp(r'^version:\s*"?(.+?)"?\s*$', multiLine: true)
        .firstMatch(body);
    final v = m?.group(1)?.trim() ?? '';
    return v.isEmpty ? null : v;
  }

  /// The version `main` currently declares. Throws [ReleaseCheckException] on
  /// any failure — there is no "no releases yet" state with a pubspec source.
  Future<ReleaseInfo> fetchLatest() async {
    final http.Response res;
    try {
      res = await _client
          .get(Uri.parse(pubspecUrl))
          .timeout(const Duration(seconds: 12));
    } on Exception {
      throw const ReleaseCheckException('网络异常，请检查网络后重试');
    }
    if (res.statusCode != 200) {
      throw ReleaseCheckException('检查更新失败（HTTP ${res.statusCode}）');
    }
    final version = parsePubspecVersion(utf8.decode(res.bodyBytes));
    if (version == null) {
      throw const ReleaseCheckException('版本信息无法解析');
    }
    return ReleaseInfo(
        version: version.startsWith('v') ? version.substring(1) : version);
  }

  /// Streams [url] into [file], reporting progress (0..1) as bytes arrive.
  /// Returns the number of bytes written. Partial files are removed on failure.
  Future<int> download(
    String url,
    File file, {
    void Function(double progress)? onProgress,
  }) async {
    final http.StreamedResponse res;
    try {
      final req = http.Request('GET', Uri.parse(url));
      res = await _client.send(req).timeout(const Duration(seconds: 30));
    } on Exception {
      throw const ReleaseCheckException('网络异常，请检查网络后重试');
    }
    if (res.statusCode == 404) {
      // Version bumped on main but the release (and its APK) isn't published.
      throw const ReleaseCheckException('该版本尚未发布安装包，请稍后再试');
    }
    if (res.statusCode != 200) {
      throw ReleaseCheckException('下载失败（HTTP ${res.statusCode}）');
    }
    final total = res.contentLength ?? 0;
    var received = 0;
    final sink = file.openWrite();
    try {
      await for (final chunk in res.stream.timeout(const Duration(seconds: 30))) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0 && onProgress != null) onProgress(received / total);
      }
      await sink.flush();
    } catch (_) {
      if (file.existsSync()) {
        try {
          file.deleteSync();
        } catch (_) {
          // Best effort; a stray partial file is harmless.
        }
      }
      rethrow;
    } finally {
      await sink.close();
    }
    return received;
  }

  void close() => _client.close();
}