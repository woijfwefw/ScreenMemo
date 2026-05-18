import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_memo/data/platform/path_service.dart';

void main() {
  group('PathService', () {
    late Directory tempRoot;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp(
        'screen_memo_path_service_test_',
      );
      PathService.debugSetInternalAppDirBaseOverride(tempRoot);
    });

    tearDown(() async {
      PathService.debugSetInternalAppDirBaseOverride(null);
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    test(
      'persistent private dir is outside output and marks nomedia',
      () async {
        final Directory? dir = await PathService.getPersistentPrivateDir(
          'ai/chat_attachments/2026-05',
        );

        expect(dir, isNotNull);
        final String normalized = dir!.path.replaceAll('\\', '/');
        expect(
          normalized,
          endsWith('/persistent_private/ai/chat_attachments/2026-05'),
        );
        expect(normalized.contains('/output/'), isFalse);
        expect(await File('${dir.path}/.nomedia').exists(), isTrue);
      },
    );
  });
}
