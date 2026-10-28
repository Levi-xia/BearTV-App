import 'package:shared_preferences/shared_preferences.dart';

/// A tiny string key/value abstraction so config storage can vary by platform
/// without leaking the backend into the stores. In production this is backed by
/// [SharedPrefsStore] (SharedPreferences on Android/iOS, NSUserDefaults, or
/// localStorage on web); under `flutter test` (or when the plugin is
/// unavailable) it degrades to an in-memory map so nothing has to be mocked.
abstract class KeyValueStore {
  Future<void> init();
  String? getString(String key);
  Future<void> setString(String key, String value);
  Future<void> remove(String key);
}

/// [KeyValueStore] backed by `shared_preferences`. If [SharedPreferences] can't
/// be reached (e.g. no platform channel under tests), it falls back to a plain
/// in-memory map and every read/write still works — just not persisted.
class SharedPrefsStore implements KeyValueStore {
  SharedPreferences? _prefs;
  final Map<String, String> _mem = {};

  @override
  Future<void> init() async {
    try {
      _prefs = await SharedPreferences.getInstance();
    } catch (_) {
      // No platform channel (tests / unsupported host): stay in-memory.
      _prefs = null;
    }
  }

  @override
  String? getString(String key) => _prefs?.getString(key) ?? _mem[key];

  @override
  Future<void> setString(String key, String value) async {
    _mem[key] = value;
    try {
      await _prefs?.setString(key, value);
    } catch (_) {
      // Ignore write failures; the in-memory copy stays authoritative.
    }
  }

  @override
  Future<void> remove(String key) async {
    _mem.remove(key);
    try {
      await _prefs?.remove(key);
    } catch (_) {
      // Ignore.
    }
  }
}

/// Pure in-memory [KeyValueStore] for tests that want to preseed values.
class MemoryKeyValueStore implements KeyValueStore {
  MemoryKeyValueStore([Map<String, String>? seed]) {
    if (seed != null) _mem.addAll(seed);
  }

  final Map<String, String> _mem = {};

  @override
  Future<void> init() async {}

  @override
  String? getString(String key) => _mem[key];

  @override
  Future<void> setString(String key, String value) async => _mem[key] = value;

  @override
  Future<void> remove(String key) async => _mem.remove(key);
}
