import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_mobile/agent/mcp.dart';
import 'package:zcode_mobile/agent/tools.dart';
import 'package:zcode_mobile/services/plugins.dart';

/// A tiny MCP server that speaks just enough JSON-RPC for the client tests.
Future<HttpServer> _mockMcp({bool sse = false}) async {
  final HttpServer server = await HttpServer.bind(
    InternetAddress.loopbackIPv4,
    0,
  );
  server.listen((HttpRequest req) async {
    final String body = await utf8.decoder.bind(req).join();
    final Map<String, dynamic> msg =
        jsonDecode(body) as Map<String, dynamic>;
    final String method = '${msg['method']}';
    final Object? id = msg['id'];
    Map<String, dynamic>? result;
    if (method == 'initialize') {
      result = <String, dynamic>{
        'protocolVersion': '2025-06-18',
        'capabilities': <String, dynamic>{'tools': <String, dynamic>{}},
        'serverInfo': <String, dynamic>{'name': 'mock', 'version': '1'},
      };
    } else if (method == 'tools/list') {
      result = <String, dynamic>{
        'tools': <Map<String, dynamic>>[
          <String, dynamic>{
            'name': 'echo',
            'description': 'echo back',
            'inputSchema': <String, dynamic>{
              'type': 'object',
              'properties': <String, dynamic>{
                'text': <String, dynamic>{'type': 'string'},
              },
            },
          },
        ],
      };
    } else if (method == 'tools/call') {
      final Map<String, dynamic> params =
          (msg['params'] as Map).cast<String, dynamic>();
      result = <String, dynamic>{
        'content': <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'text',
            'text': 'echo:${(params['arguments'] as Map)['text']}',
          },
        ],
      };
    }
    if (id == null) {
      req.response.statusCode = 202;
      await req.response.close();
      return;
    }
    final String payload = jsonEncode(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'result': result ??
          <String, dynamic>{
            'ok': true,
            'method': method,
          },
    });
    req.response.headers.set('mcp-session-id', 'sess-1');
    if (sse) {
      req.response.headers.contentType =
          ContentType('text', 'event-stream', charset: 'utf-8');
      req.response.write('event: message\ndata: $payload\n\n');
    } else {
      req.response.headers.contentType = ContentType.json;
      req.response.write(payload);
    }
    await req.response.close();
  });
  return server;
}

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('zcode_plugins');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  group('PluginCenter', () {
    test('installs skill files and records state', () async {
      final PluginCenter center = PluginCenter(root);
      await center.load();
      const PluginManifest m = PluginManifest(
        id: 'demo-skill',
        name: 'Demo',
        description: 'demo',
        files: <PluginFile>[
          PluginFile('skills/demo.md', '# Demo\n\nUse it.'),
          PluginFile('agents/helper.md', 'You help.'),
        ],
      );
      await center.install(m);

      expect(
        File('${root.path}/.zcode/skills/demo.md').readAsStringSync(),
        contains('Use it.'),
      );
      expect(File('${root.path}/.zcode/agents/helper.md').existsSync(), isTrue);
      expect(center.isInstalled('demo-skill'), isTrue);
      expect(center.installed.single.manifest.name, 'Demo');

      // Reload from disk: the manifest survives a restart.
      final PluginCenter again = PluginCenter(root);
      await again.load();
      expect(again.isInstalled('demo-skill'), isTrue);
      expect(again.installed.single.files.length, 2);
    });

    test('rejects paths that escape .zcode', () async {
      final PluginCenter center = PluginCenter(root);
      const PluginManifest m = PluginManifest(
        id: 'evil',
        name: 'Evil',
        description: 'tries to escape',
        files: <PluginFile>[
          PluginFile('skills/../../../etc/passwd', 'nope'),
          PluginFile('/etc/hosts', 'nope'),
          PluginFile('secrets/x.md', 'also not allowed'),
          PluginFile('skills/ok.md', 'fine'),
        ],
      );
      await center.install(m);

      expect(File('${root.path}/.zcode/skills/ok.md').existsSync(), isTrue);
      expect(Directory('${root.path}/.zcode/secrets').existsSync(), isFalse);
      expect(center.installed.single.files, <String>['skills/ok.md']);
      expect(File('/etc/hosts').readAsStringSync(), isNot(contains('nope')));
    });

    test('uninstall removes owned files but keeps unrelated ones', () async {
      final PluginCenter center = PluginCenter(root);
      Directory('${root.path}/.zcode/skills').createSync(recursive: true);
      File('${root.path}/.zcode/skills/mine.md').writeAsStringSync('mine');
      await center.install(const PluginManifest(
        id: 'temp',
        name: 'Temp',
        description: '',
        files: <PluginFile>[PluginFile('skills/temp.md', 'x')],
      ));
      await center.uninstall('temp');

      expect(File('${root.path}/.zcode/skills/temp.md').existsSync(), isFalse);
      expect(File('${root.path}/.zcode/skills/mine.md').existsSync(), isTrue);
      expect(center.isInstalled('temp'), isFalse);
    });

    test('mcp plugins merge into mcp.json and drop on remove', () async {
      final PluginCenter center = PluginCenter(root);
      await center.install(const PluginManifest(
        id: 'mcp-demo',
        name: 'MCP Demo',
        description: '',
        kind: PluginKind.mcp,
        mcp: <String, dynamic>{
          'demo': <String, dynamic>{'url': 'https://example.com/mcp'},
        },
      ));
      final Map<String, dynamic> mcp = jsonDecode(
        File('${root.path}/.zcode/mcp.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      expect((mcp['mcpServers'] as Map)['demo'], isNotNull);

      await center.uninstall('mcp-demo');
      final Map<String, dynamic> after = jsonDecode(
        File('${root.path}/.zcode/mcp.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      expect((after['mcpServers'] as Map).containsKey('demo'), isFalse);
    });

    test('fetches a registry and accepts the plugins envelope', () async {
      final HttpServer server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      server.listen((HttpRequest req) async {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(<String, dynamic>{
          'plugins': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'remote-one',
              'name': 'Remote',
              'description': 'from url',
              'kind': 'skill',
              'files': <Map<String, String>>[
                <String, String>{'path': 'skills/r.md', 'content': '# R'},
              ],
            },
          ],
        }));
        await req.response.close();
      });
      final PluginCenter center = PluginCenter(root);
      final List<PluginManifest> list = await center.fetchManifest(
        'http://127.0.0.1:${server.port}/index.json',
      );
      await server.close(force: true);

      expect(list.single.id, 'remote-one');
      expect(list.single.kind, PluginKind.skill);
    });

    test('catalog is self-consistent', () {
      final Set<String> ids = <String>{};
      for (final PluginManifest m in PluginCatalog.all) {
        expect(m.id, isNotEmpty);
        expect(ids.add(m.id), isTrue, reason: 'duplicate id ${m.id}');
        expect(m.files.isNotEmpty || m.mcp.isNotEmpty, isTrue,
            reason: '${m.id} has no payload');
        for (final PluginFile f in m.files) {
          expect(
            f.path.startsWith('skills/') ||
                f.path.startsWith('commands/') ||
                f.path.startsWith('agents/') ||
                f.path.startsWith('plugins/'),
            isTrue,
            reason: '${m.id}: ${f.path}',
          );
        }
      }
      expect(PluginCatalog.all.length, greaterThanOrEqualTo(12));
    });
  });

  group('MCP', () {
    test('http client handshakes, lists tools and calls one', () async {
      final HttpServer server = await _mockMcp();
      final McpClient client = HttpMcpClient(McpServerConfig(
        name: 'mock',
        url: 'http://127.0.0.1:${server.port}/mcp',
      ));
      final List<McpTool> tools = await client.connect();
      expect(tools.single.name, 'echo');
      expect(tools.single.schema['type'], 'object');

      final String out =
          await client.callTool('echo', <String, dynamic>{'text': 'hi'});
      expect(out, 'echo:hi');
      await client.close();
      await server.close(force: true);
    });

    test('sse responses are unwrapped', () async {
      final HttpServer server = await _mockMcp(sse: true);
      final McpClient client = HttpMcpClient(McpServerConfig(
        name: 'mock',
        url: 'http://127.0.0.1:${server.port}/mcp',
      ));
      final List<McpTool> tools = await client.connect();
      expect(tools.single.name, 'echo');
      await client.close();
      await server.close(force: true);
    });

    test('manager registers namespaced tools on the toolbox', () async {
      final HttpServer server = await _mockMcp();
      final ToolBox box = ToolBox.at(root);
      Directory('${root.path}/.zcode').createSync(recursive: true);
      File('${root.path}/.zcode/mcp.json').writeAsStringSync(jsonEncode(
        <String, dynamic>{
          'mcpServers': <String, dynamic>{
            'mock': <String, dynamic>{
              'url': 'http://127.0.0.1:${server.port}/mcp',
            },
          },
        },
      ));
      final McpManager manager = McpManager(root, box);
      final int count = await manager.reload();

      expect(count, 1);
      expect(manager.statuses['mock']!.state, 'ready');
      expect(box.specsAll.any((ToolSpec t) => t.name == 'mcp__mock__echo'),
          isTrue);

      final String out = await box.execute(ToolCall(
        id: 't1',
        name: 'mcp__mock__echo',
        input: <String, dynamic>{'text': 'yo'},
      ));
      expect(out, 'echo:yo');

      // Reconnecting must not duplicate registrations.
      await manager.reload();
      expect(
        box.specsAll.where((ToolSpec t) => t.name == 'mcp__mock__echo').length,
        1,
      );
      await manager.dispose();
      await server.close(force: true);
    });

    test('a broken server is reported, not thrown', () async {
      Directory('${root.path}/.zcode').createSync(recursive: true);
      File('${root.path}/.zcode/mcp.json').writeAsStringSync(jsonEncode(
        <String, dynamic>{
          'mcpServers': <String, dynamic>{
            'dead': <String, dynamic>{'url': 'http://127.0.0.1:1/mcp'},
            'off': <String, dynamic>{'url': 'http://x', 'enabled': false},
          },
        },
      ));
      final ToolBox box = ToolBox.at(root);
      final McpManager manager = McpManager(root, box);
      final int count = await manager.reload();

      expect(count, 0);
      expect(manager.statuses['dead']!.state, 'error');
      expect(manager.statuses['off']!.state, 'disabled');
      expect(manager.error, isNotNull);
    });
  });

  group('task tool', () {
    test('delegates to the sub-agent hook once and forbids nesting', () async {
      final ToolBox box = ToolBox.at(root);
      int calls = 0;
      box.subagent = (String prompt, {String? agent}) async {
        calls++;
        expect(agent, 'helper');
        expect(prompt, contains('find the bug'));
        // Inside a child run the hook is cleared, so nesting returns a note.
        expect(box.subagent, isNull);
        return 'report: fixed';
      };
      final String out = await box.execute(ToolCall(
        id: 't1',
        name: 'task',
        input: <String, dynamic>{
          'description': 'hunt',
          'prompt': 'find the bug',
          'agent': 'helper',
        },
      ));
      expect(calls, 1);
      expect(out, 'report: fixed');
      expect(
        box.specsAll.any((ToolSpec t) => t.name == 'task'),
        isTrue,
      );
    });
  });
}
