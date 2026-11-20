import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;

/// Markdown renderer tuned for phone reading: no heavy syntax colouring,
/// but real code cards with a language chip and a copy button.
class MarkdownText extends StatelessWidget {
  const MarkdownText({
    Key? key,
    required this.data,
    this.small = false,
  }) : super(key: key);

  final String data;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final bool dark = theme.brightness == Brightness.dark;
    final double base = small ? 13 : 15;

    return MarkdownBody(
      data: data,
      selectable: true,
      softLineBreak: false,
      onTapLink: (String text, String? href, String title) {
        if (href == null) return;
        Clipboard.setData(ClipboardData(text: href));
      },
      styleSheet: MarkdownStyleSheet(
        p: theme.textTheme.bodyMedium?.copyWith(fontSize: base, height: 1.62),
        h1: theme.textTheme.titleLarge?.copyWith(
          fontSize: base + 7,
          fontWeight: FontWeight.w700,
          height: 1.4,
        ),
        h2: theme.textTheme.titleMedium?.copyWith(
          fontSize: base + 4,
          fontWeight: FontWeight.w700,
          height: 1.4,
        ),
        h3: theme.textTheme.titleMedium?.copyWith(
          fontSize: base + 1.5,
          fontWeight: FontWeight.w600,
        ),
        listBullet: theme.textTheme.bodyMedium
            ?.copyWith(fontSize: base, height: 1.6),
        blockquoteDecoration: BoxDecoration(
          color: cs.primary.withOpacity(dark ? 0.10 : 0.05),
          borderRadius: BorderRadius.circular(4),
          border: Border(
            left: BorderSide(color: cs.primary.withOpacity(0.55), width: 3),
          ),
        ),
        blockquotePadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        blockquote: theme.textTheme.bodyMedium?.copyWith(
          fontSize: base - 0.5,
          height: 1.6,
          color: cs.onSurface.withOpacity(0.78),
        ),
        code: TextStyle(
          fontFamily: 'monospace',
          fontSize: base - 1.5,
          backgroundColor: cs.primary.withOpacity(dark ? 0.16 : 0.08),
          color: cs.onSurface,
        ),
        codeblockPadding: EdgeInsets.zero,
        codeblockDecoration: const BoxDecoration(color: Colors.transparent),
        horizontalRuleDecoration: BoxDecoration(
          border: Border(
            top: BorderSide(
              color: cs.onSurface.withOpacity(0.12),
              width: 1,
            ),
          ),
        ),
        tableBorder: TableBorder.all(
          color: cs.onSurface.withOpacity(0.14),
          width: 0.8,
        ),
        tableCellsPadding:
            const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        tableHead: theme.textTheme.bodySmall
            ?.copyWith(fontSize: base - 2, fontWeight: FontWeight.w700),
        tableBody: theme.textTheme.bodySmall?.copyWith(fontSize: base - 2),
        a: TextStyle(
          color: cs.primary,
          decoration: TextDecoration.underline,
          decorationColor: cs.primary.withOpacity(0.4),
        ),
      ),
      builders: <String, MarkdownElementBuilder>{
        'code': _CodeCardBuilder(dark: dark),
      },
    );
  }
}

/// Renders ``` fenced blocks as a card with a language chip and copy button.
/// flutter_markdown only calls custom builders for inline tags, so `code` is
/// the hook: block-level code is detected by its language class or newlines.
class _CodeCardBuilder extends MarkdownElementBuilder {
  _CodeCardBuilder({required this.dark});
  final bool dark;

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final String cls = (element.attributes['class'] ?? '').trim();
    String text = element.textContent;
    final bool block = cls.startsWith('language-') ||
        cls == 'fenced-code' ||
        text.contains('\n');
    if (!block) return null;
    if (text.endsWith('\n')) {
      text = text.substring(0, text.length - 1);
    }
    final String lang =
        cls.startsWith('language-') ? cls.substring(9) : '';
    return _CodeCard(code: text, language: lang, dark: dark);
  }
}

class _CodeCard extends StatelessWidget {
  const _CodeCard({
    required this.code,
    required this.language,
    required this.dark,
  });

  final String code;
  final String language;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Color bg = dark ? const Color(0xFF0A0C10) : const Color(0xFFF3F5F9);
    final Color border = dark ? const Color(0xFF232A35) : const Color(0xFFE2E7EF);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.only(left: 12, right: 4),
            height: 36,
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: border)),
            ),
            child: Row(
              children: <Widget>[
                Icon(Icons.terminal_rounded,
                    size: 14, color: cs.onSurface.withOpacity(0.5)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    language.isEmpty ? 'code' : language,
                    style: TextStyle(
                      fontSize: 11.5,
                      letterSpacing: 0.3,
                      color: cs.onSurface.withOpacity(0.55),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Copy',
                  visualDensity: VisualDensity.compact,
                  iconSize: 16,
                  padding: const EdgeInsets.all(8),
                  constraints: const BoxConstraints(),
                  icon: Icon(Icons.copy_rounded,
                      size: 15, color: cs.onSurface.withOpacity(0.6)),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: code));
                    ScaffoldMessenger.of(context)
                      ..hideCurrentSnackBar()
                      ..showSnackBar(
                        const SnackBar(
                          content: Text('Copied'),
                          duration: Duration(milliseconds: 1200),
                        ),
                      );
                  },
                ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: Text(
              code,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12.4,
                height: 1.55,
                color: dark
                    ? const Color(0xFFD7E0EC)
                    : const Color(0xFF243043),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
