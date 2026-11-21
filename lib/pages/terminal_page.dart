import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../platform/device_bridge.dart';
import '../services/workspace.dart';
import '../state/app_state.dart';
import '../widgets/glass_header.dart';

/// A real shell inside the app sandbox. Not a full pty, but enough to inspect
/// the workspace, chain commands and see exactly what the agent would see.
class TerminalPage extends StatefulWidget {
  const TerminalPage({Key? key, this.embedded = false}) : super(key: key);

  /// Hosted inside the root shell: no back arrow, and the shared
  /// liquid backdrop stays visible behind the page.
  final bool embedded;

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
  String _cwd = '';
  int _epoch = -1;

  /// `builtin` (sh + toybox), `termux` (node/python/git) or `priv`
  /// (root/Shizuku: `pm`, `svc`, `input`, `settings` all work).
  /// All three point at the same real folder.
  String _mode = 'builtin';

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
    final AppState state = context.read<AppState>();
    _input.clear();
    if (_history.isEmpty || _history.last != cmd) _history.add(cmd);
    _historyAt = -1;

    // `cd` has to be handled here: every command is its own process, so the
    // shell cannot keep a working directory between runs.
    if (cmd == 'cd' || cmd.startsWith('cd ') || cmd == 'cd ~') {
      _changeDir(cmd.length > 2 ? cmd.substring(2).trim() : '');
      return;
    }
    if (cmd == 'clear') {
      setState(() => _entries.clear());
      return;
    }

    final _Entry entry = _Entry(cmd);
    setState(() {
      _entries.add(entry);
      _busy = true;
    });
    _scrollDown();
    String out;
    if (_mode == 'termux') {
      out = await state.runTermux(cmd, cwd: _cwd);
    } else if (_mode == 'priv') {
      // The privileged channel has no cwd argument, so the directory rides
      // along as a leading `cd`.
      final String quoted = _cwd.replaceAll("'", "'\\''");
      out = await state.runPrivileged("cd '$quoted' 2>/dev/null; $cmd",
          timeout: 60);
    } else {
      out = await state.runShell(cmd, cwd: _cwd);
    }
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

  void _changeDir(String arg) {
    final String root = context.read<AppState>().workspacePath;
    String target;
    if (arg.isEmpty || arg == '~') {
      target = root;
    } else if (arg.startsWith('/')) {
      target = arg;
    } else {
      target = '$_cwd/$arg';
    }
    target = WorkspaceResolver.normalize(target);
    final bool isDir = FileSystemEntity.isDirectorySync(target);
    final _Entry entry = _Entry('cd ${arg.isEmpty ? '~' : arg}');
    setState(() {
      entry
        ..running = false
        ..output = isDir
            ? target
            : 'cd: no such directory: $target\n\n[exit 1]'
        ..exit = isDir ? 0 : 1;
      if (isDir) _cwd = target;
      _entries.add(entry);
    });
    _scrollDown();
  }

  /// Cycles builtin → Termux → privileged → builtin, warning when the next
  /// mode is not actually available instead of letting commands fail silently.
  Future<void> _cycleMode() async {
    final AppState state = context.read<AppState>();
    if (!DeviceBridge.isAndroid) {
      _toast('只有 Android 上有多种执行通道');
      return;
    }
    if (_mode == 'builtin') {
      final bool installed = await DeviceBridge.termuxInstalled();
      if (!installed) {
        _toast('没检测到 Termux。装上它并在里面 pkg install nodejs python git，'
            '就能在手机上跑真正的构建。');
        await _switchTo('priv');
        return;
      }
      if (!state.storageAccess) {
        _toast('建议先去「工作区」授予文件权限，否则 Termux 与 App 看不到同一批文件。');
      }
      setState(() => _mode = 'termux');
      return;
    }
    if (_mode == 'termux') {
      await _switchTo('priv');
      return;
    }
    setState(() => _mode = 'builtin');
  }

  Future<void> _switchTo(String mode) async {
    final AppState state = context.read<AppState>();
    if (mode == 'priv') {
      await state.refreshPrivilege();
      if (!state.privilege.privileged) {
        _toast('没有 root 或 Shizuku。装了 Shizuku 的话去「自动化」页授权，'
            'root 用户打开 su 授权即可。');
      }
    }
    if (mounted) setState(() => _mode = mode);
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(text),
        duration: const Duration(milliseconds: 2400),
      ));
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

    // Workspace switched underneath us: forget the old cwd.
    if (_epoch != state.workspaceEpoch || _cwd.isEmpty) {
      _epoch = state.workspaceEpoch;
      _cwd = state.workspacePath;
    }

    final List<String> quick = <String>[
      'pwd',
      'ls -la',
      'cd ..',
      'df -h .',
      'uname -a',
      'ps -A | head -20',
      'du -sh * 2>/dev/null',
    ];

    return Scaffold(
      backgroundColor: widget.embedded ? Colors.transparent : null,
      body: Column(
        children: <Widget>[
          GlassHeader(
            embedded: widget.embedded,
            leading: widget.embedded ? null : const BackButton(),
            title: en ? 'Terminal' : '终端',
            subtitle: Text(
              _cwd.isEmpty ? 'sandbox' : _cwd,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontFamily: 'monospace'),
            ),
            actions: <Widget>[
              HeaderAction(
                icon: _mode == 'termux'
                    ? Icons.bolt_rounded
                    : (_mode == 'priv'
                        ? Icons.shield_rounded
                        : Icons.memory_rounded),
                tint: _mode == 'builtin' ? null : cs.primary,
                tooltip: _mode == 'builtin'
                    ? (en ? 'Built-in sh · tap for Termux' : '内置 sh · 点一下切到 Termux')
                    : (_mode == 'termux'
                        ? (en
                            ? 'Termux · tap for root/Shizuku'
                            : 'Termux · 点一下切到 root/Shizuku')
                        : (en
                            ? 'Privileged shell · tap for built-in sh'
                            : '特权 shell · 点一下回到内置 sh')),
                onTap: _cycleMode,
              ),
              HeaderAction(
                icon: Icons.copy_all_rounded,
                tooltip: en ? 'Copy transcript' : '复制全部输出',
                onTap: _entries.isEmpty
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
              HeaderAction(
                icon: Icons.delete_sweep_outlined,
                tooltip: en ? 'Clear' : '清屏',
                onTap: _entries.isEmpty
                    ? null
                    : () => setState(() => _entries.clear()),
              ),
            ],
          ),
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
          if (_mode != 'builtin') _modeHint(cs, en),
          _quickBar(quick, cs, dark),
          SafeArea(
            top: false,
            child: Container(
              decoration: BoxDecoration(
                color: dark ? const Color(0xFF101318) : Colors.white,
                border: Border(
                  top: BorderSide(color: cs.onSurface.withValues(alpha: 0.08)),
                ),
              ),
              padding: const EdgeInsets.fromLTRB(6, 6, 8, 8),
              child: Row(
                children: <Widget>[
                  Icon(Icons.chevron_right_rounded,
                      size: 18, color: cs.primary.withValues(alpha: 0.7)),
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
                          color: cs.onSurface.withValues(alpha: 0.3),
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    padding: EdgeInsets.zero,
                    iconSize: 17,
                    tooltip: en ? 'Previous' : '上一条',
                    icon: Icon(Icons.keyboard_arrow_up_rounded,
                        color: cs.onSurface.withValues(alpha: 0.4)),
                    onPressed: () => _historyMove(-1),
                  ),
                  IconButton(
                    padding: EdgeInsets.zero,
                    iconSize: 17,
                    tooltip: en ? 'Next' : '下一条',
                    icon: Icon(Icons.keyboard_arrow_down_rounded,
                        color: cs.onSurface.withValues(alpha: 0.4)),
                    onPressed: () => _historyMove(1),
                  ),
                  SizedBox(
                    width: 38,
                    height: 38,
                    child: Material(
                      color: _busy
                          ? cs.onSurface.withValues(alpha: 0.08)
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
                              ? cs.onSurface.withValues(alpha: 0.35)
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
                size: 38, color: cs.onSurface.withValues(alpha: 0.2)),
            const SizedBox(height: 12),
            Text(
              en ? 'A shell on your phone' : '手机上的一只 shell',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: cs.onSurface.withValues(alpha: 0.65),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              en
                  ? 'Commands run in your real workspace folder with the same PATH '
                      'the agent uses. The icon up top cycles built-in sh → Termux '
                      '(node/python/git) → privileged shell (pm/svc/input).'
                  : '命令跑在你自己的文件夹里，PATH 与智能体一致；右上角图标在'
                      '内置 sh → Termux（node/python/git）→ 特权 shell（pm/svc/input）之间切换。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                height: 1.55,
                color: cs.onSurface.withValues(alpha: 0.4),
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
                  color: cs.primary.withValues(alpha: 0.9),
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
                    color: cs.onSurface.withValues(alpha: 0.88),
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
                    ? cs.error.withValues(alpha: 0.28)
                    : cs.onSurface.withValues(alpha: 0.06),
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
                          color: cs.onSurface.withValues(alpha: 0.4),
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

  Widget _modeHint(ColorScheme cs, bool en) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
      color: cs.primary.withValues(alpha: 0.07),
      child: Row(
        children: <Widget>[
          Icon(_mode == 'termux' ? Icons.bolt_rounded : Icons.shield_rounded,
              size: 13, color: cs.primary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _mode == 'termux'
                  ? (en
                      ? 'Termux mode · same files, full toolchain'
                      : 'Termux 模式 · 同一批文件，完整工具链')
                  : (en
                      ? 'Privileged shell · pm / svc / input / settings work here'
                      : '特权 shell · pm、svc、input、settings 在这里都能用'),
              style: TextStyle(
                fontSize: 10.5,
                color: cs.primary.withValues(alpha: 0.85),
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
                border: Border.all(color: cs.onSurface.withValues(alpha: 0.07)),
              ),
              child: Text(
                quick[i],
                style: TextStyle(
                  fontSize: 11,
                  fontFamily: 'monospace',
                  color: cs.onSurface.withValues(alpha: 0.55),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
