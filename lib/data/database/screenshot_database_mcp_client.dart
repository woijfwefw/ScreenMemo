part of 'screenshot_database.dart';

extension ScreenshotDatabaseMcpClientExt on ScreenshotDatabase {
  Future<void> _createMcpClientTables(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS mcp_client_servers (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        transport TEXT NOT NULL,
        url TEXT NOT NULL,
        headers_json TEXT NOT NULL DEFAULT '{}',
        enabled INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        last_synced_at INTEGER,
        last_error TEXT
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_mcp_client_servers_enabled ON mcp_client_servers(enabled, updated_at DESC)',
    );
    await db.execute('''
      CREATE TABLE IF NOT EXISTS mcp_client_tools (
        id TEXT PRIMARY KEY,
        server_id TEXT NOT NULL,
        name TEXT NOT NULL,
        dynamic_name TEXT NOT NULL,
        description TEXT,
        input_schema_json TEXT,
        enabled INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        last_synced_at INTEGER,
        FOREIGN KEY(server_id) REFERENCES mcp_client_servers(id) ON DELETE CASCADE,
        UNIQUE(server_id, name),
        UNIQUE(dynamic_name)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_mcp_client_tools_server ON mcp_client_tools(server_id, enabled, updated_at DESC)',
    );
  }

  Future<List<Map<String, Object?>>> listMcpClientServersRaw() async {
    final db = await database;
    return db.query(
      'mcp_client_servers',
      orderBy: 'updated_at DESC, name COLLATE NOCASE ASC',
    );
  }

  Future<Map<String, Object?>?> getMcpClientServerRaw(String id) async {
    final db = await database;
    final rows = await db.query(
      'mcp_client_servers',
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<Map<String, Object?>?> getMcpClientServerByNameRaw(String name) async {
    final db = await database;
    final rows = await db.query(
      'mcp_client_servers',
      where: 'LOWER(name) = LOWER(?)',
      whereArgs: <Object?>[name],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> upsertMcpClientServerRaw(Map<String, Object?> values) async {
    final db = await database;
    final String id = (values['id'] ?? '').toString();
    final updated = await db.update(
      'mcp_client_servers',
      values,
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
    if (updated == 0) {
      final existing = await db.query(
        'mcp_client_servers',
        columns: const <String>['id'],
        where: 'id = ?',
        whereArgs: <Object?>[id],
        limit: 1,
      );
      if (existing.isNotEmpty) return;
      await db.insert('mcp_client_servers', values);
    }
  }

  Future<void> updateMcpClientServerRaw(
    String id,
    Map<String, Object?> values,
  ) async {
    final db = await database;
    await db.update(
      'mcp_client_servers',
      values,
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  Future<void> deleteMcpClientServer(String id) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete(
        'mcp_client_tools',
        where: 'server_id = ?',
        whereArgs: <Object?>[id],
      );
      await txn.delete(
        'mcp_client_servers',
        where: 'id = ?',
        whereArgs: <Object?>[id],
      );
    });
  }

  Future<List<Map<String, Object?>>> listMcpClientToolsRaw({
    String? serverId,
    bool enabledOnly = false,
  }) async {
    final db = await database;
    final List<String> where = <String>[];
    final List<Object?> args = <Object?>[];
    if ((serverId ?? '').trim().isNotEmpty) {
      where.add('server_id = ?');
      args.add(serverId!.trim());
    }
    if (enabledOnly) {
      where.add('enabled = 1');
    }
    return db.query(
      'mcp_client_tools',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'server_id ASC, name COLLATE NOCASE ASC',
    );
  }

  Future<Map<String, Object?>?> getMcpClientToolByDynamicNameRaw(
    String dynamicName,
  ) async {
    final db = await database;
    final rows = await db.query(
      'mcp_client_tools',
      where: 'dynamic_name = ?',
      whereArgs: <Object?>[dynamicName],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> replaceMcpClientToolsForServer({
    required String serverId,
    required Iterable<Map<String, Object?>> tools,
    required int syncedAt,
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      final existingRows = await txn.query(
        'mcp_client_tools',
        where: 'server_id = ?',
        whereArgs: <Object?>[serverId],
      );
      final Map<String, Map<String, Object?>> existingByName =
          <String, Map<String, Object?>>{};
      for (final row in existingRows) {
        final String name = (row['name'] ?? '').toString();
        if (name.isNotEmpty) existingByName[name] = row;
      }
      final Set<String> seen = <String>{};
      for (final tool in tools) {
        final String name = (tool['name'] ?? '').toString();
        if (name.trim().isEmpty) continue;
        seen.add(name);
        final Map<String, Object?>? old = existingByName[name];
        final Map<String, Object?> values = <String, Object?>{
          ...tool,
          'server_id': serverId,
          'enabled': old?['enabled'] ?? 0,
          'created_at': old?['created_at'] ?? syncedAt,
          'updated_at': syncedAt,
          'last_synced_at': syncedAt,
        };
        await txn.insert(
          'mcp_client_tools',
          values,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      for (final row in existingRows) {
        final String name = (row['name'] ?? '').toString();
        if (seen.contains(name)) continue;
        await txn.delete(
          'mcp_client_tools',
          where: 'server_id = ? AND name = ?',
          whereArgs: <Object?>[serverId, name],
        );
      }
      await txn.update(
        'mcp_client_servers',
        <String, Object?>{
          'last_synced_at': syncedAt,
          'last_error': null,
          'updated_at': syncedAt,
        },
        where: 'id = ?',
        whereArgs: <Object?>[serverId],
      );
    });
  }

  Future<void> updateMcpClientToolOptions({
    required String dynamicName,
    bool? enabled,
  }) async {
    final values = <String, Object?>{
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    };
    if (enabled != null) values['enabled'] = enabled ? 1 : 0;
    final db = await database;
    await db.update(
      'mcp_client_tools',
      values,
      where: 'dynamic_name = ?',
      whereArgs: <Object?>[dynamicName],
    );
  }

  Future<int> countMcpClientToolByDynamicName(String dynamicName) async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM mcp_client_tools WHERE dynamic_name = ?',
      <Object?>[dynamicName],
    );
    return (rows.first['c'] as int?) ?? 0;
  }
}
