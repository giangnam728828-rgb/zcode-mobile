import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_mobile/agent/agent_runner.dart';
import 'package:zcode_mobile/agent/tools.dart';

/// End-to-end proof that the agent really executes tools: a fake model asks for
/// a shell command, the runner runs it on this machine, and the second request
/// must carry the tool_result back.
void main() {
  late HttpServer server;
  late Directory workspace;
  final List<Map<String, dynamic>> requests = <Map<String, dynamic>>[];

  setUp(() async {
    requests.clear();
    workspace = await Directory.systemTemp.createTemp('zcode-agent-test');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest req) async {
      final String body = await utf8.decoder.bind(req).join();
      final Map<String, dynamic> payload =
          jsonDecode(body) as Map<String, dynamic>;
      requests.add(payload);
      req.response.headers.contentType = ContentType('text', 'event-stream');
      void w(String chunk) => req.response.add(utf8.encode(chunk));

      if (requests.length == 1) {
        // First turn: the model calls bash once.
        w('data: {"type":"content_block_start","index":0,'
            '"content_block":{"type":"tool_use","id":"tool_1","name":"bash"}}\n\n');
        w('data: {"type":"content_block_delta","index":0,'
            '"delta":{"type":"input_json_delta","partial_json":'
            '"{\\"command\\":\\"echo hello-from-agent > proof.txt\\"}"}}\n\n');
        w('data: {"type":"content_block_stop","index":0}\n\n');
        w('data: {"type":"message_delta",'
            '"delta":{"stop_reason":"tool_use"}}\n\n');
      } else {
        // Second turn: after seeing the result, answer in text.
        w('data: {"type":"content_block_start","index":0,'
            '"content_block":{"type":"text"}}\n\n');
        w('data: {"type":"content_block_delta","index":0,'
            '"delta":{"type":"text_delta","text":"文件已写好"}}\n\n');
        w('data: {"type":"message_delta",'
            '"delta":{"stop_reason":"end_turn"}}\n\n');
      }
      await req.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    if (await workspace.exists()) await workspace.delete(recursive: true);
  });

  test('runs a shell tool and feeds the result back to the model', () async {
    final ToolBox box = ToolBox.at(workspace);
    final AgentRunner runner = AgentRunner(
      baseUrl: 'http://127.0.0.1:${server.port}',
      token: 'test-token',
      model: 'glm-5.3',
      toolbox: box,
    );

    final List<ToolCall> started = <ToolCall>[];
    final StringBuffer text = StringBuffer();
    final List<Map<String, dynamic>> wire = <Map<String, dynamic>>[
      <String, dynamic>{'role': 'user', 'content': '写个文件'},
    ];

    await runner.run(
      wire: wire,
      systemPrompt: 'test',
      onText: text.write,
      onThinking: (_) {},
      onToolStart: started.add,
      onToolUpdate: (_) {},
      approve: (_) async => true,
    );

    // The command really ran on disk.
    final File proof = File('${workspace.path}/proof.txt');
    expect(await proof.exists(), isTrue);
    expect((await proof.readAsString()).trim(), 'hello-from-agent');

    expect(started, hasLength(1));
    expect(started.first.status, ToolStatus.done);
    expect(started.first.output, contains('exit 0'));
    expect(text.toString(), contains('文件已写好'));

    // Two round trips: initial call, then the turn carrying the tool_result.
    expect(requests, hasLength(2));
    expect(requests.first['tools'], isA<List<dynamic>>());
    final List<dynamic> second = requests[1]['messages'] as List<dynamic>;
    final Map<String, dynamic> resultMsg =
        (second.last as Map<String, dynamic>);
    expect(resultMsg['role'], 'user');
    final List<dynamic> blocks = resultMsg['content'] as List<dynamic>;
    expect((blocks.first as Map<String, dynamic>)['type'], 'tool_result');
    // The command redirected its output, so the tool_result carries the exit
    // status rather than stdout — the file assertion above proves execution.
    expect(
      (blocks.first as Map<String, dynamic>)['content'],
      contains('exit 0'),
    );
  });

  test('denied tools are reported instead of executed', () async {
    final ToolBox box = ToolBox.at(workspace);
    final AgentRunner runner = AgentRunner(
      baseUrl: 'http://127.0.0.1:${server.port}',
      token: 'test-token',
      model: 'glm-5.3',
      toolbox: box,
    );
    final List<ToolCall> started = <ToolCall>[];
    final List<Map<String, dynamic>> wire = <Map<String, dynamic>>[
      <String, dynamic>{'role': 'user', 'content': '写个文件'},
    ];

    await runner.run(
      wire: wire,
      systemPrompt: 'test',
      onText: (_) {},
      onThinking: (_) {},
      onToolStart: started.add,
      onToolUpdate: (_) {},
      approve: (_) async => false,
    );

    expect(await File('${workspace.path}/proof.txt').exists(), isFalse);
    expect(started.single.status, ToolStatus.denied);
  });

  test('risky commands are flagged for approval', () {
    final ToolBox box = ToolBox.at(workspace);
    expect(
      box.requiresApproval(ToolCall(id: '1', name: 'bash',
          input: <String, dynamic>{'command': 'rm -rf build'})),
      isTrue,
    );
    expect(
      box.requiresApproval(ToolCall(id: '2', name: 'bash',
          input: <String, dynamic>{'command': 'ls -la'})),
      isFalse,
    );
    expect(
      box.requiresApproval(ToolCall(id: '3', name: 'read_file',
          input: <String, dynamic>{'path': 'a.txt'})),
      isFalse,
    );
  });

  test('paths cannot escape the workspace', () async {
    final ToolBox box = ToolBox.at(workspace);
    final String out = await box.execute(ToolCall(
      id: 'x',
      name: 'read_file',
      input: <String, dynamic>{'path': '../../../../etc/hostname'},
    ));
    expect(out, contains('File not found'));
    expect(out, contains(workspace.path));
  });
}
