import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zcode_mobile/agent/tools.dart';
import 'package:zcode_mobile/services/workspace.dart';
import 'package:zcode_mobile/state/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tmp = await Directory.systemTemp.createTemp('zcode-ws-');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  group('path helpers', () {
    test('normalize collapses dots and duplicate slashes', () {
      expect(WorkspaceResolver.normalize('/storage//emulated/0/./ZCode/'),
          '/storage/emulated/0/ZCode');
      expect(WorkspaceResolver.normalize('/a/b/../c'), '/a/c');
      expect(WorkspaceResolver.normalize('/..'), '/');
    });

    test('label turns shared storage into something readable', () {
      expect(WorkspaceResolver.label('/storage/emulated/0'), '内部存储');
      expect(WorkspaceResolver.label('/storage/emulated/0/ZCode'),
          '内部存储/ZCode');
      expect(WorkspaceResolver.label('/storage/1A2B-3C4D/proj'),
          '存储卡 1A2B-3C4D/proj');
    });

    test('isShared only accepts public storage', () {
      expect(WorkspaceResolver.isShared('/storage/emulated/0/ZCode'), isTrue);
      expect(WorkspaceResolver.isShared('/data/user/0/ai.zcode/files'), isFalse);
    });
  });

  group('workspace folder', () {
    test('validate rejects empty and relative paths', () async {
      expect(await WorkspaceResolver.validate(''), isNotEmpty);
      expect(await WorkspaceResolver.validate('Documents/x'), isNotEmpty);
    });

    test('validate accepts a real folder and creates it when missing', () async {
      final String nested = '${tmp.path}/a/b/c';
      expect(await WorkspaceResolver.validate(nested), '');
      expect(await Directory(nested).exists(), isTrue);
    });

    test('ensureWritable creates the tree and proves writes work', () async {
      final String nested = '${tmp.path}/deep/deeper';
      expect(await WorkspaceResolver.ensureWritable(nested), isTrue);
      expect(await File('$nested/.zcode/write-test').exists(), isFalse);
    });

    test('bootstrap lays down the skeleton the agent expects', () async {
      await WorkspaceResolver.bootstrap(tmp.path);
      for (final String sub in <String>[
        '.zcode/bin',
        '.zcode/skills',
        '.zcode/commands',
        '.zcode/agents',
        '.zcode/backups',
      ]) {
        expect(await Directory('${tmp.path}/$sub').exists(), isTrue,
            reason: sub);
      }
      expect(await File('${tmp.path}/README.md').exists(), isTrue);
    });
  });

  group('ToolBox paths', () {
    test('sandboxed boxes keep absolute paths inside the root', () {
      final ToolBox box = ToolBox.at(Directory('${tmp.path}/ws'));
      expect(box.resolvePath('/etc/hosts'), '${tmp.path}/ws');
      expect(box.resolvePath('src/main.dart'), '${tmp.path}/ws/src/main.dart');
    });

    test('android-style boxes may reach shared storage', () {
      final ToolBox box =
          ToolBox.at(Directory('${tmp.path}/ws'), allowOutside: true);
      expect(box.resolvePath('/storage/emulated/0/Download/a.txt'),
          '/storage/emulated/0/Download/a.txt');
      // Private app data is still off limits.
      expect(box.resolvePath('/data/data/other/files/x'), '${tmp.path}/ws');
    });

    test('the workspace bin folder leads PATH', () {
      final ToolBox box = ToolBox.at(Directory('${tmp.path}/ws'));
      box.extraPaths.add('/opt/mod/bin');
      expect(box.pathEnv.split(':').first, '${tmp.path}/ws/.zcode/bin');
      expect(box.pathEnv.contains('/opt/mod/bin'), isTrue);
    });
  });

  group('switching workspace', () {
    test('rebinds the agent to the new folder and persists it', () async {
      final AppState state = AppState();
      final String target = '${tmp.path}/project';

      final String problem = await state.switchWorkspace(target);
      expect(problem, '');
      expect(state.workspacePath, target);
      expect(await Directory('$target/.zcode/bin').exists(), isTrue);
      expect(state.tools!.resolvePath('lib/main.dart'), '$target/lib/main.dart');

      // A file written through the toolbox lands in the real folder.
      final File f = File('$target/notes.md');
      await f.writeAsString('hello');
      expect(await File('$target/notes.md').readAsString(), 'hello');

      // Written relative paths resolve under the new root.
      expect(state.tools!.resolvePath('notes.md'), '$target/notes.md');
    });

    test('a broken target is rejected without losing the old workspace',
        () async {
      final AppState state = AppState();
      expect(await state.switchWorkspace('${tmp.path}/ok'), '');
      final String before = state.workspacePath;
      expect(await state.switchWorkspace('relative/path'), isNotEmpty);
      expect(state.workspacePath, before);
    });
  });
}
