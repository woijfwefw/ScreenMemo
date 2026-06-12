import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:screen_memo/features/skills/application/skill_service.dart';

void main() {
  group('SkillService', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('screen_memo_skills_');
      SkillService.instance.setBaseDirForTesting(tempDir);
    });

    tearDown(() async {
      SkillService.instance.setBaseDirForTesting(null);
      SkillService.instance.setHttpClientForTesting(null);
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('saves and lists SKILL.md content', () async {
      final skill = await SkillService.instance.saveSkillFromContent('''
---
name: test-skill
description: Test skill
compatibility: screenmemo
allowed-tools: search_segments get_images
---

Use this skill.
''');

      expect(skill.name, 'test-skill');
      expect(skill.description, 'Test skill');
      expect(skill.allowedTools, <String>['search_segments', 'get_images']);

      final skills = await SkillService.instance.listSkills();
      expect(skills, hasLength(1));
      expect(
        await SkillService.instance.readSkillBody('test-skill'),
        'Use this skill.\n',
      );
    });

    test('rejects traversal in skill names and file paths', () async {
      await expectLater(
        SkillService.instance.saveSkillFromContent('''
---
name: ../escape
description: Bad
---

Bad.
'''),
        throwsArgumentError,
      );

      await SkillService.instance.saveSkillFromContent('''
---
name: safe-skill
description: Safe
---

Safe.
''');

      final file = await SkillService.instance.resolveSkillFile(
        'safe-skill',
        '../secret.txt',
      );
      expect(file, isNull);
    });

    test('imports a GitHub skill directory atomically', () async {
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/contents/skills/demo')) {
          return http.Response(
            jsonEncode(<Map<String, dynamic>>[
              <String, dynamic>{
                'type': 'file',
                'path': 'skills/demo/SKILL.md',
                'download_url': 'https://raw.example/SKILL.md',
              },
              <String, dynamic>{
                'type': 'file',
                'path': 'skills/demo/examples/basic.md',
                'download_url': 'https://raw.example/examples/basic.md',
              },
            ]),
            200,
          );
        }
        if (request.url.toString() == 'https://raw.example/SKILL.md') {
          return http.Response('''
---
name: github-skill
description: GitHub skill
---

Read examples/basic.md.
''', 200);
        }
        if (request.url.toString() == 'https://raw.example/examples/basic.md') {
          return http.Response('Example content', 200);
        }
        return http.Response('not found', 404);
      });
      SkillService.instance.setHttpClientForTesting(client);

      final skill = await SkillService.instance.importSkillFromGitHub(
        'https://github.com/owner/repo/tree/main/skills/demo',
      );

      expect(skill.name, 'github-skill');
      expect(
        await SkillService.instance.readSkillFile(
          'github-skill',
          'examples/basic.md',
        ),
        'Example content',
      );
    });

    test('tracks enabled skills and filters disabled skills', () async {
      await SkillService.instance.saveSkillFromContent('''
---
name: toggle-skill
description: Toggle skill
---

Use this skill.
''');

      expect(
        (await SkillService.instance.listEnabledSkills()).map((s) => s.name),
        contains('toggle-skill'),
      );

      await SkillService.instance.setSkillEnabled('toggle-skill', false);
      expect(await SkillService.instance.getSkill('toggle-skill'), isNotNull);
      expect(
        (await SkillService.instance.getSkill('toggle-skill'))!.enabled,
        isFalse,
      );
      expect(
        (await SkillService.instance.listEnabledSkills()).map((s) => s.name),
        isNot(contains('toggle-skill')),
      );

      await SkillService.instance.setSkillEnabled('toggle-skill', true);
      expect(
        (await SkillService.instance.getSkill('toggle-skill'))!.enabled,
        isTrue,
      );
    });

    test('manages individual skill files safely', () async {
      await SkillService.instance.saveSkillFromContent('''
---
name: managed-skill
description: Managed skill
---

Use examples/basic.md.
''');

      await SkillService.instance.saveSkillFile(
        'managed-skill',
        'examples/basic.md',
        'Example content',
      );

      final files = await SkillService.instance.listSkillFiles('managed-skill');
      expect(files.map((file) => file.relativePath), <String>[
        'SKILL.md',
        'examples/basic.md',
      ]);
      expect(
        await SkillService.instance.readSkillFile(
          'managed-skill',
          'examples/basic.md',
        ),
        'Example content',
      );

      expect(
        await SkillService.instance.deleteSkillFile(
          'managed-skill',
          'examples/basic.md',
        ),
        isTrue,
      );
      expect(
        await SkillService.instance.readSkillFile(
          'managed-skill',
          'examples/basic.md',
        ),
        isNull,
      );
    });

    test('rejects hidden secret and binary-like skill files', () async {
      await SkillService.instance.saveSkillFromContent('''
---
name: guarded-skill
description: Guarded skill
---

Safe.
''');

      await expectLater(
        SkillService.instance.saveSkillFile(
          'guarded-skill',
          '.env',
          'TOKEN=secret',
        ),
        throwsArgumentError,
      );
      await expectLater(
        SkillService.instance.saveSkillFile(
          'guarded-skill',
          'secrets.json',
          '{}',
        ),
        throwsArgumentError,
      );
      await expectLater(
        SkillService.instance.saveSkillFile(
          'guarded-skill',
          'image.png',
          'not really an image',
        ),
        throwsArgumentError,
      );
    });

    test('limits GitHub skill imports', () async {
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/contents/skills/large')) {
          return http.Response(
            jsonEncode(<Map<String, dynamic>>[
              <String, dynamic>{
                'type': 'file',
                'path': 'skills/large/SKILL.md',
                'download_url': 'https://raw.example/SKILL.md',
              },
              for (int i = 0; i < 81; i += 1)
                <String, dynamic>{
                  'type': 'file',
                  'path': 'skills/large/examples/$i.md',
                  'download_url': 'https://raw.example/examples/$i.md',
                },
            ]),
            200,
          );
        }
        return http.Response('not found', 404);
      });
      SkillService.instance.setHttpClientForTesting(client);

      await expectLater(
        SkillService.instance.importSkillFromGitHub(
          'https://github.com/owner/repo/tree/main/skills/large',
        ),
        throwsFormatException,
      );
    });
  });
}
