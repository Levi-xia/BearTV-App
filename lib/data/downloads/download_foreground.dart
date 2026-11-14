import 'dart:io';

import 'package:flutter/services.dart';

/// Keeps the app process alive while episodes download.
///
/// Android only lets a cached process keep working in the background when it
/// owns a foreground service with a persistent notification. Without one the
/// download queue must pause the moment the app leaves the screen, otherwise
/// the system may kill the process in the middle of a segment write.
///
/// This is the seam between [DownloadManager] and the native service; the
/// manager starts it while the queue has work and falls back to pausing when
/// the platform refuses or there is no service at all (tests, desktop).
abstract class DownloadForeground {
  /// Starts the service (or refreshes it when it is already up). Returns false
  /// when the platform has no service to offer or the system refused the
  /// start — callers then keep the pause-on-background behaviour.
  Future<bool> start({
    required String title,
    required String text,
    int? progress,
    int? max,
  });

  /// Updates the notification of a service that is already running. Returns
  /// false when there is nothing to update — the service was never started, or
  /// the system killed it — so the caller can drop back to pausing.
  Future<bool> update({
    required String title,
    required String text,
    int? progress,
    int? max,
  });

  Future<void> stop();
}

/// Platform default: the Android foreground service, no-op everywhere else.
DownloadForeground defaultDownloadForeground() => Platform.isAndroid
    ? const AndroidDownloadForeground()
    : const NoopDownloadForeground();

/// Used by tests and non-Android builds; refuses to start, so
/// [DownloadManager] keeps its conservative pause-on-background behaviour.
class NoopDownloadForeground implements DownloadForeground {
  const NoopDownloadForeground();

  @override
  Future<bool> start({
    required String title,
    required String text,
    int? progress,
    int? max,
  }) async =>
      false;

  @override
  Future<bool> update({
    required String title,
    required String text,
    int? progress,
    int? max,
  }) async =>
      false;

  @override
  Future<void> stop() async {}
}

/// Talks to `DownloadForegroundService` through `bear_tv/downloads`.
class AndroidDownloadForeground implements DownloadForeground {
  const AndroidDownloadForeground();

  static const _channel = MethodChannel('bear_tv/downloads');

  @override
  Future<bool> start({
    required String title,
    required String text,
    int? progress,
    int? max,
  }) async {
    try {
      final started = await _channel.invokeMethod<bool>('start', {
        'title': title,
        'text': text,
        if (progress != null) 'progress': progress,
        if (max != null) 'max': max,
      });
      return started ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<bool> update({
    required String title,
    required String text,
    int? progress,
    int? max,
  }) async {
    try {
      final updated = await _channel.invokeMethod<bool>('update', {
        'title': title,
        'text': text,
        if (progress != null) 'progress': progress,
        if (max != null) 'max': max,
      });
      return updated ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      // A notification refresh is never worth failing a download over.
      return false;
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      // Nothing to stop.
    } on PlatformException {
      // The service dies with the process anyway.
    }
  }
}
