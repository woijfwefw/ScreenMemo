import 'package:flutter_test/flutter_test.dart';
import 'package:screen_memo/features/updater/application/update_changelog.dart';

void main() {
  group('UpdateChangelogText', () {
    test('splits release body into virtual-list items', () {
      final items = UpdateChangelogText.releaseBodyItems(
        '- Add update notes\n'
        '- Improve updater prompt\n'
        'Full Changelog: v1.1.3...v1.1.4',
      );

      expect(items, <String>['Add update notes', 'Improve updater prompt']);
    });

    test('keeps plain text release note lines', () {
      final items = UpdateChangelogText.releaseBodyItems(
        'Add update notes\nImprove updater prompt',
      );

      expect(items, <String>['Add update notes', 'Improve updater prompt']);
    });
  });
}
