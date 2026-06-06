part of 'ai_chat_service.dart';

extension AIChatServiceAgentStatusExt on AIChatService {
  static Map<String, dynamic> buildUpdateTodosToolSchema() {
    return <String, dynamic>{
      'type': 'function',
      'function': <String, dynamic>{
        'name': 'update_todos',
        'description':
            'Create or update the visible task TODO list for the main agent. Use this only when the user asks for TODOs or when the task is complex enough to benefit from explicit progress tracking. Max 6 items. This updates UI state only.',
        'parameters': <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'title': <String, dynamic>{
              'type': 'string',
              'description': 'Optional TODO title. Default TODO.',
            },
            'items': <String, dynamic>{
              'type': 'array',
              'minItems': 1,
              'maxItems': 6,
              'description': 'TODO items in display order. Max 6.',
              'items': <String, dynamic>{
                'type': 'object',
                'properties': <String, dynamic>{
                  'id': <String, dynamic>{
                    'type': 'string',
                    'description': 'Stable short id for the TODO item.',
                  },
                  'text': <String, dynamic>{
                    'type': 'string',
                    'description': 'Concrete TODO text.',
                  },
                  'status': <String, dynamic>{
                    'type': 'string',
                    'enum': <String>[
                      'pending',
                      'in_progress',
                      'completed',
                      'blocked',
                    ],
                    'description': 'Current TODO status.',
                  },
                },
                'required': <String>['text', 'status'],
              },
            },
          },
          'required': <String>['items'],
        },
      },
    };
  }

  void _emitTodoUpdate(
    void Function(AIStreamEvent event)? emitEvent, {
    required List<Map<String, dynamic>> items,
    String title = 'TODO',
  }) {
    _emitUi(emitEvent, <String, dynamic>{
      'type': 'todo_update',
      'title': title,
      'items': items,
    });
  }

  void _emitSubagentUpdate(
    void Function(AIStreamEvent event)? emitEvent, {
    required List<Map<String, dynamic>> agents,
    String title = 'Subagents',
  }) {
    _emitUi(emitEvent, <String, dynamic>{
      'type': 'subagent_update',
      'title': title,
      'agents': agents,
    });
  }

  bool _isAgentStatusTool(AIToolCall call) {
    final String name = call.name.trim();
    return name == 'update_todos';
  }

  Future<List<AIMessage>> _executeAgentStatusToolCall(
    AIToolCall call, {
    required void Function(AIStreamEvent event)? emitEvent,
  }) async {
    final Map<String, dynamic> args = _safeJsonObject(call.argumentsJson);
    final List<Map<String, dynamic>> items = _normalizeTodoItems(args['items']);
    if (items.isEmpty) {
      return _agentStatusToolResult(
        call,
        ok: false,
        error: 'invalid_todo_items',
      );
    }
    final String title = ((args['title'] as String?) ?? '').trim().isEmpty
        ? 'TODO'
        : (args['title'] as String).trim();
    _emitTodoUpdate(emitEvent, title: title, items: items);
    return _agentStatusToolResult(
      call,
      ok: true,
      extra: <String, dynamic>{
        'tool': 'update_todos',
        'title': title,
        'count': items.length,
        'items': items,
      },
    );
  }

  List<Map<String, dynamic>> _normalizeTodoItems(Object? raw) {
    if (raw is! List) return const <Map<String, dynamic>>[];
    final List<Map<String, dynamic>> items = <Map<String, dynamic>>[];
    for (final dynamic item in raw.take(6)) {
      if (item is! Map) continue;
      final Map<String, dynamic> map = Map<String, dynamic>.from(item);
      final String text =
          (map['text'] ?? map['task'] ?? map['description'] ?? '')
              .toString()
              .trim();
      if (text.isEmpty) continue;
      final String idRaw = (map['id'] ?? '').toString().trim();
      final String id = idRaw.isEmpty
          ? 'todo_${items.length + 1}'
          : _normalizeAgentStatusId(idRaw);
      items.add(<String, dynamic>{
        'id': id.isEmpty ? 'todo_${items.length + 1}' : id,
        'text': text,
        'status': _normalizeAgentStatusValue(map['status']),
      });
    }
    return items;
  }

  List<AIMessage> _agentStatusToolResult(
    AIToolCall call, {
    required bool ok,
    String? error,
    Map<String, dynamic> extra = const <String, dynamic>{},
  }) {
    return <AIMessage>[
      AIMessage(
        role: 'tool',
        toolCallId: call.id,
        content: jsonEncode(<String, dynamic>{
          'tool': call.name,
          'ok': ok,
          if ((error ?? '').trim().isNotEmpty) 'error': error,
          ...extra,
        }),
      ),
    ];
  }

  String _normalizeAgentStatusValue(Object? raw) {
    final String value = (raw ?? '').toString().trim().toLowerCase();
    return switch (value) {
      'in_progress' || 'working' || 'running' => 'in_progress',
      'completed' || 'complete' || 'done' => 'completed',
      'blocked' || 'failed' => 'blocked',
      _ => 'pending',
    };
  }

  String _normalizeAgentStatusId(String raw) {
    final String normalized = raw
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    return normalized.length <= 48 ? normalized : normalized.substring(0, 48);
  }
}
