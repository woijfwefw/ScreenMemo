import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:screen_memo/core/constants/user_settings_keys.dart';
import 'package:screen_memo/data/database/screenshot_database.dart';
import 'package:screen_memo/data/settings/user_settings_service.dart';
import 'package:screen_memo/l10n/app_localizations_en.dart';
import 'package:screen_memo/l10n/app_localizations_ja.dart';
import 'package:screen_memo/l10n/app_localizations_ko.dart';
import 'package:screen_memo/l10n/app_localizations_zh.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _deleteTempDir(Directory dir) async {
  for (int attempt = 0; attempt < 5; attempt++) {
    try {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
      return;
    } on PathAccessException {
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDown(() async {
    try {
      await ScreenshotDatabase.instance.disposeDesktop();
    } catch (_) {}
  });

  test(
    'screenshot dedupe mode defaults to balanced and persists all modes',
    () async {
      final Directory tmp = await Directory.systemTemp.createTemp(
        'screen_memo_dedupe_mode_',
      );
      try {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        await ScreenshotDatabase.instance.initializeForDesktop(tmp.path);

        expect(
          await UserSettingsService.instance.getString(
            UserSettingKeys.screenshotDedupeMode,
            defaultValue: 'balanced',
          ),
          'balanced',
        );

        for (final String mode in <String>[
          'exact',
          'conservative',
          'balanced',
          'aggressive',
        ]) {
          await UserSettingsService.instance.setString(
            UserSettingKeys.screenshotDedupeMode,
            mode,
          );
          expect(
            await UserSettingsService.instance.getString(
              UserSettingKeys.screenshotDedupeMode,
            ),
            mode,
          );
        }

        final dbPath = p.join(
          tmp.path,
          'output',
          'databases',
          'screenshot_memo.db',
        );
        expect(File(dbPath).existsSync(), isTrue);
      } finally {
        await ScreenshotDatabase.instance.disposeDesktop();
        await _deleteTempDir(tmp);
      }
    },
  );

  test('screenshot dedupe mode localization exposes four choices', () {
    final en = AppLocalizationsEn();
    expect(en.screenshotDedupeModeExact, 'Off / exact');
    expect(en.screenshotDedupeModeConservative, 'Conservative');
    expect(en.screenshotDedupeModeBalanced, 'Balanced');
    expect(en.screenshotDedupeModeAggressive, 'Aggressive');
    expect(en.screenshotDedupeModeCurrent('Balanced'), 'Current: Balanced');

    final zh = AppLocalizationsZh();
    expect(zh.screenshotDedupeModeExact, '关闭/精确');
    expect(zh.screenshotDedupeModeConservative, '保守');
    expect(zh.screenshotDedupeModeBalanced, '均衡');
    expect(zh.screenshotDedupeModeAggressive, '激进');
    expect(zh.screenshotDedupeModeCurrent('均衡'), '当前：均衡');

    final ja = AppLocalizationsJa();
    expect(ja.screenshotDedupeModeExact, 'オフ / 完全一致');
    expect(ja.screenshotDedupeModeConservative, '控えめ');
    expect(ja.screenshotDedupeModeBalanced, 'バランス');
    expect(ja.screenshotDedupeModeAggressive, '強め');

    final ko = AppLocalizationsKo();
    expect(ko.screenshotDedupeModeExact, '끄기 / 정확히 일치');
    expect(ko.screenshotDedupeModeConservative, '보수적');
    expect(ko.screenshotDedupeModeBalanced, '균형');
    expect(ko.screenshotDedupeModeAggressive, '적극적');
  });
}
