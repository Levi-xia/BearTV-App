import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../data/updater/release_checker.dart';

/// Version / ABI info reported by the platform channel.
class AppVersionInfo {
  const AppVersionInfo({
    required this.versionName,
    required this.versionCode,
    this.supportedAbis = const [],
  });

  final String versionName;
  final int versionCode;
  final List<String> supportedAbis;
}

/// Native side of the updater (see `MainActivity.kt`): package info, the
/// download directory, and the APK install intent. Abstracted so tests can
/// fake it; production uses [MethodChannelUpdaterPlatform].
abstract class UpdaterPlatform {
  Future<AppVersionInfo> getAppInfo();

  /// Absolute path of the directory APKs are downloaded into (created if
  /// needed). Lives on the native side so `FileProvider` config matches.
  Future<String> getDownloadDir();

  /// Hands [filePath] to the system package installer. The user confirms.
  Future<void> installApk(String filePath);
}

class MethodChannelUpdaterPlatform implements UpdaterPlatform {
  const MethodChannelUpdaterPlatform();

  static const MethodChannel _channel = MethodChannel('bear_tv/updater');

  @override
  Future<AppVersionInfo> getAppInfo() async {
    final map = (await _channel.invokeMethod<Map<Object?, Object?>>('getAppInfo')) ??
        const <Object?, Object?>{};
    return AppVersionInfo(
      versionName: (map['versionName'] as String?) ?? '',
      versionCode: (map['versionCode'] as num?)?.toInt() ?? 0,
      supportedAbis: [
        for (final a in (map['supportedAbis'] as List?) ?? const [])
          if (a is String) a,
      ],
    );
  }

  @override
  Future<String> getDownloadDir() async =>
      (await _channel.invokeMethod<String>('getDownloadDir')) ?? '';

  @override
  Future<void> installApk(String filePath) =>
      _channel.invokeMethod<void>('installApk', {'path': filePath});
}

/// Lifecycle of the check → download → install flow.
enum UpdateState {
  /// Nothing asked yet.
  idle,

  /// Checking the repository for a newer release.
  checking,

  /// A newer release exists and [abi] may be non-null (null = no APK for this
  /// device's architecture is published).
  available,

  /// Streaming the matching APK to disk; [progress] is 0..1.
  downloading,

  /// The APK is on disk and ready to install.
  downloaded,

  /// The installed version is the newest published one.
  upToDate,

  /// Last operation failed; [error] has a user-facing message.
  failed,
}

/// Drives the version-check feature for the settings page: reads the installed
/// version + supported ABIs from native, compares against the latest GitHub
/// release, streams the matching APK to disk, then hands it to the system
/// installer. All state changes notify listeners; the UI is a pure renderer.
class UpdateController extends ChangeNotifier {
  UpdateController({GitHubReleaseChecker? checker, UpdaterPlatform? platform})
      : _checker = checker ?? GitHubReleaseChecker(),
        _platform = platform ?? const MethodChannelUpdaterPlatform();

  final GitHubReleaseChecker _checker;
  final UpdaterPlatform _platform;

  UpdateState _state = UpdateState.idle;
  UpdateState get state => _state;

  AppVersionInfo? _appInfo;
  AppVersionInfo? get appInfo => _appInfo;

  ReleaseInfo? _release;
  ReleaseInfo? get release => _release;

  /// ABI of the APK being offered / downloaded. Null means the release has no
  /// package for this device.
  String? _abi;
  String? get abi => _abi;

  /// Download progress, 0..1. Only meaningful while [state] is downloading.
  double _progress = 0;
  double get progress => _progress;

  /// Path of the downloaded APK; set when [state] becomes [UpdateState.downloaded].
  String? _apkPath;
  String? get apkPath => _apkPath;

  int _apkSize = 0;
  int get apkSize => _apkSize;

  String? _error;
  String? get error => _error;

  /// Asks native for the installed version + ABIs (cached for the controller's
  /// lifetime), then queries the repository. Never throws — failures land in
  /// [state] with a [error] message.
  Future<void> check() async {
    if (_state == UpdateState.checking || _state == UpdateState.downloading) {
      return;
    }
    try {
      _appInfo ??= await _platform.getAppInfo();
      _error = null;
      _state = UpdateState.checking;
      notifyListeners();
      final latest = await _checker.fetchLatest();
      if (compareVersions(latest.version, _appInfo!.versionName) <= 0) {
        _state = UpdateState.upToDate;
      } else {
        _release = latest;
        _abi = pickAbi(_appInfo!.supportedAbis);
        _state = UpdateState.available;
      }
    } catch (e) {
      _error = _friendly(e);
      _state = UpdateState.failed;
    }
    notifyListeners();
  }

  /// Downloads the offered APK. No-op unless [state] is available with an ABI.
  Future<void> download() async {
    final release = _release;
    final abi = _abi;
    if (release == null || abi == null) return;
    _state = UpdateState.downloading;
    _progress = 0;
    _error = null;
    notifyListeners();
    try {
      final dir = Directory(await _platform.getDownloadDir());
      await dir.create(recursive: true);
      final file =
          File('${dir.path}/bear_tv_${release.tagName}_$abi.apk');
      final size = await _checker.download(release, abi, file,
          onProgress: (p) {
        _progress = p;
        notifyListeners();
      });
      _apkPath = file.path;
      _apkSize = size;
      _state = UpdateState.downloaded;
    } catch (e) {
      _error = _friendly(e);
      _state = UpdateState.failed;
    }
    notifyListeners();
  }

  /// Hands the downloaded APK to the system installer. No-op unless
  /// [state] is [UpdateState.downloaded].
  Future<void> install() async {
    final path = _apkPath;
    if (path == null) return;
    try {
      await _platform.installApk(path);
    } catch (e) {
      _error = _friendly(e);
      _state = UpdateState.failed;
      notifyListeners();
    }
  }

  /// Clears a failed state and checks again.
  Future<void> retry() async {
    if (_state == UpdateState.failed) _state = UpdateState.idle;
    await check();
  }

  static String _friendly(Object e) {
    if (e is ReleaseCheckException) return e.message;
    if (e is MissingPluginException || e is PlatformException) {
      return '当前设备不支持此操作';
    }
    return '操作失败，请重试';
  }

  @override
  void dispose() {
    _checker.close();
    super.dispose();
  }
}