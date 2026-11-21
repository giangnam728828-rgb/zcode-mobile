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

## 工作区：就是你手机上的那个文件夹

桌面版让你 `cd` 进项目；手机版也一样，只是这个目录由你在手机上挑。

**设置 → 工作区文件夹** 打开目录浏览器：内部存储、SD 卡、`Download`、`Documents` 都在里面，可以逐级进入、新建文件夹，也可以直接输路径。选中之后：

- 文件管理器、相册、其他 App 打开的就是同一批文件，卸载 App 也不会删掉你的项目；
- 终端和智能体用的都是这个绝对路径，没有「虚拟文件系统」这层；
- 每个项目一个工作区，随时在设置里切换，最近的 8 个会记住。

首次使用会提示授予**所有文件访问权限**（Android 11+ 的系统叫法；10 及以下为存储权限）。没有它，App 只能看到自己的私有目录。授权入口就在选择页顶部，点「去授权」跳到系统设置，回来会自动重新检测。

工作区里会自动建好这些：

```
<你的文件夹>/
  README.md              首次创建时的说明
  .zcode/bin/            放你自己的脚本，终端里按名字就能调用
  .zcode/skills/         技能（装插件时写入）
  .zcode/commands/       自定义斜杠命令
  .zcode/agents/         子智能体人设
  .zcode/modules/        扩展模块
  .zcode/backups/        回合快照，供 /undo 还原
  .tmp/                  命令临时目录
```

路径规则：相对路径以工作区为根；绝对路径在获得文件权限后可以读写 `/storage/**`（手机上的其他文件夹），其余系统目录仍会被拒绝——`..` 也不能穿出去，这部分有测试覆盖。

## Agent：真的会在手机上干活

内置 14 个工具，走 Anthropic 兼容的 `tool_use` / `tool_result` 循环；装插件后还会多出 MCP 工具：

| 工具 | 能力 |
|---|---|
| `bash` | `sh` + toybox：ls / cat / grep / sed / find / tar…，可跑脚本；支持 `cwd`，PATH 依次为 `.zcode/bin` → 模块 → 系统 |
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
| `task` | 把独立子任务交给子智能体，它用自己的上下文干活，只回传结论 |
| `device` | 把手机当手机用：通知、剪贴板、震动、打开应用、电量、音量；root / Shizuku 下再加系统开关、截屏、点击滑动、强制停止、装包授权 |

安全与掌控：

- 工作区是你在手机上选的文件夹（默认 `内部存储/ZCode`），不是沙箱副本；`..` 越权路径会被规范化后拒绝，绝对路径仅在授权后放行 `/storage/**`（有测试覆盖）；
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
| 读写文件 / shell / 搜索 / 抓网页 | ✅ 13 个工具 |
| 计划清单（todo） | ✅ 计划卡实时打勾 |
| 文件树与编辑器 | ✅ 新建 / 重命名 / 删除 / 预览图片 |
| 终端 | ✅ 独立终端页，与 Agent 同一 PATH，支持 `cd` |
| 项目规则 `AGENTS.md`、`.zcode/skills` | ✅ 每轮自动注入 |
| 上下文压缩 | ✅ 自动 + `/compact`，摘要可见可清 |
| 回合撤销 | ✅ 文件级快照 |
| MCP 服务 | ✅ HTTP / stdio，工具自动注入 |
| 子智能体 | ✅ `task` 工具 + `.zcode/agents` |
| 插件市场 | ✅ 16 款内置，支持从链接装 |
| 工作区位置 | ✅ 手机真实文件夹，可随时切换 |
| Node / Python / git 运行时 | ✅ Termux 桥：同一目录，完整工具链 |
| 自动化（定时 / 电量 / 通知 / 前台应用 / 屏幕文字 / 息屏） | ✅ 规则引擎 + 一句话建规则 + 运行记录 + 13 个模板 |
| 无障碍（免 root） | ✅ 读屏、按文字点按、输入、滚动、全局动作、前台应用上报 |
| 通知读取 | ✅ 通知触发 + `{app}` `{title}` `{text}` 变量 |
| root / Shizuku 提权 | ✅ 系统开关、截屏、模拟点击、pm/svc/cmd |
| 通知、剪贴板、震动、打开应用 | ✅ 普通权限即可 |
| 桌面快捷方式 / 分享接收 | ✅ 长按图标直达自动化；其他 App 分享文本给 ZCode |

## 手机端交互

- **导航**：底部悬浮玻璃 Dock 四项——对话 / 文件 / 终端 / 设置，切页保状态（草稿、滚动位置都不丢）；**自动化、扩展模块、插件在设置页里**，自动化排在最上方一张卡；
- **输入**：`/` 弹命令面板，`@` 补全工作区文件并把内容随消息附上；图片会作为 image block 直传模型；
- **发送**：生成中继续输入会排队（带附件），可「立即发送」或清空队列；空输入时按钮变停止；
- **阅读**：倒序列表 + 吸底滚动、上滑自动脱离、右下角回到底部、长会话只渲染最近 30 条并可「加载更早」；
- **消息**：复制 / 引用 / 编辑重发 / 重生成 / 删除，代码块带语言标签与复制，思考过程默认折叠；
- **用量**：每条回答下方显示 in/out token，顶部显示当前上下文估算；上下文过长会自动折叠早期消息；
- **流畅度**：流式文本按 16ms 合帧、完成后一次性走 Markdown、消息级缓存 + `RepaintBoundary`，滚动不抖。

命令：`/new` `/clear` `/compact` `/undo` `/model` `/automation` `/files` `/terminal` `/modules` `/plugins` `/export` `/settings` `/help`，外加插件提供的命令。

## 在手机上真的跑命令

终端页有两种执行方式，右下角切换到哪一种就用哪一种：

| 模式 | 跑什么 | 说明 |
|---|---|---|
| 内置 sh（默认） | `sh` + toybox + `.zcode/bin` + 已装模块 | 秒开，不依赖外部 App |
| Termux 模式 | node、python、git、npm、pip、cargo… | 命令交给 Termux 执行，输出回传到终端 |

为什么 node/python 要走 Termux：Android 10 起禁止从「应用可写目录」执行二进制（W^X），自带一个 150MB 的运行时也跑不起来。Termux 有自己的 prefix，是官方允许的路子，而且和 ZCode 共享同一个工作区文件夹——所以 `npm run build` 的结果，在 ZCode 的文件页里立刻能看到。

准备一次即可：

```bash
# 在 Termux 里
pkg install nodejs python git
echo "allow-external-apps=true" >> ~/.termux/termux.properties
termux-reload-settings
```

之后在终端页点亮右上角的闪电图标，`git status`、`node -v`、`python main.py` 都能直接跑。工作区若在应用私有目录（Termux 访问不到），会明确提示你切到内部存储。

脚本放 `.zcode/bin` 后可以直接按名字调用，但有一点要注意：Android 把 `/sdcard` 以 **noexec** 挂载，里面的 `.sh` 不一定能直接执行。用 `sh .zcode/bin/foo.sh` 最稳；命令返回 126/127 时工具输出里也会给出这个提示。

## 自动化：手机才有的触发条件

入口在 **设置 → 自动化**，或者输入 `/automation`。规则由「触发条件 + 一串动作」组成：

| 触发 | 说明 |
|---|---|
| 每隔 N 分钟 / 每天几点 | 选星期几，不选就是每天 |
| 电量低于 / 高于 / 充满 | 到阈值触发一次，恢复后重新武装，不会反复刷 |
| 插上电源 / 拔掉电源 | 系统广播即时触发 |
| 连上 / 断开 Wi-Fi | 可只匹配 SSID 片段 |
| 点亮屏幕 / 解锁手机 | 适合「回来时看一眼待办」 |
| 收到通知 | 按应用 + 关键词过滤，需要「通知使用权」 |
| 打开某个应用 | 由无障碍服务上报前台应用，不需要 root |
| 屏幕出现文字 | 切到新界面时读一次，命中关键字触发，30 秒内不重复 |
| 息屏 N 分钟 | 适合「睡前半小时整理笔记」 |
| 开机后首次打开 | 重启后第一次启动 App 时执行 |
| 仅手动 | 只在你点播放时跑 |

动作可以串起来，前一个失败就停：

- **智能体**：跑一轮无界面对话（不打断你正在聊的会话），结果写进运行记录；
- **命令**：内置 sh / Termux / root·Shizuku 三种通道；
- **通知**：标题 + 正文，支持 `{app}` `{title}` `{text}` `{time}` `{battery}` `{ssid}` 占位符；
- **屏幕操作**：按文字点按钮 / 长按 / 输入 / 滚动 / 返回 / 桌面 / 最近任务 / 通知栏 / 截屏 / 锁屏，走无障碍，不用 root；
- **操作手机**：Wi-Fi、移动数据、飞行模式、勿扰、亮度、锁屏、截屏、通知栏、返回/桌面/最近任务、强制停止、清空后台、充电时保持唤醒、音量、媒体播放、深色模式、直接息屏；
- **朗读**：系统 TTS 念一段话，适合「构建完成」这类播报；
- **复制到剪贴板**：常和通知触发搭配，例如验证码自动入剪贴板；
- **打开应用** / **等待**：包名或应用名，等待 1–300 秒给上一步留时间；
- **HTTP 请求**：把结果推到自己的服务。

内置 13 个模板（到家拉代码、早间检查、重要消息提醒、验证码自动复制、微信自动打卡、构建成功播报、息屏整理笔记、充满提醒……），点「模板 → 添加」就有一条能跑的规则，再按需改条件；也可以点标题栏的 ✨ 用**一句话建规则**：输入「收到验证码通知就复制到剪贴板」，解析成触发条件 + 动作后先打开编辑页确认，再保存。

边界说清楚：规则在 App 进程存活时生效（前台或刚退到后台），不做常驻前台服务——那会多一条常驻通知，也费电。被系统杀掉后不会再跑；开机规则会在下次打开 App 时补执行，因为 Android 10 起不允许后台拉起界面。

## 无障碍：不用 root 也能读屏和点按

**设置 → 无障碍 → ZCode 屏幕助手** 打开后，App 就能看见前台应用和屏幕上的文字，并且按文字点按钮。它和 root / Shizuku 是两条独立的路：没有 root 也能用，只是能力集中在「界面层」而不是「系统层」。

| 能做 | 怎么做 |
|---|---|
| 读当前屏幕 | 无障碍节点树，只保留可见文字/描述，最多 60 条 |
| 按文字点击 / 长按 | 先精确匹配再包含匹配，自动找可点击的父节点，不看坐标 |
| 输入文字 | 找可编辑节点，`ACTION_SET_TEXT`，可用 `{text}` 取通知正文 |
| 滚动 / 返回 / 桌面 / 最近任务 / 通知栏 / 截屏 / 锁屏 | 全局动作，不需要 shell |
| 前台应用触发 | 窗口切换时上报包名与应用名，2 秒内去重 |
| 通知触发 | 单独的「通知使用权」，读取标题和正文 |

自动化页顶部有「读一下当前屏幕」按钮，可以直接看到这一屏有哪些可点元素——调试规则时比猜坐标快得多。智能体的 `device` 工具也多了 `screen` / `click` / `type_text` / `global` / `speak`：没有 root 时它依然能读屏、点按钮、返回桌面。屏幕内容只在本机处理，不上传。


## root 与 Shizuku：多出来的那一层

普通权限已经能发通知、读写工作区、跑内置 shell。要让 App 动系统开关、截屏、模拟点击，就需要一个「shell uid」：

| 能力 | 普通 | root | Shizuku |
|---|---|---|---|
| 通知 / 剪贴板 / 震动 / 打开应用 / 音量 | ✅ | ✅ | ✅ |
| Wi-Fi、移动数据、飞行模式、勿扰、亮度 | — | ✅ | ✅ |
| 截屏、锁屏、通知栏、返回/桌面/最近任务 | — | ✅ | ✅ |
| 模拟点击、滑动、输入文本 | — | ✅ | ✅ |
| 强制停止、清空后台、装包、`pm grant` | — | ✅ | ✅ |
| 任意 `settings put` / `cmd` / `dumpsys` | — | ✅ | ✅ |

怎么开：

- **root**：手机已 root 并装好 `su`，App 第一次执行特权命令时系统会弹授权，允许即可；
- **Shizuku**：装 [Shizuku](https://shizuku.rikka.app/)，用 adb 或无线调试启动服务，然后在 **自动化 → 权限 → 授权** 点一下；状态栏会显示 `Shizuku`。

终端页右上角图标在 **内置 sh → Termux → 特权 shell** 之间循环，切到盾牌图标时 `pm`、`svc`、`input`、`settings` 都能直接用。智能体的 `device` 工具也会先看当前通道：没有特权时明确告诉你需要开哪一个，而不是假装执行成功。

## 插件：下载即用

和桌面端一样，手机版把「扩展」做成内容而不是代码：装插件就是往工作区写文件，下一轮对话立刻生效，不需要重新打 APK。

打开 **设置 → 插件市场**（或 `/plugins`），16 款内置插件离线可装：

| 类型 | 内置示例 | 安装后 |
|---|---|---|
| 技能 | 代码评审、Android Shell、联网调研、安全自查、移动端 UI | 写入 `.zcode/skills/`，自动出现在系统提示里 |
| 命令 | `/commit`、`/explain` | 写入 `.zcode/commands/`，输入 `/` 直接看到 |
| 子智能体 | 缺陷猎手、测试编写、重构助手、文档撰写 | 写入 `.zcode/agents/`，`task` 工具按名调用 |
| 资源包 | 网页起手模板、Python 小工具箱 | 文件落到工作区，改完就能跑 |
| MCP | 接入示例 | 合并进 `.zcode/mcp.json`，自动重连 |

也可以在插件页右上角「从链接安装」：填一个 JSON 清单地址即可，支持：

```json
{
  "plugins": [
    {
      "id": "my-skill",
      "name": "我的技能",
      "kind": "skill",
      "files": [{ "path": "skills/my.md", "content": "# 规则…" }]
    }
  ]
}
```

单个对象、数组、`{"plugins": […]}` 三种写法都能解析。写入路径被限制在 `.zcode/{skills,commands,agents,plugins}/` 下，`..` 与绝对路径会被丢弃（有测试覆盖）。卸载时它写过的文件一并删除，停用则只摘掉 MCP 注册。

## MCP：把别的应用变成工具

`设置 → 插件 → MCP 服务` 里可以直接编辑 `.zcode/mcp.json`：

```json
{
  "mcpServers": {
    "filesystem": {
      "url": "https://your-host/mcp",
      "headers": { "Authorization": "Bearer YOUR_TOKEN" }
    },
    "local-tool": {
      "command": "/path/to/server",
      "args": ["--stdio"]
    }
  }
}
```

保存后点「重新连接」，服务暴露的工具会以 `mcp__服务器名__工具名` 出现在智能体手里，卡片上的名称也带 `MCP:` 前缀，一眼能看出调用来源。远程走 Streamable HTTP（支持 SSE 响应与 session），本地走 stdio；连不上的服务只会在列表里标红，不会拖慢对话。

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

## 界面

v3.5.0 起界面换成液态玻璃材质：玻璃只出现在**固定的控制层**（顶栏、Dock、输入栏、弹层），消息、卡片、列表一律实色。原因很实际——每层毛玻璃都是一次离屏渲染，列表里铺 20 个就会掉到 30fps；而玻璃只有叠在内容上才有意义。

- 背景是一层中性底色加两团很淡的光（4–6% alpha），给玻璃提供可折射的东西，不抢内容；
- 玻璃分三档：`soft`（默认，模糊 + 顶点高光）、`full`（再加 1.06× 折射）、`flat`（纯半透明，低端机用），配置项 `glassQuality`；
- 动效统一走 `AppTokens`：按压放大 1.03 后弹性回弹，页面切换 260ms 淡入上移，键盘弹出时 Dock 自动收起；
- 深浅色共用一套语义色板，正文对比度按 4.5:1 卡（`test/theme_test.dart` 会校验）。

v3.7.0 把二级页面（自动化 / 扩展模块 / 插件 / 工作区选择 / 登录 / 会话抽屉）并入同一套令牌，并在主题层把 M3 的五级 `surfaceContainer` 直接指到色板——未迁移的控件不会再有那层种子色偏紫的问题。深色底色抬到 `#101419`，卡片与玻璃的层次靠明度而不是染色建立。

v3.6.0 把改版推到内容层：对话 / 文件 / 终端 / 设置四页共用 `GlassHeader`（溢出的动作收进菜单，四个按钮才塞得进 390dp）；设置页从一长串表单改成带标题的分组卡，组内输入框去掉边框与填充，文字与标签左对齐；用户气泡在浅色下改成白卡加发丝边，工具卡与计划卡改用 `surfaceRaised` 令牌。

设计令牌在 `lib/theme/tokens.dart`，玻璃组件在 `lib/theme/glass.dart`，改版方案与落地记录在 `docs/UI-REDESIGN.md`。

## 其他

- **会话**：多会话、自动标题、置顶、归档、搜索、重命名、复制、删除
- **外观**：5 套主色、亮 / 暗 / 跟随系统、4 档字号、中英双语
- **端侧**：自适应图标、品牌闪屏、状态栏配色、横竖屏、键盘避让

## 自己构建

需要 Flutter 3.50.1（Dart 3.14）、JDK 17、Android SDK 36。

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
  services/plugins.dart     插件市场、清单解析、安装/卸载、内置 16 款
  agent/tools.dart          工作区沙箱、13 个工具、外部工具注册、回合快照
  agent/mcp.dart            MCP 客户端（HTTP/stdio）、连接与工具注入
  agent/agent_runner.dart   流式 tool_use 循环、审批、usage、断线重试
  agent/commands.dart       斜杠命令定义
  platform/device_bridge.dart 存储权限、卷、Termux 桥（MethodChannel）
  services/workspace.dart   工作区定位、校验、初始化目录结构
  services/automation.dart  触发器判定、动作执行、规则持久化、模板
  platform/privilege_bridge.dart root / Shizuku 通道、设备事件流
  platform/a11y_bridge.dart 无障碍：读屏、按文字点按、输入、全局动作、TTS
  state/app_state.dart      会话、回合、队列、压缩、撤销、附件、工作区切换
  pages/files_page.dart     文件浏览 + 编辑器 + 图片预览
  pages/workspace_picker_page.dart 手机上选目录（含权限引导）
  pages/automation_page.dart 规则列表、编辑器、模板与运行记录
  pages/terminal_page.dart  终端（内置 sh / Termux / 特权）
  pages/root_shell.dart     手机壳：四页 IndexedStack + 悬浮 Dock
  theme/tokens.dart         设计令牌：间距 / 圆角 / 动效 / 语义色 / 玻璃档位
  theme/glass.dart          液态玻璃组件、实色卡、按压缩放、液体背景
  widgets/app_dock.dart     底部悬浮玻璃导航（四项 + 液体选中胶囊）
  pages/modules_page.dart   扩展模块管理
  pages/plugins_page.dart   插件市场 / 已安装 / MCP 三栏
  widgets/composer.dart     命令/文件补全、附件、引用、队列
  widgets/tool_card.dart    工具卡与计划卡
docs/RESEARCH.md            12 个同类项目的对比与取舍
docs/PARITY.md              与桌面版 ZCode 的能力对照
docs/UI-REDESIGN.md         视觉改版方案与 P1 落地记录
docs/UPGRADE-3.50.md        从 Flutter 3.0 升到 3.50 的完整记录
lib/dev_preview.dart        仅用于浏览器/真机视觉检查的演示入口（不参与 APK）
```

## 已验证

- `flutter analyze` → **No issues found**
- `flutter test` → **81/81 通过**，覆盖：
  - 假模型服务端跑通完整闭环：`bash` 真执行、`tool_result` 回传、拒绝审批不落盘、越权路径被拦；
  - `glob` / `grep` / `mkdir` / `move` / `delete` / `todo_write` 的行为；
  - 回合快照：新建文件被删、改过的文件内容还原；
  - 内置模块安装后脚本落盘、重启后仍注册、卸载清理；
  - 输入框的 `/` 命令与 `@` 文件补全；
  - 计划卡渲染；
  - 插件安装/卸载、越权路径丢弃、MCP 合并与撤销；
  - 远程清单拉取（本地 HTTP 服务模拟 `{"plugins": […]}`）；
  - MCP HTTP 客户端握手、`tools/list`、`tools/call`，SSE 响应解包；
  - MCP 工具以 `mcp__server__tool` 注册进工具链并可执行，重连不重复注册；
  - 子智能体只能派发一层；
  - 插件页点「安装」后文件落盘、按钮变「已安装」；
  - 工作区：路径归一化、「内部存储」标签、不可写目录被拒、切换后工具链指向新目录、`.zcode/bin` 领先 PATH、沙箱与 `/storage/**` 的放行边界；
  - 设计令牌：圆角/时长有序、按压幅度在 1.00–1.06、深浅色面层亮度递进、正文与次要文字对比度 ≥ 4.5:1、玻璃档位字符串往返；
  - 自动化：间隔 / 每日 / 星期过滤、电量阈值迟滞、Wi-Fi SSID 匹配、事件只触发对应规则、动作按序执行且首个失败即停、规则 JSON 往返、模板可直接用、设备动作到 shell 命令的映射。
  - 手机事件：通知按应用+关键词匹配、前台应用匹配、屏幕文字匹配、充满判定、息屏间隔；一句话解析器覆盖 Wi-Fi / 电量 / 验证码 / 屏幕文字 / 息屏 / 打开应用六类说法。

## 路线图

- [ ] 内置静态运行时（不依赖 Termux 也能跑 node / python）
- [ ] 语音输入与图片 OCR
- [x] 无障碍服务：无需 root 也能读屏 / 按文字点按 / 输入 / 返回桌面
- [x] 通知监听：通知触发 + 变量插值（验证码自动复制）
- [ ] 常驻前台服务的自动化（进程被杀也能跑）

## 免责声明

- 非官方客户端。账号登录与模型调用遵循平台公开接口，但长期使用请自行评估服务条款与风控风险。
- Agent 会真的执行命令，`auto` 模式请谨慎开启。
- 与智谱、Z.ai、DeepSeek、DSH Go 等均无隶属关系。

## License

MIT
