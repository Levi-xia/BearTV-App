import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// The version the repository's `main` branch currently declares. `pubspec.yaml`
/// on GitHub is the source of truth for "is there a newer version"; the APK
/// itself is fetched from the matching GitHub release (`v<baseVersion>` tag,
/// `--split-per-abi` naming), see [GitHubReleaseChecker.apkDownloadUrls].
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

/// Reads the version from the repository's `main` branch and derives the
/// release APK download URL. Every source is tried twice — direct GitHub plus
/// a CN-friendly mirror — because `raw.githubusercontent.com` / GitHub release
/// downloads are blocked or unstable inside mainland China; the first source
/// that answers wins, the next is only tried when the previous one fails.
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

  /// pubspec.yaml sources, tried in order. jsDelivr mirrors GitHub repos on a
  /// CDN that is reachable from mainland China; it may lag the push by a few
  /// minutes to hours, which only delays detecting a bump.
  List<String> get pubspecUrls => [
        'https://raw.githubusercontent.com/$repository/$branch/pubspec.yaml',
        'https://cdn.jsdelivr.net/gh/$repository@$branch/pubspec.yaml',
      ];

  /// APK download candidates for [info]'s tag and [abi], tried in order.
  /// gh-proxy.com is a generic GitHub release accelerator (third party).
  List<String> apkDownloadUrls(ReleaseInfo info, String abi) {
    final direct = 'https://github.com/$repository/releases/download/'
        '${info.tagName}/app-$abi-release.apk';
    return [direct, 'https://gh-proxy.com/$direct'];
  }

  /// Extracts the top-level `version: x.y.z+build` line. Returns null when the
  /// body has no usable version.
  static String? parsePubspecVersion(String body) {
    final m = RegExp(r'^version:\s*"?(.+?)"?\s*$', multiLine: true)
        .firstMatch(body);
    final v = m?.group(1)?.trim() ?? '';
    return v.isEmpty ? null : v;
  }

  /// The version `main` currently declares. Tries [pubspecUrls] in order —
  /// a blocked / wrong status on one source falls through to the next.
  /// Throws [ReleaseCheckException] when every source fails.
  Future<ReleaseInfo> fetchLatest() async {
    String? httpError;
    var sawParseFailure = false;
    var sawNetworkFailure = false;
    for (final url in pubspecUrls) {
      try {
        final res = await _client
            .get(Uri.parse(url))
            .timeout(const Duration(seconds: 12));
        if (res.statusCode == 200) {
          final version = parsePubspecVersion(utf8.decode(res.bodyBytes));
          if (version != null) {
            return ReleaseInfo(
                version: version.startsWith('v') ? version.substring(1) : version);
          }
          sawParseFailure = true;
        } else {
          httpError = '${res.statusCode}';
        }
      } on Exception {
        sawNetworkFailure = true;
      }
    }
    if (sawParseFailure) {
      throw const ReleaseCheckException('版本信息无法解析');
    }
    if (httpError != null) {
      throw ReleaseCheckException('检查更新失败（HTTP $httpError）');
    }
    // Blocked / reset / timed out on every source — the mainland-China case.
    if (sawNetworkFailure) {
      throw const ReleaseCheckException('网络异常，请检查网络后重试');
    }
    throw const ReleaseCheckException('检查更新失败，请重试');
  }

  /// Streams the APK for [info] + [abi] into [file], reporting progress (0..1)
  /// as bytes arrive. Tries [apkDownloadUrls] in order. Returns the number of
  /// bytes written; partial files are removed on failure.
  Future<int> download(
    ReleaseInfo info,
    String abi,
    File file, {
    void Function(double progress)? onProgress,
  }) async {
    String? httpError;
    var sawNetworkFailure = false;
    for (final url in apkDownloadUrls(info, abi)) {
      final http.StreamedResponse res;
      try {
        final req = http.Request('GET', Uri.parse(url));
        res = await _client.send(req).timeout(const Duration(seconds: 30));
      } on Exception {
        sawNetworkFailure = true;
        continue;
      }
      if (res.statusCode != 200) {
        httpError = '${res.statusCode}';
        continue;
      }
      final total = res.contentLength ?? 0;
      var received = 0;
      var failed = false;
      final sink = file.openWrite();
      try {
        await for (final chunk
            in res.stream.timeout(const Duration(seconds: 30))) {
          sink.add(chunk);
          received += chunk.length;
          if (total > 0 && onProgress != null) onProgress(received / total);
        }
        await sink.flush();
      } catch (_) {
        // Mid-stream reset (common for blocked hosts): drop the partial file
        // and fall through to the next source.
        failed = true;
        sawNetworkFailure = true;
      } finally {
        await sink.close();
      }
      if (!failed) return received;
      if (file.existsSync()) {
        try {
          file.deleteSync();
        } catch (_) {
          // Best effort; a stray partial file is harmless.
        }
      }
    }
    throw _downloadError(httpError, sawNetworkFailure);
  }

  /// All download sources failed — pick the most useful message.
  static ReleaseCheckException _downloadError(
      String? httpError, bool sawNetworkFailure) {
    if (httpError == '404') {
      // Version bumped on main but the release (and its APK) isn't published.
      return const ReleaseCheckException('该版本尚未发布安装包，请稍后再试');
    }
    if (httpError != null) {
      return ReleaseCheckException('下载失败（HTTP $httpError）');
    }
    if (sawNetworkFailure) {
      return const ReleaseCheckException('网络异常，请检查网络后重试');
    }
    return const ReleaseCheckException('下载失败，请重试');
  }

  void close() => _client.close();
}