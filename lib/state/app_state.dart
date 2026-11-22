import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../agent/agent_runner.dart';
import '../agent/commands.dart';
import '../agent/mcp.dart';
import '../agent/tools.dart';
import '../models/app_config.dart';
import '../models/attachment.dart';
import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../platform/a11y_bridge.dart';
import '../platform/device_bridge.dart';
import '../platform/privilege_bridge.dart';
import '../services/account.dart';
import '../services/automation.dart';
import '../services/modules.dart';
import '../services/plugins.dart';
import '../services/store.dart';
import '../services/workspace.dart';

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
  PluginCenter? pluginCenter;
  McpManager? mcpManager;
  List<String> fileIndex = <String>[];

  /// Absolute path of the folder the agent works in. On a phone this is a real
  /// folder the user picked from their own storage.
  String _workspacePath = '';

  /// Whether the app can touch arbitrary user folders (All-files access).
  bool storageAccess = false;

  /// Whether Termux is installed, i.e. whether node/python/git can run.
  bool termuxAvailable = false;

  /// Bumped on every workspace switch so open browsers can reset their state.
  int workspaceEpoch = 0;

  /// Commands contributed by installed plugins (`.zcode/commands/*.md`).
  List<SlashCommand> customCommands = const <SlashCommand>[];

  /// Sub-agent names found in `.zcode/agents`.
  List<String> agentNames = const <String>[];

  /// How many MCP tools are currently registered, shown in the settings card.
  int mcpToolCount = 0;

  /// Root / Shizuku availability, refreshed whenever the app comes back.
  PrivStatus privilege = const PrivStatus();

  /// Accessibility service and notification listener state.
  A11yStatus a11y = const A11yStatus();

  /// Automation rules and their history. Created in [init].
  AutomationEngine? automation;

  /// Text handed over by another app's share sheet, waiting to be put in the
  /// composer.
  String? pendingDraft;

  /// A route requested by a launcher shortcut (`automation`).
  String? pendingRoute;

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
    DeviceBridge.init();
    DeviceBridge.onIntent = _handleIntent;
    config = await Store.loadConfig() ?? AppConfig.empty;
    session = await _account.restore();
    await DeviceBridge.refresh();
    storageAccess = DeviceBridge.info.storageAccess;
    termuxAvailable = DeviceBridge.info.termux;
    final String wsPath = await _resolveInitialWorkspace();
    await WorkspaceResolver.bootstrap(wsPath);
    _toolbox = await ToolBox.openAt(wsPath);
    _workspacePath = wsPath;
    await _bindExtensions();
    privilege = await PrivilegeBridge.refresh();
    a11y = await A11yBridge.refresh();
    automation = AutomationEngine(runner: _runAutomationAction);
    automation!.onFinished = _notifyRuleResult;
    await automation!.load();
    automation!.start();
    _listenDeviceEvents();
    unawaited(_seedSignal());
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
    unawaited(_runBootRules());
    final Map<String, dynamic>? early = DeviceBridge.takePendingIntent();
    if (early != null) _handleIntent(early);
  }

  /// Launcher shortcuts and the share sheet land here.
  void _handleIntent(Map<String, dynamic> data) {
    final String kind = '${data['kind'] ?? ''}';
    if (kind == 'shortcut') {
      final String value = '${data['value'] ?? ''}';
      if (value == 'automation') {
        pendingRoute = 'automation';
        notifyListeners();
      } else if (value == 'new_chat') {
        newConversation();
      }
      return;
    }
    if (kind == 'share') {
      final String text = '${data['value'] ?? ''}'.trim();
      if (text.isEmpty) return;
      // A share is a new thought, not a continuation: open a clean session and
      // drop the text in the box so nothing is sent without the user's word.
      newConversation();
      pendingDraft = text;
      notifyListeners();
    }
  }

  String? takeDraft() {
    final String? d = pendingDraft;
    pendingDraft = null;
    return d;
  }

  String? takeRoute() {
    final String? r = pendingRoute;
    pendingRoute = null;
    return r;
  }

  /// First run: suggest `Internal storage/ZCode`, but honour whatever the user
  /// picked last time even if the app was killed.
  Future<String> _resolveInitialWorkspace() async {
    final String? saved = await Store.loadWorkspace();
    if (saved != null && await WorkspaceResolver.ensureWritable(saved)) {
      return saved;
    }
    // Upgrading from a private-directory workspace: keep it until the user
    // deliberately moves, otherwise their files look lost.
    final String? legacy = await WorkspaceResolver.legacyWorkspace();
    if (legacy != null) {
      await Store.saveWorkspace(legacy);
      return legacy;
    }
    final String suggestion = await WorkspaceResolver.suggest();
    await Store.saveWorkspace(suggestion);
    return suggestion;
  }

  /// Wires the workspace-dependent services (modules, plugins, MCP, custom
  /// commands) to [ToolBox]. Also used after switching folders.
  Future<void> _bindExtensions() async {
    final ToolBox box = _toolbox!;
    box.subagent = _runSubagent;
    moduleCenter = ModuleCenter(box.workspace);
    await moduleCenter!.load();
    _applyModulePaths();
    pluginCenter = PluginCenter(box.workspace);
    await pluginCenter!.load();
    pluginCenter!.onChanged = (bool mcpChanged) =>
        unawaited(_reloadExtensions(mcpChanged: mcpChanged));
    mcpManager = McpManager(box.workspace, box);
    await _loadCustomCommands();
    unawaited(_connectMcp());
  }

  /// Re-reads storage permission after the user comes back from Settings.
  Future<void> refreshDeviceState() async {
    if (!DeviceBridge.isAndroid) return;
    await DeviceBridge.refresh();
    storageAccess = DeviceBridge.info.storageAccess;
    termuxAvailable = DeviceBridge.info.termux;
    privilege = await PrivilegeBridge.refresh();
    a11y = await A11yBridge.refresh();
    notifyListeners();
  }

  /// Points the agent at another folder.
  /// Returns an empty string on success,
  /// otherwise the reason the folder cannot be used.
  Future<String> switchWorkspace(String path) async {
    final String problem = await WorkspaceResolver.validate(path);
    if (problem.isNotEmpty) return problem;
    final String clean = path.trim();
    if (clean == _workspacePath && _toolbox != null) return '';
    await WorkspaceResolver.bootstrap(clean);
    final ToolBox box = await ToolBox.openAt(clean);
    _toolbox = box;
    _workspacePath = clean;
    workspaceEpoch++;
    await _bindExtensions();
    await Store.saveWorkspace(clean);
    fileIndex = <String>[];
    notifyListeners();
    unawaited(refreshFileIndex());
    return '';
  }

  Future<List<String>> recentWorkspaces() => Store.loadRecentWorkspaces();

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

  /// Test hook: re-read plugin commands without booting the whole app.
  @visibleForTesting
  Future<void> debugReloadExtensions() => _loadCustomCommands();

  Directory? get workspace => _toolbox?.workspace;

  String get workspacePath => _workspacePath.isEmpty
      ? (_toolbox?.workspace.path ?? '')
      : _workspacePath;

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
    String? glassQuality,
    String? glassAutoTier,
    bool? glassAutoHinted,
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
      glassQuality: glassQuality,
      glassAutoTier: glassAutoTier,
      glassAutoHinted: glassAutoHinted,
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
    // "Send now" means "start the first queued turn immediately", not "throw
    // away the rest". `stop(flushQueue: false)` empties the queue as a side
    // effect, so snapshot it first and put it straight back.
    final List<_QueuedTurn> kept = List<_QueuedTurn>.of(_queue);
    // Starting the turn here would race with the cancelled run's `finally`,
    // which picks up the head itself once the turn is torn down.
    stop(flushQueue: false);
    _queue
      ..clear()
      ..addAll(kept);
    notifyListeners();
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
    for (final String raw in parseMentions(text)) {
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
    if (agentNames.isNotEmpty) {
      out.writeln('\n## Sub-agents');
      out.writeln('Pass one of these names as `agent` when calling task:');
      out.writeln(agentNames.map((String a) => '- $a').join('\n'));
    }
    return out.toString().trim();
  }

  Future<String> _systemPrompt(AppConfig cfg) async {
    final String ws = _toolbox?.workspace.path ?? '(unavailable)';
    final String cmds = customCommands.isEmpty
        ? ''
        : customCommands.map((SlashCommand c) => '/${c.name}').join(', ');
    final String mods = moduleCenter?.installed.isNotEmpty == true
        ? moduleCenter!.installed
            .map((InstalledModule m) => m.commands.join(', '))
            .join('; ')
        : 'none installed';
    return '${cfg.systemPrompt}\n\n'
        '## Runtime\n'
        'You are running inside an Android app, not on a server. Your workspace '
        'is $ws — a real folder on the user\'s phone, not a sandbox copy: the '
        'files you edit are the files they see in their file manager, and the '
        'shell uses the same absolute paths.\n'
        'Available tools: bash (sh + toybox; PATH starts with .zcode/bin, then '
        'module bins), read_file, write_file, edit_file, list_dir, glob, grep, '
        'make_dir, move_file, delete_file, web_fetch, todo_write, device '
        '(notifications, clipboard, app launch, battery, volume; plus system '
        'switches, screenshots and taps when root or Shizuku is available)'
        '${agentNames.isEmpty ? '' : ', task'}'
        '${mcpToolCount == 0 ? '' : ', plus $mcpToolCount MCP tools named mcp__<server>__<tool>'}.\n'
        'Installed CLI modules: $mods. If node, python or git is missing, the '
        'user can run that command through Termux (the terminal page has a '
        'Termux mode) — say so plainly instead of pretending it worked.\n'
        'Privileged channel: ${privilege.label}. '
        '${privilege.privileged ? 'You may use device actions that need it '
            '(svc, pm, input, screencap, settings).' : 'Without root or Shizuku, '
            'system-level device actions will fail — offer to enable one instead '
            'of retrying.'}\n'
        '${agentNames.isEmpty ? '' : 'Sub-agents you can pass to task: ${agentNames.join(', ')}.\n'}'
        '${cmds.isEmpty ? '' : 'Plugin commands the user has: $cmds.\n'}'
        'Working rules:\n'
        '- For anything with more than two steps, call todo_write first and keep '
        'it updated as you go.\n'
        '- Inspect before editing. Prefer small, exact edits over rewrites.\n'
        '- Verify by running code or commands; never claim success without '
        'seeing the output.\n'
        '- Stay inside the workspace unless the user explicitly points at '
        'another folder; then use the absolute path.\n'
        '- Finish with a short summary of what changed and how it was verified.'
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
          // Say so instead of vanishing. A message that silently arrives
          // without the screenshot the user attached is indistinguishable from
          // the model ignoring it; a note lets the model mention the omission.
          if (a.exceedsLimit) {
            parts.add(<String, dynamic>{
              'type': 'text',
              'text': '[Attachment omitted: ${a.name} is ${a.sizeLabel}, over '
                  'the ${a.isImage ? '3 MB' : '512 KB'} limit]',
            });
            continue;
          }
          final String? block = await _attachmentBlock(a);
          if (block == null) {
            parts.add(<String, dynamic>{
              'type': 'text',
              'text': '[Attachment missing: ${a.name}]',
            });
            continue;
          }
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
        if (size > Attachment.maxImageBytes) return null;
        return base64Encode(await f.readAsBytes());
      }
      final int size = await f.length();
      if (size > Attachment.maxTextBytes) {
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

  // -------------------------------------------------------------- extensions

  /// Re-reads plugin-provided commands and agents, then reconnects MCP. Called
  /// after an install so the next message already sees the new tools.
  Future<void> _reloadExtensions({bool mcpChanged = true}) async {
    await _loadCustomCommands();
    if (mcpChanged) await _connectMcp();
    notifyListeners();
  }

  Future<void> _connectMcp() async {
    final McpManager? m = mcpManager;
    if (m == null) return;
    try {
      mcpToolCount = await m.reload();
    } catch (e) {
      mcpToolCount = 0;
      m.error = '$e';
    }
    notifyListeners();
  }

  /// Reconnects MCP servers after the user edits mcp.json.
  Future<void> reloadMcp() => _connectMcp();

  /// Re-reads commands/agents after a plugin file was edited by hand.
  Future<void> refreshPlugins() => _reloadExtensions(mcpChanged: false);

  Future<void> _loadCustomCommands() async {
    final ToolBox? box = _toolbox;
    if (box == null) return;
    final List<SlashCommand> cmds = <SlashCommand>[];
    try {
      final Directory dir = Directory(box.resolvePath('.zcode/commands'));
      if (await dir.exists()) {
        await for (final FileSystemEntity e in dir.list()) {
          if (e is! File || !e.path.endsWith('.md')) continue;
          try {
            final String raw = await e.readAsString();
            final Map<String, String> meta = _frontMatter(raw);
            final String id = e.path.split('/').last.replaceAll('.md', '');
            final String name = (meta['name'] ?? id).trim();
            if (name.isEmpty) continue;
            cmds.add(SlashCommand(
              name: name,
              usage: meta['usage'] ?? '/$name',
              zh: meta['description'] ?? '插件命令',
              en: meta['description'] ?? 'Plugin command',
              takesArg: (raw.contains(r'$ARGUMENTS') || raw.contains('{{args}}')),
            ));
          } catch (_) {}
        }
      }
    } catch (_) {}
    cmds.sort((SlashCommand a, SlashCommand b) => a.name.compareTo(b.name));
    customCommands = cmds;

    final List<String> agents = <String>[];
    try {
      final Directory dir = Directory(box.resolvePath('.zcode/agents'));
      if (await dir.exists()) {
        await for (final FileSystemEntity e in dir.list()) {
          if (e is File && e.path.endsWith('.md')) {
            agents.add(e.path.split('/').last.replaceAll('.md', ''));
          }
        }
      }
    } catch (_) {}
    agents.sort();
    agentNames = agents;
  }

  /// Expands a plugin command into the prompt it stands for, or null when the
  /// name does not belong to a plugin.
  String? customCommandPrompt(String name, String args) {
    final ToolBox? box = _toolbox;
    if (box == null) return null;
    final File f = File(box.resolvePath('.zcode/commands/$name.md'));
    if (!f.existsSync()) return null;
    try {
      final String raw = f.readAsStringSync();
      final String body = _stripFrontMatter(raw);
      return body
          .replaceAll(r'$ARGUMENTS', args)
          .replaceAll('{{args}}', args)
          .trim();
    } catch (_) {
      return null;
    }
  }

  static Map<String, String> _frontMatter(String raw) {
    final Map<String, String> out = <String, String>{};
    final List<String> lines = raw.split('\n');
    if (lines.isEmpty || lines.first.trim() != '---') return out;
    for (int i = 1; i < lines.length; i++) {
      final String line = lines[i];
      if (line.trim() == '---') break;
      final int colon = line.indexOf(':');
      if (colon <= 0) continue;
      out[line.substring(0, colon).trim()] = line.substring(colon + 1).trim();
    }
    return out;
  }

  static String _stripFrontMatter(String raw) {
    final List<String> lines = raw.split('\n');
    if (lines.isEmpty || lines.first.trim() != '---') return raw;
    for (int i = 1; i < lines.length; i++) {
      if (lines[i].trim() == '---') return lines.skip(i + 1).join('\n').trim();
    }
    return raw;
  }

  /// Runs a child agent on behalf of the `task` tool. The child gets the same
  /// workspace and tools but its own transcript, and only its final text comes
  /// back — that is what keeps a long investigation out of the main context.
  Future<String> _runSubagent(String prompt, {String? agent}) async {
    final ToolBox? box = _toolbox;
    final AppConfig? cfg = config;
    final AccountSession? s = session;
    if (box == null || cfg == null || s == null) {
      return 'Sub-agent unavailable: the session is not ready.';
    }
    String persona = '';
    if (agent != null && agent.trim().isNotEmpty) {
      final File f = File(box.resolvePath('.zcode/agents/${agent.trim()}.md'));
      if (await f.exists()) persona = _stripFrontMatter(await f.readAsString());
    }
    final StringBuffer out = StringBuffer();
    final Future<String> Function(String, {String? agent})? parent = box.subagent;
    // No nested task calls: keeps depth at one and avoids runaway fan-out.
    box.subagent = null;
    try {
      final AgentRunner runner = AgentRunner(
        baseUrl: cfg.baseUrl,
        token: s.projectToken,
        model: cfg.model,
        toolbox: box,
        maxTokens: cfg.maxTokens,
        maxSteps: 10,
        temperature: cfg.temperature,
      );
      await runner.run(
        wire: <Map<String, dynamic>>[
          <String, dynamic>{'role': 'user', 'content': prompt},
        ],
        systemPrompt: '${await _systemPrompt(cfg)}\n\n'
            '## 当前角色\n'
            '${persona.isEmpty ? '你是主智能体派出的子智能体。只完成交给你的这一件事，'
                '然后给出结论，不要寒暄。' : persona}',
        onText: (String t) => out.write(t),
        onThinking: (String t) {},
        onToolStart: (ToolCall c) {},
        onToolUpdate: (ToolCall c) {},
        approve: (ToolCall c) => _approve(c),
      );
    } catch (e) {
      return 'Sub-agent failed: $e';
    } finally {
      box.subagent = parent;
    }
    final String text = out.toString().trim();
    return text.isEmpty ? 'Sub-agent finished without a report.' : text;
  }

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

  Future<String> runShell(String command,
      {int timeout = 60, String? cwd}) async {
    final ToolBox? box = _toolbox;
    if (box == null) return '工具环境尚未就绪';
    return box.shell(command, timeout: timeout, cwd: cwd ?? workspacePath);
  }

  /// Runs a command through Termux, which is where node / python / git live on
  /// a phone. Output is polled from a file because the service has no pipe.
  Future<String> runTermux(String command,
      {String? cwd, int timeout = 180}) async {
    if (!DeviceBridge.isAndroid) {
      return 'Termux 桥接只在 Android 上可用。';
    }
    final String dir = (cwd ?? workspacePath).trim();
    if (dir.isEmpty) return '请先选择工作区。';
    if (!WorkspaceResolver.isShared(dir)) {
      return '当前工作区在应用私有目录，Termux 读不到。\n'
          '请在「工作区」里改选内部存储上的文件夹（例如 内部存储/ZCode），'
          '选中后这里的命令就能直接跑 node、python、git 了。';
    }
    if (!await DeviceBridge.termuxInstalled()) {
      return '没有检测到 Termux。\n'
          '手机上跑 node/python/git 需要它：装好 Termux 后执行\n'
          '  pkg install nodejs python git\n'
          '再回到这里就能用了。';
    }
    final Directory meta = Directory('$dir/.zcode');
    try {
      await meta.create(recursive: true);
    } catch (e) {
      return '无法写入 $dir/.zcode：$e';
    }
    final String stamp = DateTime.now().microsecondsSinceEpoch.toString();
    final String out = '${meta.path}/termux-$stamp.out';
    final String exit = '${meta.path}/termux-$stamp.exit';
    final bool sent = await DeviceBridge.termuxRun(
      command: command,
      cwd: dir,
      outFile: out,
      exitFile: exit,
    );
    if (!sent) {
      return '无法唤起 Termux。\n'
          '请在 Termux 里执行：\n'
          '  echo "allow-external-apps=true" >> ~/.termux/termux.properties\n'
          '  termux-reload-settings\n'
          '然后重试。';
    }
    int code = -1;
    final DateTime deadline = DateTime.now().add(Duration(seconds: timeout));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final File marker = File(exit);
      if (await marker.exists()) {
        code = int.tryParse((await marker.readAsString()).trim()) ?? 0;
        break;
      }
    }
    String body = '';
    try {
      body = await File(out).readAsString();
    } catch (_) {}
    for (final String p in <String>[out, exit]) {
      try {
        await File(p).delete();
      } catch (_) {}
    }
    if (code == -1) {
      return 'Termux 在 ${timeout}s 内没有回传结果（命令可能还在跑，或 Termux 被系统冻结）。';
    }
    final String trimmed = body.trim();
    final String shown =
        trimmed.length > 12000 ? '${trimmed.substring(0, 12000)}\n…' : trimmed;
    return '${shown.isEmpty ? '(no output)' : shown}\n\n[exit $code]';
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

  // ------------------------------------------------------------- privilege

  /// Re-reads root / Shizuku state. Cheap enough to call on every resume.
  Future<void> refreshPrivilege() async {
    privilege = await PrivilegeBridge.refresh();
    a11y = await A11yBridge.refresh();
    notifyListeners();
  }

  /// Asks Shizuku for its API permission; falls back to opening the app so the
  /// user can start the service if it is not running.
  Future<bool> requestShizuku() async {
    final bool asked = await PrivilegeBridge.requestShizuku();
    await Future<void>.delayed(const Duration(milliseconds: 700));
    await refreshPrivilege();
    if (privilege.shizukuGranted) return true;
    if (!asked) await PrivilegeBridge.openShizuku();
    return privilege.shizukuGranted;
  }

  /// Runs a command as the shell uid through root or Shizuku.
  Future<String> runPrivileged(
    String command, {
    String mode = 'auto',
    int timeout = 30,
  }) async {
    final PrivResult r =
        await PrivilegeBridge.run(command, mode: mode, timeout: timeout);
    return r.text;
  }

  void _listenDeviceEvents() {
    PrivilegeBridge.listen((Map<String, dynamic> event) {
      final String type = '${event['type'] ?? ''}';
      if (type == 'a11y_connected' ||
          type == 'a11y_disconnected' ||
          type == 'notification_listener') {
        unawaited(_refreshA11ySilently());
      }
      automation?.onEvent(event);
    });
  }

  Future<void> _refreshA11ySilently() async {
    a11y = await A11yBridge.refresh();
    notifyListeners();
  }

  /// Opens the accessibility settings screen, then re-reads the status when the
  /// user comes back.
  Future<bool> openA11ySettings({bool notifications = false}) async {
    final bool ok = await A11yBridge.openSettings(notifications: notifications);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await refreshPrivilege();
    return ok;
  }

  /// Reads the current screen for the "试一试" button and for the agent.
  Future<A11ySnapshot> readScreen({int limit = 40}) async {
    final A11ySnapshot snap = await A11yBridge.snapshot(limit: limit);
    if (snap.connected != a11y.connected) {
      unawaited(_refreshA11ySilently());
    }
    return snap;
  }

  Future<void> _seedSignal() async {
    if (!DeviceBridge.isAndroid) return;
    final Map<String, dynamic> b = await PrivilegeBridge.battery();
    automation?.updateSignal(AutomationSignal(
      batteryLevel: (b['level'] as num?)?.toInt() ?? -1,
      charging: b['charging'] == true,
      screenOn: b['screenOn'] != false,
    ));
  }

  /// Boot is a one-shot flag: the native receiver cannot start the UI, so the
  /// rules tagged `boot` run on the first launch after a reboot.
  Future<void> _runBootRules() async {
    final bool booted = await Store.takeFlag('boot');
    final AutomationEngine? eng = automation;
    if (!booted || eng == null) return;
    for (final AutomationRule r in eng.enabledRules) {
      if (r.trigger.kind != 'boot') continue;
      await eng.run(r, auto: true);
    }
  }

  // ------------------------------------------------------------ automation

  /// A rule can ask for a notification after it runs; failures always notify,
  /// because a silent failure is worse than a noisy one.
  Future<void> _notifyRuleResult(
    AutomationRule rule,
    bool ok,
    String detail,
  ) async {
    // Failures always surface; successes only when the switch is on.
    if (!rule.notify && ok) return;
    final String first = detail.split('\n').first;
    final String body = first.length > 180 ? '${first.substring(0, 180)}…' : first;
    await PrivilegeBridge.notify(
      '${rule.name}${ok ? '' : ' · 失败'}',
      body.isEmpty ? (ok ? '已执行' : '执行失败') : body,
      id: rule.id.hashCode & 0x7fff,
    );
  }

  /// Replaces `{app}`, `{text}`, `{time}` … in any action argument. This is what
  /// makes "把验证码复制到剪贴板" work without writing code.
  String _fill(String raw, AutomationRule rule) {
    if (raw.isEmpty) return raw;
    final AutomationSignal sig =
        automation?.signal ?? const AutomationSignal();
    final DateTime now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final String app =
        sig.notifApp.isNotEmpty ? sig.notifApp : sig.foregroundLabel;
    final String pkg =
        sig.notifPackage.isNotEmpty ? sig.notifPackage : sig.foreground;
    return raw
        .replaceAll('{app}', app)
        .replaceAll('{package}', pkg)
        .replaceAll('{title}', sig.notifTitle)
        .replaceAll('{text}', sig.notifText)
        .replaceAll('{screen}', sig.screenText)
        .replaceAll('{battery}', sig.batteryLevel >= 0 ? '${sig.batteryLevel}' : '')
        .replaceAll('{ssid}', sig.ssid)
        .replaceAll('{time}', '${two(now.hour)}:${two(now.minute)}')
        .replaceAll('{date}',
            '${now.year}-${two(now.month)}-${two(now.day)}')
        .replaceAll('{rule}', rule.name);
  }

  Future<String> _runAutomationAction(
    AutomationRule rule,
    AutomationAction action,
  ) async {
    final Map<String, dynamic> a = action.args;
    switch (action.kind) {
      case 'notify':
        final bool ok = await PrivilegeBridge.notify(
          _fill('${a['title'] ?? rule.name}', rule),
          _fill('${a['body'] ?? ''}', rule),
          id: rule.id.hashCode & 0x7fff,
        );
        return ok ? '已发出通知' : '通知没发出去（可能缺少通知权限）';
      case 'shell':
        final String cmd = _fill('${a['command'] ?? ''}', rule).trim();
        if (cmd.isEmpty) return 'ERROR 命令为空';
        final String mode = '${a['mode'] ?? 'builtin'}';
        if (mode == 'builtin') return runShell(cmd);
        if (mode == 'termux') return runTermux(cmd);
        final PrivResult pr =
            await PrivilegeBridge.run(cmd, mode: mode, timeout: 90);
        if (!pr.ok) return 'ERROR ${pr.text}';
        final String out = pr.stdout.trim();
        return out.isEmpty ? '完成（${pr.channel}）' : out;
      case 'device':
        return _runDeviceAction(
          '${a['action'] ?? ''}',
          '${a['package'] ?? ''}',
        );
      case 'agent':
        return _runAutomationAgent(_fill('${a['prompt'] ?? ''}', rule).trim());
      case 'webhook':
        return _postWebhook(
          _fill('${a['url'] ?? ''}', rule),
          _fill('${a['body'] ?? ''}', rule),
        );
      case 'a11y':
        return _runA11yAction(a, rule);
      case 'speak':
        final String spoken = _fill('${a['text'] ?? ''}', rule).trim();
        if (spoken.isEmpty) return 'ERROR 没有要朗读的文字';
        final bool ok = await A11yBridge.speak(spoken);
        return ok ? '已朗读' : 'ERROR 系统没有可用的语音引擎';
      case 'clipboard':
        final String copied = _fill('${a['text'] ?? ''}', rule);
        final bool ok = await PrivilegeBridge.clipboardSet(copied);
        return ok ? '已复制 ${copied.length} 个字' : 'ERROR 剪贴板写入失败';
      case 'open_app':
        final String target =
            _fill('${a['package'] ?? a['label'] ?? ''}', rule).trim();
        if (target.isEmpty) return 'ERROR 没有指定应用';
        final bool ok = await PrivilegeBridge.openApp(target);
        return ok ? '已打开 $target' : 'ERROR 找不到应用 $target';
      case 'delay':
        final int seconds =
            ((a['seconds'] as num?)?.toInt() ?? 5).clamp(1, 300).toInt();
        await Future<void>.delayed(Duration(seconds: seconds));
        return '等待了 $seconds 秒';
      default:
        return 'ERROR 未知动作 ${action.kind}';
    }
  }

  Future<String> _runA11yAction(
    Map<String, dynamic> a,
    AutomationRule rule,
  ) async {
    final String op = '${a['op'] ?? ''}';
    if (op.isEmpty) return 'ERROR 没有选择屏幕动作';
    A11yStatus st = a11y;
    if (!st.connected) {
      st = await A11yBridge.refresh();
      a11y = st;
    }
    if (!st.connected) {
      return 'ERROR 无障碍服务未连接（设置 → 无障碍 → ZCode 屏幕助手）';
    }
    final String text = _fill('${a['text'] ?? ''}', rule).trim();
    final int index = ((a['index'] as num?)?.toInt() ?? 0).clamp(0, 20).toInt();
    switch (op) {
      case 'read':
        final A11ySnapshot snap = await A11yBridge.snapshot(limit: 40);
        if (!snap.connected) return 'ERROR 无障碍服务断开';
        if (snap.isEmpty) return '屏幕没有可读文字（${snap.package}）';
        final List<String> lines = snap.text
            .split('\n')
            .where((String l) => l.trim().isNotEmpty)
            .take(14)
            .toList();
        return '${snap.app.isEmpty ? snap.package : snap.app}：${lines.join(' / ')}';
      case 'click':
      case 'long_click':
        if (text.isEmpty) return 'ERROR 要点击的文字为空';
        final bool ok = await A11yBridge.click(
          text,
          index: index,
          longPress: op == 'long_click',
        );
        return ok ? '已点击「$text」' : 'ERROR 屏幕上没找到「$text」';
      case 'input':
        final String value =
            _fill('${a['value'] ?? a['text'] ?? ''}', rule);
        if (value.isEmpty) return 'ERROR 没有要输入的内容';
        final bool ok =
            await A11yBridge.setText(value, target: '${a['text'] ?? ''}');
        return ok ? '已输入 ${value.length} 个字' : 'ERROR 没找到可输入的框';
      case 'scroll_down':
      case 'scroll_up':
        final int times =
            ((a['times'] as num?)?.toInt() ?? 1).clamp(1, 6).toInt();
        final bool ok = await A11yBridge.scroll(
          forward: op == 'scroll_down',
          times: times,
        );
        return ok ? '已滚动 $times 次' : 'ERROR 没有可滚动的区域';
      case 'back':
      case 'home':
      case 'recents':
      case 'notifications':
      case 'screenshot':
      case 'lock':
        final bool ok = await A11yBridge.global(op);
        return ok ? '已执行 $op' : 'ERROR 系统拒绝了 $op';
      default:
        return 'ERROR 未知屏幕动作 $op';
    }
  }

  Future<String> _runDeviceAction(String id, String pkg) async {
    if (id.isEmpty) return 'ERROR 没有选择设备动作';
    if (id == 'screenshot') {
      final String stamp = DateTime.now().millisecondsSinceEpoch.toString();
      final String dir = workspacePath.isEmpty ? '/sdcard' : workspacePath;
      final String path = '$dir/screenshot-$stamp.png';
      final PrivResult r =
          await PrivilegeBridge.run('screencap -p "$path"', timeout: 30);
      return r.ok ? '已保存 $path' : 'ERROR ${r.text}';
    }
    if (id == 'volume_up' || id == 'volume_down' || id == 'mute') {
      final int delta = id == 'volume_up' ? 2 : (id == 'volume_down' ? -2 : -20);
      final Map<String, dynamic> v =
          await PrivilegeBridge.volume('music', delta: delta);
      if (v.isEmpty) return 'ERROR 读不到音量';
      return '音量 ${v['level']}/${v['max']}';
    }
    if (!privilege.privileged) {
      return 'ERROR 这个动作需要 root 或 Shizuku（当前：${privilege.label}）';
    }
    final String cmd = DeviceAction.command(id, pkg: pkg);
    if (cmd.isEmpty) return 'ERROR 未知设备动作 $id';
    final PrivResult r = await PrivilegeBridge.run(cmd, timeout: 25);
    return r.ok ? '已完成（${r.channel}）' : 'ERROR ${r.text}';
  }

  /// A headless agent turn: no UI state is touched, so a scheduled rule can run
  /// while the user is elsewhere in the app.
  Future<String> _runAutomationAgent(String prompt) async {
    if (prompt.isEmpty) return 'ERROR 提示词为空';
    if (streaming) return 'ERROR 正在对话中，本轮跳过';
    final AppConfig? cfg = config;
    final ToolBox? box = _toolbox;
    if (cfg == null || session == null) return 'ERROR 未登录账号';
    if (box == null) return 'ERROR 工具环境未就绪';
    await _refreshIfNeeded();
    final StringBuffer out = StringBuffer();
    try {
      final AgentRunner runner = AgentRunner(
        baseUrl: cfg.baseUrl,
        token: session!.projectToken,
        model: cfg.model,
        toolbox: box,
        maxTokens: cfg.maxTokens,
        maxSteps: cfg.maxSteps,
        temperature: cfg.temperature,
      );
      await runner.run(
        wire: <Map<String, dynamic>>[
          <String, dynamic>{'role': 'user', 'content': prompt},
        ],
        systemPrompt: '${await _systemPrompt(cfg)}\n\n'
            '## 自动化执行\n'
            '这条消息来自自动化规则，没有人在旁边回答你的问题。直接动手，'
            '不要反问；破坏性操作要保守。最后用不超过 200 字说明做了什么、'
            '结果如何。',
        onText: (String t) => out.write(t),
        onThinking: (String t) {},
        onToolStart: (ToolCall c) {},
        onToolUpdate: (ToolCall c) {},
        // Nobody is around to approve: allow the tools, but the rule author
        // wrote the prompt, so this is not a silent escalation.
        approve: (ToolCall c) => Future<bool>.value(true),
        onUsage: (int input, int output) {},
      );
    } catch (e) {
      return 'ERROR $e';
    }
    final String text = out.toString().trim();
    return text.isEmpty ? '智能体没有返回内容' : text;
  }

  Future<String> _postWebhook(String url, String body) async {
    if (url.isEmpty) return 'ERROR URL 为空';
    try {
      final http.Response resp = await http
          .post(
            Uri.parse(url),
            headers: <String, String>{'content-type': 'application/json'},
            body: body.isEmpty ? '{}' : body,
          )
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        return 'HTTP ${resp.statusCode}';
      }
      return 'ERROR HTTP ${resp.statusCode}';
    } catch (e) {
      return 'ERROR $e';
    }
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
    automation?.stop();
    PrivilegeBridge.stopListening();
    _account.dispose();
    super.dispose();
  }
}


class _QueuedTurn {
  _QueuedTurn(this.text, this.attachments);

  final String text;
  final List<Attachment> attachments;
}

/// Extracts file mentions from a message: `@"My Project/a.dart"` and the bare
/// `@src/main.dart`.
///
/// Whitespace ends an unquoted path, which is why the composer quotes paths
/// that contain spaces. A leading `/` is skipped — it is a slash command, not
/// a file. Top-level so it can be tested without a workspace.
List<String> parseMentions(String text) {
  final RegExp re = RegExp(r'@"([^"]+)"|@([^\s@]+)');
  final List<String> out = <String>[];
  for (final RegExpMatch m in re.allMatches(text)) {
    final String raw = (m.group(1) ?? m.group(2) ?? '').trim();
    if (raw.isEmpty || raw.startsWith('/')) continue;
    out.add(raw);
  }
  return out;
}
