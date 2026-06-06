import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:screen_memo/data/database/screenshot_database.dart';
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

  test('对话列表查询不会返回上下文大字段', () async {
    final Directory tmp = await Directory.systemTemp.createTemp(
      'screen_memo_ai_conversation_list_',
    );
    try {
      await ScreenshotDatabase.instance.initializeForDesktop(tmp.path);
      final db = await ScreenshotDatabase.instance.database;
      final String largeText = List<String>.filled(64 * 1024, 'x').join();
      final int now = DateTime.now().millisecondsSinceEpoch;

      for (int i = 0; i < 4; i++) {
        await db.insert('ai_conversations', <String, Object?>{
          'cid': 'cid-$i',
          'title': 'conversation-$i',
          'provider_id': i + 1,
          'model': 'model-$i',
          'summary': largeText,
          'tool_memory_json': '{"memory":"$largeText"}',
          'last_prompt_breakdown_json': '{"tokens":"$largeText"}',
          'created_at': now + i,
          'updated_at': now + i,
        });
      }

      final rows = (await ScreenshotDatabase.instance.listAiConversations())
          .where((row) => (row['cid'] as String? ?? '').startsWith('cid-'))
          .toList();

      expect(rows, hasLength(4));
      for (final row in rows) {
        expect(
          row.keys,
          containsAll(<String>[
            'id',
            'cid',
            'title',
            'provider_id',
            'model',
            'pinned',
            'archived',
            'created_at',
            'updated_at',
          ]),
        );
        expect(row, isNot(contains('summary')));
        expect(row, isNot(contains('tool_memory_json')));
        expect(row, isNot(contains('last_prompt_breakdown_json')));
      }

      final detail = await ScreenshotDatabase.instance.getAiConversationByCid(
        'cid-0',
      );
      expect(detail?['summary'], largeText);
      expect(detail?['tool_memory_json'], contains(largeText));
      expect(detail?['last_prompt_breakdown_json'], contains(largeText));
    } finally {
      await ScreenshotDatabase.instance.disposeDesktop();
      await _deleteTempDir(tmp);
    }
  });

  test('父子会话查询与删除会级联子代理会话', () async {
    final Directory tmp = await Directory.systemTemp.createTemp(
      'screen_memo_ai_subagent_list_',
    );
    try {
      await ScreenshotDatabase.instance.initializeForDesktop(tmp.path);
      final String parentCid = await ScreenshotDatabase.instance
          .createAiConversation(
            cid: 'parent-cid',
            title: 'Parent conversation',
          );
      final String childCid = await ScreenshotDatabase.instance
          .createAiConversation(
            cid: 'child-cid',
            title: 'Child subagent',
            model: 'chat-test',
            conversationKind: 'subagent',
            parentCid: parentCid,
            parentAssistantCreatedAt: 123,
            parentToolCallId: 'call_1',
            subagentId: 'agent_1',
            subagentRole: 'reviewer',
            subagentContextTokens: 321,
            subagentContextCapTokens: 4096,
          );
      expect(parentCid, 'parent-cid');
      expect(childCid, 'child-cid');

      final List<Map<String, dynamic>> rootRows = await ScreenshotDatabase
          .instance
          .listAiConversations();
      expect(
        rootRows.where((Map<String, dynamic> row) => row['cid'] == parentCid),
        hasLength(1),
      );
      expect(
        rootRows.where((Map<String, dynamic> row) => row['cid'] == childCid),
        isEmpty,
      );

      final List<Map<String, dynamic>> allRows = await ScreenshotDatabase
          .instance
          .listAiConversations(includeSubagents: true);
      expect(
        allRows.where((Map<String, dynamic> row) => row['cid'] == childCid),
        hasLength(1),
      );

      final List<Map<String, dynamic>> childRows = await ScreenshotDatabase
          .instance
          .listAiConversations(parentCid: parentCid, includeSubagents: true);
      expect(childRows, hasLength(1));
      expect(childRows.first['conversation_kind'], 'subagent');
      expect(childRows.first['parent_cid'], parentCid);
      expect(childRows.first['subagent_role'], 'reviewer');
      expect(childRows.first['subagent_context_tokens'], 321);
      expect(childRows.first['subagent_context_cap_tokens'], 4096);

      await ScreenshotDatabase.instance.appendAiMessage(
        parentCid,
        'user',
        'Parent message',
      );
      await ScreenshotDatabase.instance.appendAiMessage(
        childCid,
        'assistant',
        'Child message',
      );

      final bool deleted = await ScreenshotDatabase.instance
          .deleteAiConversation(parentCid);
      expect(deleted, isTrue);
      expect(
        await ScreenshotDatabase.instance.getAiConversationByCid(parentCid),
        isNull,
      );
      expect(
        await ScreenshotDatabase.instance.getAiConversationByCid(childCid),
        isNull,
      );
      expect(
        await ScreenshotDatabase.instance.getAiMessagesTail(
          parentCid,
          limit: 10,
        ),
        isEmpty,
      );
      expect(
        await ScreenshotDatabase.instance.getAiMessagesTail(
          childCid,
          limit: 10,
        ),
        isEmpty,
      );
    } finally {
      await ScreenshotDatabase.instance.disposeDesktop();
      await _deleteTempDir(tmp);
    }
  });

  test('旧版 ai_conversations 升级后仍能读取历史对话', () async {
    final Directory tmp = await Directory.systemTemp.createTemp(
      'screen_memo_ai_upgrade_legacy_',
    );
    try {
      final String dbDir = p.join(tmp.path, 'output', 'databases');
      await Directory(dbDir).create(recursive: true);
      final String dbPath = p.join(dbDir, 'screenshot_memo.db');
      final Database legacyDb = await databaseFactoryFfi.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          version: 54,
          onCreate: (Database db, int version) async {
            await db.execute('''
              CREATE TABLE ai_conversations (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                cid TEXT NOT NULL UNIQUE,
                title TEXT,
                provider_id INTEGER,
                model TEXT,
                pinned INTEGER NOT NULL DEFAULT 0,
                archived INTEGER NOT NULL DEFAULT 0,
                summary TEXT,
                summary_updated_at INTEGER,
                summary_tokens INTEGER,
                compaction_count INTEGER NOT NULL DEFAULT 0,
                last_compaction_reason TEXT,
                tool_memory_json TEXT,
                tool_memory_updated_at INTEGER,
                last_prompt_tokens INTEGER,
                last_prompt_at INTEGER,
                last_prompt_breakdown_json TEXT,
                created_at INTEGER,
                updated_at INTEGER
              )
            ''');
            await db.execute(
              'CREATE INDEX idx_ai_conversations_updated ON ai_conversations(updated_at DESC, pinned DESC, id DESC)',
            );
          },
        ),
      );
      final int now = DateTime.now().millisecondsSinceEpoch;
      await legacyDb.insert('ai_conversations', <String, Object?>{
        'cid': 'legacy-cid',
        'title': 'Legacy conversation',
        'provider_id': 1,
        'model': 'legacy-model',
        'pinned': 0,
        'archived': 0,
        'summary': 'legacy summary',
        'created_at': now,
        'updated_at': now,
      });
      await legacyDb.close();

      await ScreenshotDatabase.instance.initializeForDesktop(tmp.path);

      final List<Map<String, dynamic>> rows = await ScreenshotDatabase.instance
          .listAiConversations(includeSubagents: true);
      final Map<String, dynamic> row = rows.firstWhere(
        (Map<String, dynamic> item) => item['cid'] == 'legacy-cid',
      );
      expect(row['title'], 'Legacy conversation');
      expect(row['conversation_kind'], anyOf(isNull, 'chat'));
      expect(row['parent_cid'], isNull);

      final db = await ScreenshotDatabase.instance.database;
      final List<Map<String, Object?>> cols = await db.rawQuery(
        "PRAGMA table_info('ai_conversations')",
      );
      final Set<String> colNames = cols
          .map((Map<String, Object?> row) => row['name'] as String? ?? '')
          .where((String name) => name.isNotEmpty)
          .toSet();
      expect(
        colNames,
        containsAll(<String>[
          'conversation_kind',
          'parent_cid',
          'parent_assistant_created_at',
          'parent_tool_call_id',
          'subagent_id',
          'subagent_role',
          'subagent_context_tokens',
          'subagent_context_cap_tokens',
        ]),
      );

      final List<Map<String, Object?>> indexes = await db.rawQuery(
        "PRAGMA index_list('ai_conversations')",
      );
      final Set<String> indexNames = indexes
          .map((Map<String, Object?> row) => row['name'] as String? ?? '')
          .where((String name) => name.isNotEmpty)
          .toSet();
      expect(indexNames, contains('idx_ai_conversations_parent'));
    } finally {
      await ScreenshotDatabase.instance.disposeDesktop();
      await _deleteTempDir(tmp);
    }
  });

  test('仅有消息记录时会自动补齐会话列表索引', () async {
    final Directory tmp = await Directory.systemTemp.createTemp(
      'screen_memo_ai_conversation_repair_',
    );
    try {
      await ScreenshotDatabase.instance.initializeForDesktop(tmp.path);
      final db = await ScreenshotDatabase.instance.database;
      final int now = DateTime.now().millisecondsSinceEpoch;

      await db.insert('ai_messages', <String, Object?>{
        'conversation_id': 'recovered-cid',
        'role': 'user',
        'content': 'hello',
        'created_at': now - 10,
      });
      await db.insert('ai_messages', <String, Object?>{
        'conversation_id': 'recovered-cid',
        'role': 'assistant',
        'content': 'world',
        'created_at': now,
      });
      await db.insert('ai_settings', <String, Object?>{
        'key': 'chat_active_cid',
        'value': 'recovered-cid',
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      final List<Map<String, dynamic>> rows = await ScreenshotDatabase.instance
          .listAiConversations();
      final Map<String, dynamic> row = rows.firstWhere(
        (Map<String, dynamic> item) => item['cid'] == 'recovered-cid',
      );
      expect(row['cid'], 'recovered-cid');
      expect((row['parent_cid'] as String?)?.trim() ?? '', isEmpty);
      expect((row['updated_at'] as int?) ?? 0, greaterThanOrEqualTo(now));
    } finally {
      await ScreenshotDatabase.instance.disposeDesktop();
      await _deleteTempDir(tmp);
    }
  });
}
