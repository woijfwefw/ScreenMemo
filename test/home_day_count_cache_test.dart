import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_memo/data/database/screenshot_database.dart';
import 'package:screen_memo/features/capture/application/screenshot_service.dart';
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
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(() async {
    try {
      await ScreenshotDatabase.instance.disposeDesktop();
    } catch (_) {}
  });

  test('首页天数在 day_stats_meta 缺失时优先返回轻量 day_stats 缓存', () async {
    final Directory tmp = await Directory.systemTemp.createTemp(
      'screen_memo_home_day_count_',
    );
    try {
      await ScreenshotDatabase.instance.initializeForDesktop(tmp.path);
      final db = await ScreenshotDatabase.instance.database;
      await db.insert('day_stats', <String, Object?>{
        'day': '2026-05-22',
        'screenshot_count': 12,
        'total_size_bytes': 120,
        'updated_at': 1,
      });
      await db.insert('day_stats', <String, Object?>{
        'day': '2026-05-23',
        'screenshot_count': 1,
        'total_size_bytes': 10,
        'updated_at': 1,
      });
      await db.delete('day_stats_meta', where: 'id = 1');

      final Stopwatch sw = Stopwatch()..start();
      final int count = await ScreenshotService.instance
          .getAvailableDayCountCachedFirst()
          .timeout(const Duration(seconds: 1));
      sw.stop();

      expect(count, 2);
      expect(sw.elapsedMilliseconds, lessThan(1000));
      await ScreenshotDatabase.instance.disposeDesktop();
    } finally {
      await ScreenshotDatabase.instance.disposeDesktop();
      await _deleteTempDir(tmp);
    }
  });
}
