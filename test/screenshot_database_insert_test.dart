import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:screen_memo/data/database/screenshot_database.dart';
import 'package:screen_memo/models/screenshot_record.dart';
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

  test('截图入库不会在汇总更新时嵌套开启主库事务', () async {
    final Directory tmp = await Directory.systemTemp.createTemp(
      'screen_memo_insert_screenshot_',
    );
    try {
      await ScreenshotDatabase.instance.initializeForDesktop(tmp.path);

      final File imageFile = File(
        p.join(
          tmp.path,
          'output',
          'screen',
          'pkg.demo',
          '2026-05',
          '06',
          'demo.webp',
        ),
      );
      await imageFile.parent.create(recursive: true);
      await imageFile.writeAsBytes(<int>[1, 2, 3, 4]);

      final ScreenshotRecord record = ScreenshotRecord(
        appPackageName: 'pkg.demo',
        appName: 'Demo',
        filePath: imageFile.path,
        captureTime: DateTime(2026, 5, 6, 18, 38),
        fileSize: 0,
      );

      final int? gid = await ScreenshotDatabase.instance
          .insertScreenshotIfNotExists(record)
          .timeout(const Duration(seconds: 3));

      expect(gid, isNotNull);

      final List<ScreenshotRecord> screenshots = await ScreenshotDatabase
          .instance
          .getScreenshotsByApp('pkg.demo');
      expect(screenshots, hasLength(1));
      expect(screenshots.single.filePath, imageFile.path);
      expect(screenshots.single.fileSize, 4);

      final db = await ScreenshotDatabase.instance.database;
      final List<Map<String, Object?>> totals = await db.query(
        'totals',
        where: 'id = ?',
        whereArgs: <Object>[1],
        limit: 1,
      );
      expect(totals, hasLength(1));
      expect(totals.single['app_count'], 1);
      expect(totals.single['screenshot_count'], 1);
      expect(totals.single['total_size_bytes'], 4);

      final int? duplicated = await ScreenshotDatabase.instance
          .insertScreenshotIfNotExists(record)
          .timeout(const Duration(seconds: 3));
      expect(duplicated, isNull);

      final List<Map<String, Object?>> totalsAfterDuplicate = await db.query(
        'totals',
        where: 'id = ?',
        whereArgs: <Object>[1],
        limit: 1,
      );
      expect(totalsAfterDuplicate.single['screenshot_count'], 1);
    } finally {
      await ScreenshotDatabase.instance.disposeDesktop();
      await _deleteTempDir(tmp);
    }
  });

  test('证据图片文件名路径索引会写入、命中并随删除清理', () async {
    final Directory tmp = await Directory.systemTemp.createTemp(
      'screen_memo_evidence_lookup_',
    );
    try {
      await ScreenshotDatabase.instance.initializeForDesktop(tmp.path);

      final File imageFile = File(
        p.join(
          tmp.path,
          'output',
          'screen',
          'pkg.lookup',
          '2026-05',
          '25',
          'demo_lookup.webp',
        ),
      );
      await imageFile.parent.create(recursive: true);
      await imageFile.writeAsBytes(<int>[9, 8, 7]);

      final ScreenshotRecord record = ScreenshotRecord(
        appPackageName: 'pkg.lookup',
        appName: 'Lookup',
        filePath: imageFile.path,
        captureTime: DateTime(2026, 5, 25, 22, 5, 28),
        fileSize: 0,
      );

      final int? gid = await ScreenshotDatabase.instance
          .insertScreenshotIfNotExists(record)
          .timeout(const Duration(seconds: 3));
      expect(gid, isNotNull);

      final String? byName = await ScreenshotDatabase.instance
          .findScreenshotPathByBasename('demo_lookup.webp');
      expect(byName, imageFile.path);

      final String? byStem = await ScreenshotDatabase.instance
          .findScreenshotPathByBasename('demo_lookup');
      expect(byStem, imageFile.path);

      final ScreenshotRecord? byPath = await ScreenshotDatabase.instance
          .getScreenshotByPath(imageFile.path);
      expect(byPath?.filePath, imageFile.path);
      expect(byPath?.appPackageName, 'pkg.lookup');

      final db = await ScreenshotDatabase.instance.database;
      final List<Map<String, Object?>> rows = await db.query(
        'screenshot_path_lookup',
        where: 'file_path = ?',
        whereArgs: <Object>[imageFile.path],
      );
      expect(rows, hasLength(1));
      expect(rows.single['filename_key'], 'demo_lookup.webp');
      expect(rows.single['filename_stem_key'], 'demo_lookup');
      expect(rows.single['app_package_name'], 'pkg.lookup');

      final bool deleted = await ScreenshotDatabase.instance.deleteScreenshot(
        gid!,
        'pkg.lookup',
      );
      expect(deleted, isTrue);
      expect(await imageFile.exists(), isFalse);

      final List<Map<String, Object?>> rowsAfterDelete = await db.query(
        'screenshot_path_lookup',
        where: 'file_path = ?',
        whereArgs: <Object>[imageFile.path],
      );
      expect(rowsAfterDelete, isEmpty);

      final String? afterDelete = await ScreenshotDatabase.instance
          .findScreenshotPathByBasename('demo_lookup.webp');
      expect(afterDelete, isNull);
    } finally {
      await ScreenshotDatabase.instance.disposeDesktop();
      await _deleteTempDir(tmp);
    }
  });
}
