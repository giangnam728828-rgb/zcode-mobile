# 同类 App 调研与取舍（2026-11）

目标：做一个**和桌面端共用同一份账号/Toke 的手机 App**，并且**能在手机上真跑代码、真改文件**，不是网页套壳、也不是扫码遥控。下面是我看过的 12 个项目，以及每个项目里被我采纳或明确放弃的做法。

## 一、横向对比

| # | 项目 | 形态 | 登录方式 | 运行时 |
|---|---|---|---|---|
| 1 | [dsh-Go](https://github.com/ccch1mneyyy/dsh-Go) | Flutter 原生 + 内置 Linux | DeepSeek 账号（浏览器 OAuth）或 API Key | PRoot + Ubuntu + Node，约 750 MB |
| 2 | [DSH-Folk](https://git.hiwiki.org/en/repo/ipf-sinon/dsh-folk) | 原生壳 + 容器 | 容器内登录 | 首次启动下载 ~150 MB 运行时，proot 跑 `dsh web` |
| 3 | [AndroPI](https://github.com/imtaqin/andropi) | Flutter + 原生服务 | GitHub device code、各家模型 Key | Termux 包重打包成 jniLibs：node/git/ssh/proot |
| 4 | [Mobile-Harness](https://github.com/techjarves/Mobile-Harness) | Kotlin + Compose | Claude / DeepSeek 账号或 Key | C++ JNI 桥接 PRoot Ubuntu 20.04 |
| 5 | [Ruuh](https://github.com/perminder-klair/ruuh) | Termux 脚本 | `ollama signin` / 云端 Key | proot Ubuntu + Node 22 + pi agent |
| 6 | [Zemote](https://github.com/HumanAILoop/zemote) | Flutter | 扫码接管桌面端 | 无（远控） |
| 7 | [ZMobile](https://github.com/my-dlq/zcode-mobile-app) | Kotlin WebView | 复用桌面端登录态 | 无（远控） |
| 8 | [ZCode-App](https://github.com/daniei-chen/ZCode-App) | Flutter + WebView | 扫码 sid/hash | 无（远控） |
| 9 | [zcode-webui](https://github.com/windviki/zcode-webui) | 本地 Web 服务 | 复用 `~/.zcode/v2/credentials.json` | 宿主机的 Node |
| 10 | [DSHA / DSH Mobile](https://github.com/search?q=dsha+deepseek+harness) | 原生 + 内置 rootfs | 应用内登录 | 离线 Ubuntu rootfs |
| 11 | [Termux + zcode](https://quicktui.ai/guides/run-zcode-from-phone) | 终端 | CLI 登录 | Termux 自带环境 |
| 12 | [ZCode 官方 CLI](https://github.com/zai-org/ZCode)（参考实现） | CLI/TUI | `zcode login` OAuth | 宿主 Node |

## 二、每个项目里值得拿的东西

**dsh-Go（1）**
- 登录：**浏览器跳转授权，密码不过 App，凭证只落本机**。这是我要的形态，不是贴 Key。
- 交互：生成中可插话、工具调用自动折叠、敏感操作默认询问、六套主题。
- 运行时：本机 PRoot 环境，首次安装约 750 MB，内存约 300 MB。
- 放弃：内置整套 Linux（体积/权限/iOS 不可行）；采纳：账号 OAuth + 审批 + 折叠卡片。

**DSH-Folk（2）**
- 运行时**按需下载**而不是打进 APK，安装包只有 26 MB —— 这是将来接 Node 时的正确做法。
- 容器内真终端、配置备份格式与桌面互通。
- 采纳：APK 保持轻量；运行时要装再装。

**AndroPI（3）**
- 工程化最完整：`tool/bundle_runtime.py` 把 Termux 的 node/git/ssh/rsync/proot 重打包成 `jniLibs`，三种 ABI；agent host（TypeScript）打成 `assets/agent.zip`，通过 **JSON lines** 与 Flutter 通信。
- 审批三档：全都问 / 只问危险 / 全放开；检查点与撤销；文件树 + diff。
- 采纳：**审批分档**、工具卡片、workspace 概念；暂不采纳：TypeScript agent host（我们直接在 Dart 里实现同构的工具循环，少一层进程通信）。

**Mobile-Harness（4）**
- Kotlin + Compose + JNI 桥接 PRoot，四个页签（项目/聊天/终端/预览）。
- 密钥用 Android Keystore（AES-256 GCM）保存 —— 采纳这个存储思路（本项目用 `flutter_secure_storage`）。

**Ruuh（5）**
- 把 Termux:API 的摄像头、短信、通知封装成 agent 可调用技能 —— 未来“操作手机”的扩展方向。

**Zemote / ZMobile / ZCode-App（6–8）**
- 全是“扫码远控”：体验轻，但**必须电脑开机**，且链接里带 `sid/hash` 等同密码。
- 明确放弃：这正是用户不要的形态。

**zcode-webui（9）**
- 唯一做“共用 `credentials.json`”的项目，但是浏览器访问的本地服务。
- 放弃：不是原生 App。

**ZCode 官方 CLI（12）—— 登录流程的事实来源**
- 授权：`{authorizeUrl}?redirect=<uri>&appId=zcode&state=<32字节hex>`，浏览器回调带 `authCode`（兼容 `code`）。
- 换证：`POST https://zcode.z.ai/api/v1/oauth/token`，body `{provider, code, redirect_uri, state}`，返回 `data.token`（ZCode JWT）与 `data.bigmodel.access_token`。
- 拿模型凭据：`GET /api/biz/customer/getCustomerInfo` → 组织/项目 → `GET/POST .../api_keys` 找或建专用 Key `zcode-api-key` → `POST .../api_keys/{id}/access_tokens`（Bearer JWT）换**短期 Project Token**，模型请求带它就是套餐额度。
- 采纳：**完整照此实现**（`lib/services/account.dart`），回调走 `127.0.0.1` 随机端口的 loopback server，和桌面端 CLI 一致。

## 三、本项目的取舍结论

| 维度 | 决定 | 原因 |
|---|---|---|
| 登录 | 浏览器 OAuth + loopback 回调 + Project Token | 与官方 CLI 同构，用户不接触密钥 |
| 凭据存储 | `flutter_secure_storage`（Android Keystore） | 令牌不落明文 |
| Agent | Dart 内实现工具循环（bash/read/write/edit/ls/grep） | 不加进程通信层，逻辑可单测 |
| 运行时 | 先 `sh` + toybox（系统自带） | 零体积、能真跑命令；Node/Python 走阶段二按需下载 |
| 沙箱 | workspace 限定在应用私有目录，路径规范化防越权 | `..` 穿越已有测试覆盖 |
| 审批 | risky / ask / auto 三档 | 抄 AndroPI、dsh-Go 的做法 |
| 包体积 | 保持 ~22 MB | 不把 Linux 塞进 APK |

## 四、阶段二（未做）

按 DSH-Folk 的路子：首次启动按 ABI 下载 Termux 运行时（node + python + git + proot），解压到应用目录，agent 的 `bash` 切到容器里执行。这样 `npm install`、`python`、`git` 才真正可用，APK 仍可保持轻量。
