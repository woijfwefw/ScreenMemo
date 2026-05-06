import 'dart:io';

import 'package:flutter/services.dart';

/// 自动更新需要的 Android 原生能力。
class UpdatePlatformService {
  UpdatePlatformService({MethodChannel? channel})
    : _channel =
          channel ?? const MethodChannel('com.fqyw.screen_memo/accessibility');

  final MethodChannel _channel;

  Future<List<String>> getSupportedAbis() async {
    if (!Platform.isAndroid) return const <String>[];
    final List<dynamic>? raw = await _channel.invokeMethod<List<dynamic>>(
      'getSupportedAbis',
    );
    return (raw ?? const <dynamic>[])
        .map((item) => item.toString())
        .where((item) => item.trim().isNotEmpty)
        .toList(growable: false);
  }

  Future<bool> canRequestPackageInstalls() async {
    if (!Platform.isAndroid) return false;
    final bool? allowed = await _channel.invokeMethod<bool>(
      'canRequestPackageInstalls',
    );
    return allowed == true;
  }

  Future<bool> openInstallPermissionSettings() async {
    if (!Platform.isAndroid) return false;
    final bool? opened = await _channel.invokeMethod<bool>(
      'openInstallPermissionSettings',
    );
    return opened == true;
  }

  Future<bool> installApk(String path) async {
    if (!Platform.isAndroid) return false;
    final bool? opened = await _channel.invokeMethod<bool>('installApk', {
      'path': path,
    });
    return opened == true;
  }
}
