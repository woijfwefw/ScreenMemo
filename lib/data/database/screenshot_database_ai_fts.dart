part of 'screenshot_database.dart';

Future<void> _createUserMemoryItemEventsTable(DatabaseExecutor db) async {
  try {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS user_memory_item_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        memory_item_id INTEGER NOT NULL,
        kind TEXT NOT NULL,                -- rule | fact | habit
        content TEXT NOT NULL,
        content_hash TEXT NOT NULL,
        keywords_json TEXT,
        confidence REAL,
        source_type TEXT NOT NULL,         -- segment | chat | daily_summary | weekly_summary | morning_insights
        source_id TEXT NOT NULL,           -- e.g. segment:123 / chat:cid=...#ts=...
        evidence_filenames_json TEXT,      -- optional JSON array of basenames (max ~5)
        start_time INTEGER,
        end_time INTEGER,
        created_at INTEGER DEFAULT (strftime('%s','now') * 1000),
        UNIQUE(memory_item_id, source_type, source_id, content_hash)
      )
    ''');
  } catch (_) {}

  // Expression index for stable chronological reads; best-effort for older SQLite.
  try {
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_user_memory_item_events_item
      ON user_memory_item_events(memory_item_id, COALESCE(start_time, created_at) ASC, id ASC)
      ''');
  } catch (_) {}
}

Future<void> _createWeeklySummariesTable(DatabaseExecutor db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS weekly_summaries (
      week_start_date TEXT PRIMARY KEY,
      week_end_date TEXT NOT NULL,
      ai_provider TEXT,
      ai_model TEXT,
      output_text TEXT,
      structured_json TEXT,
      created_at INTEGER DEFAULT (strftime('%s','now') * 1000)
    )
  ''');
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_weekly_summaries_created ON weekly_summaries(created_at DESC)',
  );
}

Future<void> _createMorningInsightsTable(DatabaseExecutor db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS morning_insights (
      date_key TEXT PRIMARY KEY,
      source_date_key TEXT NOT NULL,
      tips_json TEXT NOT NULL,
      raw_response TEXT,
      created_at INTEGER DEFAULT (strftime('%s','now') * 1000)
    )
  ''');
}

/// 创建 segment_results 的 FTS5 全文搜索索引
Future<void> _createSegmentResultsFts(DatabaseExecutor db) async {
  try {
    await db.execute('''
      CREATE VIRTUAL TABLE IF NOT EXISTS segment_results_fts USING fts5(
        output_text,
        structured_json,
        categories,
        content='segment_results',
        content_rowid='segment_id',
        prefix='2 3 4'
      )
    ''');
    // 创建触发器保持 FTS 同步
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS segment_results_ai AFTER INSERT ON segment_results BEGIN
        INSERT INTO segment_results_fts(rowid, output_text, structured_json, categories)
        VALUES (NEW.segment_id, NEW.output_text, NEW.structured_json, NEW.categories);
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS segment_results_ad AFTER DELETE ON segment_results BEGIN
        INSERT INTO segment_results_fts(segment_results_fts, rowid, output_text, structured_json, categories)
        VALUES ('delete', OLD.segment_id, OLD.output_text, OLD.structured_json, OLD.categories);
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS segment_results_au AFTER UPDATE ON segment_results BEGIN
        INSERT INTO segment_results_fts(segment_results_fts, rowid, output_text, structured_json, categories)
        VALUES ('delete', OLD.segment_id, OLD.output_text, OLD.structured_json, OLD.categories);
        INSERT INTO segment_results_fts(rowid, output_text, structured_json, categories)
        VALUES (NEW.segment_id, NEW.output_text, NEW.structured_json, NEW.categories);
      END
    ''');
  } catch (e) {
    try {
      FlutterLogger.nativeWarn('DB', 'FTS5（segment_results）不支持：$e');
    } catch (_) {}
  }
}

/// 回填已有数据到 FTS 索引
Future<void> _backfillSegmentResultsFts(DatabaseExecutor db) async {
  try {
    await db.execute('''
      INSERT OR IGNORE INTO segment_results_fts(rowid, output_text, structured_json, categories)
      SELECT segment_id, output_text, structured_json, categories FROM segment_results
      WHERE (output_text IS NOT NULL AND TRIM(output_text) != '')
         OR (structured_json IS NOT NULL AND TRIM(structured_json) != '')
         OR (categories IS NOT NULL AND TRIM(categories) != '')
    ''');
  } catch (e) {
    try {
      FlutterLogger.nativeWarn('DB', '回填 segment_results_fts 失败：$e');
    } catch (_) {}
  }
}

/// 创建 ai_image_meta 的 FTS5 全文搜索索引（用于按图片标签/描述检索）。
Future<void> _createAiImageMetaFts(DatabaseExecutor db) async {
  try {
    await db.execute('''
      CREATE VIRTUAL TABLE IF NOT EXISTS ai_image_meta_fts USING fts5(
        tags_json,
        description,
        description_range,
        content='ai_image_meta',
        content_rowid='rowid',
        prefix='2 3 4'
      )
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS ai_image_meta_ai AFTER INSERT ON ai_image_meta BEGIN
        INSERT INTO ai_image_meta_fts(rowid, tags_json, description, description_range)
        VALUES (NEW.rowid, NEW.tags_json, NEW.description, NEW.description_range);
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS ai_image_meta_ad AFTER DELETE ON ai_image_meta BEGIN
        INSERT INTO ai_image_meta_fts(ai_image_meta_fts, rowid, tags_json, description, description_range)
        VALUES ('delete', OLD.rowid, OLD.tags_json, OLD.description, OLD.description_range);
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS ai_image_meta_au AFTER UPDATE ON ai_image_meta BEGIN
        INSERT INTO ai_image_meta_fts(ai_image_meta_fts, rowid, tags_json, description, description_range)
        VALUES ('delete', OLD.rowid, OLD.tags_json, OLD.description, OLD.description_range);
        INSERT INTO ai_image_meta_fts(rowid, tags_json, description, description_range)
        VALUES (NEW.rowid, NEW.tags_json, NEW.description, NEW.description_range);
      END
    ''');
  } catch (e) {
    try {
      FlutterLogger.nativeWarn('DB', 'FTS5（ai_image_meta）不支持：$e');
    } catch (_) {}
  }
}

/// 回填已有数据到 ai_image_meta_fts 索引
Future<void> _backfillAiImageMetaFts(DatabaseExecutor db) async {
  try {
    await db.execute('''
      INSERT OR IGNORE INTO ai_image_meta_fts(rowid, tags_json, description, description_range)
      SELECT rowid, tags_json, description, description_range FROM ai_image_meta
      WHERE
        (description IS NOT NULL AND TRIM(description) != '')
        OR (tags_json IS NOT NULL AND TRIM(tags_json) != '')
    ''');
  } catch (e) {
    try {
      FlutterLogger.nativeWarn('DB', '回填 ai_image_meta_fts 失败：$e');
    } catch (_) {}
  }
}

/// Create FTS5 index for ai_atomic_memories (atomic facts/rules).
Future<void> _createAtomicMemoriesFts(DatabaseExecutor db) async {
  try {
    await db.execute('''
      CREATE VIRTUAL TABLE IF NOT EXISTS ai_atomic_memories_fts USING fts5(
        memory_key,
        content,
        keywords_json,
        content='ai_atomic_memories',
        content_rowid='rowid',
        prefix='2 3 4'
      )
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS ai_atomic_memories_ai AFTER INSERT ON ai_atomic_memories BEGIN
        INSERT INTO ai_atomic_memories_fts(rowid, memory_key, content, keywords_json)
        VALUES (NEW.rowid, NEW.memory_key, NEW.content, NEW.keywords_json);
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS ai_atomic_memories_ad AFTER DELETE ON ai_atomic_memories BEGIN
        INSERT INTO ai_atomic_memories_fts(ai_atomic_memories_fts, rowid, memory_key, content, keywords_json)
        VALUES ('delete', OLD.rowid, OLD.memory_key, OLD.content, OLD.keywords_json);
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS ai_atomic_memories_au AFTER UPDATE ON ai_atomic_memories BEGIN
        INSERT INTO ai_atomic_memories_fts(ai_atomic_memories_fts, rowid, memory_key, content, keywords_json)
        VALUES ('delete', OLD.rowid, OLD.memory_key, OLD.content, OLD.keywords_json);
        INSERT INTO ai_atomic_memories_fts(rowid, memory_key, content, keywords_json)
        VALUES (NEW.rowid, NEW.memory_key, NEW.content, NEW.keywords_json);
      END
    ''');
  } catch (e) {
    try {
      FlutterLogger.nativeWarn('DB', 'FTS5（ai_atomic_memories）不支持：$e');
    } catch (_) {}
  }
}

/// Backfill existing rows into ai_atomic_memories_fts.
Future<void> _backfillAtomicMemoriesFts(DatabaseExecutor db) async {
  try {
    await db.execute('''
      INSERT OR IGNORE INTO ai_atomic_memories_fts(rowid, memory_key, content, keywords_json)
      SELECT rowid, memory_key, content, keywords_json FROM ai_atomic_memories
      WHERE
        (content IS NOT NULL AND TRIM(content) != '')
        OR (memory_key IS NOT NULL AND TRIM(memory_key) != '')
        OR (keywords_json IS NOT NULL AND TRIM(keywords_json) != '')
    ''');
  } catch (e) {
    try {
      FlutterLogger.nativeWarn('DB', '回填 ai_atomic_memories_fts 失败：$e');
    } catch (_) {}
  }
}

/// Create FTS5 index for user_memory_items (global user memory).
Future<void> _createUserMemoryItemsFts(DatabaseExecutor db) async {
  try {
    await db.execute('''
      CREATE VIRTUAL TABLE IF NOT EXISTS user_memory_items_fts USING fts5(
        memory_key,
        content,
        keywords_json,
        content='user_memory_items',
        content_rowid='rowid',
        prefix='2 3 4'
      )
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS user_memory_items_ai AFTER INSERT ON user_memory_items BEGIN
        INSERT INTO user_memory_items_fts(rowid, memory_key, content, keywords_json)
        VALUES (NEW.rowid, NEW.memory_key, NEW.content, NEW.keywords_json);
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS user_memory_items_ad AFTER DELETE ON user_memory_items BEGIN
        INSERT INTO user_memory_items_fts(user_memory_items_fts, rowid, memory_key, content, keywords_json)
        VALUES ('delete', OLD.rowid, OLD.memory_key, OLD.content, OLD.keywords_json);
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS user_memory_items_au AFTER UPDATE ON user_memory_items BEGIN
        INSERT INTO user_memory_items_fts(user_memory_items_fts, rowid, memory_key, content, keywords_json)
        VALUES ('delete', OLD.rowid, OLD.memory_key, OLD.content, OLD.keywords_json);
        INSERT INTO user_memory_items_fts(rowid, memory_key, content, keywords_json)
        VALUES (NEW.rowid, NEW.memory_key, NEW.content, NEW.keywords_json);
      END
    ''');
  } catch (e) {
    try {
      FlutterLogger.nativeWarn('DB', 'FTS5（user_memory_items）不支持：$e');
    } catch (_) {}
  }
}

/// Backfill existing rows into user_memory_items_fts.
Future<void> _backfillUserMemoryItemsFts(DatabaseExecutor db) async {
  try {
    await db.execute('''
      INSERT OR IGNORE INTO user_memory_items_fts(rowid, memory_key, content, keywords_json)
      SELECT rowid, memory_key, content, keywords_json FROM user_memory_items
      WHERE
        (content IS NOT NULL AND TRIM(content) != '')
        OR (memory_key IS NOT NULL AND TRIM(memory_key) != '')
        OR (keywords_json IS NOT NULL AND TRIM(keywords_json) != '')
    ''');
  } catch (e) {
    try {
      FlutterLogger.nativeWarn('DB', '回填 user_memory_items_fts 失败：$e');
    } catch (_) {}
  }
}

/// v32 migration: Recreate AI-related FTS tables so new options (e.g. prefix)
/// take effect even when the virtual tables already existed.
Future<void> _recreateAiFtsTablesWithPrefix(DatabaseExecutor db) async {
  Future<void> drop(String name) async {
    try {
      await db.execute('DROP TABLE IF EXISTS $name');
    } catch (_) {}
  }

  // These are derived indexes; safe to rebuild from their content tables.
  await drop('segment_results_fts');
  await drop('ai_image_meta_fts');
  await drop('ai_atomic_memories_fts');
  await drop('user_memory_items_fts');

  try {
    await _createSegmentResultsFts(db);
  } catch (_) {}
  try {
    await _backfillSegmentResultsFts(db);
  } catch (_) {}

  try {
    await _createAiImageMetaFts(db);
  } catch (_) {}
  try {
    await _backfillAiImageMetaFts(db);
  } catch (_) {}

  try {
    await _createAtomicMemoriesFts(db);
  } catch (_) {}
  try {
    await _backfillAtomicMemoriesFts(db);
  } catch (_) {}

  try {
    await _createUserMemoryItemsFts(db);
  } catch (_) {}
  try {
    await _backfillUserMemoryItemsFts(db);
  } catch (_) {}
}
