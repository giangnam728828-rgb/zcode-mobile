import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

enum ToolStatus { pending, running, done, failed, denied }

/// One tool invocation as shown in the transcript and replayed to the model.
class ToolCall {
  ToolCall({
    required this.id,
    required this.name,
    this.input = const <String, dynamic>{},
    this.output = '',
    this.status = ToolStatus.pending,
  });

  final String id;
  final String name;
  Map<String, dynamic> input;
  String output;
  ToolStatus status;

  String get title {
    switch (name) {
      case 'bash':
        return '${input['command'] ?? ''}';
      case 'read_file':
        return '${input['path'] ?? ''}';
      case 'write_file':
        return '写入 ${input['path'] ?? ''}';
      case 'edit_file':
        return '修改 ${input['path'] ?? ''}';
      case 'list_dir':
        return '${input['path'] ?? '.'}';
      case 'grep':
        return '${input['pattern'] ?? ''}';
      default:
        return name;
    }
  }

  bool get isShell => name == 'bash';

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'input': input,
        if (output.isNotEmpty) 'output': output,
        'status': status.index,
      };

  static ToolCall fromJson(Map<String, dynamic> json) => ToolCall(
        id: '${json['id']}',
        name: '${json['name']}',
        input: (json['input'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{},
        output: '${json['output'] ?? ''}',
        status: ToolStatus.values[
            ((json['status'] as int?) ?? 0).clamp(0, ToolStatus.values.length - 1)],
      );
}

class ToolSpec {
  const ToolSpec(this.name, this.description, this.schema);
  final String name;
  final String description;
  final Map<String, dynamic> schema;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'description': description,
        'input_schema': schema,
      };
}

/// Executes shell commands and file edits inside a private workspace, the way
/// the desktop agent does — but scoped to the app sandbox on Android.
class ToolBox {
  ToolBox._(this.workspace);

  /// Test hook: run against an explicit directory without the platform plugin.
  ToolBox.at(Directory dir) : workspace = dir;

  final Directory workspace;

  static Future<ToolBox> open() async {
    final Directory base = await getApplicationSupportDirectory();
    final Directory ws = Directory('${base.path}/workspace');
    if (!await ws.exists()) {
      await ws.create(recursive: true);
    }
    return ToolBox._(ws);
  }

  static const int _maxOutput = 12000;

  static List<ToolSpec> get specs => const <ToolSpec>[
        ToolSpec(
          'bash',
          'Run a shell command in the workspace. Android provides sh plus the '
              'usual toybox utilities (ls, cat, grep, sed, find, curl...). '
              'Use it to inspect files, run scripts and check results.',
          <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'command': <String, dynamic>{'type': 'string', 'description': 'Shell command'},
              'timeout': <String, dynamic>{
                'type': 'integer',
                'description': 'Seconds before the command is killed (default 60)',
              },
            },
            'required': <String>['command'],
          },
        ),
        ToolSpec(
          'read_file',
          'Read a text file. Paths are relative to the workspace unless absolute.',
          <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'path': <String, dynamic>{'type': 'string'},
              'offset': <String, dynamic>{'type': 'integer', 'description': 'First line (1-based)'},
              'limit': <String, dynamic>{'type': 'integer', 'description': 'Max lines'},
            },
            'required': <String>['path'],
          },
        ),
        ToolSpec(
          'write_file',
          'Create or overwrite a text file with the given content.',
          <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'path': <String, dynamic>{'type': 'string'},
              'content': <String, dynamic>{'type': 'string'},
            },
            'required': <String>['path', 'content'],
          },
        ),
        ToolSpec(
          'edit_file',
          'Replace one exact occurrence of old_string with new_string.',
          <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'path': <String, dynamic>{'type': 'string'},
              'old_string': <String, dynamic>{'type': 'string'},
              'new_string': <String, dynamic>{'type': 'string'},
            },
            'required': <String>['path', 'old_string', 'new_string'],
          },
        ),
        ToolSpec(
          'list_dir',
          'List entries of a directory in the workspace.',
          <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'path': <String, dynamic>{'type': 'string', 'description': 'Defaults to the workspace root'},
            },
          },
        ),
        ToolSpec(
          'grep',
          'Search files for a regular expression and return matching lines.',
          <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'pattern': <String, dynamic>{'type': 'string'},
              'path': <String, dynamic>{'type': 'string', 'description': 'File or directory'},
              'glob': <String, dynamic>{'type': 'string', 'description': 'e.g. *.dart'},
            },
            'required': <String>['pattern'],
          },
        ),
      ];

  Future<String> execute(ToolCall call) async {
    switch (call.name) {
      case 'bash':
        return _bash(call);
      case 'read_file':
        return _read(call);
      case 'write_file':
        return _write(call);
      case 'edit_file':
        return _edit(call);
      case 'list_dir':
        return _list(call);
      case 'grep':
        return _grep(call);
      default:
        return 'Unknown tool: ${call.name}';
    }
  }

  /// Shell edits and destructive commands always ask first.
  bool requiresApproval(ToolCall call) {
    if (call.name == 'write_file' || call.name == 'edit_file') return false;
    if (call.name != 'bash') return false;
    final String cmd = '${call.input['command'] ?? ''}';
    return RegExp(r'(^|\s|\|)(rm|mv|dd|mkfs|chmod|chown|kill|pkill|su|sudo|reboot)\b')
            .hasMatch(cmd) ||
        cmd.contains('>') && !cmd.contains('>>');
  }

  // -------------------------------------------------------------- execution

  Future<String> _bash(ToolCall call) async {
    final String command = '${call.input['command'] ?? ''}'.trim();
    if (command.isEmpty) return 'Empty command';
    final int seconds = (call.input['timeout'] as int?) ?? 60;
    final String shell = Platform.isAndroid ? '/system/bin/sh' : '/bin/sh';
    final String path = Platform.isAndroid
        ? '/system/bin:/system/xbin:/vendor/bin:/product/bin:/bin'
        : '/usr/local/bin:/usr/bin:/bin';
    try {
      final ProcessResult r = await Process.run(
        shell,
        <String>['-c', command],
        workingDirectory: workspace.path,
        environment: <String, String>{
          'PATH': path,
          'HOME': workspace.path,
          'TMPDIR': '${workspace.path}/.tmp',
        },
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(Duration(seconds: seconds));
      final String out = '${r.stdout ?? ''}'.trim();
      final String err = '${r.stderr ?? ''}'.trim();
      final StringBuffer b = StringBuffer();
      if (out.isNotEmpty) b.writeln(out);
      if (err.isNotEmpty) {
        if (b.isNotEmpty) b.writeln();
        b.writeln('[stderr]');
        b.writeln(err);
      }
      if (b.isEmpty) b.writeln('(no output)');
      b.writeln('\n[exit ${r.exitCode}]');
      return _clip(b.toString());
    } on TimeoutException {
      return 'Command timed out after ${seconds}s';
    } catch (e) {
      return 'Command failed: $e';
    }
  }

  Future<String> _read(ToolCall call) async {
    final File f = File(_resolve('${call.input['path'] ?? ''}'));
    if (!await f.exists()) return 'File not found: ${f.path}';
    final List<String> lines = await f.readAsLines();
    final int offset = ((call.input['offset'] as int?) ?? 1).clamp(1, lines.length + 1);
    final int limit = ((call.input['limit'] as int?) ?? 400).clamp(1, 2000);
    final int end = (offset - 1 + limit).clamp(0, lines.length);
    final String body = lines.sublist(offset - 1, end).join('\n');
    return _clip('${f.path} (lines $offset-$end of ${lines.length})\n$body');
  }

  Future<String> _write(ToolCall call) async {
    final File f = File(_resolve('${call.input['path'] ?? ''}'));
    await f.parent.create(recursive: true);
    await f.writeAsString('${call.input['content'] ?? ''}');
    final int size = await f.length();
    return 'Wrote ${f.path} ($size bytes)';
  }

  Future<String> _edit(ToolCall call) async {
    final File f = File(_resolve('${call.input['path'] ?? ''}'));
    if (!await f.exists()) return 'File not found: ${f.path}';
    final String oldStr = '${call.input['old_string'] ?? ''}';
    final String newStr = '${call.input['new_string'] ?? ''}';
    final String text = await f.readAsString();
    final int at = text.indexOf(oldStr);
    if (at < 0) return 'old_string not found in ${f.path}';
    if (text.contains(oldStr, at + 1)) {
      return 'old_string appears more than once; include more context';
    }
    await f.writeAsString(text.replaceRange(at, at + oldStr.length, newStr));
    return 'Updated ${f.path}';
  }

  Future<String> _list(ToolCall call) async {
    final Directory d = Directory(_resolve('${call.input['path'] ?? '.'}'));
    if (!await d.exists()) return 'Not a directory: ${d.path}';
    final List<FileSystemEntity> items = await d.list().toList()
      ..sort((FileSystemEntity a, FileSystemEntity b) => a.path.compareTo(b.path));
    if (items.isEmpty) return '(empty)';
    final StringBuffer b = StringBuffer();
    for (final FileSystemEntity e in items.take(200)) {
      final String name = e.path.split('/').last;
      b.writeln(e is Directory ? '$name/' : name);
    }
    return _clip(b.toString());
  }

  Future<String> _grep(ToolCall call) async {
    final String pattern = '${call.input['pattern'] ?? ''}';
    if (pattern.isEmpty) return 'Empty pattern';
    final RegExp re;
    try {
      re = RegExp(pattern);
    } catch (e) {
      return 'Bad regex: $e';
    }
    final FileSystemEntity target = FileSystemEntity.typeSync(
                _resolve('${call.input['path'] ?? '.'}')) ==
            FileSystemEntityType.file
        ? File(_resolve('${call.input['path'] ?? '.'}'))
        : Directory(_resolve('${call.input['path'] ?? '.'}'));
    final String glob = '${call.input['glob'] ?? ''}';
    final StringBuffer b = StringBuffer();
    int hits = 0;
    Future<void> scan(File f) async {
      if (hits >= 200) return;
      try {
        if (await f.length() > 512 * 1024) return;
        final List<String> lines = await f.readAsLines();
        for (int i = 0; i < lines.length && hits < 200; i++) {
          if (re.hasMatch(lines[i])) {
            b.writeln('${f.path}:${i + 1}: ${lines[i]}');
            hits++;
          }
        }
      } catch (_) {}
    }

    if (target is File) {
      await scan(target);
    } else {
      await for (final FileSystemEntity e
          in (target as Directory).list(recursive: true)) {
        if (hits >= 200) break;
        if (e is! File) continue;
        if (e.path.contains('/.git/')) continue;
        if (glob.isNotEmpty && !_matchGlob(e.path.split('/').last, glob)) continue;
        await scan(e);
      }
    }
    return hits == 0 ? 'No matches' : _clip(b.toString());
  }

  static bool _matchGlob(String name, String glob) {
    final String rx = glob
        .replaceAll('.', r'\.')
        .replaceAll('*', '.*')
        .replaceAll('?', '.');
    return RegExp('^$rx\$').hasMatch(name);
  }

  String _resolve(String raw) {
    final String p = raw.trim();
    final String root = _normalize(workspace.path);
    final String candidate = p.isEmpty || p == '.'
        ? root
        : p.startsWith('/')
            ? p
            : '$root/$p';
    final String normalized = _normalize(candidate);
    if (normalized == root || normalized.startsWith('$root/')) return normalized;
    // Anything reaching outside the sandbox collapses to the root itself, so
    // the caller just sees "not found" instead of a file from the real system.
    return root;
  }

  /// Collapses `.` / `..` segments without touching the file system.
  static String _normalize(String path) {
    final List<String> out = <String>[];
    for (final String part in path.split('/')) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        if (out.isNotEmpty) out.removeLast();
        continue;
      }
      out.add(part);
    }
    return '/${out.join('/')}';
  }

  static String _clip(String s) =>
      s.length <= _maxOutput ? s : '${s.substring(0, _maxOutput)}\n… [truncated]';
}
