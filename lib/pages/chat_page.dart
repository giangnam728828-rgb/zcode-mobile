import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/app_config.dart';
import '../agent/tools.dart';
import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../state/app_state.dart';
import '../widgets/composer.dart';
import '../widgets/message_bubble.dart';
import '../widgets/tool_card.dart';
import 'settings_page.dart';

/// The conversation view: header, transcript, composer.
class ChatPage extends StatefulWidget {
  const ChatPage({
    Key? key,
    required this.s,
    required this.wide,
    this.onOpenSessions,
  }) : super(key: key);

  final S s;
  final bool wide;
  final VoidCallback? onOpenSessions;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final ScrollController _scroll = ScrollController();
  final TextEditingController _input = TextEditingController();
  final Map<String, Widget> _cache = <String, Widget>{};
  bool _stick = true;
  String _themeKey = '';

  @override
  void initState() {
    super.initState();
    // The list is reversed, so "at the bottom" is offset 0.
    _scroll.addListener(() {
      if (!_scroll.hasClients) return;
      _stick = _scroll.position.pixels < 90;
    });
  }

  @override
  void dispose() {
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
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final S s = widget.s;
    final Conversation? convo = state.current;

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
          child: msgs.isEmpty
              ? _EmptyState(
                  s: s,
                  onPick: (String q) {
                    state.send(q);
                    _stick = true;
                  },
                )
              : ListView.builder(
                  controller: _scroll,
                  reverse: true,
                  padding: const EdgeInsets.fromLTRB(0, 18, 0, 6),
                  itemCount: msgs.length,
                  itemBuilder: (BuildContext ctx, int i) {
                    final int idx = msgs.length - 1 - i;
                    return _bubble(state, msgs[idx], idx == msgs.length - 1, s);
                  },
                ),
        ),
        Composer(
          controller: _input,
          streaming: state.streaming,
          queue: state.queue,
          s: s,
          onSend: (String text) {
            _stick = true;
            state.send(text);
          },
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

  Widget _bubble(AppState state, ChatMessage m, bool last, S s) {
    final Widget bubble = _bubbleBody(state, m, last, s);
    if (m.tools.isEmpty) return bubble;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        bubble,
        for (final ToolCall t in m.tools) ToolCard(call: t),
      ],
    );
  }

  Widget _bubbleBody(AppState state, ChatMessage m, bool last, S s) {
    if (m.streaming) {
      return MessageBubble(
        message: m,
        s: s,
        isLast: last,
        onRegenerate: state.regenerate,
      );
    }
    final String key =
        '${m.id}|${m.text.length}|${m.error}|${m.stopped}|${m.thinking.length}';
    return _cache.putIfAbsent(
      key,
      () => MessageBubble(
        message: m,
        s: s,
        isLast: last,
        onRegenerate: state.regenerate,
        onRetry: state.regenerate,
        onEdit: m.isUser
            ? () => _editMessage(state, m, s)
            : null,
        onDelete: () => _confirmDeleteMessage(state, m, s),
      ),
    );
  }

  bool _asking = false;

  /// Blocks the agent until the user allows or denies a risky tool call.
  Future<void> _askApproval(AppState state, S s) async {
    if (_asking) return;
    final ToolCall? call = state.pendingApproval;
    if (call == null || !mounted) return;
    _asking = true;
    final bool en = s.isEnglish;
    final String detail = call.isShell
        ? '${call.input['command'] ?? ''}'
        : call.name == 'write_file'
            ? '${call.input['path'] ?? ''}\n+ ${('${call.input['content'] ?? ''}').split('\n').length} lines'
            : '${call.input['path'] ?? call.title}';
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
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Theme.of(ctx).colorScheme.primary.withOpacity(0.12),
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
              ],
            ),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 220),
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

  Widget _header(AppState state, ColorScheme cs, S s, Conversation? convo) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final String title =
        (convo?.previewTitle().isNotEmpty ?? false)
            ? convo!.previewTitle()
            : s.newChatShort;
    return Container(
      padding: EdgeInsets.fromLTRB(widget.wide ? 20 : 6, 6, 8, 6),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF0C0E12) : Colors.white,
        border: Border(
          bottom: BorderSide(
            color: cs.onSurface.withOpacity(0.07),
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
                      fontSize: 15.5,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                    ),
                  ),
                  const SizedBox(height: 1),
                  _modelChip(state, cs),
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
                color: cs.onSurface.withOpacity(0.5),
                letterSpacing: 0.1,
              ),
            ),
            Icon(Icons.expand_more_rounded,
                size: 13, color: cs.onSurface.withOpacity(0.4)),
          ],
        ),
      ),
    );
  }

  Widget _moreMenu(AppState state, S s, Conversation? convo) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert_rounded, size: 20),
      tooltip: '',
      onSelected: (String v) {
        switch (v) {
          case 'clear':
            state.clearCurrent();
            break;
          case 'export':
            _exportMarkdown(convo, s);
            break;
          case 'settings':
            Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
            );
            break;
        }
      },
      itemBuilder: (BuildContext ctx) => <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          value: 'clear',
          child: Row(children: <Widget>[
            const Icon(Icons.cleaning_services_outlined, size: 17),
            const SizedBox(width: 10),
            Text(s.clearChat, style: const TextStyle(fontSize: 13.5)),
          ]),
        ),
        PopupMenuItem<String>(
          value: 'export',
          child: Row(children: <Widget>[
            const Icon(Icons.ios_share_rounded, size: 17),
            const SizedBox(width: 10),
            Text(s.shareChat, style: const TextStyle(fontSize: 13.5)),
          ]),
        ),
        PopupMenuItem<String>(
          value: 'settings',
          child: Row(children: <Widget>[
            const Icon(Icons.settings_outlined, size: 17),
            const SizedBox(width: 10),
            Text(s.settings, style: const TextStyle(fontSize: 13.5)),
          ]),
        ),
      ],
    );
  }

  void _exportMarkdown(Conversation? convo, S s) {
    if (convo == null || convo.messages.isEmpty) return;
    Clipboard.setData(ClipboardData(text: convo.toMarkdown()));
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(s.copied)));
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

  Future<void> _confirmDeleteMessage(
      AppState state, ChatMessage m, S s) async {
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
                  color: m == cfg.model
                      ? Theme.of(ctx).colorScheme.primary
                      : null,
                ),
                title: Text(m, style: const TextStyle(fontSize: 14)),
                onTap: () => Navigator.pop(ctx, m),
              ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.edit_outlined, size: 18),
              title: Text(widget.s.custom,
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
  const _EmptyState({required this.s, required this.onPick});

  final S s;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final bool dark = theme.brightness == Brightness.dark;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              Container(
                width: 62,
                height: 62,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: <Color>[
                      cs.primary,
                      cs.primary.withOpacity(0.65),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: cs.primary.withOpacity(dark ? 0.30 : 0.22),
                      blurRadius: 22,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                alignment: Alignment.center,
                child: const Icon(Icons.bolt_rounded,
                    size: 34, color: Colors.white),
              ),
              const SizedBox(height: 20),
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
                  fontSize: 13.5,
                  height: 1.55,
                  color: cs.onSurface.withOpacity(0.5),
                ),
              ),
              const SizedBox(height: 22),
              for (final String q in <String>[s.ex1, s.ex2, s.ex3])
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _PromptCard(label: q, onTap: () => onPick(q)),
                ),
              const SizedBox(height: 10),
              Text(
                s.tokensNote,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.5,
                  color: cs.onSurface.withOpacity(0.32),
                ),
              ),
            ],
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
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final bool dark = theme.brightness == Brightness.dark;
    return Material(
      color: dark ? const Color(0xFF12151A) : Colors.white,
      borderRadius: BorderRadius.circular(13),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(13),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(13),
            border: Border.all(color: cs.onSurface.withOpacity(0.08)),
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 13.5,
                    color: cs.onSurface.withOpacity(0.82),
                  ),
                ),
              ),
              Icon(Icons.north_east_rounded,
                  size: 14, color: cs.onSurface.withOpacity(0.28)),
            ],
          ),
        ),
      ),
    );
  }
}
