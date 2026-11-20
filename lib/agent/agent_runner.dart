import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'tools.dart';

/// Streaming agent loop for the Anthropic-compatible endpoint: text deltas go
/// to the UI, `tool_use` blocks are executed in the phone sandbox and fed back
/// as `tool_result` until the model stops asking for tools.
class AgentRunner {
  AgentRunner({
    required this.baseUrl,
    required this.token,
    required this.model,
    required this.toolbox,
    this.maxTokens = 8192,
    this.maxSteps = 12,
  });

  final String baseUrl;
  final String token;
  final String model;
  final ToolBox toolbox;
  final int maxTokens;
  final int maxSteps;

  http.Client? _active;
  bool _cancelled = false;
  bool get cancelled => _cancelled;

  void cancel() {
    _cancelled = true;
    _active?.close();
    _active = null;
  }

  Uri get _uri {
    final String base =
        baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    return Uri.parse('$base/v1/messages');
  }

  /// Runs one user turn. [wire] is the running message list; the runner appends
  /// assistant/tool messages to it as the loop progresses.
  Future<void> run({
    required List<Map<String, dynamic>> wire,
    required String systemPrompt,
    required void Function(String text) onText,
    required void Function(String text) onThinking,
    required void Function(ToolCall call) onToolStart,
    required void Function(ToolCall call) onToolUpdate,
    required Future<bool> Function(ToolCall call) approve,
  }) async {
    for (int step = 0; step < maxSteps; step++) {
      if (_cancelled) return;

      final _StepResult result = await _streamStep(
        wire: wire,
        systemPrompt: systemPrompt,
        onText: onText,
        onThinking: onThinking,
        onToolStart: onToolStart,
        onToolUpdate: onToolUpdate,
      );

      if (_cancelled) return;

      final List<Map<String, dynamic>> content = <Map<String, dynamic>>[];
      if (result.text.trim().isNotEmpty) {
        content.add(<String, dynamic>{'type': 'text', 'text': result.text});
      }
      for (final ToolCall call in result.calls) {
        content.add(<String, dynamic>{
          'type': 'tool_use',
          'id': call.id,
          'name': call.name,
          'input': call.input,
        });
      }
      if (content.isEmpty) content.add(<String, dynamic>{'type': 'text', 'text': '…'});
      wire.add(<String, dynamic>{'role': 'assistant', 'content': content});

      if (result.calls.isEmpty || result.stopReason != 'tool_use') return;

      final List<Map<String, dynamic>> results = <Map<String, dynamic>>[];
      for (final ToolCall call in result.calls) {
        if (_cancelled) return;
        final bool allowed = await approve(call);
        if (!allowed) {
          call.status = ToolStatus.denied;
          call.output = 'User denied this action.';
          onToolUpdate(call);
          results.add(_toolResult(call, 'The user denied this action. Ask before retrying.'));
          continue;
        }
        call.status = ToolStatus.running;
        onToolUpdate(call);
        String output;
        try {
          output = await toolbox.execute(call);
          call.status = ToolStatus.done;
        } catch (e) {
          output = 'Tool failed: $e';
          call.status = ToolStatus.failed;
        }
        call.output = output;
        onToolUpdate(call);
        results.add(_toolResult(call, output));
      }
      wire.add(<String, dynamic>{'role': 'user', 'content': results});
    }
  }

  Map<String, dynamic> _toolResult(ToolCall call, String content) => <String, dynamic>{
        'type': 'tool_result',
        'tool_use_id': call.id,
        'content': content,
        'is_error': call.status == ToolStatus.failed,
      };

  Future<_StepResult> _streamStep({
    required List<Map<String, dynamic>> wire,
    required String systemPrompt,
    required void Function(String) onText,
    required void Function(String) onThinking,
    required void Function(ToolCall) onToolStart,
    required void Function(ToolCall) onToolUpdate,
  }) async {
    final http.Client client = http.Client();
    _active = client;
    final http.Request req = http.Request('POST', _uri);
    req.headers.addAll(<String, String>{
      'x-api-key': token,
      'authorization': 'Bearer $token',
      'anthropic-version': '2023-06-01',
      'content-type': 'application/json',
      'accept': 'text/event-stream',
    });
    req.body = jsonEncode(<String, dynamic>{
      'model': model,
      'max_tokens': maxTokens,
      'stream': true,
      'system': systemPrompt,
      'tools': ToolBox.specs.map((ToolSpec t) => t.toJson()).toList(),
      'messages': wire,
    });

    final http.StreamedResponse resp = await client.send(req);
    if (resp.statusCode != 200) {
      final String body = await resp.stream.bytesToString();
      _active = null;
      throw AgentException(resp.statusCode, body);
    }

    final StringBuffer text = StringBuffer();
    final Map<int, ToolCall> pending = <int, ToolCall>{};
    final Map<int, StringBuffer> buffers = <int, StringBuffer>{};
    String stopReason = 'end_turn';

    await for (final String line
        in resp.stream.transform(utf8.decoder).transform(const LineSplitter())) {
      if (_cancelled) break;
      if (!line.startsWith('data:')) continue;
      final String data = line.substring(5).trim();
      if (data.isEmpty || data == '[DONE]') continue;
      Map<String, dynamic> ev;
      try {
        ev = jsonDecode(data) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }
      final String? type = ev['type'] as String?;
      if (type == 'content_block_start') {
        final int index = (ev['index'] as int?) ?? 0;
        final Map<String, dynamic>? block =
            (ev['content_block'] as Map?)?.cast<String, dynamic>();
        if (block != null && block['type'] == 'tool_use') {
          final ToolCall call = ToolCall(
            id: '${block['id']}',
            name: '${block['name']}',
          );
          pending[index] = call;
          buffers[index] = StringBuffer();
          onToolStart(call);
        }
      } else if (type == 'content_block_delta') {
        final int index = (ev['index'] as int?) ?? 0;
        final Map<String, dynamic>? delta =
            (ev['delta'] as Map?)?.cast<String, dynamic>();
        if (delta == null) continue;
        final String? dType = delta['type'] as String?;
        if (dType == 'text_delta') {
          final String chunk = '${delta['text'] ?? ''}';
          if (chunk.isNotEmpty) {
            text.write(chunk);
            onText(chunk);
          }
        } else if (dType == 'thinking_delta') {
          final String chunk = '${delta['thinking'] ?? ''}';
          if (chunk.isNotEmpty) onThinking(chunk);
        } else if (dType == 'input_json_delta') {
          buffers[index]?.write('${delta['partial_json'] ?? ''}');
        }
      } else if (type == 'content_block_stop') {
        final int index = (ev['index'] as int?) ?? 0;
        final ToolCall? call = pending[index];
        if (call != null) {
          final String raw = buffers[index]?.toString() ?? '';
          if (raw.trim().isNotEmpty) {
            try {
              call.input = (jsonDecode(raw) as Map).cast<String, dynamic>();
            } catch (_) {
              call.input = <String, dynamic>{'raw': raw};
            }
          }
          onToolUpdate(call);
        }
      } else if (type == 'message_delta') {
        final Map<String, dynamic>? delta =
            (ev['delta'] as Map?)?.cast<String, dynamic>();
        final String? stop = delta?['stop_reason'] as String?;
        if (stop != null) stopReason = stop;
      } else if (type == 'error') {
        final Map<String, dynamic>? err =
            (ev['error'] as Map?)?.cast<String, dynamic>();
        _active = null;
        throw AgentException(0, '${err?['message'] ?? 'stream error'}');
      }
    }

    _active = null;
    final List<int> order = pending.keys.toList()..sort();
    return _StepResult(
      text: text.toString(),
      calls: <ToolCall>[for (final int i in order) pending[i]!],
      stopReason: stopReason,
    );
  }
}

class _StepResult {
  _StepResult({required this.text, required this.calls, required this.stopReason});

  final String text;
  final List<ToolCall> calls;
  final String stopReason;
}

class AgentException implements Exception {
  AgentException(this.statusCode, this.body);
  final int statusCode;
  final String body;

  String get message {
    if (statusCode == 401 || statusCode == 403) {
      return '登录状态已失效（$statusCode），请在设置里重新登录';
    }
    if (statusCode == 429) {
      return '额度不足或请求过于频繁（429）';
    }
    final String snippet = body.length > 240 ? body.substring(0, 240) : body;
    return '请求失败（$statusCode）：$snippet';
  }

  @override
  String toString() => message;
}
