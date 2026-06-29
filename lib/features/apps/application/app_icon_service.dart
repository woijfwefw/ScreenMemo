import 'dart:collection';
import 'package:flutter/services.dart';

class AppIconService {
  static final AppIconService _instance = AppIconService._internal();
  static AppIconService get instance => _instance;
  AppIconService._internal();

  static const MethodChannel _channel = MethodChannel(
    'com.fqyw.screen_memo/accessibility',
  );

  static const int _maxEntries = 160;
  static const int _maxBytes = 8 * 1024 * 1024;
  static const Duration _missTtl = Duration(minutes: 10);

  final LinkedHashMap<String, _CachedIcon> _cache =
      LinkedHashMap<String, _CachedIcon>();
  final Map<String, Future<Uint8List?>> _inFlight =
      <String, Future<Uint8List?>>{};
  final Map<String, DateTime> _missUntilByKey = <String, DateTime>{};
  int _totalBytes = 0;

  Uint8List? getCached(String packageName, {required int sizePx}) {
    final key = _cacheKey(packageName, sizePx);
    final cached = _cache.remove(key);
    if (cached == null) return null;
    _cache[key] = cached;
    return cached.bytes;
  }

  Future<Uint8List?> loadIcon(String packageName, {required int sizePx}) {
    final pkg = packageName.trim();
    if (pkg.isEmpty) return Future<Uint8List?>.value(null);

    final key = _cacheKey(pkg, sizePx);
    final cached = getCached(pkg, sizePx: sizePx);
    if (cached != null) return Future<Uint8List?>.value(cached);

    final missUntil = _missUntilByKey[key];
    if (missUntil != null && DateTime.now().isBefore(missUntil)) {
      return Future<Uint8List?>.value(null);
    }

    final existing = _inFlight[key];
    if (existing != null) return existing;

    final future = _loadIconFromNative(pkg, _normalizeSizePx(sizePx))
        .then((bytes) {
          if (bytes != null && bytes.isNotEmpty) {
            _put(key, bytes);
            _missUntilByKey.remove(key);
            return bytes;
          }
          _missUntilByKey[key] = DateTime.now().add(_missTtl);
          return null;
        })
        .catchError((_) {
          _missUntilByKey[key] = DateTime.now().add(_missTtl);
          return null;
        })
        .whenComplete(() {
          _inFlight.remove(key);
        });

    _inFlight[key] = future;
    return future;
  }

  void clearMemoryCache() {
    _cache.clear();
    _inFlight.clear();
    _missUntilByKey.clear();
    _totalBytes = 0;
  }

  Future<Uint8List?> _loadIconFromNative(String packageName, int sizePx) async {
    final bytes = await _channel.invokeMethod<Uint8List>('getAppIcon', {
      'packageName': packageName,
      'sizePx': sizePx,
    });
    if (bytes == null || bytes.isEmpty) return null;
    return bytes;
  }

  void _put(String key, Uint8List bytes) {
    final old = _cache.remove(key);
    if (old != null) {
      _totalBytes -= old.bytes.lengthInBytes;
    }
    _cache[key] = _CachedIcon(bytes);
    _totalBytes += bytes.lengthInBytes;
    _evictIfNeeded();
  }

  void _evictIfNeeded() {
    while (_cache.length > _maxEntries || _totalBytes > _maxBytes) {
      if (_cache.isEmpty) break;
      final oldestKey = _cache.keys.first;
      final oldest = _cache.remove(oldestKey);
      if (oldest != null) {
        _totalBytes -= oldest.bytes.lengthInBytes;
      }
    }
  }

  String _cacheKey(String packageName, int sizePx) {
    return '${packageName.trim()}@${_normalizeSizePx(sizePx)}';
  }

  int _normalizeSizePx(int sizePx) {
    if (sizePx <= 0) return 96;
    return sizePx.clamp(32, 192);
  }
}

class _CachedIcon {
  _CachedIcon(this.bytes);

  final Uint8List bytes;
}
