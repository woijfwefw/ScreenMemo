import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_memo/features/ai/application/ai_request_gateway.dart';
import 'package:screen_memo/features/ai/application/ai_settings_service.dart';

void main() {
  test('AIMessage keeps local evidence paths out of provider JSON', () {
    final AIMessage message = AIMessage(
      role: 'assistant',
      content:
          'See [evidence: /data/user/0/app/files/output/screen/pkg/2026-05/25/demo.webp] '
          r'and [evidence: C:\Users\me\Screen Memo\demo 2.webp] '
          'and [evidence: demo3.webp].',
      reasoningContent:
          'Reasoning [evidence: /data/user/0/app/files/output/screen/pkg/demo4.webp]',
    );

    final Map<String, dynamic> json = message.toJson();

    expect(
      json['content'],
      r'See [evidence: demo.webp] and [evidence: demo 2.webp] and [evidence: demo3.webp].',
    );
    expect(json['reasoning_content'], 'Reasoning [evidence: demo4.webp]');
    expect(
      message.content,
      contains('/data/user/0/app/files/output/screen/pkg/2026-05/25/demo.webp'),
    );
  });

  test('AIMessage resolves basename evidence refs to local absolute paths', () {
    final String updated = AIMessage.resolveEvidenceRefsToLocalPaths(
      r'See [evidence: demo.webp] and [evidence: C:\already\absolute.webp].',
      <String, String>{
        'demo.webp':
            '/data/user/0/app/files/output/screen/pkg/2026-05/25/demo.webp',
        'absolute.webp': '/should/not/use.webp',
      },
    );

    expect(
      updated,
      r'See [evidence: /data/user/0/app/files/output/screen/pkg/2026-05/25/demo.webp] and [evidence: C:\already\absolute.webp].',
    );
  });

  test('AIMessage resolves multiple basename evidence refs in one marker', () {
    final String updated = AIMessage.resolveEvidenceRefsToLocalPaths(
      'See [evidence: a.webp, b.webp c.webp].',
      <String, String>{
        'a.webp': '/data/user/0/app/files/output/a.webp',
        'b.webp': '/data/user/0/app/files/output/b.webp',
      },
    );

    expect(
      updated,
      'See [evidence: /data/user/0/app/files/output/a.webp] [evidence: /data/user/0/app/files/output/b.webp] [evidence: c.webp].',
    );
  });

  test('AIMessage sanitizes structured text parts without changing images', () {
    final AIMessage message = AIMessage(
      role: 'user',
      content: 'fallback',
      apiContent: const <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'text',
          'text': '[evidence: /data/user/0/app/files/a.webp]',
        },
        <String, dynamic>{
          'type': 'image_url',
          'image_url': <String, dynamic>{'url': 'data:image/png;base64,AAAA'},
        },
      ],
    );

    final Map<String, dynamic> json = message.toJson();
    final List<dynamic> content = json['content'] as List<dynamic>;
    final Map<String, dynamic> textPart = content.first as Map<String, dynamic>;
    final Map<String, dynamic> imagePart = content.last as Map<String, dynamic>;

    expect(textPart['text'], '[evidence: a.webp]');
    expect(
      (imagePart['image_url'] as Map<String, dynamic>)['url'],
      'data:image/png;base64,AAAA',
    );
  });

  test('assistant tool call message serializes reasoning_content', () {
    final AIMessage message = AIMessage(
      role: 'assistant',
      content: '',
      reasoningContent: 'model reasoning',
      toolCalls: const <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'call_1',
          'type': 'function',
          'function': <String, dynamic>{
            'name': 'search_segments',
            'arguments': '{}',
          },
        },
      ],
    );

    final Map<String, dynamic> json = message.toJson();

    expect(json['content'], isNull);
    expect(json['reasoning_content'], 'model reasoning');
    expect(json['tool_calls'], isA<List<dynamic>>());
  });

  test(
    'OpenAI chat completions payload sends xhigh reasoning effort',
    () async {
      final HttpServer server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      Map<String, dynamic>? captured;

      final Future<void> serverDone = () async {
        await for (final HttpRequest req in server) {
          captured =
              jsonDecode(await utf8.decoder.bind(req).join())
                  as Map<String, dynamic>;
          req.response.statusCode = HttpStatus.ok;
          req.response.headers.contentType = ContentType.json;
          req.response.write(
            jsonEncode(<String, dynamic>{
              'choices': <Map<String, dynamic>>[
                <String, dynamic>{
                  'message': <String, dynamic>{
                    'role': 'assistant',
                    'content': 'ok',
                  },
                },
              ],
            }),
          );
          await req.response.close();
          break;
        }
      }();

      final AIGatewayResult result = await AIRequestGateway.instance.complete(
        endpoints: <AIEndpoint>[
          AIEndpoint(
            groupId: null,
            providerType: 'openai',
            baseUrl: 'http://127.0.0.1:${server.port}',
            apiKey: 'test-key',
            model: 'gpt-5.5',
            chatPath: '/v1/chat/completions',
          ),
        ],
        messages: <AIMessage>[AIMessage(role: 'user', content: 'hello')],
        responseStartMarker: '',
        preferStreaming: false,
        reasoningLevel: AIReasoningLevel.xhigh,
        trackKeyStats: false,
      );

      await serverDone;
      await server.close(force: true);

      expect(result.content, 'ok');
      expect(captured!['reasoning_effort'], 'xhigh');
    },
  );

  test('DeepSeek chat completions payload preserves tool reasoning', () async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    Map<String, dynamic>? captured;

    final Future<void> serverDone = () async {
      await for (final HttpRequest req in server) {
        captured =
            jsonDecode(await utf8.decoder.bind(req).join())
                as Map<String, dynamic>;
        req.response.statusCode = HttpStatus.ok;
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode(<String, dynamic>{
            'choices': <Map<String, dynamic>>[
              <String, dynamic>{
                'message': <String, dynamic>{
                  'role': 'assistant',
                  'content': 'ok',
                },
              },
            ],
            'usage': <String, dynamic>{
              'prompt_tokens': 10,
              'completion_tokens': 2,
              'total_tokens': 12,
              'prompt_cache_hit_tokens': 4,
              'prompt_cache_miss_tokens': 6,
            },
          }),
        );
        await req.response.close();
        break;
      }
    }();

    final AIGatewayResult result = await AIRequestGateway.instance.complete(
      endpoints: <AIEndpoint>[
        AIEndpoint(
          groupId: null,
          providerType: 'deepseek',
          baseUrl: 'http://127.0.0.1:${server.port}',
          apiKey: 'test-key',
          model: 'deepseek-v4-pro',
          chatPath: '/v1/chat/completions',
        ),
      ],
      messages: <AIMessage>[
        AIMessage(role: 'user', content: 'call a tool'),
        AIMessage(
          role: 'assistant',
          content: '',
          toolCalls: const <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'call_1',
              'type': 'function',
              'function': <String, dynamic>{
                'name': 'search_segments',
                'arguments': '{}',
              },
            },
          ],
        ),
        AIMessage(role: 'tool', content: '{}', toolCallId: 'call_1'),
      ],
      responseStartMarker: '',
      preferStreaming: false,
      reasoningLevel: AIReasoningLevel.high,
      trackKeyStats: false,
    );

    await serverDone;
    await server.close(force: true);

    expect(result.content, 'ok');
    expect(result.usageCacheHitTokens, 4);
    expect(result.usageCacheMissTokens, 6);

    final Map<String, dynamic> payload = captured!;
    expect(payload['thinking'], <String, dynamic>{'type': 'enabled'});
    expect(payload['reasoning_effort'], 'high');
    final List<dynamic> messages = payload['messages'] as List<dynamic>;
    final Map<String, dynamic> assistant = messages[1] as Map<String, dynamic>;
    expect(assistant['tool_calls'], isA<List<dynamic>>());
    expect(assistant.containsKey('reasoning_content'), isTrue);
    expect(assistant['reasoning_content'], '');
  });

  test(
    'chat completions payload stabilizes tool order and schema keys',
    () async {
      final HttpServer server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      String capturedBody = '';

      final Future<void> serverDone = () async {
        await for (final HttpRequest req in server) {
          capturedBody = await utf8.decoder.bind(req).join();
          req.response.statusCode = HttpStatus.ok;
          req.response.headers.contentType = ContentType.json;
          req.response.write(
            jsonEncode(<String, dynamic>{
              'choices': <Map<String, dynamic>>[
                <String, dynamic>{
                  'message': <String, dynamic>{
                    'role': 'assistant',
                    'content': 'ok',
                  },
                },
              ],
            }),
          );
          await req.response.close();
          break;
        }
      }();

      final List<Map<String, dynamic>> tools = <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'function',
          'function': <String, dynamic>{
            'name': 'z_tool',
            'description': 'Z',
            'parameters': <String, dynamic>{
              'type': 'object',
              'properties': <String, dynamic>{
                'z': <String, dynamic>{'type': 'string'},
                'a': <String, dynamic>{'type': 'string'},
              },
            },
          },
        },
        <String, dynamic>{
          'type': 'function',
          'function': <String, dynamic>{
            'name': 'a_tool',
            'description': 'A',
            'parameters': <String, dynamic>{
              'type': 'object',
              'properties': <String, dynamic>{
                'b': <String, dynamic>{'type': 'string'},
                'a': <String, dynamic>{'type': 'string'},
              },
            },
          },
        },
      ];

      final AIGatewayResult result = await AIRequestGateway.instance.complete(
        endpoints: <AIEndpoint>[
          AIEndpoint(
            groupId: null,
            providerType: 'openai',
            baseUrl: 'http://127.0.0.1:${server.port}',
            apiKey: 'test-key',
            model: 'gpt-4.1',
            chatPath: '/v1/chat/completions',
          ),
        ],
        messages: <AIMessage>[AIMessage(role: 'user', content: 'hello')],
        responseStartMarker: '',
        preferStreaming: false,
        tools: tools,
        trackKeyStats: false,
      );

      await serverDone;
      await server.close(force: true);

      expect(result.content, 'ok');
      expect(
        capturedBody.indexOf('"name":"a_tool"'),
        lessThan(capturedBody.indexOf('"name":"z_tool"')),
      );
      expect(
        capturedBody.indexOf('"a":{"type":"string"}'),
        lessThan(capturedBody.indexOf('"b":{"type":"string"}')),
      );
    },
  );

  test(
    'prompt_cache_key is not sent to non-official OpenAI endpoints',
    () async {
      final HttpServer server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      Map<String, dynamic>? captured;

      final Future<void> serverDone = () async {
        await for (final HttpRequest req in server) {
          captured =
              jsonDecode(await utf8.decoder.bind(req).join())
                  as Map<String, dynamic>;
          req.response.statusCode = HttpStatus.ok;
          req.response.headers.contentType = ContentType.json;
          req.response.write(
            jsonEncode(<String, dynamic>{
              'choices': <Map<String, dynamic>>[
                <String, dynamic>{
                  'message': <String, dynamic>{
                    'role': 'assistant',
                    'content': 'ok',
                  },
                },
              ],
            }),
          );
          await req.response.close();
          break;
        }
      }();

      final AIGatewayResult result = await AIRequestGateway.instance.complete(
        endpoints: <AIEndpoint>[
          AIEndpoint(
            groupId: null,
            providerType: 'openai',
            baseUrl: 'http://127.0.0.1:${server.port}',
            apiKey: 'test-key',
            model: 'gpt-4.1',
            chatPath: '/v1/chat/completions',
          ),
        ],
        messages: <AIMessage>[AIMessage(role: 'user', content: 'hello')],
        responseStartMarker: '',
        preferStreaming: false,
        promptCacheKey: 'screenmemo_test_bucket',
        trackKeyStats: false,
      );

      await serverDone;
      await server.close(force: true);

      expect(result.content, 'ok');
      expect(captured!.containsKey('prompt_cache_key'), isFalse);
    },
  );

  test(
    'usageMetadata includes Gemini thoughts and cached content tokens',
    () async {
      final HttpServer server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );

      final Future<void> serverDone = () async {
        await for (final HttpRequest req in server) {
          await utf8.decoder.bind(req).join();
          req.response.statusCode = HttpStatus.ok;
          req.response.headers.contentType = ContentType.json;
          req.response.write(
            jsonEncode(<String, dynamic>{
              'choices': <Map<String, dynamic>>[
                <String, dynamic>{
                  'message': <String, dynamic>{
                    'role': 'assistant',
                    'content': 'ok',
                  },
                },
              ],
              'usageMetadata': <String, dynamic>{
                'promptTokenCount': 10,
                'candidatesTokenCount': 3,
                'thoughtsTokenCount': 7,
                'cachedContentTokenCount': 4,
                'totalTokenCount': 20,
              },
            }),
          );
          await req.response.close();
          break;
        }
      }();

      final AIGatewayResult result = await AIRequestGateway.instance.complete(
        endpoints: <AIEndpoint>[
          AIEndpoint(
            groupId: null,
            providerType: 'openai',
            baseUrl: 'http://127.0.0.1:${server.port}',
            apiKey: 'test-key',
            model: 'gemini-compatible',
            chatPath: '/v1/chat/completions',
          ),
        ],
        messages: <AIMessage>[AIMessage(role: 'user', content: 'hello')],
        responseStartMarker: '',
        preferStreaming: false,
        trackKeyStats: false,
      );

      await serverDone;
      await server.close(force: true);

      expect(result.content, 'ok');
      expect(result.usagePromptTokens, 10);
      expect(result.usageCompletionTokens, 10);
      expect(result.usageTotalTokens, 20);
      expect(result.usageCacheHitTokens, 4);
    },
  );

  test(
    'Anthropic usage adds cache read and creation tokens to input',
    () async {
      final HttpServer server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );

      final Future<void> serverDone = () async {
        await for (final HttpRequest req in server) {
          await utf8.decoder.bind(req).join();
          req.response.statusCode = HttpStatus.ok;
          req.response.headers.contentType = ContentType.json;
          req.response.write(
            jsonEncode(<String, dynamic>{
              'choices': <Map<String, dynamic>>[
                <String, dynamic>{
                  'message': <String, dynamic>{
                    'role': 'assistant',
                    'content': 'ok',
                  },
                },
              ],
              'usage': <String, dynamic>{
                'input_tokens': 11,
                'cache_read_input_tokens': 5,
                'cache_creation_input_tokens': 7,
                'output_tokens': 13,
              },
            }),
          );
          await req.response.close();
          break;
        }
      }();

      final AIGatewayResult result = await AIRequestGateway.instance.complete(
        endpoints: <AIEndpoint>[
          AIEndpoint(
            groupId: null,
            providerType: 'openai',
            baseUrl: 'http://127.0.0.1:${server.port}',
            apiKey: 'test-key',
            model: 'claude-compatible',
            chatPath: '/v1/chat/completions',
          ),
        ],
        messages: <AIMessage>[AIMessage(role: 'user', content: 'hello')],
        responseStartMarker: '',
        preferStreaming: false,
        trackKeyStats: false,
      );

      await serverDone;
      await server.close(force: true);

      expect(result.content, 'ok');
      expect(result.usagePromptTokens, 23);
      expect(result.usageCompletionTokens, 13);
      expect(result.usageTotalTokens, 36);
      expect(result.usageCacheHitTokens, 5);
      expect(result.usageCacheMissTokens, 7);
    },
  );
}
