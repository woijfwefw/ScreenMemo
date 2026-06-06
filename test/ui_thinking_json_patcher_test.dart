import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_memo/features/ai/application/ui_thinking_json_patcher.dart';

void main() {
  test(
    'patchUiThinkingJsonWithToolUiEvent creates v2 base and upserts tool chips',
    () {
      final String? out = patchUiThinkingJsonWithToolUiEvent(
        null,
        <String, dynamic>{
          'type': 'tool_batch_begin',
          'tools': <Map<String, dynamic>>[
            <String, dynamic>{
              'call_id': 'c1',
              'tool_name': 'search_segments',
              'label': 'Search',
              'app_names': <String>['AppA'],
            },
          ],
        },
        assistantCreatedAtMs: 123,
        toolsTitle: 'Tools',
      );

      expect(out, isNotNull);
      final Map<String, dynamic> decoded =
          jsonDecode(out!) as Map<String, dynamic>;
      expect(decoded['v'], 2);
      final List<dynamic> blocks = decoded['blocks'] as List<dynamic>;
      expect(blocks.length, 1);
      final Map<String, dynamic> b0 = blocks.first as Map<String, dynamic>;
      final List<dynamic> events = b0['events'] as List<dynamic>;
      expect(events.isNotEmpty, true);
      final Map<String, dynamic> e0 = events.last as Map<String, dynamic>;
      expect(e0['type'], 'tools');
      expect(e0['title'], 'Tools');
      final List<dynamic> tools = e0['tools'] as List<dynamic>;
      expect(tools.length, 1);
      final Map<String, dynamic> chip = tools.first as Map<String, dynamic>;
      expect(chip['call_id'], 'c1');
      expect(chip['tool_name'], 'search_segments');
      expect(chip['label'], 'Search');
      expect(chip['active'], true);
    },
  );

  test(
    'patchUiThinkingJsonWithToolUiEvent marks tool_call_end inactive and stores summary',
    () {
      final String base = patchUiThinkingJsonWithToolUiEvent(
        null,
        <String, dynamic>{
          'type': 'tool_batch_begin',
          'tools': <Map<String, dynamic>>[
            <String, dynamic>{
              'call_id': 'c1',
              'tool_name': 'search_segments',
              'label': 'Search',
            },
          ],
        },
        assistantCreatedAtMs: 123,
        toolsTitle: 'Tools',
      )!;

      final String out = patchUiThinkingJsonWithToolUiEvent(
        base,
        <String, dynamic>{
          'type': 'tool_call_end',
          'call_id': 'c1',
          'tool_name': 'search_segments',
          'result_summary': 'count=2',
        },
        assistantCreatedAtMs: 123,
        toolsTitle: 'Tools',
      )!;

      final Map<String, dynamic> decoded =
          jsonDecode(out) as Map<String, dynamic>;
      final List<dynamic> blocks = decoded['blocks'] as List<dynamic>;
      final Map<String, dynamic> b0 = blocks.first as Map<String, dynamic>;
      final List<dynamic> events = b0['events'] as List<dynamic>;
      final Map<String, dynamic> e0 = events.last as Map<String, dynamic>;
      final List<dynamic> tools = e0['tools'] as List<dynamic>;
      final Map<String, dynamic> chip = tools.first as Map<String, dynamic>;
      expect(chip['active'], false);
      expect(chip['result_summary'], 'count=2');
    },
  );

  test('patchUiThinkingJsonWithToolUiEvent preserves seg_lens', () {
    final String seeded = jsonEncode(<String, dynamic>{
      'v': 2,
      'blocks': <Map<String, dynamic>>[
        <String, dynamic>{'created_at': 10, 'events': <Map<String, dynamic>>[]},
      ],
      'seg_lens': <int>[3, 4],
    });

    final String out = patchUiThinkingJsonWithToolUiEvent(
      seeded,
      <String, dynamic>{
        'type': 'tool_batch_begin',
        'tools': <Map<String, dynamic>>[
          <String, dynamic>{'call_id': 'c1', 'tool_name': 't'},
        ],
      },
      assistantCreatedAtMs: 10,
      toolsTitle: 'Tools',
    )!;

    final Map<String, dynamic> decoded =
        jsonDecode(out) as Map<String, dynamic>;
    expect(decoded['seg_lens'], <dynamic>[3, 4]);
  });

  test(
    'patchUiThinkingJsonWithToolUiEvent returns original on invalid json',
    () {
      final String raw = '{not json';
      expect(
        patchUiThinkingJsonWithToolUiEvent(
          raw,
          <String, dynamic>{
            'type': 'tool_call_end',
            'call_id': 'c1',
            'tool_name': 't',
          },
          assistantCreatedAtMs: 1,
          toolsTitle: 'Tools',
        ),
        raw,
      );
    },
  );

  test('patchUiThinkingJsonWithToolUiEvent upserts plan steps', () {
    final String out = patchUiThinkingJsonWithToolUiEvent(
      null,
      <String, dynamic>{
        'type': 'plan_update',
        'steps': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'inspect',
            'step': 'Inspect repository',
            'status': 'completed',
          },
          <String, dynamic>{
            'id': 'test',
            'step': 'Add functional tests',
            'status': 'in_progress',
          },
        ],
      },
      assistantCreatedAtMs: 123,
      toolsTitle: 'Tools',
    )!;

    final Map<String, dynamic> decoded =
        jsonDecode(out) as Map<String, dynamic>;
    final List<dynamic> events =
        (decoded['blocks'] as List).first['events'] as List<dynamic>;
    final Map<String, dynamic> plan = events.last as Map<String, dynamic>;
    expect(plan['type'], 'plan');
    expect(plan['items'], hasLength(2));
    expect(plan['items'][1]['status'], 'in_progress');
  });

  test('patchUiThinkingJsonWithToolUiEvent upserts todo items by id', () {
    final String base = patchUiThinkingJsonWithToolUiEvent(
      null,
      <String, dynamic>{
        'type': 'todo_update',
        'items': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'split_gateway',
            'text': 'Split gateway file',
            'status': 'pending',
          },
        ],
      },
      assistantCreatedAtMs: 123,
      toolsTitle: 'Tools',
    )!;

    final String out = patchUiThinkingJsonWithToolUiEvent(
      base,
      <String, dynamic>{
        'type': 'todo_update',
        'items': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'split_gateway',
            'text': 'Split gateway file',
            'status': 'completed',
          },
        ],
      },
      assistantCreatedAtMs: 123,
      toolsTitle: 'Tools',
    )!;

    final Map<String, dynamic> decoded =
        jsonDecode(out) as Map<String, dynamic>;
    final List<dynamic> events =
        (decoded['blocks'] as List).first['events'] as List<dynamic>;
    final Map<String, dynamic> todo = events.last as Map<String, dynamic>;
    expect(todo['type'], 'todo');
    expect(todo['items'], hasLength(1));
    expect(todo['items'][0]['status'], 'completed');
  });

  test('patchUiThinkingJsonWithToolUiEvent stores subagent states', () {
    final String out = patchUiThinkingJsonWithToolUiEvent(
      null,
      <String, dynamic>{
        'type': 'subagent_update',
        'agents': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'agent_a',
            'name': 'Retriever',
            'status': 'working',
            'summary': 'Searching screenshots',
            'conversation_cid': 'child-cid',
            'context_tokens_estimate': 321,
            'context_cap_tokens': 4096,
            'context_percent': 8,
          },
        ],
      },
      assistantCreatedAtMs: 123,
      toolsTitle: 'Tools',
    )!;

    final Map<String, dynamic> decoded =
        jsonDecode(out) as Map<String, dynamic>;
    final List<dynamic> events =
        (decoded['blocks'] as List).first['events'] as List<dynamic>;
    final Map<String, dynamic> subagents = events.last as Map<String, dynamic>;
    expect(subagents['type'], 'subagents');
    expect(subagents['items'][0]['name'], 'Retriever');
    expect(subagents['items'][0]['summary'], 'Searching screenshots');
    expect(subagents['items'][0]['conversation_cid'], 'child-cid');
    expect(subagents['items'][0]['context_tokens_estimate'], 321);
    expect(subagents['items'][0]['context_cap_tokens'], 4096);
    expect(subagents['items'][0]['context_percent'], 8);
  });
}
