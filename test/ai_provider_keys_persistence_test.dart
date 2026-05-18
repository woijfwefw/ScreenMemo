import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_memo/data/database/screenshot_database.dart';
import 'package:screen_memo/features/ai/application/ai_providers_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDown(() async {
    try {
      await ScreenshotDatabase.instance.disposeDesktop();
    } catch (_) {}
  });

  test('读取提供商 Key 时会从旧 api_key 字段自动恢复 Key 列表', () async {
    final Directory tmp = await Directory.systemTemp.createTemp(
      'screen_memo_ai_provider_keys_',
    );
    try {
      await ScreenshotDatabase.instance.initializeForDesktop(tmp.path);

      final int? providerId = await AIProvidersService.instance.createProvider(
        name: 'Legacy provider',
        type: AIProviderTypes.openai,
        baseUrl: 'https://api.openai.com',
        models: const <String>['gpt-test'],
      );
      expect(providerId, isNotNull);

      final db = await ScreenshotDatabase.instance.database;
      await db.update(
        'ai_providers',
        <String, Object?>{
          'api_key': 'sk-legacy',
          'models_json': '["gpt-test"]',
        },
        where: 'id = ?',
        whereArgs: <Object?>[providerId],
      );
      await db.delete(
        'ai_provider_keys',
        where: 'provider_id = ?',
        whereArgs: <Object?>[providerId],
      );

      final keys = await AIProvidersService.instance.listProviderKeys(
        providerId!,
      );

      expect(keys, hasLength(1));
      expect(keys.single.apiKey, 'sk-legacy');
      expect(keys.single.models, contains('gpt-test'));

      final provider = await AIProvidersService.instance.getProvider(
        providerId,
      );
      expect(provider?.keySummary.totalCount, 1);
    } finally {
      await ScreenshotDatabase.instance.disposeDesktop();
      if (await tmp.exists()) {
        await tmp.delete(recursive: true);
      }
    }
  });

  test('新增 Key 后会同步旧 api_key 字段作为恢复来源', () async {
    final Directory tmp = await Directory.systemTemp.createTemp(
      'screen_memo_ai_provider_key_sync_',
    );
    try {
      await ScreenshotDatabase.instance.initializeForDesktop(tmp.path);

      final int? providerId = await AIProvidersService.instance.createProvider(
        name: 'New provider',
        type: AIProviderTypes.openai,
        baseUrl: 'https://api.openai.com',
        models: const <String>['gpt-new'],
      );
      expect(providerId, isNotNull);

      await AIProvidersService.instance.createProviderKey(
        providerId: providerId!,
        name: 'first',
        apiKey: 'sk-new',
        models: const <String>['gpt-new'],
      );

      final db = await ScreenshotDatabase.instance.database;
      final providerRows = await db.query(
        'ai_providers',
        columns: <String>['api_key'],
        where: 'id = ?',
        whereArgs: <Object?>[providerId],
        limit: 1,
      );
      expect(providerRows.single['api_key'], 'sk-new');

      await db.delete(
        'ai_provider_keys',
        where: 'provider_id = ?',
        whereArgs: <Object?>[providerId],
      );

      await ScreenshotDatabase.instance.disposeDesktop();
      await ScreenshotDatabase.instance.initializeForDesktop(tmp.path);

      final keys = await AIProvidersService.instance.listProviderKeys(
        providerId,
      );
      expect(keys, hasLength(1));
      expect(keys.single.apiKey, 'sk-new');
    } finally {
      await ScreenshotDatabase.instance.disposeDesktop();
      if (await tmp.exists()) {
        await tmp.delete(recursive: true);
      }
    }
  });

  test('旧版 Key 表缺少运行列时仍能新增并持久化 Key', () async {
    final Directory tmp = await Directory.systemTemp.createTemp(
      'screen_memo_ai_provider_keys_old_schema_',
    );
    try {
      await ScreenshotDatabase.instance.initializeForDesktop(tmp.path);

      final int? providerId = await AIProvidersService.instance.createProvider(
        name: 'Old key schema provider',
        type: AIProviderTypes.openai,
        baseUrl: 'https://api.openai.com',
        models: const <String>['gpt-old-schema'],
      );
      expect(providerId, isNotNull);

      final db = await ScreenshotDatabase.instance.database;
      await db.execute('DROP TABLE ai_provider_keys');
      await db.execute('''
        CREATE TABLE ai_provider_keys (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          provider_id INTEGER NOT NULL,
          name TEXT NOT NULL,
          api_key TEXT NOT NULL,
          models_json TEXT
        )
      ''');

      final int? keyId = await AIProvidersService.instance.createProviderKey(
        providerId: providerId!,
        name: 'first',
        apiKey: 'sk-old-schema',
        models: const <String>['gpt-old-schema'],
      );
      expect(keyId, isNotNull);

      await ScreenshotDatabase.instance.disposeDesktop();
      await ScreenshotDatabase.instance.initializeForDesktop(tmp.path);

      final keys = await AIProvidersService.instance.listProviderKeys(
        providerId,
      );
      expect(keys, hasLength(1));
      expect(keys.single.apiKey, 'sk-old-schema');
      expect(keys.single.models, contains('gpt-old-schema'));
    } finally {
      await ScreenshotDatabase.instance.disposeDesktop();
      if (await tmp.exists()) {
        await tmp.delete(recursive: true);
      }
    }
  });

  test('删除最后一个 Key 后不会被旧 api_key 字段恢复', () async {
    final Directory tmp = await Directory.systemTemp.createTemp(
      'screen_memo_ai_provider_key_delete_',
    );
    try {
      await ScreenshotDatabase.instance.initializeForDesktop(tmp.path);

      final int? providerId = await AIProvidersService.instance.createProvider(
        name: 'Delete provider key',
        type: AIProviderTypes.openai,
        baseUrl: 'https://api.openai.com',
        models: const <String>['gpt-delete'],
      );
      expect(providerId, isNotNull);

      final int? keyId = await AIProvidersService.instance.createProviderKey(
        providerId: providerId!,
        name: 'first',
        apiKey: 'sk-delete',
        models: const <String>['gpt-delete'],
      );
      expect(keyId, isNotNull);

      await AIProvidersService.instance.deleteProviderKey(keyId!);
      await ScreenshotDatabase.instance.disposeDesktop();
      await ScreenshotDatabase.instance.initializeForDesktop(tmp.path);

      final keys = await AIProvidersService.instance.listProviderKeys(
        providerId,
      );
      expect(keys, isEmpty);
      expect(
        await ScreenshotDatabase.instance.getAIProviderApiKey(providerId),
        isNull,
      );
    } finally {
      await ScreenshotDatabase.instance.disposeDesktop();
      if (await tmp.exists()) {
        await tmp.delete(recursive: true);
      }
    }
  });
}
