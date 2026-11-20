import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/app_config.dart';
import '../models/chat_message.dart';

class GlmApiException implements Exception {
  GlmApiException(this.statusCode, this.body);
  final int statusCode;
  final String body;

  String get friendly {
    if (statusCode == 401 || statusCode == 403) {
      return '认证失败（$statusCode）：API Key 无效、已过期，或当前套餐不支持该端点。\n'
          '请确认 Key 来自 GLM Coding Plan 控制台，且端点与账号区域（国内/海外）一致。';
    }
    if (statusCode == 429) {
      return '请求过于频繁或额度不足（429）。请稍后再试，或检查 Coding Plan 套餐余量。';
    }
    if (statusCode == 404) {
      return '端点不存在（404）。请检查 Base URL 是否填成了 /v1/messages 的完整路径。';
    }
    if (statusCode == 0) {
      return body.isEmpty ? '网络错误' : body;
    }
    final String snippet = body.length > 300 ? body.substring(0, 300) : body;
    return '请求失败（$statusCode）：$snippet';
  }

  @override
  String toString() => friendly;
}

/// A single delta from the stream: either visible text or reasoning text.
class GlmDelta {
  const GlmDelta(this.text, {this.thinking = false});
  final String text;
  final bool thinking;
}

/// Streaming client for the Anthropic-compatible GLM endpoint.
/// Works against https://open.bigmodel.cn/api/anthropic or https://api.z.ai/api/anthropic
class GlmClient {
  GlmClient(this.config);

  final AppConfig config;
  http.Client? _active;

  Uri get _uri {
    final String base = config.baseUrl.endsWith('/')
        ? config.baseUrl.substring(0, config.baseUrl.length - 1)
        : config.baseUrl;
    return Uri.parse('$base/v1/messages');
  }

  List<Map<String, dynamic>> _historyPayload(List<ChatMessage> history) {
    final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
    for (final ChatMessage m in history) {
      if (m.role == Sender.system) continue;
      if (m.text.trim().isEmpty) continue;
      out.add(<String, dynamic>{
        'role': m.role == Sender.user ? 'user' : 'assistant',
        'content': m.text,
      });
    }
    return out;
  }

  /// Emits text deltas. Call [cancel] to abort mid-stream.
  Stream<GlmDelta> streamChat(List<ChatMessage> history) async* {
    final http.Client client = http.Client();
    _active = client;
    try {
      final http.Request req = http.Request('POST', _uri);
      req.headers.addAll(<String, String>{
        'x-api-key': config.apiKey,
        'anthropic-version': '2023-06-01',
        'content-type': 'application/json',
        'accept': 'text/event-stream',
      });
      req.body = jsonEncode(<String, dynamic>{
        'model': config.model,
        'max_tokens': config.maxTokens,
        'stream': true,
        'system': config.systemPrompt,
        'messages': _historyPayload(history),
      });

      final http.StreamedResponse resp = await client.send(req);
      if (resp.statusCode != 200) {
        final String body = await resp.stream.bytesToString();
        throw GlmApiException(resp.statusCode, body);
      }

      await for (final String line in resp.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        if (!line.startsWith('data:')) continue;
        final String data = line.substring(5).trim();
        if (data.isEmpty || data == '[DONE]') continue;
        Map<String, dynamic> json;
        try {
          json = jsonDecode(data) as Map<String, dynamic>;
        } catch (_) {
          continue;
        }
        final String? type = json['type'] as String?;
        if (type == 'content_block_delta') {
          final Map<String, dynamic>? delta =
              json['delta'] as Map<String, dynamic>?;
          if (delta == null) continue;
          final String? dType = delta['type'] as String?;
          final Object? t = delta[dType == 'thinking_delta' ? 'thinking' : 'text'];
          if (t is String && t.isNotEmpty) {
            yield GlmDelta(t, thinking: dType == 'thinking_delta');
          }
        } else if (type == 'error') {
          final Object? err = json['error'];
          throw GlmApiException(0, err?.toString() ?? 'stream error');
        }
      }
    } finally {
      _active = null;
      client.close();
    }
  }

  void cancel() {
    _active?.close();
    _active = null;
  }
}
