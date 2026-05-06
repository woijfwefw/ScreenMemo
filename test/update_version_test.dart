import 'package:flutter_test/flutter_test.dart';
import 'package:screen_memo/features/updater/application/update_models.dart';
import 'package:screen_memo/features/updater/application/update_version.dart';

void main() {
  group('UpdateVersionComparator', () {
    test('compares semantic release tags', () {
      expect(
        UpdateVersionComparator.compare('v1.1.1', '1.0.0'),
        greaterThan(0),
      );
      expect(UpdateVersionComparator.compare('1.1.1', 'v1.1.1'), 0);
      expect(UpdateVersionComparator.compare('v1.1.0', '1.1.1'), lessThan(0));
    });

    test('normalizes leading v prefix', () {
      expect(UpdateVersionComparator.normalize('v1.2.3'), '1.2.3');
      expect(UpdateVersionComparator.normalize('V2.0.0'), '2.0.0');
    });
  });

  group('UpdateAssetSelector', () {
    const assets = <UpdateReleaseAsset>[
      UpdateReleaseAsset(
        name: 'screen_memo-v1.1.1-app-armeabi-v7a-release.apk',
        downloadUrl: 'https://example.com/armeabi.apk',
      ),
      UpdateReleaseAsset(
        name: 'screen_memo-v1.1.1-app-arm64-v8a-release.apk',
        downloadUrl: 'https://example.com/arm64.apk',
      ),
      UpdateReleaseAsset(
        name: 'screen_memo-v1.1.1-app-x86_64-release.apk',
        downloadUrl: 'https://example.com/x86.apk',
      ),
    ];

    test('selects the first supported ABI in device preference order', () {
      final selected = UpdateAssetSelector.select(assets, const <String>[
        'x86_64',
        'arm64-v8a',
      ]);

      expect(selected?.name, contains('x86_64'));
    });

    test('falls back to arm64 APK when ABI list is empty', () {
      final selected = UpdateAssetSelector.select(assets, const <String>[]);

      expect(selected?.name, contains('arm64-v8a'));
    });
  });
}
