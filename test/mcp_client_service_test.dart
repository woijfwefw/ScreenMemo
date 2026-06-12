import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:screen_memo/data/database/screenshot_database.dart';
import 'package:screen_memo/features/mcp/application/mcp_client_service.dart';
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

  group('McpClientService', () {
    Future<T> withTempDatabase<T>(Future<T> Function() body) async {
      final Directory tmp = await Directory.systemTemp.createTemp(
        'screen_memo_mcp_client_',
      );
      try {
        await ScreenshotDatabase.instance.initializeForDesktop(tmp.path);
        return await body();
      } finally {
        await ScreenshotDatabase.instance.disposeDesktop();
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      }
    }

    Future<McpClientTool> createEnabledMcpTool({
      String url = 'https://example.com/mcp',
    }) async {
      final server = await McpClientService.instance.upsertServer(
        McpClientServer(
          id: '',
          name: 'Demo',
          transport: 'streamable_http',
          url: url,
          headers: const <String, String>{},
          enabled: true,
          createdAt: 0,
          updatedAt: 0,
        ),
      );
      final String dynamicName = McpClientService.dynamicToolName(
        server.id,
        server.name,
        'search',
      );
      final int now = DateTime.now().millisecondsSinceEpoch;
      await ScreenshotDatabase.instance.replaceMcpClientToolsForServer(
        serverId: server.id,
        syncedAt: now,
        tools: <Map<String, Object?>>[
          <String, Object?>{
            'id': '${server.id}:search',
            'name': 'search',
            'dynamic_name': dynamicName,
            'description': 'Search remote data',
            'input_schema_json':
                '{"type":"object","properties":{"q":{"type":"string"}}}',
          },
        ],
      );
      await ScreenshotDatabase.instance.updateMcpClientToolOptions(
        dynamicName: dynamicName,
        enabled: true,
      );
      final row = await ScreenshotDatabase.instance
          .getMcpClientToolByDynamicNameRaw(dynamicName);
      return McpClientTool.fromRaw(row!);
    }

    test('parses Claude/RikkaHub style mcpServers config', () {
      final items = McpClientService.instance.parseImportConfig(
        jsonEncode(<String, dynamic>{
          'mcpServers': <String, dynamic>{
            'demo': <String, dynamic>{
              'type': 'streamable_http',
              'url': 'https://example.com/mcp',
              'headers': <String, String>{
                'Authorization': 'Bearer secret-token',
              },
            },
          },
        }),
      );

      expect(items, hasLength(1));
      expect(items.single.name, 'demo');
      expect(items.single.transport, 'streamable_http');
      expect(items.single.url, 'https://example.com/mcp');
      expect(items.single.headers['Authorization'], 'Bearer secret-token');
      expect(
        items.single.toRedactedJson()['headers']['Authorization'],
        'Bearer ***',
      );
    });

    test('parses SSE mcpServers config without downgrading transport', () {
      final items = McpClientService.instance.parseImportConfig(
        jsonEncode(<String, dynamic>{
          'mcpServers': <String, dynamic>{
            'legacy': <String, dynamic>{
              'type': 'sse',
              'url': 'https://example.com/sse',
            },
          },
        }),
      );

      expect(items, hasLength(1));
      expect(items.single.name, 'legacy');
      expect(items.single.transport, 'sse');
      expect(items.single.url, 'https://example.com/sse');
    });

    test(
      'rejects unsupported MCP transports instead of downgrading to HTTP',
      () {
        expect(
          () => McpClientService.instance.parseImportConfig(
            jsonEncode(<String, dynamic>{
              'mcpServers': <String, dynamic>{
                'local': <String, dynamic>{
                  'type': 'stdio',
                  'url': 'stdio://local',
                },
              },
            }),
          ),
          throwsA(isA<ArgumentError>()),
        );
      },
    );

    test('dynamic tool names are namespaced and bounded', () {
      final name = McpClientService.dynamicToolName(
        'server-id',
        'Demo Server',
        'search.things/with spaces',
      );

      expect(name, startsWith('mcp__demo_server__'));
      expect(name.length, lessThanOrEqualTo(64));
      expect(RegExp(r'^[a-z0-9_]+$').hasMatch(name), isTrue);
      expect(name, endsWith('__b11858bb'));
    });

    test('management tools are always available for chat bootstrap', () {
      final names = McpClientService.managementToolSchemas()
          .map((tool) => ((tool['function'] as Map)['name']).toString())
          .toSet();

      expect(names, contains('list_mcp_servers'));
      expect(names, contains('preview_mcp_config_import'));
      expect(names, contains('configure_mcp_server'));
      expect(names, contains('sync_mcp_server'));
      expect(names, contains('set_mcp_tool_options'));
    });

    test(
      'database preserves tool enable settings on resync',
      () async {
        await withTempDatabase(() async {
          final server = await McpClientService.instance.upsertServer(
            const McpClientServer(
              id: '',
              name: 'Demo',
              transport: 'streamable_http',
              url: 'https://example.com/mcp',
              headers: <String, String>{},
              enabled: true,
              createdAt: 0,
              updatedAt: 0,
            ),
          );

          final int firstSync = DateTime.now().millisecondsSinceEpoch;
          await ScreenshotDatabase.instance.replaceMcpClientToolsForServer(
            serverId: server.id,
            syncedAt: firstSync,
            tools: <Map<String, Object?>>[
              <String, Object?>{
                'id': '${server.id}:search',
                'name': 'search',
                'dynamic_name': McpClientService.dynamicToolName(
                  server.id,
                  server.name,
                  'search',
                ),
                'description': 'old description',
                'input_schema_json': '{"type":"object","properties":{}}',
              },
            ],
          );
          final String dynamicName = McpClientService.dynamicToolName(
            server.id,
            server.name,
            'search',
          );
          await ScreenshotDatabase.instance.updateMcpClientToolOptions(
            dynamicName: dynamicName,
            enabled: true,
          );

          await ScreenshotDatabase.instance.replaceMcpClientToolsForServer(
            serverId: server.id,
            syncedAt: firstSync + 1,
            tools: <Map<String, Object?>>[
              <String, Object?>{
                'id': '${server.id}:search',
                'name': 'search',
                'dynamic_name': dynamicName,
                'description': 'new description',
                'input_schema_json':
                    '{"type":"object","properties":{"q":{"type":"string"}}}',
              },
            ],
          );

          final tools = (await ScreenshotDatabase.instance
              .listMcpClientToolsRaw(serverId: server.id));
          expect(tools, hasLength(1));
          expect(tools.single['enabled'], 1);
          expect(tools.single['description'], 'new description');
        });
      },
    );

    test('AI management writes apply MCP config directly', () async {
      await withTempDatabase(() async {
        final payload = await McpClientService.instance.executeManagementTool(
          'configure_mcp_server',
          <String, dynamic>{
            'action': 'upsert',
            'name': 'Demo',
            'transport': 'streamable_http',
            'url': 'https://example.com/mcp',
            'headers': <String, String>{
              'Authorization': 'Bearer secret-token',
            },
          },
        );

        expect(payload['ok'], isTrue);
        expect(payload['requires_confirmation'], isNull);
        final row = await ScreenshotDatabase.instance
            .getMcpClientServerByNameRaw('Demo');
        expect(row, isNotNull);
        expect(row!['url'], 'https://example.com/mcp');
        expect(jsonEncode(payload), isNot(contains('secret-token')));
        expect(jsonEncode(payload), contains('Bearer ***'));
      });
    });

    test('AI initiated sync runs directly without local approval', () async {
      await withTempDatabase(() async {
        final client = _FakeLegacySseMcpClient();
        McpClientService.instance.setHttpClientForTesting(client);
        try {
          final server = await McpClientService.instance.upsertServer(
            const McpClientServer(
              id: '',
              name: 'Demo',
              transport: 'sse',
              url: 'https://example.com/sse',
              headers: <String, String>{},
              enabled: true,
              createdAt: 0,
              updatedAt: 0,
            ),
          );

          final payload = await McpClientService.instance.executeManagementTool(
            'sync_mcp_server',
            <String, dynamic>{'id': server.id},
          );

          expect(payload['ok'], isTrue);
          expect(payload['requires_confirmation'], isNull);
          expect(payload['approval_id'], isNull);
          expect(payload['count'], 1);
          expect(
            await ScreenshotDatabase.instance.listMcpClientToolsRaw(
              serverId: server.id,
            ),
            hasLength(1),
          );
        } finally {
          McpClientService.instance.setHttpClientForTesting(null);
        }
      });
    });

    test('import_json applies directly and redacts returned secrets', () async {
      await withTempDatabase(() async {
        final rawConfig = jsonEncode(<String, dynamic>{
          'mcpServers': <String, dynamic>{
            'demo': <String, dynamic>{
              'type': 'streamable_http',
              'url': 'https://example.com/mcp',
              'headers': <String, String>{
                'Authorization': 'Bearer secret-token',
              },
            },
          },
        });

        final payload = await McpClientService.instance.executeManagementTool(
          'configure_mcp_server',
          <String, dynamic>{
            'action': 'import_json',
            'confirm': true,
            'config_json': rawConfig,
          },
        );

        expect(payload['ok'], isTrue);
        final encodedPayload = jsonEncode(payload);
        expect(encodedPayload, isNot(contains('secret-token')));
        expect(encodedPayload, contains('Bearer ***'));
        final row = await ScreenshotDatabase.instance
            .getMcpClientServerByNameRaw('demo');
        expect(row, isNotNull);
      });
    });

    test('import_json can replace a single existing server by id', () async {
      await withTempDatabase(() async {
        final original = await McpClientService.instance.upsertServer(
          const McpClientServer(
            id: '',
            name: 'Old',
            transport: 'streamable_http',
            url: 'https://old.example.com/mcp',
            headers: <String, String>{},
            enabled: true,
            createdAt: 0,
            updatedAt: 0,
          ),
        );

        final rawConfig = jsonEncode(<String, dynamic>{
          'mcpServers': <String, dynamic>{
            'New': <String, dynamic>{
              'type': 'sse',
              'url': 'https://new.example.com/sse',
              'headers': <String, String>{
                'Authorization': 'Bearer replacement',
              },
            },
          },
        });

        final payload = await McpClientService.instance.executeManagementTool(
          'configure_mcp_server',
          <String, dynamic>{
            'action': 'import_json',
            'confirm': true,
            'config_json': rawConfig,
            'replace_server_id': original.id,
          },
        );

        expect(payload['ok'], isTrue);
        final servers = await McpClientService.instance.listServers(
          includeTools: false,
        );
        expect(servers, hasLength(1));
        expect(servers.single.id, original.id);
        expect(servers.single.name, 'New');
        expect(servers.single.transport, 'sse');
        expect(servers.single.url, 'https://new.example.com/sse');
        expect(
          servers.single.headers['Authorization'],
          'Bearer replacement',
        );
      });
    });

    test('repeated management writes update the same server directly', () async {
      await withTempDatabase(() async {
        final args = <String, dynamic>{
          'action': 'upsert',
          'name': 'Dedup',
          'transport': 'streamable_http',
          'url': 'https://example.com/mcp',
        };

        final first = await McpClientService.instance.executeManagementTool(
          'configure_mcp_server',
          args,
        );
        final second = await McpClientService.instance.executeManagementTool(
          'configure_mcp_server',
          args,
        );

        expect(first['ok'], isTrue);
        expect(second['ok'], isTrue);
        final servers = await McpClientService.instance.listServers(
          includeTools: false,
        );
        expect(servers, hasLength(1));
      });
    });

    test('repeated identical server id save does not insert duplicate', () async {
      await withTempDatabase(() async {
        const server = McpClientServer(
          id: 'WeChatDataAnalysis',
          name: 'WeChatDataAnalysis',
          transport: 'streamable_http',
          url: 'http://169.254.80.23:10392/mcp',
          headers: <String, String>{'Authorization': 'Bearer token'},
          enabled: true,
          createdAt: 0,
          updatedAt: 0,
        );

        await McpClientService.instance.upsertServer(server);
        await McpClientService.instance.upsertServer(server);

        final servers = await McpClientService.instance.listServers(
          includeTools: false,
        );
        expect(servers, hasLength(1));
        expect(servers.single.id, 'WeChatDataAnalysis');
      });
    });

    test('set_mcp_tool_options rejects unknown dynamic tool names', () async {
      await withTempDatabase(() async {
        final payload = await McpClientService.instance.executeManagementTool(
          'set_mcp_tool_options',
          <String, dynamic>{
            'dynamic_name': 'mcp__missing__tool__12345678',
            'enabled': true,
          },
        );

        expect(payload['ok'], isFalse);
        expect(payload['error'], 'mcp_tool_not_found');
      });
    });

    test(
      'enabled external MCP tool calls run directly without local approval',
      () async {
        final List<Map<String, dynamic>> calls = <Map<String, dynamic>>[];
        final client = MockClient((http.Request request) async {
          final Map<String, dynamic> rpc = jsonDecode(request.body);
          calls.add(rpc);
          final String method = (rpc['method'] ?? '').toString();
          if (method == 'initialize') {
            return http.Response(
              jsonEncode(<String, dynamic>{
                'jsonrpc': '2.0',
                'id': rpc['id'],
                'result': <String, dynamic>{
                  'protocolVersion': '2025-06-18',
                  'capabilities': <String, dynamic>{},
                  'serverInfo': <String, dynamic>{'name': 'stub'},
                },
              }),
              200,
              headers: <String, String>{'mcp-session-id': 'session-test'},
            );
          }
          if (method == 'notifications/initialized') {
            expect(request.headers['mcp-session-id'], 'session-test');
            return http.Response('', 200);
          }
          if (method == 'tools/call') {
            expect(request.headers['mcp-session-id'], 'session-test');
            return http.Response(
              jsonEncode(<String, dynamic>{
                'jsonrpc': '2.0',
                'id': rpc['id'],
                'result': <String, dynamic>{
                  'content': <Map<String, String>>[
                    <String, String>{'type': 'text', 'text': 'remote result'},
                  ],
                },
              }),
              200,
            );
          }
          return http.Response('unknown method', 400);
        });

        try {
          McpClientService.instance.setHttpClientForTesting(client);
          await withTempDatabase(() async {
            final tool = await createEnabledMcpTool(
              url: 'https://example.com/mcp',
            );

            final matching = await McpClientService.instance.callExternalTool(
              tool.dynamicName,
              <String, dynamic>{'q': 'needle'},
            );

            expect(matching['ok'], isTrue);
            expect(matching['result']['content'][0]['text'], 'remote result');
            expect(calls.map((call) => call['method']), <String>[
              'initialize',
              'notifications/initialized',
              'tools/call',
            ]);
          });
        } finally {
          McpClientService.instance.setHttpClientForTesting(null);
          client.close();
        }
      },
    );

    test('streamable HTTP transport accepts event-stream responses', () async {
      final client = _FakeStreamableHttpSseClient();
      try {
        McpClientService.instance.setHttpClientForTesting(client);
        await withTempDatabase(() async {
          final server = await McpClientService.instance.upsertServer(
            const McpClientServer(
              id: '',
              name: 'Streamable SSE',
              transport: 'streamable_http',
              url: 'https://example.com/mcp',
              headers: <String, String>{},
              enabled: true,
              createdAt: 0,
              updatedAt: 0,
            ),
          );

          final payload = await McpClientService.instance.syncServer(server.id);

          expect(payload['ok'], isTrue);
          expect(payload['count'], 1);
          expect(client.postedMethods, <String>[
            'initialize',
            'notifications/initialized',
            'tools/list',
          ]);
        });
      } finally {
        McpClientService.instance.setHttpClientForTesting(null);
        client.close();
      }
    });

    test(
      'streamable HTTP event-stream ignores unrelated JSON-RPC messages',
      () async {
        final client = _FakeStreamableHttpSseClient(
          includeUnrelatedMessages: true,
        );
        try {
          McpClientService.instance.setHttpClientForTesting(client);
          await withTempDatabase(() async {
            final server = await McpClientService.instance.upsertServer(
              const McpClientServer(
                id: '',
                name: 'Streamable SSE',
                transport: 'streamable_http',
                url: 'https://example.com/mcp',
                headers: <String, String>{},
                enabled: true,
                createdAt: 0,
                updatedAt: 0,
              ),
            );

            final payload = await McpClientService.instance.syncServer(
              server.id,
            );

            expect(payload['ok'], isTrue);
            expect(payload['count'], 1);
          });
        } finally {
          McpClientService.instance.setHttpClientForTesting(null);
          client.close();
        }
      },
    );

    test('external MCP tool schema preserves top-level constraints', () async {
      await withTempDatabase(() async {
        final server = await McpClientService.instance.upsertServer(
          const McpClientServer(
            id: '',
            name: 'Schema Server',
            transport: 'streamable_http',
            url: 'https://example.com/mcp',
            headers: <String, String>{},
            enabled: true,
            createdAt: 0,
            updatedAt: 0,
          ),
        );
        final String dynamicName = McpClientService.dynamicToolName(
          server.id,
          server.name,
          'strict_lookup',
        );
        await ScreenshotDatabase.instance.replaceMcpClientToolsForServer(
          serverId: server.id,
          syncedAt: DateTime.now().millisecondsSinceEpoch,
          tools: <Map<String, Object?>>[
            <String, Object?>{
              'id': '${server.id}:strict_lookup',
              'name': 'strict_lookup',
              'dynamic_name': dynamicName,
              'description': 'Strict lookup',
              'input_schema_json': jsonEncode(<String, dynamic>{
                'type': 'object',
                'properties': <String, dynamic>{
                  'mode': <String, dynamic>{
                    'oneOf': <Map<String, dynamic>>[
                      <String, dynamic>{'const': 'fast'},
                      <String, dynamic>{'const': 'deep'},
                    ],
                  },
                },
                'required': <String>['mode'],
                'additionalProperties': false,
              }),
            },
          ],
        );
        await ScreenshotDatabase.instance.updateMcpClientToolOptions(
          dynamicName: dynamicName,
          enabled: true,
        );

        final schemas = await McpClientService.instance
            .buildEnabledToolSchemas();
        final schema = schemas.single['function'] as Map<String, dynamic>;
        final parameters = schema['parameters'] as Map<String, dynamic>;
        final properties = parameters['properties'] as Map<String, dynamic>;

        expect(parameters['additionalProperties'], isFalse);
        expect(parameters['required'], contains('mode'));
        expect(properties['mode'], contains('oneOf'));
        expect(properties, isNot(contains('approval_id')));
      });
    });

    test('syncServer supports legacy SSE MCP transport', () async {
      final client = _FakeLegacySseMcpClient();
      try {
        McpClientService.instance.setHttpClientForTesting(client);
        await withTempDatabase(() async {
          final server = await McpClientService.instance.upsertServer(
            const McpClientServer(
              id: '',
              name: 'Legacy SSE',
              transport: 'sse',
              url: 'https://example.com/sse',
              headers: <String, String>{},
              enabled: true,
              createdAt: 0,
              updatedAt: 0,
            ),
          );

          final payload = await McpClientService.instance.syncServer(server.id);

          expect(payload['ok'], isTrue);
          expect(payload['count'], 1);
          expect(client.getCount, 1);
          expect(client.postedMethods, <String>[
            'initialize',
            'notifications/initialized',
            'tools/list',
          ]);

          final tools = await ScreenshotDatabase.instance.listMcpClientToolsRaw(
            serverId: server.id,
          );
          expect(tools, hasLength(1));
          expect(tools.single['name'], 'lookup');
        });
      } finally {
        McpClientService.instance.setHttpClientForTesting(null);
        client.close();
      }
    });

    test('legacy SSE endpoint preserves query string', () async {
      final client = _FakeLegacySseMcpClient(endpoint: '/messages?sid=abc');
      try {
        McpClientService.instance.setHttpClientForTesting(client);
        await withTempDatabase(() async {
          final server = await McpClientService.instance.upsertServer(
            const McpClientServer(
              id: '',
              name: 'Legacy SSE',
              transport: 'sse',
              url: 'https://example.com/sse',
              headers: <String, String>{},
              enabled: true,
              createdAt: 0,
              updatedAt: 0,
            ),
          );

          final payload = await McpClientService.instance.syncServer(server.id);

          expect(payload['ok'], isTrue);
          expect(client.postUris, isNotEmpty);
          expect(
            client.postUris.first.toString(),
            'https://example.com/messages?sid=abc',
          );
        });
      } finally {
        McpClientService.instance.setHttpClientForTesting(null);
        client.close();
      }
    });

    test('external tool calls support legacy SSE MCP transport', () async {
      final client = _FakeLegacySseMcpClient();
      try {
        McpClientService.instance.setHttpClientForTesting(client);
        await withTempDatabase(() async {
          final server = await McpClientService.instance.upsertServer(
            const McpClientServer(
              id: '',
              name: 'Legacy SSE',
              transport: 'sse',
              url: 'https://example.com/sse',
              headers: <String, String>{},
              enabled: true,
              createdAt: 0,
              updatedAt: 0,
            ),
          );
          final String dynamicName = McpClientService.dynamicToolName(
            server.id,
            server.name,
            'lookup',
          );
          await ScreenshotDatabase.instance.replaceMcpClientToolsForServer(
            serverId: server.id,
            syncedAt: DateTime.now().millisecondsSinceEpoch,
            tools: <Map<String, Object?>>[
              <String, Object?>{
                'id': '${server.id}:lookup',
                'name': 'lookup',
                'dynamic_name': dynamicName,
                'description': 'Lookup',
                'input_schema_json':
                    '{"type":"object","properties":{"q":{"type":"string"}}}',
              },
            ],
          );
          await ScreenshotDatabase.instance.updateMcpClientToolOptions(
            dynamicName: dynamicName,
            enabled: true,
          );

          final payload = await McpClientService.instance.callExternalTool(
            dynamicName,
            <String, dynamic>{'q': 'screenmemo'},
          );

          expect(payload['ok'], isTrue);
          expect(payload['result']['content'][0]['text'], 'lookup result');
          expect(client.postedMethods, <String>[
            'initialize',
            'notifications/initialized',
            'tools/call',
          ]);
        });
      } finally {
        McpClientService.instance.setHttpClientForTesting(null);
        client.close();
      }
    });
  });
}

class _FakeStreamableHttpSseClient extends http.BaseClient {
  _FakeStreamableHttpSseClient({this.includeUnrelatedMessages = false});

  final bool includeUnrelatedMessages;
  bool _closed = false;
  final List<String> postedMethods = <String>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed) throw StateError('client closed');
    final String body = await request.finalize().bytesToString();
    final Map<String, dynamic> rpc = jsonDecode(body);
    final String method = (rpc['method'] ?? '').toString();
    postedMethods.add(method);
    if (rpc['id'] == null) {
      return http.StreamedResponse(
        Stream<List<int>>.fromIterable(const <List<int>>[]),
        202,
        request: request,
      );
    }
    final String payload = jsonEncode(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': rpc['id'],
      'result': _resultFor(method),
    });
    final List<List<int>> chunks = <List<int>>[];
    if (includeUnrelatedMessages) {
      chunks.addAll(<List<int>>[
        utf8.encode('event: message\n'),
        utf8.encode(
          'data: ${jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'method': 'notifications/progress',
            'params': <String, dynamic>{'progress': 1},
          })}\n\n',
        ),
        utf8.encode('event: message\n'),
        utf8.encode(
          'data: ${jsonEncode(<String, dynamic>{'jsonrpc': '2.0', 'id': -123, 'result': <String, dynamic>{}})}\n\n',
        ),
      ]);
    }
    chunks.addAll(<List<int>>[
      utf8.encode('event: message\n'),
      utf8.encode('data: $payload\n\n'),
    ]);
    final stream = Stream<List<int>>.fromIterable(chunks);
    return http.StreamedResponse(
      stream,
      200,
      headers: <String, String>{
        'content-type': 'text/event-stream',
        if (method == 'initialize') 'mcp-session-id': 'streamable-session',
      },
      request: request,
    );
  }

  Object? _resultFor(String method) {
    if (method == 'initialize') {
      return <String, dynamic>{
        'protocolVersion': '2025-06-18',
        'capabilities': <String, dynamic>{},
        'serverInfo': <String, dynamic>{'name': 'streamable-sse'},
      };
    }
    if (method == 'tools/list') {
      return <String, dynamic>{
        'tools': <Map<String, dynamic>>[
          <String, dynamic>{
            'name': 'lookup',
            'description': 'Lookup via Streamable HTTP SSE',
            'inputSchema': <String, dynamic>{'type': 'object'},
          },
        ],
      };
    }
    return <String, dynamic>{};
  }

  @override
  void close() {
    _closed = true;
    super.close();
  }
}

class _FakeLegacySseMcpClient extends http.BaseClient {
  _FakeLegacySseMcpClient({this.endpoint = '/messages'});

  final String endpoint;
  final StreamController<List<int>> _sse = StreamController<List<int>>();
  bool _closed = false;
  int getCount = 0;
  final List<String> postedMethods = <String>[];
  final List<Uri> postUris = <Uri>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed) throw StateError('client closed');
    if (request.method == 'GET') {
      getCount += 1;
      scheduleMicrotask(() {
        _emitSse('endpoint', endpoint);
      });
      return http.StreamedResponse(
        _sse.stream,
        200,
        headers: <String, String>{'content-type': 'text/event-stream'},
        request: request,
      );
    }
    if (request.method == 'POST') {
      postUris.add(request.url);
      final String body = await request.finalize().bytesToString();
      final Map<String, dynamic> rpc = jsonDecode(body);
      final String method = (rpc['method'] ?? '').toString();
      postedMethods.add(method);
      if (rpc['id'] != null) {
        scheduleMicrotask(() {
          _emitSse(
            'message',
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': rpc['id'],
              'result': _resultFor(method),
            }),
          );
        });
      }
      return http.StreamedResponse(
        Stream<List<int>>.fromIterable(<List<int>>[utf8.encode('OK')]),
        202,
        request: request,
      );
    }
    return http.StreamedResponse(
      Stream<List<int>>.fromIterable(<List<int>>[utf8.encode('unsupported')]),
      405,
      request: request,
    );
  }

  Object? _resultFor(String method) {
    if (method == 'initialize') {
      return <String, dynamic>{
        'protocolVersion': '2025-06-18',
        'capabilities': <String, dynamic>{},
        'serverInfo': <String, dynamic>{'name': 'fake-sse'},
      };
    }
    if (method == 'tools/list') {
      return <String, dynamic>{
        'tools': <Map<String, dynamic>>[
          <String, dynamic>{
            'name': 'lookup',
            'description': 'Lookup via SSE',
            'inputSchema': <String, dynamic>{
              'type': 'object',
              'properties': <String, dynamic>{
                'q': <String, dynamic>{'type': 'string'},
              },
            },
          },
        ],
      };
    }
    if (method == 'tools/call') {
      return <String, dynamic>{
        'content': <Map<String, String>>[
          <String, String>{'type': 'text', 'text': 'lookup result'},
        ],
      };
    }
    return <String, dynamic>{};
  }

  void _emitSse(String event, String data) {
    if (_closed || _sse.isClosed) return;
    _sse.add(utf8.encode('event: $event\n'));
    _sse.add(utf8.encode('data: $data\n\n'));
  }

  @override
  void close() {
    _closed = true;
    unawaited(_sse.close());
    super.close();
  }
}
