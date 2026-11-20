/// Minimal two-language string table. Chosen over generated l10n to keep the
/// build free of codegen while still covering every visible label.
class S {
  const S({
    required this.appName,
    required this.tagline,
    required this.sessions,
    required this.newChat,
    required this.searchHint,
    required this.pinned,
    required this.today,
    required this.yesterday,
    required this.last7,
    required this.earlier,
    required this.archived,
    required this.showArchived,
    required this.hideArchived,
    required this.rename,
    required this.pin,
    required this.unpin,
    required this.archive,
    required this.unarchive,
    required this.delete,
    required this.deleteConfirm,
    required this.deleteChatConfirm,
    required this.cancel,
    required this.ok,
    required this.noResults,
    required this.welcomeTitle,
    required this.welcomeSub,
    required this.ex1,
    required this.ex2,
    required this.ex3,
    required this.inputHint,
    required this.stop,
    required this.queued,
    required this.sendNow,
    required this.clearQueue,
    required this.thinking,
    required this.copy,
    required this.copied,
    required this.regenerate,
    required this.editResend,
    required this.stopped,
    required this.emptyReply,
    required this.settings,
    required this.account,
    required this.provider,
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    required this.custom,
    required this.advanced,
    required this.systemPrompt,
    required this.maxTokens,
    required this.appearance,
    required this.theme,
    required this.themeSystem,
    required this.themeLight,
    required this.themeDark,
    required this.accent,
    required this.fontSize,
    required this.language,
    required this.dataSection,
    required this.exportConfig,
    required this.importConfig,
    required this.exportHint,
    required this.importHint,
    required this.shareChat,
    required this.clearChat,
    required this.clearAll,
    required this.clearAllConfirm,
    required this.about,
    required this.disclaimer,
    required this.start,
    required this.keyHint,
    required this.importInstead,
    required this.needKey,
    required this.importFail,
    required this.importOk,
    required this.saved,
    required this.newChatShort,
    required this.sessionsCount,
    required this.tokensNote,
  });

  final String appName;
  final String tagline;
  final String sessions;
  final String newChat;
  final String searchHint;
  final String pinned;
  final String today;
  final String yesterday;
  final String last7;
  final String earlier;
  final String archived;
  final String showArchived;
  final String hideArchived;
  final String rename;
  final String pin;
  final String unpin;
  final String archive;
  final String unarchive;
  final String delete;
  final String deleteConfirm;
  final String deleteChatConfirm;
  final String cancel;
  final String ok;
  final String noResults;
  final String welcomeTitle;
  final String welcomeSub;
  final String ex1;
  final String ex2;
  final String ex3;
  final String inputHint;
  final String stop;
  final String queued;
  final String sendNow;
  final String clearQueue;
  final String thinking;
  final String copy;
  final String copied;
  final String regenerate;
  final String editResend;
  final String stopped;
  final String emptyReply;
  final String settings;
  final String account;
  final String provider;
  final String baseUrl;
  final String apiKey;
  final String model;
  final String custom;
  final String advanced;
  final String systemPrompt;
  final String maxTokens;
  final String appearance;
  final String theme;
  final String themeSystem;
  final String themeLight;
  final String themeDark;
  final String accent;
  final String fontSize;
  final String language;
  final String dataSection;
  final String exportConfig;
  final String importConfig;
  final String exportHint;
  final String importHint;
  final String shareChat;
  final String clearChat;
  final String clearAll;
  final String clearAllConfirm;
  final String about;
  final String disclaimer;
  final String start;
  final String keyHint;
  final String importInstead;
  final String needKey;
  final String importFail;
  final String importOk;
  final String saved;
  final String newChatShort;
  final String sessionsCount;
  final String tokensNote;

  static const S zh = S(
    appName: 'ZCode',
    tagline: '装在手机里的编程智能体',
    sessions: '会话',
    newChat: '新建会话',
    searchHint: '搜索会话',
    pinned: '已置顶',
    today: '今天',
    yesterday: '昨天',
    last7: '最近 7 天',
    earlier: '更早',
    archived: '已归档',
    showArchived: '显示归档',
    hideArchived: '隐藏归档',
    rename: '重命名',
    pin: '置顶',
    unpin: '取消置顶',
    archive: '归档',
    unarchive: '取消归档',
    delete: '删除',
    deleteConfirm: '确定删除这条消息？',
    deleteChatConfirm: '删除后无法恢复，确定删除这个会话？',
    cancel: '取消',
    ok: '确定',
    noResults: '没有匹配的会话',
    welcomeTitle: '今天想写点什么？',
    welcomeSub: '直连 GLM，与桌面端共用同一份 Token 和额度。',
    ex1: '用 Python 写一个 LRU 缓存',
    ex2: '这段报错怎么修？',
    ex3: '帮我设计一个 REST API',
    inputHint: '给 ZCode 发消息…',
    stop: '停止',
    queued: '排队中',
    sendNow: '立即发送',
    clearQueue: '清空队列',
    thinking: '思考过程',
    copy: '复制',
    copied: '已复制',
    regenerate: '重新生成',
    editResend: '编辑并重发',
    stopped: '已停止',
    emptyReply: '（无内容返回）',
    settings: '设置',
    account: '账号与模型',
    provider: '服务商',
    baseUrl: '接口地址',
    apiKey: 'API Key',
    model: '模型',
    custom: '自定义',
    advanced: '高级',
    systemPrompt: '系统提示词',
    maxTokens: '最大输出 token',
    appearance: '外观',
    theme: '主题',
    themeSystem: '跟随系统',
    themeLight: '浅色',
    themeDark: '深色',
    accent: '主色',
    fontSize: '字号',
    language: '语言',
    dataSection: '数据',
    exportConfig: '导出配置',
    importConfig: '导入配置',
    exportHint: '复制这串文本，在另一台设备上粘贴导入，即可共用同一份 Token。',
    importHint: '粘贴从另一台设备导出的配置串',
    shareChat: '导出为 Markdown',
    clearChat: '清空当前会话',
    clearAll: '清空全部数据',
    clearAllConfirm: '将删除所有会话和设置，且无法恢复。',
    about: '关于',
    disclaimer: '社区非官方客户端，与智谱 / Z.ai 无隶属关系。仅直连官方 API，请遵守服务条款。',
    start: '开始使用',
    keyHint: '粘贴 GLM Coding Plan 的 API Key',
    importInstead: '已有配置？粘贴导入',
    needKey: '先填写 API Key 才能开始。',
    importFail: '配置无法识别，请检查是否完整复制。',
    importOk: '配置已导入',
    saved: '已保存',
    newChatShort: '新会话',
    sessionsCount: '个会话',
    tokensNote: 'Coding Plan 官方限定在其列出的工具中使用，第三方客户端直连有被限流的可能。',
  );

  static const S en = S(
    appName: 'ZCode',
    tagline: 'A coding agent in your pocket',
    sessions: 'Chats',
    newChat: 'New chat',
    searchHint: 'Search chats',
    pinned: 'Pinned',
    today: 'Today',
    yesterday: 'Yesterday',
    last7: 'Previous 7 days',
    earlier: 'Earlier',
    archived: 'Archived',
    showArchived: 'Show archived',
    hideArchived: 'Hide archived',
    rename: 'Rename',
    pin: 'Pin',
    unpin: 'Unpin',
    archive: 'Archive',
    unarchive: 'Unarchive',
    delete: 'Delete',
    deleteConfirm: 'Delete this message?',
    deleteChatConfirm: 'This chat will be gone for good. Delete it?',
    cancel: 'Cancel',
    ok: 'OK',
    noResults: 'No matching chats',
    welcomeTitle: 'What are we building?',
    welcomeSub: 'Talks to GLM directly, sharing the same token and quota as desktop.',
    ex1: 'Write an LRU cache in Python',
    ex2: 'Why does this error happen?',
    ex3: 'Design a REST API for me',
    inputHint: 'Message ZCode…',
    stop: 'Stop',
    queued: 'Queued',
    sendNow: 'Send now',
    clearQueue: 'Clear queue',
    thinking: 'Thinking',
    copy: 'Copy',
    copied: 'Copied',
    regenerate: 'Regenerate',
    editResend: 'Edit & resend',
    stopped: 'Stopped',
    emptyReply: '(empty reply)',
    settings: 'Settings',
    account: 'Account & model',
    provider: 'Provider',
    baseUrl: 'Base URL',
    apiKey: 'API key',
    model: 'Model',
    custom: 'Custom',
    advanced: 'Advanced',
    systemPrompt: 'System prompt',
    maxTokens: 'Max output tokens',
    appearance: 'Appearance',
    theme: 'Theme',
    themeSystem: 'System',
    themeLight: 'Light',
    themeDark: 'Dark',
    accent: 'Accent',
    fontSize: 'Text size',
    language: 'Language',
    dataSection: 'Data',
    exportConfig: 'Export config',
    importConfig: 'Import config',
    exportHint: 'Copy this string and paste it on another device to share the same token.',
    importHint: 'Paste the config string from another device',
    shareChat: 'Export as Markdown',
    clearChat: 'Clear this chat',
    clearAll: 'Erase all data',
    clearAllConfirm: 'All chats and settings will be deleted permanently.',
    about: 'About',
    disclaimer: 'Unofficial community client, not affiliated with Zhipu / Z.ai. Talks to the official API only.',
    start: 'Get started',
    keyHint: 'Paste your GLM Coding Plan API key',
    importInstead: 'Already set up? Import',
    needKey: 'An API key is required.',
    importFail: 'Unrecognised config. Make sure it was copied in full.',
    importOk: 'Config imported',
    saved: 'Saved',
    newChatShort: 'New',
    sessionsCount: 'chats',
    tokensNote: 'Coding Plan is licensed for the tools listed by the vendor; third-party clients may be rate-limited.',
  );

  static S of(String? lang) => lang == 'en' ? en : zh;
}
