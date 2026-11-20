import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/app_config.dart';
import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../services/glm_client.dart';
import '../services/store.dart';

/// Single source of truth for config, conversations and the live turn.
class AppState extends ChangeNotifier {
  AppConfig? config;
  final List<Conversation> conversations = <Conversation>[];
  String? currentId;

  bool ready = false;
  bool streaming = false;
  String? error;

  /// Messages typed while a turn is running; flushed one by one when it ends.
  final List<String> queue = <String>[];

  GlmClient? _client;
  ChatMessage? _streamTarget;
  bool _cancelRequested = false;
  Timer? _persist;
  Timer? _drain;

  String _pendingText = '';
  String _pendingThink = '';

  // ---------------------------------------------------------------- lifecycle

  Future<void> init() async {
    config = await Store.loadConfig();
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

  bool get configured => config != null && config!.isConfigured;

  /// Changes only when a finished message lands, so the list of settled
  /// bubbles can skip rebuilding on every streaming tick.
  String get historyFingerprint {
    final Conversation? c = current;
    if (c == null) return '';
    int done = 0;
    for (final ChatMessage m in c.messages) {
      if (!m.streaming) done++;
    }
    return '${c.id}|${c.messages.length}|$done';
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
  }) async {
    final AppConfig? c = config;
    if (c == null) return;
    await saveConfig(c.copyWith(
      themeMode: themeMode,
      accentId: accentId,
      fontScale: fontScale,
      language: language,
    ));
  }

  /// Applies a `zcm://` bundle (or raw JSON) exported from another device.
  bool importConfig(String raw) {
    final AppConfig? c = config;
    if (c == null) return false;
    final AppConfig? next = AppConfig.tryImport(raw, c);
    if (next == null) return false;
    saveConfig(next);
    return true;
  }

  // ------------------------------------------------------------ conversations

  void _sortConversations() {
    conversations.sort((Conversation a, Conversation b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      return b.updatedAt.compareTo(a.updatedAt);
    });
  }

  Conversation newConversation({bool select = true}) {
    final Conversation c = Conversation.fresh();
    conversations.insert(0, c);
    if (select) currentId = c.id;
    notifyListeners();
    _schedulePersist();
    return c;
  }

  void selectConversation(String id) {
    if (id == currentId) return;
    currentId = id;
    notifyListeners();
  }

  void deleteConversation(String id) {
    conversations.removeWhere((Conversation c) => c.id == id);
    if (conversations.isEmpty) {
      conversations.add(Conversation.fresh());
    }
    if (currentId == id) currentId = conversations.first.id;
    notifyListeners();
    _schedulePersist();
  }

  void renameConversation(String id, String title) {
    for (final Conversation c in conversations) {
      if (c.id == id) {
        c.title = title.trim();
        c.updatedAt = DateTime.now();
      }
    }
    _sortConversations();
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
    stop();
    c.messages.clear();
    c.title = '';
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

  /// Called by the composer. If a turn is running the text is queued instead.
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

  /// Send the head of the queue right away, interrupting the running turn.
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
    if (cfg == null || !cfg.isConfigured || c == null) {
      error = '请先在设置中填写 API Key。';
      notifyListeners();
      return;
    }

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

    final GlmClient client = GlmClient(cfg);
    _client = client;
    _run(client, List<ChatMessage>.from(c.messages), assistant);
  }

  Future<void> _run(
    GlmClient client,
    List<ChatMessage> history,
    ChatMessage target,
  ) async {
    try {
      await for (final GlmDelta d in client.streamChat(history)) {
        if (_cancelRequested) break;
        if (d.thinking) {
          _pendingThink += d.text;
        } else {
          _pendingText += d.text;
        }
        _ensureDrain();
      }
      // Flush whatever the pacer has not shown yet.
      if (!_cancelRequested) await _flushPacer();
    } catch (e) {
      if (!_cancelRequested) {
        final String msg = e is GlmApiException ? e.friendly : e.toString();
        error = msg;
        target.error = msg;
      }
    } finally {
      _drain?.cancel();
      _drain = null;
      _streamTarget = null;
      _client = null;
      target.streaming = false;
      if (_cancelRequested) target.stopped = true;
      if (!_cancelRequested && target.isEmpty && target.error == null) {
        target.text = '（无内容返回）';
      }
      final Conversation? c = current;
      if (c != null) {
        c.updatedAt = DateTime.now();
        // Drop a trailing empty assistant bubble left by a failed request.
        if (target.isEmpty && target.error == null) {
          c.messages.removeWhere((ChatMessage m) => m.id == target.id);
        }
      }
      streaming = false;
      _cancelRequested = false;
      _sortConversations();
      notifyListeners();
      _schedulePersist();
      _drainQueue();
    }
  }

  void _drainQueue() {
    if (queue.isEmpty) return;
    final String next = queue.removeAt(0);
    Future<void>.delayed(const Duration(milliseconds: 260), () {
      if (!streaming) _startTurn(next);
    });
  }

  /// Character pacing so both the native stream and the web build (where XHR
  /// may deliver the whole body at once) feel identical.
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
    _client?.cancel();
    _client = null;
    _drain?.cancel();
    _drain = null;
    // Show text that already arrived.
    final ChatMessage? target = _streamTarget;
    if (target != null) {
      target.text += _pendingText;
      target.thinking += _pendingThink;
      _pendingText = '';
      _pendingThink = '';
      target.streaming = false;
      target.stopped = true;
    }
    _streamTarget = null;
    streaming = false;
    if (!flushQueue) queue.clear();
    notifyListeners();
    _schedulePersist();
    if (flushQueue) _drainQueue();
  }

  /// Re-run the last user turn, replacing the previous answer.
  void regenerate() {
    final Conversation? c = current;
    if (c == null || streaming) return;
    int idx = -1;
    for (int i = c.messages.length - 1; i >= 0; i--) {
      if (c.messages[i].isUser) {
        idx = i;
        break;
      }
    }
    if (idx < 0) return;
    final String prompt = c.messages[idx].text;
    c.messages.removeRange(idx, c.messages.length);
    notifyListeners();
    _startTurn(prompt);
  }

  /// Edit a user message and rewind the thread to that point.
  void editAndResend(String messageId, String text) {
    final Conversation? c = current;
    if (c == null || streaming) return;
    final String trimmed = text.trim();
    if (trimmed.isEmpty) return;
    int idx = c.messages.indexWhere((ChatMessage m) => m.id == messageId);
    if (idx < 0) return;
    c.messages.removeRange(idx, c.messages.length);
    notifyListeners();
    _startTurn(trimmed);
  }

  void deleteMessage(String id) {
    final Conversation? c = current;
    if (c == null) return;
    c.messages.removeWhere((ChatMessage m) => m.id == id);
    notifyListeners();
    _schedulePersist();
  }

  // ------------------------------------------------------------- persistence

  void _schedulePersist() {
    _persist?.cancel();
    _persist = Timer(const Duration(milliseconds: 400), () {
      Store.saveConversations(conversations);
    });
  }

  Future<void> clearAllData() async {
    stop(flushQueue: false);
    queue.clear();
    await Store.clearAll();
    config = null;
    conversations
      ..clear()
      ..add(Conversation.fresh());
    currentId = conversations.first.id;
    notifyListeners();
  }

  @override
  void dispose() {
    _persist?.cancel();
    _drain?.cancel();
    _client?.cancel();
    super.dispose();
  }
}
