import 'dart:typed_data';
import 'dart:convert';

/// 应用信息模型
class AppInfo {
  final String packageName;
  final String appName;
  final Uint8List? icon;
  final String version;
  final bool isSystemApp;
  final bool isInstalled;
  bool isSelected;

  AppInfo({
    required this.packageName,
    required this.appName,
    this.icon,
    required this.version,
    required this.isSystemApp,
    this.isInstalled = true,
    this.isSelected = false,
  });

  /// 从installed_apps包的AppInfo对象创建AppInfo
  factory AppInfo.fromInstalledApp(dynamic app) {
    final Uint8List? iconBytes = app.icon is Uint8List && app.icon.isNotEmpty
        ? app.icon as Uint8List
        : null;
    return AppInfo(
      packageName: app.packageName ?? '',
      appName: app.name ?? '',
      icon: iconBytes,
      version: app.versionName ?? '',
      isSystemApp: false, // installed_apps包默认排除系统应用
      isInstalled: true,
    );
  }

  /// 转换为 JSON。
  ///
  /// 应用图标可能很大，持久化到 SharedPreferences 后会让
  /// shared_preferences 在启动或保存时通过 MethodChannel 传输超大字符串，
  /// 低内存设备上会直接 OOM。默认只序列化轻量元数据；只有明确需要导出图标时
  /// 才传入 [includeIcon]。
  Map<String, dynamic> toJson({bool includeIcon = false}) {
    final json = <String, dynamic>{
      'packageName': packageName,
      'appName': appName,
      'version': version,
      'isSystemApp': isSystemApp,
      'isInstalled': isInstalled,
      'isSelected': isSelected,
    };
    if (includeIcon && icon != null && icon!.isNotEmpty) {
      json['icon'] = base64Encode(icon!);
    }
    return json;
  }

  /// 从JSON创建AppInfo
  factory AppInfo.fromJson(
    Map<String, dynamic> json, {
    bool decodeIcon = true,
  }) {
    Uint8List? iconData;
    if (decodeIcon && json['icon'] != null) {
      try {
        iconData = base64Decode(json['icon']);
      } catch (e) {
        iconData = null;
      }
    }

    return AppInfo(
      packageName: json['packageName'] ?? '',
      appName: json['appName'] ?? '',
      icon: iconData,
      version: json['version'] ?? '',
      isSystemApp: json['isSystemApp'] ?? false,
      isInstalled: json['isInstalled'] ?? true,
      isSelected: json['isSelected'] ?? false,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is AppInfo && other.packageName == packageName;
  }

  @override
  int get hashCode => packageName.hashCode;

  @override
  String toString() {
    return 'AppInfo(packageName: $packageName, appName: $appName, isSelected: $isSelected)';
  }
}
