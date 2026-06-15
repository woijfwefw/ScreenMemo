import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_memo/l10n/app_localizations.dart';
import 'package:screen_memo/features/backup/presentation/pages/export_backup_page.dart';
import 'package:screen_memo/features/backup/data/backup_inventory_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  BackupInventory inventoryFixture() {
    const BackupRootPaths roots = BackupRootPaths(
      filesDirPath: '/data/files',
      dataRootPath: '/data',
      outputDirPath: '/data/files/output',
      appDatabasesDirPath: '/data/databases',
      sharedPrefsDirPath: '/data/shared_prefs',
      appFlutterDirPath: '/data/app_flutter',
      noBackupDirPath: '/data/no_backup',
    );
    return BackupInventory(
      roots: roots,
      categories: const <BackupInventoryCategory>[
        BackupInventoryCategory(
          id: BackupCategoryIds.screenshots,
          files: <BackupInventoryFile>[
            BackupInventoryFile(
              sourcePath: '/data/files/output/screen/demo/a.png',
              archivePath: 'output/screen/demo/a.png',
              bytes: 50,
              categoryId: BackupCategoryIds.screenshots,
            ),
          ],
          totalBytes: 50,
          fileCount: 1,
        ),
        BackupInventoryCategory(
          id: BackupCategoryIds.mainDatabase,
          files: <BackupInventoryFile>[
            BackupInventoryFile(
              sourcePath: '/data/files/output/databases/screenshot_memo.db',
              archivePath: 'output/databases/screenshot_memo.db',
              bytes: 50,
              categoryId: BackupCategoryIds.mainDatabase,
            ),
          ],
          totalBytes: 50,
          fileCount: 1,
        ),
      ],
      excludedItems: const <BackupExcludedItem>[
        BackupExcludedItem(
          id: BackupExcludedIds.externalLogs,
          reason: 'External logs are intentionally excluded.',
        ),
      ],
      totalBytes: 100,
      totalFiles: 2,
      warnings: const <String>[],
    );
  }

  BackupInventory inventoryWithAppFilesFixture() {
    final BackupInventory base = inventoryFixture();
    return BackupInventory(
      roots: base.roots,
      categories: <BackupInventoryCategory>[
        ...base.categories,
        const BackupInventoryCategory(
          id: BackupCategoryIds.appFiles,
          files: <BackupInventoryFile>[
            BackupInventoryFile(
              sourcePath: '/data/files/skills/demo/SKILL.md',
              archivePath: 'files/skills/demo/SKILL.md',
              bytes: 25,
              categoryId: BackupCategoryIds.appFiles,
            ),
          ],
          totalBytes: 25,
          fileCount: 1,
        ),
      ],
      excludedItems: base.excludedItems,
      totalBytes: base.totalBytes + 25,
      totalFiles: base.totalFiles + 1,
      warnings: base.warnings,
    );
  }

  Widget buildHarness(Widget child, {List<NavigatorObserver>? observers}) {
    return MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      navigatorObservers: observers ?? const <NavigatorObserver>[],
      home: child,
    );
  }

  Widget buildPushHarness(Widget child, {required NavigatorObserver observer}) {
    return buildHarness(
      Builder(
        builder: (BuildContext context) {
          return Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () {
                  Navigator.of(
                    context,
                  ).push(MaterialPageRoute<void>(builder: (_) => child));
                },
                child: const Text('open export'),
              ),
            ),
          );
        },
      ),
      observers: <NavigatorObserver>[observer],
    );
  }

  Future<void> scrollToText(WidgetTester tester, String text) async {
    final Finder finder = find.text(text);
    if (finder.evaluate().isEmpty) {
      try {
        await tester.scrollUntilVisible(
          finder,
          300,
          scrollable: find.byType(Scrollable).first,
          maxScrolls: 30,
        );
      } catch (_) {
        await tester.scrollUntilVisible(
          finder,
          -300,
          scrollable: find.byType(Scrollable).first,
          maxScrolls: 30,
        );
      }
    } else {
      await tester.ensureVisible(finder);
    }
    await tester.pumpAndSettle();
  }

  Future<void> expectVisibleText(WidgetTester tester, String text) async {
    await scrollToText(tester, text);
    expect(find.text(text), findsOneWidget);
  }

  Future<void> tapVisibleText(WidgetTester tester, String text) async {
    await scrollToText(tester, text);
    await tester.tap(find.text(text));
  }

  testWidgets('export page scans scope first and waits for manual start', (
    WidgetTester tester,
  ) async {
    final BackupInventory inventory = inventoryFixture();
    int exportCalls = 0;

    await tester.pumpWidget(
      buildHarness(
        ExportBackupPage(
          inventoryLoader:
              ({
                void Function(String scopeId, String? currentPath)? onProgress,
              }) async {
                onProgress?.call('output', '/data/files/output');
                return inventory;
              },
          exportExecutor:
              ({
                required BackupExportScope exportScope,
                required void Function(ExportProgressSnapshot snapshot)
                onProgress,
                required bool Function() isCancelled,
              }) async {
                exportCalls += 1;
                return null;
              },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await expectVisibleText(tester, '开始导出');
    expect(find.text('截图文件'), findsOneWidget);
    expect(find.text('主数据库'), findsOneWidget);
    expect(exportCalls, 0);
  });

  testWidgets('export page shows scanning, packing, and completion states', (
    WidgetTester tester,
  ) async {
    final Completer<void> packingGate = Completer<void>();
    final Completer<void> completionGate = Completer<void>();
    final BackupInventory inventory = inventoryFixture();
    int exportCalls = 0;

    Future<Map<String, dynamic>?> executor({
      required BackupExportScope exportScope,
      required void Function(ExportProgressSnapshot snapshot) onProgress,
      required bool Function() isCancelled,
    }) async {
      exportCalls += 1;
      onProgress(
        ExportProgressSnapshot(
          phase: ExportPhase.scanning,
          overallProgress: 0,
          completedBytes: 0,
          totalBytes: inventory.totalBytes,
          categoryCompletedBytes: const <String, int>{
            BackupCategoryIds.screenshots: 0,
            BackupCategoryIds.mainDatabase: 0,
          },
          inventory: inventory,
          currentEntry: '/data/files/output',
        ),
      );
      await packingGate.future;
      onProgress(
        ExportProgressSnapshot(
          phase: ExportPhase.packing,
          overallProgress: 0.5,
          completedBytes: 50,
          totalBytes: 100,
          categoryCompletedBytes: const <String, int>{
            BackupCategoryIds.screenshots: 50,
            BackupCategoryIds.mainDatabase: 0,
          },
          inventory: inventory,
          currentCategoryId: BackupCategoryIds.screenshots,
          currentEntry: 'output/screen/demo/a.png',
        ),
      );
      await completionGate.future;
      onProgress(
        ExportProgressSnapshot(
          phase: ExportPhase.completed,
          overallProgress: 1,
          completedBytes: 100,
          totalBytes: 100,
          categoryCompletedBytes: const <String, int>{
            BackupCategoryIds.screenshots: 50,
            BackupCategoryIds.mainDatabase: 50,
          },
          inventory: inventory,
          outputPath: 'Download/ScreenMemory/test.zip',
        ),
      );
      return <String, dynamic>{'humanPath': 'Download/ScreenMemory/test.zip'};
    }

    await tester.pumpWidget(
      buildHarness(
        ExportBackupPage(
          inventoryLoader:
              ({
                void Function(String scopeId, String? currentPath)? onProgress,
              }) async => inventory,
          exportExecutor: executor,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await expectVisibleText(tester, '开始导出');
    expect(exportCalls, 0);

    await tapVisibleText(tester, '开始导出');
    await tester.pump();
    expect(exportCalls, 1);
    expect(find.text('正在扫描全部持久化数据…'), findsOneWidget);
    await expectVisibleText(tester, '取消导出');

    packingGate.complete();
    await tester.pump();
    await expectVisibleText(tester, '50%');

    completionGate.complete();
    await tester.pumpAndSettle();
    await expectVisibleText(tester, '导出完成，可以确认备份已生成。');
    await expectVisibleText(tester, '复制路径');
    await expectVisibleText(tester, 'Download/ScreenMemory/test.zip');
  });

  testWidgets('cancel keeps page open and allows restart after cleanup', (
    WidgetTester tester,
  ) async {
    final BackupInventory inventory = inventoryFixture();
    final Completer<void> releaseExecutor = Completer<void>();
    final _TestNavigatorObserver observer = _TestNavigatorObserver();

    Future<Map<String, dynamic>?> executor({
      required BackupExportScope exportScope,
      required void Function(ExportProgressSnapshot snapshot) onProgress,
      required bool Function() isCancelled,
    }) async {
      onProgress(
        ExportProgressSnapshot(
          phase: ExportPhase.packing,
          overallProgress: 0.5,
          completedBytes: 50,
          totalBytes: 100,
          categoryCompletedBytes: const <String, int>{
            BackupCategoryIds.screenshots: 50,
            BackupCategoryIds.mainDatabase: 0,
          },
          inventory: inventory,
          currentCategoryId: BackupCategoryIds.screenshots,
          currentEntry: 'output/screen/demo/a.png',
        ),
      );
      await releaseExecutor.future;
      if (isCancelled()) {
        onProgress(
          ExportProgressSnapshot(
            phase: ExportPhase.cancelled,
            overallProgress: 0.5,
            completedBytes: 50,
            totalBytes: 100,
            categoryCompletedBytes: const <String, int>{
              BackupCategoryIds.screenshots: 50,
              BackupCategoryIds.mainDatabase: 0,
            },
            inventory: inventory,
          ),
        );
        throw const BackupExportCancelledException();
      }
      return null;
    }

    await tester.pumpWidget(
      buildPushHarness(
        ExportBackupPage(
          inventoryLoader:
              ({
                void Function(String scopeId, String? currentPath)? onProgress,
              }) async => inventory,
          exportExecutor: executor,
        ),
        observer: observer,
      ),
    );

    await tester.tap(find.text('open export'));
    await tester.pumpAndSettle();
    expect(find.byType(ExportBackupPage), findsOneWidget);

    await tapVisibleText(tester, '开始导出');
    await tester.pump();
    await expectVisibleText(tester, '取消导出');

    await tapVisibleText(tester, '取消导出');
    await tester.pump();
    expect(find.text('正在取消并清理'), findsOneWidget);

    releaseExecutor.complete();
    await tester.pumpAndSettle();

    expect(find.byType(ExportBackupPage), findsOneWidget);
    expect(observer.popCount, 0);
    await expectVisibleText(tester, '重新开始导出');
    expect(find.text('导出已取消，未完成的备份文件已清理。'), findsWidgets);
  });

  testWidgets('export page shows restart state on failure', (
    WidgetTester tester,
  ) async {
    final BackupInventory inventory = inventoryFixture();

    Future<Map<String, dynamic>?> executor({
      required BackupExportScope exportScope,
      required void Function(ExportProgressSnapshot snapshot) onProgress,
      required bool Function() isCancelled,
    }) async {
      onProgress(
        ExportProgressSnapshot(
          phase: ExportPhase.scanning,
          overallProgress: 0,
          completedBytes: 0,
          totalBytes: inventory.totalBytes,
          categoryCompletedBytes: const <String, int>{
            BackupCategoryIds.screenshots: 0,
            BackupCategoryIds.mainDatabase: 0,
          },
          inventory: inventory,
        ),
      );
      throw StateError('boom');
    }

    await tester.pumpWidget(
      buildHarness(
        ExportBackupPage(
          inventoryLoader:
              ({
                void Function(String scopeId, String? currentPath)? onProgress,
              }) async => inventory,
          exportExecutor: executor,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tapVisibleText(tester, '开始导出');
    await tester.pumpAndSettle();

    await expectVisibleText(tester, '导出失败');
    expect(find.textContaining('boom'), findsOneWidget);
    await expectVisibleText(tester, '重新开始导出');
  });

  testWidgets('database-only scope updates preview and executor scope', (
    WidgetTester tester,
  ) async {
    final BackupInventory inventory = inventoryWithAppFilesFixture();
    BackupExportScope? receivedScope;

    await tester.pumpWidget(
      buildHarness(
        ExportBackupPage(
          inventoryLoader:
              ({
                void Function(String scopeId, String? currentPath)? onProgress,
              }) async => inventory,
          exportExecutor:
              ({
                required BackupExportScope exportScope,
                required void Function(ExportProgressSnapshot snapshot)
                onProgress,
                required bool Function() isCancelled,
              }) async {
                receivedScope = exportScope;
                return null;
              },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('截图文件'), findsOneWidget);
    expect(find.text('主数据库'), findsOneWidget);
    expect(find.text('应用 files 持久化目录'), findsOneWidget);

    await tester.tap(find.text('仅导出数据库'));
    await tester.pumpAndSettle();

    expect(find.text('截图文件'), findsNothing);
    expect(find.text('主数据库'), findsOneWidget);
    expect(find.text('应用 files 持久化目录'), findsNothing);
    await expectVisibleText(tester, '开始导出数据库');

    await tapVisibleText(tester, '开始导出数据库');
    await tester.pump();

    expect(receivedScope, BackupExportScope.databasesOnly);
  });
}

class _TestNavigatorObserver extends NavigatorObserver {
  int popCount = 0;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    popCount += 1;
    super.didPop(route, previousRoute);
  }
}
