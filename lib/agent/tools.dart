import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

enum ToolStatus { pending, running, done, failed, denied }

/// One checklist row emitted by the `todo_write` tool.
class TodoEntry {
  const TodoEntry(this.content, this.status);

  final String content;
  final String status; // pending | in_progress | completed

  bool get done => status == 'completed';
  bool get active => status == 'in_progress';

  static List<TodoEntry> parse(Object? raw) {
    final List<TodoEntry> out = <TodoEntry>[];
    if (raw is! List) return out;
    for (final Object? item in raw) {
      if (item is Map) {
        final String text = '${item['content'] ?? item['title'] ?? ''}'.trim();
        if (text.isEmpty) continue;
        final String status = '${item['status'] ?? 'pending'}';
        out.add(TodoEntry(text, status));
      } else if (item != null) {
        final String text = '$item'.trim();
        if (text.isNotEmpty) out.add(TodoEntry(text, 'pending'));
      }
    }
    return out;
  }
}

/// One tool invocation as shown in the transcript and replayed to the model.
class ToolCall {
  ToolCall({
    required this.id,
    required this.name,
    this.input = const <String, dynamic>{},
    this.output = '',
    this.status = ToolStatus.pending,
    this.startedAt,
    this.endedAt,
  });

  final String id;
  final String name;
  Map<String, dynamic> input;
  String output;
  ToolStatus status;
  DateTime? startedAt;
  DateTime? endedAt;

  List<TodoEntry> get todos => TodoEntry.parse(input['todos']);

  Duration? get duration {
    if (startedAt == null || endedAt == null) return null;
    return endedAt!.difference(startedAt!);
  }

  String get title {
    switch (name) {
      case 'bash':
        return '${input['command'] ?? ''}';
      case 'read_file':
      case 'write_file':
      case 'edit_file':
      case 'delete_file':
        return '${input['path'] ?? ''}';
      case 'move_file':
        return '${input['from'] ?? ''} → ${input['to'] ?? ''}';
      case 'make_dir':
        return '${input['path'] ?? ''}';
      case 'list_dir':
        return '${input['path'] ?? '.'}';
      case 'grep':
        return '${input['pattern'] ?? ''}';
      case 'glob':
        return '${input['pattern'] ?? ''}';
      case 'web_fetch':
        return '${input['url'] ?? ''}';
      case 'todo_write':
        return '计划 · ${todos.where((TodoEntry t) => t.done).length}/${todos.length}';
      case 'task':
        return '${input['agent'] ?? '子智能体'} · ${input['description'] ?? ''}';
      default:
        return name;
    }
  }

  bool get isShell => name == 'bash';

  /// Short preview used when the card is collapsed.
  String get subtitle {
    if (status == ToolStatus.running) return '执行中…';
    if (status == ToolStatus.denied) return '已拒绝';
    final String first = output
        .trim()
        .split('\n')
        .firstWhere((String l) => l.trim().isNotEmpty, orElse: () => '');
    final String t = first.length > 90 ? '${first.substring(0, 90)}…' : first;
    switch (status) {
      case ToolStatus.done:
        return t.isEmpty ? '完成' : t;
      case ToolStatus.failed:
        return t.isEmpty ? '失败' : t;
      default:
        return t;
    }
  }

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
        input: (json['input'] as Map?)?.cast<String, dynamic>() ??
            <String, dynamic>{},
        output: '${json['output'] ?? ''}',
        status: ToolStatus.values[((json['status'] as int?) ?? 0)
            .clamp(0, ToolStatus.values.length - 1)],
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

/// A tool contributed from outside the built-in set — an MCP server, or any
/// plugin that wants to expose a function to the model.
class ExternalTool {
  ExternalTool(this.spec, this.run, {this.server = ''});

  final ToolSpec spec;
  final Future<String> Function(Map<String, dynamic> input) run;

  /// MCP server name, so a reconnect can drop the previous registrations.
  final String server;
}

/// Executes shell commands and file edits in the user's real workspace.
///
/// On a phone that is a folder the user picked on shared storage, so the paths
/// here are the same ones their file manager and Termux see — no virtual file
/// system in between.
class ToolBox {
  ToolBox._(this.workspace, {bool? allowOutside})
      : allowOutside = allowOutside ?? _androidByDefault;

  /// Test hook: run against an explicit directory without the platform plugin.
  ToolBox.at(this.workspace, {this.allowOutside = false});

  final Directory workspace;

  /// Whether absolute paths outside [workspace] may be read and written. True
  /// on Android once the workspace lives on shared storage: the user's own
  /// folders are the point, so a second layer of sandboxing would only get in
  /// the way.
  final bool allowOutside;

  static bool get _androidByDefault {
    if (kIsWeb) return false;
    try {
      return Platform.isAndroid;
    } catch (_) {
      return false;
    }
  }

  /// Extra `bin` directories contributed by installed modules.
  final List<String> extraPaths = <String>[];

  /// Tools contributed by MCP servers and plugins, keyed by tool name.
  final Map<String, ExternalTool> _external = <String, ExternalTool>{};

  /// Set by AppState so the `task` tool can spawn a child agent.
  Future<String> Function(String prompt, {String? agent})? subagent;

  /// Snapshot bookkeeping for "undo this turn".
  String? _turnStamp;
  final Map<String, String> _backups = <String, String>{};

  bool get canUndo => _backups.isNotEmpty;

  List<ExternalTool> get externalTools => _external.values.toList();

  void registerExternal(ExternalTool tool) {
    _external[tool.spec.name] = tool;
  }

  /// Drops every tool that came from one server, used before reconnecting.
  void clearExternal({String? server, String? prefix}) {
    _external.removeWhere((String name, ExternalTool t) =>
        (server != null && t.server == server) ||
        (prefix != null && name.startsWith(prefix)));
  }

  /// Built-in tools plus whatever MCP/plugins registered right now.
  List<ToolSpec> get specsAll => <ToolSpec>[
        ...specs,
        for (final ExternalTool t in _external.values) t.spec,
      ];

  static Future<ToolBox> open() async {
    final Directory base = await getApplicationSupportDirectory();
    final Directory ws = Directory('${base.path}/workspace');
    if (!await ws.exists()) {
      await ws.create(recursive: true);
    }
    return ToolBox._(ws);
  }

  /// Opens an explicit folder — the one the user picked in the picker.
  static Future<ToolBox> openAt(String path) async {
    final Directory ws = Directory(path);
    if (!await ws.exists()) await ws.create(recursive: true);
    return ToolBox._(ws);
  }

  static const int _maxOutput = 14000;

  /// `bin` folders searched before the system ones. Keeping the workspace one
  /// first means a script dropped in `.zcode/bin` shadows a system tool.
  List<String> get binPaths => <String>[
        '${workspace.path}/.zcode/bin',
        ...extraPaths,
      ];

  String get pathEnv {
    final String base = _androidByDefault
        ? '/system/bin:/system/xbin:/vendor/bin:/product/bin:/bin'
        : '/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin';
    return '${binPaths.join(':')}:$base';
  }

  static List<ToolSpec> get specs => const <ToolSpec>[
        ToolSpec(
          'bash',
          'Run a shell command in the workspace. This is a real shell on the '
              'user\'s phone: sh plus the toybox utilities (ls, cat, grep, sed, '
              'find, tar, curl...), anything installed under .zcode/bin, and '
              'the module binaries. Use it to inspect files, run scripts, '
              'check build output and verify results.',
          <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'command': <String, dynamic>{
                'type': 'string',
                'description': 'Shell command'
              },
              'cwd': <String, dynamic>{
                'type': 'string',
                'description':
                    'Directory to run in, relative to the workspace or absolute'
              },
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
              'offset': <String, dynamic>{
                'type': 'integer',
                'description': 'First line (1-based)'
              },
              'limit': <String, dynamic>{
                'type': 'integer',
                'description': 'Max lines'
              },
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
          'List entries of a directory in the workspace, with sizes.',
          <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'path': <String, dynamic>{
                'type': 'string',
                'description': 'Defaults to the workspace root'
              },
            },
          },
        ),
        ToolSpec(
          'glob',
          'Find files by glob pattern (supports *, ? and **) inside the workspace.',
          <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'pattern': <String, dynamic>{
                'type': 'string',
                'description': 'e.g. **/*.dart or lib/*.txt'
              },
              'path': <String, dynamic>{
                'type': 'string',
                'description': 'Directory to search, defaults to the workspace'
              },
            },
            'required': <String>['pattern'],
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
              'glob': <String, dynamic>{
                'type': 'string',
                'description': 'Only files whose name matches, e.g. *.dart'
              },
            },
            'required': <String>['pattern'],
          },
        ),
        ToolSpec(
          'make_dir',
          'Create a directory (parents included).',
          <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'path': <String, dynamic>{'type': 'string'},
            },
            'required': <String>['path'],
          },
        ),
        ToolSpec(
          'move_file',
          'Move or rename a file or directory inside the workspace.',
          <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'from': <String, dynamic>{'type': 'string'},
              'to': <String, dynamic>{'type': 'string'},
            },
            'required': <String>['from', 'to'],
          },
        ),
        ToolSpec(
          'delete_file',
          'Delete a file, or a directory when recursive is true. '
              'Always confirm the path first.',
          <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'path': <String, dynamic>{'type': 'string'},
              'recursive': <String, dynamic>{'type': 'boolean'},
            },
            'required': <String>['path'],
          },
        ),
        ToolSpec(
          'web_fetch',
          'Fetch an http(s) URL and return readable text (HTML is stripped). '
              'Use it for docs, changelogs or API responses.',
          <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'url': <String, dynamic>{'type': 'string'},
              'format': <String, dynamic>{
                'type': 'string',
                'enum': <String>['text', 'raw'],
                'description': 'text (default) strips HTML tags',
              },
              'max_chars': <String, dynamic>{'type': 'integer'},
            },
            'required': <String>['url'],
          },
        ),
        ToolSpec(
          'task',
          'Delegate a self-contained sub-task to a child agent. The child has '
              'its own context, the same workspace and tools, and returns only '
              'a final report — use it for parallel or isolated investigations '
              'so this conversation stays short. Optional `agent` picks a '
              'definition from .zcode/agents.',
          <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'description': <String, dynamic>{
                'type': 'string',
                'description': 'Short label shown in the transcript',
              },
              'prompt': <String, dynamic>{
                'type': 'string',
                'description': 'Full instructions for the child agent',
              },
              'agent': <String, dynamic>{
                'type': 'string',
                'description': 'Agent file name under .zcode/agents (optional)',
              },
            },
            'required': <String>['description', 'prompt'],
          },
        ),
        ToolSpec(
          'todo_write',
          'Publish or update the task checklist for the current turn. '
              'Call it at the start of a multi-step task and after finishing steps.',
          <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'todos': <String, dynamic>{
                'type': 'array',
                'items': <String, dynamic>{
                  'type': 'object',
                  'properties': <String, dynamic>{
                    'content': <String, dynamic>{'type': 'string'},
                    'status': <String, dynamic>{
                      'type': 'string',
                      'enum': <String>['pending', 'in_progress', 'completed'],
                    },
                  },
                  'required': <String>['content', 'status'],
                },
              },
            },
            'required': <String>['todos'],
          },
        ),
      ];

  /// Starts a checkpoint. Every file the agent touches from now on is copied
  /// to `.zcode/backups/<stamp>/` before it changes, so one tap can roll the
  /// whole turn back.
  void beginTurn() {
    final DateTime now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    _turnStamp = '${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}-'
        '${now.millisecond}';
    _backups.clear();
  }

  /// Restores every file touched since [beginTurn]. Returns how many paths
  /// were restored (or removed, for files newly created in the turn).
  Future<int> undoLastTurn() async {
    int restored = 0;
    final List<MapEntry<String, String>> entries = _backups.entries.toList();
    for (final MapEntry<String, String> e in entries) {
      // Keys for files outside the workspace are stored as `external/<abs>`.
      final String abs = e.key.startsWith('external/')
          ? e.key.substring('external'.length)
          : _resolve(e.key);
      try {
        if (e.value.isEmpty) {
          final FileSystemEntityType t = FileSystemEntity.typeSync(abs);
          if (t == FileSystemEntityType.directory) {
            await Directory(abs).delete(recursive: true);
          } else if (t != FileSystemEntityType.notFound) {
            await File(abs).delete();
          }
        } else {
          final File backup = File(e.value);
          if (await backup.exists()) {
            await Directory(File(abs).parent.path).create(recursive: true);
            await backup.copy(abs);
          }
        }
        restored++;
      } catch (_) {}
    }
    final String? stamp = _turnStamp;
    _backups.clear();
    if (stamp != null) {
      try {
        final Directory dir = Directory('${workspace.path}/.zcode/backups/$stamp');
        if (await dir.exists()) await dir.delete(recursive: true);
      } catch (_) {}
    }
    return restored;
  }

  /// Copies a file aside before it is modified. Directories and huge files are
  /// skipped on purpose — the goal is undo for source-sized edits.
  Future<void> _snapshot(String absPath) async {
    final String? stamp = _turnStamp;
    if (stamp == null) return;
    final String relRaw = relPath(absPath);
    // Files outside the workspace need a key that cannot collide with a
    // relative path, so they get an `external/` prefix holding the abs path.
    final String rel = relRaw.startsWith('/') ? 'external$relRaw' : relRaw;
    if (rel.isEmpty || _backups.containsKey(rel)) return;
    final FileSystemEntityType type = FileSystemEntity.typeSync(absPath);
    if (type == FileSystemEntityType.directory) return;
    if (type == FileSystemEntityType.notFound) {
      _backups[rel] = '';
      return;
    }
    final File f = File(absPath);
    try {
      if (await f.length() > 2 * 1024 * 1024) return;
      final File target = File('${workspace.path}/.zcode/backups/$stamp/$rel');
      await target.parent.create(recursive: true);
      await f.copy(target.path);
      _backups[rel] = target.path;
    } catch (_) {}
  }

  Future<String> execute(ToolCall call) async {
    call.startedAt ??= DateTime.now();
    try {
      return await _dispatch(call);
    } finally {
      call.endedAt = DateTime.now();
    }
  }

  Future<String> _dispatch(ToolCall call) async {
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
      case 'glob':
        return _glob(call);
      case 'grep':
        return _grep(call);
      case 'make_dir':
        return _mkdir(call);
      case 'move_file':
        return _move(call);
      case 'delete_file':
        return _delete(call);
      case 'web_fetch':
        return _fetch(call);
      case 'todo_write':
        return _todo(call);
      case 'task':
        return _task(call);
      default:
        final ExternalTool? ext = _external[call.name];
        if (ext != null) {
          try {
            return _clip(await ext.run(call.input));
          } catch (e) {
            return 'Tool ${call.name} failed: $e';
          }
        }
        return 'Unknown tool: ${call.name}';
    }
  }

  /// Shell edits and destructive commands always ask first.
  bool requiresApproval(ToolCall call) {
    if (call.name == 'delete_file' || call.name == 'move_file') return true;
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
    final String dir = _cwd(call.input['cwd']);
    final String shell = _androidByDefault ? '/system/bin/sh' : '/bin/sh';
    try {
      final ProcessResult r = await Process.run(
        shell,
        <String>['-c', command],
        workingDirectory: dir,
        environment: <String, String>{
          'PATH': pathEnv,
          'HOME': workspace.path,
          'PWD': dir,
          'TMPDIR': '${workspace.path}/.tmp',
          'ZCODE_WORKSPACE': workspace.path,
          'TERM': 'dumb',
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
      if (r.exitCode == 126 || r.exitCode == 127) {
        b.writeln('\n[hint] 126/127 means "not found" or "not executable". '
            'Shared storage on Android is usually mounted noexec, so run a '
            'script with `sh <path>` instead of calling it directly.');
      }
      b.writeln('\n[exit ${r.exitCode}]');
      return _clip(b.toString());
    } on TimeoutException {
      return 'Command timed out after ${seconds}s';
    } catch (e) {
      return 'Command failed: $e';
    }
  }

  /// Resolves a requested working directory, falling back to the workspace.
  String _cwd(Object? raw) {
    final String wanted = '${raw ?? ''}'.trim();
    if (wanted.isEmpty) return workspace.path;
    try {
      final String abs = _resolve(wanted);
      if (FileSystemEntity.isDirectorySync(abs)) return abs;
    } catch (_) {}
    return workspace.path;
  }

  Future<String> _read(ToolCall call) async {
    final File f = File(_resolve('${call.input['path'] ?? ''}'));
    if (!await f.exists()) return 'File not found: ${f.path}';
    final int size = await f.length();
    if (size > 2 * 1024 * 1024) {
      return 'File is ${_size(size)}; too large to read as text. '
          'Use bash (head/tail/grep) to inspect parts of it.';
    }
    final String raw = await f.readAsString();
    if (raw.contains('\u0000')) {
      return 'Binary file (${_size(size)}): ${f.path}';
    }
    final List<String> lines = const LineSplitter().convert(raw);
    final int total = lines.length;
    final int offset = ((call.input['offset'] as int?) ?? 1).clamp(1, total + 1);
    final int limit = ((call.input['limit'] as int?) ?? 400).clamp(1, 2000);
    final int end = (offset - 1 + limit).clamp(0, total);
    final String body = lines.sublist(offset - 1, end).join('\n');
    return _clip('${f.path} (lines $offset-$end of $total)\n$body');
  }

  Future<String> _write(ToolCall call) async {
    final File f = File(_resolve('${call.input['path'] ?? ''}'));
    if (await f.exists() && await f.length() > 4 * 1024 * 1024) {
      return 'Refusing to overwrite a file larger than 4 MB: ${f.path}';
    }
    await _snapshot(f.path);
    await f.parent.create(recursive: true);
    await f.writeAsString('${call.input['content'] ?? ''}');
    final int size = await f.length();
    return 'Wrote ${f.path} ($size bytes)';
  }

  Future<String> _edit(ToolCall call) async {
    final File f = File(_resolve('${call.input['path'] ?? ''}'));
    if (!await f.exists()) return 'File not found: ${f.path}';
    await _snapshot(f.path);
    final String oldStr = '${call.input['old_string'] ?? ''}';
    final String newStr = '${call.input['new_string'] ?? ''}';
    if (oldStr.isEmpty) return 'old_string must not be empty';
    final String text = await f.readAsString();
    final int at = text.indexOf(oldStr);
    if (at < 0) return 'old_string not found in ${f.path}';
    if (text.contains(oldStr, at + 1)) {
      return 'old_string appears more than once; include more context';
    }
    await f.writeAsString(text.replaceRange(at, at + oldStr.length, newStr));
    return 'Updated ${f.path} (${_lineCount(newStr) - _lineCount(oldStr)} lines)';
  }

  Future<String> _list(ToolCall call) async {
    final Directory d = Directory(_resolve('${call.input['path'] ?? '.'}'));
    if (!await d.exists()) return 'Not a directory: ${d.path}';
    final List<FileSystemEntity> items = await d.list().toList()
      ..sort((FileSystemEntity a, FileSystemEntity b) {
        final bool ad = a is Directory;
        final bool bd = b is Directory;
        if (ad != bd) return ad ? -1 : 1;
        return a.path.toLowerCase().compareTo(b.path.toLowerCase());
      });
    if (items.isEmpty) return '(empty)';
    final StringBuffer b = StringBuffer();
    for (final FileSystemEntity e in items.take(300)) {
      final String name = e.path.split('/').last;
      if (e is Directory) {
        b.writeln('$name/');
      } else if (e is File) {
        b.writeln('$name  (${_size(await e.length())})');
      } else {
        b.writeln(name);
      }
    }
    return _clip(b.toString());
  }

  Future<String> _glob(ToolCall call) async {
    final String pattern = '${call.input['pattern'] ?? ''}'.trim();
    if (pattern.isEmpty) return 'Empty pattern';
    final Directory root = Directory(_resolve('${call.input['path'] ?? '.'}'));
    if (!await root.exists()) return 'Not a directory: ${root.path}';
    final String base = _normalize(workspace.path);
    final List<String> hits = <String>[];
    await for (final FileSystemEntity e
        in root.list(recursive: true, followLinks: false)) {
      if (hits.length >= 300) break;
      if (e is! File) continue;
      final String rel = e.path.startsWith('$base/')
          ? e.path.substring(base.length + 1)
          : e.path;
      if (rel.startsWith('.git/') || rel.contains('/.git/')) continue;
      if (rel.startsWith('.zcode/modules/')) continue;
      final String probe = pattern.contains('/') ? rel : rel.split('/').last;
      if (_globMatch(probe, pattern)) hits.add(rel);
    }
    hits.sort();
    return hits.isEmpty ? 'No files match $pattern' : _clip(hits.join('\n'));
  }

  Future<String> _mkdir(ToolCall call) async {
    final Directory d = Directory(_resolve('${call.input['path'] ?? ''}'));
    await d.create(recursive: true);
    return 'Created ${d.path}';
  }

  Future<String> _move(ToolCall call) async {
    final String from = _resolve('${call.input['from'] ?? ''}');
    final String to = _resolve('${call.input['to'] ?? ''}');
    if (from == to) return 'Source and destination are the same';
    final FileSystemEntityType type = FileSystemEntity.typeSync(from);
    if (type == FileSystemEntityType.notFound) return 'Not found: $from';
    if (FileSystemEntity.typeSync(to) != FileSystemEntityType.notFound) {
      return 'Destination already exists: $to';
    }
    await _snapshot(from);
    await Directory(File(to).parent.path).create(recursive: true);
    if (type == FileSystemEntityType.directory) {
      await Directory(from).rename(to);
    } else {
      await File(from).rename(to);
      // The moved file is new at the destination; undo removes it.
      final String relTo = relPath(to);
      if (relTo.isNotEmpty) _backups.putIfAbsent(relTo, () => '');
    }
    return 'Moved $from → $to';
  }

  Future<String> _delete(ToolCall call) async {
    final String path = _resolve('${call.input['path'] ?? ''}');
    final bool recursive = (call.input['recursive'] as bool?) ?? false;
    final FileSystemEntityType type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.notFound) return 'Not found: $path';
    if (type == FileSystemEntityType.directory) {
      // Snapshot each file so a recursive delete can be undone.
      int seen = 0;
      try {
        await for (final FileSystemEntity e
            in Directory(path).list(recursive: true, followLinks: false)) {
          if (e is! File) continue;
          await _snapshot(e.path);
          if (++seen >= 300) break;
        }
      } catch (_) {}
    } else {
      await _snapshot(path);
    }
    if (type == FileSystemEntityType.directory) {
      final List<FileSystemEntity> items = await Directory(path).list().toList();
      if (items.isNotEmpty && !recursive) {
        return 'Directory is not empty; pass recursive=true to delete it';
      }
      await Directory(path).delete(recursive: recursive);
    } else {
      await File(path).delete();
    }
    return 'Deleted $path';
  }

  Future<String> _fetch(ToolCall call) async {
    final String rawUrl = '${call.input['url'] ?? ''}'.trim();
    final Uri? uri = Uri.tryParse(rawUrl);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      return 'Only http(s) URLs are supported';
    }
    final int maxChars =
        ((call.input['max_chars'] as int?) ?? 8000).clamp(500, 40000);
    final bool strip = '${call.input['format'] ?? 'text'}' != 'raw';
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..userAgent = 'ZCode-Mobile/3.0 (+https://github.com/zai-org/ZCode)';
    try {
      final HttpClientRequest req = await client.getUrl(uri);
      req.headers.set('accept', 'text/html,application/json,text/plain,*/*');
      final HttpClientResponse resp = await req.close();
      final String body = await resp
          .transform(const Utf8Decoder(allowMalformed: true))
          .join()
          .timeout(const Duration(seconds: 20));
      final String text = strip ? _htmlToText(body) : body;
      final String clipped =
          text.length > maxChars ? '${text.substring(0, maxChars)}\n… [truncated]' : text;
      return 'HTTP ${resp.statusCode} · ${uri.host}\n\n$clipped';
    } on TimeoutException {
      return 'Request timed out: $rawUrl';
    } catch (e) {
      return 'Fetch failed: $e';
    } finally {
      client.close(force: true);
    }
  }

  Future<String> _todo(ToolCall call) async {
    final List<TodoEntry> items = ToolEntryHelper.parse(call.input['todos']);
    if (items.isEmpty) return 'No todo items provided';
    final StringBuffer b = StringBuffer();
    for (final TodoEntry t in items) {
      final String box = t.done ? '[x]' : (t.active ? '[~]' : '[ ]');
      b.writeln('$box ${t.content}');
    }
    final int done = items.where((TodoEntry t) => t.done).length;
    return '${b.toString().trim()}\n\n$done/${items.length} completed';
  }

  Future<String> _task(ToolCall call) async {
    final Future<String> Function(String prompt, {String? agent})? run = subagent;
    if (run == null) {
      return 'Sub-agents are unavailable in this build. Do the work yourself.';
    }
    final String prompt = '${call.input['prompt'] ?? ''}'.trim();
    if (prompt.isEmpty) return 'Empty task prompt';
    final String? agent = '${call.input['agent'] ?? ''}'.trim().isEmpty
        ? null
        : '${call.input['agent']}'.trim();
    // Depth is capped at one: a child cannot spawn grandchildren, which keeps
    // a confused model from fanning out without bound.
    final Future<String> Function(String, {String? agent})? outer = subagent;
    subagent = null;
    try {
      return await run(prompt, agent: agent);
    } finally {
      subagent = outer;
    }
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
    final String targetPath = _resolve('${call.input['path'] ?? '.'}');
    final FileSystemEntity target = FileSystemEntity.typeSync(targetPath) ==
            FileSystemEntityType.file
        ? File(targetPath)
        : Directory(targetPath);
    final String glob = '${call.input['glob'] ?? ''}';
    final StringBuffer b = StringBuffer();
    int hits = 0;
    Future<void> scan(File f) async {
      if (hits >= 200) return;
      try {
        if (await f.length() > 1024 * 1024) return;
        final String content = await f.readAsString();
        if (content.contains('\u0000')) return;
        final List<String> lines = const LineSplitter().convert(content);
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
      await for (final FileSystemEntity e in (target as Directory)
          .list(recursive: true, followLinks: false)) {
        if (hits >= 200) break;
        if (e is! File) continue;
        if (e.path.contains('/.git/')) continue;
        if (glob.isNotEmpty && !_matchGlob(e.path.split('/').last, glob)) {
          continue;
        }
        await scan(e);
      }
    }
    return hits == 0 ? 'No matches' : _clip(b.toString());
  }

  // ------------------------------------------------------------------ helpers

  /// Public, sandbox-checked path resolution for UI pages.
  String resolvePath(String raw) => _resolve(raw);

  /// Workspace-relative path for display.
  String relPath(String absolute) {
    final String root = _normalize(workspace.path);
    if (absolute == root) return '';
    return absolute.startsWith('$root/')
        ? absolute.substring(root.length + 1)
        : absolute;
  }

  /// Runs a command on behalf of the terminal page (output is not escaped).
  Future<String> shell(String command, {int timeout = 60, String? cwd}) =>
      _bash(ToolCall(
        id: 'term${DateTime.now().microsecondsSinceEpoch}',
        name: 'bash',
        input: <String, dynamic>{
          'command': command,
          'timeout': timeout,
          if (cwd != null) 'cwd': cwd,
        },
      ));

  /// Flat file index for the `@` mention picker.
  Future<List<String>> listFiles({int limit = 600}) async {
    final String root = _normalize(workspace.path);
    final List<String> out = <String>[];
    try {
      await for (final FileSystemEntity e in workspace
          .list(recursive: true, followLinks: false)
          .timeout(const Duration(seconds: 8))) {
        if (out.length >= limit) break;
        if (e is! File) continue;
        final String rel = e.path.startsWith('$root/')
            ? e.path.substring(root.length + 1)
            : e.path;
        if (rel.startsWith('.git/') ||
            rel.contains('/.git/') ||
            rel.startsWith('.zcode/') ||
            rel.startsWith('.tmp/')) {
          continue;
        }
        out.add(rel);
      }
    } catch (_) {}
    out.sort();
    return out;
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
    if (normalized == root || normalized.startsWith('$root/')) {
      return normalized;
    }
    // Shared storage is fair game: those are the user's own folders and the
    // whole point of picking a real workspace.
    if (allowOutside &&
        (normalized.startsWith('/storage/') ||
            normalized.startsWith('/sdcard'))) {
      return normalized;
    }
    // Anything else collapses to the root itself, so the caller just sees
    // "not found" instead of a file from the app's private data.
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

  static bool _matchGlob(String name, String glob) => _globMatch(name, glob);

  /// `*` never crosses `/`, `**` does.
  static bool _globMatch(String path, String pattern) {
    final StringBuffer rx = StringBuffer('^');
    final String p = pattern.replaceAll('\\', '/');
    for (int i = 0; i < p.length; i++) {
      final String ch = p[i];
      if (ch == '*') {
        if (i + 1 < p.length && p[i + 1] == '*') {
          i++;
          if (i + 1 < p.length && p[i + 1] == '/') {
            // `**/` also matches zero directories, so root-level files hit too.
            rx.write(r'(?:.*/)?');
            i++;
          } else {
            rx.write('.*');
          }
        } else {
          rx.write('[^/]*');
        }
      } else if (ch == '?') {
        rx.write('[^/]');
      } else {
        rx.write(_escapeRegExp(ch));
      }
    }
    rx.write(r'$');
    try {
      return RegExp(rx.toString()).hasMatch(path);
    } catch (_) {
      return false;
    }
  }

  static String _escapeRegExp(String ch) {
    const String special = r'\^$.*+?()[]{}|';
    return special.contains(ch) ? '\\$ch' : ch;
  }

  static int _lineCount(String s) =>
      s.isEmpty ? 0 : '\n'.allMatches(s).length + 1;

  static String _htmlToText(String html) {
    String s = html
        .replaceAll(RegExp(r'<script[\s\S]*?</script>', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'<style[\s\S]*?</style>', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</(p|div|li|h[1-6]|tr)>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<[^>]+>'), ' ');
    const Map<String, String> entities = <String, String>{
      '&nbsp;': ' ',
      '&amp;': '&',
      '&lt;': '<',
      '&gt;': '>',
      '&quot;': '"',
      '&#39;': "'",
      '&apos;': "'",
    };
    entities.forEach((String k, String v) => s = s.replaceAll(k, v));
    return s
        .replaceAll(RegExp(r'[ \t]+'), ' ')
        .replaceAll(RegExp(r'\n\s*\n\s*\n+'), '\n\n')
        .trim();
  }

  static String _size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  static String _clip(String s) =>
      s.length <= _maxOutput ? s : '${s.substring(0, _maxOutput)}\n… [truncated]';
}

/// Small indirection so `_todo` and `TodoEntry` stay in one place for tests.
class ToolEntryHelper {
  static List<TodoEntry> parse(Object? raw) => TodoEntry.parse(raw);
}
