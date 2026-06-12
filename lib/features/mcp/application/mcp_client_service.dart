import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:screen_memo/core/logging/flutter_logger.dart';
import 'package:screen_memo/data/database/screenshot_database.dart';
import 'package:screen_memo/features/ai/application/provider_request_headers.dart';

class McpClientService {
  McpClientService._();

  static final McpClientService instance = McpClientService._();

  http.Client? _httpClientForTesting;

  void setHttpClientForTesting(http.Client? client) {
    _httpClientForTesting = client;
  }

  static const Set<String> managementToolNames = <String>{
    'list_mcp_servers',
    'preview_mcp_config_import',
    'configure_mcp_server',
    'sync_mcp_server',
    'set_mcp_tool_options',
  };

  static bool isMcpManagementTool(String name) =>
      managementToolNames.contains(name.trim());

  static bool isExternalMcpToolName(String name) =>
      name.trim().startsWith('mcp__');

  static List<Map<String, dynamic>>
  managementToolSchemas() => <Map<String, dynamic>>[
    _functionSchema(
      name: 'list_mcp_servers',
      description:
          'List configured external MCP servers and their synced tools. Returned headers are always redacted.',
      properties: <String, dynamic>{
        'include_tools': <String, dynamic>{
          'type': 'boolean',
          'description': 'Whether to include each server tool list.',
        },
      },
    ),
    _functionSchema(
      name: 'preview_mcp_config_import',
      description:
          'Preview an MCP config JSON import without saving it. Supports RikkaHub/Claude-style {"mcpServers": {...}} configs.',
      properties: <String, dynamic>{
        'config_json': <String, dynamic>{
          'type': 'string',
          'description': 'Raw MCP config JSON.',
        },
      },
      required: <String>['config_json'],
    ),
    _functionSchema(
      name: 'configure_mcp_server',
      description:
          'Create, update, enable, disable, remove, or import external MCP server configs. Apply changes directly when the user asks to configure MCP.',
      properties: <String, dynamic>{
        'action': <String, dynamic>{
          'type': 'string',
          'enum': <String>[
            'upsert',
            'import_json',
            'remove',
            'enable',
            'disable',
          ],
          'description': 'Configuration action to perform.',
        },
        'confirm': <String, dynamic>{
          'type': 'boolean',
          'description':
              'Optional compatibility flag. MCP configuration changes are applied directly when requested by the user.',
        },
        'id': <String, dynamic>{
          'type': 'string',
          'description': 'Existing server id for update/remove/enable/disable.',
        },
        'name': <String, dynamic>{
          'type': 'string',
          'description': 'Server display name.',
        },
        'transport': <String, dynamic>{
          'type': 'string',
          'enum': <String>['streamable_http', 'sse'],
          'description':
              'Transport type. Streamable HTTP and legacy HTTP+SSE are supported.',
        },
        'url': <String, dynamic>{
          'type': 'string',
          'description': 'MCP endpoint URL, normally https://.../mcp.',
        },
        'headers': <String, dynamic>{
          'type': 'object',
          'description':
              'Optional request headers. Sensitive values are stored but redacted from tool output.',
          'additionalProperties': <String, dynamic>{'type': 'string'},
        },
        'enabled': <String, dynamic>{
          'type': 'boolean',
          'description': 'Whether the server is enabled after saving.',
        },
        'config_json': <String, dynamic>{
          'type': 'string',
          'description': 'Raw config JSON for action=import_json.',
        },
        'replace_server_id': <String, dynamic>{
          'type': 'string',
          'description':
              'Optional existing server id to replace when importing exactly one server from JSON.',
        },
        'sync_after_save': <String, dynamic>{
          'type': 'boolean',
          'description': 'If true, immediately sync tools after saving.',
        },
        'enable_tools_after_sync': <String, dynamic>{
          'type': 'boolean',
          'description':
              'If true, enable synced remote tools immediately. Use only when the user explicitly asked for immediate availability.',
        },
      },
      required: <String>['action'],
    ),
    _functionSchema(
      name: 'sync_mcp_server',
      description:
          'Connect to one configured MCP server, run initialize/tools.list, and refresh its cached tool schemas.',
      properties: <String, dynamic>{
        'id': <String, dynamic>{
          'type': 'string',
          'description': 'Server id to sync.',
        },
        'name': <String, dynamic>{
          'type': 'string',
          'description': 'Server name to sync if id is unknown.',
        },
        'enable_tools_after_sync': <String, dynamic>{
          'type': 'boolean',
          'description':
              'If true, enable synced remote tools immediately. Use only when explicitly requested.',
        },
      },
    ),
    _functionSchema(
      name: 'set_mcp_tool_options',
      description: 'Enable or disable a synced external MCP tool.',
      properties: <String, dynamic>{
        'dynamic_name': <String, dynamic>{
          'type': 'string',
          'description': 'Namespaced tool name such as mcp__server__tool.',
        },
        'enabled': <String, dynamic>{'type': 'boolean'},
      },
      required: <String>['dynamic_name'],
    ),
  ];

  static Map<String, dynamic> _functionSchema({
    required String name,
    required String description,
    required Map<String, dynamic> properties,
    List<String> required = const <String>[],
    Map<String, dynamic>? parameters,
  }) {
    return <String, dynamic>{
      'type': 'function',
      'function': <String, dynamic>{
        'name': name,
        'description': description,
        'parameters':
            parameters ??
            <String, dynamic>{
              'type': 'object',
              'properties': properties,
              'required': required,
            },
      },
    };
  }

  Future<List<McpClientServer>> listServers({bool includeTools = true}) async {
    final List<McpClientServer> servers =
        (await ScreenshotDatabase.instance.listMcpClientServersRaw())
            .map(McpClientServer.fromRaw)
            .toList(growable: false);
    if (!includeTools) return servers;
    final List<McpClientTool> allTools =
        (await ScreenshotDatabase.instance.listMcpClientToolsRaw())
            .map(McpClientTool.fromRaw)
            .toList(growable: false);
    final Map<String, List<McpClientTool>> byServer =
        <String, List<McpClientTool>>{};
    for (final tool in allTools) {
      byServer.putIfAbsent(tool.serverId, () => <McpClientTool>[]).add(tool);
    }
    return servers
        .map(
          (server) => server.copyWith(
            tools: List<McpClientTool>.unmodifiable(
              byServer[server.id] ?? const <McpClientTool>[],
            ),
          ),
        )
        .toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> buildEnabledToolSchemas() async {
    final List<McpClientServer> servers = await listServers();
    final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
    for (final server in servers) {
      if (!server.enabled) continue;
      for (final tool in server.tools) {
        if (!tool.enabled) continue;
        out.add(_toolToSchema(server, tool));
      }
    }
    return out;
  }

  Map<String, dynamic> _toolToSchema(
    McpClientServer server,
    McpClientTool tool,
  ) {
    final Map<String, dynamic> inputSchema = _normalizeInputSchema(
      tool.inputSchema,
    );
    final Map<String, dynamic> parameters = Map<String, dynamic>.from(
      inputSchema,
    );
    parameters['type'] = 'object';
    parameters['properties'] = (parameters['properties'] is Map)
        ? Map<String, dynamic>.from(parameters['properties'] as Map)
        : <String, dynamic>{};
    if (parameters['required'] is! List) {
      parameters['required'] = const <String>[];
    }
    return _functionSchema(
      name: tool.dynamicName,
      description: _clipDescription(
        '[External MCP: ${server.name}/${tool.name}] This tool is connected to an external MCP server. ${tool.description}',
      ),
      properties: const <String, dynamic>{},
      parameters: parameters,
    );
  }

  Future<Map<String, dynamic>> executeManagementTool(
    String name,
    Map<String, dynamic> args, {
    bool trustedLocal = true,
  }) async {
    switch (name.trim()) {
      case 'list_mcp_servers':
        final bool includeTools = _toBool(
          args['include_tools'],
          fallback: true,
        );
        return _serversPayload(await listServers(includeTools: includeTools));
      case 'preview_mcp_config_import':
        final String raw = (args['config_json'] ?? '').toString();
        final List<McpConfigImportItem> items = parseImportConfig(raw);
        return <String, dynamic>{
          'tool': name,
          'ok': true,
          'count': items.length,
          'servers': items.map((e) => e.toRedactedJson()).toList(),
        };
      case 'configure_mcp_server':
        return _executeConfigure(args, trustedLocal: trustedLocal);
      case 'sync_mcp_server':
        return _executeSync(args, trustedLocal: trustedLocal);
      case 'set_mcp_tool_options':
        return _executeSetToolOptions(args, trustedLocal: trustedLocal);
      default:
        return <String, dynamic>{
          'tool': name,
          'ok': false,
          'error': 'unknown_mcp_management_tool',
        };
    }
  }

  Future<Map<String, dynamic>> callExternalTool(
    String dynamicName,
    Map<String, dynamic> args,
  ) async {
    final row = await ScreenshotDatabase.instance
        .getMcpClientToolByDynamicNameRaw(dynamicName);
    if (row == null) {
      return <String, dynamic>{
        'tool': dynamicName,
        'ok': false,
        'error': 'mcp_tool_not_found',
        'hint': 'Sync MCP servers and refresh tools.',
      };
    }
    final tool = McpClientTool.fromRaw(row);
    if (!tool.enabled) {
      return <String, dynamic>{
        'tool': dynamicName,
        'ok': false,
        'error': 'mcp_tool_disabled',
      };
    }
    final serverRow = await ScreenshotDatabase.instance.getMcpClientServerRaw(
      tool.serverId,
    );
    if (serverRow == null) {
      return <String, dynamic>{
        'tool': dynamicName,
        'ok': false,
        'error': 'mcp_server_not_found',
      };
    }
    final server = McpClientServer.fromRaw(serverRow);
    if (!server.enabled) {
      return <String, dynamic>{
        'tool': dynamicName,
        'ok': false,
        'error': 'mcp_server_disabled',
      };
    }
    try {
      final McpJsonRpcSession session = await _initializeSession(server);
      late final Object? result;
      try {
        result = await _callMcpJsonRpc(
          server,
          session: session,
          method: 'tools/call',
          params: <String, dynamic>{'name': tool.name, 'arguments': args},
        );
      } finally {
        await session.close();
      }
      return <String, dynamic>{
        'tool': dynamicName,
        'ok': true,
        'server_id': server.id,
        'server_name': server.name,
        'mcp_tool': tool.name,
        'result': _clipDeep(result),
      };
    } catch (e) {
      await ScreenshotDatabase.instance.updateMcpClientServerRaw(server.id, {
        'last_error': e.toString(),
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      });
      return <String, dynamic>{
        'tool': dynamicName,
        'ok': false,
        'server_id': server.id,
        'server_name': server.name,
        'mcp_tool': tool.name,
        'error': e.toString(),
      };
    }
  }

  Future<Map<String, dynamic>> _executeConfigure(
    Map<String, dynamic> args, {
    required bool trustedLocal,
  }) async {
    final String action = (args['action'] ?? '').toString().trim();
    switch (action) {
      case 'import_json':
        final List<McpConfigImportItem> items = parseImportConfig(
          (args['config_json'] ?? '').toString(),
        );
        final String replaceServerId = _safeId(args['replace_server_id']);
        if (replaceServerId.isNotEmpty && items.length != 1) {
          throw ArgumentError(
            'replace_server_id requires exactly one MCP server in config_json.',
          );
        }
        final List<McpClientServer> saved = <McpClientServer>[];
        for (final item in items) {
          saved.add(
            await upsertServer(
              item
                  .toServer(enabled: true)
                  .copyWith(id: saved.isEmpty ? replaceServerId : ''),
            ),
          );
        }
        final bool sync = _toBool(args['sync_after_save'], fallback: false);
        final bool enableTools = _toBool(
          args['enable_tools_after_sync'],
          fallback: false,
        );
        final List<Map<String, dynamic>> syncResults = <Map<String, dynamic>>[];
        if (sync) {
          for (final server in saved) {
            syncResults.add(
              await syncServer(server.id, enableToolsAfterSync: enableTools),
            );
          }
        }
        return <String, dynamic>{
          'tool': 'configure_mcp_server',
          'ok': true,
          'tools_changed': true,
          'action': action,
          'count': saved.length,
          'servers': saved.map((e) => e.toRedactedJson()).toList(),
          if (syncResults.isNotEmpty) 'sync_results': syncResults,
        };
      case 'upsert':
        final server = await upsertServer(
          McpClientServer(
            id: _safeId(args['id']),
            name: (args['name'] ?? '').toString().trim(),
            transport: _normalizeTransport(args['transport']),
            url: (args['url'] ?? '').toString().trim(),
            headers: _stringMap(args['headers']),
            enabled: _toBool(args['enabled'], fallback: true),
            createdAt: 0,
            updatedAt: 0,
            tools: const <McpClientTool>[],
          ),
        );
        final bool sync = _toBool(args['sync_after_save'], fallback: false);
        Map<String, dynamic>? syncResult;
        if (sync) {
          syncResult = await syncServer(
            server.id,
            enableToolsAfterSync: _toBool(
              args['enable_tools_after_sync'],
              fallback: false,
            ),
          );
        }
        return <String, dynamic>{
          'tool': 'configure_mcp_server',
          'ok': true,
          'tools_changed': true,
          'action': action,
          'server': server.toRedactedJson(),
          if (syncResult != null) 'sync_result': syncResult,
        };
      case 'enable':
      case 'disable':
        final server = await _resolveServer(args);
        if (server == null) {
          return _managementError('configure_mcp_server', 'server_not_found');
        }
        await ScreenshotDatabase.instance.updateMcpClientServerRaw(server.id, {
          'enabled': action == 'enable' ? 1 : 0,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        });
        return <String, dynamic>{
          'tool': 'configure_mcp_server',
          'ok': true,
          'tools_changed': true,
          'action': action,
          'server_id': server.id,
        };
      case 'remove':
        final server = await _resolveServer(args);
        if (server == null) {
          return _managementError('configure_mcp_server', 'server_not_found');
        }
        await ScreenshotDatabase.instance.deleteMcpClientServer(server.id);
        return <String, dynamic>{
          'tool': 'configure_mcp_server',
          'ok': true,
          'tools_changed': true,
          'action': action,
          'server_id': server.id,
        };
      default:
        return _managementError('configure_mcp_server', 'invalid_action');
    }
  }

  Future<Map<String, dynamic>> _executeSync(
    Map<String, dynamic> args, {
    required bool trustedLocal,
  }) async {
    final server = await _resolveServer(args);
    if (server == null) {
      return _managementError('sync_mcp_server', 'server_not_found');
    }
    return syncServer(
      server.id,
      enableToolsAfterSync: _toBool(
        args['enable_tools_after_sync'],
        fallback: false,
      ),
    );
  }

  Future<Map<String, dynamic>> _executeSetToolOptions(
    Map<String, dynamic> args, {
    required bool trustedLocal,
  }) async {
    final String dynamicName = (args['dynamic_name'] ?? '').toString().trim();
    if (!isExternalMcpToolName(dynamicName)) {
      return _managementError('set_mcp_tool_options', 'invalid_dynamic_name');
    }
    final int existing = await ScreenshotDatabase.instance
        .countMcpClientToolByDynamicName(dynamicName);
    if (existing <= 0) {
      return _managementError('set_mcp_tool_options', 'mcp_tool_not_found');
    }
    await ScreenshotDatabase.instance.updateMcpClientToolOptions(
      dynamicName: dynamicName,
      enabled: args.containsKey('enabled')
          ? _toBool(args['enabled'], fallback: false)
          : null,
    );
    return <String, dynamic>{
      'tool': 'set_mcp_tool_options',
      'ok': true,
      'tools_changed': true,
      'dynamic_name': dynamicName,
    };
  }

  Future<McpClientServer> upsertServer(McpClientServer input) async {
    final String name = input.name.trim();
    final String url = input.url.trim();
    if (name.isEmpty) throw ArgumentError('Server name is required.');
    final Uri? uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || uri.host.trim().isEmpty) {
      throw ArgumentError('Valid MCP URL is required.');
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw ArgumentError('MCP URL must use http or https.');
    }
    final Map<String, String> headers = _validateHeaders(input.headers);
    final int now = DateTime.now().millisecondsSinceEpoch;
    final Map<String, Object?>? existing = input.id.trim().isNotEmpty
        ? await ScreenshotDatabase.instance.getMcpClientServerRaw(input.id)
        : await ScreenshotDatabase.instance.getMcpClientServerByNameRaw(name);
    final String id = (existing?['id'] ?? input.id).toString().trim().isNotEmpty
        ? (existing?['id'] ?? input.id).toString().trim()
        : _newServerId(name);
    final McpClientServer server = input.copyWith(
      id: id,
      name: name,
      transport: _normalizeTransport(input.transport),
      url: url,
      headers: headers,
      createdAt: _toInt(existing?['created_at']) ?? now,
      updatedAt: now,
      lastSyncedAt: _toInt(existing?['last_synced_at']),
      lastError: existing?['last_error']?.toString(),
    );
    await ScreenshotDatabase.instance.upsertMcpClientServerRaw(server.toRaw());
    return server;
  }

  Future<Map<String, dynamic>> syncServer(
    String serverId, {
    bool enableToolsAfterSync = false,
  }) async {
    final row = await ScreenshotDatabase.instance.getMcpClientServerRaw(
      serverId.trim(),
    );
    if (row == null) {
      return _managementError('sync_mcp_server', 'server_not_found');
    }
    final server = McpClientServer.fromRaw(row);
    try {
      final McpJsonRpcSession session = await _initializeSession(server);
      late final Object? toolsResult;
      try {
        toolsResult = await _callMcpJsonRpc(
          server,
          method: 'tools/list',
          params: const <String, dynamic>{},
          session: session,
        );
      } finally {
        await session.close();
      }
      final List<Object?> toolsRaw = _extractToolsList(toolsResult);
      final int now = DateTime.now().millisecondsSinceEpoch;
      final List<Map<String, Object?>> rows = toolsRaw
          .whereType<Map>()
          .map((Map raw) => _toolRawFromMcp(server, raw, now))
          .where((Map<String, Object?> raw) {
            return (raw['name'] ?? '').toString().trim().isNotEmpty;
          })
          .toList(growable: false);
      await ScreenshotDatabase.instance.replaceMcpClientToolsForServer(
        serverId: server.id,
        tools: rows,
        syncedAt: now,
      );
      if (enableToolsAfterSync) {
        for (final raw in rows) {
          final String dynamicName = (raw['dynamic_name'] ?? '').toString();
          if (dynamicName.isEmpty) continue;
          await ScreenshotDatabase.instance.updateMcpClientToolOptions(
            dynamicName: dynamicName,
            enabled: true,
          );
        }
      }
      return <String, dynamic>{
        'tool': 'sync_mcp_server',
        'ok': true,
        'tools_changed': true,
        'server': server.toRedactedJson(includeTools: false),
        'count': rows.length,
        'enabled_after_sync': enableToolsAfterSync,
        'tools': rows
            .map(
              (raw) => <String, dynamic>{
                'name': raw['name'],
                'dynamic_name': raw['dynamic_name'],
                'description': raw['description'],
                'enabled': enableToolsAfterSync,
              },
            )
            .toList(),
      };
    } catch (e) {
      await ScreenshotDatabase.instance.updateMcpClientServerRaw(server.id, {
        'last_error': e.toString(),
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      });
      return <String, dynamic>{
        'tool': 'sync_mcp_server',
        'ok': false,
        'server': server.toRedactedJson(includeTools: false),
        'error': e.toString(),
      };
    }
  }

  Future<McpJsonRpcSession> _initializeSession(McpClientServer server) async {
    final McpJsonRpcSession session = McpJsonRpcSession();
    final Object? result = await _callMcpJsonRpc(
      server,
      method: 'initialize',
      params: {
        'protocolVersion': '2025-06-18',
        'capabilities': <String, dynamic>{},
        'clientInfo': <String, dynamic>{
          'name': 'ScreenMemo',
          'version': '1.0.0',
        },
      },
      session: session,
    );
    if (result is Map && result['protocolVersion'] != null) {
      final String protocolVersion = result['protocolVersion'].toString();
      if (protocolVersion.trim().isEmpty) {
        throw StateError('MCP initialize returned empty protocolVersion.');
      }
      session.protocolVersion = protocolVersion;
    }
    await _callMcpJsonRpc(
      server,
      method: 'notifications/initialized',
      session: session,
      isNotification: true,
    );
    return session;
  }

  Future<Object?> _callMcpJsonRpc(
    McpClientServer server, {
    required String method,
    Map<String, dynamic>? params,
    McpJsonRpcSession? session,
    bool isNotification = false,
  }) async {
    if (server.transport == 'sse') {
      return _callLegacySseJsonRpc(
        server,
        method: method,
        params: params,
        session: session,
        isNotification: isNotification,
      );
    }
    if (server.transport != 'streamable_http') {
      throw StateError('Unsupported MCP transport: ${server.transport}');
    }
    final Uri uri = Uri.parse(server.url);
    final Map<String, String> headers =
        ProviderRequestHeaders.mergeHeaders(<String, String>{
          'Accept': 'application/json, text/event-stream',
          'Content-Type': 'application/json',
          'MCP-Protocol-Version': '2025-06-18',
          'User-Agent': 'ScreenMemo MCP Client',
        }, server.headers);
    final String? sessionId = session?.sessionId;
    if (sessionId != null && sessionId.trim().isNotEmpty) {
      headers['MCP-Session-Id'] = sessionId.trim();
    }
    final Map<String, dynamic> payload = <String, dynamic>{
      'jsonrpc': '2.0',
      if (!isNotification) 'id': DateTime.now().microsecondsSinceEpoch,
      'method': method,
      if (params != null) 'params': params,
    };
    try {
      await FlutterLogger.nativeDebug(
        'MCP_CLIENT',
        'call server=${server.id} method=$method headers=${jsonEncode(ProviderRequestHeaders.redactForLog(headers))}',
      );
    } catch (_) {}
    final http.Client? injectedClient = _httpClientForTesting;
    final http.Client client = injectedClient ?? http.Client();
    late final http.StreamedResponse response;
    try {
      final http.Request request = http.Request('POST', uri)
        ..headers.addAll(headers)
        ..body = jsonEncode(payload);
      response = await client
          .send(request)
          .timeout(const Duration(seconds: 25));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final String body = await response.stream
            .transform(utf8.decoder)
            .join()
            .timeout(const Duration(seconds: 25));
        final String redactedBody = _redactTextByHeaders(body, headers);
        throw StateError(
          'MCP HTTP ${response.statusCode}: ${_clipString(redactedBody, 800)}',
        );
      }
      final String? nextSessionId =
          response.headers['mcp-session-id'] ??
          response.headers['MCP-Session-Id'];
      if (nextSessionId != null && nextSessionId.trim().isNotEmpty) {
        session?.sessionId = nextSessionId.trim();
      }
      if (isNotification) {
        return null;
      }
      return await _decodeMcpResponseStream(
        response.stream,
        headers: headers,
        expectedId: _toInt(payload['id']),
      );
    } finally {
      if (injectedClient == null) client.close();
    }
  }

  Future<Object?> _callLegacySseJsonRpc(
    McpClientServer server, {
    required String method,
    Map<String, dynamic>? params,
    McpJsonRpcSession? session,
    bool isNotification = false,
  }) async {
    final _McpLegacySseConnection connection =
        session?._sseConnection ?? _McpLegacySseConnection(this, server);
    if (session != null) session._sseConnection = connection;
    await connection.start();
    final int? id = isNotification
        ? null
        : DateTime.now().microsecondsSinceEpoch;
    final Map<String, dynamic> payload = <String, dynamic>{
      'jsonrpc': '2.0',
      if (id != null) 'id': id,
      'method': method,
      if (params != null) 'params': params,
    };
    try {
      await FlutterLogger.nativeDebug(
        'MCP_CLIENT',
        'sse call server=${server.id} method=$method headers=${jsonEncode(ProviderRequestHeaders.redactForLog(connection.headers))}',
      );
    } catch (_) {}
    return connection.send(payload, id: id);
  }

  Future<Object?> _decodeMcpResponseStream(
    Stream<List<int>> stream, {
    required Map<String, String> headers,
    required int? expectedId,
  }) async {
    String? eventName;
    final StringBuffer data = StringBuffer();
    final Completer<Object?> completer = Completer<Object?>();
    StreamSubscription<String>? subscription;

    void dispatch() {
      final String event = (eventName ?? 'message').trim();
      final String text = data.toString().trim();
      eventName = null;
      data.clear();
      if (text.isEmpty) return;
      if (event != 'message') return;
      try {
        final _McpDecodedResponse decoded = _decodeMcpBody(
          text,
          headers: headers,
          expectedId: expectedId,
        );
        if (!decoded.matchesExpectedId) return;
        if (!completer.isCompleted) completer.complete(decoded.result);
      } catch (e, st) {
        if (!completer.isCompleted) completer.completeError(e, st);
      }
    }

    subscription = stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (String line) {
            if (line.isEmpty) {
              dispatch();
            } else if (line.startsWith('event:')) {
              eventName = line.substring(6).trim();
            } else if (line.startsWith('data:')) {
              if (data.isNotEmpty) data.writeln();
              data.write(line.substring(5).trim());
            } else if (!line.startsWith(':')) {
              if (data.isNotEmpty) data.writeln();
              data.write(line);
            }
          },
          onError: (Object e, StackTrace st) {
            if (!completer.isCompleted) completer.completeError(e, st);
          },
          onDone: () {
            dispatch();
            if (!completer.isCompleted) {
              completer.completeError(StateError('Empty MCP response.'));
            }
          },
          cancelOnError: true,
        );
    try {
      return await completer.future.timeout(const Duration(seconds: 25));
    } finally {
      await subscription.cancel();
    }
  }

  _McpDecodedResponse _decodeMcpBody(
    String body, {
    required Map<String, String> headers,
    int? expectedId,
  }) {
    final String text = body.trim();
    if (text.isEmpty) {
      return const _McpDecodedResponse(result: null, matchesExpectedId: true);
    }
    String jsonText = text;
    if (text.startsWith('event:') || text.startsWith('data:')) {
      final StringBuffer sb = StringBuffer();
      for (final String line in const LineSplitter().convert(text)) {
        if (line.startsWith('data:')) {
          final String data = line.substring(5).trim();
          if (data.isNotEmpty && data != '[DONE]') sb.writeln(data);
        }
      }
      jsonText = sb.toString().trim();
    }
    final dynamic decoded = jsonDecode(jsonText);
    if (decoded is Map) {
      if (expectedId != null && _toInt(decoded['id']) != expectedId) {
        return const _McpDecodedResponse(
          result: null,
          matchesExpectedId: false,
        );
      }
      if (decoded['error'] != null) {
        throw StateError(
          'MCP error: ${_redactTextByHeaders(jsonEncode(decoded['error']), headers)}',
        );
      }
      return _McpDecodedResponse(
        result: decoded['result'],
        matchesExpectedId: true,
      );
    }
    return _McpDecodedResponse(result: decoded, matchesExpectedId: true);
  }

  List<Object?> _extractToolsList(Object? toolsResult) {
    if (toolsResult is Map && toolsResult['tools'] is List) {
      return List<Object?>.from(toolsResult['tools'] as List);
    }
    if (toolsResult is List) return List<Object?>.from(toolsResult);
    throw StateError('Invalid MCP tools/list response.');
  }

  Map<String, Object?> _toolRawFromMcp(
    McpClientServer server,
    Map raw,
    int now,
  ) {
    final String name = (raw['name'] ?? '').toString().trim();
    final Object? schema = raw['inputSchema'] ?? raw['input_schema'];
    return <String, Object?>{
      'id': '${server.id}:$name',
      'server_id': server.id,
      'name': name,
      'dynamic_name': dynamicToolName(server.id, server.name, name),
      'description': _clipString((raw['description'] ?? '').toString(), 1200),
      'input_schema_json': jsonEncode(_normalizeInputSchema(schema)),
      'enabled': 0,
      'created_at': now,
      'updated_at': now,
      'last_synced_at': now,
    };
  }

  List<McpConfigImportItem> parseImportConfig(String rawJson) {
    final dynamic decoded = jsonDecode(rawJson);
    final Object? root = decoded is Map && decoded['mcpServers'] is Map
        ? decoded['mcpServers']
        : decoded;
    if (root is! Map) {
      throw FormatException('MCP config must be an object.');
    }
    final List<McpConfigImportItem> out = <McpConfigImportItem>[];
    root.forEach((Object? key, Object? value) {
      if (value is! Map) return;
      final String name = (value['name'] ?? key ?? '').toString().trim();
      final String transport = _normalizeTransport(
        value['type'] ?? value['transport'] ?? 'streamable_http',
      );
      final String url = (value['url'] ?? value['endpoint'] ?? '')
          .toString()
          .trim();
      final Map<String, String> headers = _validateHeaders(
        _stringMap(value['headers']),
      );
      if (name.isEmpty || url.isEmpty) return;
      out.add(
        McpConfigImportItem(
          name: name,
          transport: transport,
          url: url,
          headers: headers,
        ),
      );
    });
    if (out.isEmpty) throw FormatException('No MCP servers found in config.');
    return out;
  }

  Future<McpClientServer?> _resolveServer(Map<String, dynamic> args) async {
    final String id = (args['id'] ?? '').toString().trim();
    if (id.isNotEmpty) {
      final row = await ScreenshotDatabase.instance.getMcpClientServerRaw(id);
      return row == null ? null : McpClientServer.fromRaw(row);
    }
    final String name = (args['name'] ?? '').toString().trim();
    if (name.isNotEmpty) {
      final row = await ScreenshotDatabase.instance.getMcpClientServerByNameRaw(
        name,
      );
      return row == null ? null : McpClientServer.fromRaw(row);
    }
    return null;
  }

  Map<String, dynamic> _serversPayload(List<McpClientServer> servers) {
    return <String, dynamic>{
      'tool': 'list_mcp_servers',
      'ok': true,
      'count': servers.length,
      'servers': servers.map((e) => e.toRedactedJson()).toList(),
    };
  }

  Map<String, dynamic> _managementError(String tool, String error) {
    return <String, dynamic>{'tool': tool, 'ok': false, 'error': error};
  }

  static String dynamicToolName(
    String serverId,
    String serverName,
    String toolName,
  ) {
    final String serverSlug = _slug(
      serverName.isNotEmpty ? serverName : serverId,
    );
    final String toolSlug = _slug(toolName);
    final String hash = _stableHash('$serverId::$toolName');
    final String base =
        'mcp__${serverSlug.isEmpty ? 'server' : serverSlug}__${toolSlug.isEmpty ? 'tool' : toolSlug}__$hash';
    if (base.length <= 64) return base;
    final int keepServer = min(16, serverSlug.length);
    final int keepTool = min(22, toolSlug.length);
    return 'mcp__${serverSlug.substring(0, keepServer)}__${toolSlug.substring(0, keepTool)}__$hash';
  }

  static String _newServerId(String name) {
    final String uuid = ProviderRequestHeaders.newUuid().replaceAll('-', '');
    final String slug = _slug(name);
    return '${slug.isEmpty ? 'mcp' : slug}_${uuid.substring(0, 10)}';
  }

  static String _safeId(Object? raw) {
    final String id = (raw ?? '').toString().trim();
    if (!RegExp(r'^[A-Za-z0-9_.:-]{1,120}$').hasMatch(id)) return '';
    return id;
  }

  static String _slug(String raw) {
    final String lower = raw.trim().toLowerCase();
    final String replaced = lower.replaceAll(RegExp(r'[^a-z0-9_]+'), '_');
    return replaced
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
  }

  static String _stableHash(String raw) {
    int hash = 0x811c9dc5;
    for (final int code in raw.codeUnits) {
      hash ^= code;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  static Map<String, dynamic> _normalizeInputSchema(Object? raw) {
    if (raw is String && raw.trim().isNotEmpty) {
      try {
        return _normalizeInputSchema(jsonDecode(raw));
      } catch (_) {}
    }
    if (raw is Map) {
      final Map<String, dynamic> out = Map<String, dynamic>.from(raw);
      out['type'] = (out['type'] ?? 'object').toString();
      if (out['type'] != 'object') out['type'] = 'object';
      if (out['properties'] is! Map) out['properties'] = <String, dynamic>{};
      return out;
    }
    return <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{},
    };
  }

  static Map<String, String> _validateHeaders(Map<String, String> headers) {
    final Map<String, String> out = <String, String>{};
    headers.forEach((String key, String value) {
      final String name = key.trim();
      final String val = value.trim();
      if (name.isEmpty && val.isEmpty) return;
      if (!ProviderRequestHeaders.isValidHeaderName(name)) {
        throw ArgumentError('Invalid header name: $name');
      }
      if (val.contains('\r') || val.contains('\n')) {
        throw ArgumentError('Invalid header value for $name');
      }
      if (val.isNotEmpty) out[name] = val;
    });
    return out;
  }

  static Map<String, String> _stringMap(Object? raw) {
    if (raw is String && raw.trim().isNotEmpty) {
      try {
        return _stringMap(jsonDecode(raw));
      } catch (_) {
        return const <String, String>{};
      }
    }
    if (raw is! Map) return const <String, String>{};
    final Map<String, String> out = <String, String>{};
    raw.forEach((Object? key, Object? value) {
      final String k = (key ?? '').toString().trim();
      final String v = (value ?? '').toString().trim();
      if (k.isNotEmpty && v.isNotEmpty) out[k] = v;
    });
    return out;
  }

  static bool _toBool(Object? raw, {required bool fallback}) {
    if (raw is bool) return raw;
    if (raw is num) return raw != 0;
    final String s = (raw ?? '').toString().trim().toLowerCase();
    if (s.isEmpty) return fallback;
    return s == 'true' || s == '1' || s == 'yes' || s == 'y';
  }

  static int? _toInt(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return int.tryParse((raw ?? '').toString());
  }

  static String _normalizeTransport(Object? raw) {
    final String value = (raw ?? '').toString().trim().toLowerCase();
    if (value.isEmpty) return 'streamable_http';
    if (value == 'streamable_http' ||
        value == 'streamable-http' ||
        value == 'http') {
      return 'streamable_http';
    }
    if (value == 'sse') return 'sse';
    throw ArgumentError('Unsupported MCP transport: $value');
  }

  static String _clipDescription(String text) => _clipString(text, 900);

  static String _clipString(String text, int maxChars) {
    final String t = text.trim();
    if (t.length <= maxChars) return t;
    return '${t.substring(0, maxChars)}...';
  }

  static String _redactTextByHeaders(String text, Map<String, String> headers) {
    String out = text;
    headers.forEach((String key, String value) {
      final String trimmed = value.trim();
      if (trimmed.length < 4) return;
      final String masked = ProviderRequestHeaders.maskedHeaderValue(
        key,
        trimmed,
      );
      if (masked == trimmed) return;
      out = out.replaceAll(trimmed, masked);
      if (key.toLowerCase() == 'authorization' &&
          trimmed.toLowerCase().startsWith('bearer ')) {
        out = out.replaceAll(trimmed.substring(7).trim(), '***');
      }
    });
    return out;
  }

  static Object? _clipDeep(Object? value, {int maxString = 8000}) {
    if (value is String) return _clipString(value, maxString);
    if (value is List) {
      return value.take(80).map((Object? v) => _clipDeep(v)).toList();
    }
    if (value is Map) {
      final Map<String, dynamic> out = <String, dynamic>{};
      int count = 0;
      value.forEach((Object? key, Object? val) {
        if (count++ >= 80) return;
        out[(key ?? '').toString()] = _clipDeep(val);
      });
      return out;
    }
    return value;
  }

}

class McpClientServer {
  const McpClientServer({
    required this.id,
    required this.name,
    required this.transport,
    required this.url,
    required this.headers,
    required this.enabled,
    required this.createdAt,
    required this.updatedAt,
    this.lastSyncedAt,
    this.lastError,
    this.tools = const <McpClientTool>[],
  });

  final String id;
  final String name;
  final String transport;
  final String url;
  final Map<String, String> headers;
  final bool enabled;
  final int createdAt;
  final int updatedAt;
  final int? lastSyncedAt;
  final String? lastError;
  final List<McpClientTool> tools;

  factory McpClientServer.fromRaw(Map<String, Object?> raw) {
    return McpClientServer(
      id: (raw['id'] ?? '').toString(),
      name: (raw['name'] ?? '').toString(),
      transport: (raw['transport'] ?? 'streamable_http').toString(),
      url: (raw['url'] ?? '').toString(),
      headers: McpClientService._stringMap(raw['headers_json']),
      enabled: McpClientService._toInt(raw['enabled']) == 1,
      createdAt: McpClientService._toInt(raw['created_at']) ?? 0,
      updatedAt: McpClientService._toInt(raw['updated_at']) ?? 0,
      lastSyncedAt: McpClientService._toInt(raw['last_synced_at']),
      lastError: raw['last_error']?.toString(),
    );
  }

  Map<String, Object?> toRaw() {
    return <String, Object?>{
      'id': id,
      'name': name,
      'transport': transport,
      'url': url,
      'headers_json': jsonEncode(headers),
      'enabled': enabled ? 1 : 0,
      'created_at': createdAt,
      'updated_at': updatedAt,
      'last_synced_at': lastSyncedAt,
      'last_error': lastError,
    };
  }

  McpClientServer copyWith({
    String? id,
    String? name,
    String? transport,
    String? url,
    Map<String, String>? headers,
    bool? enabled,
    int? createdAt,
    int? updatedAt,
    int? lastSyncedAt,
    String? lastError,
    List<McpClientTool>? tools,
  }) {
    return McpClientServer(
      id: id ?? this.id,
      name: name ?? this.name,
      transport: transport ?? this.transport,
      url: url ?? this.url,
      headers: headers ?? this.headers,
      enabled: enabled ?? this.enabled,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
      lastError: lastError ?? this.lastError,
      tools: tools ?? this.tools,
    );
  }

  Map<String, dynamic> toRedactedJson({bool includeTools = true}) {
    return <String, dynamic>{
      'id': id,
      'name': name,
      'transport': transport,
      'url': url,
      'headers': ProviderRequestHeaders.redactForLog(headers),
      'enabled': enabled,
      'created_at': createdAt,
      'updated_at': updatedAt,
      'last_synced_at': lastSyncedAt,
      'last_error': lastError,
      if (includeTools) 'tools': tools.map((e) => e.toJson()).toList(),
    };
  }
}

class McpClientTool {
  const McpClientTool({
    required this.id,
    required this.serverId,
    required this.name,
    required this.dynamicName,
    required this.description,
    required this.inputSchema,
    required this.enabled,
    required this.createdAt,
    required this.updatedAt,
    this.lastSyncedAt,
  });

  final String id;
  final String serverId;
  final String name;
  final String dynamicName;
  final String description;
  final Map<String, dynamic> inputSchema;
  final bool enabled;
  final int createdAt;
  final int updatedAt;
  final int? lastSyncedAt;

  factory McpClientTool.fromRaw(Map<String, Object?> raw) {
    return McpClientTool(
      id: (raw['id'] ?? '').toString(),
      serverId: (raw['server_id'] ?? '').toString(),
      name: (raw['name'] ?? '').toString(),
      dynamicName: (raw['dynamic_name'] ?? '').toString(),
      description: (raw['description'] ?? '').toString(),
      inputSchema: McpClientService._normalizeInputSchema(
        raw['input_schema_json'],
      ),
      enabled: McpClientService._toInt(raw['enabled']) == 1,
      createdAt: McpClientService._toInt(raw['created_at']) ?? 0,
      updatedAt: McpClientService._toInt(raw['updated_at']) ?? 0,
      lastSyncedAt: McpClientService._toInt(raw['last_synced_at']),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'server_id': serverId,
      'name': name,
      'dynamic_name': dynamicName,
      'description': description,
      'input_schema': inputSchema,
      'enabled': enabled,
      'created_at': createdAt,
      'updated_at': updatedAt,
      'last_synced_at': lastSyncedAt,
    };
  }
}

class McpConfigImportItem {
  const McpConfigImportItem({
    required this.name,
    required this.transport,
    required this.url,
    required this.headers,
  });

  final String name;
  final String transport;
  final String url;
  final Map<String, String> headers;

  McpClientServer toServer({required bool enabled}) {
    return McpClientServer(
      id: '',
      name: name,
      transport: transport,
      url: url,
      headers: headers,
      enabled: enabled,
      createdAt: 0,
      updatedAt: 0,
    );
  }

  Map<String, dynamic> toRedactedJson() {
    return <String, dynamic>{
      'name': name,
      'transport': transport,
      'url': url,
      'headers': ProviderRequestHeaders.redactForLog(headers),
    };
  }
}

class McpJsonRpcSession {
  String? sessionId;
  String? protocolVersion;
  _McpLegacySseConnection? _sseConnection;

  Future<void> close() async {
    await _sseConnection?.close();
    _sseConnection = null;
  }
}

class _McpDecodedResponse {
  const _McpDecodedResponse({
    required this.result,
    required this.matchesExpectedId,
  });

  final Object? result;
  final bool matchesExpectedId;
}

class _McpLegacySseConnection {
  _McpLegacySseConnection(this.service, this.server);

  final McpClientService service;
  final McpClientServer server;
  final Completer<Uri> _endpoint = Completer<Uri>();
  final Map<int, Completer<Object?>> _pending = <int, Completer<Object?>>{};

  StreamSubscription<String>? _lineSubscription;
  http.Client? _ownedClient;
  Future<void>? _startFuture;
  bool _closed = false;
  String? _eventName;
  final StringBuffer _dataBuffer = StringBuffer();

  Map<String, String> get headers =>
      ProviderRequestHeaders.mergeHeaders(<String, String>{
        'Accept': 'text/event-stream',
        'Cache-Control': 'no-cache',
        'User-Agent': 'ScreenMemo MCP Client',
      }, server.headers);

  Future<void> start() {
    return _startFuture ??= _start();
  }

  Future<void> _start() async {
    final Uri uri = Uri.parse(server.url);
    final http.Client client =
        service._httpClientForTesting ?? (_ownedClient = http.Client());
    final http.Request request = http.Request('GET', uri);
    request.headers.addAll(headers);
    final http.StreamedResponse response = await client
        .send(request)
        .timeout(const Duration(seconds: 25));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('MCP SSE HTTP ${response.statusCode}');
    }
    _lineSubscription = response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          _handleLine,
          onError: _failAll,
          onDone: () {
            if (!_closed) {
              _failAll(StateError('MCP SSE stream closed.'));
            }
          },
          cancelOnError: true,
        );
    await _endpoint.future.timeout(
      const Duration(seconds: 25),
      onTimeout: () => throw TimeoutException('MCP SSE endpoint timeout.'),
    );
  }

  Future<Object?> send(Map<String, dynamic> payload, {required int? id}) async {
    final Uri endpoint = await _endpoint.future;
    if (_closed) throw StateError('MCP SSE connection is closed.');
    final Completer<Object?>? pending = id == null
        ? null
        : Completer<Object?>();
    if (id != null && pending != null) {
      _pending[id] = pending;
    }
    final Map<String, String> postHeaders = ProviderRequestHeaders.mergeHeaders(
      <String, String>{
        'Content-Type': 'application/json',
        'User-Agent': 'ScreenMemo MCP Client',
      },
      server.headers,
    );
    final http.Response response =
        await (service._httpClientForTesting?.post(
                  endpoint,
                  headers: postHeaders,
                  body: jsonEncode(payload),
                ) ??
                http.post(
                  endpoint,
                  headers: postHeaders,
                  body: jsonEncode(payload),
                ))
            .timeout(const Duration(seconds: 25));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (id != null) _pending.remove(id);
      throw StateError(
        'MCP SSE POST ${response.statusCode}: ${McpClientService._clipString(McpClientService._redactTextByHeaders(response.body, postHeaders), 800)}',
      );
    }
    if (id == null) return null;
    return pending!.future.timeout(
      const Duration(seconds: 25),
      onTimeout: () {
        _pending.remove(id);
        throw TimeoutException('MCP SSE response timeout.');
      },
    );
  }

  Future<void> close() async {
    _closed = true;
    await _lineSubscription?.cancel();
    _lineSubscription = null;
    _ownedClient?.close();
    _ownedClient = null;
    _failAll(StateError('MCP SSE connection closed.'));
  }

  void _handleLine(String line) {
    if (line.isEmpty) {
      _dispatchEvent();
      return;
    }
    if (line.startsWith(':')) return;
    if (line.startsWith('event:')) {
      _eventName = line.substring(6).trim();
      return;
    }
    if (line.startsWith('data:')) {
      if (_dataBuffer.isNotEmpty) _dataBuffer.writeln();
      _dataBuffer.write(line.substring(5).trim());
    }
  }

  void _dispatchEvent() {
    final String event = (_eventName ?? 'message').trim();
    final String data = _dataBuffer.toString().trim();
    _eventName = null;
    _dataBuffer.clear();
    if (data.isEmpty) return;
    if (event == 'endpoint') {
      if (!_endpoint.isCompleted) {
        _endpoint.complete(_resolveEndpoint(Uri.parse(server.url), data));
      }
      return;
    }
    if (event == 'error') {
      _failAll(StateError('MCP SSE error: $data'));
      return;
    }
    if (event != 'message') return;
    try {
      final dynamic decoded = jsonDecode(data);
      if (decoded is! Map) return;
      if (decoded['id'] == null) return;
      final int? id = McpClientService._toInt(decoded['id']);
      if (id == null) return;
      final Completer<Object?>? pending = _pending.remove(id);
      if (pending == null || pending.isCompleted) return;
      if (decoded['error'] != null) {
        pending.completeError(
          StateError(
            'MCP error: ${McpClientService._redactTextByHeaders(jsonEncode(decoded['error']), headers)}',
          ),
        );
      } else {
        pending.complete(decoded['result']);
      }
    } catch (e) {
      _failAll(e);
    }
  }

  Uri _resolveEndpoint(Uri base, String raw) {
    final String text = raw.trim();
    final Uri? parsed = Uri.tryParse(text);
    if (parsed != null && parsed.hasScheme) return parsed;
    return base.resolve(text);
  }

  void _failAll(Object error) {
    if (!_endpoint.isCompleted) {
      _endpoint.completeError(error);
    }
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    _pending.clear();
  }
}
