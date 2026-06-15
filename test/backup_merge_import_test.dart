import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:screen_memo/data/database/screenshot_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:screen_memo/features/backup/data/backup_inventory_service.dart';

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

  test('合并导入全量备份时跳过非 output 根目录', () async {
    final Directory tmp = await Directory.systemTemp.createTemp(
      'screen_memo_merge_full_backup_',
    );
    try {
      await ScreenshotDatabase.instance.initializeForDesktop(
        p.join(tmp.path, 'target'),
      );

      final Directory source = Directory(p.join(tmp.path, 'source'));
      final File manifest = File(p.join(source.path, backupManifestFileName));
      await manifest.create(recursive: true);
      await manifest.writeAsString('{"version":2}');

      final File replay = File(
        p.join(source.path, 'output', 'replay', 'replay.jsonl'),
      );
      await replay.create(recursive: true);
      await replay.writeAsString('{"ok":true}\n');

      final File prefs = File(
        p.join(source.path, 'shared_prefs', 'FlutterSharedPreferences.xml'),
      );
      await prefs.create(recursive: true);
      await prefs.writeAsString('<prefs />');

      final File appDb = File(
        p.join(
          source.path,
          'databases',
          'shards',
          'com_pl_getaway_rescueTime',
          'settings.db',
        ),
      );
      await appDb.create(recursive: true);
      await appDb.writeAsString('not a real sqlite db');

      final String zipPath = p.join(tmp.path, 'full_backup.zip');
      final ZipFileEncoder encoder = ZipFileEncoder();
      encoder.create(zipPath, level: 0);
      await encoder.addFile(manifest, backupManifestFileName);
      await encoder.addFile(replay, 'output/replay/replay.jsonl');
      await encoder.addFile(prefs, 'shared_prefs/FlutterSharedPreferences.xml');
      await encoder.addFile(
        appDb,
        'databases/shards/com_pl_getaway_rescueTime/settings.db',
      );
      encoder.close();

      final MergeReport? report = await ScreenshotDatabase.instance
          .mergeDataFromZip(zipPath: zipPath, throwOnError: true)
          .timeout(const Duration(seconds: 5));

      expect(report, isNotNull);
      expect(report!.copiedFiles, 1);
      expect(
        File(
          p.join(tmp.path, 'target', 'output', 'replay', 'replay.jsonl'),
        ).existsSync(),
        isTrue,
      );
    } finally {
      try {
        await ScreenshotDatabase.instance.disposeDesktop();
      } catch (_) {}
      if (await tmp.exists()) {
        await tmp.delete(recursive: true);
      }
    }
  });

  test('合并导入兼容无 manifest 的 output 根 ZIP', () async {
    final Directory tmp = await Directory.systemTemp.createTemp(
      'screen_memo_merge_legacy_backup_',
    );
    try {
      await ScreenshotDatabase.instance.initializeForDesktop(
        p.join(tmp.path, 'target'),
      );

      final Directory source = Directory(p.join(tmp.path, 'source'));
      final File extraDb = File(p.join(source.path, 'databases', 'plugin.db'));
      await extraDb.create(recursive: true);
      await extraDb.writeAsString('plugin');

      final String zipPath = p.join(tmp.path, 'legacy_backup.zip');
      final ZipFileEncoder encoder = ZipFileEncoder();
      encoder.create(zipPath, level: 0);
      await encoder.addFile(extraDb, 'databases/plugin.db');
      encoder.close();

      final MergeReport? report = await ScreenshotDatabase.instance
          .mergeDataFromZip(zipPath: zipPath, throwOnError: true)
          .timeout(const Duration(seconds: 5));

      expect(report, isNotNull);
      expect(
        File(
          p.join(tmp.path, 'target', 'output', 'databases', 'plugin.db'),
        ).existsSync(),
        isTrue,
      );
    } finally {
      try {
        await ScreenshotDatabase.instance.disposeDesktop();
      } catch (_) {}
      if (await tmp.exists()) {
        await tmp.delete(recursive: true);
      }
    }
  });

  test('覆盖导入 files 根时恢复持久文件且保留 output', () async {
    final Directory tmp = await Directory.systemTemp.createTemp(
      'screen_memo_import_files_root_',
    );
    try {
      final String targetPath = p.join(tmp.path, 'target');
      await ScreenshotDatabase.instance.initializeForDesktop(targetPath);

      final File keptOutput = File(
        p.join(targetPath, 'output', 'screen', 'demo', 'kept.png'),
      );
      await keptOutput.create(recursive: true);
      await keptOutput.writeAsString('kept');

      final File oldSkill = File(
        p.join(targetPath, 'skills', 'old', 'SKILL.md'),
      );
      await oldSkill.create(recursive: true);
      await oldSkill.writeAsString('old');

      final Directory source = Directory(p.join(tmp.path, 'source'));
      final File manifest = File(p.join(source.path, backupManifestFileName));
      await manifest.create(recursive: true);
      await manifest.writeAsString('{"version":2}');

      final File attachment = File(
        p.join(
          source.path,
          'files',
          'persistent_private',
          'ai',
          'chat_attachments',
          'a.jpg',
        ),
      );
      await attachment.create(recursive: true);
      await attachment.writeAsString('attachment');

      final File skill = File(
        p.join(source.path, 'files', 'skills', 'demo', 'SKILL.md'),
      );
      await skill.create(recursive: true);
      await skill.writeAsString('skill');

      final File secureKeys = File(
        p.join(source.path, 'files', '.secure_keys.json'),
      );
      await secureKeys.create(recursive: true);
      await secureKeys.writeAsString('keys');

      final File duplicatedOutput = File(
        p.join(source.path, 'files', 'output', 'should_not_restore.txt'),
      );
      await duplicatedOutput.create(recursive: true);
      await duplicatedOutput.writeAsString('skip');

      final String zipPath = p.join(tmp.path, 'files_root_backup.zip');
      final ZipFileEncoder encoder = ZipFileEncoder();
      encoder.create(zipPath, level: 0);
      await encoder.addFile(manifest, backupManifestFileName);
      await encoder.addFile(
        attachment,
        'files/persistent_private/ai/chat_attachments/a.jpg',
      );
      await encoder.addFile(skill, 'files/skills/demo/SKILL.md');
      await encoder.addFile(secureKeys, 'files/.secure_keys.json');
      await encoder.addFile(
        duplicatedOutput,
        'files/output/should_not_restore.txt',
      );
      encoder.close();

      final Map<String, dynamic>? result = await ScreenshotDatabase.instance
          .importDataFromZipStreaming(zipPath: zipPath, overwrite: true)
          .timeout(const Duration(seconds: 5));

      expect(result, isNotNull);
      expect(result!['restoredRoots'], contains('files'));
      expect(await keptOutput.exists(), isTrue);
      expect(await oldSkill.exists(), isFalse);
      expect(
        await File(
          p.join(
            targetPath,
            'persistent_private',
            'ai',
            'chat_attachments',
            'a.jpg',
          ),
        ).exists(),
        isTrue,
      );
      expect(
        await File(p.join(targetPath, 'skills', 'demo', 'SKILL.md')).exists(),
        isTrue,
      );
      expect(
        await File(p.join(targetPath, '.secure_keys.json')).exists(),
        isTrue,
      );
      expect(
        await File(
          p.join(targetPath, 'output', 'should_not_restore.txt'),
        ).exists(),
        isFalse,
      );
    } finally {
      try {
        await ScreenshotDatabase.instance.disposeDesktop();
      } catch (_) {}
      if (await tmp.exists()) {
        await tmp.delete(recursive: true);
      }
    }
  });
}
