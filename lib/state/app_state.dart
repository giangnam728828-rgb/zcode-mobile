import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../agent/agent_runner.dart';
import '../agent/tools.dart';
import '../models/app_config.dart';
import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../services/account.dart';
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
  final List<String> queue = <String>[];

  /// Tool waiting for the user's go-ahead, surfaced as a dialog by the chat page.
  ToolCall? pendingApproval;

  final AccountService _account = AccountService();
  ToolBox? _toolbox;
  AgentRunner? _runner;
  Completer<bool>? _approval;
  ChatMessage? _streamTarget;
  bool _cancelRequested = false;
  Timer? _persist;
  Timer? _drain;

  String _pendingText = '';
  String _pendingThink = '';

  // ---------------------------------------------------------------- lifecycle

  Future<void> init() async {
    config = await Store.loadConfig() ?? AppConfig.empty;
    session = await _account.restore();
    _toolbox = await ToolBox.open();
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
  }) async {
    final AppConfig? c = config;
    if (c == null) return;
    await saveConfig(c.copyWith(
      themeMode: themeMode,
      accentId: accentId,
      fontScale: fontScale,
      language: language,
      approvalMode: approvalMode,
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

  void send(String text) {
    final String content = text.trim();
    if (content.isEmpty) return;
    if (streaming) {
      queue.add(content);
      notifyListeners();
      return;
    }
    _startTurn(content);
  }

  void flushQueueNow() {
    if (queue.isEmpty) return;
    final String next = queue.removeAt(0);
    stop(flushQueue: false);
    _startTurn(next);
  }

  void removeQueued(int index) {
    if (index < 0 || index >= queue.length) return;
    queue.removeAt(index);
    notifyListeners();
  }

  void _startTurn(String content) {
    final AppConfig? cfg = config;
    final Conversation? c = current;
    if (session == null) {
      error = '请先登录账号';
      notifyListeners();
      return;
    }
    if (cfg == null || c == null) return;

    error = null;
    c.messages.add(ChatMessage(
      id: 'u${DateTime.now().microsecondsSinceEpoch}',
      role: Sender.user,
      text: content,
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

  String _systemPrompt(AppConfig cfg) {
    final String ws = _toolbox?.workspace.path ?? '(unavailable)';
    return '${cfg.systemPrompt}\n\n'
        '## Runtime\n'
        'You are running inside an Android app. Your workspace is $ws — this is '
        'the app sandbox, not the whole phone.\n'
        'You have real tools: bash (sh + toybox utilities), read_file, write_file, '
        'edit_file, list_dir, grep. Use them instead of guessing: inspect before '
        'editing, and run code to verify your work.\n'
        'Rules: keep paths inside the workspace, prefer small targeted edits, and '
        'never claim a command succeeded unless you ran it and saw the output. '
        'When a task is done, summarise what changed and how it was verified.';
  }

  List<Map<String, dynamic>> _wireFrom(List<ChatMessage> history) {
    final List<Map<String, dynamic>> wire = <Map<String, dynamic>>[];
    for (final ChatMessage m in history) {
      if (m.role == Sender.system) continue;
      if (m.role == Sender.user) {
        if (m.text.trim().isNotEmpty) {
          wire.add(<String, dynamic>{'role': 'user', 'content': m.text});
        }
        continue;
      }
      final List<Map<String, dynamic>> content = <Map<String, dynamic>>[];
      if (m.text.trim().isNotEmpty) {
        content.add(<String, dynamic>{'type': 'text', 'text': m.text});
      }
      for (final ToolCall t in m.tools) {
        if (t.id.isEmpty) continue;
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

      final AgentRunner runner = AgentRunner(
        baseUrl: cfg.baseUrl,
        token: s.projectToken,
        model: cfg.model,
        toolbox: box,
        maxTokens: cfg.maxTokens,
      );
      _runner = runner;

      await runner.run(
        wire: _wireFrom(
            history.where((ChatMessage m) => m.id != target.id).toList()),
        systemPrompt: _systemPrompt(cfg),
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
        onToolUpdate: (ToolCall call) => notifyListeners(),
        approve: (ToolCall call) => _approve(call),
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
      _drainQueue();
    }
  }

  /// Approval gate: read-only tools and an `auto` policy pass straight through.
  Future<bool> _approve(ToolCall call) async {
    final String mode = config?.approvalMode ?? 'risky';
    if (mode == 'auto') return true;
    final ToolBox? box = _toolbox;
    final bool risky = box?.requiresApproval(call) ?? true;
    final bool readOnly = call.name == 'read_file' ||
        call.name == 'list_dir' ||
        call.name == 'grep';
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
    if (queue.isEmpty) return;
    final String next = queue.removeAt(0);
    Future<void>.delayed(const Duration(milliseconds: 260), () {
      if (!streaming) _startTurn(next);
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
    if (!flushQueue) queue.clear();
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
    final String prompt = c.messages[lastUser].text;
    c.messages.removeRange(lastUser, c.messages.length);
    notifyListeners();
    _startTurn(prompt);
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
    c.messages.removeRange(at, c.messages.length);
    notifyListeners();
    _startTurn(text);
  }

  void deleteMessage(String id) {
    final Conversation? c = current;
    if (c == null) return;
    c.messages.removeWhere((ChatMessage m) => m.id == id);
    notifyListeners();
    _schedulePersist();
  }

  void _schedulePersist() {
    _persist?.cancel();
    _persist = Timer(const Duration(milliseconds: 400), () {
      Store.saveConversations(conversations);
    });
  }

  Future<void> clearAllData() async {
    for (final Conversation c in conversations) {
      c.messages.clear();
    }
    await Store.saveConversations(conversations);
    notifyListeners();
  }

  String exportTranscript() {
    final Conversation? c = current;
    if (c == null) return '';
    return c.toMarkdown();
  }

  Directory? get workspace => _toolbox?.workspace;

  @override
  void dispose() {
    _persist?.cancel();
    _drain?.cancel();
    _account.dispose();
    super.dispose();
  }
}
