import 'dart:io';

import 'package:bear_tv/core/update_controller.dart';
import 'package:bear_tv/data/updater/release_checker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('compareVersions', () {
    test('equal versions', () {
      expect(compareVersions('0.1.3', '0.1.3'), 0);
    });

    test('compares numerically, not lexically', () {
      expect(compareVersions('0.1.10', '0.1.9'), greaterThan(0));
      expect(compareVersions('1.0.0', '0.9.9'), greaterThan(0));
      expect(compareVersions('0.1.3', '0.1.4'), lessThan(0));
    });

    test('tolerates v-prefix and +build suffix', () {
      expect(compareVersions('v0.1.3', '0.1.3'), 0);
      expect(compareVersions('v0.1.3+3', '0.1.3'), 0);
      expect(compareVersions('0.1.3+9', '0.1.3+1'), 0);
    });

    test('pads short versions', () {
      expect(compareVersions('0.1', '0.1.0'), 0);
    });
  });

  group('pickAbi', () {
    test('device ABI order wins', () {
      expect(pickAbi(const ['x86_64', 'arm64-v8a', 'armeabi-v7a']), 'x86_64');
    });

    test('skips ABIs no release APK exists for', () {
      expect(pickAbi(const ['armeabi', 'arm64-v8a']), 'arm64-v8a');
    });

    test('null when nothing matches', () {
      expect(pickAbi(const ['mips', 'armeabi']), isNull);
    });
  });

  group('GitHubReleaseChecker', () {
    test('fetchLatest parses the pubspec version', () async {
      final client = MockClient((req) async {
        expect(
            req.url.toString(),
            'https://raw.githubusercontent.com/'
            'Levi-xia/BearTV-App/main/pubspec.yaml');
        return http.Response(
          'name: bear_tv\n'
          'publish_to: \'none\'\n'
          'version: 0.1.4+4\n',
          200,
        );
      });
      final info = await GitHubReleaseChecker(client: client).fetchLatest();
      expect(info.version, '0.1.4+4');
      expect(info.baseVersion, '0.1.4');
      expect(info.tagName, 'v0.1.4');
    });

    test('fetchLatest falls back to jsDelivr when raw is unreachable',
        () async {
      final client = MockClient((req) async {
        if (req.url.host == 'raw.githubusercontent.com') {
          throw http.ClientException('blocked');
        }
        return http.Response('version: 0.1.4+4\n', 200);
      });
      final info = await GitHubReleaseChecker(client: client).fetchLatest();
      expect(info.version, '0.1.4+4');
    });

    test('fetchLatest throws 网络异常 when every source is unreachable', () async {
      final client =
          MockClient((req) async => throw http.ClientException('blocked'));
      final c = GitHubReleaseChecker(client: client);
      await expectLater(
        c.fetchLatest(),
        throwsA(predicate(
            (e) => e is ReleaseCheckException && e.message.contains('网络异常'))),
      );
    });

    test('fetchLatest throws on non-200 from every source', () async {
      final c = GitHubReleaseChecker(
          client: MockClient((_) async => http.Response('', 404)));
      await expectLater(c.fetchLatest(), throwsA(isA<ReleaseCheckException>()));
    });

    test('fetchLatest throws when the version line is missing', () async {
      final c = GitHubReleaseChecker(
          client: MockClient((_) async => http.Response('name: x\n', 200)));
      await expectLater(c.fetchLatest(), throwsA(isA<ReleaseCheckException>()));
    });

    test('parsePubspecVersion handles quotes and CRLF', () {
      expect(
          GitHubReleaseChecker.parsePubspecVersion(
              'name: a\r\nversion: "0.1.3+3"\r\n'),
          '0.1.3+3');
      expect(GitHubReleaseChecker.parsePubspecVersion('name: a\nversion:  \n'),
          isNull);
      expect(GitHubReleaseChecker.parsePubspecVersion(''), isNull);
    });

    test('apkDownloadUrls are direct GitHub first, then a mirror', () {
      final c = GitHubReleaseChecker();
      final urls =
          c.apkDownloadUrls(const ReleaseInfo(version: '0.1.4+4'), 'arm64-v8a');
      expect(
        urls.first,
        'https://github.com/Levi-xia/BearTV-App/releases/download/'
        'v0.1.4/app-arm64-v8a-release.apk',
      );
      expect(
        urls.last,
        'https://gh-proxy.com/'
        'https://github.com/Levi-xia/BearTV-App/releases/download/'
        'v0.1.4/app-arm64-v8a-release.apk',
      );
    });

    test('download streams to disk and reports progress', () async {
      final bytes = List<int>.generate(1024, (i) => i % 256);
      final client = MockClient((req) async => http.Response.bytes(bytes, 200,
          headers: {'content-length': '${bytes.length}'}));
      final c = GitHubReleaseChecker(client: client);
      final tmp = await Directory.systemTemp.createTemp('bear_tv_upd');
      addTearDown(() => tmp.delete(recursive: true));
      final f = File('${tmp.path}/a.apk');
      final heard = <double>[];
      final size = await c.download(
          const ReleaseInfo(version: '0.1.4'), 'arm64-v8a', f,
          onProgress: heard.add);
      expect(size, bytes.length);
      expect(f.readAsBytesSync(), bytes);
      expect(heard, isNotEmpty);
      expect(heard.last, closeTo(1.0, 1e-9));
    });

    test('download falls back to the mirror when direct fails', () async {
      final bytes = [1, 2, 3];
      final client = MockClient((req) async {
        if (req.url.host == 'github.com') {
          return http.Response('', 500);
        }
        return http.Response.bytes(bytes, 200);
      });
      final c = GitHubReleaseChecker(client: client);
      final tmp = await Directory.systemTemp.createTemp('bear_tv_upd');
      addTearDown(() => tmp.delete(recursive: true));
      final f = File('${tmp.path}/a.apk');
      final size =
          await c.download(const ReleaseInfo(version: '0.1.4'), 'arm64-v8a', f);
      expect(size, bytes.length);
      expect(f.readAsBytesSync(), bytes);
    });

    test('download maps 404 to an unpublished-release message', () async {
      final c = GitHubReleaseChecker(
          client: MockClient((_) async => http.Response('', 404)));
      final tmp = await Directory.systemTemp.createTemp('bear_tv_upd');
      addTearDown(() => tmp.delete(recursive: true));
      await expectLater(
        c.download(const ReleaseInfo(version: '0.1.4'), 'arm64-v8a',
            File('${tmp.path}/a.apk')),
        throwsA(predicate(
            (e) => e is ReleaseCheckException && e.message.contains('尚未发布'))),
      );
    });
  });

  group('UpdateController', () {
    test('check → available with the device ABI', () async {
      final c = UpdateController(
          checker: _FakeChecker(ReleaseInfo(version: '0.1.4+4')),
          platform: _FakePlatform());
      await c.check();
      expect(c.state, UpdateState.available);
      expect(c.release!.version, '0.1.4+4');
      expect(c.abi, 'arm64-v8a');
      expect(c.appInfo!.versionName, '0.1.3');
    });

    test('check → upToDate when installed is the newest', () async {
      final c = UpdateController(
          checker: _FakeChecker(const ReleaseInfo(version: '0.1.3+3')),
          platform: _FakePlatform());
      await c.check();
      expect(c.state, UpdateState.upToDate);
    });

    test('check → failed surfaces the checker message', () async {
      final ch = _FakeChecker(const ReleaseInfo(version: '0.1.4'))
        ..fetchError = const ReleaseCheckException('网络异常，请检查网络后重试');
      final c = UpdateController(checker: ch, platform: _FakePlatform());
      await c.check();
      expect(c.state, UpdateState.failed);
      expect(c.error, '网络异常，请检查网络后重试');
    });

    test('available without a matching ABI has nothing to download', () async {
      final c = UpdateController(
          checker: _FakeChecker(const ReleaseInfo(version: '0.1.4')),
          platform: _FakePlatform(supportedAbis: const ['mips']));
      await c.check();
      expect(c.state, UpdateState.available);
      expect(c.abi, isNull);
      await c.download();
      expect(c.state, UpdateState.available); // no-op
    });

    test('download writes the APK, install hands it to native', () async {
      final p = _FakePlatform();
      final tmp = await Directory.systemTemp.createTemp('bear_tv_ctrl');
      addTearDown(() => tmp.delete(recursive: true));
      p.downloadDir = tmp.path;
      final c = UpdateController(
          checker: _FakeChecker(const ReleaseInfo(version: '0.1.4')),
          platform: p);
      await c.check();
      await c.download();
      expect(c.state, UpdateState.downloaded);
      expect(c.progress, 1.0);
      expect(c.apkPath, isNotNull);
      expect(File(c.apkPath!).existsSync(), isTrue);
      expect(File(c.apkPath!).lengthSync(), 3);
      await c.install();
      expect(p.installedPath, c.apkPath);
    });

    test('missing platform channel → failed, never throws', () async {
      final c = UpdateController(
          checker: _FakeChecker(const ReleaseInfo(version: '0.1.4')),
          platform: _ThrowingPlatform());
      await c.check();
      expect(c.state, UpdateState.failed);
      expect(c.error, '当前设备不支持此操作');
    });
  });
}

class _FakeChecker extends GitHubReleaseChecker {
  _FakeChecker(this.release);
  final ReleaseInfo release;
  Object? fetchError;

  @override
  Future<ReleaseInfo> fetchLatest() async {
    final e = fetchError;
    if (e != null) throw e;
    return release;
  }

  @override
  Future<int> download(ReleaseInfo info, String abi, File file,
      {void Function(double progress)? onProgress}) async {
    onProgress?.call(0.5);
    await file.writeAsBytes(const [1, 2, 3]);
    onProgress?.call(1.0);
    return 3;
  }
}

class _FakePlatform implements UpdaterPlatform {
  _FakePlatform({this.supportedAbis = const ['arm64-v8a', 'armeabi-v7a']});
  final List<String> supportedAbis;
  String downloadDir = '';
  String? installedPath;

  @override
  Future<AppVersionInfo> getAppInfo() async => AppVersionInfo(
      versionName: '0.1.3', versionCode: 3, supportedAbis: supportedAbis);

  @override
  Future<String> getDownloadDir() async => downloadDir;

  @override
  Future<void> installApk(String filePath) async => installedPath = filePath;
}

class _ThrowingPlatform implements UpdaterPlatform {
  @override
  Future<AppVersionInfo> getAppInfo() async =>
      throw MissingPluginException('no channel');

  @override
  Future<String> getDownloadDir() async => throw MissingPluginException();

  @override
  Future<void> installApk(String filePath) async =>
      throw MissingPluginException();
}
