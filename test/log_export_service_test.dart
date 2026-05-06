import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:screen_memo/features/diagnostics/application/log_export_service.dart';

void main() {
  group('LogExportService', () {
    late Directory tempDir;
    late Directory logsRoot;
    late Directory outDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'screen_memo_log_export_test_',
      );
      logsRoot = Directory(p.join(tempDir.path, 'output', 'logs'));
      outDir = Directory(p.join(tempDir.path, 'zip_out'));
      await logsRoot.create(recursive: true);
      await outDir.create(recursive: true);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('按 yyyy/MM/dd 聚合并按日期倒序排序', () async {
      await _writeFile(
        logsRoot,
        p.join('2026', '05', '06', '06_info.log'),
        'hello',
      );
      await _writeFile(
        logsRoot,
        p.join('2026', '05', '06', 'ai_gateway_logs', 'stream.log'),
        'gateway',
      );
      await _writeFile(
        logsRoot,
        p.join('2026', '05', '07', '07_error.log'),
        'boom',
      );
      await _writeFile(logsRoot, p.join('bad', 'ignored.log'), 'ignored');

      final List<LogDaySummary> days = await LogExportService.listLogDays(
        logsRoot: logsRoot,
      );

      expect(days, hasLength(2));
      expect(_dateKey(days[0].date), '2026-05-07');
      expect(_dateKey(days[1].date), '2026-05-06');
      expect(days[1].fileCount, 2);
      expect(days[1].totalBytes, 'hellogateway'.length);
    });

    test('按文件列出日志并保留相对路径', () async {
      await _writeFile(
        logsRoot,
        p.join('2026', '05', '06', '06_info.log'),
        'hello',
      );
      await _writeFile(
        logsRoot,
        p.join('2026', '05', '06', 'ai_gateway_logs', 'stream.log'),
        'gateway',
      );
      await _writeFile(
        logsRoot,
        p.join('2026', '05', '07', '07_error.log'),
        'boom',
      );
      await _writeFile(logsRoot, p.join('2026', 'bad.log'), 'ignored');

      final List<LogFileSummary> files = await LogExportService.listLogFiles(
        logsRoot: logsRoot,
      );

      expect(files, hasLength(3));
      expect(_dateKey(files[0].date), '2026-05-07');
      expect(
        files.map((LogFileSummary file) => file.archivePath),
        containsAll(<String>[
          'output/logs/2026/05/06/06_info.log',
          'output/logs/2026/05/06/ai_gateway_logs/stream.log',
          'output/logs/2026/05/07/07_error.log',
        ]),
      );
    });

    test('按目录层级只列出当前目录直接子项', () async {
      await _writeFile(
        logsRoot,
        p.join('2026', '05', '06', '06_info.log'),
        'hello',
      );
      await _writeFile(
        logsRoot,
        p.join('2026', '05', '06', 'ai_gateway_logs', 'stream.log'),
        'gateway',
      );
      await _writeFile(
        logsRoot,
        p.join('2026', '05', '07', '07_error.log'),
        'boom',
      );

      final LogDirectoryListing root = await LogExportService.listDirectory(
        logsRoot: logsRoot,
      );
      final LogDirectoryListing day = await LogExportService.listDirectory(
        relativePath: '2026/05/06',
        logsRoot: logsRoot,
      );

      expect(root.entries.map((LogBrowserEntry entry) => entry.name), <String>[
        '2026',
      ]);
      expect(root.entries.single.fileCount, 3);
      expect(day.entries.map((LogBrowserEntry entry) => entry.name), <String>[
        'ai_gateway_logs',
        '06_info.log',
      ]);
      expect(day.entries.first.isDirectory, isTrue);
      expect(day.entries.first.fileCount, 1);
    });

    test('目录浏览项 ZIP 只包含该文件夹内容', () async {
      await _writeFile(
        logsRoot,
        p.join('2026', '05', '06', '06_info.log'),
        'hello',
      );
      await _writeFile(
        logsRoot,
        p.join('2026', '05', '06', 'ai_gateway_logs', 'stream.log'),
        'gateway',
      );
      await _writeFile(
        logsRoot,
        p.join('2026', '05', '07', '07_error.log'),
        'boom',
      );
      final LogDirectoryListing month = await LogExportService.listDirectory(
        relativePath: '2026/05',
        logsRoot: logsRoot,
      );
      final LogBrowserEntry day06 = month.entries.firstWhere(
        (LogBrowserEntry entry) => entry.name == '06',
      );

      final File zip = await LogExportService.createZipForBrowserEntry(
        day06,
        outputDirectory: outDir,
      );
      final List<String> entries = _zipEntries(zip);

      expect(
        entries,
        containsAll(<String>[
          'output/logs/2026/05/06/06_info.log',
          'output/logs/2026/05/06/ai_gateway_logs/stream.log',
        ]),
      );
      expect(entries, isNot(contains('output/logs/2026/05/07/07_error.log')));
    });

    test('单文件 ZIP 只包含该文件并保留 output/logs 前缀', () async {
      await _writeFile(
        logsRoot,
        p.join('2026', '05', '06', '06_info.log'),
        'hello',
      );
      await _writeFile(
        logsRoot,
        p.join('2026', '05', '06', '06_error.log'),
        'boom',
      );

      final LogFileSummary logFile = (await LogExportService.listLogFiles(
        logsRoot: logsRoot,
      )).firstWhere((LogFileSummary item) => item.fileName == '06_info.log');

      final File zip = await LogExportService.createZipForFile(
        logFile,
        outputDirectory: outDir,
      );
      final List<String> entries = _zipEntries(zip);

      expect(entries, <String>['output/logs/2026/05/06/06_info.log']);
    });

    test('单日 ZIP 只包含该日文件并保留 output/logs 前缀', () async {
      await _writeFile(
        logsRoot,
        p.join('2026', '05', '06', '06_info.log'),
        'hello',
      );
      await _writeFile(
        logsRoot,
        p.join('2026', '05', '06', 'ai_gateway_logs', 'stream.log'),
        'gateway',
      );
      await _writeFile(
        logsRoot,
        p.join('2026', '05', '07', '07_error.log'),
        'boom',
      );

      final LogDaySummary day =
          (await LogExportService.listLogDays(logsRoot: logsRoot)).firstWhere(
            (LogDaySummary item) => _dateKey(item.date) == '2026-05-06',
          );

      final File zip = await LogExportService.createZipForDay(
        day,
        outputDirectory: outDir,
      );
      final List<String> entries = _zipEntries(zip);

      expect(
        entries,
        containsAll(<String>[
          'output/logs/2026/05/06/06_info.log',
          'output/logs/2026/05/06/ai_gateway_logs/stream.log',
        ]),
      );
      expect(entries, isNot(contains('output/logs/2026/05/07/07_error.log')));
    });

    test('按日期 ZIP 只包含该日文件', () async {
      await _writeFile(
        logsRoot,
        p.join('2026', '05', '06', '06_info.log'),
        'hello',
      );
      await _writeFile(
        logsRoot,
        p.join('2026', '05', '06', 'ai_gateway_logs', 'stream.log'),
        'gateway',
      );
      await _writeFile(
        logsRoot,
        p.join('2026', '05', '07', '07_error.log'),
        'boom',
      );

      final File zip = await LogExportService.createZipForDate(
        DateTime(2026, 5, 6),
        logsRoot: logsRoot,
        outputDirectory: outDir,
      );
      final List<String> entries = _zipEntries(zip);

      expect(
        entries,
        containsAll(<String>[
          'output/logs/2026/05/06/06_info.log',
          'output/logs/2026/05/06/ai_gateway_logs/stream.log',
        ]),
      );
      expect(entries, isNot(contains('output/logs/2026/05/07/07_error.log')));
    });

    test('全部 ZIP 包含所有日期文件', () async {
      await _writeFile(
        logsRoot,
        p.join('2026', '05', '06', '06_info.log'),
        'hello',
      );
      await _writeFile(
        logsRoot,
        p.join('2026', '05', '07', '07_error.log'),
        'boom',
      );

      final File zip = await LogExportService.createZipForAll(
        logsRoot: logsRoot,
        outputDirectory: outDir,
      );
      final List<String> entries = _zipEntries(zip);

      expect(
        entries,
        containsAll(<String>[
          'output/logs/2026/05/06/06_info.log',
          'output/logs/2026/05/07/07_error.log',
        ]),
      );
    });

    test('空目录返回空列表，空导出抛出 StateError', () async {
      final List<LogDaySummary> days = await LogExportService.listLogDays(
        logsRoot: logsRoot,
      );

      expect(days, isEmpty);
      expect(
        () => LogExportService.createZipForAll(
          logsRoot: logsRoot,
          outputDirectory: outDir,
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('导出期间文件消失时跳过该文件', () async {
      final File kept = await _writeFile(
        logsRoot,
        p.join('2026', '05', '06', '06_info.log'),
        'hello',
      );
      final File removed = await _writeFile(
        logsRoot,
        p.join('2026', '05', '06', '06_error.log'),
        'boom',
      );
      final LogDaySummary day = (await LogExportService.listLogDays(
        logsRoot: logsRoot,
      )).single;

      await removed.delete();
      expect(await kept.exists(), isTrue);

      final File zip = await LogExportService.createZipForDay(
        day,
        outputDirectory: outDir,
      );
      final List<String> entries = _zipEntries(zip);

      expect(entries, contains('output/logs/2026/05/06/06_info.log'));
      expect(entries, isNot(contains('output/logs/2026/05/06/06_error.log')));
    });

    test('删除单个日志文件后不再列出', () async {
      await _writeFile(
        logsRoot,
        p.join('2026', '05', '06', '06_info.log'),
        'hello',
      );
      final LogFileSummary logFile = (await LogExportService.listLogFiles(
        logsRoot: logsRoot,
      )).single;

      final bool deleted = await LogExportService.deleteLogFile(logFile);
      final List<LogFileSummary> files = await LogExportService.listLogFiles(
        logsRoot: logsRoot,
      );

      expect(deleted, isTrue);
      expect(files, isEmpty);
      expect(await logFile.file.exists(), isFalse);
    });

    test('删除目录浏览项只移除该文件夹', () async {
      await _writeFile(
        logsRoot,
        p.join('2026', '05', '06', '06_info.log'),
        'hello',
      );
      await _writeFile(
        logsRoot,
        p.join('2026', '05', '07', '07_error.log'),
        'boom',
      );
      final LogDirectoryListing month = await LogExportService.listDirectory(
        relativePath: '2026/05',
        logsRoot: logsRoot,
      );
      final LogBrowserEntry day06 = month.entries.firstWhere(
        (LogBrowserEntry entry) => entry.name == '06',
      );

      final LogDeleteResult result = await LogExportService.deleteBrowserEntry(
        day06,
      );
      final LogDirectoryListing refreshed =
          await LogExportService.listDirectory(
            relativePath: '2026/05',
            logsRoot: logsRoot,
          );

      expect(result.targetDeleted, isTrue);
      expect(result.fileCount, 1);
      expect(
        refreshed.entries.map((LogBrowserEntry entry) => entry.name),
        <String>['07'],
      );
    });

    test('删除某天日志只移除当天文件', () async {
      await _writeFile(
        logsRoot,
        p.join('2026', '05', '06', '06_info.log'),
        'hello',
      );
      await _writeFile(
        logsRoot,
        p.join('2026', '05', '06', 'ai_gateway_logs', 'stream.log'),
        'gateway',
      );
      await _writeFile(
        logsRoot,
        p.join('2026', '05', '07', '07_error.log'),
        'boom',
      );

      final int deleted = await LogExportService.deleteLogFilesForDate(
        DateTime(2026, 5, 6),
        logsRoot: logsRoot,
      );
      final List<LogFileSummary> files = await LogExportService.listLogFiles(
        logsRoot: logsRoot,
      );

      expect(deleted, 2);
      expect(files.map((LogFileSummary file) => file.archivePath), <String>[
        'output/logs/2026/05/07/07_error.log',
      ]);
    });
  });
}

Future<File> _writeFile(
  Directory root,
  String relativePath,
  String content,
) async {
  final File file = File(
    p.joinAll(<String>[root.path, ...p.split(relativePath)]),
  );
  await file.parent.create(recursive: true);
  await file.writeAsString(content, flush: true);
  return file;
}

List<String> _zipEntries(File zip) {
  final InputFileStream input = InputFileStream(zip.path);
  try {
    final Archive archive = ZipDecoder().decodeBuffer(input);
    return archive.files.map((ArchiveFile file) => file.name).toList()..sort();
  } finally {
    input.close();
  }
}

String _dateKey(DateTime date) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${date.year}-${two(date.month)}-${two(date.day)}';
}
