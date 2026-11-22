import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../agent/commands.dart';
import '../l10n/strings.dart';
import '../models/attachment.dart';
import '../theme/tokens.dart';

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
    this.embedded = false,
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

  /// Hosted by the root shell: the bar sits on the shared backdrop instead of
  /// painting an opaque strip, and leaves the bottom inset to the shell.
  final bool embedded;

  @override
  State<Composer> createState() => _ComposerState();
}

/// A file mention that survives a path with spaces: `@"My Project/a.dart"`.
///
/// The bare `@path` form stops at the first space because the parser used to
/// treat whitespace as the terminator. Quoting keeps the path in one piece;
/// the parser accepts both forms so text typed by hand still works.
String mentionFor(String path) =>
    path.contains(' ') ? '@"$path" ' : '@$path ';

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

  /// The attachment that stopped a send because it is past the wire limit.
  Attachment? _blocked;

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
    if (!listEquals(old.attachments, widget.attachments)) {
      _blocked = null;
    }
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
              insert: mentionFor(p),
            ),
        ];
      }
    }

    // Compare the whole list, not just its length and first row. Narrowing
    // `/file` to `/form` can leave both lists the same size with the same head,
    // and the panel would keep showing candidates that no longer match.
    final String sig = _signature(next);
    if (sig != _signature(_suggestions)) {
      setState(() => _suggestions = next);
    }
  }

  static String _signature(List<_Suggestion> list) => list
      .map((_Suggestion s) => '${s.label}\u0000${s.insert}\u0000${s.hint}')
      .join('\n');

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
    // Block rather than send-without-it: the request drops oversized files, so
    // letting this through would produce a message that looks sent but never
    // carried the attachment.
    for (final Attachment a in widget.attachments) {
      if (a.exceedsLimit) {
        HapticFeedback.heavyImpact();
        setState(() => _blocked = a);
        return;
      }
    }
    widget.controller.clear();
    setState(() {
      _suggestions = const <_Suggestion>[];
      _blocked = null;
    });
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

    final Widget body = Container(
      decoration: widget.embedded
          ? null
          : BoxDecoration(
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
            if (_blocked != null) _blockedBar(cs),
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
                              ? cs.primary.withValues(alpha: 0.55)
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
                              color: cs.onSurface.withValues(alpha: 0.38),
                              fontSize: 15,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Stop and send are separate controls on purpose. They used
                  // to share one key, so the moment you started typing the
                  // next message the stop button turned into a send button and
                  // the only way to cancel was to clear the box first.
                  if (widget.streaming && !_hasText)
                    _stopKey(cs, dark)
                  else if (widget.streaming) ...<Widget>[
                    _stopKey(cs, dark),
                    const SizedBox(width: 6),
                    _sendKey(cs, dark),
                  ] else
                    _sendKey(cs, dark),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    if (!widget.embedded) return body;
    final AppPalette p = AppPalette.of(context);
    // No backdrop filter here on purpose: nothing scrolls *under* this bar, so
    // a blur pass would cost a frame and change nothing. A near-opaque fill
    // still picks up the backdrop's light pool, which is the visible part.
    return DecoratedBox(
      decoration: BoxDecoration(
        color: p.isDark
            ? Colors.white.withValues(alpha: 0.035)
            : Colors.white.withValues(alpha: 0.72),
        border: Border(top: BorderSide(color: p.line, width: 0.8)),
      ),
      child: body,
    );
  }

  Widget _plusButton(ColorScheme cs, bool dark) {
    return SizedBox(
      width: 38,
      height: 44,
      child: IconButton(
        padding: EdgeInsets.zero,
        icon: Icon(Icons.add_rounded,
            size: 21, color: cs.onSurface.withValues(alpha: 0.62)),
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
          color: cs.onSurface.withValues(alpha: 0.06),
        ),
        itemBuilder: (BuildContext ctx, int i) {
          final _Suggestion s = _suggestions[i];
          return InkWell(
            onTap: () => _accept(s),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Row(
                children: <Widget>[
                  Icon(s.icon, size: 16, color: cs.primary.withValues(alpha: 0.8)),
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
                        color: cs.onSurface.withValues(alpha: 0.85),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    s.hint,
                    style: TextStyle(
                      fontSize: 10.5,
                      color: cs.onSurface.withValues(alpha: 0.38),
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
        color: cs.primary.withValues(alpha: dark ? 0.10 : 0.06),
        borderRadius: BorderRadius.circular(9),
        border: Border(
          left: BorderSide(color: cs.primary.withValues(alpha: 0.6), width: 3),
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
                color: cs.onSurface.withValues(alpha: 0.62),
              ),
            ),
          ),
          InkWell(
            onTap: widget.onClearQuote,
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Icon(Icons.close_rounded,
                  size: 14, color: cs.onSurface.withValues(alpha: 0.5)),
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
          final bool over = a.exceedsLimit;
          return Container(
            padding: const EdgeInsets.fromLTRB(8, 2, 2, 2),
            decoration: BoxDecoration(
              color: over
                  ? cs.error.withValues(alpha: 0.08)
                  : cs.onSurface.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: over
                    ? cs.error.withValues(alpha: 0.45)
                    : cs.onSurface.withValues(alpha: 0.08),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  over
                      ? Icons.error_outline_rounded
                      : (a.isImage
                          ? Icons.image_outlined
                          : Icons.description_outlined),
                  size: 13,
                  color: over ? cs.error : cs.primary.withValues(alpha: 0.85),
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
                      color: over
                          ? cs.error
                          : cs.onSurface.withValues(alpha: 0.72),
                    ),
                  ),
                ),
                if (over) ...<Widget>[
                  const SizedBox(width: 4),
                  Text(
                    a.sizeLabel,
                    style: TextStyle(fontSize: 10, color: cs.error),
                  ),
                ],
                InkWell(
                  onTap: () => widget.onRemoveAttachment?.call(a),
                  borderRadius: BorderRadius.circular(14),
                  child: Padding(
                    padding: const EdgeInsets.all(5),
                    child: Icon(Icons.close_rounded,
                        size: 12, color: cs.onSurface.withValues(alpha: 0.45)),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// Shown when a send was stopped by an oversized attachment, so the reason
  /// is attached to the thing that caused it rather than a transient snackbar.
  Widget _blockedBar(ColorScheme cs) {
    final Attachment a = _blocked!;
    final String limit = a.isImage ? '3 MB' : '512 KB';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.error_outline_rounded, size: 14, color: cs.error),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              widget.s.isEnglish
                  ? '${a.name} is ${a.sizeLabel} — over the $limit limit. '
                      'Remove it to send.'
                  : '${a.name} 有 ${a.sizeLabel}，超过 $limit 上限，移除后再发。',
              style: TextStyle(
                fontSize: 11.5,
                height: 1.4,
                color: cs.error,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _queueBar(ColorScheme cs, bool dark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
      child: Row(
        children: <Widget>[
          Icon(Icons.schedule_send_outlined,
              size: 15, color: cs.primary.withValues(alpha: 0.8)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '${widget.s.queued} · ${widget.queue.length}',
              style: TextStyle(
                fontSize: 12.5,
                color: cs.onSurface.withValues(alpha: 0.62),
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

  /// Cancel the live turn. Kept apart from send so it stays reachable while
  /// the user is already typing the next message.
  Widget _stopKey(ColorScheme cs, bool dark) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: cs.onSurface.withValues(alpha: 0.18)),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () {
            HapticFeedback.selectionClick();
            widget.onStop();
          },
          child: Icon(
            Icons.stop_rounded,
            size: 18,
            color: cs.onSurface.withValues(alpha: 0.72),
          ),
        ),
      ),
    );
  }

  Widget _sendKey(ColorScheme cs, bool dark) {
    final bool enabled = _hasText;
    // While a turn runs, sending means "queue", not "go now" — the queue icon
    // says that without needing a tooltip.
    final IconData icon = widget.streaming
        ? Icons.schedule_send_rounded
        : Icons.arrow_upward_rounded;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: enabled ? cs.primary : cs.onSurface.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: enabled ? _submit : null,
          child: Icon(
            icon,
            size: 21,
            color: enabled
                ? cs.onPrimary
                : cs.onSurface.withValues(alpha: 0.3),
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
          color: emphasized ? cs.primary.withValues(alpha: 0.12) : null,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: emphasized
                ? cs.primary.withValues(alpha: 0.35)
                : cs.onSurface.withValues(alpha: 0.16),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: emphasized ? cs.primary : cs.onSurface.withValues(alpha: 0.6),
          ),
        ),
      ),
    );
  }
}
