import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app_info.dart';
import '../l10n/strings.dart';
import '../models/app_config.dart';
import '../platform/device_bridge.dart';
import '../services/account.dart';
import '../services/workspace.dart';
import '../state/app_state.dart';
import 'files_page.dart';
import 'modules_page.dart';
import 'plugins_page.dart';
import 'terminal_page.dart';
import 'workspace_picker_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({Key? key}) : super(key: key);

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _key;
  late final TextEditingController _baseUrl;
  late final TextEditingController _model;
  late final TextEditingController _system;
  late final TextEditingController _maxTokens;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    final AppConfig c = context.read<AppState>().config ?? AppConfig.empty;
    _key = TextEditingController(text: c.apiKey);
    _baseUrl = TextEditingController(text: c.baseUrl);
    _model = TextEditingController(text: c.model);
    _system = TextEditingController(text: c.systemPrompt);
    _maxTokens = TextEditingController(text: '${c.maxTokens}');
    for (final TextEditingController ctrl in <TextEditingController>[
      _key,
      _baseUrl,
      _model,
      _system,
      _maxTokens,
    ]) {
      ctrl.addListener(_markDirty);
    }
  }

  void _markDirty() {
    if (!_dirty) setState(() => _dirty = true);
  }

  @override
  void dispose() {
    _key.dispose();
    _baseUrl.dispose();
    _model.dispose();
    _system.dispose();
    _maxTokens.dispose();
    super.dispose();
  }

  String _sessionLine(AppState state) {
    final AccountSession? session = state.session;
    if (session == null) return '未登录';
    final DateTime t = session.expiresAt.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    final String plan = session.planLabel ?? session.accountRegion.label;
    return '$plan · 凭据 ${two(t.hour)}:${two(t.minute)} 过期';
  }

  Future<void> _openAgents(AppState state, S s) async {
    final tools = state.tools;
    if (tools == null) return;
    final File file = File(tools.resolvePath('AGENTS.md'));
    if (!await file.exists()) {
      await file.writeAsString(AppState.agentsTemplate);
    }
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => FileEditorPage(
        path: file.path,
        relative: 'AGENTS.md',
      ),
    ));
    if (!mounted) return;
    state.refreshFileIndex();
    setState(() {});
  }

  Future<void> _confirmSignOut(AppState state) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        content: const Text('退出登录后需要重新授权才能继续使用。',
            style: TextStyle(fontSize: 14.5, height: 1.5)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (ok == true) await state.signOut();
  }

  Future<void> _save(AppState state) async {
    final AppConfig base = state.config ?? AppConfig.empty;
    final int maxTokens =
        int.tryParse(_maxTokens.text.trim()) ?? base.maxTokens;
    await state.saveConfig(base.copyWith(
      apiKey: _key.text.trim(),
      baseUrl: _baseUrl.text.trim(),
      model: _model.text.trim(),
      systemPrompt: _system.text,
      maxTokens: maxTokens.clamp(256, 65536),
    ));
    if (!mounted) return;
    setState(() => _dirty = false);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(S.of(state.config?.language).saved),
        duration: const Duration(milliseconds: 1400),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final AppState state = context.watch<AppState>();
    final AppConfig c = state.config ?? AppConfig.empty;
    final S s = S.of(c.language);
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(s.settings),
        actions: <Widget>[
          if (_dirty)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: TextButton(
                onPressed: () => _save(state),
                child: Text(
                  s.ok,
                  style: TextStyle(
                    color: cs.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 40),
        children: <Widget>[
          _section(s.account, cs),
          _card(<Widget>[
            _providerRow(c, state, s, cs),
            const _Gap(),
            _label(s.baseUrl, cs),
            TextField(
              controller: _baseUrl,
              style: const TextStyle(fontSize: 13.5),
              decoration: const InputDecoration(isDense: true),
            ),
            const _Gap(),
            _label(s.account, cs),
            Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
              decoration: BoxDecoration(
                color: cs.primary.withOpacity(0.06),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: <Widget>[
                  Icon(Icons.account_circle_outlined, size: 20, color: cs.primary),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          state.session?.displayName ??
                              (state.session?.region == 'zai'
                                  ? 'Z.ai account'
                                  : 'BigModel account'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _sessionLine(state),
                          style: TextStyle(
                            fontSize: 11,
                            color: cs.onSurface.withOpacity(0.45),
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () => _confirmSignOut(state),
                    child: Text(s.isEnglish ? 'Sign out' : '退出登录'),
                  ),
                ],
              ),
            ),
            const _Gap(),
            _label(s.model, cs),
            TextField(
              controller: _model,
              style: const TextStyle(fontSize: 13.5),
              decoration: const InputDecoration(isDense: true),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: <Widget>[
                  for (final String m in kGlmModels)
                    _chip(
                      label: m,
                      active: _model.text.trim() == m,
                      onTap: () {
                        _model.text = m;
                        setState(() {});
                      },
                      cs: cs,
                    ),
                ],
              ),
            ),
            const _Gap(),
            _label(s.systemPrompt, cs),
            TextField(
              controller: _system,
              minLines: 2,
              maxLines: 5,
              style: const TextStyle(fontSize: 13, height: 1.5),
              decoration: const InputDecoration(isDense: true),
            ),
            const _Gap(),
            _label(s.maxTokens, cs),
            TextField(
              controller: _maxTokens,
              keyboardType: TextInputType.number,
              inputFormatters: <TextInputFormatter>[
                FilteringTextInputFormatter.digitsOnly,
              ],
              style: const TextStyle(fontSize: 13.5),
              decoration: const InputDecoration(isDense: true),
            ),
          ]),
          const SizedBox(height: 18),
          _section(s.isEnglish ? 'Agent' : '智能体', cs),
          _card(<Widget>[
            _label(s.isEnglish ? 'Tool approval' : '工具审批', cs),
            const SizedBox(height: 6),
            _segmented(
              options: <String>[
                s.isEnglish ? 'Risky only' : '仅危险操作',
                s.isEnglish ? 'Ask all' : '每次询问',
                s.isEnglish ? 'Auto' : '自动执行',
              ],
              values: <String>['risky', 'ask', 'auto'],
              selected: c.approvalMode,
              cs: cs,
              onPick: (String v) => state.updatePrefs(approvalMode: v),
            ),
            const SizedBox(height: 6),
            Text(
              c.approvalMode == 'auto'
                  ? (s.isEnglish
                      ? 'The agent can run any tool without asking. Use it for trusted tasks.'
                      : '智能体可以不经确认执行任何工具，请只在信任的任务里使用。')
                  : c.approvalMode == 'ask'
                      ? (s.isEnglish
                          ? 'Every tool call waits for your tap.'
                          : '每一次工具调用都会等你确认。')
                      : (s.isEnglish
                          ? 'Only deletes, moves and destructive shell commands ask.'
                          : '只有删除、移动和破坏性 shell 命令会询问。'),
              style: TextStyle(
                fontSize: 11,
                height: 1.5,
                color: cs.onSurface.withOpacity(0.38),
              ),
            ),
            const _Gap(),
            Row(
              children: <Widget>[
                Expanded(
                  child: _label(
                    '${s.isEnglish ? 'Temperature' : '温度'}  '
                    '${c.temperature.toStringAsFixed(1)}',
                    cs,
                  ),
                ),
                Text(
                  c.temperature <= 0.35
                      ? (s.isEnglish ? 'precise' : '严谨')
                      : c.temperature >= 0.85
                          ? (s.isEnglish ? 'creative' : '发散')
                          : (s.isEnglish ? 'balanced' : '均衡'),
                  style: TextStyle(
                    fontSize: 10.5,
                    color: cs.onSurface.withOpacity(0.35),
                  ),
                ),
              ],
            ),
            Slider(
              value: c.temperature.clamp(0.0, 1.0),
              min: 0,
              max: 1,
              divisions: 20,
              onChanged: (double v) =>
                  state.updatePrefs(temperature: (v * 10).round() / 10),
            ),
            const _Gap(),
            _switchRow(
              icon: Icons.compress_rounded,
              label: s.isEnglish ? 'Auto-compact context' : '自动压缩上下文',
              hint: s.isEnglish
                  ? 'Fold older turns into a summary before the window fills up.'
                  : '上下文变长前，自动把早期对话折叠成摘要。',
              value: c.autoCompact,
              onChanged: (bool v) => state.updatePrefs(autoCompact: v),
              cs: cs,
            ),
          ]),
          const SizedBox(height: 18),
          _section(s.isEnglish ? 'Workspace' : '工作区', cs),
          _card(<Widget>[
            _navRow(
              icon: Icons.smartphone_rounded,
              label: s.isEnglish ? 'Workspace folder' : '工作区文件夹',
              hint: <String>[
                state.workspacePath.isEmpty
                    ? '—'
                    : WorkspaceResolver.label(state.workspacePath),
                if (DeviceBridge.isAndroid && !state.storageAccess)
                  (s.isEnglish ? 'file access not granted' : '未授予文件访问')
                else if (DeviceBridge.isAndroid &&
                    !WorkspaceResolver.isShared(state.workspacePath))
                  (s.isEnglish
                      ? 'still private — tap to move to Internal storage'
                      : '仍在私有目录，点一下换到内部存储'),
                if (state.termuxAvailable)
                  (s.isEnglish ? 'Termux ready' : 'Termux 可用'),
              ].join(' · '),
              onTap: () async {
                final bool? changed = await Navigator.of(context).push<bool>(
                  MaterialPageRoute<bool>(
                    builder: (_) =>
                        WorkspacePickerPage(initialPath: state.workspacePath),
                  ),
                );
                if (mounted && changed == true) setState(() {});
              },
              cs: cs,
            ),
            const Divider(height: 14),
            _navRow(
              icon: Icons.folder_open_rounded,
              label: s.isEnglish ? 'Files' : '文件管理',
              hint: s.isEnglish
                  ? 'Browse, edit and reference workspace files'
                  : '浏览、编辑文件，或插入 @ 引用',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const FilesPage()),
              ),
              cs: cs,
            ),
            const Divider(height: 14),
            _navRow(
              icon: Icons.terminal_rounded,
              label: s.isEnglish ? 'Terminal' : '终端',
              hint: s.isEnglish
                  ? 'Run shell commands with the agent\'s PATH'
                  : '用与智能体相同的 PATH 执行命令',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const TerminalPage()),
              ),
              cs: cs,
            ),
            const Divider(height: 14),
            _navRow(
              icon: Icons.extension_outlined,
              label: s.isEnglish ? 'Modules' : '扩展模块',
              hint: s.isEnglish
                  ? 'Install tree, peek and other CLI helpers'
                  : '安装 tree、peek 等命令行小工具',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const ModulesPage()),
              ),
              cs: cs,
            ),
            const Divider(height: 14),
            _navRow(
              icon: Icons.widgets_outlined,
              label: s.isEnglish ? 'Plugins' : '插件市场',
              hint: <String>[
                if (state.pluginCenter != null)
                  '${state.pluginCenter!.installed.length} ${s.isEnglish ? 'installed' : '个已安装'}',
                if (state.mcpToolCount > 0)
                  'MCP ${state.mcpToolCount} ${s.isEnglish ? 'tools' : '个工具'}',
                if (state.pluginCenter?.installed.isEmpty != false &&
                    state.mcpToolCount == 0)
                  (s.isEnglish
                      ? 'Skills, commands, sub-agents and MCP — tap to install'
                      : '技能、命令、子智能体与 MCP，点一下即可安装'),
              ].join(' · '),
              onTap: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const PluginsPage()),
                );
                if (mounted) setState(() {});
              },
              cs: cs,
            ),
            const Divider(height: 14),
            _navRow(
              icon: Icons.rule_rounded,
              label: s.isEnglish ? 'Project rules' : '项目规则 AGENTS.md',
              hint: state.tools != null &&
                      File(state.tools!.resolvePath('AGENTS.md')).existsSync()
                  ? (s.isEnglish
                      ? 'Loaded into every conversation'
                      : '已在每次对话中自动加载')
                  : (s.isEnglish
                      ? 'Create one to teach the agent this project'
                      : '创建后智能体会自动遵守这份说明'),
              onTap: () => _openAgents(state, s),
              cs: cs,
            ),
            const Divider(height: 14),
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    state.workspacePath.isEmpty ? '—' : state.workspacePath,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10.5,
                      fontFamily: 'monospace',
                      color: cs.onSurface.withOpacity(0.38),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  DeviceBridge.isAndroid
                      ? (state.storageAccess
                          ? (s.isEnglish ? 'real files' : '手机真实文件')
                          : (s.isEnglish ? 'private dir' : '私有目录'))
                      : (s.isEnglish ? 'sandbox' : '沙箱'),
                  style: TextStyle(
                    fontSize: 10,
                    color: cs.onSurface.withOpacity(0.3),
                  ),
                ),
              ],
            ),
          ]),
          const SizedBox(height: 18),
          _section(s.appearance, cs),
          _card(<Widget>[
            _label(s.theme, cs),
            const SizedBox(height: 6),
            _segmented(
              options: <String>[s.themeSystem, s.themeLight, s.themeDark],
              values: <String>['system', 'light', 'dark'],
              selected: c.themeMode,
              cs: cs,
              onPick: (String v) => state.updatePrefs(themeMode: v),
            ),
            const _Gap(),
            _label(s.accent, cs),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                for (final Accent a in Accent.all)
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: GestureDetector(
                      onTap: () => state.updatePrefs(accentId: a.id),
                      child: Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: Color(a.seed),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: c.accentId == a.id
                                ? cs.onSurface.withOpacity(0.75)
                                : Colors.transparent,
                            width: 2.2,
                          ),
                        ),
                        child: c.accentId == a.id
                            ? const Icon(Icons.check_rounded,
                                size: 17, color: Colors.white)
                            : null,
                      ),
                    ),
                  ),
              ],
            ),
            const _Gap(),
            _label('${s.fontSize}  ${_fontLabel(c.fontScale, s)}', cs),
            const SizedBox(height: 6),
            _segmented(
              options: <String>['A-', 'A', 'A+', 'A++'],
              values: <String>['0.9', '1.0', '1.1', '1.2'],
              selected: c.fontScale.toStringAsFixed(1),
              cs: cs,
              onPick: (String v) =>
                  state.updatePrefs(fontScale: double.parse(v)),
            ),
            const _Gap(),
            _label(s.language, cs),
            const SizedBox(height: 6),
            _segmented(
              options: <String>['简体中文', 'English'],
              values: <String>['zh', 'en'],
              selected: c.language,
              cs: cs,
              onPick: (String v) => state.updatePrefs(language: v),
            ),
          ]),
          const SizedBox(height: 18),
          _section(s.dataSection, cs),
          _card(<Widget>[
            _actionRow(
              icon: Icons.key_outlined,
              label: s.exportConfig,
              hint: s.exportHint,
              onTap: () => _showExport(state, c, s),
            ),
            const Divider(height: 18),
            _actionRow(
              icon: Icons.download_outlined,
              label: s.importConfig,
              hint: s.importHint,
              onTap: () => _showImport(state, s),
            ),
            const Divider(height: 18),
            _actionRow(
              icon: Icons.delete_forever_outlined,
              label: s.clearAll,
              hint: s.clearAllConfirm,
              danger: true,
              onTap: () => _confirmWipe(state, s),
            ),
          ]),
          const SizedBox(height: 18),
          _section(s.about, cs),
          _card(<Widget>[
            Row(
              children: <Widget>[
                Text(
                  '${s.appName} Mobile',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                  ),
                ),
                const Spacer(),
                Text(
                  'v$kAppVersion',
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurface.withOpacity(0.4),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              s.disclaimer,
              style: TextStyle(
                fontSize: 12,
                height: 1.55,
                color: cs.onSurface.withOpacity(0.45),
              ),
            ),
          ]),
          if (_dirty)
            Padding(
              padding: const EdgeInsets.only(top: 22),
              child: SizedBox(
                height: 46,
                child: ElevatedButton(
                  onPressed: () => _save(state),
                  style: ElevatedButton.styleFrom(
                    primary: cs.primary,
                    onPrimary: cs.onPrimary,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(13),
                    ),
                  ),
                  child: Text(
                    s.ok,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _fontLabel(double scale, S s) {
    if (scale <= 0.92) return 'S';
    if (scale <= 1.02) return 'M';
    if (scale <= 1.12) return 'L';
    return 'XL';
  }

  Widget _navRow({
    required IconData icon,
    required String label,
    required String hint,
    required VoidCallback onTap,
    required ColorScheme cs,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: <Widget>[
            Icon(icon, size: 18, color: cs.primary.withOpacity(0.8)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(label, style: const TextStyle(fontSize: 13.5)),
                  const SizedBox(height: 2),
                  Text(
                    hint,
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.45,
                      color: cs.onSurface.withOpacity(0.4),
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                size: 17, color: cs.onSurface.withOpacity(0.3)),
          ],
        ),
      ),
    );
  }

  Widget _switchRow({
    required IconData icon,
    required String label,
    required String hint,
    required bool value,
    required ValueChanged<bool> onChanged,
    required ColorScheme cs,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(icon, size: 18, color: cs.primary.withOpacity(0.8)),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(label, style: const TextStyle(fontSize: 13.5)),
              const SizedBox(height: 2),
              Text(
                hint,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.45,
                  color: cs.onSurface.withOpacity(0.4),
                ),
              ),
            ],
          ),
        ),
        Switch(
          value: value,
          onChanged: onChanged,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ],
    );
  }

  Widget _section(String title, ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 10, 4, 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3,
          color: cs.onSurface.withOpacity(0.42),
        ),
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

  Widget _label(String text, ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 5, left: 2),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          color: cs.onSurface.withOpacity(0.55),
        ),
      ),
    );
  }

  Widget _providerRow(AppConfig c, AppState state, S s, ColorScheme cs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _label(s.provider, cs),
        Row(
          children: <Widget>[
            _chip(
              label: 'BigModel 国内',
              active: c.provider == 'bigmodel',
              onTap: () {
                _baseUrl.text = Endpoints.bigmodel;
                state.saveConfig(c.copyWith(
                  provider: 'bigmodel',
                  baseUrl: Endpoints.bigmodel,
                ));
              },
              cs: cs,
            ),
            const SizedBox(width: 8),
            _chip(
              label: 'Z.ai 海外',
              active: c.provider == 'zai',
              onTap: () {
                _baseUrl.text = Endpoints.zai;
                state.saveConfig(c.copyWith(
                  provider: 'zai',
                  baseUrl: Endpoints.zai,
                ));
              },
              cs: cs,
            ),
          ],
        ),
      ],
    );
  }

  Widget _chip({
    required String label,
    required bool active,
    required VoidCallback onTap,
    required ColorScheme cs,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
        decoration: BoxDecoration(
          color: active ? cs.primary.withOpacity(0.12) : null,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: active
                ? cs.primary.withOpacity(0.4)
                : cs.onSurface.withOpacity(0.14),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: active ? FontWeight.w600 : FontWeight.w400,
            color:
                active ? cs.primary : cs.onSurface.withOpacity(0.65),
          ),
        ),
      ),
    );
  }

  Widget _segmented({
    required List<String> options,
    required List<String> values,
    required String selected,
    required ColorScheme cs,
    required ValueChanged<String> onPick,
  }) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: cs.onSurface.withOpacity(0.05),
        borderRadius: BorderRadius.circular(11),
      ),
      child: Row(
        children: <Widget>[
          for (int i = 0; i < options.length; i++)
            Expanded(
              child: GestureDetector(
                onTap: () => onPick(values[i]),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    color: selected == values[i]
                        ? (Theme.of(context).brightness == Brightness.dark
                            ? const Color(0xFF262D38)
                            : Colors.white)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(9),
                    boxShadow: selected == values[i]
                        ? <BoxShadow>[
                            BoxShadow(
                              color: Colors.black.withOpacity(0.06),
                              blurRadius: 4,
                              offset: const Offset(0, 1),
                            ),
                          ]
                        : null,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    options[i],
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: selected == values[i]
                          ? FontWeight.w600
                          : FontWeight.w400,
                      color: selected == values[i]
                          ? cs.onSurface
                          : cs.onSurface.withOpacity(0.55),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _actionRow({
    required IconData icon,
    required String label,
    required String hint,
    required VoidCallback onTap,
    bool danger = false,
  }) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Color color = danger ? cs.error : cs.onSurface;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(icon, size: 18, color: color.withOpacity(0.7)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 13.5,
                      color: danger ? cs.error : cs.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    hint,
                    style: TextStyle(
                      fontSize: 11.5,
                      height: 1.45,
                      color: cs.onSurface.withOpacity(0.4),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showExport(AppState state, AppConfig c, S s) {
    final String bundle = c.exportBundle();
    showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(s.exportConfig,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              s.exportHint,
              style: const TextStyle(fontSize: 12.5, height: 1.5),
            ),
            const SizedBox(height: 10),
            Container(
              constraints: const BoxConstraints(maxHeight: 150),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Theme.of(ctx).colorScheme.onSurface.withOpacity(0.05),
                borderRadius: BorderRadius.circular(10),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  bundle,
                  style: const TextStyle(
                      fontSize: 10.5, fontFamily: 'monospace', height: 1.4),
                ),
              ),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(s.cancel),
          ),
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: bundle));
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context)
                  .showSnackBar(SnackBar(content: Text(s.copied)));
            },
            child: Text(s.copy),
          ),
        ],
      ),
    );
  }

  void _showImport(AppState state, S s) {
    final TextEditingController ctrl = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(s.importConfig,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        content: TextField(
          controller: ctrl,
          minLines: 3,
          maxLines: 6,
          autofocus: true,
          style: const TextStyle(fontSize: 11.5, fontFamily: 'monospace'),
          decoration: InputDecoration(hintText: s.importHint),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(s.cancel),
          ),
          TextButton(
            onPressed: () async {
              final bool ok = state.importConfig(ctrl.text);
              Navigator.pop(ctx);
              if (ok) {
                final AppConfig? now = state.config;
                if (now != null) {
                  _key.text = now.apiKey;
                  _baseUrl.text = now.baseUrl;
                  _model.text = now.model;
                  _system.text = now.systemPrompt;
                  _maxTokens.text = '${now.maxTokens}';
                }
                setState(() => _dirty = false);
              }
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(ok ? s.importOk : s.importFail)),
              );
            },
            child: Text(s.ok),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmWipe(AppState state, S s) async {
    final bool? yes = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        content: Text(s.clearAllConfirm,
            style: const TextStyle(fontSize: 14.5, height: 1.5)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(s.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(s.delete, style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
          ),
        ],
      ),
    );
    if (yes != true) return;
    await state.clearAllData();
    if (mounted) Navigator.of(context).pop();
  }
}

class _Gap extends StatelessWidget {
  const _Gap();
  @override
  Widget build(BuildContext context) => const SizedBox(height: 12);
}
