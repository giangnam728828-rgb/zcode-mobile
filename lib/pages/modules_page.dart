import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../services/modules.dart';
import '../state/app_state.dart';

/// Optional CLI tools the agent can use. Everything installs into the app's
/// private workspace, so no root, no system changes, and one tap to remove.
class ModulesPage extends StatefulWidget {
  const ModulesPage({Key? key}) : super(key: key);

  @override
  State<ModulesPage> createState() => _ModulesPageState();
}

class _ModulesPageState extends State<ModulesPage> {
  final Map<String, double> _progress = <String, double>{};
  final TextEditingController _url = TextEditingController();
  final TextEditingController _name = TextEditingController();
  bool _remoteBusy = false;
  bool _probing = false;
  String _env = '';

  @override
  void dispose() {
    _url.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _install(ModuleSpec spec) async {
    final AppState state = context.read<AppState>();
    setState(() => _progress[spec.id] = 0.01);
    try {
      await state.installBuiltinModule(spec.id);
      _toast(S.of(state.config?.language).isEnglish
          ? '${spec.name} installed'
          : '${spec.name} 已安装');
    } catch (e) {
      _toast('$e');
    } finally {
      if (mounted) setState(() => _progress.remove(spec.id));
    }
  }

  Future<void> _installRemote() async {
    final AppState state = context.read<AppState>();
    final bool en = S.of(state.config?.language).isEnglish;
    final String url = _url.text.trim();
    if (url.isEmpty || _remoteBusy) return;
    setState(() => _remoteBusy = true);
    try {
      await state.installRemoteModule(url,
          name: _name.text.trim().isEmpty ? null : _name.text.trim());
      if (!mounted) return;
      _url.clear();
      _name.clear();
      FocusScope.of(context).unfocus();
      _toast(en ? 'Module installed' : '模块已安装');
    } catch (e) {
      _toast('$e');
    } finally {
      if (mounted) setState(() => _remoteBusy = false);
    }
  }

  Future<void> _probe() async {
    final AppState state = context.read<AppState>();
    final bool en = S.of(state.config?.language).isEnglish;
    setState(() => _probing = true);
    final String out = await state.runShell(
      'echo "\$PWD"; uname -a; '
      'for c in sh tar unzip curl git node python3; do '
      'if command -v \$c >/dev/null 2>&1; then echo "\$c: yes"; else echo "\$c: no"; fi; done; '
      'df -h . 2>/dev/null | tail -2',
    );
    if (!mounted) return;
    setState(() {
      _env = out;
      _probing = false;
    });
    if (!en) {
      // The output is intentionally raw — it is the point of the probe.
    }
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(text),
        duration: const Duration(milliseconds: 1800),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final AppState state = context.watch<AppState>();
    final bool en = S.of(state.config?.language).isEnglish;
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final ModuleCenter? mc = state.moduleCenter;
    final List<InstalledModule> installed = mc?.installed ?? <InstalledModule>[];
    final Set<String> ids = installed.map((InstalledModule m) => m.id).toSet();

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(en ? 'Modules' : '扩展模块'),
            Text(
              en
                  ? 'Extra CLI tools for the agent'
                  : '给智能体补上手机缺的命令行工具',
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w400,
                color: cs.onSurface.withValues(alpha: 0.42),
              ),
            ),
          ],
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 40),
        children: <Widget>[
          _card(<Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.memory_rounded, size: 18, color: cs.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    en ? 'Runtime' : '运行环境',
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                ),
                TextButton(
                  onPressed: _probing ? null : _probe,
                  child: Text(
                    _probing
                        ? (en ? 'Checking…' : '检测中…')
                        : (en ? 'Check' : '检测'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              en
                  ? 'Android ships sh + toybox. Node, Python and git are not included — install a module or bring your own static build.'
                  : 'Android 自带 sh + toybox，但不含 Node / Python / git。可以安装模块，或把自己的静态二进制放进工作区。',
              style: TextStyle(
                fontSize: 12,
                height: 1.55,
                color: cs.onSurface.withValues(alpha: 0.5),
              ),
            ),
            if (_env.isNotEmpty) ...<Widget>[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 210),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F1319),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    _env,
                    style: const TextStyle(
                      fontSize: 10.5,
                      height: 1.45,
                      fontFamily: 'monospace',
                      color: Color(0xFFD6DDE6),
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                Icon(Icons.folder_outlined,
                    size: 13, color: cs.onSurface.withValues(alpha: 0.4)),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    state.workspacePath,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10.5,
                      fontFamily: 'monospace',
                      color: cs.onSurface.withValues(alpha: 0.38),
                    ),
                  ),
                ),
                Text(
                  '${installed.length} ${en ? 'installed' : '已安装'}',
                  style: TextStyle(
                    fontSize: 10.5,
                    color: cs.onSurface.withValues(alpha: 0.38),
                  ),
                ),
              ],
            ),
          ]),
          _section(en ? 'Built-in' : '内置模块', cs),
          for (final ModuleSpec spec in ModuleCenter.catalog)
            _moduleCard(
              spec: spec,
              installed: ids.contains(spec.id),
              progress: _progress[spec.id],
              cs: cs,
              en: en,
              onInstall: () => _install(spec),
              onRemove: () => state.removeModule(spec.id),
            ),
          if (installed.isNotEmpty) ...<Widget>[
            _section(en ? 'Installed' : '已安装', cs),
            for (final InstalledModule m in installed)
              if (!ModuleCenter.catalog
                  .any((ModuleSpec s) => s.id == m.id))
                _installedCard(m, cs, en, state),
          ],
          _section(en ? 'Install from URL' : '从链接安装', cs),
          _card(<Widget>[
            TextField(
              controller: _url,
              style: const TextStyle(fontSize: 12.5, fontFamily: 'monospace'),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'https://example.com/tools.tar.gz',
                hintStyle: TextStyle(
                  fontSize: 12,
                  color: cs.onSurface.withValues(alpha: 0.3),
                ),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _name,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                isDense: true,
                hintText: en ? 'Display name (optional)' : '显示名称（可选）',
                hintStyle: TextStyle(
                  fontSize: 12,
                  color: cs.onSurface.withValues(alpha: 0.3),
                ),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 42,
              child: ElevatedButton(
                onPressed: _remoteBusy ? null : _installRemote,
                style: ElevatedButton.styleFrom(
                  backgroundColor: cs.primary,
                  foregroundColor: cs.onPrimary,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(11),
                  ),
                ),
                child: _remoteBusy
                    ? SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor:
                              AlwaysStoppedAnimation<Color>(cs.onPrimary),
                        ),
                      )
                    : Text(
                        en ? 'Download & install' : '下载并安装',
                        style: const TextStyle(
                            fontSize: 13.5, fontWeight: FontWeight.w600),
                      ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              en
                  ? 'tar.gz / tgz / zip. The archive must contain a bin/ folder; every file inside becomes a command on PATH.'
                  : '支持 tar.gz / tgz / zip，压缩包里需要有 bin/ 目录，里面的文件会直接注册为 PATH 上的命令。',
              style: TextStyle(
                fontSize: 11,
                height: 1.5,
                color: cs.onSurface.withValues(alpha: 0.38),
              ),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _section(String title, ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3,
          color: cs.onSurface.withValues(alpha: 0.42),
        ),
      ),
    );
  }

  Widget _moduleCard({
    required ModuleSpec spec,
    required bool installed,
    required double? progress,
    required ColorScheme cs,
    required bool en,
    required VoidCallback onInstall,
    required VoidCallback onRemove,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: Theme.of(context).cardTheme.color,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: Theme.of(context).dividerTheme.color ?? Colors.transparent,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(8),
                ),
                alignment: Alignment.center,
                child: Icon(Icons.terminal_rounded,
                    size: 15, color: cs.primary),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      spec.name,
                      style: const TextStyle(
                          fontSize: 13.5, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Wrap(
                      spacing: 5,
                      children: <Widget>[
                        for (final String c in spec.commands)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                              color: cs.onSurface.withValues(alpha: 0.05),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              c,
                              style: TextStyle(
                                fontSize: 9.5,
                                fontFamily: 'monospace',
                                color: cs.onSurface.withValues(alpha: 0.5),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              installed
                  ? TextButton(
                      onPressed: onRemove,
                      child: Text(en ? 'Remove' : '移除',
                          style: TextStyle(
                              fontSize: 12,
                              color: cs.onSurface.withValues(alpha: 0.45))),
                    )
                  : TextButton(
                      onPressed: progress == null ? onInstall : null,
                      child: Text(
                        progress == null
                            ? (en ? 'Install' : '安装')
                            : '${(progress * 100).round()}%',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: cs.primary,
                        ),
                      ),
                    ),
            ],
          ),
          const SizedBox(height: 7),
          Text(
            spec.description,
            style: TextStyle(
              fontSize: 11.5,
              height: 1.55,
              color: cs.onSurface.withValues(alpha: 0.45),
            ),
          ),
          if (progress != null) ...<Widget>[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: progress > 0 ? progress : null,
                minHeight: 2.5,
                backgroundColor: cs.onSurface.withValues(alpha: 0.07),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _installedCard(
      InstalledModule m, ColorScheme cs, bool en, AppState state) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: Theme.of(context).cardTheme.color,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: Theme.of(context).dividerTheme.color ?? Colors.transparent,
        ),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.extension_rounded, size: 17, color: cs.primary),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  m.name,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  m.commands.isEmpty
                      ? m.dir
                      : m.commands.join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontFamily: 'monospace',
                    color: cs.onSurface.withValues(alpha: 0.4),
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () => state.removeModule(m.id),
            child: Text(en ? 'Remove' : '移除',
                style: TextStyle(
                    fontSize: 12, color: cs.onSurface.withValues(alpha: 0.45))),
          ),
        ],
      ),
    );
  }

  Widget _card(List<Widget> children) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).cardTheme.color,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Theme.of(context).dividerTheme.color ?? Colors.transparent,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}
