import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../agent/commands.dart';
import '../l10n/strings.dart';
import '../models/attachment.dart';

/// The single-input composer. One send key: while a turn runs, text is queued
/// instead of blocked (same model as DSH Go), and the key becomes stop when
/// the box is empty.
///
/// Typing `/` opens the command palette, `@` autocompletes workspace files —
/// both run locally against a cached index so the list never lags typing.
class Composer extends StatefulWidget {
  const Composer({
    Key? key,
    required this.controller,
    required this.streaming,
    required this.queue,
    required this.s,
    required this.onSend,
    required this.onStop,
    required this.onSendNow,
    required this.onClearQueue,
    this.attachments = const <Attachment>[],
    this.onRemoveAttachment,
    this.quote,
    this.onClearQuote,
    this.onPickAttachment,
    this.onOpenFiles,
    this.onOpenTerminal,
    this.onOpenModules,
    this.filePaths = const <String>[],
    this.extraCommands = const <SlashCommand>[],
  }) : super(key: key);

  final TextEditingController controller;
  final bool streaming;
  final List<String> queue;
  final S s;
  final ValueChanged<String> onSend;
  final VoidCallback onStop;
  final VoidCallback onSendNow;
  final VoidCallback onClearQueue;

  final List<Attachment> attachments;
  final ValueChanged<Attachment>? onRemoveAttachment;
  final String? quote;
  final VoidCallback? onClearQuote;
  final VoidCallback? onPickAttachment;
  final VoidCallback? onOpenFiles;
  final VoidCallback? onOpenTerminal;
  final VoidCallback? onOpenModules;
  final List<String> filePaths;

  /// Commands contributed by installed plugins.
  final List<SlashCommand> extraCommands;

  @override
  State<Composer> createState() => _ComposerState();
}

class _Suggestion {
  const _Suggestion({
    required this.icon,
    required this.label,
    required this.hint,
    required this.insert,
    this.submit = false,
  });

  final IconData icon;
  final String label;
  final String hint;
  final String insert;
  final bool submit;
}

class _ComposerState extends State<Composer> {
  final FocusNode _focus = FocusNode();
  bool _hasText = false;
  List<_Suggestion> _suggestions = const <_Suggestion>[];

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onText);
    _focus.addListener(_onFocus);
    _hasText = widget.controller.text.trim().isNotEmpty;
  }

  @override
  void didUpdateWidget(covariant Composer old) {
    super.didUpdateWidget(old);
    if (old.filePaths != widget.filePaths &&
        widget.controller.text.contains('@')) {
      _rebuildSuggestions();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onText);
    _focus.removeListener(_onFocus);
    _focus.dispose();
    super.dispose();
  }

  void _onFocus() {
    if (mounted) setState(() {});
  }

  void _onText() {
    final bool next = widget.controller.text.trim().isNotEmpty;
    if (next != _hasText) {
      setState(() => _hasText = next);
    }
    _rebuildSuggestions();
  }

  bool get _isSingleCommand =>
      widget.controller.text.startsWith('/') &&
      !widget.controller.text.contains('\n');

  void _rebuildSuggestions() {
    final String text = widget.controller.text;
    List<_Suggestion> next = const <_Suggestion>[];

    if (_isSingleCommand) {
      final String body = text.substring(1);
      if (!body.contains(' ')) {
        final String q = body.toLowerCase();
        next = <SlashCommand>[...kSlashCommands, ...widget.extraCommands]
            .where((SlashCommand c) => c.name.startsWith(q))
            .map((SlashCommand c) => _Suggestion(
                  icon: _commandIcon(c.name),
                  label: c.usage,
                  hint: widget.s.isEnglish ? c.en : c.zh,
                  insert: c.takesArg ? '/${c.name} ' : '/${c.name}',
                  submit: !c.takesArg,
                ))
            .toList();
      }
    } else {
      final RegExpMatch? m = RegExp(r'(^|\s)@([^\s@]*)$').firstMatch(text);
      if (m != null) {
        final String q = (m.group(2) ?? '').toLowerCase();
        final List<String> hits = <String>[];
        for (final String p in widget.filePaths) {
          if (p.toLowerCase().contains(q)) hits.add(p);
          if (hits.length >= 6) break;
        }
        next = <_Suggestion>[
          for (final String p in hits)
            _Suggestion(
              icon: Attachment.looksLikeImage(p)
                  ? Icons.image_outlined
                  : Icons.description_outlined,
              label: p,
              hint: widget.s.isEnglish ? 'Attach file' : '附上文件内容',
              insert: '@$p ',
            ),
        ];
      }
    }

    if (next.length != _suggestions.length ||
        (next.isNotEmpty && next.first.label != _suggestions.first.label)) {
      setState(() => _suggestions = next);
    }
  }

  IconData _commandIcon(String name) {
    switch (name) {
      case 'new':
        return Icons.add_comment_outlined;
      case 'clear':
        return Icons.cleaning_services_outlined;
      case 'compact':
        return Icons.compress_rounded;
      case 'undo':
        return Icons.undo_rounded;
      case 'files':
        return Icons.folder_open_rounded;
      case 'terminal':
        return Icons.terminal_rounded;
      case 'modules':
        return Icons.extension_outlined;
      case 'plugins':
        return Icons.widgets_outlined;
      case 'model':
        return Icons.memory_rounded;
      case 'settings':
        return Icons.settings_outlined;
      case 'export':
        return Icons.ios_share_rounded;
      default:
        return Icons.help_outline_rounded;
    }
  }

  void _submit() {
    final String text = widget.controller.text.trim();
    if (text.isEmpty) return;
    widget.controller.clear();
    setState(() => _suggestions = const <_Suggestion>[]);
    HapticFeedback.lightImpact();
    widget.onSend(text);
    if (!widget.streaming) _focus.requestFocus();
  }

  void _accept(_Suggestion s) {
    if (s.submit) {
      widget.controller.clear();
      setState(() => _suggestions = const <_Suggestion>[]);
      HapticFeedback.selectionClick();
      widget.onSend(s.insert);
      return;
    }
    final String text = widget.controller.text;
    String next;
    if (s.insert.startsWith('/')) {
      next = s.insert;
    } else {
      final int at = text.lastIndexOf('@');
      next = at < 0
          ? '$text${s.insert}'
          : '${text.substring(0, at)}${s.insert}';
    }
    widget.controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: next.length),
    );
    setState(() => _suggestions = const <_Suggestion>[]);
    _focus.requestFocus();
  }

  bool get _desktopLike =>
      kIsWeb ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final bool dark = theme.brightness == Brightness.dark;
    final Color border =
        dark ? const Color(0xFF262D38) : const Color(0xFFE3E8F0);

    return Container(
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF101318) : Colors.white,
        border: Border(top: BorderSide(color: border)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (widget.queue.isNotEmpty) _queueBar(cs, dark),
            if (widget.quote != null) _quoteBar(cs, dark),
            if (widget.attachments.isNotEmpty) _attachmentBar(cs, dark),
            if (_suggestions.isNotEmpty) _suggestionPanel(cs, dark),
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 8, 10, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  _plusButton(cs, dark),
                  Expanded(
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 44),
                      decoration: BoxDecoration(
                        color: dark
                            ? const Color(0xFF171B21)
                            : const Color(0xFFF4F6F9),
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(
                          color: _focus.hasFocus
                              ? cs.primary.withOpacity(0.55)
                              : Colors.transparent,
                          width: 1.2,
                        ),
                      ),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 2),
                      child: Focus(
                        onKey: (FocusNode node, RawKeyEvent event) {
                          if (event is! RawKeyDownEvent) {
                            return KeyEventResult.ignored;
                          }
                          final bool enter = event.logicalKey ==
                                  LogicalKeyboardKey.enter ||
                              event.logicalKey ==
                                  LogicalKeyboardKey.numpadEnter;
                          if (!enter) return KeyEventResult.ignored;
                          if (_suggestions.isNotEmpty && _desktopLike) {
                            _accept(_suggestions.first);
                            return KeyEventResult.handled;
                          }
                          final bool shift = HardwareKeyboard
                                  .instance.logicalKeysPressed
                                  .contains(LogicalKeyboardKey.shiftLeft) ||
                              HardwareKeyboard.instance.logicalKeysPressed
                                  .contains(LogicalKeyboardKey.shiftRight);
                          if (shift || !_desktopLike) {
                            return KeyEventResult.ignored;
                          }
                          _submit();
                          return KeyEventResult.handled;
                        },
                        child: TextField(
                          controller: widget.controller,
                          focusNode: _focus,
                          minLines: 1,
                          maxLines: 6,
                          keyboardType: TextInputType.multiline,
                          textInputAction: TextInputAction.newline,
                          style: TextStyle(
                            fontSize: 15,
                            height: 1.45,
                            color: cs.onSurface,
                          ),
                          decoration: InputDecoration(
                            hintText: widget.s.inputHint,
                            isDense: true,
                            filled: false,
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            contentPadding:
                                const EdgeInsets.symmetric(vertical: 11),
                            hintStyle: TextStyle(
                              color: cs.onSurface.withOpacity(0.38),
                              fontSize: 15,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _sendKey(cs, dark),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _plusButton(ColorScheme cs, bool dark) {
    return SizedBox(
      width: 38,
      height: 44,
      child: IconButton(
        padding: EdgeInsets.zero,
        icon: Icon(Icons.add_rounded,
            size: 21, color: cs.onSurface.withOpacity(0.62)),
        tooltip: widget.s.isEnglish ? 'More' : '更多',
        onPressed: _openTools,
      ),
    );
  }

  void _openTools() {
    showModalBottomSheet<void>(
      context: context,
      builder: (BuildContext ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.attach_file_rounded),
              title: Text(widget.s.isEnglish ? 'Attach a file' : '附加文件'),
              subtitle: Text(
                widget.s.isEnglish
                    ? 'Sent with your next message'
                    : '随下一条消息一起发给模型',
                style: const TextStyle(fontSize: 11.5),
              ),
              onTap: () {
                Navigator.pop(ctx);
                widget.onPickAttachment?.call();
              },
            ),
            ListTile(
              leading: const Icon(Icons.folder_open_rounded),
              title: Text(widget.s.isEnglish ? 'Workspace files' : '工作区文件'),
              subtitle: Text(
                widget.s.isEnglish
                    ? 'Browse, edit and reference files'
                    : '浏览、编辑，或插入 @ 引用',
                style: const TextStyle(fontSize: 11.5),
              ),
              onTap: () {
                Navigator.pop(ctx);
                widget.onOpenFiles?.call();
              },
            ),
            ListTile(
              leading: const Icon(Icons.terminal_rounded),
              title: Text(widget.s.isEnglish ? 'Terminal' : '终端'),
              subtitle: Text(
                widget.s.isEnglish
                    ? 'Run shell commands on the phone'
                    : '直接在手机上跑 shell 命令',
                style: const TextStyle(fontSize: 11.5),
              ),
              onTap: () {
                Navigator.pop(ctx);
                widget.onOpenTerminal?.call();
              },
            ),
            ListTile(
              leading: const Icon(Icons.extension_outlined),
              title: Text(widget.s.isEnglish ? 'Modules' : '扩展模块'),
              subtitle: Text(
                widget.s.isEnglish
                    ? 'Install extra CLI tools'
                    : '下载 tree / peek 等命令行小工具',
                style: const TextStyle(fontSize: 11.5),
              ),
              onTap: () {
                Navigator.pop(ctx);
                widget.onOpenModules?.call();
              },
            ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }

  Widget _suggestionPanel(ColorScheme cs, bool dark) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      constraints: const BoxConstraints(maxHeight: 196),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF14181F) : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: dark ? const Color(0xFF262D38) : const Color(0xFFE3E8F0),
        ),
      ),
      child: ListView.separated(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: _suggestions.length,
        separatorBuilder: (_, __) => Divider(
          height: 1,
          color: cs.onSurface.withOpacity(0.06),
        ),
        itemBuilder: (BuildContext ctx, int i) {
          final _Suggestion s = _suggestions[i];
          return InkWell(
            onTap: () => _accept(s),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Row(
                children: <Widget>[
                  Icon(s.icon, size: 16, color: cs.primary.withOpacity(0.8)),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      s.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontFamily: s.label.startsWith('/')
                            ? null
                            : 'monospace',
                        color: cs.onSurface.withOpacity(0.85),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    s.hint,
                    style: TextStyle(
                      fontSize: 10.5,
                      color: cs.onSurface.withOpacity(0.38),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _quoteBar(ColorScheme cs, bool dark) {
    final String preview = widget.quote!.trim().replaceAll('\n', ' ');
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 8, 14, 0),
      padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
      decoration: BoxDecoration(
        color: cs.primary.withOpacity(dark ? 0.10 : 0.06),
        borderRadius: BorderRadius.circular(9),
        border: Border(
          left: BorderSide(color: cs.primary.withOpacity(0.6), width: 3),
        ),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              preview.length > 80 ? '${preview.substring(0, 80)}…' : preview,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.4,
                color: cs.onSurface.withOpacity(0.62),
              ),
            ),
          ),
          InkWell(
            onTap: widget.onClearQuote,
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Icon(Icons.close_rounded,
                  size: 14, color: cs.onSurface.withOpacity(0.5)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _attachmentBar(ColorScheme cs, bool dark) {
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
        itemCount: widget.attachments.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (BuildContext ctx, int i) {
          final Attachment a = widget.attachments[i];
          return Container(
            padding: const EdgeInsets.fromLTRB(8, 2, 2, 2),
            decoration: BoxDecoration(
              color: cs.onSurface.withOpacity(0.05),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: cs.onSurface.withOpacity(0.08)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  a.isImage ? Icons.image_outlined : Icons.description_outlined,
                  size: 13,
                  color: cs.primary.withOpacity(0.85),
                ),
                const SizedBox(width: 5),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 150),
                  child: Text(
                    a.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: cs.onSurface.withOpacity(0.72),
                    ),
                  ),
                ),
                InkWell(
                  onTap: () => widget.onRemoveAttachment?.call(a),
                  borderRadius: BorderRadius.circular(14),
                  child: Padding(
                    padding: const EdgeInsets.all(5),
                    child: Icon(Icons.close_rounded,
                        size: 12, color: cs.onSurface.withOpacity(0.45)),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _queueBar(ColorScheme cs, bool dark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
      child: Row(
        children: <Widget>[
          Icon(Icons.schedule_send_outlined,
              size: 15, color: cs.primary.withOpacity(0.8)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '${widget.s.queued} · ${widget.queue.length}',
              style: TextStyle(
                fontSize: 12.5,
                color: cs.onSurface.withOpacity(0.62),
              ),
            ),
          ),
          _PillButton(
            label: widget.s.sendNow,
            onTap: widget.onSendNow,
            emphasized: true,
          ),
          const SizedBox(width: 6),
          _PillButton(
            label: widget.s.clearQueue,
            onTap: widget.onClearQueue,
            emphasized: false,
          ),
        ],
      ),
    );
  }

  Widget _sendKey(ColorScheme cs, bool dark) {
    final bool showStop = widget.streaming && !_hasText;
    final bool enabled = showStop || _hasText;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: enabled
            ? (showStop
                ? (dark ? const Color(0xFF2A3140) : const Color(0xFFEDF0F5))
                : cs.primary)
            : cs.onSurface.withOpacity(0.07),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: showStop ? widget.onStop : (_hasText ? _submit : null),
          child: Icon(
            showStop ? Icons.stop_rounded : Icons.arrow_upward_rounded,
            size: showStop ? 20 : 21,
            color: enabled
                ? (showStop ? cs.onSurface.withOpacity(0.75) : cs.onPrimary)
                : cs.onSurface.withOpacity(0.3),
          ),
        ),
      ),
    );
  }
}

class _PillButton extends StatelessWidget {
  const _PillButton({
    required this.label,
    required this.onTap,
    required this.emphasized,
  });

  final String label;
  final VoidCallback onTap;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: emphasized ? cs.primary.withOpacity(0.12) : null,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: emphasized
                ? cs.primary.withOpacity(0.35)
                : cs.onSurface.withOpacity(0.16),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: emphasized ? cs.primary : cs.onSurface.withOpacity(0.6),
          ),
        ),
      ),
    );
  }
}
