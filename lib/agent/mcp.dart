import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'tools.dart';

/// One remote/local MCP endpoint as written in `.zcode/mcp.json`.
class McpServerConfig {
  McpServerConfig({
    required this.name,
    this.url = '',
    this.headers = const <String, String>{},
    this.command = '',
    this.args = const <String>[],
    this.env = const <String, String>{},
    this.enabled = true,
  });

  final String name;
  final String url;
  final Map<String, String> headers;
  final String command;
  final List<String> args;
  final Map<String, String> env;
  final bool enabled;

  bool get isHttp => url.isNotEmpty;

  static McpServerConfig? fromJson(String name, Object? raw) {
    if (raw is! Map) return null;
    final Map<String, dynamic> json = raw.cast<String, dynamic>();
    return McpServerConfig(
      name: name,
      url: '${json['url'] ?? ''}',
      headers: ((json['headers'] as Map?) ?? <String, dynamic>{})
          .map((dynamic k, dynamic v) => MapEntry<String, String>('$k', '$v')),
      command: '${json['command'] ?? ''}',
      args: ((json['args'] as List?) ?? <dynamic>[])
          .map((dynamic e) => '$e')
          .toList(),
      env: ((json['env'] as Map?) ?? <String, dynamic>{})
          .map((dynamic k, dynamic v) => MapEntry<String, String>('$k', '$v')),
      enabled: (json['enabled'] as bool?) ?? true,
    );
  }
}

class McpTool {
  const McpTool(this.name, this.description, this.schema);

  final String name;
  final String description;
  final Map<String, dynamic> schema;
}

/// Result of a connection attempt, surfaced in the plugins page.
class McpStatus {
  McpStatus(this.server, {this.state = 'idle', this.detail = '', this.tools = 0});

  final String server;
  String state; // idle | connecting | ready | error | disabled
  String detail;
  int tools;

  bool get ready => state == 'ready';
}

abstract class McpClient {
  String get name;
  Future<List<McpTool>> connect();
  Future<String> callTool(String tool, Map<String, dynamic> arguments);
  Future<void> close();
}

/// JSON-RPC over Streamable HTTP. Works with the hosted MCP servers people
/// usually want on a phone, and needs no extra runtime.
class HttpMcpClient implements McpClient {
  HttpMcpClient(this.config);

  final McpServerConfig config;
  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15);
  String? _session;
  int _id = 0;

  @override
  String get name => config.name;

  @override
  Future<List<McpTool>> connect() async {
    await _request('initialize', <String, dynamic>{
      'protocolVersion': '2025-06-18',
      'capabilities': <String, dynamic>{},
      'clientInfo': <String, dynamic>{
        'name': 'zcode-mobile',
        'version': '3.2.0',
      },
    });
    // Notification: no id, fire and forget.
    await _post(<String, dynamic>{
      'jsonrpc': '2.0',
      'method': 'notifications/initialized',
    }).catchError((Object _) => '');
    final Map<String, dynamic> res =
        await _request('tools/list', <String, dynamic>{});
    return _parseTools(res);
  }

  @override
  Future<String> callTool(String tool, Map<String, dynamic> arguments) async {
    final Map<String, dynamic> res = await _request('tools/call', <String, dynamic>{
      'name': tool,
      'arguments': arguments,
    });
    return _renderResult(res);
  }

  @override
  Future<void> close() async {
    _http.close(force: true);
  }

  Future<Map<String, dynamic>> _request(
    String method,
    Map<String, dynamic> params,
  ) async {
    final int id = ++_id;
    final String body = await _post(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    });
    final Map<String, dynamic>? msg = _findMessage(body, id);
    if (msg == null) {
      throw StateError('MCP 响应里没有 $method 的结果');
    }
    final Object? err = msg['error'];
    if (err is Map && err['message'] != null) {
      throw StateError('MCP 错误：${err['message']}');
    }
    final Object? result = msg['result'];
    return result is Map ? result.cast<String, dynamic>() : <String, dynamic>{};
  }

  Future<String> _post(Map<String, dynamic> payload) async {
    final Uri uri = Uri.parse(config.url);
    final HttpClientRequest req = await _http.postUrl(uri);
    req.headers.set('content-type', 'application/json');
    req.headers.set('accept', 'application/json, text/event-stream');
    if (_session != null) req.headers.set('mcp-session-id', _session!);
    config.headers.forEach(req.headers.set);
    req.add(utf8.encode(jsonEncode(payload)));
    final HttpClientResponse resp = await req.close();
    final String session = resp.headers.value('mcp-session-id') ?? '';
    if (session.isNotEmpty) _session = session;
    final String body = await resp
        .transform(const Utf8Decoder(allowMalformed: true))
        .join()
        .timeout(const Duration(seconds: 30));
    if (resp.statusCode >= 400) {
      throw StateError('MCP HTTP ${resp.statusCode}：${body.trim()}');
    }
    return body;
  }

  /// Responses can be plain JSON or an SSE stream; pick the frame whose id
  /// matches the request we just sent.
  static Map<String, dynamic>? _findMessage(String body, int id) {
    final List<String> candidates = <String>[];
    final String trimmed = body.trim();
    if (trimmed.startsWith('{')) candidates.add(trimmed);
    for (final String line in const LineSplitter().convert(body)) {
      final String t = line.trim();
      if (t.startsWith('data:')) {
        final String data = t.substring(5).trim();
        if (data.startsWith('{')) candidates.add(data);
      }
    }
    Map<String, dynamic>? fallback;
    for (final String c in candidates) {
      try {
        final Object? raw = jsonDecode(c);
        if (raw is! Map) continue;
        final Map<String, dynamic> map = raw.cast<String, dynamic>();
        if (map['id'] == id) return map;
        if (map['result'] != null || map['error'] != null) fallback ??= map;
      } catch (_) {}
    }
    return fallback;
  }

  static List<McpTool> _parseTools(Map<String, dynamic> res) {
    final List<McpTool> out = <McpTool>[];
    final Object? raw = res['tools'];
    if (raw is! List) return out;
    for (final Object? item in raw) {
      if (item is! Map) continue;
      final String name = '${item['name'] ?? ''}';
      if (name.isEmpty) continue;
      final Object? schema = item['inputSchema'] ?? item['input_schema'];
      out.add(McpTool(
        name,
        '${item['description'] ?? ''}',
        schema is Map
            ? schema.cast<String, dynamic>()
            : <String, dynamic>{'type': 'object', 'properties': <String, dynamic>{}},
      ));
    }
    return out;
  }

  static String _renderResult(Map<String, dynamic> res) {
    final Object? content = res['content'];
    if (content is List) {
      final List<String> parts = <String>[];
      for (final Object? item in content) {
        if (item is! Map) continue;
        final String type = '${item['type'] ?? ''}';
        if (type == 'text') {
          parts.add('${item['text'] ?? ''}');
        } else if (type == 'resource') {
          final Object? r = item['resource'];
          if (r is Map && r['text'] != null) parts.add('${r['text']}');
        } else {
          parts.add('[${type.isEmpty ? 'content' : type}]');
        }
      }
      if (parts.isNotEmpty) return parts.join('\n');
    }
    if (res['structuredContent'] != null) {
      return const JsonEncoder.withIndent('  ').convert(res['structuredContent']);
    }
    return res.isEmpty ? '(no output)' : jsonEncode(res);
  }
}

/// JSON-RPC over stdin/stdout for a locally installed server. Useful once the
/// user installs a node/python module; fails with a clear message otherwise.
class StdioMcpClient implements McpClient {
  StdioMcpClient(this.config);

  final McpServerConfig config;
  Process? _process;
  final Map<int, Completer<Map<String, dynamic>>> _pending =
      <int, Completer<Map<String, dynamic>>>{};
  int _id = 0;
  final StringBuffer _stderr = StringBuffer();

  @override
  String get name => config.name;

  @override
  Future<List<McpTool>> connect() async {
    final Process p = await Process.start(
      config.command,
      config.args,
      workingDirectory: Directory.current.path,
      environment: <String, String>{...Platform.environment, ...config.env},
    );
    _process = p;
    p.stderr.transform(utf8.decoder).listen((String chunk) {
      if (_stderr.length < 4000) _stderr.write(chunk);
    });
    p.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine);
    await _request('initialize', <String, dynamic>{
      'protocolVersion': '2025-06-18',
      'capabilities': <String, dynamic>{},
      'clientInfo': <String, dynamic>{'name': 'zcode-mobile', 'version': '3.2.0'},
    });
    _write(<String, dynamic>{
      'jsonrpc': '2.0',
      'method': 'notifications/initialized',
    });
    final Map<String, dynamic> res =
        await _request('tools/list', <String, dynamic>{});
    return HttpMcpClient._parseTools(res);
  }

  @override
  Future<String> callTool(String tool, Map<String, dynamic> arguments) async {
    final Map<String, dynamic> res = await _request('tools/call', <String, dynamic>{
      'name': tool,
      'arguments': arguments,
    });
    return HttpMcpClient._renderResult(res);
  }

  @override
  Future<void> close() async {
    try {
      _process?.kill();
    } catch (_) {}
    _process = null;
    for (final Completer<Map<String, dynamic>> c in _pending.values) {
      if (!c.isCompleted) c.completeError(StateError('MCP 进程已关闭'));
    }
    _pending.clear();
  }

  void _write(Map<String, dynamic> payload) {
    _process?.stdin.writeln(jsonEncode(payload));
  }

  void _onLine(String line) {
    final String t = line.trim();
    if (t.isEmpty || !t.startsWith('{')) return;
    try {
      final Object? raw = jsonDecode(t);
      if (raw is! Map) return;
      final Map<String, dynamic> msg = raw.cast<String, dynamic>();
      final Object? id = msg['id'];
      if (id is int && _pending.containsKey(id)) {
        _pending.remove(id)!.complete(msg);
      }
    } catch (_) {}
  }

  Future<Map<String, dynamic>> _request(
    String method,
    Map<String, dynamic> params,
  ) async {
    final int id = ++_id;
    final Completer<Map<String, dynamic>> c = Completer<Map<String, dynamic>>();
    _pending[id] = c;
    _write(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    });
    final Map<String, dynamic> msg = await c.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        _pending.remove(id);
        final String err = _stderr.toString().trim();
        throw StateError(
          'MCP 服务无响应${err.isEmpty ? '' : '：${err.split('\n').last}'}',
        );
      },
    );
    final Object? err = msg['error'];
    if (err is Map && err['message'] != null) {
      throw StateError('MCP 错误：${err['message']}');
    }
    final Object? result = msg['result'];
    return result is Map ? result.cast<String, dynamic>() : <String, dynamic>{};
  }
}

/// Reads `.zcode/mcp.json`, connects every enabled server, and registers their
/// tools on the toolbox as `mcp__<server>__<tool>`.
class McpManager {
  McpManager(this.workspace, this.toolbox);

  final Directory workspace;
  final ToolBox toolbox;

  final Map<String, McpStatus> statuses = <String, McpStatus>{};
  final Map<String, McpClient> _clients = <String, McpClient>{};
  bool loading = false;

  File get _file => File('${workspace.path}/.zcode/mcp.json');

  /// Last connection error, shown in the plugins page when every server fails.
  String? error;

  Future<List<McpServerConfig>> configs() async {
    final List<McpServerConfig> out = <McpServerConfig>[];
    try {
      if (!await _file.exists()) return out;
      final Object? raw = jsonDecode(await _file.readAsString());
      if (raw is! Map) return out;
      final Object? servers = raw['mcpServers'] ?? raw['servers'];
      if (servers is! Map) return out;
      servers.forEach((dynamic name, dynamic value) {
        final McpServerConfig? cfg = McpServerConfig.fromJson('$name', value);
        if (cfg != null) out.add(cfg);
      });
    } catch (e) {
      error = '读取 mcp.json 失败：$e';
    }
    return out;
  }

  /// Drops old registrations, reconnects everything, and returns how many
  /// tools ended up available.
  Future<int> reload() async {
    if (loading) return 0;
    loading = true;
    error = null;
    try {
      for (final McpClient c in _clients.values) {
        await c.close();
      }
      _clients.clear();
      toolbox.clearExternal(prefix: 'mcp__');
      statuses.clear();

      final List<McpServerConfig> list = await configs();
      int total = 0;
      for (final McpServerConfig cfg in list) {
        if (!cfg.enabled) {
          statuses[cfg.name] = McpStatus(cfg.name, state: 'disabled');
          continue;
        }
        final McpStatus st = McpStatus(cfg.name, state: 'connecting');
        statuses[cfg.name] = st;
        final McpClient client = cfg.isHttp
            ? HttpMcpClient(cfg)
            : StdioMcpClient(cfg);
        try {
          final List<McpTool> tools = await client
              .connect()
              .timeout(const Duration(seconds: 25));
          _clients[cfg.name] = client;
          final String safeServer =
              cfg.name.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
          for (final McpTool t in tools) {
            final String safeTool =
                t.name.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
            final String name = 'mcp__${safeServer}__$safeTool';
            final McpClient bound = client;
            toolbox.registerExternal(ExternalTool(
              ToolSpec(
                name,
                '[MCP:${cfg.name}] ${t.description}'.trim(),
                t.schema,
              ),
              (Map<String, dynamic> input) => bound.callTool(t.name, input),
              server: cfg.name,
            ));
            total++;
          }
          st
            ..state = 'ready'
            ..tools = tools.length
            ..detail = tools.isEmpty ? '已连接，未暴露工具' : '${tools.length} 个工具';
        } catch (e) {
          await client.close();
          st
            ..state = 'error'
            ..detail = '$e';
          error ??= '${cfg.name}: $e';
        }
      }
      return total;
    } finally {
      loading = false;
    }
  }

  Future<void> dispose() async {
    for (final McpClient c in _clients.values) {
      await c.close();
    }
    _clients.clear();
  }
}
