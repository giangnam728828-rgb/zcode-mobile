/// Slash commands offered in the composer. Keeping them declarative means the
/// picker, the help sheet and the submit handler never drift apart.
class SlashCommand {
  const SlashCommand({
    required this.name,
    required this.usage,
    required this.zh,
    required this.en,
    this.takesArg = false,
  });

  final String name;
  final String usage;
  final String zh;
  final String en;
  final bool takesArg;
}

const List<SlashCommand> kSlashCommands = <SlashCommand>[
  SlashCommand(name: 'new', usage: '/new', zh: '新建会话', en: 'New chat'),
  SlashCommand(name: 'clear', usage: '/clear', zh: '清空当前会话', en: 'Clear chat'),
  SlashCommand(
      name: 'compact',
      usage: '/compact',
      zh: '压缩早期上下文',
      en: 'Compact context'),
  SlashCommand(
      name: 'undo',
      usage: '/undo',
      zh: '撤销本轮文件改动',
      en: 'Undo file changes'),
  SlashCommand(
      name: 'automation',
      usage: '/automation',
      zh: '打开自动化规则',
      en: 'Automation rules'),
  SlashCommand(
      name: 'workspace',
      usage: '/workspace',
      zh: '切换工作区文件夹',
      en: 'Switch workspace folder'),
  SlashCommand(name: 'files', usage: '/files', zh: '打开文件管理', en: 'Files'),
  SlashCommand(name: 'terminal', usage: '/terminal', zh: '打开终端', en: 'Terminal'),
  SlashCommand(name: 'modules', usage: '/modules', zh: '扩展模块', en: 'Modules'),
  SlashCommand(
      name: 'plugins', usage: '/plugins', zh: '插件市场', en: 'Plugins'),
  SlashCommand(
      name: 'model',
      usage: '/model <id>',
      zh: '切换模型',
      en: 'Switch model',
      takesArg: true),
  SlashCommand(
      name: 'settings', usage: '/settings', zh: '打开设置', en: 'Settings'),
  SlashCommand(
      name: 'export', usage: '/export', zh: '导出会话为 Markdown', en: 'Export chat'),
  SlashCommand(name: 'help', usage: '/help', zh: '查看命令说明', en: 'Commands'),
];

SlashCommand? findCommand(String name) {
  for (final SlashCommand c in kSlashCommands) {
    if (c.name == name) return c;
  }
  return null;
}
