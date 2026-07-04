import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_memo/features/gallery/presentation/pages/screenshot_gallery_page.dart';
import 'package:screen_memo/features/gallery/presentation/pages/screenshot_viewer_page.dart';
import 'package:screen_memo/l10n/app_localizations.dart';
import 'package:screen_memo/models/screenshot_record.dart';

void main() {
  Widget buildHarness({Object? arguments}) {
    return MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      onGenerateRoute: (settings) {
        return MaterialPageRoute<void>(
          settings: RouteSettings(
            name: '/screenshot_viewer',
            arguments: arguments,
          ),
          builder: (_) => const ScreenshotViewerPage(),
        );
      },
      initialRoute: '/screenshot_viewer',
    );
  }

  Widget buildGalleryHarness({Object? arguments}) {
    return MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      onGenerateRoute: (settings) {
        return MaterialPageRoute<void>(
          settings: RouteSettings(
            name: '/screenshot_gallery',
            arguments: arguments,
          ),
          builder: (_) => const ScreenshotGalleryPage(),
        );
      },
      initialRoute: '/screenshot_gallery',
    );
  }

  testWidgets('查看器无路由参数时不会崩溃', (tester) async {
    await tester.pumpWidget(buildHarness());
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('图库页无路由参数时不会崩溃', (tester) async {
    await tester.pumpWidget(buildGalleryHarness());
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('查看器收到空截图列表时不会崩溃', (tester) async {
    await tester.pumpWidget(
      buildHarness(
        arguments: <String, dynamic>{'screenshots': <ScreenshotRecord>[]},
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('查看器收到坏参数类型时不会崩溃', (tester) async {
    await tester.pumpWidget(
      buildHarness(
        arguments: <Object?, Object?>{
          1: 'ignored',
          'screenshots': 'not a list',
          'initialIndex': 'bad',
          'singleMode': 'bad',
        },
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('查看器会钳制越界 initialIndex', (tester) async {
    final screenshots = <ScreenshotRecord>[
      ScreenshotRecord(
        id: 1,
        appPackageName: 'com.example.app',
        appName: 'Example',
        filePath: '/tmp/missing.png',
        captureTime: DateTime(2026),
        fileSize: 0,
      ),
    ];

    await tester.pumpWidget(
      buildHarness(
        arguments: <String, dynamic>{
          'screenshots': screenshots,
          'initialIndex': 99,
        },
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Example (1/1)'), findsOneWidget);
  });

  testWidgets('查看器长按带链接图片时显示加入 NSFW 网站选项', (tester) async {
    final screenshots = <ScreenshotRecord>[
      ScreenshotRecord(
        id: null,
        appPackageName: 'com.example.app',
        appName: 'Example',
        filePath: '/tmp/missing-linked.png',
        captureTime: DateTime(2026),
        fileSize: 0,
        pageUrl: 'https://site-to-block.test/post/1',
      ),
    ];

    await tester.pumpWidget(
      buildHarness(
        arguments: <String, dynamic>{
          'screenshots': screenshots,
          'initialIndex': 0,
        },
      ),
    );
    await tester.pump();

    await tester.longPressAt(tester.getCenter(find.byType(Scaffold)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.text('Add this site to NSFW'), findsOneWidget);
    expect(find.text('site-to-block.test'), findsOneWidget);
    expect(find.text('Mark as NSFW'), findsNothing);
  });
}
