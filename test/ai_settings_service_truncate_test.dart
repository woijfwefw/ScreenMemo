import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:screen_memo/data/database/screenshot_database.dart';
import 'package:screen_memo/features/ai/application/ai_settings_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _prepareChatDb(Directory root, {required String cid}) async {
  await ScreenshotDatabase.instance.initializeForDesktop(root.path);
  final db = await ScreenshotDatabase.instance.database;
  final int now = DateTime.now().millisecondsSinceEpoch;
  await _insertConversation(db, cid: cid, now: now);
  await db.insert('ai_messages', <String, Object?>{
    'conversation_id': cid,
    'role': 'user',
    'content': 'before',
    'created_at': 1000,
  });
  await db.insert('ai_messages', <String, Object?>{
    'conversation_id': cid,
    'role': 'assistant',
    'content': 'old answer',
    'created_at': 2000,
  });
}

Future<void> _insertConversation(
  Database db, {
  required String cid,
  required int now,
  String title = 'retry-test',
}) async {
  await db.insert('ai_conversations', <String, Object?>{
    'cid': cid,
    'title': title,
    'created_at': now,
    'updated_at': now,
  });
}

Future<void> _insertMessage(Database db, {required String cid}) async {
  await db.insert('ai_messages', <String, Object?>{
    'conversation_id': cid,
    'role': 'user',
    'content': 'before',
    'created_at': 1000,
  });
  await db.insert('ai_messages', <String, Object?>{
    'conversation_id': cid,
    'role': 'assistant',
    'content': 'old answer',
    'created_at': 2000,
  });
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('silent truncate does not broadcast chat history reload', () async {
    final Directory tmp = await Directory.systemTemp.createTemp(
      'screen_memo_silent_truncate_',
    );
    final List<String> events = <String>[];
    StreamSubscription<String>? sub;
    try {
      final Directory root = Directory(p.join(tmp.path, 'root'));
      await root.create(recursive: true);
      await _prepareChatDb(root, cid: 'retry-cid');

      sub = AISettingsService.instance.onContextChanged.listen(events.add);
      await AISettingsService.instance.truncateConversationAfterCreatedAt(
        'retry-cid',
        2000,
        notify: false,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(events, isEmpty);
      final rows = await ScreenshotDatabase.instance.getAiMessagesTail(
        'retry-cid',
        limit: 10,
      );
      expect(rows.map((e) => e['content']).toList(), <String>['before']);
    } finally {
      await sub?.cancel();
      try {
        await ScreenshotDatabase.instance.disposeDesktop();
      } catch (_) {}
      if (await tmp.exists()) {
        await tmp.delete(recursive: true);
      }
    }
  });

  test(
    'retry truncate removes later rows from all chat history stores',
    () async {
      final Directory tmp = await Directory.systemTemp.createTemp(
        'screen_memo_retry_truncate_all_stores_',
      );
      try {
        const String cid = 'retry-all-stores-cid';
        final Directory root = Directory(p.join(tmp.path, 'root'));
        await root.create(recursive: true);
        await ScreenshotDatabase.instance.initializeForDesktop(root.path);
        final db = await ScreenshotDatabase.instance.database;
        final int now = DateTime.now().millisecondsSinceEpoch;
        await _insertConversation(db, cid: cid, now: now);
        await db.update(
          'ai_conversations',
          <String, Object?>{
            'summary': 'old summary',
            'summary_updated_at': now,
            'summary_tokens': 10,
            'compaction_count': 1,
            'last_compaction_reason': 'test',
            'tool_memory_json': '{"items":[]}',
            'tool_memory_updated_at': now,
            'last_prompt_tokens': 123,
            'last_prompt_at': now,
            'last_prompt_breakdown_json': '{}',
          },
          where: 'cid = ?',
          whereArgs: <Object?>[cid],
        );

        final List<Map<String, Object?>> visible = <Map<String, Object?>>[
          <String, Object?>{
            'role': 'user',
            'content': 'u1',
            'created_at': 1000,
          },
          <String, Object?>{
            'role': 'assistant',
            'content': 'a1',
            'created_at': 2000,
          },
          <String, Object?>{
            'role': 'user',
            'content': 'u2',
            'created_at': 3000,
          },
          // 模拟一条顺序在后、但时间戳早于重试截断点的异常消息。
          <String, Object?>{
            'role': 'assistant',
            'content': 'a2-skewed',
            'created_at': 1500,
          },
        ];
        for (final Map<String, Object?> row in visible) {
          await db.insert('ai_messages', <String, Object?>{
            'conversation_id': cid,
            ...row,
          });
          await db.insert('ai_messages_full', <String, Object?>{
            'conversation_id': cid,
            ...row,
          });
          await db.insert('ai_messages_raw', <String, Object?>{
            'conversation_id': cid,
            ...row,
          });
        }
        await db.insert('ai_context_events', <String, Object?>{
          'conversation_id': cid,
          'type': 'before',
          'created_at': 1000,
        });
        await db.insert('ai_context_events', <String, Object?>{
          'conversation_id': cid,
          'type': 'cutoff',
          'created_at': 3000,
        });
        await db.insert('ai_context_events', <String, Object?>{
          'conversation_id': cid,
          'type': 'skewed',
          'created_at': 1500,
        });
        await db.insert('ai_prompt_usage_events', <String, Object?>{
          'conversation_id': cid,
          'model': 'before',
          'created_at': 1000,
        });
        await db.insert('ai_prompt_usage_events', <String, Object?>{
          'conversation_id': cid,
          'model': 'cutoff',
          'created_at': 3000,
        });
        await db.insert('ai_prompt_usage_events', <String, Object?>{
          'conversation_id': cid,
          'model': 'skewed',
          'created_at': 1500,
        });
        await db.insert('ai_tool_call_details', <String, Object?>{
          'conversation_id': cid,
          'assistant_created_at': 2000,
          'call_id': 'before-call',
          'tool_name': 'search_segments',
        });
        await db.insert('ai_tool_call_details', <String, Object?>{
          'conversation_id': cid,
          'assistant_created_at': 3000,
          'call_id': 'cutoff-call',
          'tool_name': 'search_segments',
        });
        await db.insert('ai_tool_call_details', <String, Object?>{
          'conversation_id': cid,
          'assistant_created_at': 1500,
          'call_id': 'skewed-call',
          'tool_name': 'search_segments',
        });

        await AISettingsService.instance.truncateConversationAfterCreatedAt(
          cid,
          3000,
          notify: false,
        );

        Future<List<String>> columnValues(String table, String column) async {
          final rows = await db.query(
            table,
            columns: <String>[column],
            where: 'conversation_id = ?',
            whereArgs: <Object?>[cid],
            orderBy: 'id ASC',
          );
          return rows.map((row) => row[column]?.toString() ?? '').toList();
        }

        expect(await columnValues('ai_messages', 'content'), <String>[
          'u1',
          'a1',
        ]);
        expect(await columnValues('ai_messages_full', 'content'), <String>[
          'u1',
          'a1',
        ]);
        expect(await columnValues('ai_messages_raw', 'content'), <String>[
          'u1',
          'a1',
        ]);
        expect(await columnValues('ai_context_events', 'type'), <String>[
          'before',
        ]);
        expect(await columnValues('ai_prompt_usage_events', 'model'), <String>[
          'before',
        ]);
        expect(await columnValues('ai_tool_call_details', 'call_id'), <String>[
          'before-call',
        ]);

        final conv = (await db.query(
          'ai_conversations',
          where: 'cid = ?',
          whereArgs: <Object?>[cid],
          limit: 1,
        )).single;
        expect(conv['summary'], isNull);
        expect(conv['tool_memory_json'], isNull);
        expect(conv['last_prompt_tokens'], isNull);
        expect(conv['compaction_count'], 0);
      } finally {
        try {
          await ScreenshotDatabase.instance.disposeDesktop();
        } catch (_) {}
        if (await tmp.exists()) {
          await tmp.delete(recursive: true);
        }
      }
    },
  );

  test('truncate broadcasts chat history reload by default', () async {
    final Directory tmp = await Directory.systemTemp.createTemp(
      'screen_memo_notify_truncate_',
    );
    final List<String> events = <String>[];
    StreamSubscription<String>? sub;
    try {
      final Directory root = Directory(p.join(tmp.path, 'root'));
      await root.create(recursive: true);
      await _prepareChatDb(root, cid: 'notify-cid');

      sub = AISettingsService.instance.onContextChanged.listen(events.add);
      await AISettingsService.instance.truncateConversationAfterCreatedAt(
        'notify-cid',
        2000,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(events, contains('chat:history'));
    } finally {
      await sub?.cancel();
      try {
        await ScreenshotDatabase.instance.disposeDesktop();
      } catch (_) {}
      if (await tmp.exists()) {
        await tmp.delete(recursive: true);
      }
    }
  });

  test(
    'deleting active conversation selects another cid and broadcasts delete',
    () async {
      final Directory tmp = await Directory.systemTemp.createTemp(
        'screen_memo_delete_active_conversation_',
      );
      final List<String> events = <String>[];
      StreamSubscription<String>? sub;
      try {
        final Directory root = Directory(p.join(tmp.path, 'root'));
        await root.create(recursive: true);
        await ScreenshotDatabase.instance.initializeForDesktop(root.path);
        final db = await ScreenshotDatabase.instance.database;
        final int now = DateTime.now().millisecondsSinceEpoch;
        await _insertConversation(
          db,
          cid: 'deleted-cid',
          now: now,
          title: 'deleted',
        );
        await _insertMessage(db, cid: 'deleted-cid');
        await _insertConversation(
          db,
          cid: 'next-cid',
          now: now + 1,
          title: 'next',
        );
        await ScreenshotDatabase.instance.setAiSetting(
          'chat_active_cid',
          'deleted-cid',
        );

        sub = AISettingsService.instance.onContextChanged.listen(events.add);
        final bool deleted = await AISettingsService.instance
            .deleteConversation('deleted-cid');
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(deleted, isTrue);
        expect(
          await AISettingsService.instance.getActiveConversationCid(),
          'next-cid',
        );
        expect(events, contains('chat:deleted'));

        final rows = await ScreenshotDatabase.instance.getAiMessagesTail(
          'deleted-cid',
          limit: 10,
        );
        expect(rows, isEmpty);
      } finally {
        await sub?.cancel();
        try {
          await ScreenshotDatabase.instance.disposeDesktop();
        } catch (_) {}
        if (await tmp.exists()) {
          await tmp.delete(recursive: true);
        }
      }
    },
  );
}
