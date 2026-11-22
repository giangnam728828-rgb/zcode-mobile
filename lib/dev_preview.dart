// Developer-only entrypoint used for visual checks in a browser at phone
// sizes. It is not referenced by main.dart and never ships in the APK.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'agent/tools.dart';
import 'models/app_config.dart';
import 'models/attachment.dart';
import 'models/chat_message.dart';
import 'models/conversation.dart';
import 'pages/home_shell.dart';
import 'pages/automation_page.dart';
import 'pages/login_page.dart';
import 'pages/modules_page.dart';
import 'pages/plugins_page.dart';
import 'pages/settings_page.dart';
import 'pages/terminal_page.dart';
import 'pages/workspace_picker_page.dart';
import 'platform/a11y_bridge.dart';
import 'platform/privilege_bridge.dart';
import 'services/automation.dart';
import 'services/plugins.dart';
import 'state/app_state.dart';
import 'theme/app_theme.dart';

Widget _pageFor(String? page) {
  switch (page) {
    case 'modules':
      return const ModulesPage();
    case 'automation':
      return const AutomationPage();
    case 'terminal':
      return const TerminalPage();
    case 'plugins':
      return const PluginsPage();
    case 'settings':
      return const SettingsPage();
    case 'workspace':
      return const WorkspacePickerPage();
    case 'login':
      return const LoginPage();
    default:
      return HomeShell(
        initialTab: int.tryParse(Uri.base.queryParameters['tab'] ?? '') ?? 0,
      );
  }
}

void main() {
  final bool light = Uri.base.queryParameters['light'] == '1';
  final bool empty = Uri.base.queryParameters['empty'] == '1';
  final AppState state = AppState();
  state.config = AppConfig.empty.copyWith(model: 'glm-4.6');
  state.config = state.config!.copyWith(glassQuality: 'full');
  // The web preview has no real workspace, but the market tab is pure catalog.
  state.pluginCenter = PluginCenter(null);
  state.automation = AutomationEngine(
    runner: (AutomationRule r, AutomationAction a) async => 'ok',
  );
  state.automation!.rules.addAll(
    AutomationTemplates.market().take(4).map((AutomationRule r) =>
        AutomationRule(
          id: r.id,
          name: r.name,
          trigger: r.trigger,
          actions: r.actions,
          enabled: r.id != 'tpl-unlock-brief',
          lastRunMs: r.id == 'builtin-nightly'
              ? DateTime.now()
                  .subtract(const Duration(hours: 13))
                  .millisecondsSinceEpoch
              : 0,
          runCount: r.id == 'builtin-nightly' ? 6 : 0,
          lastResult: r.id == 'builtin-nightly'
              ? '今天主要改了工作区切换与 Termux 桥接；明天接着补自动化。'
              : '',
        )),
  );
  PrivilegeBridge.debugSetStatus(const PrivStatus(
    root: true,
    shizuku: true,
    shizukuGranted: true,
    channel: 'root',
    notifications: true,
    writeSettings: true,
    dndAccess: true,
    accessibility: true,
    a11yConnected: true,
    notificationListener: true,
  ));
  A11yBridge.debugSetStatus(const A11yStatus(
    enabled: true,
    connected: true,
    notificationListener: true,
    foreground: 'com.tencent.mm',
    foregroundLabel: '微信',
  ));
  state.privilege = PrivilegeBridge.status;
  final Conversation c = Conversation(id: 'demo', title: '整理工作区并补文档');

  final ToolCall bash = ToolCall(
    id: 'b1',
    name: 'bash',
    input: <String, dynamic>{'command': 'ls -la && wc -l src/*.dart'},
    output: 'total 32\n'
        'drwx------  5 u0_a123  u0_a123  4096 Nov 21 03:12 .\n'
        'drwx------  3 u0_a123  u0_a123  4096 Nov 21 03:10 ..\n'
        '-rw-r--r--  1 u0_a123  u0_a123   842 Nov 20 22:04 README.md\n'
        'drwxr-xr-x  2 u0_a123  u0_a123  4096 Nov 21 02:55 src\n'
        '\n[exit 0]',
    status: ToolStatus.done,
    startedAt: DateTime.now().subtract(const Duration(milliseconds: 780)),
    endedAt: DateTime.now(),
  );
  final ToolCall plan = ToolCall(
    id: 'p1',
    name: 'todo_write',
    input: <String, dynamic>{
      'todos': <Map<String, dynamic>>[
        <String, dynamic>{'content': '浏览工作区结构', 'status': 'completed'},
        <String, dynamic>{'content': '补全 README 的启动与目录说明', 'status': 'completed'},
        <String, dynamic>{'content': '跑一次 flutter analyze 验证', 'status': 'in_progress'},
        <String, dynamic>{'content': '汇总改动', 'status': 'pending'},
      ],
    },
    output: '[x] 浏览工作区结构\n[x] 补全 README\n[~] flutter analyze\n[ ] 汇总改动\n\n2/4 completed',
    status: ToolStatus.done,
  );

  c.messages.addAll(<ChatMessage>[
    ChatMessage(
      id: 'u1',
      role: Sender.user,
      text: '看看工作区里有什么，然后帮我补一个 README',
      attachments: <Attachment>[
        const Attachment(
          path: 'src/main.dart',
          name: 'main.dart',
          isImage: false,
          size: 2480,
        ),
      ],
      inputTokens: 1240,
      outputTokens: 0,
    ),
    ChatMessage(
      id: 'a1',
      role: Sender.assistant,
      thinking: '先列目录，确认项目结构，再决定 README 要写哪些章节。',
      text: '工作区里是一个很小的 Dart CLI：`src/main.dart` 是入口，'
          '`README.md` 已有标题但缺少启动说明。我补了安装、运行和目录结构三节。\n\n'
          '```bash\n'
          'dart pub get\n'
          'dart run bin/zcode.dart --help\n'
          '```\n\n'
          '改动集中在 README，没有动代码逻辑。',
      tools: <ToolCall>[bash, plan],
      inputTokens: 3120,
      outputTokens: 486,
    ),
    ChatMessage(
      id: 'u2',
      role: Sender.user,
      text: '顺便把「为什么这么设计」也写清楚，别只列命令。',
      inputTokens: 3180,
      outputTokens: 0,
    ),
    ChatMessage(
      id: 'a2',
      role: Sender.assistant,
      text: '已经在 README 里加了一节 **Design notes**，解释了为什么把工具执行放在'
          '应用私有工作区：\n\n'
          '1. 不需要存储权限，安装即用；\n'
          '2. 卸载应用时一起清理，不留残留；\n'
          '3. 模型只能看到你允许它看到的文件。\n\n'
          '另外把 `tree` 模块列进了可选依赖，第一次运行时用 `/modules` 安装即可。',
      inputTokens: 3700,
      outputTokens: 322,
    ),
  ]);

  if (empty) c.messages.clear();
  state.conversations.add(c);
  state.currentId = c.id;
  // `queue` is a getter that returns a fresh list, so `state.queue.add(...)`
  // would only touch a temporary. Queue through `send` instead: with streaming
  // on, that is the branch that appends.
  if (Uri.base.queryParameters['streaming'] == '1') {
    state.streaming = true;
    state.send('再补一个 LICENSE 段落');
    state.send('顺手更新一下 changelog');
    state.send('然后跑一遍 analyze');
  }
  state.ready = true;

  runApp(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.build(Accent.indigo.seed, Brightness.light, 1.0),
        darkTheme: AppTheme.build(Accent.indigo.seed, Brightness.dark, 1.0),
        themeMode: light ? ThemeMode.light : ThemeMode.dark,
        home: _pageFor(Uri.base.queryParameters['page']),
      ),
    ),
  );
}
