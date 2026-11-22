# 桌面远程模式与账号额度链路（阶段六决策记录）

日期：2026-11-22 · 基线：d5a26cd · 分支：feat/desktop-remote-and-quota-fixes

## 一、两条「用桌面端额度」的路径

| 路径 | 机制 | 前提 | 状态 |
|---|---|---|---|
| ① 同一账号直连 | 手机用与官方 CLI 同构的 OAuth 链路签发 Project Token，直接调用模型 API，消耗**同一账号**的 Coding Plan 套餐 | 电脑不用开机 | 阶段A 修复：签发失败显式化，不再静默回退 |
| ② 官方桌面远程 | 手机打开官方 `/remote/v4` 页面，遥控用户自己的桌面端；模型请求由桌面端发出，消耗**桌面端**当前套餐 | 电脑开机且桌面端在线 | 阶段B 新增 |

两条路径互不替代：①在电脑离线时可用，②保证与桌面完全一致的执行环境（工作区、会话、审批都在桌面端）。

## 二、链路结论（P0-2 的证据边界）

- 登录链路完整照官方开源 CLI（`zai-org/ZCode`）实现：浏览器授权 → `zcode.z.ai/api/v1/oauth/token` 换 JWT/BigModel access_token → `getCustomerInfo` → 找/建 `zcode-api-key` → `POST .../api_keys/{id}/access_tokens` 换短期 Project Token。
- BigModel 国内：**Project Token 是唯一可用的模型凭证**。v3.10.1 及以前签发失败会静默把 OAuth access_token 当成模型凭证保存，且错误回调不校验 state、loopback 服务器不关闭——这些已在阶段A 修复（见下）。
- Z.ai 海外：token 路由返回的 JWT 本身就是模型凭证，无独立签发接口；过期后只能重新登录（如实提示，不再静默保留旧凭证）。
- **边界**：官方条款未公开背书第三方客户端复用 `appId=zcode` 的授权链路。因此 UI 文案不宣称「桌面端赠送额度」，只说「同一账号的 Coding Plan 套餐」；路径①按现状保留并修好错误处理，路径②才是官方支持的桌面接入形态。

## 三、阶段A 修复清单（凭证链路）

1. `AccountSession` 引入 `CredentialSource`（project-token / zai-jwt / legacy），旧会话标记 legacy 并在下次刷新时重签，杜绝「无从分辨是真 Project Token 还是降级 access_token」。
2. 登录：签发失败 → 会话带 `issueError` 且 `hasModelCredential == false`，绝不回退；`modelCredential` getter 在凭证不可用时抛错，网络层拿不到假凭证。
3. 回调：错误回调必须校验 state；超时/拒绝/异常全部关闭 loopback 服务器（try/finally）。
4. 刷新：区分「重新签发失败」（可重试）与「账号失效需重新登录」（401/403，`reauth: true`）。
5. 设置页显示凭证状态 + 「重新签发」入口。
6. 错误信息只含步骤/状态码/服务端消息，不含任何 Token 材料；全链路无日志打印。

## 四、阶段B 实现方式（Remote 最小接入）

**协议承载：官方页面。** 桌面 3.16.2+ 的 V2 协议（`wss://zcode.z.ai/api/v1/remote/ws2` + JWT 设备注册）与旧 V1（sid/hash + HMAC 挑战）均为未公开私有协议（证据：zai-org/feedback#1149）。方案明令不复刻私有协议、不伪造桌面身份，而官方唯一支持的手机客户端就是 `/remote/v4` 页面本身。因此：

- 原生层只负责：连接列表（多设备、重命名、删除即清除链接）、二维码扫描、粘贴链接、**严格白名单校验**（仅 `https://zcode.z.ai/remote/…`）、安全存储与脱敏展示（仅显示 host/path + 参数尾 4 位）。
- 打开连接 = 内嵌 WebView 加载官方页面；页面内完成配对、会话、消息、审批与断线重连。
- WebView 导航白名单：仅官方 host 放行，其余一律交给系统浏览器。
- 扫码器通过条件导入编译（`dart.library.io`），网页预览构建不受影响。

## 五、模式隔离（P0-5 / 阶段C）

- Remote 会话由官方页面持有，与本地 `AppState` 的会话/工作区/消息零共享——本地聊天记录不会被 Remote 改写，切换模式不丢数据。
- 所有本地页面维持「手机工作台」语义；Remote 页面与容器页头部明确标注「桌面远程 · 执行在电脑端」。
- 删除连接或退出 Remote 不影响桌面端登录状态（链接只是操控凭证，非账号凭证）。

## 六、已知限制（如实声明）

- 官方页面本身要求桌面在线：桌面退出/刷新二维码都会使旧链接失效（官方文档明示），手机端如实呈现加载失败与重试。
- 手机无法代桌面创建 SSH/WSL/Docker 连接（官方页面限制，非本应用限制）。
- 路径①的长期可用性取决于官方政策，若官方要求独立客户端走 API Key，现有 Provider/API Key 模式始终可用作回退。
