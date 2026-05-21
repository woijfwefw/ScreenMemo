import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_memo/features/ai/application/ai_request_gateway.dart';
import 'package:screen_memo/features/ai/application/ai_settings_service.dart';

int _countOccurrences(String haystack, String needle) {
  if (needle.isEmpty) return 0;
  int count = 0;
  int index = 0;
  while (true) {
    final int found = haystack.indexOf(needle, index);
    if (found < 0) break;
    count += 1;
    index = found + needle.length;
  }
  return count;
}

Future<void> _writeSseEvent(
  HttpResponse response,
  String type,
  Map<String, dynamic> data,
) async {
  response.write('event: $type\n');
  response.write('data: ${jsonEncode(data)}\n\n');
  await response.flush();
}

Future<void> _writeSseData(HttpResponse response, Object data) async {
  final String encoded = data is String ? data : jsonEncode(data);
  response.write('data: $encoded\n\n');
  await response.flush();
}

void main() {
  test('responses terminal events do not duplicate final content', () async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );

    final String finalText = '有，而且从你这段“去年”的记录里，我看到两类波动。';

    final Future<void> serverDone = () async {
      await for (final HttpRequest req in server) {
        if (req.method != 'POST' || req.uri.path != '/v1/responses') {
          req.response.statusCode = HttpStatus.notFound;
          await req.response.close();
          continue;
        }

        await utf8.decoder.bind(req).join();

        req.response.statusCode = HttpStatus.ok;
        req.response.headers.set(
          HttpHeaders.contentTypeHeader,
          'text/event-stream; charset=utf-8',
        );
        req.response.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');

        await Future<void>.delayed(const Duration(milliseconds: 20));

        await _writeSseEvent(
          req.response,
          'response.output_text.delta',
          <String, dynamic>{
            'type': 'response.output_text.delta',
            'output_index': 0,
            'content_index': 0,
            'delta': '有，',
          },
        );
        await _writeSseEvent(
          req.response,
          'response.output_text.delta',
          <String, dynamic>{
            'type': 'response.output_text.delta',
            'output_index': 0,
            'content_index': 0,
            'delta': '波动',
          },
        );
        await _writeSseEvent(
          req.response,
          'response.output_text.delta',
          <String, dynamic>{
            'type': 'response.output_text.delta',
            'output_index': 0,
            'content_index': 0,
            'delta': '开心',
          },
        );

        await _writeSseEvent(
          req.response,
          'response.output_text.done',
          <String, dynamic>{
            'type': 'response.output_text.done',
            'output_index': 0,
            'content_index': 0,
            'text': finalText,
          },
        );

        await _writeSseEvent(
          req.response,
          'response.content_part.done',
          <String, dynamic>{
            'type': 'response.content_part.done',
            'output_index': 0,
            'content_index': 0,
            'part': <String, dynamic>{
              'type': 'output_text',
              'text': finalText,
              'annotations': <Object>[],
            },
          },
        );

        await _writeSseEvent(
          req.response,
          'response.output_item.done',
          <String, dynamic>{
            'type': 'response.output_item.done',
            'output_index': 0,
            'item': <String, dynamic>{
              'id': 'msg_test',
              'type': 'message',
              'role': 'assistant',
              'status': 'completed',
              'content': <Map<String, dynamic>>[
                <String, dynamic>{
                  'type': 'output_text',
                  'text': finalText,
                  'annotations': <Object>[],
                },
              ],
            },
          },
        );

        await _writeSseEvent(
          req.response,
          'response.completed',
          <String, dynamic>{
            'type': 'response.completed',
            'response': <String, dynamic>{
              'id': 'resp_test',
              'usage': <String, dynamic>{
                'input_tokens': 100,
                'output_tokens': 25,
                'total_tokens': 125,
                'input_tokens_details': <String, dynamic>{'cached_tokens': 40},
              },
            },
          },
        );

        await req.response.close();
        break;
      }
    }();

    final AIEndpoint endpoint = AIEndpoint(
      groupId: null,
      baseUrl: 'http://127.0.0.1:${server.port}',
      apiKey: 'test-key',
      model: 'gpt-5.2-xhigh',
      chatPath: '/v1/responses',
      useResponseApi: true,
    );

    final AIGatewayStreamingSession session = AIRequestGateway.instance
        .startStreaming(
          endpoints: <AIEndpoint>[endpoint],
          messages: <AIMessage>[
            AIMessage(role: 'user', content: '去年我有什么感情波动吗'),
          ],
          responseStartMarker: '',
          timeout: const Duration(seconds: 5),
        );

    final Future<List<String>> contentChunksFuture = session.stream
        .where((AIGatewayEvent e) => e.kind == AIGatewayEventKind.content)
        .map((AIGatewayEvent e) => e.data)
        .toList();

    final AIGatewayResult result = await session.completed;
    final List<String> contentChunks = await contentChunksFuture;

    expect(result.content, finalText);
    expect(result.usagePromptTokens, 100);
    expect(result.usageCompletionTokens, 25);
    expect(result.usageTotalTokens, 125);
    expect(result.usageCacheHitTokens, 40);
    final String streamedText = contentChunks.join();
    expect(_countOccurrences(streamedText, finalText), 1);

    await serverDone;
    await server.close(force: true);
  });

  test(
    'chat completions stream reads usage chunk after finish_reason',
    () async {
      final HttpServer server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );

      Map<String, dynamic>? capturedBody;
      final Future<void> serverDone = () async {
        await for (final HttpRequest req in server) {
          if (req.method != 'POST' || req.uri.path != '/v1/chat/completions') {
            req.response.statusCode = HttpStatus.notFound;
            await req.response.close();
            continue;
          }

          final String body = await utf8.decoder.bind(req).join();
          capturedBody = jsonDecode(body) as Map<String, dynamic>;

          req.response.statusCode = HttpStatus.ok;
          req.response.headers.set(
            HttpHeaders.contentTypeHeader,
            'text/event-stream; charset=utf-8',
          );
          req.response.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');

          await _writeSseData(req.response, <String, dynamic>{
            'id': 'chatcmpl_test',
            'model': 'gpt-test',
            'choices': <Map<String, dynamic>>[
              <String, dynamic>{
                'index': 0,
                'delta': <String, dynamic>{'content': 'Hello'},
                'finish_reason': null,
              },
            ],
          });
          await _writeSseData(req.response, <String, dynamic>{
            'id': 'chatcmpl_test',
            'model': 'gpt-test',
            'choices': <Map<String, dynamic>>[
              <String, dynamic>{
                'index': 0,
                'delta': <String, dynamic>{},
                'finish_reason': 'stop',
              },
            ],
          });
          await _writeSseData(req.response, <String, dynamic>{
            'id': 'chatcmpl_test',
            'model': 'gpt-test',
            'choices': <Object>[],
            'usage': <String, dynamic>{
              'prompt_tokens': 11,
              'completion_tokens': 3,
              'total_tokens': 14,
              'prompt_tokens_details': <String, dynamic>{'cached_tokens': 5},
            },
          });
          await _writeSseData(req.response, '[DONE]');
          await req.response.close();
          break;
        }
      }();

      final AIEndpoint endpoint = AIEndpoint(
        groupId: null,
        baseUrl: 'http://127.0.0.1:${server.port}',
        apiKey: 'test-key',
        model: 'gpt-test',
        chatPath: '/v1/chat/completions',
        useResponseApi: false,
      );

      final AIGatewayStreamingSession session = AIRequestGateway.instance
          .startStreaming(
            endpoints: <AIEndpoint>[endpoint],
            messages: <AIMessage>[AIMessage(role: 'user', content: 'hello')],
            responseStartMarker: '',
            timeout: const Duration(seconds: 5),
          );

      final Future<List<String>> contentChunksFuture = session.stream
          .where((AIGatewayEvent e) => e.kind == AIGatewayEventKind.content)
          .map((AIGatewayEvent e) => e.data)
          .toList();

      final AIGatewayResult result = await session.completed;
      final List<String> contentChunks = await contentChunksFuture;

      expect(contentChunks.join(), 'Hello');
      expect(result.content, 'Hello');
      expect(result.usagePromptTokens, 11);
      expect(result.usageCompletionTokens, 3);
      expect(result.usageTotalTokens, 14);
      expect(result.usageCacheHitTokens, 5);
      expect(
        (capturedBody?['stream_options'] as Map?)?['include_usage'],
        isTrue,
      );

      await serverDone;
      await server.close(force: true);
    },
  );
}
