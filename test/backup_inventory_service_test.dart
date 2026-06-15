import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_memo/features/backup/data/backup_inventory_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('scan classifies full backup roots and excluded bytes', () async {
    final Directory tempDir = await Directory.systemTemp.createTemp(
      'screenmemo_backup_inventory_',
    );
    try {
      final Directory dataRoot = Directory('${tempDir.path}/data');
      final Directory filesDir = Directory('${dataRoot.path}/files');
      final Directory outputDir = Directory('${filesDir.path}/output');
      final Directory sharedPrefsDir = Directory(
        '${dataRoot.path}/shared_prefs',
      );
      final Directory appFlutterDir = Directory('${dataRoot.path}/app_flutter');
      final Directory noBackupDir = Directory('${dataRoot.path}/no_backup');
      final Directory appDatabasesDir = Directory('${dataRoot.path}/databases');
      final Directory cacheDir = Directory('${dataRoot.path}/cache');
      final Directory codeCacheDir = Directory('${dataRoot.path}/code_cache');

      await File('${outputDir.path}/screen/com.demo/a.png')
          .create(recursive: true)
          .then((File f) => f.writeAsBytes(List<int>.filled(10, 1)));
      await File(
        '${outputDir.path}/databases/screenshot_memo.db',
      ).create(recursive: true).then((File f) => f.writeAsString('master'));
      await File(
        '${outputDir.path}/databases/screenshot_memo.db-wal',
      ).create(recursive: true).then((File f) => f.writeAsString('wal'));
      await File(
        '${outputDir.path}/databases/shards/com_demo/2024/smm_com_demo_2024.db',
      ).create(recursive: true).then((File f) => f.writeAsString('shard'));
      await File(
        '${outputDir.path}/databases/shards/com_demo/settings.db',
      ).create(recursive: true).then((File f) => f.writeAsString('settings'));
      await File(
        '${outputDir.path}/replay/replay.jsonl',
      ).create(recursive: true).then((File f) => f.writeAsString('replay'));
      await File(
        '${sharedPrefsDir.path}/FlutterSharedPreferences.xml',
      ).create(recursive: true).then((File f) => f.writeAsString('prefs'));
      await File(
        '${appFlutterDir.path}/state.json',
      ).create(recursive: true).then((File f) => f.writeAsString('flutter'));
      await File(
        '${noBackupDir.path}/session.txt',
      ).create(recursive: true).then((File f) => f.writeAsString('no_backup'));
      await File(
        '${appDatabasesDir.path}/plugin.db',
      ).create(recursive: true).then((File f) => f.writeAsString('plugin'));
      await File(
        '${filesDir.path}/persistent_private/ai/chat_attachments/a.jpg',
      ).create(recursive: true).then((File f) => f.writeAsString('attachment'));
      await File(
        '${filesDir.path}/skills/demo/SKILL.md',
      ).create(recursive: true).then((File f) => f.writeAsString('skill'));
      await File(
        '${filesDir.path}/skills/.screenmemo_skills_state.json',
      ).create(recursive: true).then((File f) => f.writeAsString('state'));
      await File(
        '${filesDir.path}/.secure_keys.json',
      ).create(recursive: true).then((File f) => f.writeAsString('keys'));
      await File('${cacheDir.path}/cache.bin')
          .create(recursive: true)
          .then((File f) => f.writeAsBytes(List<int>.filled(7, 2)));
      await File('${codeCacheDir.path}/code.bin')
          .create(recursive: true)
          .then((File f) => f.writeAsBytes(List<int>.filled(9, 3)));
      await File('${outputDir.path}/cache/tmp.bin')
          .create(recursive: true)
          .then((File f) => f.writeAsBytes(List<int>.filled(5, 4)));

      final BackupInventory inventory = await BackupInventoryService.scan(
        roots: BackupRootPaths(
          filesDirPath: filesDir.path,
          dataRootPath: dataRoot.path,
          outputDirPath: outputDir.path,
          appDatabasesDirPath: appDatabasesDir.path,
          sharedPrefsDirPath: sharedPrefsDir.path,
          appFlutterDirPath: appFlutterDir.path,
          noBackupDirPath: noBackupDir.path,
        ),
      );

      expect(inventory.totalFiles, 14);
      expect(
        inventory.categoryById(BackupCategoryIds.screenshots)?.fileCount,
        1,
      );
      expect(
        inventory.categoryById(BackupCategoryIds.mainDatabase)?.fileCount,
        2,
      );
      expect(
        inventory.categoryById(BackupCategoryIds.shardDatabases)?.fileCount,
        1,
      );
      expect(
        inventory.categoryById(BackupCategoryIds.perAppSettings)?.fileCount,
        1,
      );
      expect(
        inventory.categoryById(BackupCategoryIds.otherOutput)?.fileCount,
        1,
      );
      expect(
        inventory.categoryById(BackupCategoryIds.sharedPrefs)?.fileCount,
        1,
      );
      expect(
        inventory.categoryById(BackupCategoryIds.appFlutter)?.fileCount,
        1,
      );
      expect(inventory.categoryById(BackupCategoryIds.noBackup)?.fileCount, 1);
      expect(
        inventory.categoryById(BackupCategoryIds.appDatabases)?.fileCount,
        1,
      );
      expect(inventory.categoryById(BackupCategoryIds.appFiles)?.fileCount, 4);
      expect(
        inventory
            .categoryById(BackupCategoryIds.appFiles)!
            .files
            .map((BackupInventoryFile file) => file.archivePath),
        containsAll(<String>[
          'files/persistent_private/ai/chat_attachments/a.jpg',
          'files/skills/demo/SKILL.md',
          'files/skills/.screenmemo_skills_state.json',
          'files/.secure_keys.json',
        ]),
      );
      expect(
        inventory
            .categoryById(BackupCategoryIds.appFiles)!
            .files
            .map((BackupInventoryFile file) => file.archivePath),
        isNot(contains('files/output/screen/com.demo/a.png')),
      );
      expect(inventory.requiresRestartAfterImport, isTrue);

      final BackupExcludedItem cacheExcluded = inventory.excludedItems
          .firstWhere(
            (BackupExcludedItem item) => item.id == BackupExcludedIds.cache,
          );
      final BackupExcludedItem outputTempExcluded = inventory.excludedItems
          .firstWhere(
            (BackupExcludedItem item) =>
                item.id == BackupExcludedIds.outputTemp,
          );
      expect(cacheExcluded.bytes, greaterThan(0));
      expect(outputTempExcluded.bytes, greaterThan(0));
    } finally {
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'inspectArchiveFile reads backup roots from central directory only',
    () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'screenmemo_backup_inspect_',
      );
      try {
        final File manifest = await File(
          '${tempDir.path}/$backupManifestFileName',
        ).create(recursive: true);
        await manifest.writeAsString('{"version":2}');

        final File outputFile = await File(
          '${tempDir.path}/output/screen/demo/a.png',
        ).create(recursive: true);
        await outputFile.writeAsBytes(List<int>.filled(32, 7));

        final File sharedPrefsFile = await File(
          '${tempDir.path}/shared_prefs/FlutterSharedPreferences.xml',
        ).create(recursive: true);
        await sharedPrefsFile.writeAsString('<prefs />');
        final File filesRootFile = await File(
          '${tempDir.path}/files/persistent_private/ai/chat_attachments/a.jpg',
        ).create(recursive: true);
        await filesRootFile.writeAsString('attachment');

        final String zipPath = '${tempDir.path}/backup.zip';
        final ZipFileEncoder encoder = ZipFileEncoder();
        encoder.create(zipPath, level: 0);
        encoder.addFile(manifest, backupManifestFileName);
        encoder.addFile(outputFile, 'output/screen/demo/a.png');
        encoder.addFile(
          sharedPrefsFile,
          'shared_prefs/FlutterSharedPreferences.xml',
        );
        encoder.addFile(
          filesRootFile,
          'files/persistent_private/ai/chat_attachments/a.jpg',
        );
        encoder.close();

        final BackupArchiveInspection inspection =
            await BackupInventoryService.inspectArchiveFile(zipPath);

        expect(inspection.hasManifest, isTrue);
        expect(inspection.rootEntries, contains('output'));
        expect(inspection.rootEntries, contains('shared_prefs'));
        expect(inspection.rootEntries, contains('files'));
        expect(inspection.manifestRequiresRestart, isTrue);
      } finally {
        await tempDir.delete(recursive: true);
      }
    },
  );

  test('filterInventoryByScope keeps only database categories', () async {
    const BackupRootPaths roots = BackupRootPaths(
      filesDirPath: '/data/files',
      dataRootPath: '/data',
      outputDirPath: '/data/files/output',
      appDatabasesDirPath: '/data/databases',
    );
    const BackupInventory inventory = BackupInventory(
      roots: roots,
      categories: <BackupInventoryCategory>[
        BackupInventoryCategory(
          id: BackupCategoryIds.screenshots,
          files: <BackupInventoryFile>[
            BackupInventoryFile(
              sourcePath: '/tmp/a.png',
              archivePath: 'output/screen/demo/a.png',
              bytes: 10,
              categoryId: BackupCategoryIds.screenshots,
            ),
          ],
          totalBytes: 10,
          fileCount: 1,
        ),
        BackupInventoryCategory(
          id: BackupCategoryIds.mainDatabase,
          files: <BackupInventoryFile>[
            BackupInventoryFile(
              sourcePath: '/tmp/main.db',
              archivePath: 'output/databases/screenshot_memo.db',
              bytes: 20,
              categoryId: BackupCategoryIds.mainDatabase,
            ),
          ],
          totalBytes: 20,
          fileCount: 1,
        ),
        BackupInventoryCategory(
          id: BackupCategoryIds.appDatabases,
          files: <BackupInventoryFile>[
            BackupInventoryFile(
              sourcePath: '/tmp/plugin.db',
              archivePath: 'databases/plugin.db',
              bytes: 30,
              categoryId: BackupCategoryIds.appDatabases,
            ),
          ],
          totalBytes: 30,
          fileCount: 1,
        ),
      ],
      excludedItems: <BackupExcludedItem>[],
      totalBytes: 60,
      totalFiles: 3,
      warnings: <String>[],
    );

    final BackupInventory filtered =
        BackupInventoryService.filterInventoryByScope(
          inventory,
          BackupExportScope.databasesOnly,
        );

    expect(
      filtered.categories.map((BackupInventoryCategory e) => e.id).toList(),
      <String>[BackupCategoryIds.mainDatabase, BackupCategoryIds.appDatabases],
    );
    expect(filtered.totalBytes, 50);
    expect(filtered.totalFiles, 2);
  });
}
