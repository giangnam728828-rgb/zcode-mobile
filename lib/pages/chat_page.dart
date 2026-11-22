import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../agent/commands.dart';
import '../agent/tools.dart';
import '../l10n/strings.dart';
import '../models/app_config.dart';
import '../models/attachment.dart';
import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../state/app_state.dart';
import '../state/dock_visibility.dart';
import '../theme/glass.dart';
import '../theme/tokens.dart';
import '../widgets/composer.dart';
import '../widgets/message_bubble.dart';
import 'files_page.dart';
import 'modules_page.dart';
import 'plugins_page.dart';
import 'settings_page.dart';
import 'automation_page.dart';
import 'terminal_page.dart';
import 'workspace_picker_page.dart';

/// The conversation view: header, transcript, composer.
class ChatPage extends StatefulWidget {
  const ChatPage({
    Key? key,
    required this.s,
    required this.wide,
    this.embedded = false,
    this.onOpenSessions,
  }) : super(key: key);

  final S s;
  final bool wide;

  /// Hosted by [RootShell]: the page supplies no background of its own and
  /// draws its header as a glass bar over the shared backdrop.
  final bool embedded;
  final VoidCallback? onOpenSessions;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final ScrollController _scroll = ScrollController();
  final TextEditingController _input = TextEditingController();
  final Map<String, Widget> _cache = <String, Widget>{};
  bool _stick = true;
  bool _showJump = false;
  String _themeKey = '';
  String? _convId;

  List<Attachment> _attachments = <Attachment>[];
  String? _quote;
  int _visibleLimit = 30;

  double _lastPx = 0;
  Timer? _dockTimer;

  @override
  void initState() {
    super.initState();
    // The list is reversed, so "at the bottom" is offset 0.
    _scroll.addListener(() {
      if (!_scroll.hasClients) return;
      final double px = _scroll.position.pixels;
      final bool stick = px < 90;
      if (stick != _stick) {
        _stick = stick;
        if (mounted) setState(() {});
      }
      final bool show = px > 420;
      if (show != _showJump) {
        _showJump = show;
        if (mounted) setState(() {});
      }
      _trackDock(px);
    });
  }

  /// Reading back through history tucks the dock out of the way; scrolling
  /// towards the newest message brings it back. Either way it returns by
  /// itself after a moment, so a resting thumb is never stranded without
  /// navigation.
  void _trackDock(double px) {
    final double delta = px - _lastPx;
    _lastPx = px;
    if (px < 40) {
      DockVisibility.reset();
    } else if (delta > 3) {
      DockVisibility.set(true);
    } else if (delta < -3) {
      DockVisibility.reset();
    }
    if (DockVisibility.tucked.value) {
      _dockTimer?.cancel();
      _dockTimer = Timer(const Duration(milliseconds: 2600), () {
        if (mounted) DockVisibility.reset();
      });
    }
  }

  @override
  void dispose() {
    _dockTimer?.cancel();
    DockVisibility.reset();
    _scroll.dispose();
    _input.dispose();
    super.dispose();
  }

  void _scrollToBottom({bool animate = false}) {
    if (!_scroll.hasClients) return;
    if (animate) {
      _scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    } else if (_scroll.position.pixels != 0) {
      _scroll.jumpTo(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppState state = context.watch<AppState>();
    // Text shared from another app lands here; filling the box (rather than
    // sending) keeps the decision with the user.
    if (state.pendingDraft != null) {
      final String draft = state.takeDraft() ?? '';
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _input.text = draft;
        _input.selection = TextSelection.collapsed(offset: draft.length);
      });
    }
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final S s = widget.s;
    final Conversation? convo = state.current;

    if (convo?.id != _convId) {
      _convId = convo?.id;
      _visibleLimit = 30;
      _stick = true;
      _attachments = <Attachment>[];
      _quote = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToBottom();
      });
    }

    final String nextThemeKey =
        '${theme.brightness}|${cs.primary.value}|${theme.textTheme.bodyMedium?.fontSize}';
    if (nextThemeKey != _themeKey) {
      _themeKey = nextThemeKey;
      _cache.clear();
    }

    final List<ChatMessage> msgs = convo?.messages ?? <ChatMessage>[];

    if (state.pendingApproval != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _askApproval(state, s);
      });
    }

    if (_stick) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToBottom();
      });
    }

    return Column(
      children: <Widget>[
        _header(state, cs, s, convo),
        Expanded(
          child: Stack(
            children: <Widget>[
              msgs.isEmpty
                  ? _EmptyState(
                      s: s,
                      onPick: (String q) {
                        _input.text = q;
                        _input.selection =
                            TextSelection.collapsed(offset: _input.text.length);
                      },
                      onFiles: _openFiles,
                      onTerminal: _openTerminal,
                      onModules: _openModules,
                    )
                  : _transcript(state, msgs, convo, s),
              if (_showJump && msgs.isNotEmpty)
                Positioned(
                  right: 12,
                  bottom: 10,
                  child: FloatingActionButton.small(
                    elevation: 2,
                    backgroundColor: cs.surface,
                    foregroundColor: cs.primary,
                    onPressed: () {
                      _stick = true;
                      _scrollToBottom(animate: true);
                    },
                    child: const Icon(Icons.arrow_downward_rounded, size: 18),
                  ),
                ),
            ],
          ),
        ),
        Composer(
          controller: _input,
          embedded: widget.embedded,
          streaming: state.streaming,
          stopping: state.stopping,
          queue: state.queue,
          s: s,
          attachments: _attachments,
          quote: _quote,
          filePaths: state.fileIndex,
          extraCommands: state.customCommands,
          onRemoveAttachment: (Attachment a) {
            setState(() => _attachments = _attachments
                .where((Attachment x) => x.path != a.path)
                .toList());
          },
          onClearQuote: () => setState(() => _quote = null),
          onPickAttachment: _pickAttachment,
          onOpenFiles: _openFiles,
          onOpenTerminal: _openTerminal,
          onOpenModules: _openModules,
          onSend: (String text) => _submit(state, text),
          onStop: () => state.stop(),
          onSendNow: () => state.flushQueueNow(),
          onClearQueue: () {
            for (int i = state.queue.length - 1; i >= 0; i--) {
              state.removeQueued(i);
            }
          },
        ),
      ],
    );
  }

  Widget _transcript(
    AppState state,
    List<ChatMessage> msgs,
    Conversation? convo,
    S s,
  ) {
    final int total = msgs.length;
    final bool hasMore = total > _visibleLimit;
    final bool hasSummary = (convo?.summary.trim().isNotEmpty ?? false);
    final int shown = hasMore ? _visibleLimit : total;
    final int extra = (hasMore ? 1 : 0) + (hasSummary ? 1 : 0);

    return ListView.builder(
      controller: _scroll,
      reverse: true,
      cacheExtent: 700,
      padding: const EdgeInsets.fromLTRB(0, 18, 0, 6),
      itemCount: shown + extra,
      itemBuilder: (BuildContext ctx, int i) {
        if (i >= shown) {
          if (hasMore && i == shown) {
            return _loadEarlier(state);
          }
          return _summaryCard(state, convo!);
        }
        final int idx = total - 1 - i;
        return RepaintBoundary(
          child: _bubble(state, msgs[idx], idx == total - 1, s),
        );
      },
    );
  }

  Widget _loadEarlier(AppState state) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: InkWell(
          onTap: () => setState(() => _visibleLimit += 40),
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            decoration: BoxDecoration(
              color: cs.onSurface.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(
              widget.s.isEnglish ? 'Load earlier messages' : '加载更早的消息',
              style: TextStyle(
                fontSize: 11.5,
                color: cs.onSurface.withValues(alpha: 0.55),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _summaryCard(AppState state, Conversation convo) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool en = widget.s.isEnglish;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
      child: InkWell(
        onTap: () => _showSummary(state, convo, en),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
          decoration: BoxDecoration(
            color: cs.primary.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: cs.primary.withValues(alpha: 0.12)),
          ),
          child: Row(
            children: <Widget>[
              Icon(Icons.compress_rounded, size: 14, color: cs.primary),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  en
                      ? '${convo.compactedCount} earlier messages folded into a summary'
                      : '早期 ${convo.compactedCount} 条消息已压缩为摘要',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: cs.onSurface.withValues(alpha: 0.55),
                  ),
                ),
              ),
              Icon(Icons.chevron_right_rounded,
                  size: 16, color: cs.onSurface.withValues(alpha: 0.3)),
            ],
          ),
        ),
      ),
    );
  }

  void _showSummary(AppState state, Conversation convo, bool en) {
    showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(en ? 'Context summary' : '上下文摘要',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 320),
          child: SingleChildScrollView(
            child: SelectableText(
              convo.summary,
              style: const TextStyle(fontSize: 12.5, height: 1.6),
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              state.clearSummary();
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(en ? 'Summary cleared' : '已清除摘要，恢复完整上下文'),
              ));
            },
            child: Text(en ? 'Clear' : '清除'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(widget.s.ok),
          ),
        ],
      ),
    );
  }

  Widget _bubble(AppState state, ChatMessage m, bool last, S s) =>
      _bubbleBody(state, m, last, s);

  Widget _bubbleBody(AppState state, ChatMessage m, bool last, S s) {
    String resolve(String p) => state.tools?.resolvePath(p) ?? p;
    if (m.streaming) {
      return MessageBubble(
        message: m,
        s: s,
        isLast: last,
        onRegenerate: state.regenerate,
        onQuote: () => _quoteMessage(m),
        resolvePath: resolve,
        tools: m.tools,
      );
    }
    final String toolKey = m.tools
        .map((ToolCall t) =>
            '${t.status.index}:${t.output.length}:${t.input.length}')
        .join(',');
    final String key = '${m.id}|${m.text.length}|${m.error}|${m.stopped}|'
        '${m.thinking.length}|${m.inputTokens}|${m.outputTokens}|'
        '${m.attachments.length}|${m.compacted}|$toolKey';
    return _cache.putIfAbsent(
      key,
      () => MessageBubble(
        message: m,
        s: s,
        isLast: last,
        onRegenerate: state.regenerate,
        onRetry: state.regenerate,
        onQuote: () => _quoteMessage(m),
        resolvePath: resolve,
        tools: m.tools,
        onEdit: m.isUser ? () => _editMessage(state, m, s) : null,
        onDelete: () => _confirmDeleteMessage(state, m, s),
      ),
    );
  }

  void _quoteMessage(ChatMessage m) {
    final String text = m.text.trim();
    if (text.isEmpty) return;
    setState(() => _quote = text.length > 600 ? text.substring(0, 600) : text);
    _stick = true;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(
            widget.s.isEnglish ? 'Quoted — type your reply' : '已引用，输入你的追问'),
        duration: const Duration(milliseconds: 1400),
      ));
  }

  // ------------------------------------------------------------------ commands

  Future<void> _submit(AppState state, String raw) async {
    final String text = raw.trim();
    if (text.isEmpty && _attachments.isEmpty) return;

    if (text.startsWith('/') && !text.contains('\n')) {
      final List<String> parts = text.substring(1).split(RegExp(r'\s+'));
      final SlashCommand? cmd = findCommand(parts.first);
      if (cmd == null) {
        // Plugin commands expand into a normal prompt, so they run through the
        // same path as typed text.
        final String args = parts.skip(1).join(' ').trim();
        final String? expanded = state.customCommandPrompt(parts.first, args);
        if (expanded == null) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(SnackBar(
              content: Text(widget.s.isEnglish
                  ? 'Unknown command: /${parts.first}'
                  : '未知命令：/${parts.first}'),
              duration: const Duration(milliseconds: 1500),
            ));
          return;
        }
        state.send(expanded, attachments: _attachments, quote: _quote);
        setState(() {
          _attachments = <Attachment>[];
          _quote = null;
        });
        _scrollToBottom();
        return;
      }
      final String arg = parts.skip(1).join(' ').trim();
      await _runCommand(state, cmd, arg);
      return;
    }

    _stick = true;
    state.send(text, attachments: _attachments, quote: _quote);
    setState(() {
      _attachments = <Attachment>[];
      _quote = null;
      _visibleLimit = 30;
    });
    _scrollToBottom();
  }

  Future<void> _runCommand(AppState state, SlashCommand cmd, String arg) async {
    final bool en = widget.s.isEnglish;
    switch (cmd.name) {
      case 'new':
        state.newConversation();
        break;
      case 'clear':
        state.clearCurrent();
        break;
      case 'compact':
        final int n = state.compact();
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            content: Text(n == 0
                ? (en ? 'Nothing to compact yet' : '当前没有可压缩的内容')
                : (en
                    ? 'Folded $n messages into the summary'
                    : '已把 $n 条早期消息折叠为摘要')),
          ));
        break;
      case 'automation':
        await _openAutomation();
        break;
      case 'workspace':
        await _openWorkspace();
        break;
      case 'files':
        await _openFiles();
        break;
      case 'terminal':
        await _openTerminal();
        break;
      case 'modules':
        await _openModules();
        break;
      case 'plugins':
        await _openPlugins();
        break;
      case 'settings':
        await _openSettings();
        break;
      case 'undo':
        final int n = await state.undoLastTurn();
        _toast(n == 0
            ? (en ? 'Nothing to undo' : '没有可撤销的改动')
            : (en ? 'Restored $n files' : '已恢复 $n 个文件'));
        break;
      case 'export':
        _exportMarkdown(state.current, widget.s);
        break;
      case 'model':
        if (arg.isEmpty) {
          await _pickModel(state);
        } else {
          final AppConfig? cfg = state.config;
          if (cfg != null) {
            await state.saveConfig(cfg.copyWith(model: arg));
            _toast(en ? 'Model: $arg' : '模型已切换到 $arg');
          }
        }
        break;
      case 'help':
        _showHelp(state, en);
        break;
    }
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(text),
        duration: const Duration(milliseconds: 1500),
      ));
  }

  void _showHelp(AppState state, bool en) {
    showModalBottomSheet<void>(
      context: context,
      builder: (BuildContext ctx) {
        final ColorScheme cs = Theme.of(ctx).colorScheme;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  en ? 'Commands' : '可用命令',
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 10),
                for (final SlashCommand c in <SlashCommand>[
                  ...kSlashCommands,
                  ...state.customCommands,
                ])
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Row(
                      children: <Widget>[
                        SizedBox(
                          width: 96,
                          child: Text(
                            c.usage,
                            style: TextStyle(
                              fontSize: 12,
                              fontFamily: 'monospace',
                              color: cs.primary,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            en ? c.en : c.zh,
                            style: TextStyle(
                              fontSize: 12.5,
                              color: cs.onSurface.withValues(alpha: 0.7),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 8),
                Text(
                  en
                      ? 'Tip: type @ to attach a workspace file to your message.'
                      : '提示：输入 @ 可以把工作区里的文件直接附给模型。',
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.5,
                    color: cs.onSurface.withValues(alpha: 0.4),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // -------------------------------------------------------------------- pages

  Future<void> _openAutomation() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const AutomationPage()),
    );
  }

  Future<void> _openWorkspace() async {
    final bool? changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => WorkspacePickerPage(
            initialPath: context.read<AppState>().workspacePath),
      ),
    );
    if (!mounted || changed != true) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(context.read<AppState>().workspacePath),
        duration: const Duration(milliseconds: 1600),
      ));
  }

  Future<void> _openFiles() async {
    final String? mention = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(builder: (_) => const FilesPage()),
    );
    if (!mounted || mention == null) return;
    _insertIntoComposer('$mention ');
    context.read<AppState>().refreshFileIndex();
  }

  Future<void> _openTerminal() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const TerminalPage()),
    );
  }

  Future<void> _openPlugins() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => const PluginsPage(),
    ));
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _openModules() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const ModulesPage()),
    );
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
    );
  }

  void _insertIntoComposer(String snippet) {
    final String current = _input.text;
    final int at = _input.selection.baseOffset < 0
        ? current.length
        : _input.selection.baseOffset;
    final String next = current.replaceRange(at, at, snippet);
    _input.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: at + snippet.length),
    );
    setState(() {});
  }

  Future<void> _pickAttachment() async {
    final AppState state = context.read<AppState>();
    final bool en = widget.s.isEnglish;
    final List<String> files = state.fileIndex;
    String query = '';
    final String? picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, StateSetter setSheet) {
          final List<String> shown = files
              .where((String p) =>
                  query.isEmpty ||
                  p.toLowerCase().contains(query.toLowerCase()))
              .take(120)
              .toList();
          return SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.62,
            child: Column(
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                  child: Row(
                    children: <Widget>[
                      Text(
                        en ? 'Attach a file' : '附加文件',
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w600),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: () {
                          Navigator.pop(ctx);
                          _openFiles();
                        },
                        child: Text(en ? 'Browse…' : '浏览工作区…'),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: TextField(
                    onChanged: (String v) => setSheet(() => query = v),
                    style: const TextStyle(fontSize: 13),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: en ? 'Filter files' : '筛选文件',
                      prefixIcon: const Icon(Icons.search_rounded, size: 18),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Expanded(
                  child: shown.isEmpty
                      ? Center(
                          child: Text(
                            en ? 'No files yet' : '工作区里还没有文件',
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(ctx)
                                  .colorScheme
                                  .onSurface
                                  .withValues(alpha: 0.4),
                            ),
                          ),
                        )
                      : ListView.builder(
                          itemCount: shown.length,
                          itemBuilder: (BuildContext c, int i) {
                            final String p = shown[i];
                            final bool image = Attachment.looksLikeImage(p);
                            return ListTile(
                              dense: true,
                              leading: Icon(
                                image
                                    ? Icons.image_outlined
                                    : Icons.description_outlined,
                                size: 18,
                              ),
                              title: Text(
                                p,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 12, fontFamily: 'monospace'),
                              ),
                              onTap: () => Navigator.pop(ctx, p),
                            );
                          },
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
    if (picked == null) return;
    final Attachment? a = await state.attach(picked);
    if (a == null) return;
    if (_attachments.any((Attachment x) => x.path == a.path)) return;
    if (!mounted) return;
    setState(() => _attachments = <Attachment>[..._attachments, a]);
  }

  bool _asking = false;

  /// Blocks the agent until the user allows or denies a risky tool call.
  Future<void> _askApproval(AppState state, S s) async {
    if (_asking) return;
    final ToolCall? call = state.pendingApproval;
    if (call == null || !mounted) return;
    _asking = true;
    final bool en = s.isEnglish;
    final String detail = _approvalDetail(call);
    final bool? ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(
          en ? 'Run this action?' : '允许执行这个操作？',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Theme.of(ctx)
                        .colorScheme
                        .primary
                        .withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(
                    call.isShell ? 'bash' : call.name,
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      color: Theme.of(ctx).colorScheme.primary,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    en
                        ? 'The agent wants to change files in the workspace.'
                        : '智能体准备修改工作区里的文件。',
                    style: TextStyle(
                      fontSize: 11.5,
                      height: 1.4,
                      color: Theme.of(ctx)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.5),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 240),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF0F1319),
                borderRadius: BorderRadius.circular(8),
              ),
              child: SingleChildScrollView(
                child: Text(
                  detail,
                  style: const TextStyle(
                    fontSize: 12,
                    height: 1.45,
                    fontFamily: 'monospace',
                    color: Color(0xFFD6DDE6),
                  ),
                ),
              ),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(en ? 'Deny' : '拒绝'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(en ? 'Allow' : '允许'),
          ),
        ],
      ),
    );
    state.resolveApproval(ok == true);
    _asking = false;
  }

  String _approvalDetail(ToolCall call) {
    switch (call.name) {
      case 'bash':
        return '${call.input['command'] ?? ''}';
      case 'write_file':
        return '${call.input['path'] ?? ''}\n'
            '+ ${('${call.input['content'] ?? ''}').split('\n').length} lines';
      case 'edit_file':
        return '${call.input['path'] ?? ''}\n'
            '- ${('${call.input['old_string'] ?? ''}').split('\n').length} lines\n'
            '+ ${('${call.input['new_string'] ?? ''}').split('\n').length} lines';
      case 'move_file':
        return '${call.input['from'] ?? ''} → ${call.input['to'] ?? ''}';
      case 'delete_file':
        return '${call.input['path'] ?? ''}\n'
            '${call.input['recursive'] == true ? '(recursive)' : ''}';
      default:
        return call.title;
    }
  }

  Widget _header(AppState state, ColorScheme cs, S s, Conversation? convo) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final String title = (convo?.previewTitle().isNotEmpty ?? false)
        ? convo!.previewTitle()
        : s.newChatShort;
    final Widget bar = Container(
      padding: EdgeInsets.fromLTRB(widget.wide ? 20 : 6, 6, 8, 6),
      decoration: widget.embedded
          ? null
          : BoxDecoration(
              color: dark ? const Color(0xFF0C0E12) : Colors.white,
              border: Border(
                bottom: BorderSide(
                  color: cs.onSurface.withValues(alpha: 0.07),
                ),
              ),
            ),
      child: SafeArea(
        bottom: false,
        child: Row(
          children: <Widget>[
            if (!widget.wide)
              IconButton(
                icon: const Icon(Icons.menu_rounded, size: 22),
                tooltip: s.sessions,
                onPressed: widget.onOpenSessions,
              ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 16.5,
                      height: 1.2,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.1,
                      color: cs.onSurface,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Row(
                    children: <Widget>[
                      _modelChip(state, cs),
                      if (state.contextChars > 0) ...<Widget>[
                        const SizedBox(width: 7),
                        Text(
                          _contextLabel(state.contextChars),
                          style: TextStyle(
                            fontSize: 10,
                            color: cs.onSurface.withValues(alpha: 0.3),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.add_comment_outlined, size: 20),
              tooltip: s.newChat,
              onPressed: () => state.newConversation(),
            ),
            _moreMenu(state, s, convo),
          ],
        ),
      ),
    );

    if (!widget.embedded) return bar;
    // Inside the shell the header is a real glass bar: the backdrop is
    // refracted by 6% so text scrolling under it visibly bends.
    final AppPalette p = AppPalette.of(context);
    return GlassSurface(
      radius: 0,
      blur: 18,
      quality: GlassQuality.full,
      shadow: false,
      border: false,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: p.line, width: 0.8)),
        ),
        child: bar,
      ),
    );
  }

  String _contextLabel(int chars) {
    final int tokens = (chars / 3.2).round();
    if (tokens < 1000) return '~$tokens tok';
    return '~${(tokens / 1000).toStringAsFixed(1)}k tok';
  }

  Widget _modelChip(AppState state, ColorScheme cs) {
    final AppConfig? cfg = state.config;
    if (cfg == null) return const SizedBox.shrink();
    return InkWell(
      onTap: () => _pickModel(state),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 1, horizontal: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                color: cs.primary,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 5),
            Text(
              cfg.model,
              style: TextStyle(
                fontSize: 11,
                color: cs.onSurface.withValues(alpha: 0.5),
                letterSpacing: 0.1,
              ),
            ),
            Icon(Icons.expand_more_rounded,
                size: 13, color: cs.onSurface.withValues(alpha: 0.4)),
          ],
        ),
      ),
    );
  }

  Widget _moreMenu(AppState state, S s, Conversation? convo) {
    final bool en = s.isEnglish;
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert_rounded, size: 20),
      tooltip: '',
      onSelected: (String v) async {
        switch (v) {
          case 'clear':
            state.clearCurrent();
            break;
          case 'export':
            _exportMarkdown(convo, s);
            break;
          case 'automation':
            await _openAutomation();
            break;
          case 'workspace':
            await _openWorkspace();
            break;
          case 'files':
            await _openFiles();
            break;
          case 'terminal':
            await _openTerminal();
            break;
          case 'modules':
            await _openModules();
            break;
          case 'compact':
            final int n = state.compact();
            _toast(n == 0
                ? (en ? 'Nothing to compact' : '没有可压缩的内容')
                : (en ? 'Folded $n messages' : '已压缩 $n 条消息'));
            break;
          case 'settings':
            await _openSettings();
            break;
        }
      },
      itemBuilder: (BuildContext ctx) => <PopupMenuEntry<String>>[
        _menuItem('automation', Icons.auto_awesome_rounded,
            en ? 'Automation' : '自动化'),
        _menuItem('workspace', Icons.smartphone_rounded,
            en ? 'Workspace folder' : '工作区文件夹'),
        _menuItem('files', Icons.folder_open_rounded, en ? 'Files' : '文件'),
        _menuItem('terminal', Icons.terminal_rounded, en ? 'Terminal' : '终端'),
        _menuItem('modules', Icons.extension_outlined, en ? 'Modules' : '扩展模块'),
        const PopupMenuDivider(height: 6),
        _menuItem('compact', Icons.compress_rounded,
            en ? 'Compact context' : '压缩上下文'),
        _menuItem(
            'undo', Icons.undo_rounded, en ? 'Undo file changes' : '撤销本轮改动',
            enabled: state.canUndo),
        _menuItem('export', Icons.ios_share_rounded,
            en ? 'Export as Markdown' : '导出为 Markdown'),
        _menuItem('clear', Icons.cleaning_services_outlined,
            en ? 'Clear chat' : '清空当前会话'),
        const PopupMenuDivider(height: 6),
        _menuItem('settings', Icons.settings_outlined, s.settings),
      ],
    );
  }

  PopupMenuItem<String> _menuItem(
    String value,
    IconData icon,
    String label, {
    bool enabled = true,
  }) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Color tint =
        enabled ? cs.onSurface : cs.onSurface.withValues(alpha: 0.32);
    return PopupMenuItem<String>(
      value: value,
      enabled: enabled,
      child: Row(children: <Widget>[
        Icon(icon, size: 17, color: tint),
        const SizedBox(width: 10),
        Text(label, style: TextStyle(fontSize: 13.5, color: tint)),
      ]),
    );
  }

  void _exportMarkdown(Conversation? convo, S s) {
    if (convo == null || convo.messages.isEmpty) return;
    Clipboard.setData(ClipboardData(text: convo.toMarkdown()));
    _toast(s.copied);
  }

  Future<void> _editMessage(AppState state, ChatMessage m, S s) async {
    final TextEditingController ctrl = TextEditingController(text: m.text);
    final String? next = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(s.editResend,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          minLines: 3,
          maxLines: 8,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(s.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: Text(s.sendNow),
          ),
        ],
      ),
    );
    if (next != null && next.trim().isNotEmpty) {
      state.editAndResend(m.id, next);
      _stick = true;
    }
  }

  Future<void> _confirmDeleteMessage(AppState state, ChatMessage m, S s) async {
    final bool? yes = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        content: Text(s.deleteConfirm,
            style: const TextStyle(fontSize: 14.5, height: 1.5)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(s.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(s.delete),
          ),
        ],
      ),
    );
    if (yes == true) state.deleteMessage(m.id);
  }

  Future<void> _pickModel(AppState state) async {
    final AppConfig? cfg = state.config;
    if (cfg == null) return;
    final bool en = widget.s.isEnglish;
    final String? picked = await showModalBottomSheet<String>(
      context: context,
      builder: (BuildContext ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final String m in kGlmModels)
              ListTile(
                dense: true,
                leading: Icon(
                  m == cfg.model
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 18,
                  color:
                      m == cfg.model ? Theme.of(ctx).colorScheme.primary : null,
                ),
                title: Text(m, style: const TextStyle(fontSize: 14)),
                onTap: () => Navigator.pop(ctx, m),
              ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.edit_outlined, size: 18),
              title: Text(en ? 'Custom model id' : '自定义模型 ID',
                  style: const TextStyle(fontSize: 14)),
              onTap: () => Navigator.pop(ctx, '__custom__'),
            ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
    if (picked == null) return;
    String next = picked;
    if (picked == '__custom__') {
      final String? custom = await _askModel();
      if (custom == null || custom.trim().isEmpty) return;
      next = custom.trim();
    }
    if (next.trim().isNotEmpty) {
      await state.saveConfig(cfg.copyWith(model: next.trim()));
    }
  }

  Future<String?> _askModel() async {
    final TextEditingController ctrl = TextEditingController(
      text: context.read<AppState>().config?.model ?? '',
    );
    return showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(widget.s.custom,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        content: TextField(controller: ctrl, autofocus: true),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(widget.s.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: Text(widget.s.ok),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.s,
    required this.onPick,
    required this.onFiles,
    required this.onTerminal,
    required this.onModules,
  });

  final S s;
  final ValueChanged<String> onPick;
  final VoidCallback onFiles;
  final VoidCallback onTerminal;
  final VoidCallback onModules;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final bool dark = theme.brightness == Brightness.dark;
    final bool en = s.isEnglish;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              Container(
                width: 54,
                height: 54,
                decoration: BoxDecoration(
                  color: cs.primary,
                  borderRadius: AppTokens.brMd,
                ),
                alignment: Alignment.center,
                child: const Icon(Icons.bolt_rounded,
                    size: 28, color: Colors.white),
              ),
              const SizedBox(height: 18),
              Text(
                s.welcomeTitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.3,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                s.welcomeSub,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.55,
                  color: cs.onSurface.withValues(alpha: 0.5),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  _capability(
                    icon: Icons.folder_open_rounded,
                    label: en ? 'Files' : '文件',
                    onTap: onFiles,
                    cs: cs,
                    dark: dark,
                  ),
                  const SizedBox(width: 8),
                  _capability(
                    icon: Icons.terminal_rounded,
                    label: en ? 'Terminal' : '终端',
                    onTap: onTerminal,
                    cs: cs,
                    dark: dark,
                  ),
                  const SizedBox(width: 8),
                  _capability(
                    icon: Icons.extension_outlined,
                    label: en ? 'Modules' : '模块',
                    onTap: onModules,
                    cs: cs,
                    dark: dark,
                  ),
                ],
              ),
              const SizedBox(height: 18),
              for (final String q in <String>[s.ex1, s.ex2, s.ex3])
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _PromptCard(label: q, onTap: () => onPick(q)),
                ),
              const SizedBox(height: 8),
              Text(
                s.tokensNote,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 10.5,
                  height: 1.5,
                  color: cs.onSurface.withValues(alpha: 0.3),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _capability({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    required ColorScheme cs,
    required bool dark,
  }) {
    return PressScale(
      radius: AppTokens.rSm,
      child: Material(
        color: Colors.transparent,
        borderRadius: AppTokens.brSm,
        child: InkWell(
          onTap: onTap,
          borderRadius: AppTokens.brSm,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: cs.surface,
              borderRadius: AppTokens.brSm,
              border: Border.all(
                color: cs.onSurface.withValues(alpha: 0.08),
                width: 0.8,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(icon, size: 14, color: cs.primary.withValues(alpha: 0.85)),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: cs.onSurface.withValues(alpha: 0.72),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PromptCard extends StatelessWidget {
  const _PromptCard({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final AppPalette p = AppPalette.of(context);
    return PressScale(
      radius: AppTokens.rSm,
      child: Material(
        color: p.surface,
        borderRadius: AppTokens.brSm,
        child: InkWell(
          onTap: onTap,
          borderRadius: AppTokens.brSm,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: AppTokens.brSm,
              border: Border.all(color: p.line, width: 0.8),
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.35,
                      color: p.textSecondary,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Icon(Icons.arrow_forward_rounded,
                    size: 14, color: cs.primary.withValues(alpha: 0.7)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
