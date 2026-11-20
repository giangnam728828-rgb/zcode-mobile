import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../state/app_state.dart';

/// A real shell inside the app sandbox. Not a full pty, but enough to inspect
/// the workspace, chain commands and see exactly what the agent would see.
class TerminalPage extends StatefulWidget {
  const TerminalPage({Key? key}) : super(key: key);

  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

class _Entry {
  _Entry(this.command);
  final String command;
  String output = '';
  bool running = true;
  int? exit;
}

class _TerminalPageState extends State<TerminalPage> {
  final List<_Entry> _entries = <_Entry>[];
  final List<String> _history = <String>[];
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final FocusNode _focus = FocusNode();
  int _historyAt = -1;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _run([String? preset]) async {
    final String cmd = (preset ?? _input.text).trim();
    if (cmd.isEmpty || _busy) return;
    _input.clear();
    if (_history.isEmpty || _history.last != cmd) _history.add(cmd);
    _historyAt = -1;
    final _Entry entry = _Entry(cmd);
    setState(() {
      _entries.add(entry);
      _busy = true;
    });
    _scrollDown();
    final String out = await context.read<AppState>().runShell(cmd);
    if (!mounted) return;
    setState(() {
      entry
        ..output = out
        ..running = false
        ..exit = _exitOf(out);
      _busy = false;
    });
    _scrollDown();
    _focus.requestFocus();
  }

  static int? _exitOf(String out) {
    final RegExpMatch? m = RegExp(r'\[exit (-?\d+)\]').firstMatch(out);
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  void _historyMove(int delta) {
    if (_history.isEmpty) return;
    setState(() {
      if (_historyAt < 0) {
        _historyAt = _history.length - 1;
      } else {
        _historyAt = (_historyAt + delta).clamp(0, _history.length - 1);
      }
      _input.text = _history[_historyAt];
      _input.selection =
          TextSelection.collapsed(offset: _input.text.length);
    });
  }

  @override
  Widget build(BuildContext context) {
    final AppState state = context.watch<AppState>();
    final S s = S.of(state.config?.language);
    final bool en = s.isEnglish;
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final bool dark = theme.brightness == Brightness.dark;

    final List<String> quick = <String>[
      'pwd',
      'ls -la',
      'df -h .',
      'uname -a',
      'ps -A | head -20',
      en ? 'du -sh * 2>/dev/null' : 'du -sh * 2>/dev/null',
    ];

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(en ? 'Terminal' : '终端'),
            Text(
              state.workspacePath.isEmpty ? 'sandbox' : state.workspacePath,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w400,
                color: cs.onSurface.withOpacity(0.4),
              ),
            ),
          ],
        ),
        actions: <Widget>[
          IconButton(
            tooltip: en ? 'Copy transcript' : '复制全部输出',
            icon: const Icon(Icons.copy_all_rounded, size: 19),
            onPressed: _entries.isEmpty
                ? null
                : () {
                    final String text = _entries
                        .map((_Entry e) => '\$ ${e.command}\n${e.output}\n')
                        .join('\n');
                    Clipboard.setData(ClipboardData(text: text));
                    ScaffoldMessenger.of(context)
                      ..hideCurrentSnackBar()
                      ..showSnackBar(SnackBar(
                        content: Text(s.copied),
                        duration: const Duration(milliseconds: 1100),
                      ));
                  },
          ),
          IconButton(
            tooltip: en ? 'Clear' : '清屏',
            icon: const Icon(Icons.delete_sweep_outlined, size: 20),
            onPressed: _entries.isEmpty
                ? null
                : () => setState(() => _entries.clear()),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Expanded(
            child: _entries.isEmpty
                ? _welcome(cs, en)
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
                    itemCount: _entries.length,
                    itemBuilder: (BuildContext ctx, int i) =>
                        _entryView(_entries[i], cs, dark),
                  ),
          ),
          _quickBar(quick, cs, dark),
          SafeArea(
            top: false,
            child: Container(
              decoration: BoxDecoration(
                color: dark ? const Color(0xFF101318) : Colors.white,
                border: Border(
                  top: BorderSide(color: cs.onSurface.withOpacity(0.08)),
                ),
              ),
              padding: const EdgeInsets.fromLTRB(6, 6, 8, 8),
              child: Row(
                children: <Widget>[
                  Icon(Icons.chevron_right_rounded,
                      size: 18, color: cs.primary.withOpacity(0.7)),
                  Expanded(
                    child: TextField(
                      controller: _input,
                      focusNode: _focus,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontFamily: 'monospace',
                      ),
                      autocorrect: false,
                      enableSuggestions: false,
                      textInputAction: TextInputAction.go,
                      onSubmitted: (_) => _run(),
                      decoration: InputDecoration(
                        hintText: en ? 'command' : '输入命令',
                        isDense: true,
                        filled: false,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 2, vertical: 10),
                        hintStyle: TextStyle(
                          fontSize: 13,
                          fontFamily: 'monospace',
                          color: cs.onSurface.withOpacity(0.3),
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    padding: EdgeInsets.zero,
                    iconSize: 17,
                    tooltip: en ? 'Previous' : '上一条',
                    icon: Icon(Icons.keyboard_arrow_up_rounded,
                        color: cs.onSurface.withOpacity(0.4)),
                    onPressed: () => _historyMove(-1),
                  ),
                  IconButton(
                    padding: EdgeInsets.zero,
                    iconSize: 17,
                    tooltip: en ? 'Next' : '下一条',
                    icon: Icon(Icons.keyboard_arrow_down_rounded,
                        color: cs.onSurface.withOpacity(0.4)),
                    onPressed: () => _historyMove(1),
                  ),
                  SizedBox(
                    width: 38,
                    height: 38,
                    child: Material(
                      color: _busy
                          ? cs.onSurface.withOpacity(0.08)
                          : cs.primary,
                      borderRadius: BorderRadius.circular(19),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: _busy ? null : () => _run(),
                        child: Icon(
                          _busy
                              ? Icons.hourglass_top_rounded
                              : Icons.arrow_upward_rounded,
                          size: 18,
                          color: _busy
                              ? cs.onSurface.withOpacity(0.35)
                              : cs.onPrimary,
                        ),
                      ),
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

  Widget _welcome(ColorScheme cs, bool en) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.terminal_rounded,
                size: 38, color: cs.onSurface.withOpacity(0.2)),
            const SizedBox(height: 12),
            Text(
              en ? 'A shell on your phone' : '手机上的一只 shell',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: cs.onSurface.withOpacity(0.65),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              en
                  ? 'Commands run in the app workspace with the same PATH the agent uses.'
                  : '命令跑在应用私有工作区里，PATH 与智能体完全一致。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                height: 1.55,
                color: cs.onSurface.withOpacity(0.4),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _entryView(_Entry e, ColorScheme cs, bool dark) {
    final bool failed = e.exit != null && e.exit != 0;
    final String body = e.output.trim();
    final String cleaned = body.replaceFirst(RegExp(r'\s*\[exit -?\d+\]\s*$'), '');
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '\$ ',
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.5,
                  fontFamily: 'monospace',
                  color: cs.primary.withOpacity(0.9),
                ),
              ),
              Expanded(
                child: SelectableText(
                  e.command,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.5,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface.withOpacity(0.88),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              color: dark ? const Color(0xFF0F1319) : const Color(0xFFF2F4F8),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: failed
                    ? cs.error.withOpacity(0.28)
                    : cs.onSurface.withOpacity(0.06),
              ),
            ),
            child: e.running
                ? Row(
                    children: <Widget>[
                      SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.6,
                          valueColor:
                              AlwaysStoppedAnimation<Color>(cs.primary),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'running…',
                        style: TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                          color: cs.onSurface.withOpacity(0.4),
                        ),
                      ),
                    ],
                  )
                : SelectableText(
                    cleaned.isEmpty ? '(no output)' : cleaned,
                    style: TextStyle(
                      fontSize: 11.5,
                      height: 1.45,
                      fontFamily: 'monospace',
                      color: failed
                          ? cs.error
                          : (dark
                              ? const Color(0xFFD6DDE6)
                              : const Color(0xFF2B3340)),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _quickBar(List<String> quick, ColorScheme cs, bool dark) {
    return SizedBox(
      height: 36,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: quick.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (BuildContext ctx, int i) {
          return InkWell(
            onTap: _busy ? null : () => _run(quick[i]),
            borderRadius: BorderRadius.circular(16),
            child: Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              margin: const EdgeInsets.symmetric(vertical: 4),
              decoration: BoxDecoration(
                color: dark
                    ? const Color(0xFF171B21)
                    : const Color(0xFFF2F4F8),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: cs.onSurface.withOpacity(0.07)),
              ),
              child: Text(
                quick[i],
                style: TextStyle(
                  fontSize: 11,
                  fontFamily: 'monospace',
                  color: cs.onSurface.withOpacity(0.55),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
