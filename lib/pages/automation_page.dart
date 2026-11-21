import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../platform/a11y_bridge.dart';
import '../platform/privilege_bridge.dart';
import '../services/automation.dart';
import '../state/app_state.dart';
import '../theme/glass.dart';
import '../theme/tokens.dart';
import '../widgets/glass_header.dart';
import '../widgets/page_shell.dart';

/// Automation home: privilege status on top, the user's rules, then a small
/// template shelf. Everything here is phone-specific — a desktop scheduler has
/// no charger events, no Wi-Fi hand-off and no "send a notification".
class AutomationPage extends StatefulWidget {
  const AutomationPage({Key? key}) : super(key: key);

  @override
  State<AutomationPage> createState() => _AutomationPageState();
}

class _AutomationPageState extends State<AutomationPage> {
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AppState>().refreshPrivilege();
    });
  }

  AppState get _app => context.read<AppState>();

  Future<void> _refresh() async {
    setState(() => _refreshing = true);
    await _app.refreshPrivilege();
    if (mounted) setState(() => _refreshing = false);
  }

  Future<void> _authorize() async {
    final AppState app = _app;
    final PrivStatus st = app.privilege;
    if (st.shizukuGranted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Shizuku 已授权，可以直接用')),
      );
      return;
    }
    if (st.shizuku) {
      await app.requestShizuku();
    } else {
      final bool opened = await PrivilegeBridge.openShizuku();
      if (!opened && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('没找到 Shizuku。先装 Shizuku 并用它启动一次服务，'
              '或者给手机 root。'),
        ));
      }
    }
    await _refresh();
  }

  Future<void> _run(AutomationRule rule) async {
    final AutomationEngine? engine = _app.automation;
    if (engine == null) return;
    final String result = await engine.run(rule);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(
          result.length > 160 ? '${result.substring(0, 160)}…' : result,
        ),
        duration: const Duration(milliseconds: 3000),
      ));
  }

  Future<void> _edit([AutomationRule? rule]) async {
    final AutomationEngine? engine = _app.automation;
    if (engine == null) return;
    final AutomationRule working = rule ??
        AutomationRule(
          id: 'r${DateTime.now().microsecondsSinceEpoch}',
          name: '新规则',
          trigger: const AutomationTrigger('manual'),
          actions: <AutomationAction>[
            const AutomationAction('notify', <String, dynamic>{
              'title': 'ZCode',
              'body': '规则跑起来了',
            }),
          ],
        );
    final AutomationRule? saved =
        await Navigator.of(context).push<AutomationRule>(
      MaterialPageRoute<AutomationRule>(
        builder: (_) => _RuleEditorPage(rule: working, isNew: rule == null),
      ),
    );
    if (saved == null || !mounted) return;
    if (rule == null) {
      engine.add(saved);
    } else {
      engine.replace(saved);
    }
  }

  void _showLogs() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext ctx) => _LogSheet(engine: _app.automation!),
    );
  }

  void _showTemplates() {
    final AutomationEngine? engine = _app.automation;
    if (engine == null) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext ctx) {
        final List<AutomationRule> list = AutomationTemplates.market();
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.65,
          maxChildSize: 0.9,
          builder: (BuildContext c, ScrollController scroll) => ListView(
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: <Widget>[
              const _SheetHandle(),
              Row(
                children: <Widget>[
                  Text('模板',
                      style: Theme.of(ctx)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600)),
                  const Spacer(),
                  TextButton(
                    onPressed: () {
                      for (final AutomationRule t in list) {
                        final AutomationRule copy = t.copy()
                          ..id = 'r${DateTime.now().microsecondsSinceEpoch}'
                          ..lastRunMs = 0
                          ..runCount = 0;
                        engine.add(copy);
                      }
                      Navigator.pop(ctx);
                    },
                    child: const Text('全部添加', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text('加进列表后可以再改触发条件和动作。',
                  style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(ctx)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.5))),
              const SizedBox(height: 12),
              ...list.map((AutomationRule t) => Card(
                    elevation: 0,
                    margin: const EdgeInsets.only(bottom: 8),
                    color: Theme.of(ctx)
                        .colorScheme
                        .surfaceVariant
                        .withValues(alpha: 0.35),
                    child: ListTile(
                      title: Text(t.name,
                          style: const TextStyle(
                              fontSize: 13.5, fontWeight: FontWeight.w600)),
                      subtitle: Text(
                          '${t.trigger.summary} · ${t.actions.length} 个动作',
                          style: const TextStyle(fontSize: 11.5)),
                      trailing: TextButton(
                        onPressed: () {
                          final AutomationRule copy = t.copy()
                            ..id = 'r${DateTime.now().microsecondsSinceEpoch}'
                            ..lastRunMs = 0
                            ..runCount = 0;
                          engine.add(copy);
                          Navigator.pop(ctx);
                        },
                        child: const Text('添加', style: TextStyle(fontSize: 12)),
                      ),
                    ),
                  )),
            ],
          ),
        );
      },
    );
  }

  /// Batch enable or disable, for the days when a rule set gets noisy.
  void _setAll(AutomationEngine engine, bool on) {
    for (final AutomationRule r in engine.rules) {
      engine.toggle(r.id, on);
    }
    setState(() {});
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(on ? '全部规则已启用' : '全部规则已停用'),
        duration: const Duration(milliseconds: 1600),
      ));
  }

  /// The "less tapping" entrance: type one sentence, get an editable rule.
  Future<void> _quickRule() async {
    final TextEditingController controller = TextEditingController();
    String text = '';
    final String? sentence = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) {
        final ColorScheme cs = Theme.of(ctx).colorScheme;
        return AlertDialog(
          title: const Text('一句话建规则', style: TextStyle(fontSize: 16)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                TextField(
                  controller: controller,
                  autofocus: true,
                  maxLines: 3,
                  minLines: 2,
                  style: const TextStyle(fontSize: 13),
                  decoration: const InputDecoration(
                    hintText: '例如：到家连上 Wi-Fi 就 git pull，然后通知我',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (String v) => text = v,
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: <String>[
                    '每天 22:30 总结工作',
                    '电量低于 20% 调暗',
                    '验证码通知自动复制',
                    '屏幕出现构建成功就朗读',
                    '息屏 30 分钟整理笔记',
                    '打开微信时点「打卡」',
                  ]
                      .map((String sample) => ActionChip(
                            label: Text(sample,
                                style: const TextStyle(fontSize: 10.5)),
                            visualDensity: VisualDensity.compact,
                            onPressed: () {
                              controller.text = sample;
                              text = sample;
                            },
                          ))
                      .toList(),
                ),
                const SizedBox(height: 8),
                Text('会先解析成规则，再打开编辑页给你确认。',
                    style: TextStyle(
                        fontSize: 10.5,
                        color: cs.onSurface.withValues(alpha: 0.45))),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () =>
                  Navigator.pop(ctx, text.trim().isEmpty ? null : text.trim()),
              child: const Text('解析'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    if (sentence == null || sentence.isEmpty || !mounted) return;
    final AutomationRule draft = AutomationDraft.parse(sentence);
    final AppState app = _app;
    final AutomationRule? saved =
        await Navigator.of(context).push<AutomationRule>(
      MaterialPageRoute<AutomationRule>(
        builder: (_) => _RuleEditorPage(rule: draft, isNew: true),
      ),
    );
    if (saved == null || !mounted) return;
    app.automation?.add(saved);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text('已加上「${saved.name}」'),
        duration: const Duration(milliseconds: 1800),
      ));
  }

  Widget _a11yCard(AppState app, ColorScheme cs, bool en) {
    final A11yStatus st = app.a11y;
    final bool on = st.connected;
    final AppPalette p = AppPalette.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
      decoration: BoxDecoration(
        borderRadius: AppTokens.brLg,
        color: p.surface,
        border: Border.all(color: p.line, width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.visibility_outlined,
                  size: 17,
                  color:
                      on ? cs.tertiary : cs.onSurface.withValues(alpha: 0.5)),
              const SizedBox(width: 7),
              Text(en ? 'Screen & notifications' : '屏幕与通知',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  color: on
                      ? cs.tertiary.withValues(alpha: 0.16)
                      : cs.onSurface.withValues(alpha: 0.06),
                ),
                child: Text(
                  on ? (en ? 'connected' : '已连接') : (en ? 'off' : '未开启'),
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color:
                        on ? cs.tertiary : cs.onSurface.withValues(alpha: 0.5),
                  ),
                ),
              ),
              const Spacer(),
              TextButton(
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 30),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: () => _openA11y(app),
                child: Text(on ? (en ? 'Settings' : '管理') : '去开启',
                    style: const TextStyle(fontSize: 11.5)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            on
                ? '不用 root 就能读屏、按文字点按钮、输入、返回桌面，也能拿通知当触发条件。'
                : '开启后，规则可以「打开某应用后自动点一下」「屏幕出现某句话就提醒」，'
                    '通知也能当触发条件。不需要 root。',
            style: TextStyle(
                fontSize: 11.5,
                height: 1.45,
                color: cs.onSurface.withValues(alpha: 0.6)),
          ),
          const SizedBox(height: 9),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              _capChip(en ? 'Screen' : '无障碍', st.connected, cs),
              _capChip(
                  en ? 'Notifications' : '通知读取', st.notificationListener, cs),
              if (st.foregroundLabel.isNotEmpty)
                _capChip('前台：${st.foregroundLabel}', true, cs),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              TextButton.icon(
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  minimumSize: const Size(0, 30),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: () async {
                  final bool ok =
                      await app.openA11ySettings(notifications: true);
                  if (!ok && mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('没打开设置页，手动去 设置 → 通知使用权')));
                  }
                },
                icon: const Icon(Icons.notifications_outlined, size: 14),
                label: Text(en ? 'Notification access' : '通知使用权',
                    style: const TextStyle(fontSize: 11)),
              ),
              TextButton.icon(
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  minimumSize: const Size(0, 30),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: on ? () => _showScreen(app) : null,
                icon: const Icon(Icons.text_snippet_outlined, size: 14),
                label: Text(en ? 'Read screen now' : '读一下当前屏幕',
                    style: const TextStyle(fontSize: 11)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _openA11y(AppState app) async {
    if (app.a11y.connected) {
      await app.openA11ySettings();
      return;
    }
    await app.openA11ySettings();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('在「已下载的服务」里找到 ZCode 屏幕助手，打开开关。'),
      duration: Duration(seconds: 4),
    ));
  }

  Future<void> _showScreen(AppState app) async {
    final A11ySnapshot snap = await app.readScreen(limit: 40);
    if (!mounted) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext ctx) {
        final ColorScheme cs = Theme.of(ctx).colorScheme;
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.6,
          maxChildSize: 0.92,
          builder: (BuildContext c, ScrollController controller) => ListView(
            controller: controller,
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
            children: <Widget>[
              const _SheetHandle(),
              Text(snap.app.isEmpty ? snap.package : snap.app,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text('${snap.nodes.length} 个可读元素',
                  style: TextStyle(
                      fontSize: 11,
                      color: cs.onSurface.withValues(alpha: 0.45))),
              const SizedBox(height: 10),
              if (snap.isEmpty)
                Text('这一屏没有可读文字。有些应用（比如银行、游戏）会主动屏蔽。',
                    style: TextStyle(
                        fontSize: 12,
                        height: 1.5,
                        color: cs.onSurface.withValues(alpha: 0.55)))
              else
                ...snap.nodes.map((A11yNode n) => Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(9),
                        color: cs.surfaceVariant.withValues(alpha: 0.3),
                      ),
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(n.label,
                                style: const TextStyle(fontSize: 12)),
                          ),
                          if (n.clickable)
                            Text('可点',
                                style: TextStyle(
                                    fontSize: 9.5, color: cs.primary)),
                          if (n.editable)
                            Padding(
                              padding: const EdgeInsets.only(left: 5),
                              child: Text('可输入',
                                  style: TextStyle(
                                      fontSize: 9.5, color: cs.tertiary)),
                            ),
                        ],
                      ),
                    )),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppState app = context.watch<AppState>();
    final S s = S.of(app.config?.language);
    final bool en = s.isEnglish;
    final AutomationEngine? engine = app.automation;
    final ColorScheme cs = Theme.of(context).colorScheme;

    return PageShell(
      title: en ? 'Automation' : '自动化',
      subtitle: Text(
        engine == null
            ? '—'
            : (en
                ? '${engine.enabledRules.length} active · ${engine.todayRuns} runs today'
                : '${engine.enabledRules.length} 条启用 · 今天跑了 ${engine.todayRuns} 次'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      actions: <Widget>[
        HeaderAction(
          tooltip: en ? 'One sentence → rule' : '一句话建规则',
          icon: Icons.auto_awesome_rounded,
          onTap: engine == null ? null : _quickRule,
        ),
        HeaderAction(
          tooltip: en ? 'History' : '运行记录',
          icon: Icons.history_rounded,
          onTap: engine == null ? null : _showLogs,
        ),
        HeaderAction(
          tooltip: en ? 'Refresh privileges' : '重新检测权限',
          icon: Icons.refresh_rounded,
          onTap: _refreshing ? null : _refresh,
          tint: _refreshing ? cs.primary : null,
        ),
      ],
      floating: _newRuleButton(engine, en),
      child: engine == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(
                  AppTokens.gutter, AppTokens.s2, AppTokens.gutter, 96),
              children: <Widget>[
                _privCard(app, cs, en),
                const SizedBox(height: 10),
                _a11yCard(app, cs, en),
                const SizedBox(height: 14),
                Row(
                  children: <Widget>[
                    Text(en ? 'Rules' : '规则',
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600)),
                    const Spacer(),
                    PopupMenuButton<bool>(
                      tooltip: en ? 'Enable / disable all' : '批量启停',
                      splashRadius: 18,
                      icon: const Icon(Icons.tune_rounded, size: 17),
                      onSelected: (bool on) => _setAll(engine, on),
                      itemBuilder: (_) => <PopupMenuEntry<bool>>[
                        const PopupMenuItem<bool>(
                            value: true,
                            child:
                                Text('全部启用', style: TextStyle(fontSize: 13))),
                        const PopupMenuItem<bool>(
                            value: false,
                            child:
                                Text('全部停用', style: TextStyle(fontSize: 13))),
                      ],
                    ),
                    TextButton.icon(
                      onPressed: _showTemplates,
                      icon: const Icon(Icons.grid_view_rounded, size: 15),
                      label: Text(en ? 'Templates' : '模板',
                          style: const TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
                if (engine.rules.isEmpty)
                  _empty(cs, en)
                else
                  ...engine.rules
                      .map((AutomationRule r) => _ruleCard(engine, r, cs, en)),
                const SizedBox(height: 18),
                _onlyOnPhone(cs, en),
              ],
            ),
    );
  }

  /// The one primary action on the page. Solid accent rather than glass: a
  /// translucent pill over white cards has no edge to hold on to, and this is
  /// the button people need to find first.
  Widget _newRuleButton(AutomationEngine? engine, bool en) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final bool on = engine != null;
    // Dark mode uses the container tone: a tone-80 fill is the brightest thing
    // on the screen and pulls the eye away from the rules it is meant to add.
    final Color fill = dark ? cs.primaryContainer : cs.primary;
    final Color ink = dark ? cs.onPrimaryContainer : cs.onPrimary;
    return AnimatedOpacity(
      duration: AppTokens.fast,
      opacity: on ? 1 : 0.4,
      child: PressScale(
        radius: 999,
        enabled: on,
        child: GestureDetector(
          onTap: on ? () => _edit() : null,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: fill,
              borderRadius: AppTokens.brPill,
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: Colors.black.withValues(alpha: dark ? 0.35 : 0.16),
                  blurRadius: 16,
                  spreadRadius: -4,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 13, 18, 13),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(Icons.add_rounded, size: 18, color: ink),
                  const SizedBox(width: 6),
                  Text(
                    en ? 'New rule' : '新建规则',
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: ink,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _empty(ColorScheme cs, bool en) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 26),
      child: Column(
        children: <Widget>[
          Icon(Icons.auto_awesome_outlined,
              size: 34, color: cs.onSurface.withValues(alpha: 0.2)),
          const SizedBox(height: 10),
          Text(en ? 'No rules yet' : '还没有规则',
              style: TextStyle(
                  fontSize: 13, color: cs.onSurface.withValues(alpha: 0.55))),
          const SizedBox(height: 4),
          Text(
            en
                ? 'Start from a template, or create one from scratch.'
                : '可以从模板加一条，也可以自己建。',
            style: TextStyle(
                fontSize: 11.5, color: cs.onSurface.withValues(alpha: 0.4)),
          ),
        ],
      ),
    );
  }

  Widget _privCard(AppState app, ColorScheme cs, bool en) {
    final PrivStatus st = app.privilege;
    final bool strong = st.privileged;
    final AppPalette p = AppPalette.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 13, 12, 13),
      // Neutral shell, coloured state: a tinted card that means "good" here
      // would clash with the accent the user picked for the whole app.
      decoration: BoxDecoration(
        borderRadius: AppTokens.brLg,
        color: p.surface,
        border: Border.all(color: p.line, width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                strong ? Icons.shield_rounded : Icons.shield_outlined,
                size: 17,
                color:
                    strong ? cs.primary : cs.onSurface.withValues(alpha: 0.5),
              ),
              const SizedBox(width: 7),
              Text(
                en ? 'Privilege' : '权限',
                style:
                    const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  color: strong
                      ? cs.primary.withValues(alpha: 0.16)
                      : cs.onSurface.withValues(alpha: 0.07),
                ),
                child: Text(
                  st.label,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: strong
                        ? cs.primary
                        : cs.onSurface.withValues(alpha: 0.55),
                  ),
                ),
              ),
              const Spacer(),
              if (!st.shizukuGranted)
                TextButton(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 30),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: _authorize,
                  child: Text(
                    st.shizuku
                        ? (en ? 'Grant' : '授权')
                        : (en ? 'Set up' : '去开启'),
                    style: const TextStyle(fontSize: 11.5),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            st.unlocked,
            style: TextStyle(
                fontSize: 11.5,
                height: 1.45,
                color: cs.onSurface.withValues(alpha: 0.6)),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              _capChip('root', st.root, cs),
              _capChip('Shizuku', st.shizuku, cs),
              _capChip(en ? 'Notifications' : '通知', st.notifications, cs),
              _capChip(en ? 'Write settings' : '改系统设置', st.writeSettings, cs),
              _capChip(en ? 'DND' : '勿扰', st.dndAccess, cs),
            ],
          ),
          if (!st.privileged) ...[
            const SizedBox(height: 9),
            Text(
              en
                  ? 'Root or Shizuku unlocks system switches, screenshots, taps '
                      'and per-app control. Without either, rules still run '
                      'notifications, shell commands and agent turns.'
                  : 'root 或 Shizuku 能解锁系统开关、截屏、模拟点击和应用控制；'
                      '两者都没有时，规则依然可以发通知、跑命令、叫智能体干活。',
              style: TextStyle(
                  fontSize: 10.5,
                  height: 1.5,
                  color: cs.onSurface.withValues(alpha: 0.42)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _capChip(String label, bool ok, ColorScheme cs) {
    final AppPalette p = AppPalette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: AppTokens.brPill,
        color: ok ? cs.primary.withValues(alpha: 0.12) : p.surfaceRaised,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            ok ? Icons.check_rounded : Icons.remove_rounded,
            size: 12,
            color: ok ? cs.primary : cs.onSurface.withValues(alpha: 0.3),
          ),
          const SizedBox(width: 3),
          Text(
            label,
            style: TextStyle(
              fontSize: 10.5,
              color: ok ? cs.primary : cs.onSurface.withValues(alpha: 0.4),
            ),
          ),
        ],
      ),
    );
  }

  Widget _ruleCard(
      AutomationEngine engine, AutomationRule rule, ColorScheme cs, bool en) {
    final DateTime? last = rule.lastRun;
    final String lastLabel =
        last == null ? (en ? 'never run' : '未运行') : _ago(last, en);
    final AppPalette p = AppPalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTokens.s2),
      child: Material(
        color: rule.enabled ? p.surface : p.bgElevated,
        shape: RoundedRectangleBorder(
          borderRadius: AppTokens.brLg,
          side: BorderSide(color: p.line, width: 0.8),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _edit(rule),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(13, 11, 6, 11),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(
                    _triggerIcon(rule.trigger.kind),
                    size: 18,
                    color: rule.enabled
                        ? cs.primary
                        : cs.onSurface.withValues(alpha: 0.3),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        rule.name,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: rule.enabled
                              ? cs.onSurface
                              : cs.onSurface.withValues(alpha: 0.45),
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${rule.trigger.summary} · $lastLabel',
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.onSurface.withValues(alpha: 0.45),
                        ),
                      ),
                      if (rule.lastResult.isNotEmpty && rule.enabled) ...[
                        const SizedBox(height: 4),
                        Text(
                          rule.lastResult.split('\n').first,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10.5,
                            color: cs.onSurface.withValues(alpha: 0.36),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                IconButton(
                  tooltip: en ? 'Run now' : '立即运行',
                  splashRadius: 18,
                  icon: const Icon(Icons.play_arrow_rounded, size: 20),
                  onPressed: engine.busy ? null : () => _run(rule),
                ),
                Switch(
                  value: rule.enabled,
                  onChanged: (bool v) => engine.toggle(rule.id, v),
                ),
                PopupMenuButton<String>(
                  splashRadius: 18,
                  icon: const Icon(Icons.more_vert_rounded, size: 18),
                  padding: EdgeInsets.zero,
                  onSelected: (String v) {
                    switch (v) {
                      case 'dup':
                        final AutomationRule copy = rule.copy()
                          ..id = 'r${DateTime.now().microsecondsSinceEpoch}'
                          ..name = '${rule.name} 副本'
                          ..lastRunMs = 0
                          ..runCount = 0;
                        engine.add(copy);
                        break;
                      case 'delete':
                        engine.remove(rule.id);
                        break;
                      case 'logs':
                        _showLogs();
                        break;
                    }
                  },
                  itemBuilder: (_) => <PopupMenuEntry<String>>[
                    PopupMenuItem<String>(
                        value: 'dup', child: Text(en ? 'Duplicate' : '复制一份')),
                    PopupMenuItem<String>(
                        value: 'logs', child: Text(en ? 'History' : '运行记录')),
                    PopupMenuItem<String>(
                        value: 'delete', child: Text(en ? 'Delete' : '删除')),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _onlyOnPhone(ColorScheme cs, bool en) {
    const List<List<String>> rows = <List<String>>[
      <String>['插上电源', '清掉后台，开始充电'],
      <String>['连上家里 Wi-Fi', '自动 git pull，回来就是最新代码'],
      <String>['电量低于 20%', '调暗屏幕，提醒你收工'],
      <String>['解锁手机', '把今天的待办推到通知栏'],
      <String>['收到验证码通知', '自动复制，切过去就能粘贴'],
      <String>['打开微信', '按文字点「打卡」，不用自己找按钮'],
      <String>['屏幕出现「构建成功」', '朗读一句，然后震一下'],
      <String>['息屏半小时', '智能体把今天的改动整理成笔记'],
      <String>['每天 22:30', '让智能体总结今天改了什么'],
      <String>['长按图标', '「自动化」快捷方式直达规则页'],
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(en ? 'What only a phone can trigger' : '这些只有手机上能触发',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        ...rows.map((List<String> r) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Container(
                    margin: const EdgeInsets.only(top: 5),
                    width: 4,
                    height: 4,
                    decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: cs.primary.withValues(alpha: 0.5)),
                  ),
                  const SizedBox(width: 8),
                  Text(r[0],
                      style: TextStyle(
                          fontSize: 11.5,
                          color: cs.onSurface.withValues(alpha: 0.62))),
                  Text('  →  ',
                      style: TextStyle(
                          fontSize: 11.5,
                          color: cs.onSurface.withValues(alpha: 0.25))),
                  Expanded(
                    child: Text(r[1],
                        style: TextStyle(
                            fontSize: 11.5,
                            color: cs.onSurface.withValues(alpha: 0.42))),
                  ),
                ],
              ),
            )),
      ],
    );
  }

  static String _ago(DateTime at, bool en) {
    final Duration d = DateTime.now().difference(at);
    if (d.inMinutes < 1) return en ? 'just now' : '刚刚';
    if (d.inMinutes < 60)
      return en ? '${d.inMinutes}m ago' : '${d.inMinutes} 分钟前';
    if (d.inHours < 24) return en ? '${d.inHours}h ago' : '${d.inHours} 小时前';
    return en ? '${d.inDays}d ago' : '${d.inDays} 天前';
  }
}

IconData _triggerIcon(String kind) {
  switch (kind) {
    case 'interval':
      return Icons.timelapse_rounded;
    case 'daily':
      return Icons.schedule_rounded;
    case 'battery_below':
    case 'battery_above':
      return Icons.battery_alert_rounded;
    case 'battery_full':
      return Icons.battery_charging_full_rounded;
    case 'charging':
    case 'unplugged':
      return Icons.power_rounded;
    case 'wifi_on':
    case 'wifi_off':
      return Icons.wifi_rounded;
    case 'screen_on':
    case 'unlock':
      return Icons.phonelink_lock_rounded;
    case 'boot':
      return Icons.restart_alt_rounded;
    case 'notification':
      return Icons.notifications_active_rounded;
    case 'app_foreground':
      return Icons.apps_rounded;
    case 'screen_text':
      return Icons.text_fields_rounded;
    case 'idle':
      return Icons.bedtime_outlined;
    default:
      return Icons.touch_app_rounded;
  }
}

// ---------------------------------------------------------------- editor

class _RuleEditorPage extends StatefulWidget {
  const _RuleEditorPage({required this.rule, required this.isNew});

  final AutomationRule rule;
  final bool isNew;

  @override
  State<_RuleEditorPage> createState() => _RuleEditorPageState();
}

class _RuleEditorPageState extends State<_RuleEditorPage> {
  late final TextEditingController _nameField;
  late String _name;
  late AutomationTrigger _trigger;
  late List<AutomationAction> _actions;
  late bool _notify;

  @override
  void initState() {
    super.initState();
    _name = widget.rule.name;
    _nameField = TextEditingController(text: _name);
    _trigger = widget.rule.trigger;
    _actions = List<AutomationAction>.from(widget.rule.actions);
    _notify = widget.rule.notify;
  }

  @override
  void dispose() {
    _nameField.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return PageShell(
      title: widget.isNew ? '新建规则' : '编辑规则',
      subtitle: Text(
        widget.isNew ? '触发条件 + 动作，保存后立刻生效' : '改动保存后立刻生效',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      actions: <Widget>[
        Padding(
          padding: const EdgeInsets.only(right: 10),
          child: TextButton(
            onPressed: _save,
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 34),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text('保存',
                style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: cs.primary)),
          ),
        ),
      ],
      child: ListView(
        padding: const EdgeInsets.fromLTRB(
            AppTokens.gutter, AppTokens.s3, AppTokens.gutter, 32),
        children: <Widget>[
          TextField(
            controller: _nameField,
            onChanged: (String v) => _name = v,
            decoration: const InputDecoration(
              labelText: '名称',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            style: const TextStyle(fontSize: 14),
          ),
          const SizedBox(height: 18),
          _label('触发条件'),
          const SizedBox(height: 6),
          InkWell(
            onTap: _pickTrigger,
            borderRadius: BorderRadius.circular(10),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: cs.outline.withValues(alpha: 0.35)),
              ),
              child: Row(
                children: <Widget>[
                  Icon(_triggerIcon(_trigger.kind),
                      size: 17, color: cs.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(_trigger.summary,
                        style: const TextStyle(fontSize: 13)),
                  ),
                  Icon(Icons.expand_more_rounded,
                      size: 18, color: cs.onSurface.withValues(alpha: 0.4)),
                ],
              ),
            ),
          ),
          if (_trigger.kind == 'interval' || _trigger.kind == 'daily')
            _clockArgs(cs),
          if (_trigger.kind == 'battery_below' ||
              _trigger.kind == 'battery_above')
            _batteryArgs(cs),
          if (_trigger.kind == 'wifi_on') _wifiArgs(cs),
          if (_trigger.kind == 'notification') _notifArgs(cs),
          if (_trigger.kind == 'app_foreground') _appArgs(cs),
          if (_trigger.kind == 'screen_text') _screenTextArgs(cs),
          if (_trigger.kind == 'idle') _idleArgs(cs),
          const SizedBox(height: 18),
          Row(
            children: <Widget>[
              _label('动作'),
              const Spacer(),
              TextButton.icon(
                onPressed: _addAction,
                icon: const Icon(Icons.add_rounded, size: 16),
                label: const Text('添加', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
          const SizedBox(height: 2),
          if (_actions.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Text('还没有动作。至少加一个，否则规则什么也不做。',
                  style: TextStyle(
                      fontSize: 11.5,
                      color: cs.onSurface.withValues(alpha: 0.45))),
            ),
          ...List<Widget>.generate(_actions.length, (int i) {
            final AutomationAction a = _actions[i];
            return Card(
              elevation: 0,
              margin: const EdgeInsets.only(bottom: 7),
              color: cs.surfaceVariant.withValues(alpha: 0.35),
              child: ListTile(
                dense: true,
                leading: Icon(_actionIcon(a.kind), size: 17, color: cs.primary),
                title: Text(a.summary,
                    style: const TextStyle(fontSize: 12.5),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    IconButton(
                      icon: const Icon(Icons.edit_outlined, size: 16),
                      splashRadius: 16,
                      onPressed: () => _editAction(i),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded, size: 16),
                      splashRadius: 16,
                      onPressed: () => setState(() => _actions.removeAt(i)),
                    ),
                  ],
                ),
              ),
            );
          }),
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: _notify,
            onChanged: (bool v) => setState(() => _notify = v),
            title: const Text('执行后发一条通知', style: TextStyle(fontSize: 13)),
            subtitle: Text('规则里的动作失败时一定会提示。',
                style: TextStyle(
                    fontSize: 11, color: cs.onSurface.withValues(alpha: 0.45))),
          ),
        ],
      ),
    );
  }

  Widget _label(String text) => Text(text,
      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600));

  Widget _clockArgs(ColorScheme cs) {
    if (_trigger.kind == 'interval') {
      final int minutes = (_trigger.args['minutes'] as num?)?.toInt() ?? 30;
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(
          children: <Widget>[
            const Text('每', style: TextStyle(fontSize: 12)),
            SizedBox(
              width: 72,
              child: TextFormField(
                initialValue: '$minutes',
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13),
                decoration:
                    const InputDecoration(isDense: true, suffixText: '分钟'),
                onChanged: (String v) {
                  final int? n = int.tryParse(v);
                  if (n != null && n > 0) {
                    _trigger = AutomationTrigger(
                        'interval', <String, dynamic>{'minutes': n});
                  }
                },
              ),
            ),
            const Text(' 跑一次', style: TextStyle(fontSize: 12)),
          ],
        ),
      );
    }
    final int hour = (_trigger.args['hour'] as num?)?.toInt() ?? 9;
    final int minute = (_trigger.args['minute'] as num?)?.toInt() ?? 0;
    final List<int> days =
        ((_trigger.args['weekdays'] as List<dynamic>?) ?? const <dynamic>[])
            .map((dynamic e) => (e as num).toInt())
            .toList();
    const List<String> names = <String>['一', '二', '三', '四', '五', '六', '日'];
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              OutlinedButton.icon(
                onPressed: () async {
                  final TimeOfDay? picked = await showTimePicker(
                    context: context,
                    initialTime: TimeOfDay(hour: hour, minute: minute),
                  );
                  if (picked == null) return;
                  setState(() {
                    _trigger = AutomationTrigger('daily', <String, dynamic>{
                      'hour': picked.hour,
                      'minute': picked.minute,
                      'weekdays': days,
                    });
                  });
                },
                icon: const Icon(Icons.access_time_rounded, size: 15),
                label: Text(
                  '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}',
                  style: const TextStyle(fontSize: 12.5),
                ),
              ),
              const SizedBox(width: 10),
              Text('每周的哪几天（不选＝每天）',
                  style: TextStyle(
                      fontSize: 11,
                      color: cs.onSurface.withValues(alpha: 0.45))),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            children: <Widget>[
              for (int i = 1; i <= 7; i++)
                FilterChip(
                  label:
                      Text(names[i - 1], style: const TextStyle(fontSize: 11)),
                  selected: days.contains(i),
                  onSelected: (bool v) {
                    final List<int> next = List<int>.from(days);
                    if (v) {
                      next.add(i);
                    } else {
                      next.remove(i);
                    }
                    next.sort();
                    setState(() {
                      _trigger = AutomationTrigger('daily', <String, dynamic>{
                        'hour': hour,
                        'minute': minute,
                        'weekdays': next,
                      });
                    });
                  },
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _batteryArgs(ColorScheme cs) {
    final int level = (_trigger.args['level'] as num?)?.toInt() ?? 20;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Slider(
              value: level.toDouble(),
              min: 5,
              max: 100,
              divisions: 19,
              label: '$level%',
              onChanged: (double v) {
                setState(() {
                  _trigger = AutomationTrigger(
                      _trigger.kind, <String, dynamic>{'level': v.round()});
                });
              },
            ),
          ),
          SizedBox(
            width: 44,
            child: Text('$level%',
                style: const TextStyle(fontSize: 12.5),
                textAlign: TextAlign.end),
          ),
        ],
      ),
    );
  }

  Widget _wifiArgs(ColorScheme cs) {
    final String ssid = '${_trigger.args['ssid'] ?? ''}';
    return Padding(
      padding: const EdgeInsets.only(top: 8, left: 0, right: 0),
      child: TextFormField(
        initialValue: ssid,
        decoration: InputDecoration(
          isDense: true,
          labelText: 'Wi-Fi 名称包含（留空＝任意 Wi-Fi）',
          labelStyle: const TextStyle(fontSize: 12),
          border: const OutlineInputBorder(),
          helperText: 'Android 10 起读取完整 SSID 需要定位权限，读不到时按「任意 Wi-Fi」处理。',
          helperStyle: TextStyle(
              fontSize: 10, color: cs.onSurface.withValues(alpha: 0.4)),
        ),
        style: const TextStyle(fontSize: 13),
        onChanged: (String v) {
          _trigger =
              AutomationTrigger('wifi_on', <String, dynamic>{'ssid': v.trim()});
        },
      ),
    );
  }

  Widget _notifArgs(ColorScheme cs) {
    final String app = '${_trigger.args['app'] ?? ''}';
    final String keyword = '${_trigger.args['keyword'] ?? ''}';
    void put(String key, String value) {
      final Map<String, dynamic> next = Map<String, dynamic>.from(_trigger.args)
        ..[key] = value.trim();
      _trigger = AutomationTrigger('notification', next);
      setState(() {});
    }

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        children: <Widget>[
          TextFormField(
            initialValue: app,
            style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(
              labelText: '来自哪个应用（留空＝任何应用）',
              hintText: '微信 / com.tencent.mm',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            onChanged: (String v) => put('app', v),
          ),
          const SizedBox(height: 8),
          TextFormField(
            initialValue: keyword,
            style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(
              labelText: '标题或正文包含（留空＝全部）',
              hintText: '验证码 / 老板 / 构建失败',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            onChanged: (String v) => put('keyword', v),
          ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '需要「通知使用权」，自动化页顶部可以一键去开。动作里可以用 {app}、{title}、{text}。',
              style: TextStyle(
                  fontSize: 10.5,
                  height: 1.4,
                  color: cs.onSurface.withValues(alpha: 0.45)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _appArgs(ColorScheme cs) {
    final String label = '${_trigger.args['label'] ?? ''}';
    final String pkg = '${_trigger.args['package'] ?? ''}';
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        children: <Widget>[
          TextFormField(
            initialValue: label,
            style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(
              labelText: '应用名称',
              hintText: '微信',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            onChanged: (String v) {
              _trigger = AutomationTrigger('app_foreground',
                  <String, dynamic>{'label': v.trim(), 'package': pkg});
            },
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(
                child: TextFormField(
                  initialValue: pkg,
                  style: const TextStyle(fontSize: 12.5),
                  decoration: const InputDecoration(
                    labelText: '包名（更准，可留空）',
                    hintText: 'com.tencent.mm',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (String v) {
                    _trigger = AutomationTrigger('app_foreground',
                        <String, dynamic>{'label': label, 'package': v.trim()});
                  },
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: _pickApp,
                child: const Text('选应用', style: TextStyle(fontSize: 11.5)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: Text('需要无障碍服务（不用 root）。',
                style: TextStyle(
                    fontSize: 10.5,
                    color: cs.onSurface.withValues(alpha: 0.45))),
          ),
        ],
      ),
    );
  }

  Widget _screenTextArgs(ColorScheme cs) {
    final String text = '${_trigger.args['text'] ?? ''}';
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: TextFormField(
        initialValue: text,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          labelText: '屏幕上出现的文字',
          hintText: '构建成功 / 支付成功',
          isDense: true,
          border: const OutlineInputBorder(),
          helperText: '每次切到新界面时会读一次，30 秒内不会重复触发。',
          helperStyle: TextStyle(
              fontSize: 10, color: cs.onSurface.withValues(alpha: 0.4)),
        ),
        onChanged: (String v) {
          _trigger = AutomationTrigger(
              'screen_text', <String, dynamic>{'text': v.trim()});
        },
      ),
    );
  }

  Widget _idleArgs(ColorScheme cs) {
    final int minutes = (_trigger.args['minutes'] as num?)?.toInt() ?? 30;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Slider(
              value: minutes.toDouble(),
              min: 5,
              max: 180,
              divisions: 35,
              label: '$minutes 分钟',
              onChanged: (double v) {
                setState(() {
                  _trigger = AutomationTrigger(
                      'idle', <String, dynamic>{'minutes': v.round()});
                });
              },
            ),
          ),
          SizedBox(
            width: 64,
            child: Text('$minutes 分钟',
                textAlign: TextAlign.end, style: const TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Future<void> _pickApp() async {
    final List<Map<String, String>> apps = await PrivilegeBridge.apps();
    if (!mounted) return;
    if (apps.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('读不到应用列表')),
      );
      return;
    }
    final String? picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.92,
        builder: (BuildContext c, ScrollController controller) =>
            ListView.builder(
          controller: controller,
          itemCount: apps.length,
          itemBuilder: (BuildContext c, int i) {
            final Map<String, String> a = apps[i];
            return ListTile(
              dense: true,
              title:
                  Text(a['label'] ?? '', style: const TextStyle(fontSize: 13)),
              subtitle: Text(a['package'] ?? '',
                  style: const TextStyle(fontSize: 10.5)),
              onTap: () => Navigator.pop(
                  ctx, '${a['label'] ?? ''}\u0001${a['package'] ?? ''}'),
            );
          },
        ),
      ),
    );
    if (picked == null || !mounted) return;
    final int cut = picked.indexOf('\u0001');
    final String label = cut < 0 ? picked : picked.substring(0, cut);
    final String pkg = cut < 0 ? '' : picked.substring(cut + 1);
    setState(() {
      _trigger = AutomationTrigger(
          'app_foreground', <String, dynamic>{'label': label, 'package': pkg});
    });
  }

  void _save() {
    final String name = _name.trim().isEmpty ? '未命名规则' : _name.trim();
    if (_actions.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('至少需要一个动作')),
      );
      return;
    }
    final AutomationRule next = widget.rule.copy()
      ..name = name
      ..trigger = _trigger
      ..actions = List<AutomationAction>.from(_actions)
      ..notify = _notify;
    Navigator.pop(context, next);
  }

  void _addAction() {
    showModalBottomSheet<void>(
      context: context,
      builder: (BuildContext ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const _SheetHandle(),
            for (final List<String> item in <List<String>>[
              <String>['agent', '叫智能体干活', '跑一轮对话，结果写进记录'],
              <String>['shell', '执行命令', '内置 sh / Termux / root / Shizuku'],
              <String>['notify', '发通知', '标题和正文，支持 {app} {text}'],
              <String>['a11y', '屏幕操作', '按文字点按钮、输入、返回，不用 root'],
              <String>['device', '操作手机', 'Wi-Fi、截屏、音量、深色模式…'],
              <String>['speak', '朗读一段话', '系统 TTS，不用 root'],
              <String>['clipboard', '复制到剪贴板', '常和通知触发搭配，如 {text}'],
              <String>['open_app', '打开应用', '包名或应用名'],
              <String>['delay', '等一会儿', '给上一步留时间'],
              <String>['webhook', '发 HTTP 请求', '把结果推到自己的服务'],
            ])
              ListTile(
                leading: Icon(_actionIcon(item[0]), size: 19),
                title: Text(item[1], style: const TextStyle(fontSize: 13.5)),
                subtitle: Text(item[2], style: const TextStyle(fontSize: 11)),
                onTap: () {
                  Navigator.pop(ctx);
                  _editAction(-1, kind: item[0]);
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _editAction(int index, {String? kind}) async {
    final AutomationAction base = index >= 0
        ? _actions[index]
        : const AutomationAction('notify', <String, dynamic>{
            'title': 'ZCode',
            'body': '',
          });
    final AutomationAction? result =
        await showModalBottomSheet<AutomationAction>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext ctx) =>
          _ActionSheet(action: base, kindOverride: kind),
    );
    if (result == null || !mounted) return;
    setState(() {
      if (index >= 0) {
        _actions[index] = result;
      } else {
        _actions.add(result);
      }
    });
  }

  static IconData _actionIcon(String kind) {
    switch (kind) {
      case 'agent':
        return Icons.auto_awesome_rounded;
      case 'shell':
        return Icons.terminal_rounded;
      case 'notify':
        return Icons.notifications_active_outlined;
      case 'device':
        return Icons.phone_android_rounded;
      case 'a11y':
        return Icons.touch_app_rounded;
      case 'speak':
        return Icons.record_voice_over_rounded;
      case 'clipboard':
        return Icons.copy_all_rounded;
      case 'open_app':
        return Icons.open_in_new_rounded;
      case 'delay':
        return Icons.hourglass_bottom_rounded;
      case 'webhook':
        return Icons.cloud_upload_outlined;
      default:
        return Icons.bolt_rounded;
    }
  }

  void _pickTrigger() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext ctx) {
        const List<List<String>> rows = <List<String>>[
          <String>['manual', '仅手动'],
          <String>['interval', '每隔一段时间'],
          <String>['daily', '每天几点'],
          <String>['battery_below', '电量低于'],
          <String>['battery_above', '电量高于'],
          <String>['charging', '插上电源'],
          <String>['unplugged', '拔掉电源'],
          <String>['wifi_on', '连上 Wi-Fi'],
          <String>['wifi_off', '断开 Wi-Fi'],
          <String>['screen_on', '点亮屏幕'],
          <String>['unlock', '解锁手机'],
          <String>['notification', '收到通知'],
          <String>['app_foreground', '打开某个应用'],
          <String>['screen_text', '屏幕出现文字'],
          <String>['battery_full', '电量充满'],
          <String>['idle', '息屏一段时间'],
          <String>['boot', '开机后首次打开'],
        ];
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.only(bottom: 16),
            children: <Widget>[
              const _SheetHandle(),
              for (final List<String> r in rows)
                ListTile(
                  dense: true,
                  leading: Icon(_triggerIcon(r[0]), size: 18),
                  title: Text(r[1], style: const TextStyle(fontSize: 13.5)),
                  onTap: () {
                    Navigator.pop(ctx);
                    setState(() {
                      _trigger = AutomationTrigger(r[0], _defaultArgs(r[0]));
                    });
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  static Map<String, dynamic> _defaultArgs(String kind) {
    switch (kind) {
      case 'interval':
        return <String, dynamic>{'minutes': 60};
      case 'daily':
        return <String, dynamic>{
          'hour': 9,
          'minute': 0,
          'weekdays': <int>[],
        };
      case 'battery_below':
        return <String, dynamic>{'level': 20};
      case 'battery_above':
        return <String, dynamic>{'level': 80};
      case 'wifi_on':
        return <String, dynamic>{'ssid': ''};
      case 'notification':
        return <String, dynamic>{'app': '', 'keyword': ''};
      case 'app_foreground':
        return <String, dynamic>{'package': '', 'label': ''};
      case 'screen_text':
        return <String, dynamic>{'text': ''};
      case 'idle':
        return <String, dynamic>{'minutes': 30};
      default:
        return <String, dynamic>{};
    }
  }
}

// ------------------------------------------------------------- action sheet

class _ActionSheet extends StatefulWidget {
  const _ActionSheet({required this.action, this.kindOverride});

  final AutomationAction action;
  final String? kindOverride;

  @override
  State<_ActionSheet> createState() => _ActionSheetState();
}

class _ActionSheetState extends State<_ActionSheet> {
  late String _kind;
  late Map<String, dynamic> _args;

  @override
  void initState() {
    super.initState();
    _kind = widget.kindOverride ?? widget.action.kind;
    _args = Map<String, dynamic>.from(widget.action.args);
    if (widget.kindOverride != null) _args = _defaults(_kind);
  }

  static Map<String, dynamic> _defaults(String kind) {
    switch (kind) {
      case 'agent':
        return <String, dynamic>{'prompt': ''};
      case 'shell':
        return <String, dynamic>{'command': '', 'mode': 'auto'};
      case 'notify':
        return <String, dynamic>{'title': 'ZCode', 'body': ''};
      case 'device':
        return <String, dynamic>{'action': 'wifi_on', 'package': ''};
      case 'a11y':
        return <String, dynamic>{
          'op': 'click',
          'text': '',
          'value': '',
          'index': 0,
        };
      case 'speak':
        return <String, dynamic>{'text': ''};
      case 'clipboard':
        return <String, dynamic>{'text': '{text}'};
      case 'open_app':
        return <String, dynamic>{'package': '', 'label': ''};
      case 'delay':
        return <String, dynamic>{'seconds': 5};
      case 'webhook':
        return <String, dynamic>{'url': '', 'body': '{}'};
      default:
        return <String, dynamic>{};
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final AppState app = context.watch<AppState>();
    final EdgeInsets pad = MediaQuery.of(context).viewInsets;
    return Padding(
      padding: EdgeInsets.only(bottom: pad.bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const _SheetHandle(),
              Text(_title,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              ..._fields(cs, app),
              const SizedBox(height: 14),
              Row(
                children: <Widget>[
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => Navigator.pop(
                        context,
                        AutomationAction(
                            _kind, Map<String, dynamic>.from(_args)),
                      ),
                      child: const Text('确定'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String get _title {
    switch (_kind) {
      case 'agent':
        return '智能体任务';
      case 'shell':
        return '执行命令';
      case 'notify':
        return '发通知';
      case 'device':
        return '操作手机';
      case 'a11y':
        return '屏幕操作';
      case 'speak':
        return '朗读';
      case 'clipboard':
        return '复制到剪贴板';
      case 'open_app':
        return '打开应用';
      case 'delay':
        return '等待';
      case 'webhook':
        return 'HTTP 请求';
      default:
        return _kind;
    }
  }

  List<Widget> _fields(ColorScheme cs, AppState app) {
    final bool privileged = app.privilege.privileged;
    switch (_kind) {
      case 'agent':
        return <Widget>[
          TextFormField(
            initialValue: '${_args['prompt'] ?? ''}',
            maxLines: 5,
            minLines: 3,
            style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(
              labelText: '让它做什么',
              hintText: '例如：检查今天的构建，失败就把错误摘要发我',
              border: OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
            onChanged: (String v) => _args['prompt'] = v,
          ),
          const SizedBox(height: 8),
          Text(
            '自动化里的智能体会自动批准工具调用（没人在旁边点确认），所以提示词要写清楚边界。',
            style: TextStyle(
                fontSize: 10.5, color: cs.onSurface.withValues(alpha: 0.42)),
          ),
        ];
      case 'shell':
        return <Widget>[
          TextFormField(
            initialValue: '${_args['command'] ?? ''}',
            maxLines: 4,
            minLines: 2,
            style: const TextStyle(fontSize: 12.5, fontFamily: 'monospace'),
            decoration: const InputDecoration(
              labelText: '命令',
              hintText: 'git pull --ff-only',
              border: OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
            onChanged: (String v) => _args['command'] = v,
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            children: <Widget>[
              for (final List<String> m in <List<String>>[
                <String>['builtin', '内置 sh'],
                <String>['termux', 'Termux'],
                <String>['auto', 'root/Shizuku'],
              ])
                ChoiceChip(
                  label: Text(m[1], style: const TextStyle(fontSize: 11.5)),
                  selected: '${_args['mode'] ?? 'auto'}' == m[0],
                  onSelected: (_) => setState(() => _args['mode'] = m[0]),
                ),
            ],
          ),
          if (!privileged)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('选 root/Shizuku 时当前不可用，规则会报错而不是假装成功。',
                  style: TextStyle(
                      fontSize: 10.5,
                      color: cs.onSurface.withValues(alpha: 0.4))),
            ),
        ];
      case 'notify':
        return <Widget>[
          TextFormField(
            initialValue: '${_args['title'] ?? ''}',
            style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(
                labelText: '标题', isDense: true, border: OutlineInputBorder()),
            onChanged: (String v) => _args['title'] = v,
          ),
          const SizedBox(height: 10),
          TextFormField(
            initialValue: '${_args['body'] ?? ''}',
            maxLines: 3,
            style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(
                labelText: '正文',
                border: OutlineInputBorder(),
                alignLabelWithHint: true),
            onChanged: (String v) => _args['body'] = v,
          ),
        ];
      case 'device':
        final String current = '${_args['action'] ?? 'wifi_on'}';
        return <Widget>[
          DropdownButtonFormField<String>(
            value: current,
            isDense: true,
            style: TextStyle(fontSize: 13, color: cs.onSurface),
            decoration: const InputDecoration(
                labelText: '动作', isDense: true, border: OutlineInputBorder()),
            items: DeviceAction.all
                .map((DeviceAction a) => DropdownMenuItem<String>(
                      value: a.id,
                      child: Row(
                        children: <Widget>[
                          Text(a.zh, style: const TextStyle(fontSize: 12.5)),
                          if (DeviceAction.needsPrivilege(a.id))
                            Padding(
                              padding: const EdgeInsets.only(left: 6),
                              child: Icon(Icons.shield_outlined,
                                  size: 12,
                                  color: privileged
                                      ? cs.primary
                                      : cs.onSurface.withValues(alpha: 0.3)),
                            ),
                        ],
                      ),
                    ))
                .toList(),
            onChanged: (String? v) {
              if (v != null) setState(() => _args['action'] = v);
            },
          ),
          if (current == 'force_stop') ...<Widget>[
            const SizedBox(height: 10),
            TextFormField(
              initialValue: '${_args['package'] ?? ''}',
              style: const TextStyle(fontSize: 13),
              decoration: const InputDecoration(
                  labelText: '包名',
                  hintText: 'com.example.app',
                  isDense: true,
                  border: OutlineInputBorder()),
              onChanged: (String v) => _args['package'] = v,
            ),
          ],
          if (!privileged && DeviceAction.needsPrivilege(current))
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('这个动作需要 root 或 Shizuku，当前会失败。',
                  style: TextStyle(fontSize: 10.5, color: cs.error)),
            ),
        ];
      case 'a11y':
        final String rawOp = '${_args['op'] ?? 'click'}';
        final String op = A11yAction.all.any((A11yAction a) => a.id == rawOp)
            ? rawOp
            : 'click';
        final bool connected = app.a11y.connected;
        return <Widget>[
          DropdownButtonFormField<String>(
            value: op,
            isDense: true,
            style: TextStyle(fontSize: 13, color: cs.onSurface),
            decoration: const InputDecoration(
                labelText: '动作', isDense: true, border: OutlineInputBorder()),
            items: A11yAction.all
                .map((A11yAction a) => DropdownMenuItem<String>(
                      value: a.id,
                      child: Text(a.zh, style: const TextStyle(fontSize: 12.5)),
                    ))
                .toList(),
            onChanged: (String? v) {
              if (v != null) setState(() => _args['op'] = v);
            },
          ),
          if (A11yAction.needsText(op)) ...<Widget>[
            const SizedBox(height: 10),
            TextFormField(
              initialValue: '${_args['text'] ?? ''}',
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                labelText: op == 'input' ? '输入框的提示文字（可留空）' : '要操作的文字',
                hintText: op == 'input' ? '搜索' : '打卡',
                isDense: true,
                border: const OutlineInputBorder(),
              ),
              onChanged: (String v) => _args['text'] = v,
            ),
          ],
          if (A11yAction.needsValue(op)) ...<Widget>[
            const SizedBox(height: 10),
            TextFormField(
              initialValue: '${_args['value'] ?? ''}',
              style: const TextStyle(fontSize: 13),
              decoration: const InputDecoration(
                labelText: '要输入的内容',
                hintText: '可以用 {text} 取通知正文',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (String v) => _args['value'] = v,
            ),
          ],
          if (op == 'click' || op == 'long_click') ...<Widget>[
            const SizedBox(height: 10),
            TextFormField(
              initialValue: '${_args['index'] ?? 0}',
              keyboardType: TextInputType.number,
              style: const TextStyle(fontSize: 13),
              decoration: const InputDecoration(
                labelText: '第几个匹配（从 0 数，默认 0）',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (String v) =>
                  _args['index'] = int.tryParse(v.trim()) ?? 0,
            ),
          ],
          const SizedBox(height: 8),
          Text(
            connected
                ? '按屏幕上的文字找元素，不看坐标，换机型也能用。'
                : '无障碍服务没开，这个动作会报错。先到自动化页顶部开启。',
            style: TextStyle(
                fontSize: 10.5,
                height: 1.4,
                color: connected
                    ? cs.onSurface.withValues(alpha: 0.45)
                    : cs.error),
          ),
        ];
      case 'speak':
        return <Widget>[
          TextFormField(
            initialValue: '${_args['text'] ?? ''}',
            maxLines: 3,
            minLines: 2,
            style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(
              labelText: '读什么',
              hintText: '构建完成了，可以收工',
              border: OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
            onChanged: (String v) => _args['text'] = v,
          ),
        ];
      case 'clipboard':
        return <Widget>[
          TextFormField(
            initialValue: '${_args['text'] ?? ''}',
            maxLines: 4,
            minLines: 2,
            style: const TextStyle(fontSize: 12.5),
            decoration: const InputDecoration(
              labelText: '复制什么',
              hintText: '{text}',
              helperText: '支持 {app} {title} {text} {time} {battery} {ssid}',
              border: OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
            onChanged: (String v) => _args['text'] = v,
          ),
        ];
      case 'open_app':
        return <Widget>[
          TextFormField(
            initialValue: '${_args['package'] ?? ''}',
            style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(
              labelText: '包名或应用名',
              hintText: 'com.tencent.mm / 微信',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            onChanged: (String v) => _args['package'] = v,
          ),
        ];
      case 'delay':
        return <Widget>[
          TextFormField(
            initialValue: '${_args['seconds'] ?? 5}',
            keyboardType: TextInputType.number,
            style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(
              labelText: '等多少秒（1–300）',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            onChanged: (String v) =>
                _args['seconds'] = int.tryParse(v.trim()) ?? 5,
          ),
        ];
      case 'webhook':
        return <Widget>[
          TextFormField(
            initialValue: '${_args['url'] ?? ''}',
            style: const TextStyle(fontSize: 12.5),
            decoration: const InputDecoration(
                labelText: 'URL',
                hintText: 'https://example.com/hook',
                isDense: true,
                border: OutlineInputBorder()),
            onChanged: (String v) => _args['url'] = v,
          ),
          const SizedBox(height: 10),
          TextFormField(
            initialValue: '${_args['body'] ?? '{}'}',
            maxLines: 3,
            style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            decoration: const InputDecoration(
                labelText: 'JSON 正文',
                border: OutlineInputBorder(),
                alignLabelWithHint: true),
            onChanged: (String v) => _args['body'] = v,
          ),
        ];
      default:
        return const <Widget>[];
    }
  }
}

// ------------------------------------------------------------------ misc

class _SheetHandle extends StatelessWidget {
  const _SheetHandle();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 34,
        height: 3.5,
        margin: const EdgeInsets.only(bottom: 12, top: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(4),
          color:
              Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.18),
        ),
      ),
    );
  }
}

class _LogSheet extends StatelessWidget {
  const _LogSheet({required this.engine});

  final AutomationEngine engine;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      builder: (BuildContext ctx, ScrollController scroll) {
        return ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
          children: <Widget>[
            const _SheetHandle(),
            Row(
              children: <Widget>[
                const Text('运行记录',
                    style:
                        TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                const Spacer(),
                if (engine.logs.isNotEmpty)
                  TextButton(
                    onPressed: () {
                      engine.clearLogs();
                      Navigator.pop(ctx);
                    },
                    child: const Text('清空', style: TextStyle(fontSize: 12)),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            if (engine.logs.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text('还没有执行记录。',
                    style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurface.withValues(alpha: 0.45))),
              ),
            ...engine.logs.map((AutomationLog l) => Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    color: cs.surfaceVariant.withValues(alpha: 0.35),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Icon(
                            l.ok
                                ? Icons.check_circle_outline_rounded
                                : Icons.error_outline_rounded,
                            size: 14,
                            color: l.ok ? cs.primary : cs.error,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(l.ruleName,
                                style: const TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600)),
                          ),
                          Text(_time(l.at),
                              style: TextStyle(
                                  fontSize: 10,
                                  color: cs.onSurface.withValues(alpha: 0.4))),
                        ],
                      ),
                      if (l.detail.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 5),
                        Text(
                          l.detail.length > 400
                              ? '${l.detail.substring(0, 400)}…'
                              : l.detail,
                          style: TextStyle(
                              fontSize: 11,
                              height: 1.45,
                              color: cs.onSurface.withValues(alpha: 0.55)),
                        ),
                      ],
                    ],
                  ),
                )),
          ],
        );
      },
    );
  }

  static String _time(DateTime at) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(at.month)}-${two(at.day)} ${two(at.hour)}:${two(at.minute)}';
  }
}
