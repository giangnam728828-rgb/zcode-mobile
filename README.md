# ZCode Mobile

**装在手机里的 ZCode 智能体** —— 用平台账号登录（不填 API Key），登录后 Agent 能在手机本地**真跑 shell 命令、真改文件**，和桌面端共用同一份套餐额度。v3 补齐了文件管理、终端、扩展模块、回合撤销、上下文压缩与项目规则，交互按手机重做，不再是一个套壳网页。

<p align="center">
  <img src="docs/chat.png" width="190" alt="对话与工具">
  <img src="docs/tools.png" width="190" alt="计划与审批">
  <img src="docs/modules.png" width="190" alt="扩展模块">
</p>

> 社区非官方客户端，与智谱 / Z.ai 无隶属关系。Agent 只在应用私有工作区内执行，不碰系统其它数据。

## 安装

1. 到 [Releases](../../releases) 下载最新 `zcode-mobile.apk`
2. 允许「安装未知来源应用」后安装（Android 5.0+）
3. 打开后点「使用 BigModel 账号登录」或「使用 Z.ai 账号登录」，在浏览器里完成授权即可

新版本可直接覆盖安装（固定签名），会话与设置保留。

## 登录：账号授权，不贴 Key

流程与 ZCode 官方开源 CLI 一致（实现见 `lib/services/account.dart`）：

```
浏览器授权页  →  127.0.0.1 回跳带 authCode  →  POST zcode.z.ai/api/v1/oauth/token
             →  登录 JWT / BigModel access_token
             →  customerInfo → 专用 Key(zcode-api-key) → 换短期 Project Token
             →  模型请求携带 Project Token（消耗你账号里的套餐）
```

- **密码只在浏览器里输入**，App 只保存令牌；
- 令牌存在 **Android Keystore**（`flutter_secure_storage`），不落明文、不进日志；
- Project Token 过期前自动续签，长会话不会中途断；
- 回调走本机 `127.0.0.1` 随机端口，不需要扫码、不需要填远程链接、不依赖电脑开机。

## Agent：真的会在手机上干活

内置 12 个工具，走 Anthropic 兼容的 `tool_use` / `tool_result` 循环：

| 工具 | 能力 |
|---|---|
| `bash` | `sh` + toybox：ls / cat / grep / sed / find / tar…，可跑脚本；PATH 自动带上已装模块 |
| `read_file` | 按行读取，带 offset / limit，二进制与超大文件会被拦下 |
| `write_file` | 新建或覆盖（自动建目录），写前自动做快照 |
| `edit_file` | 精确替换一段内容，重复匹配会拒绝 |
| `list_dir` | 列目录，带文件大小，目录优先 |
| `glob` | `*` / `?` / `**` 模式找文件 |
| `grep` | 正则搜索，支持 glob 过滤、跳过 `.git` 与二进制 |
| `make_dir` | 递归建目录 |
| `move_file` | 移动 / 重命名，目标已存在会拒绝 |
| `delete_file` | 删除文件；非空目录需显式 `recursive` |
| `web_fetch` | 抓 http(s) 页面/接口，HTML 转可读文本 |
| `todo_write` | 发布任务清单，手机上直接渲染成带进度的计划卡 |

安全与掌控：

- 工作区固定在应用私有目录（`/data/data/ai.zcode.zcode_mobile/files/workspace`），`..` 越权路径会被规范化后拒绝（有测试覆盖）；
- **审批三档**：`risky`（默认，删除 / 移动 / 破坏性 shell 才问）、`ask`（每个工具都问）、`auto`（全放开）；
- 审批弹窗显示完整命令或 diff 行数，拒绝后模型收到 denied，不会偷偷执行；
- **回合撤销**：写文件前自动快照，`/undo` 或菜单「撤销本轮改动」可把整轮改动还原（新建的文件会被删掉）；
- 每次调用在对话里是一张卡片：命令、输出、退出码、耗时，长输出可展开、可复制。

## 与桌面版的功能对照

详细矩阵见 [`docs/PARITY.md`](docs/PARITY.md)。一句话版本：

| 能力 | 手机版 |
|---|---|
| 账号登录、共用套餐 | ✅ OAuth + Project Token |
| 流式对话、思考过程、多会话 | ✅ |
| 读写文件 / shell / 搜索 / 抓网页 | ✅ 12 个工具 |
| 计划清单（todo） | ✅ 计划卡实时打勾 |
| 文件树与编辑器 | ✅ 新建 / 重命名 / 删除 / 预览图片 |
| 终端 | ✅ 独立终端页，与 Agent 同一 PATH |
| 项目规则 `AGENTS.md`、`.zcode/skills` | ✅ 每轮自动注入 |
| 上下文压缩 | ✅ 自动 + `/compact`，摘要可见可清 |
| 回合撤销 | ✅ 文件级快照 |
| MCP / 子智能体 / 桌面级插件 | ⏳ 见路线图 |
| Node / Python / git 运行时 | ⏳ 用扩展模块或自带静态二进制 |

## 手机端交互

- **输入**：`/` 弹命令面板，`@` 补全工作区文件并把内容随消息附上；图片会作为 image block 直传模型；
- **发送**：生成中继续输入会排队（带附件），可「立即发送」或清空队列；空输入时按钮变停止；
- **阅读**：倒序列表 + 吸底滚动、上滑自动脱离、右下角回到底部、长会话只渲染最近 30 条并可「加载更早」；
- **消息**：复制 / 引用 / 编辑重发 / 重生成 / 删除，代码块带语言标签与复制，思考过程默认折叠；
- **用量**：每条回答下方显示 in/out token，顶部显示当前上下文估算；上下文过长会自动折叠早期消息；
- **流畅度**：流式文本按 16ms 合帧、完成后一次性走 Markdown、消息级缓存 + `RepaintBoundary`，滚动不抖。

命令：`/new` `/clear` `/compact` `/undo` `/model` `/files` `/terminal` `/modules` `/export` `/settings` `/help`。

## 扩展模块

手机上没有 Node / Python / git，v3 的做法是**按需安装小工具**，全部落在工作区，不需要 root：

| 内置 | 作用 |
|---|---|
| `tree` | 树形列目录 |
| `peek` | 行数 / 大小 + 头尾预览，查日志 |
| `findtext` | 递归搜索，自动跳过 `.git` |
| `space` | 按体积列目录占用 |
| `sysinfo` | 内核、运行时、磁盘摸底 |

也可以从链接安装 `tar.gz` / `tgz` / `zip`：压缩包里的 `bin/` 目录会被注册进 PATH，Agent 和终端立刻可用；一键卸载。

## 其他

- **会话**：多会话、自动标题、置顶、归档、搜索、重命名、复制、删除
- **外观**：5 套主色、亮 / 暗 / 跟随系统、4 档字号、中英双语
- **端侧**：自适应图标、品牌闪屏、状态栏配色、横竖屏、键盘避让

## 自己构建

需要 Flutter 3.0.x（Dart 2.17）、JDK 11、Android SDK 33。

```bash
flutter pub get
flutter analyze && flutter test
flutter build apk --release
```

CI **只在打 tag 或手动触发时构建**（`workflow_dispatch`），日常 push 不会消耗 Actions 额度。

签名：CI 从 Secrets（`ANDROID_KEYSTORE_BASE64` / `ANDROID_STORE_PASSWORD` / `ANDROID_KEY_ALIAS` / `ANDROID_KEY_PASSWORD`）还原 `android/key.properties`；缺 Secret 直接失败，构建后再校验证书指纹。固定密钥 SHA-256：

```
32:0B:A9:4F:FD:6A:CB:DD:2B:C2:1A:85:2C:4B:69:C0:F3:67:1B:8C:35:BE:27:E2:B9:A8:0C:71:53:C4:9F:4A
```

## 目录

```
lib/
  services/account.dart     OAuth 登录、Project Token 签发与续期、Keystore 存储
  services/modules.dart     扩展模块目录、下载解压、PATH 注入
  agent/tools.dart          工作区沙箱、12 个工具、回合快照
  agent/agent_runner.dart   流式 tool_use 循环、审批、usage、断线重试
  agent/commands.dart       斜杠命令定义
  state/app_state.dart      会话、回合、队列、压缩、撤销、附件
  pages/files_page.dart     文件浏览 + 编辑器 + 图片预览
  pages/terminal_page.dart  终端
  pages/modules_page.dart   扩展模块管理
  widgets/composer.dart     命令/文件补全、附件、引用、队列
  widgets/tool_card.dart    工具卡与计划卡
docs/RESEARCH.md            12 个同类项目的对比与取舍
docs/PARITY.md              与桌面版 ZCode 的能力对照
lib/dev_preview.dart        仅用于浏览器/真机视觉检查的演示入口（不参与 APK）
```

## 已验证

- `flutter analyze` → **No issues found**
- `flutter test` → **22/22 通过**，覆盖：
  - 假模型服务端跑通完整闭环：`bash` 真执行、`tool_result` 回传、拒绝审批不落盘、越权路径被拦；
  - `glob` / `grep` / `mkdir` / `move` / `delete` / `todo_write` 的行为；
  - 回合快照：新建文件被删、改过的文件内容还原；
  - 内置模块安装后脚本落盘、重启后仍注册、卸载清理；
  - 输入框的 `/` 命令与 `@` 文件补全；
  - 计划卡渲染。

## 路线图

- [ ] 运行时模块：按 ABI 下载 node / python / git 的静态构建（目前用扩展模块补 shell 工具）
- [ ] MCP（HTTP / stdio）与项目级工具注册
- [ ] 语音输入与图片 OCR
- [ ] 屏幕操作（无障碍 / 虚拟显示）

## 免责声明

- 非官方客户端。账号登录与模型调用遵循平台公开接口，但长期使用请自行评估服务条款与风控风险。
- Agent 会真的执行命令，`auto` 模式请谨慎开启。
- 与智谱、Z.ai、DeepSeek、DSH Go 等均无隶属关系。

## License

MIT
