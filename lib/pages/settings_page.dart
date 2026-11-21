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
import '../theme/glass.dart';
import '../theme/tokens.dart';
import '../widgets/glass_header.dart';
import 'automation_page.dart';
import 'files_page.dart';
import 'modules_page.dart';
import 'plugins_page.dart';
import 'terminal_page.dart';
import 'workspace_picker_page.dart';

/// Settings is a stack of labelled groups, not one long form.
///
/// Order is by frequency of change, not by importance: automation and the
/// account are read every few days, so they sit at the top; the appearance
/// switches are touched once and then forgotten, so they sink. Everything
/// that opens another screen is a row with a chevron; everything that is a
/// value you own is a row with the value visible.
class SettingsPage extends StatefulWidget {
  const SettingsPage({Key? key, this.embedded = false}) : super(key: key);

  /// Hosted inside the root shell: no back arrow, and the shared
  /// liquid backdrop stays visible behind the page.
  final bool embedded;

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
  bool _keyVisible = false;

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
    final bool en = s.isEnglish;
    final AppPalette p = AppPalette.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: widget.embedded ? Colors.transparent : null,
      body: Column(
        children: <Widget>[
          GlassHeader(
            embedded: widget.embedded,
            leading: widget.embedded ? null : const BackButton(),
            title: s.settings,
            subtitle: Text(
              state.session == null
                  ? (en ? 'local configuration' : '本地配置')
                  : _sessionLine(state),
            ),
            actions: <Widget>[
              if (_dirty)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: TextButton(
                    onPressed: () => _save(state),
                    style: TextButton.styleFrom(
                      foregroundColor: cs.primary,
                      minimumSize: const Size(56, 40),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: AppTokens.brSm,
                      ),
                    ),
                    child: Text(
                      s.ok,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
            ],
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 36),
              children: <Widget>[
                _autoEntry(state, cs, s),
                _accountGroup(state, s, cs),
                _Group(
                  title: en ? 'Model service' : '模型服务',
                  note: en
                      ? 'The endpoint and key are used for every new turn.'
                      : '接口地址与密钥用于每一轮新请求。',
                  children: <Widget>[
                    _FieldTile(
                      label: s.provider,
                      child: _Seg(
                        options: <String>['BigModel 国内', 'Z.ai 海外'],
                        values: const <String>['bigmodel', 'zai'],
                        selected: c.provider,
                        onPick: (String v) {
                          final String url = v == 'zai'
                              ? Endpoints.zai
                              : Endpoints.bigmodel;
                          _baseUrl.text = url;
                          state.saveConfig(
                            c.copyWith(provider: v, baseUrl: url),
                          );
                          setState(() {});
                        },
                      ),
                    ),
                    _FieldTile(
                      label: s.baseUrl,
                      child: _input(_baseUrl, hint: 'https://…'),
                    ),
                    _FieldTile(
                      label: s.model,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          _input(_model, hint: 'glm-4.6'),
                          const SizedBox(height: 9),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: <Widget>[
                              for (final String m in kGlmModels)
                                _Chip(
                                  label: m,
                                  active: _model.text.trim() == m,
                                  onTap: () {
                                    _model.text = m;
                                    setState(() {});
                                  },
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    _FieldTile(
                      label: 'API Key',
                      child: TextField(
                        controller: _key,
                        obscureText: !_keyVisible,
                        autocorrect: false,
                        enableSuggestions: false,
                        style: const TextStyle(
                          fontSize: 13,
                          fontFamily: 'monospace',
                        ),
                        decoration: InputDecoration(
                          isDense: true,
                          filled: false,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          contentPadding: EdgeInsets.zero,
                          hintText: en
                              ? 'filled in automatically after sign-in'
                              : '登录后自动填写',
                          suffixIcon: IconButton(
                            icon: Icon(
                              _keyVisible
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined,
                              size: 18,
                              color: p.textTertiary,
                            ),
                            onPressed: () =>
                                setState(() => _keyVisible = !_keyVisible),
                          ),
                          suffixIconConstraints: const BoxConstraints(
                            minWidth: 34,
                            minHeight: 34,
                          ),
                        ),
                      ),
                    ),
                    _FieldTile(
                      label: s.systemPrompt,
                      child: TextField(
                        controller: _system,
                        minLines: 2,
                        maxLines: 5,
                        style: const TextStyle(fontSize: 13, height: 1.5),
                        decoration: const InputDecoration(
                          isDense: true,
                          filled: false,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          contentPadding: EdgeInsets.zero,
                          hintText: 'You are a coding agent…',
                        ),
                      ),
                    ),
                    _FieldTile(
                      label: s.maxTokens,
                      child: _input(
                        _maxTokens,
                        hint: '8192',
                        keyboardType: TextInputType.number,
                        formatters: <TextInputFormatter>[
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                      ),
                    ),
                  ],
                ),
                _Group(
                  title: en ? 'Agent' : '智能体',
                  children: <Widget>[
                    _FieldTile(
                      label: en ? 'Tool approval' : '工具审批',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          _Seg(
                            options: <String>[
                              en ? 'Risky only' : '仅危险操作',
                              en ? 'Ask all' : '每次询问',
                              en ? 'Auto' : '自动执行',
                            ],
                            values: const <String>['risky', 'ask', 'auto'],
                            selected: c.approvalMode,
                            onPick: (String v) =>
                                state.updatePrefs(approvalMode: v),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            c.approvalMode == 'auto'
                                ? (en
                                    ? 'The agent can run any tool without asking. '
                                        'Use it for trusted tasks.'
                                    : '智能体可以不经确认执行任何工具，请只在信任的任务里使用。')
                                : c.approvalMode == 'ask'
                                    ? (en
                                        ? 'Every tool call waits for your tap.'
                                        : '每一次工具调用都会等你确认。')
                                    : (en
                                        ? 'Only deletes, moves and destructive shell '
                                            'commands ask.'
                                        : '只有删除、移动和破坏性 shell 命令会询问。'),
                            style: TextStyle(
                              fontSize: 11,
                              height: 1.5,
                              color: p.textTertiary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    _Tile(
                      label: en ? 'Temperature' : '温度',
                      sub: c.temperature <= 0.35
                          ? (en ? 'precise' : '严谨')
                          : c.temperature >= 0.85
                              ? (en ? 'creative' : '发散')
                              : (en ? 'balanced' : '均衡'),
                      trailing: Text(
                        c.temperature.toStringAsFixed(1),
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: p.textSecondary,
                          fontFeatures: const <FontFeature>[
                            FontFeature.tabularFigures(),
                          ],
                        ),
                      ),
                      bottom: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 3,
                          overlayShape:
                              const RoundSliderOverlayShape(overlayRadius: 16),
                          thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 8),
                        ),
                        child: Slider(
                          value: c.temperature.clamp(0.0, 1.0),
                          min: 0,
                          max: 1,
                          divisions: 20,
                          onChanged: (double v) => state.updatePrefs(
                              temperature: (v * 10).round() / 10),
                        ),
                      ),
                    ),
                    _Tile(
                      icon: Icons.compress_rounded,
                      label: en ? 'Auto-compact context' : '自动压缩上下文',
                      sub: en
                          ? 'Fold older turns into a summary before the window fills up.'
                          : '上下文变长前，自动把早期对话折叠成摘要。',
                      trailing: _MiniSwitch(
                        value: c.autoCompact,
                        onChanged: (bool v) =>
                            state.updatePrefs(autoCompact: v),
                      ),
                    ),
                    _Tile(
                      icon: Icons.rule_rounded,
                      label: en ? 'Project rules' : '项目规则 AGENTS.md',
                      sub: state.tools != null &&
                              File(state.tools!.resolvePath('AGENTS.md'))
                                  .existsSync()
                          ? (en
                              ? 'Loaded into every conversation'
                              : '已在每次对话中自动加载')
                          : (en
                              ? 'Create one to teach the agent this project'
                              : '创建后智能体会自动遵守这份说明'),
                      onTap: () => _openAgents(state, s),
                    ),
                  ],
                ),
                _Group(
                  title: en ? 'Workspace' : '工作区',
                  note: <String>[
                    DeviceBridge.isAndroid
                        ? (state.storageAccess
                            ? (en
                                ? 'Files are read from Internal storage.'
                                : '文件读写走手机内部存储。')
                            : (en
                                ? 'Only the app\'s private folder is visible.'
                                : '目前只能访问应用私有目录。'))
                        : (en ? 'Sandboxed workspace.' : '沙箱工作区。'),
                  ].join(),
                  children: <Widget>[
                    _Tile(
                      icon: Icons.smartphone_rounded,
                      label: en ? 'Workspace folder' : '工作区文件夹',
                      sub: <String>[
                        state.workspacePath.isEmpty
                            ? '—'
                            : WorkspaceResolver.label(state.workspacePath),
                        if (DeviceBridge.isAndroid && !state.storageAccess)
                          (en ? 'file access not granted' : '未授予文件访问')
                        else if (DeviceBridge.isAndroid &&
                            !WorkspaceResolver.isShared(state.workspacePath))
                          (en
                              ? 'still private — tap to move to Internal storage'
                              : '仍在私有目录，点一下换到内部存储'),
                        if (state.termuxAvailable)
                          (en ? 'Termux ready' : 'Termux 可用'),
                      ].join(' · '),
                      onTap: () async {
                        final bool? changed =
                            await Navigator.of(context).push<bool>(
                          MaterialPageRoute<bool>(
                            builder: (_) => WorkspacePickerPage(
                                initialPath: state.workspacePath),
                          ),
                        );
                        if (mounted && changed == true) setState(() {});
                      },
                    ),
                    _Tile(
                      icon: Icons.folder_open_rounded,
                      label: en ? 'Files' : '文件管理',
                      sub: en
                          ? 'Browse, edit and reference workspace files'
                          : '浏览、编辑文件，或插入 @ 引用',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                            builder: (_) => const FilesPage()),
                      ),
                    ),
                    _Tile(
                      icon: Icons.terminal_rounded,
                      label: en ? 'Terminal' : '终端',
                      sub: en
                          ? 'Run shell commands with the agent\'s PATH'
                          : '用与智能体相同的 PATH 执行命令',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                            builder: (_) => const TerminalPage()),
                      ),
                    ),
                    _Tile(
                      icon: Icons.extension_outlined,
                      label: en ? 'Modules' : '扩展模块',
                      sub: en
                          ? 'Install tree, peek and other CLI helpers'
                          : '安装 tree、peek 等命令行小工具',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                            builder: (_) => const ModulesPage()),
                      ),
                    ),
                    _Tile(
                      icon: Icons.widgets_outlined,
                      label: en ? 'Plugins' : '插件市场',
                      sub: <String>[
                        if (state.pluginCenter != null)
                          '${state.pluginCenter!.installed.length} ${en ? 'installed' : '个已安装'}',
                        if (state.mcpToolCount > 0)
                          'MCP ${state.mcpToolCount} ${en ? 'tools' : '个工具'}',
                        if (state.pluginCenter?.installed.isEmpty != false &&
                            state.mcpToolCount == 0)
                          (en
                              ? 'Skills, commands, sub-agents and MCP'
                              : '技能、命令、子智能体与 MCP'),
                      ].join(' · '),
                      onTap: () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute<void>(
                              builder: (_) => const PluginsPage()),
                        );
                        if (mounted) setState(() {});
                      },
                    ),
                  ],
                ),
                _Group(
                  title: s.appearance,
                  children: <Widget>[
                    _FieldTile(
                      label: s.theme,
                      child: _Seg(
                        options: <String>[
                          s.themeSystem,
                          s.themeLight,
                          s.themeDark,
                        ],
                        values: const <String>['system', 'light', 'dark'],
                        selected: c.themeMode,
                        onPick: (String v) =>
                            state.updatePrefs(themeMode: v),
                      ),
                    ),
                    _Tile(
                      label: s.accent,
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          for (final Accent a in Accent.all)
                            GestureDetector(
                              onTap: () => state.updatePrefs(accentId: a.id),
                              behavior: HitTestBehavior.opaque,
                              child: Padding(
                                padding: const EdgeInsets.only(left: 8),
                                child: Container(
                                  width: 24,
                                  height: 24,
                                  decoration: BoxDecoration(
                                    color: Color(a.seed),
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: c.accentId == a.id
                                          ? p.text
                                          : Colors.transparent,
                                      width: 1.8,
                                    ),
                                  ),
                                  child: c.accentId == a.id
                                      ? const Icon(Icons.check_rounded,
                                          size: 13, color: Colors.white)
                                      : null,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    _FieldTile(
                      label: '${s.fontSize}  ${_fontLabel(c.fontScale, s)}',
                      child: _Seg(
                        options: const <String>['A-', 'A', 'A+', 'A++'],
                        values: const <String>['0.9', '1.0', '1.1', '1.2'],
                        selected: c.fontScale.toStringAsFixed(1),
                        onPick: (String v) =>
                            state.updatePrefs(fontScale: double.parse(v)),
                      ),
                    ),
                    _FieldTile(
                      label: s.language,
                      child: _Seg(
                        options: const <String>['简体中文', 'English'],
                        values: const <String>['zh', 'en'],
                        selected: c.language,
                        onPick: (String v) =>
                            state.updatePrefs(language: v),
                      ),
                    ),
                    _FieldTile(
                      label: en ? 'Glass' : '玻璃质感',
                      note: en
                          ? 'Liquid adds one 1.06x refraction pass on the header '
                              'and dock. Drop to Soft or Off if scrolling stutters.'
                          : '「强折射」只在顶栏和 Dock 上加一次 1.06 倍折射；'
                              '如果滑动掉帧，降到「标准」或「关闭」。',
                      child: _Seg(
                        options: <String>[
                          en ? 'Off' : '关闭',
                          en ? 'Soft' : '标准',
                          en ? 'Liquid' : '强折射',
                        ],
                        values: const <String>['flat', 'soft', 'full'],
                        selected: c.glassQuality,
                        onPick: (String v) =>
                            state.updatePrefs(glassQuality: v),
                      ),
                    ),
                  ],
                ),
                _Group(
                  title: s.dataSection,
                  children: <Widget>[
                    _Tile(
                      icon: Icons.key_outlined,
                      label: s.exportConfig,
                      sub: s.exportHint,
                      onTap: () => _showExport(state, c, s),
                    ),
                    _Tile(
                      icon: Icons.download_outlined,
                      label: s.importConfig,
                      sub: s.importHint,
                      onTap: () => _showImport(state, s),
                    ),
                    _Tile(
                      icon: Icons.delete_forever_outlined,
                      label: s.clearAll,
                      sub: s.clearAllConfirm,
                      danger: true,
                      onTap: () => _confirmWipe(state, s),
                    ),
                  ],
                ),
                _Group(
                  title: s.about,
                  children: <Widget>[
                    _Tile(
                      label: '${s.appName} Mobile',
                      sub: s.disclaimer,
                      alignTop: true,
                      trailing: Text(
                        'v$kAppVersion',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: p.textTertiary,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
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

  Widget _accountGroup(AppState state, S s, ColorScheme cs) {
    final bool en = s.isEnglish;
    final AppPalette p = AppPalette.of(context);
    final AccountSession? session = state.session;
    return _Group(
      title: s.isEnglish ? 'Account' : '账号',
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
          child: Row(
            children: <Widget>[
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.12),
                  borderRadius: AppTokens.brSm,
                ),
                child: Icon(Icons.account_circle_outlined,
                    size: 19, color: cs.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      session?.displayName ??
                          (session?.region == 'zai'
                              ? 'Z.ai account'
                              : 'BigModel account'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: p.text,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _sessionLine(state),
                      style: TextStyle(fontSize: 11.5, color: p.textTertiary),
                    ),
                  ],
                ),
              ),
              if (session != null)
                TextButton(
                  onPressed: () => _confirmSignOut(state),
                  style: TextButton.styleFrom(
                    foregroundColor: p.textSecondary,
                    minimumSize: const Size(48, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                  child: Text(
                    en ? 'Sign out' : '退出登录',
                    style: const TextStyle(fontSize: 12.5),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// Automation used to be its own dock tab. It lives here now, at the very
  /// top, because it is the one group you come back to every few days — and
  /// burying it under the account form would make it effectively invisible.
  Widget _autoEntry(AppState state, ColorScheme cs, S s) {
    final bool en = s.isEnglish;
    final int rules = state.automation?.enabledRules.length ?? 0;
    final int today = state.automation?.todayRuns ?? 0;
    final AppPalette p = AppPalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 0),
      child: SolidCard(
        radius: AppTokens.rLg,
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
        onTap: () async {
          await Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const AutomationPage()),
          );
          if (mounted) setState(() {});
        },
        child: Row(
          children: <Widget>[
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: cs.primary.withValues(alpha: 0.12),
                borderRadius: AppTokens.brSm,
              ),
              child: Icon(Icons.auto_awesome_rounded,
                  size: 18, color: cs.primary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    en ? 'Automation' : '自动化',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: p.text,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    <String>[
                      '$rules ${en ? 'rules' : '条规则'}',
                      '${en ? 'today' : '今天'} $today',
                      state.privilege.label,
                    ].join(' · '),
                    style: TextStyle(fontSize: 11.5, color: p.textTertiary),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, size: 18, color: p.textTertiary),
          ],
        ),
      ),
    );
  }

  /// Borderless input used inside a group row. The row already provides the
  /// visual container, so a bordered field inside a bordered card reads as a
  /// box in a box.
  Widget _input(
    TextEditingController controller, {
    String? hint,
    TextInputType? keyboardType,
    List<TextInputFormatter>? formatters,
  }) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      inputFormatters: formatters,
      style: const TextStyle(fontSize: 13.5),
      decoration: InputDecoration(
        isDense: true,
        filled: false,
        hintText: hint,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        contentPadding: EdgeInsets.zero,
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
                color: Theme.of(ctx)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.05),
                borderRadius: AppTokens.brSm,
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
            child: Text(s.delete,
                style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
          ),
        ],
      ),
    );
    if (yes != true) return;
    await state.clearAllData();
    if (mounted) Navigator.of(context).pop();
  }
}

/// A labelled block of rows on one card, separated by hairlines.
class _Group extends StatelessWidget {
  const _Group({this.title, this.note, required this.children});

  final String? title;
  final String? note;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = AppPalette.of(context);
    final List<Widget> rows = <Widget>[];
    for (int i = 0; i < children.length; i++) {
      if (i > 0) {
        rows.add(Divider(
          height: 0.8,
          thickness: 0.8,
          indent: 14,
          endIndent: 14,
          color: p.line,
        ));
      }
      rows.add(children[i]);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (title != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 22, 2, 8),
            child: Text(
              title!,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.4,
                color: p.textTertiary,
              ),
            ),
          )
        else
          const SizedBox(height: 10),
        SolidCard(
          radius: AppTokens.rLg,
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: rows,
          ),
        ),
        if (note != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
            child: Text(
              note!,
              style: TextStyle(
                fontSize: 11,
                height: 1.5,
                color: p.textTertiary.withValues(alpha: 0.9),
              ),
            ),
          ),
      ],
    );
  }
}

/// Navigation / toggle row. 48dp minimum, chevron only when it leads somewhere.
class _Tile extends StatelessWidget {
  const _Tile({
    required this.label,
    this.sub,
    this.icon,
    this.trailing,
    this.bottom,
    this.onTap,
    this.danger = false,
    this.alignTop = false,
  });

  final String label;
  final String? sub;
  final IconData? icon;
  final Widget? trailing;
  final Widget? bottom;
  final VoidCallback? onTap;
  final bool danger;

  /// Keeps a trailing value on the first line instead of centring it against a
  /// multi-line subtitle (the version number next to the disclaimer).
  final bool alignTop;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = AppPalette.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Color tint = danger ? cs.error : p.textSecondary;

    final Widget row = ConstrainedBox(
      constraints: BoxConstraints(minHeight: onTap == null ? 0 : AppTokens.tapTarget),
      child: Padding(
        padding: EdgeInsets.fromLTRB(14, bottom == null ? 11 : 12, 8, 11),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              crossAxisAlignment:
                  alignTop ? CrossAxisAlignment.start : CrossAxisAlignment.center,
              children: <Widget>[
                if (icon != null) ...<Widget>[
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: (danger ? cs.error : cs.primary)
                          .withValues(alpha: 0.10),
                      borderRadius: AppTokens.brXs,
                    ),
                    child: Icon(
                      icon,
                      size: 15,
                      color: danger
                          ? cs.error
                          : cs.primary.withValues(alpha: 0.95),
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.3,
                          color: danger ? cs.error : p.text,
                        ),
                      ),
                      if (sub != null && sub!.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 2),
                        Text(
                          sub!,
                          style: TextStyle(
                            fontSize: 11.5,
                            height: 1.45,
                            color: p.textTertiary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (trailing != null) ...<Widget>[
                  const SizedBox(width: 10),
                  if (alignTop)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: trailing!,
                    )
                  else
                    trailing!,
                ],
                if (onTap != null) ...<Widget>[
                  const SizedBox(width: 2),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 17,
                    color: p.textTertiary.withValues(alpha: 0.8),
                  ),
                ],
              ],
            ),
            if (bottom != null) bottom!,
          ],
        ),
      ),
    );

    if (onTap == null) return row;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: AppTokens.brMd,
        splashColor: tint.withValues(alpha: 0.06),
        highlightColor: tint.withValues(alpha: 0.04),
        child: row,
      ),
    );
  }
}

/// Label + control, stacked. Used for segmented switches and text inputs.
class _FieldTile extends StatelessWidget {
  const _FieldTile({required this.label, required this.child, this.note});

  final String label;
  final Widget child;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = AppPalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 11, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            label,
            style: TextStyle(fontSize: 11.5, color: p.textTertiary),
          ),
          const SizedBox(height: 7),
          child,
          if (note != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              note!,
              style: TextStyle(
                fontSize: 10.5,
                height: 1.5,
                color: p.textTertiary.withValues(alpha: 0.85),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Seg extends StatelessWidget {
  const _Seg({
    required this.options,
    required this.values,
    required this.selected,
    required this.onPick,
  });

  final List<String> options;
  final List<String> values;
  final String selected;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = AppPalette.of(context);
    return Container(
      padding: const EdgeInsets.all(3),
      // Clip so the selected pill's shadow can never bleed past the track's
      // rounded corner — without it the last segment looks sliced off.
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: p.isDark
            ? Colors.white.withValues(alpha: 0.05)
            : Colors.black.withValues(alpha: 0.045),
        borderRadius: AppTokens.brSm,
      ),
      child: Row(
        children: <Widget>[
          for (int i = 0; i < options.length; i++)
            Expanded(
              child: GestureDetector(
                onTap: () => onPick(values[i]),
                behavior: HitTestBehavior.opaque,
                child: AnimatedContainer(
                  duration: AppTokens.fast,
                  curve: AppTokens.emphasized,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    color: selected == values[i]
                        ? (p.isDark
                            ? const Color(0xFF2A313C)
                            : Colors.white)
                        : Colors.transparent,
                    borderRadius: AppTokens.brXs,
                    boxShadow: selected == values[i]
                        ? <BoxShadow>[
                            BoxShadow(
                              color: Colors.black
                                  .withValues(alpha: p.isDark ? 0.28 : 0.07),
                              blurRadius: 5,
                              offset: const Offset(0, 1),
                            ),
                          ]
                        : null,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    options[i],
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: selected == values[i]
                          ? FontWeight.w600
                          : FontWeight.w400,
                      color: selected == values[i]
                          ? p.text
                          : p.textSecondary.withValues(alpha: 0.8),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = AppPalette.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: active ? cs.primary.withValues(alpha: 0.11) : null,
          borderRadius: AppTokens.brPill,
          border: Border.all(
            color: active
                ? cs.primary.withValues(alpha: 0.42)
                : p.lineStrong,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: active ? FontWeight.w600 : FontWeight.w400,
            color: active ? cs.primary : p.textSecondary,
          ),
        ),
      ),
    );
  }
}

/// Material switches are 52dp wide with a 48dp tap box; this trims both so the
/// row keeps a single line and the label still gets the space.
class _MiniSwitch extends StatelessWidget {
  const _MiniSwitch({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Transform.scale(
      scale: 0.86,
      child: Switch(
        value: value,
        onChanged: onChanged,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}
