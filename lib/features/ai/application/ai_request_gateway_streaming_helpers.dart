part of 'ai_request_gateway.dart';

String _deltaFromPossiblyCumulative({
  required String previous,
  required String incoming,
}) {
  if (incoming.isEmpty) return '';
  if (previous.isEmpty) return incoming;
  if (incoming.startsWith(previous)) {
    return incoming.substring(previous.length);
  }
  if (previous.startsWith(incoming)) {
    return '';
  }
  return incoming;
}

String _updateCumulativeProbe({
  required String previous,
  required String incoming,
}) {
  if (incoming.isEmpty) return previous;
  if (previous.isEmpty) return incoming;
  if (incoming.startsWith(previous)) {
    return incoming;
  }
  if (previous.startsWith(incoming)) {
    return previous;
  }
  return previous + incoming;
}

String _deltaFromTerminalFull({
  required String previous,
  required String fullText,
}) {
  if (fullText.isEmpty) return '';
  if (previous.isEmpty) return fullText;
  if (fullText.startsWith(previous)) {
    return fullText.substring(previous.length);
  }
  return fullText;
}

class _ToolCallDraft {
  _ToolCallDraft(this.index);

  final int index;
  String id = '';
  String name = '';
  final StringBuffer arguments = StringBuffer();

  void mergeFromChunk(Map<String, dynamic> chunk) {
    final String idPart = (chunk['id'] as String?) ?? '';
    if (idPart.trim().isNotEmpty) {
      id = idPart.trim();
    }
    final Map<String, dynamic>? fn = chunk['function'] is Map
        ? Map<String, dynamic>.from(chunk['function'] as Map)
        : null;
    final String namePart =
        (fn?['name'] as String?) ?? (chunk['name'] as String?) ?? '';
    if (namePart.trim().isNotEmpty) {
      name = namePart.trim();
    }
    final String argsPart =
        (fn?['arguments'] as String?) ?? (chunk['arguments'] as String?) ?? '';
    if (argsPart.isNotEmpty) {
      arguments.write(argsPart);
    }
  }

  AIToolCall? toToolCall(String Function() newId) {
    if (name.trim().isEmpty) return null;
    final String resolvedId = id.trim().isEmpty ? newId() : id.trim();
    return AIToolCall(
      id: resolvedId,
      name: name.trim(),
      argumentsJson: arguments.toString(),
    );
  }
}

class _ToolCallAccumulator {
  _ToolCallAccumulator(this._newId);

  final String Function() _newId;
  final Map<int, _ToolCallDraft> _drafts = <int, _ToolCallDraft>{};

  void ingestChatDelta(Map<String, dynamic> delta) {
    final dynamic toolCalls = delta['tool_calls'] ?? delta['toolCalls'];
    if (toolCalls is List) {
      for (int i = 0; i < toolCalls.length; i += 1) {
        final dynamic raw = toolCalls[i];
        if (raw is! Map) continue;
        final Map<String, dynamic> chunk = Map<String, dynamic>.from(raw);
        final dynamic idxRaw = chunk['index'];
        final int idx = idxRaw is int ? idxRaw : i;
        final _ToolCallDraft draft = _drafts.putIfAbsent(
          idx,
          () => _ToolCallDraft(idx),
        );
        draft.mergeFromChunk(chunk);
      }
    }

    final dynamic functionCall =
        delta['function_call'] ?? delta['functionCall'];
    if (functionCall is Map) {
      final Map<String, dynamic> chunk = Map<String, dynamic>.from(
        functionCall,
      );
      final _ToolCallDraft draft = _drafts.putIfAbsent(
        0,
        () => _ToolCallDraft(0),
      );
      draft.mergeFromChunk(chunk);
    }
  }

  List<AIToolCall> finalize() {
    if (_drafts.isEmpty) return const <AIToolCall>[];
    final List<int> indices = _drafts.keys.toList()..sort();
    final List<AIToolCall> out = <AIToolCall>[];
    for (final int idx in indices) {
      final _ToolCallDraft? draft = _drafts[idx];
      if (draft == null) continue;
      final AIToolCall? call = draft.toToolCall(_newId);
      if (call != null) {
        out.add(call);
      }
    }
    return out;
  }
}

String _extractOpenAIChatText(dynamic node) {
  if (node == null) return '';
  if (node is String) return node;
  if (node is Map) {
    final Map<String, dynamic> map = Map<String, dynamic>.from(node);
    final String type = (map['type'] as String?) ?? '';
    final String text = (map['text'] as String?) ?? '';
    if (text.isNotEmpty) {
      if (type.isEmpty ||
          type == 'text' ||
          type == 'output_text' ||
          type == 'input_text') {
        return text;
      }
    }
    final String fromContent = _extractOpenAIChatText(map['content']);
    if (fromContent.isNotEmpty) return fromContent;
    final String fromParts = _extractOpenAIChatText(map['parts']);
    if (fromParts.isNotEmpty) return fromParts;
    return '';
  }
  if (node is List) {
    final StringBuffer out = StringBuffer();
    for (final dynamic item in node) {
      final String piece = _extractOpenAIChatText(item);
      if (piece.isNotEmpty) out.write(piece);
    }
    return out.toString();
  }
  return '';
}

class _ThinkStreamFilterResult {
  const _ThinkStreamFilterResult(this.visibleDelta, this.reasoningDelta);

  final String visibleDelta;
  final String reasoningDelta;
}

class _ThinkStreamFilter {
  bool _insideThink = false;

  _ThinkStreamFilterResult process(String chunk) {
    if (chunk.isEmpty) return const _ThinkStreamFilterResult('', '');
    final StringBuffer visible = StringBuffer();
    final StringBuffer reasoning = StringBuffer();
    int index = 0;
    while (index < chunk.length) {
      if (_insideThink) {
        final int closeIdx = chunk.indexOf('</think>', index);
        if (closeIdx == -1) {
          reasoning.write(chunk.substring(index));
          index = chunk.length;
          break;
        } else {
          reasoning.write(chunk.substring(index, closeIdx));
          index = closeIdx + 8;
          _insideThink = false;
        }
      } else {
        final int openIdx = chunk.indexOf('<think>', index);
        final int closeIdx = chunk.indexOf('</think>', index);
        if (openIdx == -1 && closeIdx == -1) {
          visible.write(chunk.substring(index));
          index = chunk.length;
          break;
        }
        if (closeIdx != -1 && (openIdx == -1 || closeIdx < openIdx)) {
          visible.write(chunk.substring(index, closeIdx));
          index = closeIdx + 8;
          continue;
        }
        if (openIdx != -1) {
          visible.write(chunk.substring(index, openIdx));
          index = openIdx + 7;
          _insideThink = true;
          continue;
        }
        index = chunk.length;
      }
    }
    return _ThinkStreamFilterResult(visible.toString(), reasoning.toString());
  }

  String finalize() {
    _insideThink = false;
    return '';
  }
}

class _ResponseStartFilter {
  _ResponseStartFilter(this.marker);

  final String marker;
  String _buffer = '';
  bool _awaiting = true;

  String? process(String chunk) {
    if (marker.trim().isEmpty) return chunk;
    if (!_awaiting) return chunk;
    if (chunk.isEmpty) return '';
    int index = 0;
    while (index < chunk.length) {
      final String char = chunk[index];
      if (_awaiting && _buffer.isEmpty && _isIgnorableLeadingChar(char)) {
        index++;
        continue;
      }
      _buffer += char;
      if (!marker.startsWith(_buffer)) {
        _awaiting = false;
        final String passthrough = _buffer + chunk.substring(index + 1);
        _buffer = '';
        return passthrough;
      }
      index++;
      if (_buffer.length == marker.length) {
        _awaiting = false;
        _buffer = '';
        String remainder = chunk.substring(index);
        if (remainder.startsWith('\r\n')) {
          remainder = remainder.substring(2);
        } else if (remainder.startsWith('\n')) {
          remainder = remainder.substring(1);
        }
        return remainder;
      }
    }
    return null;
  }

  void ensureCompleted() {
    // Best-effort: if the marker never appears, do not fail the entire stream.
    _awaiting = false;
  }
}

bool _isIgnorableLeadingChar(String char) {
  if (char.isEmpty) return false;
  if (char == '\ufeff') return true; // BOM
  return char.trim().isEmpty;
}

String _trimLeadingIgnorable(String text) {
  int index = 0;
  while (index < text.length) {
    final String char = text[index];
    if (!_isIgnorableLeadingChar(char)) break;
    index++;
  }
  if (index == 0) return text;
  return text.substring(index);
}

class AIGatewayEndpointFailure {
  const AIGatewayEndpointFailure({
    required this.endpoint,
    required this.errorType,
    required this.message,
  });

  final AIEndpoint endpoint;
  final String errorType;
  final String message;
}
