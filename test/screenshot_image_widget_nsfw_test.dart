import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_memo/data/database/screenshot_database.dart';
import 'package:screen_memo/features/gallery/presentation/widgets/screenshot_image_widget.dart';
import 'package:screen_memo/features/gallery/presentation/widgets/screenshot_item_widget.dart';
import 'package:screen_memo/features/nsfw/application/nsfw_preference_service.dart';
import 'package:screen_memo/l10n/app_localizations.dart';
import 'package:screen_memo/models/screenshot_record.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets('pageUrl-only thumbnails respect custom NSFW domain rules', (
    WidgetTester tester,
  ) async {
    final Directory tempDir = Directory.systemTemp.createTempSync(
      'screen_memo_nsfw_widget_',
    );
    try {
      await tester.runAsync(() async {
        await ScreenshotDatabase.instance.initializeForDesktop(tempDir.path);
        await NsfwPreferenceService.instance.clearRules();
        await NsfwPreferenceService.instance.addRule('thumb-rule.test');
      });

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SizedBox(
              width: 180,
              height: 180,
              child: ScreenshotImageWidget(
                file: File('${tempDir.path}/missing.png'),
                privacyMode: true,
                pageUrl: 'https://thumb-rule.test/image/1',
                showNsfwButton: false,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('内容警告：成人内容'), findsOneWidget);
    } finally {
      await tester.runAsync(() async {
        try {
          await ScreenshotDatabase.instance.disposeDesktop();
        } catch (_) {}
      });
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  testWidgets('NSFW thumbnail show button reveals the image in place', (
    WidgetTester tester,
  ) async {
    final Directory tempDir = Directory.systemTemp.createTempSync(
      'screen_memo_nsfw_reveal_',
    );
    int imageTaps = 0;
    try {
      await tester.runAsync(() async {
        await ScreenshotDatabase.instance.initializeForDesktop(tempDir.path);
        await NsfwPreferenceService.instance.clearRules();
        await NsfwPreferenceService.instance.addRule('thumb-reveal.test');
      });

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SizedBox(
              width: 220,
              height: 220,
              child: ScreenshotImageWidget(
                file: File('${tempDir.path}/missing.png'),
                privacyMode: true,
                pageUrl: 'https://thumb-reveal.test/image/1',
                showNsfwButton: true,
                onTap: () => imageTaps += 1,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('内容警告：成人内容'), findsOneWidget);

      await tester.tap(find.text('显示'));
      await tester.pump();

      expect(find.text('内容警告：成人内容'), findsNothing);
      expect(imageTaps, 0);
    } finally {
      await tester.runAsync(() async {
        try {
          await ScreenshotDatabase.instance.disposeDesktop();
        } catch (_) {}
      });
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  testWidgets('timeline screenshot item show button reveals before opening', (
    WidgetTester tester,
  ) async {
    final Directory tempDir = Directory.systemTemp.createTempSync(
      'screen_memo_timeline_nsfw_reveal_',
    );
    int imageTaps = 0;
    try {
      await tester.runAsync(() async {
        await ScreenshotDatabase.instance.initializeForDesktop(tempDir.path);
        await NsfwPreferenceService.instance.clearRules();
        await NsfwPreferenceService.instance.addRule('timeline-reveal.test');
      });

      final ScreenshotRecord screenshot = ScreenshotRecord(
        id: 1,
        appPackageName: '',
        appName: 'Test',
        filePath: '${tempDir.path}/missing.png',
        captureTime: DateTime(2026, 7, 4, 12),
        fileSize: 0,
        pageUrl: 'https://timeline-reveal.test/image/1',
      );

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SizedBox(
              width: 220,
              height: 320,
              child: ScreenshotItemWidget(
                screenshot: screenshot,
                privacyMode: true,
                onTap: () => imageTaps += 1,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('内容警告：成人内容'), findsOneWidget);

      await tester.tap(find.text('显示'));
      await tester.pump();

      expect(find.text('内容警告：成人内容'), findsNothing);
      expect(imageTaps, 0);

      await tester.tap(find.byType(ScreenshotItemWidget));
      await tester.pump();

      expect(imageTaps, 1);
    } finally {
      await tester.runAsync(() async {
        try {
          await ScreenshotDatabase.instance.disposeDesktop();
        } catch (_) {}
      });
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });
}
