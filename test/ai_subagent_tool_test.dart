import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:screen_memo/data/database/screenshot_database.dart';
import 'package:screen_memo/features/ai/application/ai_chat_service.dart';
import 'package:screen_memo/features/ai/application/ai_providers_service.dart';
import 'package:screen_memo/features/ai/application/ai_settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _RealHttpOverrides extends HttpOverrides {}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDown(() async {
    try {
      await ScreenshotDatabase.instance.disposeDesktop();
    } catch (_) {}
  });

  test('delegate_subagents tool schema exists with task parameters', () {
    final List<Map<String, dynamic>> tools = AIChatService.defaultChatTools();
    expect(
      tools.any((Map<String, dynamic> item) {
        final Map<String, dynamic> fn = Map<String, dynamic>.from(
          item['function'] as Map,
        );
        return fn['name'] == 'update_plan';
      }),
      isFalse,
    );
    final Map<String, dynamic> tool = tools.firstWhere((
      Map<String, dynamic> item,
    ) {
      final Map<String, dynamic> fn = Map<String, dynamic>.from(
        item['function'] as Map,
      );
      return fn['name'] == 'delegate_subagents';
    });

    final Map<String, dynamic> fn = Map<String, dynamic>.from(
      tool['function'] as Map,
    );
    final Map<String, dynamic> params = Map<String, dynamic>.from(
      fn['parameters'] as Map,
    );
    final Map<String, dynamic> properties = Map<String, dynamic>.from(
      params['properties'] as Map,
    );
    final Map<String, dynamic> tasks = Map<String, dynamic>.from(
      properties['tasks'] as Map,
    );
    final Map<String, dynamic> taskItem = Map<String, dynamic>.from(
      tasks['items'] as Map,
    );
    final Map<String, dynamic> taskProps = Map<String, dynamic>.from(
      taskItem['properties'] as Map,
    );

    expect(params['required'], contains('tasks'));
    expect(tasks['maxItems'], greaterThanOrEqualTo(2));
    expect(
      taskProps.keys,
      containsAll(<String>['id', 'name', 'role', 'task', 'instructions']),
    );
    expect(taskItem['required'], contains('task'));

    final List<String> subagentToolNames = AIChatService.defaultSubagentTools()
        .map((Map<String, dynamic> item) {
          final Map<String, dynamic> fn = Map<String, dynamic>.from(
            item['function'] as Map,
          );
          return (fn['name'] as String?) ?? '';
        })
        .toList(growable: false);
    expect(subagentToolNames, contains('search_screenshots_ocr'));
    expect(subagentToolNames, contains('generate_image'));
    expect(subagentToolNames, isNot(contains('delegate_subagents')));
    expect(subagentToolNames, isNot(contains('update_todos')));
    expect(subagentToolNames, isNot(contains('update_plan')));
  });

  test('delegate_subagents streams child agents and lets reviewer read peers', () async {
    final Directory tmp = await Directory.systemTemp.createTemp(
      'screen_memo_subagents_',
    );
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final List<Map<String, dynamic>> chatRequests = <Map<String, dynamic>>[];
    final List<String> arrivedSubagents = <String>[];
    final Map<String, int> subagentAttempts = <String, int>{};
    final Completer<void> exploreInitialArrived = Completer<void>();
    final Completer<void> riskArrived = Completer<void>();
    final Completer<void> riskFirstChunkFlushed = Completer<void>();
    final Completer<void> finishRiskSubagent = Completer<void>();
    String? riskInitialWire;
    Map<String, dynamic>? followUpRequest;
    Future<void>? serverDone;

    Future<void> handleRequest(HttpRequest req) async {
      final String path = req.uri.path;
      final String body = await utf8.decoder.bind(req).join();
      if (req.method != 'POST' || path != '/v1/chat/completions') {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }

      final Map<String, dynamic> request =
          jsonDecode(body) as Map<String, dynamic>;
      chatRequests.add(request);
      final List<dynamic> messages = request['messages'] as List<dynamic>;
      final String wire = jsonEncode(messages);
      final bool stream = request['stream'] == true;
      final bool isSubagent = wire.contains('Delegated task:');
      final bool isFollowUp =
          stream &&
          messages.any(
            (dynamic raw) =>
                raw is Map &&
                raw['role'] == 'tool' &&
                (raw['content'] as String).contains('delegate_subagents'),
          );

      if (isSubagent) {
        final String id = wire.contains('Risk review') ? 'risk' : 'explore';
        if (!arrivedSubagents.contains(id)) {
          arrivedSubagents.add(id);
        }
        subagentAttempts[id] = (subagentAttempts[id] ?? 0) + 1;
        final int attempt = subagentAttempts[id]!;
        if (id == 'explore' &&
            attempt == 1 &&
            !exploreInitialArrived.isCompleted) {
          exploreInitialArrived.complete();
        }
        if (id == 'risk') {
          riskInitialWire ??= wire;
          if (!riskArrived.isCompleted) riskArrived.complete();
        }
        if (id == 'explore' && attempt == 1) {
          req.response.statusCode = HttpStatus.ok;
          req.response.bufferOutput = false;
          req.response.headers.set(
            HttpHeaders.contentTypeHeader,
            'text/event-stream; charset=utf-8',
          );
          req.response.write(
            'data: ${jsonEncode(<String, dynamic>{
              'choices': <Map<String, dynamic>>[
                <String, dynamic>{
                  'delta': <String, dynamic>{
                    'tool_calls': <Map<String, dynamic>>[
                      <String, dynamic>{
                        'index': 0,
                        'id': 'call_child_search',
                        'type': 'function',
                        'function': <String, dynamic>{
                          'name': 'search_screenshots_ocr',
                          'arguments': jsonEncode(<String, dynamic>{'query': 'subagent detail rendering', 'limit': 1}),
                        },
                      },
                    ],
                  },
                  'finish_reason': 'tool_calls',
                },
              ],
              'model': 'chat-test',
            })}\n\n',
          );
          req.response.write('data: [DONE]\n\n');
          await req.response.close();
          return;
        }
        req.response.statusCode = HttpStatus.ok;
        req.response.bufferOutput = false;
        req.response.headers.set(
          HttpHeaders.contentTypeHeader,
          'text/event-stream; charset=utf-8',
        );
        if (id == 'risk') {
          req.response.write(
            'data: ${jsonEncode(<String, dynamic>{
              'choices': <Map<String, dynamic>>[
                <String, dynamic>{
                  'delta': <String, dynamic>{'content': 'Risk review: watch '},
                },
              ],
              'model': 'chat-test',
            })}\n\n',
          );
          await req.response.flush();
          if (!riskFirstChunkFlushed.isCompleted) {
            riskFirstChunkFlushed.complete();
          }
          await finishRiskSubagent.future;
          req.response.write(
            'data: ${jsonEncode(<String, dynamic>{
              'choices': <Map<String, dynamic>>[
                <String, dynamic>{
                  'delta': <String, dynamic>{'content': 'recursion and missing tests.'},
                  'finish_reason': 'stop',
                },
              ],
              'model': 'chat-test',
            })}\n\n',
          );
        } else {
          req.response.write(
            'data: ${jsonEncode(<String, dynamic>{
              'choices': <Map<String, dynamic>>[
                <String, dynamic>{
                  'delta': <String, dynamic>{'content': 'Explorer summary: subagents can split noisy work.'},
                  'finish_reason': 'stop',
                },
              ],
              'model': 'chat-test',
            })}\n\n',
          );
        }
        req.response.write('data: [DONE]\n\n');
        await req.response.close();
        return;
      }

      if (isFollowUp) {
        followUpRequest = request;
        req.response.statusCode = HttpStatus.ok;
        req.response.bufferOutput = false;
        req.response.headers.set(
          HttpHeaders.contentTypeHeader,
          'text/event-stream; charset=utf-8',
        );
        req.response.write(
          'data: ${jsonEncode(<String, dynamic>{
            'choices': <Map<String, dynamic>>[
              <String, dynamic>{
                'delta': <String, dynamic>{'content': 'Final consolidated answer from subagents.'},
                'finish_reason': 'stop',
              },
            ],
            'model': 'chat-test',
          })}\n\n',
        );
        req.response.write('data: [DONE]\n\n');
        await req.response.close();
        return;
      }

      req.response.statusCode = HttpStatus.ok;
      req.response.bufferOutput = false;
      req.response.headers.set(
        HttpHeaders.contentTypeHeader,
        'text/event-stream; charset=utf-8',
      );
      req.response.write(
        'data: ${jsonEncode(<String, dynamic>{
          'choices': <Map<String, dynamic>>[
            <String, dynamic>{
              'delta': <String, dynamic>{
                'tool_calls': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'index': 0,
                    'id': 'call_delegate_1',
                    'type': 'function',
                    'function': <String, dynamic>{
                      'name': 'delegate_subagents',
                      'arguments': jsonEncode(<String, dynamic>{
                        'reason': 'The user requested subagent mode.',
                        'tasks': <Map<String, dynamic>>[
                          <String, dynamic>{'id': 'explore', 'name': 'Explorer', 'role': 'explorer', 'task': 'Explore Codex-style child-agent behavior.'},
                          <String, dynamic>{'id': 'risk', 'name': 'Reviewer', 'role': 'reviewer', 'task': 'Risk review for recursion and regression.', 'instructions': 'Focus on functional risks.'},
                        ],
                      }),
                    },
                  },
                ],
              },
              'finish_reason': 'tool_calls',
            },
          ],
          'model': 'chat-test',
        })}\n\n',
      );
      req.response.write('data: [DONE]\n\n');
      await req.response.close();
    }

    try {
      final Directory root = Directory(p.join(tmp.path, 'root'));
      await root.create(recursive: true);
      await ScreenshotDatabase.instance.initializeForDesktop(root.path);

      serverDone = () async {
        await for (final HttpRequest req in server) {
          unawaited(handleRequest(req));
        }
      }();

      final String baseUrl = 'http://127.0.0.1:${server.port}';
      final int? providerId = await AIProvidersService.instance.createProvider(
        name: 'Subagent test provider',
        type: AIProviderTypes.openai,
        baseUrl: baseUrl,
        models: const <String>['chat-test'],
        apiKey: 'sk-test',
        isDefault: true,
      );
      expect(providerId, isNotNull);
      await ScreenshotDatabase.instance.setAIContext(
        context: 'chat',
        providerId: providerId!,
        model: 'chat-test',
      );

      final int userCreatedAtMs = DateTime.now().millisecondsSinceEpoch;
      final Future<({AIMessage completed, List<AIStreamEvent> events})> run =
          HttpOverrides.runZoned(
            () async {
              final AIStreamingSession session = await AIChatService.instance
                  .sendMessageStreamedV2WithDisplayOverride(
                    '请用子代理模式审查这个实现',
                    '请用子代理模式审查这个实现',
                    includeHistory: false,
                    persistHistory: true,
                    persistHistoryTail: true,
                    tools: AIChatService.defaultChatTools(),
                    toolChoice: 'auto',
                    conversationCid: 'cid-subagent-test',
                    uiUserCreatedAtMs: userCreatedAtMs,
                    uiAssistantCreatedAtMs: userCreatedAtMs + 1,
                  );
              final List<AIStreamEvent> events = await session.stream.toList();
              final AIMessage completed = await session.completed;
              return (completed: completed, events: events);
            },
            createHttpClient: (SecurityContext? context) {
              return _RealHttpOverrides().createHttpClient(context);
            },
          );

      await exploreInitialArrived.future.timeout(const Duration(seconds: 5));
      await riskArrived.future.timeout(const Duration(seconds: 5));
      expect(arrivedSubagents.toSet(), <String>{'explore', 'risk'});
      expect(
        riskInitialWire,
        contains('Peer subagent results available for review'),
      );
      expect(
        riskInitialWire,
        contains('Explorer summary: subagents can split noisy work.'),
      );
      expect(
        riskInitialWire,
        anyOf(
          contains('Current device-local datetime'),
          contains('当前设备本地日期时间'),
        ),
      );
      await riskFirstChunkFlushed.future.timeout(const Duration(seconds: 5));

      Future<List<AIMessage>> waitForRiskPartialHistory() async {
        for (int i = 0; i < 30; i++) {
          final List<Map<String, dynamic>> rows = await AISettingsService
              .instance
              .listSubagentConversations('cid-subagent-test');
          Map<String, dynamic>? riskRow;
          for (final Map<String, dynamic> row in rows) {
            if (((row['subagent_id'] as String?) ?? '') == 'risk') {
              riskRow = row;
              break;
            }
          }
          final String childCid = (riskRow?['cid'] as String?) ?? '';
          if (childCid.isNotEmpty) {
            final List<AIMessage> history = await AISettingsService.instance
                .getChatHistoryByCid(childCid);
            if (history.any(
              (AIMessage msg) =>
                  msg.role == 'assistant' &&
                  msg.content.contains('Risk review: watch'),
            )) {
              return history;
            }
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        return const <AIMessage>[];
      }

      final List<AIMessage> riskPartialHistory =
          await waitForRiskPartialHistory();
      expect(
        riskPartialHistory.any(
          (AIMessage msg) =>
              msg.role == 'assistant' &&
              msg.content.contains('Risk review: watch'),
        ),
        isTrue,
      );
      expect(
        riskPartialHistory.where((AIMessage msg) => msg.role == 'assistant'),
        hasLength(1),
      );
      finishRiskSubagent.complete();

      final (:completed, :events) = await run.timeout(
        const Duration(seconds: 20),
      );

      expect(completed.content, contains('Final consolidated answer'));
      expect(chatRequests, hasLength(5));
      final List<Map<String, dynamic>> subagentRequests = chatRequests
          .where(
            (Map<String, dynamic> request) =>
                jsonEncode(request['messages']).contains('Delegated task:'),
          )
          .toList(growable: false);
      expect(subagentRequests, hasLength(3));
      for (final Map<String, dynamic> request in subagentRequests) {
        expect(request['stream'], isTrue);
        expect(request.containsKey('tools'), isTrue);
        final String toolsWire = jsonEncode(request['tools']);
        expect(toolsWire, contains('search_screenshots_ocr'));
        expect(toolsWire, contains('generate_image'));
        expect(toolsWire, isNot(contains('delegate_subagents')));
        expect(toolsWire, isNot(contains('update_todos')));
      }

      expect(followUpRequest, isNotNull);
      final List<dynamic> followMessages =
          followUpRequest!['messages'] as List<dynamic>;
      final int assistantIdx = followMessages.indexWhere((dynamic raw) {
        return raw is Map &&
            raw['role'] == 'assistant' &&
            raw['tool_calls'] is List;
      });
      expect(assistantIdx, greaterThanOrEqualTo(0));
      expect(followMessages[assistantIdx + 1]['role'], 'tool');
      expect(
        followMessages[assistantIdx + 1]['tool_call_id'],
        'call_delegate_1',
      );
      final Map<String, dynamic> toolResult =
          jsonDecode(followMessages[assistantIdx + 1]['content'] as String)
              as Map<String, dynamic>;
      expect(toolResult['tool'], 'delegate_subagents');
      expect(toolResult['ok'], isTrue);
      expect(toolResult['results'], hasLength(2));
      expect(
        jsonEncode(toolResult),
        contains('Explorer summary: subagents can split noisy work.'),
      );

      final List<Map<String, dynamic>> uiPayloads = events
          .where((AIStreamEvent event) => event.kind == 'ui')
          .map(
            (AIStreamEvent event) =>
                jsonDecode(event.data) as Map<String, dynamic>,
          )
          .toList(growable: false);
      expect(
        uiPayloads.where(
          (Map<String, dynamic> payload) => payload['type'] == 'plan_update',
        ),
        isEmpty,
      );
      expect(
        uiPayloads.where(
          (Map<String, dynamic> payload) => payload['type'] == 'todo_update',
        ),
        isEmpty,
      );
      final Iterable<Map<String, dynamic>> subagentUpdates = uiPayloads.where(
        (Map<String, dynamic> payload) => payload['type'] == 'subagent_update',
      );
      expect(subagentUpdates, isNotEmpty);
      expect(
        jsonEncode(subagentUpdates.toList()),
        contains('"status":"completed"'),
      );
      expect(
        jsonEncode(subagentUpdates.toList()),
        contains('"model":"chat-test"'),
      );

      final Map<String, dynamic> uiThinking =
          jsonDecode(completed.uiThinkingJson ?? '{}') as Map<String, dynamic>;
      final String uiThinkingWire = jsonEncode(uiThinking);
      expect(uiThinkingWire, contains('"id":"explore"'));
      expect(uiThinkingWire, contains('"id":"risk"'));
      expect(uiThinkingWire, contains('"status":"completed"'));
      expect(jsonEncode(uiThinking), contains('subagents'));

      final List<Map<String, dynamic>> subagentRows = await AISettingsService
          .instance
          .listSubagentConversations('cid-subagent-test');
      expect(subagentRows, hasLength(2));
      final Set<String> subagentTitles = subagentRows
          .map((Map<String, dynamic> row) => (row['title'] as String?) ?? '')
          .toSet();
      expect(subagentTitles, containsAll(<String>{'Explorer', 'Reviewer'}));
      for (final Map<String, dynamic> row in subagentRows) {
        expect(row['conversation_kind'], 'subagent');
        expect(row['parent_cid'], 'cid-subagent-test');
        expect(row['provider_id'], providerId);
        expect(row['model'], 'chat-test');
        expect((row['subagent_context_tokens'] as int?) ?? 0, greaterThan(0));
        expect(
          (row['subagent_context_cap_tokens'] as int?) ?? 0,
          greaterThan(0),
        );

        final String childCid = (row['cid'] as String?) ?? '';
        final String subagentId = (row['subagent_id'] as String?) ?? '';
        expect(childCid, isNotEmpty);
        final List<AIMessage> childHistory = await AISettingsService.instance
            .getChatHistoryByCid(childCid);
        expect(childHistory, isNotEmpty);
        expect(childHistory.first.role, 'user');
        expect(
          childHistory.map((AIMessage msg) => msg.role),
          isNot(contains('system')),
        );
        expect(
          childHistory.map((AIMessage msg) => msg.role),
          isNot(contains('tool')),
        );
        expect(childHistory.any((AIMessage msg) => msg.role == 'user'), isTrue);
        expect(
          childHistory.any((AIMessage msg) => msg.role == 'assistant'),
          isTrue,
        );
        expect(
          childHistory.where((AIMessage msg) => msg.role == 'assistant'),
          hasLength(1),
        );
        if (subagentId == 'explore') {
          expect(
            childHistory.any(
              (AIMessage msg) =>
                  msg.role == 'assistant' &&
                  ((msg.uiThinkingJson ?? '').contains(
                    'search_screenshots_ocr',
                  )),
            ),
            isTrue,
          );
        }
      }
    } finally {
      if (!finishRiskSubagent.isCompleted) finishRiskSubagent.complete();
      await server.close(force: true);
      if (serverDone != null) {
        await serverDone.timeout(const Duration(seconds: 1), onTimeout: () {});
      }
      try {
        await ScreenshotDatabase.instance.disposeDesktop();
      } catch (_) {}
      if (await tmp.exists()) {
        await tmp.delete(recursive: true);
      }
    }
  });

  test('update_todos tool persists main-agent TODO status', () async {
    final Directory tmp = await Directory.systemTemp.createTemp(
      'screen_memo_plan_todo_tools_',
    );
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final List<Map<String, dynamic>> requests = <Map<String, dynamic>>[];
    Map<String, dynamic>? followUpRequest;
    Future<void>? serverDone;

    try {
      final Directory root = Directory(p.join(tmp.path, 'root'));
      await root.create(recursive: true);
      await ScreenshotDatabase.instance.initializeForDesktop(root.path);

      serverDone = () async {
        await for (final HttpRequest req in server) {
          final String path = req.uri.path;
          final String body = await utf8.decoder.bind(req).join();
          if (req.method != 'POST' || path != '/v1/chat/completions') {
            req.response.statusCode = HttpStatus.notFound;
            await req.response.close();
            continue;
          }

          final Map<String, dynamic> request =
              jsonDecode(body) as Map<String, dynamic>;
          requests.add(request);
          final List<dynamic> messages = request['messages'] as List<dynamic>;
          final bool isFollowUp = messages.any(
            (dynamic raw) =>
                raw is Map &&
                raw['role'] == 'tool' &&
                ((raw['content'] as String?) ?? '').contains('update_todos'),
          );

          if (isFollowUp) {
            followUpRequest = request;
            req.response.statusCode = HttpStatus.ok;
            req.response.headers.set(
              HttpHeaders.contentTypeHeader,
              'text/event-stream; charset=utf-8',
            );
            req.response.write(
              'data: ${jsonEncode(<String, dynamic>{
                'choices': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'delta': <String, dynamic>{'content': 'TODO was updated.'},
                    'finish_reason': 'stop',
                  },
                ],
                'model': 'chat-test',
              })}\n\n',
            );
            req.response.write('data: [DONE]\n\n');
            await req.response.close();
            continue;
          }

          req.response.statusCode = HttpStatus.ok;
          req.response.headers.set(
            HttpHeaders.contentTypeHeader,
            'text/event-stream; charset=utf-8',
          );
          req.response.write(
            'data: ${jsonEncode(<String, dynamic>{
              'choices': <Map<String, dynamic>>[
                <String, dynamic>{
                  'delta': <String, dynamic>{
                    'tool_calls': <Map<String, dynamic>>[
                      <String, dynamic>{
                        'index': 0,
                        'id': 'call_todo_1',
                        'type': 'function',
                        'function': <String, dynamic>{
                          'name': 'update_todos',
                          'arguments': jsonEncode(<String, dynamic>{
                            'title': 'Task TODO',
                            'items': <Map<String, dynamic>>[
                              <String, dynamic>{'id': 'subagents', 'text': 'Verify subagent delegation', 'status': 'completed'},
                              <String, dynamic>{'id': 'regression', 'text': 'Keep regression tests', 'status': 'in_progress'},
                            ],
                          }),
                        },
                      },
                    ],
                  },
                  'finish_reason': 'tool_calls',
                },
              ],
              'model': 'chat-test',
            })}\n\n',
          );
          req.response.write('data: [DONE]\n\n');
          await req.response.close();
        }
      }();

      final String baseUrl = 'http://127.0.0.1:${server.port}';
      final int? providerId = await AIProvidersService.instance.createProvider(
        name: 'TODO provider',
        type: AIProviderTypes.openai,
        baseUrl: baseUrl,
        models: const <String>['chat-test'],
        apiKey: 'sk-test',
        isDefault: true,
      );
      expect(providerId, isNotNull);
      await ScreenshotDatabase.instance.setAIContext(
        context: 'chat',
        providerId: providerId!,
        model: 'chat-test',
      );

      final int userCreatedAtMs = DateTime.now().millisecondsSinceEpoch;
      final (:completed, :events) = await HttpOverrides.runZoned(
        () async {
          final AIStreamingSession session = await AIChatService.instance
              .sendMessageStreamedV2WithDisplayOverride(
                '创建 todo 并标记进度',
                '创建 todo 并标记进度',
                includeHistory: false,
                persistHistory: true,
                persistHistoryTail: true,
                tools: AIChatService.defaultChatTools(),
                toolChoice: 'auto',
                conversationCid: 'cid-plan-todo-test',
                uiUserCreatedAtMs: userCreatedAtMs,
                uiAssistantCreatedAtMs: userCreatedAtMs + 1,
              );
          final List<AIStreamEvent> events = await session.stream.toList();
          final AIMessage completed = await session.completed;
          return (completed: completed, events: events);
        },
        createHttpClient: (SecurityContext? context) {
          return _RealHttpOverrides().createHttpClient(context);
        },
      );

      expect(completed.content, contains('TODO'));
      expect(requests, hasLength(2));
      expect(followUpRequest, isNotNull);
      final List<dynamic> followMessages =
          followUpRequest!['messages'] as List<dynamic>;
      final int assistantIdx = followMessages.indexWhere(
        (dynamic raw) =>
            raw is Map &&
            raw['role'] == 'assistant' &&
            raw['tool_calls'] is List,
      );
      expect(assistantIdx, greaterThanOrEqualTo(0));
      expect(followMessages[assistantIdx + 1]['role'], 'tool');
      expect(followMessages[assistantIdx + 1]['tool_call_id'], 'call_todo_1');

      final List<Map<String, dynamic>> uiPayloads = events
          .where((AIStreamEvent event) => event.kind == 'ui')
          .map(
            (AIStreamEvent event) =>
                jsonDecode(event.data) as Map<String, dynamic>,
          )
          .toList(growable: false);
      expect(
        uiPayloads.where(
          (Map<String, dynamic> payload) => payload['type'] == 'plan_update',
        ),
        isEmpty,
      );
      expect(
        uiPayloads.where(
          (Map<String, dynamic> payload) =>
              payload['type'] == 'todo_update' &&
              jsonEncode(payload).contains('Verify subagent delegation'),
        ),
        isNotEmpty,
      );
      final String uiThinkingWire = jsonEncode(
        jsonDecode(completed.uiThinkingJson ?? '{}'),
      );
      expect(uiThinkingWire, contains('"id":"subagents"'));
      expect(uiThinkingWire, contains('"status":"completed"'));
      expect(uiThinkingWire, isNot(contains('"type":"plan"')));
    } finally {
      await server.close(force: true);
      if (serverDone != null) {
        await serverDone.timeout(const Duration(seconds: 1), onTimeout: () {});
      }
      try {
        await ScreenshotDatabase.instance.disposeDesktop();
      } catch (_) {}
      if (await tmp.exists()) {
        await tmp.delete(recursive: true);
      }
    }
  });
}
