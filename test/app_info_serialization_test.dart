import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_memo/models/app_info.dart';

void main() {
  test('AppInfo.toJson omits icon by default to keep preferences small', () {
    final app = AppInfo(
      packageName: 'com.example.large',
      appName: 'Large App',
      icon: Uint8List.fromList(List<int>.filled(4096, 7)),
      version: '1.0',
      isSystemApp: false,
      isInstalled: true,
      isSelected: true,
    );

    final json = app.toJson();

    expect(json.containsKey('icon'), isFalse);
    expect(jsonEncode(json), isNot(contains('icon')));
  });

  test('AppInfo.toJson can include icon only when explicitly requested', () {
    final app = AppInfo(
      packageName: 'com.example.large',
      appName: 'Large App',
      icon: Uint8List.fromList(<int>[1, 2, 3]),
      version: '1.0',
      isSystemApp: false,
    );

    final json = app.toJson(includeIcon: true);

    expect(json['icon'], base64Encode(<int>[1, 2, 3]));
  });

  test('AppInfo.fromJson can skip legacy icon payloads', () {
    final app = AppInfo.fromJson(<String, dynamic>{
      'packageName': 'com.example.large',
      'appName': 'Large App',
      'version': '1.0',
      'isSystemApp': false,
      'icon': base64Encode(<int>[1, 2, 3]),
    }, decodeIcon: false);

    expect(app.icon, isNull);
    expect(app.packageName, 'com.example.large');
  });
}
