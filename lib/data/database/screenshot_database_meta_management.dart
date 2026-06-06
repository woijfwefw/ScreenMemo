part of 'screenshot_database.dart';

extension ScreenshotDatabaseMetaManagement on ScreenshotDatabase {
  Future<int> getScreenshotCountByAppBetween(
    String appPackageName, {
    required int startMillis,
    required int endMillis,
  }) async {
    final db = await database; // 主库
    try {
      if (endMillis < startMillis) return 0;
      int total = 0;
      final DateTime s = DateTime.fromMillisecondsSinceEpoch(startMillis);
      final DateTime e = DateTime.fromMillisecondsSinceEpoch(endMillis);
      final years = await _listShardYearsForApp(appPackageName);
      if (years.isEmpty) return 0;
      final List<List<int>> ymList = _listYearMonthBetween(s, e);
      for (final ym in ymList) {
        final int y = ym[0];
        final int m = ym[1];
        if (!years.contains(y)) continue;
        final shardDb = await _openShardDb(appPackageName, y);
        if (shardDb == null) continue;
        final String t = _monthTableName(y, m);
        if (!await _tableExists(shardDb, t)) continue;
        try {
          final rows = await shardDb.rawQuery(
            'SELECT COUNT(*) as c FROM $t WHERE capture_time >= ? AND capture_time <= ?',
            [startMillis, endMillis],
          );
          total += (rows.first['c'] as int?) ?? 0;
        } catch (_) {}
      }
      return total;
    } catch (e) {
      print('getScreenshotCountByAppBetween 失败: $e');
      return 0;
    }
  }

  Future<List<ScreenshotRecord>> getScreenshotsByAppBetween(
    String appPackageName, {
    required int startMillis,
    required int endMillis,
    int? limit,
    int? offset,
  }) async {
    final db = await database; // 主库
    try {
      if (endMillis < startMillis) return <ScreenshotRecord>[];
      String appName = appPackageName;
      try {
        final appInfo = await db.query(
          'app_registry',
          columns: ['app_name'],
          where: 'app_package_name = ?',
          whereArgs: [appPackageName],
          limit: 1,
        );
        if (appInfo.isNotEmpty) {
          appName = (appInfo.first['app_name'] as String?) ?? appPackageName;
        }
      } catch (_) {}

      final years = await _listShardYearsForApp(appPackageName);
      if (years.isEmpty) return <ScreenshotRecord>[];
      final List<List<int>> ymList = _listYearMonthBetween(
        DateTime.fromMillisecondsSinceEpoch(startMillis),
        DateTime.fromMillisecondsSinceEpoch(endMillis),
      );

      final List<Map<String, dynamic>> rows = <Map<String, dynamic>>[];
      for (final ym in ymList) {
        final int y = ym[0];
        final int m = ym[1];
        if (!years.contains(y)) continue;
        final shardDb = await _openShardDb(appPackageName, y);
        if (shardDb == null) continue;
        final String t = _monthTableName(y, m);
        if (!await _tableExists(shardDb, t)) continue;
        try {
          final maps = await shardDb.query(
            t,
            where: 'capture_time >= ? AND capture_time <= ?',
            whereArgs: [startMillis, endMillis],
            orderBy: 'capture_time DESC',
          );
          for (final map in maps) {
            final full = Map<String, dynamic>.from(map);
            full['app_package_name'] = appPackageName;
            full['app_name'] = appName;
            final localId = (map['id'] as int?) ?? 0;
            full['id'] = _encodeGid(y, m, localId);
            rows.add(full);
          }
        } catch (_) {}
      }

      rows.sort((a, b) {
        final int ta = (a['capture_time'] as int?) ?? 0;
        final int tb = (b['capture_time'] as int?) ?? 0;
        return tb.compareTo(ta);
      });

      int start = offset ?? 0;
      if (start < 0) start = 0;
      int end = limit != null ? (start + limit) : rows.length;
      if (start > rows.length) return <ScreenshotRecord>[];
      if (end > rows.length) end = rows.length;
      final slice = rows.sublist(start, end);
      return slice.map((m) => ScreenshotRecord.fromMap(m)).toList();
    } catch (e) {
      print('getScreenshotsByAppBetween 查询失败: $e');
      return <ScreenshotRecord>[];
    }
  }

  /// 列出指定应用所有有数据的日期（本地时区），按日期倒序返回
  /// 返回元素：{ 'date': 'YYYY-MM-DD', 'count': <int> }
  Future<List<Map<String, dynamic>>> listAvailableDaysForApp(
    String appPackageName,
  ) async {
    final Map<String, int> dayToCount = <String, int>{};
    try {
      final years = await _listShardYearsForApp(appPackageName);
      if (years.isEmpty) return <Map<String, dynamic>>[];
      for (final y in years) {
        final shardDb = await _openShardDb(appPackageName, y);
        if (shardDb == null) continue;
        for (int m = 1; m <= 12; m++) {
          final String t = _monthTableName(y, m);
          if (!await _tableExists(shardDb, t)) continue;
          try {
            final List<Map<String, Object?>>
            rows = await (shardDb as Database).rawQuery(
              'SELECT date(capture_time/1000, "unixepoch", "localtime") AS d, COUNT(*) AS c FROM ' +
                  t +
                  ' WHERE is_deleted = 0 GROUP BY d',
            );
            for (final r in rows) {
              final String d = (r['d'] as String?) ?? '';
              if (d.isEmpty) continue;
              final int c = (r['c'] as int?) ?? 0;
              dayToCount[d] = (dayToCount[d] ?? 0) + c;
            }
          } catch (_) {}
        }
      }
      final List<Map<String, dynamic>> out = dayToCount.entries
          .map((e) => <String, dynamic>{'date': e.key, 'count': e.value})
          .toList();
      out.sort((a, b) => (b['date'] as String).compareTo(a['date'] as String));
      return out;
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  /// 列出指定应用在时间范围内所有有数据的日期（本地时区），按日期倒序返回。
  ///
  /// 相比 `listAvailableDaysForApp()`，该方法只扫描涉及的年月表，
  /// 用于截图列表日期 Tab 首屏与增量加载。
  Future<List<Map<String, dynamic>>> listAvailableDaysForAppRange(
    String appPackageName, {
    required int startMillis,
    required int endMillis,
  }) async {
    final String packageName = appPackageName.trim();
    if (packageName.isEmpty || endMillis < startMillis) {
      return <Map<String, dynamic>>[];
    }
    final Map<String, int> dayToCount = <String, int>{};
    try {
      final years = await _listShardYearsForApp(packageName);
      if (years.isEmpty) return <Map<String, dynamic>>[];

      final DateTime s = DateTime.fromMillisecondsSinceEpoch(startMillis);
      final DateTime e = DateTime.fromMillisecondsSinceEpoch(endMillis);
      final List<List<int>> ymList = _listYearMonthBetween(s, e);
      if (ymList.isEmpty) return <Map<String, dynamic>>[];

      for (final ym in ymList) {
        final int y = ym[0];
        final int m = ym[1];
        if (!years.contains(y)) continue;
        final shardDb = await _openShardDb(packageName, y);
        if (shardDb == null) continue;
        final String t = _monthTableName(y, m);
        if (!await _tableExists(shardDb, t)) continue;
        try {
          final List<Map<String, Object?>>
          rows = await (shardDb as Database).rawQuery(
            'SELECT date(capture_time/1000, "unixepoch", "localtime") AS d, COUNT(*) AS c FROM '
            '$t WHERE capture_time >= ? AND capture_time <= ? AND is_deleted = 0 GROUP BY d',
            <Object?>[startMillis, endMillis],
          );
          for (final r in rows) {
            final String d = (r['d'] as String?) ?? '';
            if (d.isEmpty) continue;
            final int c = (r['c'] as int?) ?? 0;
            if (c <= 0) continue;
            dayToCount[d] = (dayToCount[d] ?? 0) + c;
          }
        } catch (_) {}
      }
      final List<Map<String, dynamic>> out = dayToCount.entries
          .map((e) => <String, dynamic>{'date': e.key, 'count': e.value})
          .toList();
      out.sort((a, b) => (b['date'] as String).compareTo(a['date'] as String));
      return out;
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  Future<List<Map<String, dynamic>>> listAvailableMonthDaysForApp(
    String appPackageName, {
    required int year,
    required int month,
  }) async {
    if (year <= 0 || month < 1 || month > 12) {
      return <Map<String, dynamic>>[];
    }
    final DateTime start = DateTime(year, month);
    final DateTime end = DateTime(year, month + 1, 0, 23, 59, 59);
    return listAvailableDaysForAppRange(
      appPackageName,
      startMillis: start.millisecondsSinceEpoch,
      endMillis: end.millisecondsSinceEpoch,
    );
  }

  Future<List<int>> listAvailableYearsForApp(String appPackageName) async {
    final String packageName = appPackageName.trim();
    if (packageName.isEmpty) return const <int>[];
    try {
      final List<int> years = await _listShardYearsForApp(packageName);
      final List<int> sorted = years.where((year) => year > 0).toSet().toList();
      sorted.sort((int a, int b) => b.compareTo(a));
      return sorted;
    } catch (_) {
      return const <int>[];
    }
  }

  /// 全局列出所有有数据的日期（本地时区），按日期倒序返回
  /// 返回元素：{ 'date': 'YYYY-MM-DD', 'count': <int> }
  Future<List<Map<String, dynamic>>> listAvailableDaysGlobal() async {
    final Map<String, int> dayToCount = <String, int>{};
    try {
      final db = await database; // 主库
      final shards = await db.query(
        'shard_registry',
        columns: ['app_package_name', 'year'],
        orderBy: 'year DESC',
      );
      for (final sh in shards) {
        final String pkg = sh['app_package_name'] as String;
        final int y = sh['year'] as int;
        final shardDb = await _openShardDb(pkg, y);
        if (shardDb == null) continue;
        for (int m = 1; m <= 12; m++) {
          final String t = _monthTableName(y, m);
          if (!await _tableExists(shardDb, t)) continue;
          try {
            final List<Map<String, Object?>>
            rows = await (shardDb as Database).rawQuery(
              'SELECT date(capture_time/1000, "unixepoch", "localtime") AS d, COUNT(*) AS c FROM ' +
                  t +
                  ' WHERE is_deleted = 0 GROUP BY d',
            );
            for (final r in rows) {
              final String d = (r['d'] as String?) ?? '';
              if (d.isEmpty) continue;
              final int c = (r['c'] as int?) ?? 0;
              dayToCount[d] = (dayToCount[d] ?? 0) + c;
            }
          } catch (_) {}
        }
      }
      final List<Map<String, dynamic>> out = dayToCount.entries
          .map((e) => <String, dynamic>{'date': e.key, 'count': e.value})
          .toList();
      out.sort((a, b) => (b['date'] as String).compareTo(a['date'] as String));
      return out;
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  /// 全局列出指定时间范围内所有有数据的日期（本地时区），按日期倒序返回
  /// 返回元素：{ 'date': 'YYYY-MM-DD', 'count': <int> }
  ///
  /// 相比 `listAvailableDaysGlobal()`，该方法会按范围仅扫描涉及的年月表，
  /// 用于时间线首屏/增量加载，避免全库扫描导致卡顿。
  Future<List<Map<String, dynamic>>> listAvailableDaysGlobalRange({
    required int startMillis,
    required int endMillis,
  }) async {
    if (endMillis < startMillis) return <Map<String, dynamic>>[];
    final Map<String, int> dayToCount = <String, int>{};
    try {
      final db = await database; // 主库
      final DateTime s = DateTime.fromMillisecondsSinceEpoch(startMillis);
      final DateTime e = DateTime.fromMillisecondsSinceEpoch(endMillis);
      final List<List<int>> ymList = _listYearMonthBetween(s, e);
      if (ymList.isEmpty) return <Map<String, dynamic>>[];

      final Map<int, List<int>> monthsByYear = <int, List<int>>{};
      for (final ym in ymList) {
        if (ym.length < 2) continue;
        monthsByYear.putIfAbsent(ym[0], () => <int>[]).add(ym[1]);
      }

      final shards = await db.query(
        'shard_registry',
        columns: ['app_package_name', 'year'],
        orderBy: 'year DESC',
      );
      if (shards.isEmpty) return <Map<String, dynamic>>[];

      for (final sh in shards) {
        final String pkg = sh['app_package_name'] as String;
        final int y = sh['year'] as int;
        final List<int>? months = monthsByYear[y];
        if (months == null || months.isEmpty) continue;
        final shardDb = await _openShardDb(pkg, y);
        if (shardDb == null) continue;
        for (final m in months) {
          final String t = _monthTableName(y, m);
          if (!await _tableExists(shardDb, t)) continue;
          try {
            final List<Map<String, Object?>>
            rows = await (shardDb as Database).rawQuery(
              'SELECT date(capture_time/1000, \"unixepoch\", \"localtime\") AS d, COUNT(*) AS c FROM ' +
                  t +
                  ' WHERE capture_time >= ? AND capture_time <= ? AND is_deleted = 0 GROUP BY d',
              <Object?>[startMillis, endMillis],
            );
            for (final r in rows) {
              final String d = (r['d'] as String?) ?? '';
              if (d.isEmpty) continue;
              final int c = (r['c'] as int?) ?? 0;
              if (c <= 0) continue;
              dayToCount[d] = (dayToCount[d] ?? 0) + c;
            }
          } catch (_) {}
        }
      }
      if (dayToCount.isEmpty) return <Map<String, dynamic>>[];
      final List<Map<String, dynamic>> out = dayToCount.entries
          .map((e) => <String, dynamic>{'date': e.key, 'count': e.value})
          .toList();
      out.sort((a, b) => (b['date'] as String).compareTo(a['date'] as String));
      return out;
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  Future<List<Map<String, dynamic>>> listAvailableMonthDaysGlobal({
    required int year,
    required int month,
  }) async {
    if (year <= 0 || month < 1 || month > 12) {
      return <Map<String, dynamic>>[];
    }
    final DateTime start = DateTime(year, month);
    final DateTime end = DateTime(year, month + 1, 0, 23, 59, 59);
    return listAvailableDaysGlobalRange(
      startMillis: start.millisecondsSinceEpoch,
      endMillis: end.millisecondsSinceEpoch,
    );
  }

  Future<List<int>> listAvailableYearsGlobal() async {
    final db = await database; // 主库
    try {
      final List<Map<String, Object?>> rows = await db.rawQuery(
        'SELECT DISTINCT year FROM shard_registry ORDER BY year DESC',
      );
      return rows
          .map((row) => row['year'])
          .map((value) {
            if (value is int) return value;
            if (value is num) return value.toInt();
            return int.tryParse(value?.toString() ?? '') ?? 0;
          })
          .where((year) => year > 0)
          .toSet()
          .toList()
        ..sort((int a, int b) => b.compareTo(a));
    } catch (_) {
      return const <int>[];
    }
  }

  // ===================== 收藏相关方法 =====================
  Future<bool> addOrUpdateFavorite({
    required int screenshotId,
    required String appPackageName,
    String? note,
  }) async {
    final db = await database;
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      await db.insert('favorites', {
        'screenshot_id': screenshotId,
        'app_package_name': appPackageName,
        'favorite_time': now,
        'note': note,
        'updated_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      // 同步 SearchIndex：仅索引“有备注”的收藏
      final String trimmed = (note ?? '').trim();
      final String docKey = _favoriteNoteDocKey(appPackageName, screenshotId);
      if (trimmed.isNotEmpty) {
        // ignore: unawaited_futures
        this.upsertSearchDoc(
          docKey: docKey,
          docType: kSearchDocTypeFavoriteNote,
          title: '收藏备注',
          content: trimmed,
          appPackageName: appPackageName,
          screenshotId: screenshotId,
          updatedAt: now,
        );
      } else {
        // ignore: unawaited_futures
        this.deleteSearchDoc(docKey);
      }
      return true;
    } catch (e) {
      print('添加收藏失败: $e');
      return false;
    }
  }

  Future<bool> removeFavorite({
    required int screenshotId,
    required String appPackageName,
  }) async {
    final db = await database;
    try {
      final result = await db.delete(
        'favorites',
        where: 'screenshot_id = ? AND app_package_name = ?',
        whereArgs: [screenshotId, appPackageName],
      );
      if (result > 0) {
        // ignore: unawaited_futures
        this.deleteSearchDoc(_favoriteNoteDocKey(appPackageName, screenshotId));
      }
      return result > 0;
    } catch (e) {
      print('移除收藏失败: $e');
      return false;
    }
  }

  Future<bool> isFavorite({
    required int screenshotId,
    required String appPackageName,
  }) async {
    final db = await database;
    try {
      final result = await db.query(
        'favorites',
        where: 'screenshot_id = ? AND app_package_name = ?',
        whereArgs: [screenshotId, appPackageName],
        limit: 1,
      );
      return result.isNotEmpty;
    } catch (e) {
      print('检查收藏状态失败: $e');
      return false;
    }
  }

  Future<Map<int, bool>> checkFavorites({
    required List<int> screenshotIds,
    required String appPackageName,
  }) async {
    final db = await database;
    final Map<int, bool> result = {};
    if (screenshotIds.isEmpty) return result;
    try {
      final placeholders = List.filled(screenshotIds.length, '?').join(',');
      final rows = await db.query(
        'favorites',
        columns: ['screenshot_id'],
        where: 'screenshot_id IN ($placeholders) AND app_package_name = ?',
        whereArgs: [...screenshotIds, appPackageName],
      );
      final favoriteIds = rows.map((r) => r['screenshot_id'] as int).toSet();
      for (final id in screenshotIds) {
        result[id] = favoriteIds.contains(id);
      }
    } catch (e) {
      print('批量检查收藏状态失败: $e');
      for (final id in screenshotIds) {
        result[id] = false;
      }
    }
    return result;
  }

  Future<List<Map<String, dynamic>>> getAllFavorites({
    int? limit,
    int? offset,
  }) async {
    final db = await database;
    try {
      final rows = await db.query(
        'favorites',
        orderBy: 'favorite_time DESC',
        limit: limit,
        offset: offset,
      );
      return rows;
    } catch (e) {
      print('获取收藏列表失败: $e');
      return <Map<String, dynamic>>[];
    }
  }

  Future<int> getFavoritesCount() async {
    final db = await database;
    try {
      final result = await db.rawQuery(
        'SELECT COUNT(*) as count FROM favorites',
      );
      return (result.first['count'] as int?) ?? 0;
    } catch (e) {
      print('获取收藏数量失败: $e');
      return 0;
    }
  }

  Future<bool> updateFavoriteNote({
    required int screenshotId,
    required String appPackageName,
    String? note,
  }) async {
    final db = await database;
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final result = await db.update(
        'favorites',
        {'note': note, 'updated_at': now},
        where: 'screenshot_id = ? AND app_package_name = ?',
        whereArgs: [screenshotId, appPackageName],
      );
      if (result > 0) {
        // 同步 SearchIndex：仅索引“有备注”的收藏
        final String trimmed = (note ?? '').trim();
        final String docKey = _favoriteNoteDocKey(appPackageName, screenshotId);
        if (trimmed.isNotEmpty) {
          // ignore: unawaited_futures
          this.upsertSearchDoc(
            docKey: docKey,
            docType: kSearchDocTypeFavoriteNote,
            title: '收藏备注',
            content: trimmed,
            appPackageName: appPackageName,
            screenshotId: screenshotId,
            updatedAt: now,
          );
        } else {
          // ignore: unawaited_futures
          this.deleteSearchDoc(docKey);
        }
      }
      return result > 0;
    } catch (e) {
      print('更新收藏备注失败: $e');
      return false;
    }
  }

  Future<Map<String, dynamic>?> getFavoriteDetail({
    required int screenshotId,
    required String appPackageName,
  }) async {
    final db = await database;
    try {
      final rows = await db.query(
        'favorites',
        where: 'screenshot_id = ? AND app_package_name = ?',
        whereArgs: [screenshotId, appPackageName],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      return rows.first;
    } catch (e) {
      print('获取收藏详情失败: $e');
      return null;
    }
  }

  // ===================== NSFW 偏好表（域名规则 + 手动标记） =====================
  Future<void> _createNsfwTables(DatabaseExecutor db) async {
    // 域名禁用规则
    await db.execute('''
      CREATE TABLE IF NOT EXISTS nsfw_domain_rules (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        pattern TEXT NOT NULL UNIQUE,
        is_wildcard INTEGER NOT NULL DEFAULT 0,
        comment TEXT,
        created_at INTEGER DEFAULT (strftime('%s','now') * 1000),
        updated_at INTEGER DEFAULT (strftime('%s','now') * 1000)
      )
    ''');

    // 手动 NSFW 标记
    await db.execute('''
      CREATE TABLE IF NOT EXISTS nsfw_manual_flags (
        screenshot_id INTEGER NOT NULL,
        app_package_name TEXT NOT NULL,
        flag INTEGER NOT NULL DEFAULT 1,
        created_at INTEGER DEFAULT (strftime('%s','now') * 1000),
        updated_at INTEGER DEFAULT (strftime('%s','now') * 1000),
        PRIMARY KEY (screenshot_id, app_package_name)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_nsfw_manual_app ON nsfw_manual_flags(app_package_name, screenshot_id)',
    );
  }

  Future<void> _createUserSettingsTable(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS user_settings (
        key TEXT PRIMARY KEY,
        value TEXT,
        updated_at INTEGER DEFAULT (strftime('%s','now') * 1000)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_user_settings_updated_at ON user_settings(updated_at)',
    );
  }

  // ----- 域名规则 CRUD -----
  Future<List<Map<String, dynamic>>> listNsfwDomainRules() async {
    final db = await database;
    try {
      final rows = await db.query(
        'nsfw_domain_rules',
        orderBy: 'is_wildcard DESC, pattern ASC',
      );
      return rows;
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  Future<bool> addNsfwDomainRule({
    required String pattern,
    required bool isWildcard,
    String? comment,
  }) async {
    final db = await database;
    try {
      await db.insert('nsfw_domain_rules', {
        'pattern': pattern,
        'is_wildcard': isWildcard ? 1 : 0,
        'comment': comment,
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> removeNsfwDomainRule(String pattern) async {
    final db = await database;
    try {
      final count = await db.delete(
        'nsfw_domain_rules',
        where: 'pattern = ?',
        whereArgs: [pattern],
      );
      return count > 0;
    } catch (_) {
      return false;
    }
  }

  Future<int> clearNsfwDomainRules() async {
    final db = await database;
    try {
      return await db.delete('nsfw_domain_rules');
    } catch (_) {
      return 0;
    }
  }

  /// 近似统计指定主域名（可选含子域）的截图数量
  Future<int> countScreenshotsMatchingDomain({
    required String host,
    required bool includeSubdomains,
  }) async {
    final db = await database;
    try {
      int total = 0;
      final shards = await db.query(
        'shard_registry',
        columns: ['app_package_name', 'year'],
        orderBy: 'year DESC',
      );
      if (shards.isEmpty) return 0;

      final String hostLower = host.toLowerCase();
      final like1 = '%://' + hostLower + '/%';
      final like2 = '%.' + hostLower + '/%';
      final like3 = '%//' + hostLower + '%';
      final like4 = '%.' + hostLower + '%';

      for (final sh in shards) {
        final String pkg = sh['app_package_name'] as String;
        final int y = sh['year'] as int;
        final shardDb = await _openShardDb(pkg, y);
        if (shardDb == null) continue;
        for (int m = 1; m <= 12; m++) {
          final t = _monthTableName(y, m);
          if (!await _tableExists(shardDb, t)) continue;
          try {
            if (includeSubdomains) {
              final rows = await shardDb.rawQuery(
                "SELECT COUNT(*) AS c FROM $t WHERE page_url IS NOT NULL AND (LOWER(page_url) LIKE ? OR LOWER(page_url) LIKE ? OR LOWER(page_url) LIKE ? OR LOWER(page_url) LIKE ?)",
                [like1, like2, like3, like4],
              );
              total += (rows.first['c'] as int?) ?? 0;
            } else {
              final rows = await shardDb.rawQuery(
                "SELECT COUNT(*) AS c FROM $t WHERE page_url IS NOT NULL AND (LOWER(page_url) LIKE ? OR LOWER(page_url) LIKE ?)",
                [like1, like3],
              );
              total += (rows.first['c'] as int?) ?? 0;
            }
          } catch (_) {}
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  // ----- 手动 NSFW 标记 -----
  Future<bool> setManualNsfwFlag({
    required int screenshotId,
    required String appPackageName,
    required bool flag,
  }) async {
    final db = await database;
    try {
      if (flag) {
        await db.insert('nsfw_manual_flags', {
          'screenshot_id': screenshotId,
          'app_package_name': appPackageName,
          'flag': 1,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      } else {
        await db.delete(
          'nsfw_manual_flags',
          where: 'screenshot_id = ? AND app_package_name = ?',
          whereArgs: [screenshotId, appPackageName],
        );
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> isManuallyNsfw({
    required int screenshotId,
    required String appPackageName,
  }) async {
    final db = await database;
    try {
      final rows = await db.query(
        'nsfw_manual_flags',
        columns: ['flag'],
        where: 'screenshot_id = ? AND app_package_name = ?',
        whereArgs: [screenshotId, appPackageName],
        limit: 1,
      );
      if (rows.isEmpty) return false;
      return ((rows.first['flag'] as int?) ?? 0) == 1;
    } catch (_) {
      return false;
    }
  }

  Future<int> clearManualNsfwForApp(String appPackageName) async {
    final db = await database;
    try {
      return await db.delete(
        'nsfw_manual_flags',
        where: 'app_package_name = ?',
        whereArgs: [appPackageName],
      );
    } catch (_) {
      return 0;
    }
  }

  /// 批量检查手动 NSFW 标记状态
  Future<Map<int, bool>> checkManualNsfw({
    required List<int> screenshotIds,
    required String appPackageName,
  }) async {
    final db = await database;
    final Map<int, bool> result = {};
    if (screenshotIds.isEmpty) return result;
    try {
      final placeholders = List.filled(screenshotIds.length, '?').join(',');
      final rows = await db.query(
        'nsfw_manual_flags',
        columns: ['screenshot_id'],
        where:
            'screenshot_id IN ($placeholders) AND app_package_name = ? AND flag = 1',
        whereArgs: [...screenshotIds, appPackageName],
      );
      final flagged = rows.map((r) => r['screenshot_id'] as int).toSet();
      for (final id in screenshotIds) {
        result[id] = flagged.contains(id);
      }
    } catch (e) {
      for (final id in screenshotIds) {
        result[id] = false;
      }
    }
    return result;
  }

  // ======= 汇总统计表操作 =======
  Future<Map<String, dynamic>> getTotals() async {
    final db = await database;
    try {
      final rows = await db.query('totals', where: 'id = 1', limit: 1);
      if (rows.isEmpty) {
        await db.insert('totals', {
          'id': 1,
          'app_count': 0,
          'screenshot_count': 0,
          'total_size_bytes': 0,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        });
        return {
          'app_count': 0,
          'screenshot_count': 0,
          'total_size_bytes': 0,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        };
      }
      return rows.first;
    } catch (e) {
      print('获取汇总统计失败: $e');
      return {
        'app_count': 0,
        'screenshot_count': 0,
        'total_size_bytes': 0,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      };
    }
  }

  Future<void> updateTotalsOnInsert(
    List<String> packageNames,
    int screenshotCount,
    int totalSizeBytes,
  ) async {
    final db = await database;
    try {
      await db.transaction((txn) async {
        int newAppCount = 0;
        for (final packageName in packageNames) {
          final existing = await txn.query(
            'app_stats',
            columns: ['app_package_name'],
            where: 'app_package_name = ?',
            whereArgs: [packageName],
            limit: 1,
          );
          if (existing.isEmpty) {
            newAppCount++;
          }
        }
        await txn.execute(
          '''
          INSERT OR REPLACE INTO totals (id, app_count, screenshot_count, total_size_bytes, updated_at)
          VALUES (1,
            COALESCE((SELECT app_count FROM totals WHERE id = 1), 0) + ?,
            COALESCE((SELECT screenshot_count FROM totals WHERE id = 1), 0) + ?,
            COALESCE((SELECT total_size_bytes FROM totals WHERE id = 1), 0) + ?,
            ?
          )
        ''',
          [
            newAppCount,
            screenshotCount,
            totalSizeBytes,
            DateTime.now().millisecondsSinceEpoch,
          ],
        );
      });
    } catch (e) {
      print('更新汇总统计失败: $e');
    }
  }

  Future<void> recalculateTotals() async {
    final db = await database;
    try {
      await db.transaction((txn) async {
        final appStats = await txn.query('app_stats');
        final appCount = appStats.length;
        int totalScreenshots = 0;
        int totalSizeBytes = 0;
        for (final stat in appStats) {
          totalScreenshots += (stat['total_count'] as int?) ?? 0;
          totalSizeBytes += (stat['total_size'] as int?) ?? 0;
        }
        await txn.execute(
          '''
          INSERT OR REPLACE INTO totals (id, app_count, screenshot_count, total_size_bytes, updated_at)
          VALUES (1, ?, ?, ?, ?)
        ''',
          [
            appCount,
            totalScreenshots,
            totalSizeBytes,
            DateTime.now().millisecondsSinceEpoch,
          ],
        );
      });
    } catch (e) {
      print('重新计算汇总统计失败: $e');
    }
  }

  // ======= 导出/导入 =======
  Future<Map<String, dynamic>?> exportDatabaseToDownloads({
    BackupExportScope exportScope = BackupExportScope.full,
    void Function(ExportProgressSnapshot snapshot)? onDetailedProgress,
    bool Function()? shouldCancel,
  }) async {
    File? tmpZip;
    File? tmpManifest;
    Directory? tmpStageDir;
    BackupInventory? inventory;
    final Map<String, int> categoryCompletedBytes = <String, int>{
      for (final String id in BackupCategoryIds.ordered) id: 0,
    };
    try {
      final BackupRootPaths? roots =
          await BackupInventoryService.resolveDefaultRoots();
      if (roots == null) {
        throw StateError('backup_roots_unavailable');
      }
      await FlutterLogger.nativeInfo(
        'EXPORT',
        '开始构建导出清单，scope=$exportScope, filesDir=${roots.filesDirPath}',
      );
      _emitExportSnapshot(
        onDetailedProgress,
        phase: ExportPhase.scanning,
        inventory: null,
        categoryCompletedBytes: categoryCompletedBytes,
        currentCategoryId: 'output',
        currentEntry: roots.outputDirPath,
      );

      final BackupInventory fullInventory = await BackupInventoryService.scan(
        roots: roots,
        onProgress: (String scopeId, String? currentPath) {
          if (shouldCancel?.call() == true) {
            throw const BackupExportCancelledException();
          }
          _emitExportSnapshot(
            onDetailedProgress,
            phase: ExportPhase.scanning,
            inventory: null,
            categoryCompletedBytes: categoryCompletedBytes,
            currentCategoryId: scopeId,
            currentEntry: currentPath,
          );
        },
      );
      inventory = BackupInventoryService.filterInventoryByScope(
        fullInventory,
        exportScope,
      );
      await FlutterLogger.nativeInfo(
        'EXPORT',
        '导出清单完成，scope=$exportScope, categories=${inventory.categories.length}, files=${inventory.totalFiles}, bytes=${inventory.totalBytes}',
      );

      if (shouldCancel?.call() == true) {
        throw const BackupExportCancelledException();
      }
      if (inventory.isEmpty) {
        throw StateError('backup_inventory_empty');
      }

      final Directory tempDir = await getTemporaryDirectory();
      final ({BackupInventory inventory, Directory? stagingDir}) prepared =
          await _prepareInventoryForExport(
            inventory: inventory,
            tempDir: tempDir,
          );
      inventory = prepared.inventory;
      tmpStageDir = prepared.stagingDir;
      final String timestamp = DateTime.now().toIso8601String().replaceAll(
        RegExp(r'[:.]'),
        '-',
      );
      final String displayName = switch (exportScope) {
        BackupExportScope.full => 'screen_memo_backup_$timestamp.zip',
        BackupExportScope.databasesOnly =>
          'screen_memo_database_backup_$timestamp.zip',
      };
      tmpZip = File(join(tempDir.path, displayName));
      tmpManifest = File(
        join(tempDir.path, 'screen_memo_backup_manifest.json'),
      );
      if (await tmpZip.exists()) {
        await tmpZip.delete();
      }
      if (await tmpManifest.exists()) {
        await tmpManifest.delete();
      }

      await tmpManifest.writeAsString(
        BackupInventoryService.encodeManifestJson(
          inventory,
          createdAt: DateTime.now(),
          archiveFileName: displayName,
        ),
        flush: true,
      );

      _emitExportSnapshot(
        onDetailedProgress,
        phase: ExportPhase.packing,
        inventory: inventory,
        categoryCompletedBytes: categoryCompletedBytes,
        currentEntry: backupManifestFileName,
      );
      await FlutterLogger.nativeInfo(
        'EXPORT',
        '开始打包 ZIP，entries=${inventory.totalFiles}, tmpZip=${tmpZip.path}',
      );

      int completedBytes = 0;
      await _runBackupExportZipWithProgress(
        inventory: inventory,
        manifestPath: tmpManifest.path,
        tmpZipPath: tmpZip.path,
        onEntryStart:
            (
              int nextCompletedBytes,
              String categoryId,
              String currentEntry,
              int entryBytes,
            ) {
              _emitExportSnapshot(
                onDetailedProgress,
                phase: ExportPhase.packing,
                inventory: inventory,
                completedBytes: nextCompletedBytes,
                categoryCompletedBytes: categoryCompletedBytes,
                currentCategoryId: categoryId,
                currentEntry: currentEntry,
              );
            },
        shouldCancel: shouldCancel,
        onProgress:
            (
              int nextCompletedBytes,
              String categoryId,
              String currentEntry,
              int entryBytes,
            ) {
              completedBytes = nextCompletedBytes;
              categoryCompletedBytes[categoryId] =
                  (categoryCompletedBytes[categoryId] ?? 0) + entryBytes;
              _emitExportSnapshot(
                onDetailedProgress,
                phase: ExportPhase.packing,
                inventory: inventory,
                completedBytes: completedBytes,
                categoryCompletedBytes: categoryCompletedBytes,
                currentCategoryId: categoryId,
                currentEntry: currentEntry,
              );
            },
      );

      _emitExportSnapshot(
        onDetailedProgress,
        phase: ExportPhase.verifying,
        inventory: inventory,
        completedBytes: completedBytes,
        categoryCompletedBytes: categoryCompletedBytes,
        currentEntry: tmpZip.path,
      );
      await FlutterLogger.nativeInfo('EXPORT', 'ZIP 打包完成，开始校验：${tmpZip.path}');

      final BackupArchiveInspection inspection = await _inspectBackupArchive(
        tmpZip.path,
      );
      if (!inspection.hasManifest) {
        throw StateError('backup_manifest_missing');
      }
      await FlutterLogger.nativeInfo(
        'EXPORT',
        'ZIP 校验完成，roots=${inspection.rootEntries.join(',')}, requiresRestart=${inspection.manifestRequiresRestart}',
      );
      if (shouldCancel?.call() == true) {
        throw const BackupExportCancelledException();
      }

      final dynamic result = await ScreenshotDatabase._channel
          .invokeMethod('exportFileToDownloads', <String, Object?>{
            'sourcePath': tmpZip.path,
            'displayName': displayName,
            'subDir': 'ScreenMemory',
          });

      if (result is! Map) {
        throw StateError('backup_export_result_invalid');
      }
      final Map<String, dynamic> map = Map<String, dynamic>.from(result);
      if (shouldCancel?.call() == true) {
        await _deleteExportedBackupArtifact(map);
        throw const BackupExportCancelledException();
      }
      map['humanPath'] =
          (map['absolutePath'] as String?) ?? (map['displayPath'] as String?);
      map['inventoryTotalBytes'] = inventory.totalBytes;
      map['inventoryTotalFiles'] = inventory.totalFiles;
      map['requiresRestartAfterImport'] = inventory.requiresRestartAfterImport;
      map['exportScope'] = exportScope.name;
      _emitExportSnapshot(
        onDetailedProgress,
        phase: ExportPhase.completed,
        inventory: inventory,
        completedBytes: inventory.totalBytes,
        categoryCompletedBytes: categoryCompletedBytes,
        outputPath: map['humanPath']?.toString(),
      );
      await FlutterLogger.nativeInfo(
        'EXPORT',
        '全量备份导出完成 -> ' + (map['humanPath']?.toString() ?? ''),
      );
      return map;
    } on BackupExportCancelledException {
      await FlutterLogger.nativeWarn('EXPORT', '导出已取消，准备清理临时文件');
      _emitExportSnapshot(
        onDetailedProgress,
        phase: ExportPhase.cancelled,
        inventory: inventory,
        completedBytes: _sumCategoryCompletedBytes(categoryCompletedBytes),
        categoryCompletedBytes: categoryCompletedBytes,
      );
      rethrow;
    } catch (e) {
      await FlutterLogger.nativeError(
        'EXPORT',
        'exportDatabaseToDownloads 异常：$e',
      );
      _emitExportSnapshot(
        onDetailedProgress,
        phase: ExportPhase.failed,
        inventory: inventory,
        completedBytes: _sumCategoryCompletedBytes(categoryCompletedBytes),
        categoryCompletedBytes: categoryCompletedBytes,
        errorMessage: e.toString(),
      );
      rethrow;
    } finally {
      try {
        if (tmpZip != null && await tmpZip.exists()) {
          await tmpZip.delete();
        }
      } catch (_) {}
      try {
        if (tmpManifest != null && await tmpManifest.exists()) {
          await tmpManifest.delete();
        }
      } catch (_) {}
      try {
        if (tmpStageDir != null && await tmpStageDir.exists()) {
          await tmpStageDir.delete(recursive: true);
        }
      } catch (_) {}
    }
  }

  void _emitExportSnapshot(
    void Function(ExportProgressSnapshot snapshot)? listener, {
    required ExportPhase phase,
    required BackupInventory? inventory,
    required Map<String, int> categoryCompletedBytes,
    int? completedBytes,
    String? currentEntry,
    String? currentCategoryId,
    String? outputPath,
    String? errorMessage,
  }) {
    if (listener == null) {
      return;
    }
    final int totalBytes = inventory?.totalBytes ?? 0;
    final int resolvedCompletedBytes = completedBytes ?? 0;
    final double progress = totalBytes <= 0
        ? (phase == ExportPhase.completed ? 1.0 : 0.0)
        : (resolvedCompletedBytes / totalBytes).clamp(0.0, 1.0);
    listener(
      ExportProgressSnapshot(
        phase: phase,
        overallProgress: progress,
        completedBytes: resolvedCompletedBytes,
        totalBytes: totalBytes,
        categoryCompletedBytes: Map<String, int>.from(categoryCompletedBytes),
        inventory: inventory,
        currentEntry: currentEntry,
        currentCategoryId: currentCategoryId,
        outputPath: outputPath,
        errorMessage: errorMessage,
      ),
    );
  }

  int _sumCategoryCompletedBytes(Map<String, int> categoryCompletedBytes) {
    int sum = 0;
    for (final int value in categoryCompletedBytes.values) {
      sum += value;
    }
    return sum;
  }

  Future<BackupArchiveInspection> _inspectBackupArchive(String zipPath) async {
    return BackupInventoryService.inspectArchiveFile(zipPath);
  }

  Future<void> _deleteExportedBackupArtifact(
    Map<String, dynamic> exportResult,
  ) async {
    try {
      await ScreenshotDatabase._channel
          .invokeMethod('deleteExportedArtifact', <String, Object?>{
            'contentUri': exportResult['contentUri']?.toString(),
            'absolutePath': exportResult['absolutePath']?.toString(),
          });
    } catch (_) {}
  }

  Future<BackupRootPaths> _requireBackupRoots() async {
    final BackupRootPaths? roots =
        await BackupInventoryService.resolveDefaultRoots();
    if (roots == null) {
      throw StateError('backup_roots_unavailable');
    }
    return roots;
  }

  Future<Map<String, dynamic>?> importDataFromZip({
    String? zipPath,
    List<int>? zipBytes,
    bool overwrite = true,
    void Function(ImportExportProgress progress)? onProgress,
  }) async {
    if (zipPath != null && zipPath.isNotEmpty) {
      try {
        final BackupArchiveInspection inspection = await _inspectBackupArchive(
          zipPath,
        );
        if (!inspection.hasManifest) {
          await FlutterLogger.nativeInfo(
            'IMPORT',
            '尝试原生导入 importZipToOutput 路径=' + zipPath,
          );
          final bool ok = await _importDataFromZipNative(
            zipPath: zipPath,
            overwrite: overwrite,
          );
          if (ok) {
            final BackupRootPaths roots = await _requireBackupRoots();
            final Directory outputDir = Directory(roots.outputDirPath);
            try {
              await _clearOutputCacheDirs(outputDir);
            } catch (_) {}
            return <String, dynamic>{
              'extracted': null,
              'targetDir': outputDir.path,
              'restoredRoots': const <String>['output'],
              'requiresRestart': false,
            };
          }
        } else {
          await FlutterLogger.nativeInfo(
            'IMPORT',
            '检测到新备份 manifest，跳过原生 output-only 导入',
          );
        }
      } catch (_) {
        // 失败时回退到 Dart 实现
      }
    }
    return importDataFromZipStreaming(
      zipPath: zipPath,
      zipBytes: zipBytes,
      overwrite: overwrite,
      onProgress: onProgress,
    );
  }

  Future<Map<String, dynamic>?> importDataFromZipStreaming({
    String? zipPath,
    List<int>? zipBytes,
    bool overwrite = true,
    void Function(ImportExportProgress progress)? onProgress,
  }) async {
    try {
      await FlutterLogger.nativeInfo('IMPORT', '开始(流式+Isolate)');
      await FlutterLogger.nativeDebug(
        'IMPORT',
        'args path=' +
            (zipPath ?? '') +
            ' bytes=' +
            ((zipBytes?.length ?? 0).toString()),
      );
      if ((zipPath == null || zipPath.isEmpty) &&
          (zipBytes == null || zipBytes.isEmpty)) {
        await FlutterLogger.nativeWarn('IMPORT', '无输入数据');
        return null;
      }

      String localZipPath;
      File? tmpZipFile;
      if (zipPath != null && zipPath.isNotEmpty) {
        localZipPath = zipPath;
      } else {
        final tmpDir = await getTemporaryDirectory();
        tmpZipFile = File(join(tmpDir.path, 'screenmemo_import_tmp.zip'));
        try {
          if (await tmpZipFile.exists()) await tmpZipFile.delete();
        } catch (_) {}
        await tmpZipFile.writeAsBytes(zipBytes!, flush: true);
        localZipPath = tmpZipFile.path;
      }

      final BackupRootPaths roots = await _requireBackupRoots();
      final BackupArchiveInspection inspection = await _inspectBackupArchive(
        localZipPath,
      );
      final Set<String> importRoots = inspection.rootEntries.isEmpty
          ? <String>{'output'}
          : inspection.rootEntries;

      await FlutterLogger.nativeInfo(
        'IMPORT',
        '基础目录=' +
            roots.filesDirPath +
            ' roots=' +
            importRoots.join(',') +
            ' manifest=' +
            inspection.hasManifest.toString(),
      );

      try {
        await _resetDatabasesAfterImport();
      } catch (_) {}
      await _prepareImportTargets(
        roots: roots,
        importRoots: importRoots,
        overwrite: overwrite,
      );

      final Map<String, dynamic>? res = await _runImportZipWithProgress(
        localZipPath: localZipPath,
        targetRoots: roots.toImportTargetMap(),
        overwrite: overwrite,
        onProgress: onProgress,
      );

      try {
        if (tmpZipFile != null) await tmpZipFile.delete();
        // 如果是从 FilePicker 之类复制到临时目录的缓存 ZIP（zipPath 在临时目录下），导入后也一并删除
        if (tmpZipFile == null && zipPath != null && zipPath.isNotEmpty) {
          try {
            final Directory tmpDir = await getTemporaryDirectory();
            final String tmpRoot = tmpDir.path;
            if (zipPath.startsWith(tmpRoot)) {
              final File cachedZip = File(zipPath);
              if (await cachedZip.exists()) {
                await cachedZip.delete();
                await FlutterLogger.nativeInfo(
                  'IMPORT',
                  'deleted cached import zip: ' + zipPath,
                );
              }
            }
          } catch (_) {}
        }
      } catch (_) {}
      try {
        await _resetDatabasesAfterImport();
      } catch (_) {}

      final Directory outputDir = Directory(roots.outputDirPath);
      await FlutterLogger.nativeInfo(
        'IMPORT',
        '完成(流式+Isolate) 解压=' +
            ((res?['extracted'] as int?) ?? 0).toString() +
            ' 目标=' +
            (inspection.manifestRequiresRestart
                ? roots.dataRootPath
                : outputDir.path),
      );
      try {
        await _clearOutputCacheDirs(outputDir);
      } catch (_) {}
      if (res != null) {
        final List<String> restoredRoots = List<String>.from(
          (res['restoredRoots'] as List?) ?? const <String>[],
        );
        res['targetDir'] = restoredRoots.any((String root) => root != 'output')
            ? roots.dataRootPath
            : outputDir.path;
      }
      return res;
    } catch (e) {
      await FlutterLogger.nativeError('IMPORT', '异常(流式): ' + e.toString());
      return null;
    }
  }

  Future<void> _prepareImportTargets({
    required BackupRootPaths roots,
    required Set<String> importRoots,
    required bool overwrite,
  }) async {
    final Map<String, String> targetRoots = roots.toImportTargetMap();
    final Directory outputDir = Directory(roots.outputDirPath);

    if (!overwrite) {
      try {
        if (await outputDir.exists()) {
          await _clearOutputCacheDirs(outputDir);
        }
      } catch (_) {}
      return;
    }

    for (final String root in importRoots) {
      final String? path = targetRoots[root];
      if (path == null || path.isEmpty) {
        continue;
      }
      if (_isUnsafeImportDeleteTarget(roots, path)) {
        await FlutterLogger.nativeWarn(
          'IMPORT',
          '跳过危险导入删除目标：root=$root path=$path',
        );
        continue;
      }
      await _deleteDirectoryIfExists(path);
    }
  }

  bool _isUnsafeImportDeleteTarget(BackupRootPaths roots, String path) {
    final String target = _normalizeImportDeleteGuardPath(path);
    if (target.isEmpty) {
      return true;
    }
    final Set<String> protectedRoots = <String>{
      _normalizeImportDeleteGuardPath(roots.dataRootPath),
      _normalizeImportDeleteGuardPath(roots.filesDirPath),
    };
    return protectedRoots.contains(target);
  }

  String _normalizeImportDeleteGuardPath(String path) {
    String value = normalize(path).replaceAll('\\', '/').trim();
    while (value.length > 1 && value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }

  Future<void> _deleteDirectoryIfExists(String path) async {
    final Directory dir = Directory(path);
    if (!await dir.exists()) {
      return;
    }
    try {
      await dir.delete(recursive: true);
      await FlutterLogger.nativeInfo('IMPORT', '覆盖导入前已删除目录：' + path);
    } catch (e) {
      await FlutterLogger.nativeWarn('IMPORT', '删除导入目标目录失败：$path -> $e');
    }
  }

  /// 原生导入 ZIP：通过 MethodChannel 调用 MainActivity.importZipToOutput
  Future<bool> _importDataFromZipNative({
    required String zipPath,
    required bool overwrite,
  }) async {
    const MethodChannel channel = MethodChannel(
      'com.fqyw.screen_memo/accessibility',
    );
    try {
      final bool? ok = await channel.invokeMethod<bool>(
        'importZipToOutput',
        <String, dynamic>{'zipPath': zipPath, 'overwrite': overwrite},
      );
      // 导入后重置数据库连接池，以便后续按新文件重新打开
      try {
        await _resetDatabasesAfterImport();
      } catch (_) {}
      return ok ?? false;
    } catch (e) {
      await FlutterLogger.nativeError(
        'IMPORT',
        '原生 importZipToOutput 失败：' + e.toString(),
      );
      return false;
    }
  }

  // 已移除文件夹导入 Dart 封装（保留原生实现供未来扩展）

  Future<Directory?> _getInternalFilesDir() async {
    try {
      final dir = await getApplicationSupportDirectory();
      return dir;
    } catch (e) {
      try {
        final dir = await getApplicationDocumentsDirectory();
        return dir;
      } catch (_) {
        return null;
      }
    }
  }

  Future<void> _resetDatabasesAfterImport() async {
    try {
      if (ScreenshotDatabase._shardDbCache.isNotEmpty) {
        for (final db in ScreenshotDatabase._shardDbCache.values) {
          try {
            await db.close();
          } catch (_) {}
        }
        ScreenshotDatabase._shardDbCache.clear();
      }
      if (ScreenshotDatabase._database != null) {
        try {
          await ScreenshotDatabase._database!.close();
        } catch (_) {}
        ScreenshotDatabase._database = null;
      }
    } catch (_) {}
  }

  /// 清理 output 目录下的缓存子目录，避免导入后旧缓存占用空间
  Future<void> _clearOutputCacheDirs(Directory outputDir) async {
    try {
      final List<FileSystemEntity> entries = await outputDir
          .list(followLinks: false)
          .where((FileSystemEntity entity) => entity is Directory)
          .toList();
      for (final FileSystemEntity entity in entries) {
        final String name = basename(entity.path);
        final String lower = name.toLowerCase();
        final bool shouldDelete =
            _outputCacheDirNames.contains(lower) ||
            lower.startsWith('cache') ||
            lower.startsWith('tmp') ||
            lower.startsWith('temp') ||
            lower.contains('thumbnail');
        if (!shouldDelete) continue;
        try {
          await entity.delete(recursive: true);
          await FlutterLogger.nativeInfo('IMPORT', '已清理缓存目录：' + entity.path);
        } catch (e) {
          await FlutterLogger.nativeWarn(
            'IMPORT',
            '清理缓存目录失败：' + entity.path + ' 错误=' + e.toString(),
          );
        }
      }
    } catch (e) {
      try {
        await FlutterLogger.nativeWarn('IMPORT', '列举缓存目录失败：' + e.toString());
      } catch (_) {}
    }
  }
}
