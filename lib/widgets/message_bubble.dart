import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../agent/tools.dart';
import '../l10n/strings.dart';
import '../models/attachment.dart';
import '../models/chat_message.dart';
import '../theme/tokens.dart';
import 'markdown_text.dart';
import 'tool_card.dart';

/// One message. User messages are right-aligned bubbles; assistant messages
/// are full-width cards without a bubble so code has room to breathe.
class MessageBubble extends StatelessWidget {
  const MessageBubble({
    Key? key,
    required this.message,
    required this.s,
    this.isLast = false,
    this.onRegenerate,
    this.onEdit,
    this.onDelete,
    this.onRetry,
    this.onQuote,
    this.resolvePath,
    this.tools = const <ToolCall>[],
  }) : super(key: key);

  final ChatMessage message;
  final S s;
  final bool isLast;
  final VoidCallback? onRegenerate;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final VoidCallback? onRetry;
  final VoidCallback? onQuote;

  /// Turns a workspace-relative attachment path into an absolute one.
  final String Function(String path)? resolvePath;

  /// Tool calls that belong to this turn; rendered between the answer and the
  /// action row so the transcript reads in chronological order.
  final List<ToolCall> tools;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final AppPalette p = AppPalette.of(context);
    final bool dark = theme.brightness == Brightness.dark;

    if (message.isUser) {
      // Light mode gets a plain white bubble on the grey backdrop: tinting the
      // accent into every user turn made the transcript look like a highlight
      // reel. Dark mode keeps a trace of accent because pure grey on near-black
      // has no edge.
      final Color fill = dark
          ? cs.primary.withValues(alpha: 0.16)
          : p.surface;
      final Color edge = dark
          ? cs.primary.withValues(alpha: 0.26)
          : p.line;
      return Padding(
        padding: const EdgeInsets.fromLTRB(44, 8, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            GestureDetector(
              onTap: () => _showActions(context),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                decoration: BoxDecoration(
                  color: fill,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(AppTokens.rLg),
                    topRight: Radius.circular(AppTokens.rLg),
                    bottomLeft: Radius.circular(AppTokens.rLg),
                    bottomRight: Radius.circular(AppTokens.rXs),
                  ),
                  border: Border.all(color: edge, width: 0.8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: <Widget>[
                    if (message.attachments.isNotEmpty)
                      _Attachments(
                        attachments: message.attachments,
                        resolvePath: resolvePath,
                        alignEnd: true,
                      ),
                    if (message.text.trim().isNotEmpty)
                      Text(
                        message.text,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontSize: 15,
                          height: 1.55,
                          color: p.text,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    final bool empty = message.text.trim().isEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              _Avatar(color: cs.primary),
              const SizedBox(width: 8),
              Text(
                'ZCode',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: p.textSecondary,
                  letterSpacing: 0.2,
                ),
              ),
              if (message.stopped) ...<Widget>[
                const SizedBox(width: 8),
                _Tag(label: s.stopped, color: p.textTertiary),
              ],
            ],
          ),
          const SizedBox(height: 6),
          if (message.thinking.trim().isNotEmpty)
            _ThinkingBlock(text: message.thinking, label: s.thinking),
          if (!empty)
            Padding(
              padding: const EdgeInsets.only(left: 2, top: 2),
              child: message.streaming
                  ? _StreamingText(text: message.text)
                  : MarkdownText(data: message.text),
            ),
          if (empty && message.streaming)
            Padding(
              padding: const EdgeInsets.only(left: 8, top: 6),
              child: _DotPulse(color: cs.primary),
            ),
          if (message.error != null)
            Container(
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: cs.error.withValues(alpha: dark ? 0.14 : 0.07),
                borderRadius: AppTokens.brSm,
                border: Border.all(color: cs.error.withValues(alpha: 0.28)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    message.error!,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.5,
                      color: dark ? const Color(0xFFF2B8B8) : cs.error,
                    ),
                  ),
                  if (onRetry != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: InkWell(
                        onTap: onRetry,
                        borderRadius: BorderRadius.circular(6),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 3),
                          child: Text(
                            s.regenerate,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: cs.error,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          for (final ToolCall t in tools) ToolCard(call: t),
          if (!message.streaming && message.tokenLabel.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 2, top: 7),
              child: Text(
                message.tokenLabel,
                style: TextStyle(
                  fontSize: 10.5,
                  letterSpacing: 0.2,
                  color: cs.onSurface.withValues(alpha: 0.3),
                ),
              ),
            ),
          if (!message.streaming && !empty) _actions(context, cs, dark),
        ],
      ),
    );
  }

  Widget _actions(BuildContext context, ColorScheme cs, bool dark) {
    final Color tint = cs.onSurface.withValues(alpha: 0.52);
    return Padding(
      padding: const EdgeInsets.only(left: 0, top: 6),
      child: Row(
        children: <Widget>[
          _MiniAction(
            icon: Icons.copy_rounded,
            label: s.copy,
            color: tint,
            onTap: () {
              Clipboard.setData(ClipboardData(text: message.text));
              ScaffoldMessenger.of(context)
                ..hideCurrentSnackBar()
                ..showSnackBar(SnackBar(
                  content: Text(s.copied),
                  duration: const Duration(milliseconds: 1200),
                ));
            },
          ),
          if (onQuote != null)
            _MiniAction(
              icon: Icons.format_quote_rounded,
              label: s.isEnglish ? 'Quote' : '引用',
              color: tint,
              onTap: onQuote!,
            ),
          if (isLast && onRegenerate != null)
            _MiniAction(
              icon: Icons.refresh_rounded,
              label: s.regenerate,
              color: tint,
              onTap: onRegenerate!,
            ),
          _MiniAction(
            icon: Icons.more_horiz_rounded,
            label: '',
            color: tint,
            onTap: () => _showActions(context),
          ),
        ],
      ),
    );
  }

  void _showActions(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      builder: (BuildContext ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.copy_rounded),
              title: Text(s.copy),
              onTap: () {
                Clipboard.setData(ClipboardData(text: message.text));
                Navigator.pop(ctx);
                ScaffoldMessenger.of(ctx)
                    .showSnackBar(SnackBar(content: Text(s.copied)));
              },
            ),
            if (onQuote != null)
              ListTile(
                leading: const Icon(Icons.format_quote_rounded),
                title: Text(s.isEnglish ? 'Quote in reply' : '引用回复'),
                onTap: () {
                  Navigator.pop(ctx);
                  onQuote!();
                },
              ),
            if (message.isUser && onEdit != null)
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: Text(s.editResend),
                onTap: () {
                  Navigator.pop(ctx);
                  onEdit!();
                },
              ),
            if (!message.isUser && onRegenerate != null)
              ListTile(
                leading: const Icon(Icons.refresh_rounded),
                title: Text(s.regenerate),
                onTap: () {
                  Navigator.pop(ctx);
                  onRegenerate!();
                },
              ),
            if (onDelete != null)
              ListTile(
                leading: const Icon(Icons.delete_outline_rounded),
                title: Text(s.delete),
                onTap: () {
                  Navigator.pop(ctx);
                  onDelete!();
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(6),
      ),
      alignment: Alignment.center,
      child: Icon(Icons.bolt_rounded, size: 13, color: Theme.of(context).colorScheme.onPrimary),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 10.5, color: color, height: 1.3),
      ),
    );
  }
}

/// Collapsed reasoning: one quiet row that expands in place.
class _ThinkingBlock extends StatefulWidget {
  const _ThinkingBlock({required this.text, required this.label});
  final String text;
  final String label;

  @override
  State<_ThinkingBlock> createState() => _ThinkingBlockState();
}

class _ThinkingBlockState extends State<_ThinkingBlock> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Color tint = cs.onSurface.withValues(alpha: 0.5);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          InkWell(
            onTap: () => setState(() => _open = !_open),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(Icons.auto_awesome_outlined, size: 15, color: tint),
                  const SizedBox(width: 6),
                  Text(
                    widget.label,
                    style: TextStyle(
                        fontSize: 12.5, color: tint, height: 1.4),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    _open
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 16,
                    color: tint,
                  ),
                ],
              ),
            ),
          ),
          if (_open)
            Container(
              margin: const EdgeInsets.only(top: 2, left: 4),
              padding: const EdgeInsets.only(left: 10),
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(color: cs.onSurface.withValues(alpha: 0.15)),
                ),
              ),
              child: Text(
                widget.text,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.6,
                  color: tint,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// During streaming we render plain text (cheap to rebuild 60x/s) with a
/// blinking caret; the markdown pass happens once the turn settles.
class _StreamingText extends StatelessWidget {
  const _StreamingText({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          text,
          style: theme.textTheme.bodyMedium
              ?.copyWith(fontSize: 15, height: 1.62),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: _Caret(color: theme.colorScheme.primary),
        ),
      ],
    );
  }
}

class _Caret extends StatefulWidget {
  const _Caret({required this.color});
  final Color color;

  @override
  State<_Caret> createState() => _CaretState();
}

class _CaretState extends State<_Caret>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _c,
      child: Container(
        width: 8,
        height: 15,
        decoration: BoxDecoration(
          color: widget.color,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

class _DotPulse extends StatefulWidget {
  const _DotPulse({required this.color});
  final Color color;

  @override
  State<_DotPulse> createState() => _DotPulseState();
}

class _DotPulseState extends State<_DotPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (BuildContext context, Widget? _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List<Widget>.generate(3, (int i) {
            final double phase = (_c.value + i * 0.18) % 1.0;
            final double scale = 0.6 + 0.4 * (1 - (phase - 0.5).abs() * 2);
            return Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Transform.scale(
                scale: scale,
                child: Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: widget.color.withValues(alpha: 0.35 + 0.5 * scale),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            );
          }),
        );
      },
    );
  }
}

class _MiniAction extends StatelessWidget {
  const _MiniAction({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 14.5, color: color),
            if (label.isNotEmpty) ...<Widget>[
              const SizedBox(width: 4),
              Text(label, style: TextStyle(fontSize: 12, color: color)),
            ],
          ],
        ),
      ),
    );
  }
}


/// Attachment strip shown inside user bubbles: image thumbnails plus compact
/// file chips, so a photo sent to the model is visible in the transcript.
class _Attachments extends StatelessWidget {
  const _Attachments({
    required this.attachments,
    required this.resolvePath,
    this.alignEnd = false,
  });

  final List<Attachment> attachments;
  final String Function(String path)? resolvePath;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        alignment: alignEnd ? WrapAlignment.end : WrapAlignment.start,
        children: <Widget>[
          for (final Attachment a in attachments)
            if (a.isImage && resolvePath != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.file(
                  File(resolvePath!(a.path)),
                  width: 132,
                  height: 96,
                  fit: BoxFit.cover,
                  errorBuilder: (BuildContext ctx, Object e, StackTrace? st) =>
                      _fileChip(cs, a),
                ),
              )
            else
              _fileChip(cs, a),
        ],
      ),
    );
  }

  Widget _fileChip(ColorScheme cs, Attachment a) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: cs.onSurface.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cs.onSurface.withValues(alpha: 0.09)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            a.isImage ? Icons.image_outlined : Icons.description_outlined,
            size: 13,
            color: cs.onSurface.withValues(alpha: 0.55),
          ),
          const SizedBox(width: 5),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 170),
            child: Text(
              a.sizeLabel.isEmpty ? a.name : '${a.name} · ${a.sizeLabel}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                color: cs.onSurface.withValues(alpha: 0.65),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
