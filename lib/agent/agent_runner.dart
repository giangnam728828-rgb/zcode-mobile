import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
    this.maxSteps = 20,
    this.temperature = 0.7,
    this.provider,
    this.environment = 'local',
    this.tokenRefreshed = false,
  });

  final String baseUrl;
  final String token;
  final String model;
  final ToolBox toolbox;
  final int maxTokens;
  final int maxSteps;
  final double temperature;

  /// Error-context fields (总方案 P1-1): the exception a turn throws carries
  /// the provider id, the execution environment and whether a token refresh
  /// already happened, so quota problems are never misread as plain 429s.
  final String? provider;
  final String environment;
  final bool tokenRefreshed;

  http.Client? _active;
  bool _cancelled = false;
  int _lastInputTokens = 0;
  int _lastOutputTokens = 0;
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
    void Function(int input, int output)? onUsage,
  }) async {
    for (int step = 0; step < maxSteps; step++) {
      if (_cancelled) return;
      _lastInputTokens = 0;
      _lastOutputTokens = 0;

      final _StepResult result = await _streamStep(
        wire: wire,
        systemPrompt: systemPrompt,
        onText: onText,
        onThinking: onThinking,
        onToolStart: onToolStart,
        onToolUpdate: onToolUpdate,
      );

      if (onUsage != null && (_lastInputTokens > 0 || _lastOutputTokens > 0)) {
        onUsage(_lastInputTokens, _lastOutputTokens);
      }
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
        call.startedAt = DateTime.now();
        onToolUpdate(call);
        String output;
        try {
          output = await toolbox.execute(call);
          call.status = ToolStatus.done;
        } catch (e) {
          output = 'Tool failed: $e';
          call.status = ToolStatus.failed;
        }
        call.endedAt = DateTime.now();
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

  http.Request _buildRequest(String body) {
    final http.Request req = http.Request('POST', _uri);
    req.headers.addAll(<String, String>{
      'x-api-key': token,
      'authorization': 'Bearer $token',
      'anthropic-version': '2023-06-01',
      'content-type': 'application/json',
      'accept': 'text/event-stream',
    });
    req.body = body;
    return req;
  }

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
    final String payload = jsonEncode(<String, dynamic>{
      'model': model,
      'max_tokens': maxTokens,
      'temperature': temperature,
      'stream': true,
      'system': systemPrompt,
      'tools': toolbox.specsAll.map((ToolSpec t) => t.toJson()).toList(),
      'messages': wire,
    });

    http.StreamedResponse? resp;
    // 连接层重试：每次尝试都重新构建请求对象。package:http 的 Request 只能
    // send 一次，复用旧对象会让第二次 send 直接抛 StateError，重试从未真正
    // 生效过。
    int attempt = 0;
    while (true) {
      if (_cancelled) break;
      resp = null;
      try {
        resp = await client.send(_buildRequest(payload));
      } catch (e) {
        attempt++;
        final bool transient = e is HttpException ||
            e is SocketException ||
            e is TimeoutException ||
            e is http.ClientException;
        if (_cancelled) break;
        if (!transient || attempt >= 3) {
          _active = null;
          throw AgentException(
            0,
            '网络连接失败：$e',
            kind: AgentErrorKind.network,
            model: model,
            provider: provider,
            environment: environment,
            tokenRefreshed: tokenRefreshed,
          );
        }
        await Future<void>.delayed(Duration(milliseconds: 400 * attempt));
        continue;
      }

      // HTTP 错误按原因分类。额度耗尽、凭证无效等不可恢复错误立即抛出，绝不
      // 自动重试；只有网关类瞬时错误（502/503/504）允许一次重建请求的退避重试。
      if (resp.statusCode != 200) {
        final String body = await resp.stream.bytesToString();
        final String? requestId = resp.headers['x-request-id'];
        final AgentErrorKind kind = AgentException.classifyError(resp.statusCode, body);
        final bool gatewayTransient = kind == AgentErrorKind.server &&
            (resp.statusCode == 502 ||
                resp.statusCode == 503 ||
                resp.statusCode == 504);
        if (gatewayTransient && attempt < 2) {
          attempt++;
          await Future<void>.delayed(Duration(milliseconds: 400 * attempt));
          continue;
        }
        _active = null;
        throw AgentException(
          resp.statusCode,
          body,
          kind: kind,
          errorCode: AgentException.errorCodeOf(body),
          requestId: requestId,
          model: model,
          provider: provider,
          environment: environment,
          tokenRefreshed: tokenRefreshed,
        );
      }
      break;
    }
    if (_cancelled) {
      _active = null;
      return _StepResult(text: '', calls: <ToolCall>[], stopReason: 'cancelled');
    }
    if (resp == null) {
      _active = null;
      throw AgentException(
        0,
        '网络连接失败，请检查网络后重试',
        kind: AgentErrorKind.network,
        model: model,
        provider: provider,
        environment: environment,
        tokenRefreshed: tokenRefreshed,
      );
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
      if (type == 'message_start') {
        final Map<String, dynamic>? msg =
            (ev['message'] as Map?)?.cast<String, dynamic>();
        final Map<String, dynamic>? usage =
            (msg?['usage'] as Map?)?.cast<String, dynamic>();
        if (usage != null) {
          _lastInputTokens = (usage['input_tokens'] as int?) ?? 0;
          _lastOutputTokens = (usage['output_tokens'] as int?) ?? 0;
        }
      } else if (type == 'content_block_start') {
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
        final Map<String, dynamic>? usage =
            (ev['usage'] as Map?)?.cast<String, dynamic>();
        if (usage != null) {
          final int out = (usage['output_tokens'] as int?) ?? 0;
          if (out > 0) _lastOutputTokens = out;
        }
      } else if (type == 'error') {
        final Map<String, dynamic>? err =
            (ev['error'] as Map?)?.cast<String, dynamic>();
        _active = null;
        throw AgentException(
          0,
          '${err?['message'] ?? 'stream error'}',
          kind: AgentErrorKind.stream,
          errorCode: AgentException.errorCodeOf(jsonEncode(ev)),
          model: model,
          provider: provider,
          environment: environment,
          tokenRefreshed: tokenRefreshed,
        );
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

/// Why a turn failed. The distinction matters because the recovery is
/// different: quota/auth failures never retry, rate limits need waiting,
/// gateway errors may rebuild the request once.
enum AgentErrorKind {
  network,
  quotaExhausted,
  rateLimited,
  authInvalid,
  noModelAccess,
  badRequest,
  server,
  stream,
}

class AgentException implements Exception {
  AgentException(
    this.statusCode,
    this.body, {
    this.kind = AgentErrorKind.server,
    this.errorCode,
    this.requestId,
    this.model,
    this.provider,
    this.environment = 'local',
    this.tokenRefreshed = false,
  });

  final int statusCode;
  final String body;
  final AgentErrorKind kind;
  final String? errorCode;
  final String? requestId;
  final String? model;
  final String? provider;
  final String environment;
  final bool tokenRefreshed;

  /// Pulls the server-side error code out of a response body, handling both
  /// the Anthropic shape (`error.code`) and the BigModel shape (`code`).
  static String? errorCodeOf(String body) {
    try {
      final Object? v = jsonDecode(body);
      if (v is! Map) return null;
      final Object? err = v['error'];
      if (err is Map) {
        final Object? c = err['code'];
        if (c != null && '$c'.isNotEmpty) return '$c';
      }
      final Object? code = v['code'];
      if (code != null && '$code'.isNotEmpty) return '$code';
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Maps an HTTP status + body onto a kind. Known server codes are checked in
  /// the body first: a 429 with an exhausted-quota code is quota, not a rate
  /// limit, and the two must not be conflated (总方案 P1-1).
  static AgentErrorKind classifyError(int statusCode, String body) {
    final String? code = errorCodeOf(body);
    final String hay =
        '$code ${errorCodeText(body)}'.toLowerCase();
    bool any(List<String> needles) => needles.any(hay.contains);
    if (any(<String>['1113', '1305', 'insufficient', 'quota', 'arrears', '余额', '欠费', '额度不足', '已用尽', '耗尽'])) {
      return AgentErrorKind.quotaExhausted;
    }
    switch (statusCode) {
      case 401:
      case 403:
        // Some providers answer an exhausted quota with 403 — check the body
        // before blaming the credential.
        if (any(<String>['1113', '1305', 'insufficient', 'quota', 'arrears', '余额', '欠费', '额度'])) {
          return AgentErrorKind.quotaExhausted;
        }
        if (any(<String>['1002', '1004', 'invalid', 'expired', '无效', '过期', '未授权'])) {
          return AgentErrorKind.authInvalid;
        }
        return statusCode == 403
            ? AgentErrorKind.noModelAccess
            : AgentErrorKind.authInvalid;
      case 402:
        return AgentErrorKind.quotaExhausted;
      case 429:
        return AgentErrorKind.rateLimited;
      case 400:
      case 404:
      case 413:
      case 422:
        return AgentErrorKind.badRequest;
      default:
        return statusCode >= 500
            ? AgentErrorKind.server
            : AgentErrorKind.badRequest;
    }
  }

  static String errorCodeText(String body) {
    final Object? v = body.isEmpty ? null : _tryDecode(body);
    if (v is Map) {
      final Object? err = v['error'];
      if (err is Map && err['message'] is String) return err['message'] as String;
      if (v['msg'] is String) return v['msg'] as String;
      if (v['message'] is String) return v['message'] as String;
    }
    return body.length > 300 ? body.substring(0, 300) : body;
  }

  static Object? _tryDecode(String body) {
    try {
      return jsonDecode(body);
    } catch (_) {
      return null;
    }
  }

  /// Structured one-line detail so every failure carries what support/telemetry
  /// needs: status, server code and message, request id, model, provider,
  /// execution environment, and whether a refresh already happened.
  String get detail {
    final List<String> parts = <String>[
      if (model != null) '模型 ${model!}',
      if (provider != null) 'Provider ${provider!}',
      '环境 $environment',
      if (statusCode > 0) 'HTTP $statusCode',
      if (errorCode != null) '错误码 $errorCode',
      if (requestId != null) '请求ID $requestId',
      if (tokenRefreshed) '本轮已刷新凭证',
    ];
    return parts.join(' · ');
  }

  String get message {
    final String server = errorCodeText(body);
    final String serverLine = server.trim().isEmpty ? '' : '\n服务端信息：$server';
    switch (kind) {
      case AgentErrorKind.network:
        return body.isEmpty ? '网络请求失败，请重试' : body;
      case AgentErrorKind.quotaExhausted:
        return '套餐额度已用尽（$detail）。重试不会恢复额度，'
            '请等待套餐刷新或更换账号。$serverLine';
      case AgentErrorKind.rateLimited:
        return '请求过于频繁（429），请稍候几秒再试。'
            '这不是额度耗尽。$serverLine\n$detail';
      case AgentErrorKind.authInvalid:
        return '模型凭证无效或已过期（$detail）。'
            '请到 设置 › 账号 重新签发，或重新登录。$serverLine';
      case AgentErrorKind.noModelAccess:
        return '当前账号无权调用该模型（$detail）。'
            '请确认套餐支持 $model。$serverLine';
      case AgentErrorKind.badRequest:
        final String snippet = body.length > 240 ? body.substring(0, 240) : body;
        return '请求被拒绝（$detail）：$snippet';
      case AgentErrorKind.server:
        final String snippet = body.length > 240 ? body.substring(0, 240) : body;
        return '服务端异常（$detail）：$snippet';
      case AgentErrorKind.stream:
        return '流式响应中断：$body\n$detail';
    }
  }

  @override
  String toString() => message;
}
