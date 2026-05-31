import 'package:flutter_test/flutter_test.dart';
import 'package:screen_memo/features/ai/application/provider_request_headers.dart';

void main() {
  group('ProviderRequestHeaders', () {
    test('从 extra_json 读取并规范化请求头', () {
      final entries = ProviderRequestHeaders.entriesFromExtra(<String, dynamic>{
        ProviderRequestHeaders.extraKey: <Object>[
          <String, String>{'name': 'Authorization', 'value': 'Bearer old'},
          <String, String>{'name': 'authorization', 'value': 'Bearer new'},
          <String, String>{'name': 'X-Test', 'value': '  ok  '},
          <String, String>{'name': '', 'value': ''},
        ],
      });

      expect(entries.map((entry) => entry.name), <String>[
        'authorization',
        'X-Test',
      ]);
      expect(entries.first.value, 'Bearer new');
    });

    test('解析请求头并替换 api_key 占位符', () {
      final headers = ProviderRequestHeaders.headersFromExtra(<String, dynamic>{
        ProviderRequestHeaders.extraKey: <String, String>{
          'Authorization': 'Bearer {api_key}',
          'X-Session-Id': '{uuid}',
          'X-Request-Time': '{timestamp_ms}',
          'x-empty': '',
        },
      }, apiKey: 'sk-test');

      expect(headers['Authorization'], 'Bearer sk-test');
      expect(
        headers['X-Session-Id'],
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
      expect(int.tryParse(headers['X-Request-Time'] ?? ''), isNotNull);
      expect(headers.containsKey('x-empty'), isFalse);
    });

    test('合并请求头时按大小写不敏感覆盖', () {
      final headers = ProviderRequestHeaders.mergeHeaders(
        <String, String>{
          'Content-Type': 'application/json',
          'Authorization': 'Bearer builtin',
        },
        <String, String>{
          'authorization': 'Bearer custom',
          'X-Agent': 'ScreenMemo',
        },
      );

      expect(headers['authorization'], 'Bearer custom');
      expect(headers.containsKey('Authorization'), isFalse);
      expect(headers['Content-Type'], 'application/json');
      expect(headers['X-Agent'], 'ScreenMemo');
    });

    test('写回 extra_json 时移除空请求头配置', () {
      final extra = ProviderRequestHeaders.writeEntriesToExtra(
        <String, dynamic>{'default_model': 'gpt-4o-mini'},
        const <ProviderHeaderEntry>[],
      );

      expect(extra.containsKey(ProviderRequestHeaders.extraKey), isFalse);
      expect(extra['default_model'], 'gpt-4o-mini');
    });

    test('日志脱敏会覆盖常见凭证请求头', () {
      final redacted = ProviderRequestHeaders.redactForLog(<String, String>{
        'Authorization': 'Bearer sk-test',
        'x-api-key': 'secret',
        'X-Trace': 'visible',
      });

      expect(redacted['Authorization'], 'Bearer ***');
      expect(redacted['x-api-key'], '***');
      expect(redacted['X-Trace'], 'visible');
    });

    test('Codex 模板只包含可安全复用的兼容请求头', () {
      final headers = ProviderRequestHeaders.resolveEntries(
        ProviderHeaderTemplates.codexCompatible.entries,
        apiKey: 'sk-test',
      );

      expect(headers['Authorization'], 'Bearer sk-test');
      expect(headers['originator'], 'codex_cli_rs');
      expect(headers['User-Agent'], startsWith('codex_cli_rs/'));
      expect(headers['session-id'], isNotEmpty);
      expect(headers['thread-id'], isNotEmpty);
      expect(headers['x-client-request-id'], headers['thread-id']);
      expect(headers['x-codex-window-id'], '${headers['thread-id']}:0');
      expect(headers.containsKey('OpenAI-Beta'), isFalse);
      expect(headers.containsKey('chatgpt-account-id'), isFalse);
      expect(headers.containsKey('x-codex-turn-state'), isFalse);
      expect(
        ProviderHeaderTemplates.codexCompatible.bodyStyle,
        ProviderRequestBodyStyles.codexResponses,
      );
    });

    test('Claude Code 模板包含本地实测的 API key 模式请求头', () {
      final headers = ProviderRequestHeaders.resolveEntries(
        ProviderHeaderTemplates.claudeCodeRouter.entries,
        apiKey: 'sk-ant-test',
      );

      expect(headers['Authorization'], 'Bearer sk-ant-test');
      expect(headers['x-api-key'], 'sk-ant-test');
      expect(headers['Accept'], 'application/json');
      expect(headers['anthropic-version'], '2023-06-01');
      expect(
        headers['anthropic-beta'],
        'prompt-caching-scope-2026-01-05,claude-code-20250219',
      );
      expect(headers['anthropic-dangerous-direct-browser-access'], 'true');
      expect(headers['x-app'], 'cli');
      expect(headers['User-Agent'], startsWith('claude-cli/'));
      expect(headers['X-Claude-Code-Session-Id'], isNotEmpty);
      expect(headers['x-stainless-arch'], 'x64');
      expect(headers['x-stainless-lang'], 'js');
      expect(headers['x-stainless-os'], 'Windows');
      expect(headers['x-stainless-package-version'], '0.81.0');
      expect(headers['x-stainless-retry-count'], '0');
      expect(headers['x-stainless-runtime'], 'node');
      expect(headers['x-stainless-runtime-version'], 'v24.3.0');
      expect(headers['x-stainless-timeout'], '600');
      expect(headers.containsKey('x-anthropic-billing-header'), isFalse);
      expect(headers.containsKey('x-claude-remote-session-id'), isFalse);
      expect(
        ProviderHeaderTemplates.claudeCodeRouter.bodyStyle,
        ProviderRequestBodyStyles.claudeCodeMessages,
      );
    });

    test('读写模板请求格式复用 extra_json', () {
      final extra = ProviderRequestHeaders.writeBodyStyleToExtra(
        <String, dynamic>{'default_model': 'gpt-5'},
        ProviderRequestBodyStyles.codexResponses,
      );

      expect(
        extra[ProviderRequestHeaders.bodyStyleExtraKey],
        ProviderRequestBodyStyles.codexResponses,
      );
      expect(
        ProviderRequestHeaders.bodyStyleFromExtra(extra),
        ProviderRequestBodyStyles.codexResponses,
      );

      final cleared = ProviderRequestHeaders.writeBodyStyleToExtra(
        extra,
        ProviderRequestBodyStyles.defaultStyle,
      );
      expect(
        cleared.containsKey(ProviderRequestHeaders.bodyStyleExtraKey),
        isFalse,
      );
    });
  });
}
