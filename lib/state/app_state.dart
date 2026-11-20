import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../agent/agent_runner.dart';
import '../agent/tools.dart';
import '../models/app_config.dart';
import '../models/attachment.dart';
import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../services/account.dart';
import '../services/modules.dart';
import '../services/store.dart';

/// Single source of truth for the signed-in account, conversations and the
/// live agent turn.
class AppState extends ChangeNotifier {
  AppConfig? config;
  AccountSession? session;
  final List<Conversation> conversations = <Conversation>[];
  String? currentId;

  bool ready = false;
  bool streaming = false;
  String? error;

  /// Messages typed while a turn is running; flushed one by one when it ends.
  /// Attachments ride along so nothing is silently dropped on a queue.
  final List<_QueuedTurn> _queue = <_QueuedTurn>[];

  List<String> get queue =>
      <String>[for (final _QueuedTurn q in _queue) q.text];

  /// Tool waiting for the user's go-ahead, surfaced as a dialog by the chat page.
  ToolCall? pendingApproval;

  ModuleCenter? moduleCenter;
  List<String> fileIndex = <String>[];

  final AccountService _account = AccountService();
  ToolBox? _toolbox;
  AgentRunner? _runner;
  Completer<bool>? _approval;
  ChatMessage? _streamTarget;
  bool _cancelRequested = false;
  Timer? _persist;
  Timer? _drain;
  Timer? _indexRefresh;

  String _pendingText = '';
  String _pendingThink = '';

  // ---------------------------------------------------------------- lifecycle

  Future<void> init() async {
    config = await Store.loadConfig() ?? AppConfig.empty;
    session = await _account.restore();
    _toolbox = await ToolBox.open();
    moduleCenter = ModuleCenter(_toolbox!.workspace);
    await moduleCenter!.load();
    _applyModulePaths();
    final List<Conversation> loaded = await Store.loadConversations();
    conversations
      ..clear()
      ..addAll(loaded);
    if (conversations.isEmpty) {
      conversations.add(Conversation.fresh());
    }
    _sortConversations();
    currentId = conversations.first.id;
    ready = true;
    notifyListeners();
    unawaited(refreshFileIndex());
  }

  Conversation? get current {
    if (currentId == null) return null;
    for (final Conversation c in conversations) {
      if (c.id == currentId) return c;
    }
    return null;
  }

  List<ChatMessage> get messages => current?.messages ?? <ChatMessage>[];

  bool get configured => session != null;

  bool get needsReauth => session != null && session!.expired;

  ToolBox? get tools => _toolbox;

  /// Test hook: point the app at a temporary workspace without plugins.
  @visibleForTesting
  void debugUseWorkspace(ToolBox box) {
    _toolbox = box;
    notifyListeners();
  }

  Directory? get workspace => _toolbox?.workspace;

  String get workspacePath => _toolbox?.workspace.path ?? '';

  /// Changes only when a finished message lands, so settled bubbles can skip
  /// rebuilding on every streaming tick.
  String get historyFingerprint {
    final Conversation? c = current;
    if (c == null) return '';
    int done = 0;
    for (final ChatMessage m in c.messages) {
      if (!m.streaming) done++;
    }
    return '${c.id}|${c.messages.length}|$done';
  }

  int get contextChars {
    int n = 0;
    final String summary = current?.summary ?? '';
    n += summary.length;
    for (final ChatMessage m in messages) {
      if (m.compacted) continue;
      n += m.text.length + m.thinking.length;
      for (final ToolCall t in m.tools) {
        n += t.output.length;
      }
    }
    return n;
  }

  // ------------------------------------------------------------------- account

  /// Browser sign-in. Returns null when the user aborted, throws on failure.
  Future<AccountSession?> signIn(
    AccountRegion region, {
    void Function(String status)? onStatus,
    void Function(String url)? onUrl,
  }) async {
    error = null;
    notifyListeners();
    try {
      final AccountSession s =
          await _account.login(region, onProgress: onStatus, onUrl: onUrl);
      session = s;
      final AppConfig base = config ?? AppConfig.empty;
      config = base.copyWith(provider: region.id, baseUrl: region.modelBase);
      await Store.saveConfig(config!);
      notifyListeners();
      return s;
    } catch (e) {
      error = '$e';
      notifyListeners();
      rethrow;
    }
  }

  Future<void> signOut() async {
    await _account.logout();
    session = null;
    notifyListeners();
  }

  /// Project tokens are short lived; swap in a fresh one before a turn when it
  /// is near expiry so a long session does not die mid-answer.
  Future<void> _refreshIfNeeded() async {
    final AccountSession? s = session;
    if (s == null) return;
    if (DateTime.now()
        .isBefore(s.expiresAt.subtract(const Duration(minutes: 2)))) {
      return;
    }
    try {
      session = await _account.refresh(s);
    } catch (_) {
      // Keep the old token; the turn surfaces a 401 if it really expired.
    }
  }

  // -------------------------------------------------------------------- prefs

  Future<void> saveConfig(AppConfig next) async {
    config = next;
    await Store.saveConfig(next);
    notifyListeners();
  }

  Future<void> updatePrefs({
    String? themeMode,
    String? accentId,
    double? fontScale,
    String? language,
    String? approvalMode,
    double? temperature,
    bool? autoCompact,
  }) async {
    final AppConfig? c = config;
    if (c == null) return;
    await saveConfig(c.copyWith(
      themeMode: themeMode,
      accentId: accentId,
      fontScale: fontScale,
      language: language,
      approvalMode: approvalMode,
      temperature: temperature,
      autoCompact: autoCompact,
    ));
  }

  bool importConfig(String bundle) {
    final AppConfig? parsed =
        AppConfig.tryImport(bundle, config ?? AppConfig.empty);
    if (parsed == null) return false;
    config = parsed;
    Store.saveConfig(parsed);
    notifyListeners();
    return true;
  }

  // ----------------------------------------------------------------- sessions

  void _sortConversations() {
    conversations.sort((Conversation a, Conversation b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      return b.updatedAt.compareTo(a.updatedAt);
    });
  }

  void selectConversation(String id) {
    currentId = id;
    notifyListeners();
  }

  void newConversation() {
    final Conversation c = Conversation.fresh();
    conversations.insert(0, c);
    currentId = c.id;
    notifyListeners();
    _schedulePersist();
  }

  void deleteConversation(String id) {
    conversations.removeWhere((Conversation c) => c.id == id);
    if (conversations.isEmpty) conversations.add(Conversation.fresh());
    if (currentId == id) currentId = conversations.first.id;
    notifyListeners();
    _schedulePersist();
  }

  void renameConversation(String id, String title) {
    for (final Conversation c in conversations) {
      if (c.id == id) {
        c.title = title.trim();
      }
    }
    notifyListeners();
    _schedulePersist();
  }

  void togglePin(String id) {
    for (final Conversation c in conversations) {
      if (c.id == id) c.pinned = !c.pinned;
    }
    _sortConversations();
    notifyListeners();
    _schedulePersist();
  }

  void toggleArchive(String id) {
    for (final Conversation c in conversations) {
      if (c.id == id) c.archived = !c.archived;
    }
    notifyListeners();
    _schedulePersist();
  }

  void clearCurrent() {
    final Conversation? c = current;
    if (c == null) return;
    c.messages.clear();
    c.summary = '';
    c.compactedCount = 0;
    notifyListeners();
    _schedulePersist();
  }

  // ------------------------------------------------------------------- turns

  void clearError() {
    if (error != null) {
      error = null;
      notifyListeners();
    }
  }

  void send(
    String text, {
    List<Attachment> attachments = const <Attachment>[],
    String? quote,
  }) {
    String content = text.trim();
    if (quote != null && quote.trim().isNotEmpty) {
      final String q = quote
          .trim()
          .split('\n')
          .map((String l) => '> $l')
          .join('\n');
      content = content.isEmpty ? q : '$q\n\n$content';
    }
    if (content.isEmpty && attachments.isEmpty) return;
    if (streaming) {
      _queue.add(_QueuedTurn(content, attachments));
      notifyListeners();
      return;
    }
    _startTurn(content, attachments: attachments);
  }

  void flushQueueNow() {
    if (_queue.isEmpty) return;
    final _QueuedTurn next = _queue.removeAt(0);
    stop(flushQueue: false);
    _startTurn(next.text, attachments: next.attachments);
  }

  void removeQueued(int index) {
    if (index < 0 || index >= _queue.length) return;
    _queue.removeAt(index);
    notifyListeners();
  }

  /// Picks up `@path` mentions that point at real files and turns them into
  /// attachments, so the model gets the contents without the user hunting for
  /// an attach button.
  List<Attachment> _fromMentions(String text, List<Attachment> explicit) {
    final List<Attachment> out = List<Attachment>.from(explicit);
    final Set<String> seen = out.map((Attachment a) => a.path).toSet();
    final ToolBox? box = _toolbox;
    if (box == null) return out;
    for (final RegExpMatch m in RegExp(r'@([^\s@]+)').allMatches(text)) {
      final String raw = m.group(1) ?? '';
      if (raw.isEmpty || raw.startsWith('/')) continue;
      final String abs = box.resolvePath(raw);
      final File f = File(abs);
      if (!f.existsSync() || seen.contains(raw)) continue;
      if (FileSystemEntity.isDirectorySync(abs)) continue;
      out.add(Attachment(
        path: raw,
        name: abs.split('/').last,
        isImage: Attachment.looksLikeImage(abs),
        size: f.lengthSync(),
        mediaType: Attachment.looksLikeImage(abs)
            ? Attachment.guessMediaType(abs)
            : null,
      ));
      seen.add(raw);
    }
    return out;
  }

  void _startTurn(
    String content, {
    List<Attachment> attachments = const <Attachment>[],
  }) {
    final AppConfig? cfg = config;
    final Conversation? c = current;
    if (session == null) {
      error = '请先登录账号';
      notifyListeners();
      return;
    }
    if (cfg == null || c == null) return;

    error = null;
    final List<Attachment> files = _fromMentions(content, attachments);
    if (cfg.autoCompact && contextChars > 48000 && messages.length > 10) {
      compact();
    }
    c.messages.add(ChatMessage(
      id: 'u${DateTime.now().microsecondsSinceEpoch}',
      role: Sender.user,
      text: content,
      attachments: files,
    ));
    final ChatMessage assistant = ChatMessage(
      id: 'a${DateTime.now().microsecondsSinceEpoch}',
      role: Sender.assistant,
      text: '',
      streaming: true,
    );
    c.messages.add(assistant);
    c.updatedAt = DateTime.now();
    if (c.isUntitled) c.title = '';

    _streamTarget = assistant;
    _cancelRequested = false;
    _pendingText = '';
    _pendingThink = '';
    streaming = true;
    notifyListeners();

    _run(cfg, List<ChatMessage>.from(c.messages), assistant);
  }

  static const String agentsTemplate = '''# 项目说明

给智能体的常驻说明，每次对话都会自动读取（也可以命名为 ZCODE.md）。

## 技术栈

## 运行与测试

## 约定与注意事项
''';

  /// Reads AGENTS.md / ZCODE.md and lists project skills, mirroring how the
  /// desktop client picks up repo rules.
  Future<String> _projectContext() async {
    final ToolBox? box = _toolbox;
    if (box == null) return '';
    final StringBuffer out = StringBuffer();
    for (final String name in <String>['AGENTS.md', 'ZCODE.md']) {
      final File f = File(box.resolvePath(name));
      if (!await f.exists()) continue;
      try {
        String text = await f.readAsString();
        if (text.length > 8000) {
          text = '${text.substring(0, 8000)}\n… [truncated]';
        }
        out.writeln('\n## Project instructions ($name)');
        out.writeln(text.trim());
        break;
      } catch (_) {}
    }
    final Directory skills = Directory(box.resolvePath('.zcode/skills'));
    if (await skills.exists()) {
      final List<String> rows = <String>[];
      try {
        await for (final FileSystemEntity e in skills.list()) {
          if (e is! File || !e.path.endsWith('.md')) continue;
          String desc = '';
          try {
            final List<String> lines =
                (await e.readAsString()).split('\n');
            for (final String line in lines) {
              final String t = line.trim();
              if (t.isEmpty || t.startsWith('#')) continue;
              desc = t.length > 160 ? '${t.substring(0, 160)}…' : t;
              break;
            }
          } catch (_) {}
          rows.add('- ${box.relPath(e.path)}${desc.isEmpty ? '' : ' — $desc'}');
          if (rows.length >= 12) break;
        }
      } catch (_) {}
      if (rows.isNotEmpty) {
        out.writeln('\n## Project skills');
        out.writeln('Read the relevant skill file before using it:');
        out.writeln(rows.join('\n'));
      }
    }
    return out.toString().trim();
  }

  Future<String> _systemPrompt(AppConfig cfg) async {
    final String ws = _toolbox?.workspace.path ?? '(unavailable)';
    final String mods = moduleCenter?.installed.isNotEmpty == true
        ? moduleCenter!.installed
            .map((InstalledModule m) => m.commands.join(', '))
            .join('; ')
        : 'none installed';
    return '${cfg.systemPrompt}\n\n'
        '## Runtime\n'
        'You are running inside an Android app, not on a server. Your workspace '
        'is $ws and every file tool is sandboxed to it.\n'
        'Available tools: bash (sh + toybox, PATH already includes module bins), '
        'read_file, write_file, edit_file, list_dir, glob, grep, make_dir, '
        'move_file, delete_file, web_fetch, todo_write.\n'
        'Installed CLI modules: $mods. If a missing runtime (node, python, git) '
        'blocks the task, say so and suggest installing a module instead of '
        'pretending it worked.\n'
        'Working rules:\n'
        '- For anything with more than two steps, call todo_write first and keep '
        'it updated as you go.\n'
        '- Inspect before editing. Prefer small, exact edits over rewrites.\n'
        '- Verify by running code or commands; never claim success without '
        'seeing the output.\n'
        '- Keep paths inside the workspace, and finish with a short summary of '
        'what changed and how it was verified.'
        '${await _projectContext()}';
  }

  Future<List<Map<String, dynamic>>> _wireFrom(
      List<ChatMessage> history) async {
    final List<Map<String, dynamic>> wire = <Map<String, dynamic>>[];
    final String summary = current?.summary.trim() ?? '';
    if (summary.isNotEmpty) {
      wire.add(<String, dynamic>{
        'role': 'user',
        'content': 'Context from earlier in this conversation, already '
            'completed (summary):\n$summary',
      });
      wire.add(<String, dynamic>{
        'role': 'assistant',
        'content': 'Understood — I have that earlier context.',
      });
    }
    for (final ChatMessage m in history) {
      if (m.role == Sender.system || m.compacted) continue;
      if (m.role == Sender.user) {
        final List<Map<String, dynamic>> parts = <Map<String, dynamic>>[];
        if (m.text.trim().isNotEmpty) {
          parts.add(<String, dynamic>{'type': 'text', 'text': m.text});
        }
        for (final Attachment a in m.attachments) {
          final String? block = await _attachmentBlock(a);
          if (block == null) continue;
          if (a.isImage) {
            parts.add(<String, dynamic>{
              'type': 'image',
              'source': <String, dynamic>{
                'type': 'base64',
                'media_type': a.mediaType ?? Attachment.guessMediaType(a.name),
                'data': block,
              },
            });
          } else {
            parts.add(<String, dynamic>{'type': 'text', 'text': block});
          }
        }
        if (parts.isEmpty) continue;
        wire.add(<String, dynamic>{
          'role': 'user',
          'content': parts.length == 1 && parts.first['type'] == 'text'
              ? parts.first['text']
              : parts,
        });
        continue;
      }
      final List<Map<String, dynamic>> content = <Map<String, dynamic>>[];
      if (m.text.trim().isNotEmpty) {
        content.add(<String, dynamic>{'type': 'text', 'text': m.text});
      }
      for (final ToolCall t in m.tools) {
        if (t.id.isEmpty || t.status == ToolStatus.denied) continue;
        content.add(<String, dynamic>{
          'type': 'tool_use',
          'id': t.id,
          'name': t.name,
          'input': t.input,
        });
      }
      if (content.isEmpty) continue;
      wire.add(<String, dynamic>{'role': 'assistant', 'content': content});
      final List<Map<String, dynamic>> results = <Map<String, dynamic>>[];
      for (final ToolCall t in m.tools) {
        if (t.id.isEmpty) continue;
        results.add(<String, dynamic>{
          'type': 'tool_result',
          'tool_use_id': t.id,
          'content': t.output.isEmpty ? '(no output)' : t.output,
          'is_error': t.status == ToolStatus.failed,
        });
      }
      if (results.isNotEmpty) {
        wire.add(<String, dynamic>{'role': 'user', 'content': results});
      }
    }
    return wire;
  }

  /// Reads an attachment for the wire format: base64 for images, fenced text
  /// for source files (capped so one huge file cannot eat the context).
  Future<String?> _attachmentBlock(Attachment a) async {
    final ToolBox? box = _toolbox;
    if (box == null) return null;
    final File f = File(box.resolvePath(a.path));
    if (!await f.exists()) return null;
    try {
      if (a.isImage) {
        final int size = await f.length();
        if (size > 3 * 1024 * 1024) return null;
        return base64Encode(await f.readAsBytes());
      }
      final int size = await f.length();
      if (size > 512 * 1024) {
        return 'File: ${a.path} (${(size / 1024).toStringAsFixed(0)} KB, too '
            'large to inline — use read_file with offset/limit)';
      }
      String body = await f.readAsString();
      if (body.contains('\u0000')) return 'File: ${a.path} (binary)';
      if (body.length > 24000) {
        body = '${body.substring(0, 24000)}\n… [truncated at 24k chars]';
      }
      return 'File: ${a.path}\n```\n$body\n```';
    } catch (_) {
      return null;
    }
  }

  Future<void> _run(
    AppConfig cfg,
    List<ChatMessage> history,
    ChatMessage target,
  ) async {
    final ToolBox? box = _toolbox;
    try {
      if (box == null) throw StateError('工具环境尚未就绪');
      await _refreshIfNeeded();
      final AccountSession s = session!;

      box.beginTurn();
      final AgentRunner runner = AgentRunner(
        baseUrl: cfg.baseUrl,
        token: s.projectToken,
        model: cfg.model,
        toolbox: box,
        maxTokens: cfg.maxTokens,
        maxSteps: cfg.maxSteps,
        temperature: cfg.temperature,
      );
      _runner = runner;

      final List<Map<String, dynamic>> wire =
          await _wireFrom(history.where((ChatMessage m) => m.id != target.id).toList());

      await runner.run(
        wire: wire,
        systemPrompt: await _systemPrompt(cfg),
        onText: (String text) {
          if (_cancelRequested) return;
          _pendingText += text;
          _ensureDrain();
        },
        onThinking: (String text) {
          if (_cancelRequested) return;
          _pendingThink += text;
          _ensureDrain();
        },
        onToolStart: (ToolCall call) {
          target.tools.add(call);
          notifyListeners();
        },
        onToolUpdate: (ToolCall call) {
          notifyListeners();
          _scheduleIndexRefresh();
        },
        approve: (ToolCall call) => _approve(call),
        onUsage: (int input, int output) {
          target.inputTokens = input;
          target.outputTokens = output;
          notifyListeners();
        },
      );

      if (!_cancelRequested) await _flushPacer();
    } catch (e) {
      if (!_cancelRequested) {
        final String msg = e is AgentException ? e.message : '$e';
        error = msg;
        target.error = msg;
      }
    } finally {
      _drain?.cancel();
      _drain = null;
      _streamTarget = null;
      _runner = null;
      target.streaming = false;
      if (_cancelRequested) target.stopped = true;
      if (!_cancelRequested && target.isEmpty && target.error == null) {
        target.text = '（无内容返回）';
      }
      final Conversation? c = current;
      if (c != null) {
        c.updatedAt = DateTime.now();
        if (target.isEmpty && target.error == null) {
          c.messages.removeWhere((ChatMessage m) => m.id == target.id);
        }
      }
      streaming = false;
      _cancelRequested = false;
      if (pendingApproval != null) {
        if (_approval != null && !_approval!.isCompleted) {
          _approval!.complete(false);
        }
        _approval = null;
        pendingApproval = null;
      }
      _sortConversations();
      notifyListeners();
      _schedulePersist();
      _scheduleIndexRefresh();
      _drainQueue();
    }
  }

  /// Approval gate: read-only tools and an `auto` policy pass straight through.
  Future<bool> _approve(ToolCall call) async {
    final String mode = config?.approvalMode ?? 'risky';
    if (mode == 'auto') return true;
    if (call.name == 'todo_write') return true;
    final ToolBox? box = _toolbox;
    final bool risky = box?.requiresApproval(call) ?? true;
    final bool readOnly = call.name == 'read_file' ||
        call.name == 'list_dir' ||
        call.name == 'grep' ||
        call.name == 'glob' ||
        call.name == 'web_fetch';
    if (readOnly) return true;
    if (mode == 'risky' && !risky) return true;

    final Completer<bool> gate = Completer<bool>();
    _approval = gate;
    pendingApproval = call;
    notifyListeners();
    final bool ok = await gate.future;
    pendingApproval = null;
    _approval = null;
    notifyListeners();
    return ok;
  }

  void resolveApproval(bool allow) {
    if (_approval != null && !_approval!.isCompleted) {
      _approval!.complete(allow);
    }
  }

  void _drainQueue() {
    if (_queue.isEmpty) return;
    final _QueuedTurn next = _queue.removeAt(0);
    Future<void>.delayed(const Duration(milliseconds: 260), () {
      if (!streaming) _startTurn(next.text, attachments: next.attachments);
    });
  }

  void _ensureDrain() {
    _drain ??= Timer.periodic(const Duration(milliseconds: 16), (Timer t) {
      final ChatMessage? target = _streamTarget;
      if (target == null) {
        t.cancel();
        _drain = null;
        return;
      }
      bool moved = false;
      if (_pendingThink.isNotEmpty) {
        final int n = _step(_pendingThink.length);
        target.thinking += _pendingThink.substring(0, n);
        _pendingThink = _pendingThink.substring(n);
        moved = true;
      }
      if (_pendingText.isNotEmpty) {
        final int n = _step(_pendingText.length);
        target.text += _pendingText.substring(0, n);
        _pendingText = _pendingText.substring(n);
        moved = true;
      }
      if (moved) notifyListeners();
    });
  }

  int _step(int remaining) {
    final int byRate = (remaining / 9).ceil();
    return byRate.clamp(2, 180);
  }

  Future<void> _flushPacer() async {
    final ChatMessage? target = _streamTarget;
    if (target == null) return;
    while (_pendingText.isNotEmpty || _pendingThink.isNotEmpty) {
      if (_pendingThink.isNotEmpty) {
        target.thinking += _pendingThink;
        _pendingThink = '';
      }
      if (_pendingText.isNotEmpty) {
        target.text += _pendingText;
        _pendingText = '';
      }
      notifyListeners();
      await Future<void>.delayed(const Duration(milliseconds: 8));
    }
  }

  void stop({bool flushQueue = true}) {
    if (!streaming) return;
    _cancelRequested = true;
    if (_approval != null && !_approval!.isCompleted) {
      _approval!.complete(false);
    }
    _runner?.cancel();
    if (!flushQueue) _queue.clear();
    notifyListeners();
  }

  void regenerate() {
    final Conversation? c = current;
    if (c == null || streaming) return;
    int lastUser = -1;
    for (int i = c.messages.length - 1; i >= 0; i--) {
      if (c.messages[i].role == Sender.user) {
        lastUser = i;
        break;
      }
    }
    if (lastUser < 0) return;
    final ChatMessage prompt = c.messages[lastUser];
    c.messages.removeRange(lastUser, c.messages.length);
    notifyListeners();
    _startTurn(prompt.text, attachments: prompt.attachments);
  }

  void editAndResend(String messageId, String text) {
    final Conversation? c = current;
    if (c == null) return;
    int at = -1;
    for (int i = 0; i < c.messages.length; i++) {
      if (c.messages[i].id == messageId) {
        at = i;
        break;
      }
    }
    if (at < 0) return;
    final List<Attachment> files = c.messages[at].attachments;
    c.messages.removeRange(at, c.messages.length);
    notifyListeners();
    _startTurn(text, attachments: files);
  }

  /// Rolls back every file the last turn touched.
  Future<int> undoLastTurn() async {
    final int n = await _toolbox?.undoLastTurn() ?? 0;
    notifyListeners();
    return n;
  }

  bool get canUndo => _toolbox?.canUndo ?? false;

  /// Forks a conversation, keeping the transcript but not the running turn.
  Conversation duplicateConversation(String id) {
    Conversation source = conversations.firstWhere(
      (Conversation c) => c.id == id,
      orElse: () => conversations.first,
    );
    final Conversation copy = Conversation.fromJson(source.toJson());
    final Conversation fork = Conversation(
      id: 'c${DateTime.now().microsecondsSinceEpoch}',
      title: source.previewTitle().isEmpty
          ? '副本'
          : '${source.previewTitle()} · 副本',
      messages: copy.messages,
      summary: source.summary,
      compactedCount: source.compactedCount,
    );
    conversations.insert(0, fork);
    currentId = fork.id;
    notifyListeners();
    _schedulePersist();
    return fork;
  }

  void deleteMessage(String id) {
    final Conversation? c = current;
    if (c == null) return;
    c.messages.removeWhere((ChatMessage m) => m.id == id);
    notifyListeners();
    _schedulePersist();
  }

  // -------------------------------------------------------------- compaction

  /// Folds older turns into a compact digest. The visible transcript stays,
  /// but those bubbles are skipped on replay so the model gets room to work.
  int compact() {
    final Conversation? c = current;
    if (c == null) return 0;
    final List<ChatMessage> live =
        c.messages.where((ChatMessage m) => !m.compacted).toList();
    if (live.length <= 6) return 0;
    final int keep = live.length > 16 ? 8 : 6;
    final List<ChatMessage> fold = live.sublist(0, live.length - keep);
    if (fold.isEmpty) return 0;

    final StringBuffer b = StringBuffer();
    final Set<String> files = <String>{};
    for (final ChatMessage m in fold) {
      if (m.isUser && m.text.trim().isNotEmpty) {
        final String t = m.text.trim().replaceAll(RegExp(r'\s+'), ' ');
        b.writeln('- 用户：${t.length > 160 ? '${t.substring(0, 160)}…' : t}');
      }
      for (final ToolCall t in m.tools) {
        if (t.name == 'write_file' ||
            t.name == 'edit_file' ||
            t.name == 'move_file' ||
            t.name == 'delete_file') {
          final Object? p = t.input['path'] ?? t.input['to'];
          if (p != null) files.add('$p');
        }
      }
      if (m.attachments.isNotEmpty) {
        files.addAll(m.attachments.map((Attachment a) => a.path));
      }
    }
    if (files.isNotEmpty) {
      b.writeln('- 涉及文件：${files.take(12).join(', ')}');
    }

    final String merged = <String>[
      if (c.summary.trim().isNotEmpty) c.summary.trim(),
      b.toString().trim(),
    ].where((String s) => s.isNotEmpty).join('\n');
    c.summary = merged.length > 4000
        ? '…${merged.substring(merged.length - 4000)}'
        : merged;
    for (final ChatMessage m in fold) {
      m.compacted = true;
    }
    c.compactedCount += fold.length;
    notifyListeners();
    _schedulePersist();
    return fold.length;
  }

  void clearSummary() {
    final Conversation? c = current;
    if (c == null) return;
    c.summary = '';
    for (final ChatMessage m in c.messages) {
      m.compacted = false;
    }
    c.compactedCount = 0;
    notifyListeners();
    _schedulePersist();
  }

  // -------------------------------------------------------------------- files

  Future<void> refreshFileIndex() async {
    final ToolBox? box = _toolbox;
    if (box == null) return;
    try {
      final List<String> next = await box.listFiles();
      if (!listEquals(next, fileIndex)) {
        fileIndex = next;
        notifyListeners();
      }
    } catch (_) {}
  }

  void _scheduleIndexRefresh() {
    _indexRefresh?.cancel();
    _indexRefresh = Timer(const Duration(seconds: 3), () {
      unawaited(refreshFileIndex());
    });
  }

  /// Cheap prefix/substring match used by the `@` mention picker.
  List<String> suggestFiles(String query, {int limit = 6}) {
    final String q = query.trim().toLowerCase();
    if (q.isEmpty) return fileIndex.take(limit).toList();
    final List<String> starts = <String>[];
    final List<String> contains = <String>[];
    for (final String p in fileIndex) {
      final String lower = p.toLowerCase();
      if (lower.split('/').last.startsWith(q)) {
        starts.add(p);
      } else if (lower.contains(q)) {
        contains.add(p);
      }
      if (starts.length >= limit) break;
    }
    return <String>[...starts, ...contains].take(limit).toList();
  }

  Future<String> runShell(String command, {int timeout = 60}) async {
    final ToolBox? box = _toolbox;
    if (box == null) return '工具环境尚未就绪';
    return box.shell(command, timeout: timeout);
  }

  Future<Attachment?> attach(String relativePath) async {
    final ToolBox? box = _toolbox;
    if (box == null) return null;
    final File f = File(box.resolvePath(relativePath));
    if (!await f.exists()) return null;
    return Attachment.of(f, relativePath);
  }

  // ------------------------------------------------------------------ modules

  void _applyModulePaths() {
    final ToolBox? box = _toolbox;
    final ModuleCenter? mc = moduleCenter;
    if (box == null || mc == null) return;
    box.extraPaths
      ..clear()
      ..addAll(mc.binPaths);
  }

  Future<void> installBuiltinModule(String id) async {
    final ModuleCenter? mc = moduleCenter;
    if (mc == null) return;
    ModuleSpec? spec;
    for (final ModuleSpec s in ModuleCenter.catalog) {
      if (s.id == id) spec = s;
    }
    if (spec == null) return;
    await mc.install(spec);
    _applyModulePaths();
    notifyListeners();
  }

  Future<void> installRemoteModule(String url, {String? name}) async {
    final ModuleCenter? mc = moduleCenter;
    if (mc == null) return;
    await mc.installArchive(url, name: name);
    _applyModulePaths();
    notifyListeners();
  }

  Future<void> removeModule(String id) async {
    final ModuleCenter? mc = moduleCenter;
    if (mc == null) return;
    await mc.remove(id);
    _applyModulePaths();
    notifyListeners();
  }

  // ------------------------------------------------------------------ persist

  void _schedulePersist() {
    _persist?.cancel();
    _persist = Timer(const Duration(milliseconds: 400), () {
      Store.saveConversations(conversations);
    });
  }

  Future<void> clearAllData() async {
    for (final Conversation c in conversations) {
      c.messages.clear();
      c.summary = '';
      c.compactedCount = 0;
    }
    await Store.saveConversations(conversations);
    notifyListeners();
  }

  String exportTranscript() {
    final Conversation? c = current;
    if (c == null) return '';
    return c.toMarkdown();
  }

  @override
  void dispose() {
    _persist?.cancel();
    _drain?.cancel();
    _indexRefresh?.cancel();
    _account.dispose();
    super.dispose();
  }
}


class _QueuedTurn {
  _QueuedTurn(this.text, this.attachments);

  final String text;
  final List<Attachment> attachments;
}
