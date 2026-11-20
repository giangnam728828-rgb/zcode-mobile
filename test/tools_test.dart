import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_mobile/agent/tools.dart';
import 'package:zcode_mobile/l10n/strings.dart';
import 'package:zcode_mobile/models/attachment.dart';
import 'package:zcode_mobile/services/modules.dart';
import 'package:zcode_mobile/widgets/composer.dart';
import 'package:zcode_mobile/widgets/tool_card.dart';

ToolCall _call(String name, Map<String, dynamic> input) =>
    ToolCall(id: 't1', name: name, input: input);

void main() {
  late Directory root;
  late ToolBox box;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('zcode-tools-');
    box = ToolBox.at(root);
    await Directory('${root.path}/lib').create();
    await File('${root.path}/lib/main.dart').writeAsString('void main() {}\n');
    await File('${root.path}/notes.txt').writeAsString('hello\nworld\n');
  });

  tearDown(() async {
    try {
      await root.delete(recursive: true);
    } catch (_) {}
  });

  test('glob matches nested and root files', () async {
    final String out = await box.execute(_call('glob', <String, dynamic>{
      'pattern': '**/*.dart',
    }));
    expect(out, contains('lib/main.dart'));
  });

  test('grep returns line numbers and skips nothing important', () async {
    final String out = await box.execute(_call('grep', <String, dynamic>{
      'pattern': 'world',
    }));
    expect(out, contains('notes.txt:2'));
  });

  test('mkdir → move → delete round-trip', () async {
    expect(
      await box.execute(_call('make_dir', <String, dynamic>{'path': 'docs'})),
      contains('Created'),
    );
    expect(
      await box.execute(_call('move_file', <String, dynamic>{
        'from': 'notes.txt',
        'to': 'docs/notes.txt',
      })),
      contains('Moved'),
    );
    expect(File('${root.path}/docs/notes.txt').existsSync(), isTrue);
    // A non-empty directory needs an explicit recursive flag.
    expect(
      await box.execute(
          _call('delete_file', <String, dynamic>{'path': 'docs'})),
      contains('recursive=true'),
    );
    expect(
      await box.execute(_call('delete_file', <String, dynamic>{
        'path': 'docs',
        'recursive': true,
      })),
      contains('Deleted'),
    );
    expect(Directory('${root.path}/docs').existsSync(), isFalse);
  });

  test('todo_write keeps the checklist readable for the model', () async {
    final String out = await box.execute(_call('todo_write', <String, dynamic>{
      'todos': <Map<String, dynamic>>[
        <String, dynamic>{'content': 'read the repo', 'status': 'completed'},
        <String, dynamic>{'content': 'patch the bug', 'status': 'in_progress'},
        <String, dynamic>{'content': 'run tests', 'status': 'pending'},
      ],
    }));
    expect(out, contains('[x] read the repo'));
    expect(out, contains('[~] patch the bug'));
    expect(out, contains('1/3 completed'));
  });

  test('paths cannot escape the workspace', () async {
    final String out = await box.execute(_call('read_file', <String, dynamic>{
      'path': '../../etc/passwd',
    }));
    expect(out, isNot(contains('root:')));
  });

  test('todo entries survive a JSON round-trip on the tool call', () {
    final ToolCall call = _call('todo_write', <String, dynamic>{
      'todos': <Map<String, dynamic>>[
        <String, dynamic>{'content': 'a', 'status': 'completed'},
        <String, dynamic>{'content': 'b', 'status': 'pending'},
      ],
    });
    final ToolCall copy = ToolCall.fromJson(call.toJson());
    expect(copy.todos.length, 2);
    expect(copy.todos.first.done, isTrue);
  });

  test('a turn can be rolled back file by file', () async {
    box.beginTurn();
    await box.execute(_call('write_file', <String, dynamic>{
      'path': 'new.txt',
      'content': 'created',
    }));
    await box.execute(_call('write_file', <String, dynamic>{
      'path': 'notes.txt',
      'content': 'replaced',
    }));
    expect(box.canUndo, isTrue);
    expect(File('${root.path}/notes.txt').readAsStringSync(), 'replaced');

    final int restored = await box.undoLastTurn();
    expect(restored, 2);
    expect(File('${root.path}/new.txt').existsSync(), isFalse);
    expect(File('${root.path}/notes.txt').readAsStringSync(), 'hello\nworld\n');
    expect(box.canUndo, isFalse);
  });

  test('built-in module installs a script and exposes its bin path', () async {
    final ModuleCenter mc = ModuleCenter(root);
    await mc.load();
    final ModuleSpec spec =
        ModuleCenter.catalog.firstWhere((ModuleSpec s) => s.id == 'tree');
    final InstalledModule m = await mc.install(spec);
    expect(m.commands, contains('tree'));
    expect(File('${m.dir}/bin/tree').existsSync(), isTrue);
    expect(mc.binPaths, contains('${m.dir}/bin'));
    // A second load must remember the module.
    final ModuleCenter again = ModuleCenter(root);
    await again.load();
    expect(again.isInstalled('tree'), isTrue);
    await again.remove('tree');
    expect(Directory(m.dir).existsSync(), isFalse);
  });

  test('attachment detects images and formats sizes', () {
    expect(Attachment.looksLikeImage('photo.JPG'), isTrue);
    expect(Attachment.looksLikeImage('main.dart'), isFalse);
    const Attachment a = Attachment(
        path: 'a.png', name: 'a.png', isImage: true, size: 2048);
    expect(a.sizeLabel, '2.0 KB');
  });

  testWidgets('composer suggests slash commands and files', (tester) async {
    final TextEditingController ctrl = TextEditingController();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Composer(
          controller: ctrl,
          streaming: false,
          queue: const <String>[],
          s: S.zh,
          onSend: (_) {},
          onStop: () {},
          onSendNow: () {},
          onClearQueue: () {},
          filePaths: const <String>['lib/main.dart', 'README.md'],
        ),
      ),
    ));

    await tester.enterText(find.byType(TextField), '/');
    await tester.pump();
    expect(find.text('/compact'), findsOneWidget);
    expect(find.text('压缩早期上下文'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'look at @REA');
    await tester.pump();
    expect(find.text('README.md'), findsOneWidget);
  });

  _planWidgetTests();
}

void _planWidgetTests() {
  testWidgets('plan card renders checklist and progress', (tester) async {
    final ToolCall call = ToolCall(
      id: 'p',
      name: 'todo_write',
      input: <String, dynamic>{
        'todos': <Map<String, dynamic>>[
          <String, dynamic>{'content': 'read repo', 'status': 'completed'},
          <String, dynamic>{'content': 'patch bug', 'status': 'in_progress'},
          <String, dynamic>{'content': 'run tests', 'status': 'pending'},
        ],
      },
      status: ToolStatus.done,
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ToolCard(call: call)),
    ));
    expect(find.text('计划'), findsOneWidget);
    expect(find.text('1/3'), findsOneWidget);
    expect(find.text('patch bug'), findsOneWidget);
  });
}
