# ZCode Mobile · 视觉与布局改版方案 v1

> 状态：P1 已落地（v3.5.0）。方案部分保留原样，落地记录见第八节。
> 目标版本：v4.0.0（UI 层重构，功能与数据逻辑零变更）

---

## 一、现状盘点

### 1.1 页面清单（13 个可导航页面）

| # | 页面 | 文件 | 行数 | 现有结构 | 视觉问题 |
|---|---|---|---|---|---|
| 1 | 对话（首页） | `pages/chat_page.dart` | 1428 | 顶栏 Container + 消息列表 + 输入栏 | 顶栏是一条实色横条 + 1px 下划线，和内容割裂；空状态只有图标和几行文字 |
| 2 | 会话抽屉 | `pages/sessions_drawer.dart` | 534 | Drawer + 分组列表 + 底部工具区 | 直角抽屉、实色底，无层次 |
| 3 | 设置 | `pages/settings_page.dart` | 1101 | AppBar + 6 个 `_section` + `_card` 大卡 | 一张卡里堆 5–7 行，行间无分组节奏；分组标题 12px 灰字，弱 |
| 4 | 文件 | `pages/files_page.dart` | 918 | AppBar + 列表 | 行高偏小，图标无底色，长按菜单是系统 sheet |
| 5 | 文件编辑 | 同上 `FileEditorPage` | — | Scaffold + 全屏 TextField | 与整体脱节，纯系统样式 |
| 6 | 图片查看 | 同上 `_ImagePage` | — | 黑底 + InteractiveViewer | 可用，无需大改 |
| 7 | 终端 | `pages/terminal_page.dart` | 609 | AppBar + 等宽输出 + 底部键条 | 键条是实色方块按钮，像 2016 年的终端 App |
| 8 | 自动化 | `pages/automation_page.dart` | 2248 | AppBar + 权限卡 + 无障碍卡 + 规则卡列表 | 卡片同质化，规则卡信息层级平；两张权限卡各占一屏高的 1/3 |
| 9 | 规则编辑 | 同上 `_RuleEditorPage` | — | 表单 + 卡片 | 表单控件是默认 InputDecoration |
| 10 | 模块 | `pages/modules_page.dart` | 509 | AppBar + 3 个 section + 卡片 | 与设置页同款「白卡堆行」 |
| 11 | 插件市场 | `pages/plugins_page.dart` | 798 | AppBar + 网格/列表 | 卡片信息密度高，缺少视觉锚点 |
| 12 | 登录 / 初始化 | `pages/login_page.dart` | 371 | 居中表单 | 背景纯色，品牌感弱 |
| 13 | 工作区选择 | `pages/workspace_picker_page.dart` | 612 | AppBar + 目录列表 | 面包屑挤，权限横幅是黄色系统条 |

### 1.2 通用组件（6 个）

| 组件 | 文件 | 行数 | 说明 |
|---|---|---|---|
| Composer | `widgets/composer.dart` | 700 | 输入栏、附件条、引用条、队列条、建议面板、工具面板 |
| MessageBubble | `widgets/message_bubble.dart` | 651 | 气泡、头像、标签、思考块、流式光标、附件 |
| ToolCard | `widgets/tool_card.dart` | 335 | 工具调用卡 + 计划卡（含进度条） |
| MarkdownText | `widgets/markdown_text.dart` | 217 | 代码块、行内代码、表格 |
| HomeShell | `pages/home_shell.dart` | 110 | 窄屏 drawer / 宽屏双栏 |
| AppTheme | `theme/app_theme.dart` | 155 | 唯一主题入口 |

### 1.3 样式入口（4 个，全部要动）

| 入口 | 现状 | 问题 |
|---|---|---|
| `AppTheme.build()` | Material 3 + `ColorScheme.fromSeed`，surface 写死 `#12151A` / `#FFF` | 只有一个平面，没有材质层次；卡片靠 1px 边框区分，暗色下几乎看不见 |
| 硬编码颜色 **65 处** | 散在 8 个文件（tool_card 11、app_theme 11、login 8、composer 7、terminal 6…） | 改主题必须逐处改，深色/浅色各写一遍 |
| `withOpacity` **309 处** | 从 0.03 到 0.75 随手取值 | 没有语义层级，导致「同样重要的文字深浅不一」 |
| `BorderRadius.circular` **约 120 处** | 取值 2/4/5/6/8/9/10/11/12/13/14/16/18/20/22 | 圆角语言不统一，是最显「廉价」的地方 |

### 1.4 结论

不是配色问题，是**缺少材质系统和尺度系统**：
- 只有「背景 / 卡片」两级，没有浮层、没有高光、没有景深；
- 圆角和间距是手写魔数，页面之间不成体系；
- 没有动效层，所有状态变化都是硬切。

所以改版顺序必须是 **令牌 → 玻璃组件 → 逐页迁移**，不能逐页改颜色。

---

## 二、改动范围

### 2.1 新增（约 1200 行，纯 UI）

```
lib/theme/tokens.dart          # 色板、圆角、间距、阴影、动效曲线（唯一真源）
lib/theme/glass.dart           # GlassLevel 枚举、玻璃层参数、性能降级判定
lib/widgets/glass_surface.dart # GlassSurface（模糊层 + 高光描边 + 折射渐变）
lib/widgets/glass_card.dart    # GlassCard（列表用，零模糊的伪玻璃）
lib/widgets/glass_bar.dart     # GlassBar（顶栏/底栏，随滚动联动）
lib/widgets/press_scale.dart   # PressScale（按压缩放回弹）
lib/widgets/motion.dart        # 页面过渡、交错入场、浮动动画
lib/widgets/app_dock.dart      # 底部悬浮导航
lib/pages/root_shell.dart      # 新的主框架（承载 Dock + 5 个 tab）
```

### 2.2 修改（14 个文件，只动 build 层）

| 文件 | 改动性质 | 量级 |
|---|---|---|
| `theme/app_theme.dart` | 重写为「令牌驱动」，保留现有 API 签名 | 重写 |
| `pages/home_shell.dart` | 改为挂载 RootShell / Dock | 中 |
| `pages/chat_page.dart` | 顶栏换 GlassBar、空状态换卡片流、消息入场动画 | 大 |
| `widgets/composer.dart` | 换玻璃胶囊 + 聚焦动效 + 发送键渐变 | 大 |
| `widgets/message_bubble.dart` | 用户气泡渐变玻璃、助手去掉容器、工具卡嵌玻璃 | 大 |
| `widgets/tool_card.dart` | 左侧状态条 + 玻璃薄卡 + 展开动效 | 中 |
| `pages/sessions_drawer.dart` | 玻璃抽屉 + 圆角 + 搜索框 | 中 |
| `pages/settings_page.dart` | 分组卡重排、组标题外置、开关/滑块换色 | 大 |
| `pages/files_page.dart` | 行高、图标底色、玻璃搜索条、长按 sheet | 中 |
| `pages/terminal_page.dart` | 玻璃顶栏 + 键条改胶囊 + 输出区深玻璃 | 中 |
| `pages/automation_page.dart` | hero 卡、权限卡改双 chip、规则卡重排 | 大 |
| `pages/modules_page.dart` | 复用 Settings 的组卡规范 | 小 |
| `pages/plugins_page.dart` | 卡片视觉锚点 + 标签 chip | 中 |
| `pages/login_page.dart` | 背景光斑 + 中央玻璃卡 | 中 |
| `pages/workspace_picker_page.dart` | 面包屑胶囊 + 行样式 | 小 |
| `models/app_config.dart` | **仅新增** `glassLevel` UI 偏好字段（可选，见 §6） | 极小 |

### 2.3 明确不动

`lib/agent/**`、`lib/services/**`、`lib/platform/**`、`lib/models/`（除 app_config 加一个 UI 字段）、`lib/state/app_state.dart` 的业务方法。所有命令、自动化、权限、存储逻辑原样保留。

**验收硬指标：改版前后 `flutter test` 73 条全部通过，且不需要修改任何测试。**

---

## 三、设计规范

### 3.1 色彩

背景不是纯色，是「底色 + 3 个柔光斑」，让玻璃有东西可以透出来。

**深色**
| 令牌 | 值 | 用途 |
|---|---|---|
| `bg.base` | `#06080D` | 最底层 |
| `bg.mesh.accent` | accent @ 18%，径向，左上 | 品牌色渗出 |
| `bg.mesh.cool` | `#00C8B4` @ 12%，右下 | 冷暖对比 |
| `bg.mesh.violet` | `#8B5CF6` @ 14%，中下 | 层次 |
| `text.primary` | `#F2F5FA` | 正文 |
| `text.secondary` | 同色 @ 62% | 次要 |
| `text.tertiary` | 同色 @ 38% | 提示/占位 |

**浅色**
| 令牌 | 值 |
|---|---|
| `bg.base` | `#F2F4F9` |
| `bg.mesh.accent` | accent @ 13% |
| `bg.mesh.cool` | `#7FE0D0` @ 10% |
| `bg.mesh.warm` | `#FFC2AE` @ 9% |
| `text.primary` | `#10141C`（62% / 38% 同上） |

accent 沿用现有 5 套 seed（靛蓝/海青/紫罗兰/森林/暖橙），不新增也不删。派生规则：
- `accent.solid` = seed
- `accent.gradient` = seed → seed 混 12% 青，135°
- `accent.glow` = seed @ 22%（用于阴影和选中态）

### 3.2 液态玻璃（Liquid Glass）的物理构成

**不是高斯磨砂。磨砂是把背景糊掉，液态玻璃是把背景弯折。** 上一版把 σ 拉到 18，那是毛玻璃；正解是「低模糊 + 折射放大 + 边缘厚度 + 镜面光泽 + 色散」。

| 物理特征 | 参数 | 为什么必须有 |
|---|---|---|
| **折射放大** | 背景 1.06–1.12×，中心对齐 | 玻璃是透镜。没有这一层，再透也只是塑料膜 |
| **轻微失焦** | σ **2–4**（不是 18） | 只丢掉细节，保留形状与色块；σ 一大就变雾 |
| **染色** | 饱和 ×1.15、亮度 ×1.04 | 透过玻璃的颜色应更「鲜」，不是更灰 |
| **厚度** | 外 1px 暗线 + 内 1px 白线 + 6dp 内阴影 | 有边才有实体感；只有一层描边就是贴纸 |
| **镜面光泽** | 112° 白渐变 .30→0，占上半 42% | 表面反光；按压缩放时光带随之位移 |
| **色散** | 1px 环形 sweep（accent/青/品红 各 .10） | 棱镜边，深色背景上最像真玻璃 |
| **形变** | 按压 scale .965 + 圆角 +4 + 光泽偏移 | 液体有表面张力，压下去会「鼓」出来 |
| **液体背景** | 3 个 blob，26s 缓慢漂移 | 玻璃后面得先有液体，才有东西可折射 |

> σ 从 18 降到 2–4 **反而更省**：高斯成本随半径平方增长，σ18 的采样量约是 σ3 的 36 倍。液态玻璃版比磨砂版更快，不是更慢。

**分层结构（每个玻璃元素从下往上 5 层）**

```
┌ 光泽带 白色 112° 渐变，BlendMode.screen，可位移
├ 内容（图标/文字/输入框）
├ 染色层：accent 3–6%，让玻璃带一点环境色
├ 折射层：背景放大 1.06–1.12 + σ2–4 + 饱和/亮度提升
└ 边缘：内白线 1px(.35) + 外暗线 1px(.08) + 色散环 1px
```

### 3.2.1 Flutter 3.0 怎么实现（无 shader 约束）

技术栈锁在 Flutter 3.0 / Dart 2.17，**没有 FragmentProgram**（3.7 才有），所以不能用 GLSL 写真正的折射。用 `dart:ui` 的图像滤镜组合等价逼近：

| 特征 | Flutter 3.0 实现 | 备注 |
|---|---|---|
| 折射放大 | `BackdropFilter(filter: ImageFilter.matrix(Matrix4.diagonal3Values(1.08,1.08,1).storage))` + `ClipRRect` | 先做 8 行 spike 验证边缘采样；不达标则退到「背景复刻层」方案（见下） |
| 轻微失焦 | `ImageFilter.blur(sigmaX: 2.4, sigmaY: 2.4)` | 与 matrix 用 `ImageFilter.compose` 合成一次采样 |
| 染色 | `ColorFiltered(ColorFilter.matrix(...))` 饱和 1.15 / 亮度 1.04 | 矩阵预计算成常量，零运行时成本 |
| 厚度 | 双层 `DecoratedBox`：外层 `Border.all(0.5, black@.08)`，内层 `Border.all(1, white@.35)` | 单层 `BoxShadow` 做内阴影 |
| 镜面光泽 | `DecoratedBox` + `LinearGradient` + `BlendMode.screen` | 位置由 `AnimatedAlign` 驱动 |
| 色散 | `SweepGradient` 1px 描边（用 `ShaderMask` 或双圆角叠层） | 深色下 .10，浅色下 .06 |
| 形变 | `AnimatedContainer`：scale + `borderRadius` + 光泽 `alignment` 同时插值 | `Curves.elasticOut`，见 §3.7 |
| 液体背景 | 3 个 `Positioned` 圆 + `ImageFiltered(blur 46)`，`AnimationController` 26s | 包 `RepaintBoundary`，只重绘背景层 |

**降级路径（矩阵滤镜不可靠时）**：不做 `ImageFilter.matrix`，改为在玻璃元素内部放一个 `Transform.scale(1.08)` 的「背景复刻层」——用同样的 `RadialGradient` 近似当前位置的背景，再 `ClipRRect`。视觉上仍是「放大透过」，只是不跟随真实背景滚动。P0 阶段实测后再定，两条路都预留。

### 3.3 圆角

| 令牌 | 值 | 用途 |
|---|---|---|
| `r.xs` | 10 | 标签、小按钮 |
| `r.sm` | 14 | 输入框内元素、chips |
| `r.md` | 18 | 小卡片 |
| `r.lg` | 22 | 卡片、消息气泡 |
| `r.xl` | 26 | Dock、顶栏胶囊、sheet |
| `r.pill` | 999 | 按钮、开关底 |

现有 120 处魔数收敛到这 6 档，视觉上「圆角语言统一」是观感提升最大的一步。

### 3.4 间距（8pt 栅格）

`4 / 8 / 12 / 16 / 20 / 24 / 32`。页面左右边距统一 **16**（现在是 16 或 6 混用），卡片内边距 **16**（现在 14/12/10 混用），列表行高 **56**（现在 48–64 不等）。

### 3.5 字体与字阶

沿用系统字体（中端机避免打包字体）。字重只用 400 / 500 / 600。

| 层级 | 字号 / 行高 | 字重 | 用途 |
|---|---|---|---|
| Display | 28 / 1.2 | 600 | 空状态主标题 |
| Title | 17 / 1.3 | 600 | 顶栏、页面标题 |
| Body | 15 / 1.55 | 400 | 聊天正文、表单 |
| Label | 13 / 1.4 | 500 | 按钮、列表主行 |
| Caption | 11.5 / 1.35 | 500 | 元信息、时间 |
| Overline | 10.5 / 1.2 + 0.6 letterSpacing | 600 | 分组标题（大写/加宽） |

现有 `fontScale` 设置保留，按倍率乘算。

### 3.6 阴影

只有 3 档，且**深色模式只用一个方向**（向下），避免糊成一团：

| 令牌 | 浅色 | 深色 |
|---|---|---|
| `shadow.sm` | `0 1 3 rgba(23,32,54,.06)` | `0 1 2 rgba(0,0,0,.4)` |
| `shadow.md` | `0 6 20 rgba(23,32,54,.10)` | `0 8 24 rgba(0,0,0,.45)` |
| `shadow.glow` | `0 6 18 accent@.25` | `0 8 24 accent@.35`（仅主按钮） |

### 3.7 动效与液体行为

| 场景 | 参数 | 曲线 |
|---|---|---|
| 按压缩放 | 1 → 0.965，同时圆角 +4、光泽右移 10dp，190ms | `easeOutCubic` |
| 松开回弹 | 0.965 → 1，圆角回位，260ms | `elasticOut(1.0, 0.42)`（明显果冻感） |
| 页面进入 | opacity 0→1 + 上移 12dp，300ms | `easeOutCubic` |
| 页面退出 | opacity 1→0 + 上移 8dp，220ms | `easeInCubic` |
| Dock 选中 | 液体胶囊位移 + 轻微 overshoot，280ms | `easeOutBack(1.15)` |
| Dock 粘连 | 胶囊滑过时与相邻项短暂「拉丝」融合，300ms | 见下 |
| 列表入场 | opacity + 8dp 上移，索引×28ms，上限 240ms | `easeOutCubic` |
| 背景漂移 | 3 个 blob 各自 24–32s 循环，位移 ≤ 屏宽 12% | `sine` inOut |
| 滚动联动 | 0–64px：顶栏填充 α 0→目标值、光泽带上移 8dp | 线性，**无 setState** |
| Sheet 弹出 | r.xl，上滑，340ms | `easeOutQuint` |

**Dock 液体粘连**（可选加分项）：选中胶囊从 A 移到 B 时，在过渡的 300ms 内给 Dock 内容层加 `ImageFiltered(blur 6)` + `ColorFilter` alpha 阈值，两个胶囊会像水滴一样先粘连再分离。只在 58dp 高的小区域、只在切换瞬间启用，代价可接受；默认开启，设置里可关。

任何页面不许写裸 `Duration`，全部走 `motion.dart`。

## 四、新布局

### 4.1 导航结构（我建议的填空答案）

> **底部悬浮玻璃 Dock（4 项）+ 抽屉保留会话列表 + 设置收进 Dock 第 4 项**

```
[ 对话 ]  [ 文件 ]  [ 自动化 ]  [ 更多 ]
                                  └→ 终端 / 模块 / 插件 / 设置 / 工作区
```

理由：现有功能有 8 个入口，全塞 Dock 会挤成 8 个 12px 图标；而「终端/模块/插件/设置」是低频，放二级菜单更清爽。Dock 常驻 4 项，选中项有 accent 胶囊底。

### 4.2 对话页（含 Dock）

```
┌──────────────────────────────────┐
│  ┌────────────────────────────┐  │ ← 玻璃胶囊顶栏，浮在内容上
│  │ ☰  整理工作区…  glm-4.6 ▾ ⋮│  │   左右 12dp，高 52dp，r.xl
│  └────────────────────────────┘  │   滚动时 α 0→0.58 渐显
│                                  │
│   ┌──────────────────────────┐   │ ← 用户气泡：accent 渐变 8%,
│   │ 帮我把 README 补一下      │   │   右上角 r.sm，左下 r.lg
│   └──────────────────────────┘   │
│                                  │
│   ✦ ZCode                        │ ← 助手：无气泡，直接排版
│   已经加了一节 Design notes，     │   头像 22dp 圆形玻璃 + 光晕
│   解释了为什么……                 │
│   ┌──────────────────────────┐   │
│   │▎✓ bash   ls -la     780ms│   │ ← 工具卡：左侧 3dp 渐变状态条
│   │  total 32                │   │   glass.card，展开 260ms
│   └──────────────────────────┘   │
│                                  │
│  ┌────────────────────────────┐  │
│  │ + │ 给 ZCode 发消息…    │ ↑ │  │ ← 输入胶囊：玻璃，高 52，r.xl
│  └────────────────────────────┘  │   聚焦时描边变 accent，发光 6dp
│     ┌──────────────────────┐     │
│     │ 对话  文件  自动化  ⋯ │     │ ← Dock：高 58，r.xl，4 项
│     └──────────────────────┘     │   选中项 accent 胶囊 + 图标 -2dp
└──────────────────────────────────┘
```

> **空间取舍**：底部 = 输入 52 + 间距 8 + Dock 58 + 安全区 ≈ 134dp，占 844dp 屏高的 16%。若你觉得挤，备选是**对话页隐藏 Dock**（左右滑动/抽屉切换页面），我把它列为待确认项。

### 4.3 空状态（首页卡片流）

```
┌──────────────────────────────────┐
│                                  │
│         ◉（渐变光球 72dp，        │
│            缓慢呼吸浮动）          │
│                                  │
│      ZCode                       │
│      把手机变成你的工作台          │
│                                  │
│  ┌───────────┐ ┌───────────┐    │ ← 2×2 玻璃卡，各 8dp 间距
│  │ ⌘ 跑构建   │ │ ▤ 看改动   │    │   点一下填入输入框
│  │ flutter…  │ │ git diff  │    │
│  └───────────┘ └───────────┘    │
│  ┌───────────┐ ┌───────────┐    │
│  │ ⚡ 定时任务 │ │ ⬒ 装模块   │    │
│  └───────────┘ └───────────┘    │
│                                  │
│  最近                             │ ← Overline 分组标题
│  ┌────────────────────────────┐  │
│  │ 整理工作区…        2 分钟前 │  │ ← 最近会话（最多 3 条）
│  └────────────────────────────┘  │
└──────────────────────────────────┘
```

### 4.4 设置页

```
┌──────────────────────────────────┐
│ ←  设置                       ✓  │ ← 玻璃顶栏
│                                  │
│  账户                             │ ← Overline，在卡外，左缩进 4
│  ┌────────────────────────────┐  │
│  │ ⬤ 渐变头像  昵称            │  │ ← 账户卡：accent 渐变 6% 底
│  │    BigModel · 已连接        │  │
│  └────────────────────────────┘  │
│                                  │
│  模型与端点                       │
│  ┌────────────────────────────┐  │
│  │ 端点  [国内][海外][自定义]  │  │ ← segmented 玻璃胶囊
│  │┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈│  │ ← 分隔线左右各缩进 16
│  │ 模型  glm-4.6            › │  │   行高 56
│  │┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈│  │
│  │ 温度  0.7  ────●───────    │  │
│  └────────────────────────────┘  │
│                                  │
│  工作区                           │
│  ┌────────────────────────────┐  │
│  │ ▤ 工作区文件夹     内部存储 ›│  │ ← 每行 56，图标 32 玻璃方底
│  │ ▤ 文件管理              ›  │  │
│  │ ▤ 终端                  ›  │  │
│  └────────────────────────────┘  │
│                                  │
│  外观                             │
│  ┌────────────────────────────┐  │
│  │ 主题  [跟随][浅色][深色]    │  │
│  │ 强调色 ● ● ● ● ●          │  │ ← 5 个 22dp 圆点，选中加环
│  │ 玻璃效果  [完整][柔和][关闭]│  │ ← 新增，见 §6
│  └────────────────────────────┘  │
└──────────────────────────────────┘
```

改动要点：**一张大卡拆成「一卡一组」，组标题浮到卡外**，行间用内缩分隔线。这是从「设置项堆叠」变成「有呼吸的分组」，也是现在最显乱的地方。

### 4.5 自动化页

```
┌──────────────────────────────────┐
│  自动化                     ✨  ⋮ │
│                                  │
│  ┌────────────────────────────┐  │ ← hero 卡：accent 渐变 10% + 光晕
│  │  8 条规则                   │  │
│  │  今日已触发 3 次 · 上次 12:40│  │
│  │  [全部启用]  [＋ 新规则]    │  │ ← 主按钮用 accent 渐变
│  └────────────────────────────┘  │
│                                  │
│  ┌──────────┐ ┌──────────┐      │ ← 权限从两张大卡 → 两枚状态 chip
│  │ ⚡ root 已连│ │ 👁 无障碍 未开│  │   未开时描边为琥珀色
│  └──────────┘ └──────────┘      │
│                                  │
│  规则                             │
│  ┌────────────────────────────┐  │
│  │ ● 到家拉代码          [开] │  │ ← 左侧状态点（启用=accent 发光）
│  │   连上 Wi-Fi · 2 个动作     │  │   副行 11.5px
│  └────────────────────────────┘  │
│  ┌────────────────────────────┐  │
│  │ ○ 睡前清理            [关] │  │ ← 停用：整卡 α 0.5，状态点灰
│  └────────────────────────────┘  │
└──────────────────────────────────┘
```

### 4.6 其他页面要点

- **文件**：行高 56，文件夹图标带 accent 玻璃方底（32dp, r.sm），文件按扩展名给 5 种色相；顶部搜索改为玻璃胶囊；长按菜单换玻璃 sheet。
- **终端**：输出区用「深玻璃」（比背景更暗 + 8% 黑），等宽字体保持；底部键条从方块按钮改为 7 个玻璃胶囊，长按连发。
- **登录**：背景三光斑 + 居中玻璃卡（r.xl）+ 渐变主按钮 + 5 个服务商按钮统一为玻璃行。
- **抽屉**：玻璃底 + 右边缘 r.xl，顶部品牌区 + 搜索胶囊，会话列表行高 60。
- **宽屏（≥780dp）**：左侧栏也玻璃化，中间对话区限宽 860 不变。

---

## 五、性能预算与降级

### 5.1 硬预算

| 项 | 上限 |
|---|---|
| 同屏 `BackdropFilter` 层数 | **2**（顶栏 + 底栏），永不进列表 |
| 单个模糊区域面积 | ≤ 屏高 12%（Dock 58 / 顶栏 64） |
| 列表项阴影层数 | 1 |
| 滚动中的 `setState` | 0（用 `ValueListenable` + `RepaintBoundary`） |
| 每帧构建耗时 | < 8ms（中端机骁龙 6 系） |

### 5.2 三档玻璃

| 档位 | 折射 | 失焦 σ | 色散 | 光泽带 | 适用 |
|---|---|---|---|---|---|
| `full` | 1.12× | 3 | 有 | 有 + 随按压位移 | 高端机 / 手动开 |
| `soft` | 1.06× | 2 | 无 | 有（静态） | **默认** |
| `flat` | 无 | 0 | 无 | 无 | 低端机 / 手动关：纯半透明 + 描边 |

三档的差别只在「折射层」，布局、圆角、间距完全一致，切换不会造成视觉跳变。

### 5.3 自动判定（不引入依赖）

启动后用 `SchedulerBinding.instance.addTimingsCallback` 采样帧耗时：
- p90 > 22ms 或出现 2 次 > 40ms 的长帧 → 自动降一档（`full → soft → flat`，`soft → flat`）；
- 只降不升，只提示一次（SnackBar），用户可在设置里锁定档位；
- 偏好存 `AppConfig.glassQuality`（`auto` / `full` / `soft` / `flat`），
  实测落点另存 `glassAutoTier`，避免每次冷启动都从 soft 抖动一遍。

> 三个字段都是纯 UI 偏好，不影响任何业务逻辑。落地细节见第十一章。

---

## 六、迁移顺序（每批可单独验收）

| 批次 | 内容 | 预计 | 验收 |
|---|---|---|---|
| **P0** | `tokens.dart` + `glass.dart` + `GlassSurface/GlassCard/GlassBar/PressScale` + `app_theme.dart` 重写 | 1 批 | 现有页面不变布局，但背景/卡片/输入框自动换成新令牌；73 测试全过 |
| **P1** | Chat 页 + Composer + MessageBubble + ToolCard + 空状态 + **Dock** | 1 批 | 首页可截 3 屏（空/对话中/深色） |
| **P2** | Settings + Files + Terminal | 1 批 | 三页截图对比 |
| **P3** | Automation + Modules + Plugins + Login + WorkspacePicker + Drawer | 1 批 | 全量截图 |
| **P4** | 性能校验 + 降级逻辑 + 真机 60fps 抽查 | 1 批 | 帧率截图 |

每批结束我会：`flutter analyze` → `flutter test` → 构建 web 预览截图 → 交给你看，确认后再进下一批。

---

## 七、已确认的决策（2026-11-21）

| 决策 | 结论 |
|---|---|
| Dock 项数 | **4 项**：对话 / 文件 / 终端 / 设置 |
| 自动化入口 | **不单独占位**，收到「设置」页最上方（常去但不常改） |
| 对话页 Dock | **常驻**，输入栏之上叠放 |
| 折射强度 | 依规格取 **1.06×**（按压放大 1.03） |
| 玻璃档位 | 默认 `soft`，可在配置 `glassQuality` 切 `full` / `flat` |

---

## 八、P1 落地记录

已交付：

| 文件 | 内容 |
|---|---|
| `lib/theme/tokens.dart` | 间距 4pt 栅格、5 档圆角、动效 4 档曲线、`AppPalette` 语义色、`GlassQuality` |
| `lib/theme/glass.dart` | `GlassSurface`（折射/染色/厚边/光泽四层）、`SolidCard`、`PressScale`、`LiquidBackground`、`GlassScope` |
| `lib/widgets/app_dock.dart` | 悬浮玻璃 Dock，液体选中胶囊 |
| `lib/pages/root_shell.dart` | 4 页 `IndexedStack` 保状态 + Dock + 键盘自动收起 |
| `lib/pages/chat_page.dart` | 顶栏改真玻璃（`full` 档，1.06× 折射），空状态与建议卡改实色 |
| `lib/widgets/composer.dart` | 嵌入模式：薄膜填充 + 顶部发丝线 |
| `lib/pages/settings_page.dart` | 顶部新增「自动化」入口卡（规则数/今日次数/权限档） |
| `lib/pages/{files,terminal,settings}_page.dart` | `embedded` 参数：无返回箭头、透明底、共享背景 |

实测中修掉的两个参数错误：

1. **玻璃填充被双重衰减**：`glassTint` 自带 alpha，又乘了一次 `tintOpacity`，暗色下实际只有 7.6% 白 → 玻璃退化成纯黑块。改为不透明 token + 单次 alpha。
2. **浅色背景太亮**（`#F2F3F5`）：白卡片和玻璃都贴在上面，全屏一片白。背景降到 `#E9ECF1` 后，白卡片和玻璃才能浮起来。

P2（设置页分组、文件/终端顶栏、气泡与工具卡收敛到令牌）已完成，见第九章。

---

## 九、P2 落地记录（v3.6.0）

### 9.1 统一顶栏 `lib/widgets/glass_header.dart`

对话页、文件页、终端页、设置页此前各自用 `AppBar`：标题字号 16.5/17 混用、动作按钮 48dp 占位、背景要么透明要么纯色。现在三页共用 `GlassHeader`：

| 能力 | 说明 |
|---|---|
| 两种模式 | `embedded` 走 `GlassQuality.full` 玻璃（`blur:18`、`radius:0`、无阴影），推入路由时走实色 coat，避免转场时透出上一页 |
| 副标题 | 路径 / cwd 用等宽，走 `DefaultTextStyle.merge`，字号 10.5、`textTertiary` |
| `HeaderAction` | 视觉 19.5dp、点击 48dp，比 Material 默认省 8dp/个，四个动作才塞得进 390dp |
| `HeaderMenu` | 溢出菜单，禁用项保留占位（菜单高度不跳） |

文件页原来四个 IconButton 挤在标题右侧，现在收成「切换工作区 + 更多」两项，隐藏文件/刷新/用其他应用打开进菜单。

### 9.2 设置页分组重排

从「一长串表单」改成「带标题的分组卡」：

1. 自动化入口卡（未变，仍在最上）
2. 账号
3. 模型服务（提供方 / 端点 / 模型 / API Key / 系统提示 / 最大输出）
4. 智能体（工具审批 / 温度 / 自动压缩 / 项目规则）
5. 工作区（文件夹 / 文件 / 终端 / 模块 / 插件）
6. 外观（主题 / 主色 / 字号 / 语言 / 玻璃质感）
7. 数据（导出 / 导入 / 清空）
8. 关于（版本 + 免责声明）

行类型收敛为三种：`_Tile`（导航/开关/值）、`_FieldTile`（标签 + 控件）、`_Group`（标题 + 卡片 + 脚注）。原「工作区」里重复的自动化入口已删除，只保留顶部那张卡。

组内输入框全部去边框去填充（`filled:false` + `InputBorder.none` + `contentPadding:zero`），文字与标签左对齐——卡片本身已经是容器，框里再套框会显得脏。

### 9.3 本次修掉的四个视觉错误

| 问题 | 原因 | 修法 |
|---|---|---|
| 组内输入框变成整条灰带 | 全局 `inputDecorationTheme.filled=true` 继承到卡片内 | 每个组内字段显式 `filled:false` + 三态 border none |
| 输入文字比标签右缩 22dp | 继承主题的 `contentPadding` 14×13 | `contentPadding: EdgeInsets.zero` |
| 分段控件选中胶囊右角被「切平」 | 选中态阴影溢出轨道圆角 | 轨道 `clipBehavior: Clip.antiAlias` |
| 关于行版本号悬在免责声明中间 | `_Tile` 的 trailing 默认垂直居中 | 新增 `alignTop`，多行副标题时贴首行 |

### 9.4 气泡与工具卡

| 元素 | 之前 | 现在 |
|---|---|---|
| 用户气泡（浅色） | 主色 10% 填充，全屏一片紫 | 白卡 `p.surface` + `p.line` 发丝边，主色只留在深色档（16%） |
| 气泡圆角 | 18/18/18/5 手写 | `rLg/rLg/rLg/rXs` 令牌 |
| 工具卡 | 硬编码 `#151A21`/`#F7F8FA`/`#232A33` | `p.surfaceRaised` + `p.line` |
| 计划卡 | 同上一行 | 同上，进度条底色改 `p.line` |
| 状态色 | 直接写字面量 | 保留（语义色不在中性 token 里），但字号/间距走令牌 |

工具卡的输出区是唯一在两套主题里都保持深色的面板——它是终端，不是卡片。

### 9.5 预览方法的一个坑

`flutter build web` 的 CanvasKit 会按 unicode 分块从 `fonts.gstatic.com` 拉 CJK 回退字体。截图时如果刚滚动完就拍，部分汉字/标点会显示成豆腐块（空方框）；多等几秒或再滚 1px 触发重绘就恢复。**这是网页预览特有的现象**，APK 用系统字体，不受影响。

---

## 十、P3 落地记录（v3.7.0）

P3 的目标是让二级页面不再像"另一个 App"：自动化、扩展模块、插件、工作区选择、登录、会话抽屉。这些页面此前仍用 Material 默认的 `surfaceContainer` 色阶与 12/14/16 混编圆角。

### 10.1 先改主题，再改页面

`ColorScheme.fromSeed` 会生成五级 `surfaceContainer`（带种色），未迁移的页面全在用它，深色下整体偏紫。逐页替换是 5000 行的体力活，且有漏改风险。改为在 `app_theme.dart` 里把整条色阶指到令牌：

| M3 槽位 | 令牌 |
|---|---|
| `surfaceContainerLowest` | `p.bg` |
| `surfaceContainerLow` / `surfaceContainer` | `p.bgElevated` |
| `surfaceContainerHigh` | `p.surface` |
| `surfaceContainerHighest` | `p.surfaceRaised` |
| `outline` / `outlineVariant` | `p.line` |
| `surfaceTint` | 透明（层级只靠明度，不靠染色） |

同时补齐 `chipTheme` / `tabBarTheme` / `switchTheme` / `floatingActionButtonTheme` / `progressIndicatorTheme`，让还没重排的控件也继承令牌。

### 10.2 统一外壳 `lib/widgets/page_shell.dart`

二级页面共用 `PageShell(title, subtitle, actions, subHeader, bottomBar, floating, child)`：

- 背景 `LiquidBackground(drift: false)`：光斑静态，不给子页面白付每帧变换；
- 顶栏用 `GlassHeader(embedded: false)`，颜色取 `bgElevated` 而不是 `bg`——与背景同色时顶栏读作"缺口"而不是"条";
- `subHeader` 承接插件页的 TabBar；`bottomBar` 承接工作区页的确认栏（自带安全区与上边线）；
- `floating` 只负责定位，按钮长什么样由调用方决定。

### 10.3 各页改动

| 页面 | 改动 |
|---|---|
| 自动化 | 两张状态卡从 `primaryContainer`/`tertiaryContainer` 半透明改中性 `surface` + 发丝边，状态只由图标与徽章表达；规则卡改 `Material` + 形状边（禁用态降一档底色而非整体变淡）；新建按钮从 Material FAB 改主色胶囊 |
| 扩展模块 | 卡片圆角/边框走令牌；终端输出块统一为工具卡那块 `#0C1014`；分组标题与设置页 `_Group` 对齐 |
| 插件 | TabBar 移到 `subHeader` 并左对齐；分类 chip 改自绘胶囊；插件卡从 3.5% 半透明白改实色 `surface` |
| 工作区选择 | 头部与底部确认栏并入 `PageShell`；主按钮显式设主色/禁用色 |
| 登录 | 去掉蓝→青渐变 logo（最模板化的一处），改单色主色块；错误块改 `cs.error`；提供方按钮改 `surface` + `line`；背景接光斑 |
| 会话抽屉 | 底色交还 `RootShell`（避免两层不一致）；logo 去渐变；搜索框与列表项令牌化 |

### 10.4 Dock 滚动收起

`lib/state/dock_visibility.dart` 一个 `ValueNotifier<bool>`，对话页在滚动监听里按方向写入，`RootShell` 用 `ValueListenableBuilder` 消费。

- 向历史方向滚 > 3px 且偏移 > 40 → 收起（`offset 0.55`，不完全飞出）；
- 反向滚动或回到顶部 → 立即恢复；
- 收起后 2.6s 自动恢复——**这是可达性底线**：dock 是唯一的导航，不能靠"记得往回滚"才能切页；
- 页面销毁时 `reset()`，新页面不会以"没有 dock"的状态打开。

### 10.5 本轮修掉的三个错误

| 问题 | 原因 | 修法 |
|---|---|---|
| 分类 chip 变成 40dp 圆形、第二个字被裁 | M3 `RawChip` 用 labelPadding 公式反推宽度，两字中文被算窄 | 改自绘 `_CategoryPill`，宽度由文本 + padding 决定 |
| 插件页 chip 行 `SizedBox(height: 36)` 压缩 chip | 固定高度小于 chip 的最小高度 | 去掉固定高度，改 `SingleChildScrollView + Row` |
| 二级页顶栏与背景同色，读作缺口 | `bgElevated == bg` 时无层次 | 顶栏改用 `bgElevated` |

> 顺带记一个预览陷阱：网页预览的 CJK 字体按 unicode 分块从 `fonts.gstatic.com` 拉，偶尔整屏汉字变豆腐块。与布局无关，等 30s 或滚动 1px 触发重绘即恢复；APK 用系统字体不受影响。

---

## 十一、P4 落地记录（v3.8.0）

P4 只做一件事：把「档位」从用户手选变成用户可选、系统可判。视觉零改动——三档的布局、圆角、间距本来就一致，降档不会出现跳版。

### 11.1 探针 `lib/state/glass_probe.dart`

一个 `ChangeNotifier`，不引第三方依赖，只用引擎给的 `FrameTiming`：

| 参数 | 值 | 理由 |
|---|---|---|
| `warmup` | 24 帧 | 首屏要付字体加载和着色器编译的钱，不跳过会冤枉所有手机 |
| `window` | 120 帧 | 约 2 秒 @60Hz，够长到能看出稳定趋势，够短到用户还没开始摸 |
| `budgetMs` | 22ms | p90 超过它就等于掉到 45fps 以下 |
| `longFrameMs` | 40ms | 单帧 40ms 已经是肉眼可见的一顿 |
| `maxLongFrames` | 2 | 一个窗口里两次卡顿就够判了 |

两个判据分工明确：**p90** 抓「一直慢」的机器，**长帧计数**抓「平时挺好、一滚就噎住」的机器。单看 p90 会漏掉后者——120 帧里就 2 帧超 40ms，p90 仍是 16ms。

流程：跳过预热 → 攒满一个窗口 → 判定 → 超预算降一档 → 再攒一个窗口 → 到 `flat` 或合格即 `settled`。**只降不升**：一次卡顿的设备，等长列表出现时会再卡一次，来回跳档比稳定在低档更难受。

`start()` 在 debug 和 web 上直接 `settled`：debug 构建慢 3–5 倍，测它等于把每台开发机都判成 `flat`；web 走 swiftshader，帧耗时没有参考价值。

### 11.2 谁负责启动和停止

`RootShell` 是唯一持有者，`_syncProbe(config)` 在 `build` 里调用且幂等：

- 锁定档（`soft`/`full`/`flat`）→ 有探针就 `dispose`；
- `auto` → 没有就建，起步档取 `glassAutoTier`；已经是 `flat` 就别建，没有更低的档可证明；
- 探针运行中（未 `settled`）→ 一律不动。降级会回写配置，如果不挡住，这次回写会把探针重启，第二轮采样永远跑不完；
- 探针已 `settled` 且存量档位被**调高**（用户重新点了「自动」）→ 重建，允许重新评估。

`start()` 放在 `addPostFrameCallback` 里，避免在 build 期间注册引擎回调。

### 11.3 配置

| 字段 | 取值 | 作用 |
|---|---|---|
| `glassQuality` | `auto` / `flat` / `soft` / `full` | 用户的选择。默认 `auto` |
| `glassAutoTier` | `soft` / `flat` | 自动判定的落点，下次冷启动从这里起步 |
| `glassAutoHinted` | bool | 那次提示有没有弹过，一辈子只弹一次 |

迁移：`glassAutoHinted` 是 3.8.0 才有的键。反序列化时**没有这个键**的配置视为 3.8 之前的老配置，其 `glassQuality` 是当年的硬编码默认值而不是深思熟虑的选择，统一改成 `auto` 交给探针。有键的一律尊重用户设定。

`GlassQuality` 枚举里**不放** `auto`：它是偏好，不是渲染档。`parse('auto')` 返回 `soft` 兜底，`resolve(pref, autoTier:)` 才是外壳用的入口。这样枚举的 `values` 仍然是三个真档位，原有遍历测试不用改。

### 11.4 设置页

「外观 › 玻璃质感」从三段变四段：**自动 / 关闭 / 标准 / 强折射**。说明文字随选中项变化，`auto` 时显示实测落点（「当前：标准。」），让用户知道系统真的在测，而不是一个安慰按钮。

重新点「自动」会同时把 `glassAutoTier` 重置为 `soft`、`glassAutoHinted` 重置为 `false`——换机、关省电模式之后想重新评估，就是这个手势。

### 11.5 本轮修掉的两个问题

| 问题 | 原因 | 修法 |
|---|---|---|
| 说明文字末字落单（「当前：标 / 准。」） | 固定宽度下的自动折行点刚好卡在双字词中间 | `auto` 的说明改成显式两行：结论一行、当前档位一行 |
| 降档后点「自动」没有反应 | `_syncProbe` 只判 `_probe != null`，settled 的探针不会重建 | 增加「已 settled 且存量档位被调高 → 重建」分支 |

### 11.6 已知边界

- 采样只覆盖**启动后约 2.4 秒**。用户如果这段时间停在静态页面上，测到的是空载帧率，长列表滚动可能仍然吃力。彻底解决要在滚动中持续采样，代价是常态化的回调开销，不符合「零常驻成本」的初衷，暂不做。
- 沙箱只能验证逻辑与布局，**真机 60fps 需要实机抽查**：安装后连续滚动会话列表 10 秒，观察是否触发降档以及降档后是否稳定。

---

## 十二、P5 交互缺陷修复（v3.9.0）

这一批不是视觉打磨，是功能缺陷。外部审查按行号指出的五条，逐条对过代码，**全部属实**，其中两条会**静默丢弃用户数据**。

### 12.1 五条缺陷与修法

| # | 问题 | 原实现 | 修法 |
|---|---|---|---|
| 1 | 打字时停止键消失 | `showStop = streaming && !_hasText`，一键兼两用 | 拆成两个键：停止 44dp 描边、发送/排队 44dp 主色，并存 |
| 2 | 立即发送丢队列 | `stop(flushQueue:false)` 清空队列后只塞回第一条 | 先快照整队，中断后原样恢复；`finally` 自然从队头启动 |
| 3 | `@` 引用怕空格 | 插入 `@path`，解析 `@([^\s@]+)` | 含空格时插入 `@"path"`，解析 `@"([^"]+)"\|@([^\s@]+)` |
| 4 | 超大附件静默丢弃 | `_attachmentBlock` 超限返回 null，调用处 `continue` | 发送前拦截并说明原因；请求里补 `[Attachment omitted: …]` 文本占位 |
| 5 | 补全列表不刷新 | 只比 `length` 和 `first.label` | 整表签名比较（label + insert + hint） |

### 12.2 几个实现细节

**停止键为什么要两个尺寸一致**：44dp 是输入框的高度，两个键同高才能和输入框底部对齐；用描边而不是填充做层级区分，切换时不会有形状跳变。

**立即发送的语义**：改完之后它只表示「别等这轮结束，现在就开第一条」。队列不清空，第二条、第三条按原顺序继续。这是用户点这个按钮时的真实预期。

**附件为什么是拦截而不是跳过**：跳过会让消息看起来已送达，而模型根本没收到图。拦截把决策权还给用户——要么移除，要么换一张。请求层仍然保留兜底文本，覆盖「发送后被替换成大文件」这种时间窗。

**引号只在需要时加**：`@src/main.dart` 仍然是裸形式，只有路径含空格才写成 `@"My Project/a.dart"`。解析器两种都收，历史消息不受影响。

### 12.3 顺带修掉的一个预览 bug

`dev_preview.dart` 里一直有 `state.queue.add('…')`。但 `queue` 是个 getter：

```dart
List<String> get queue => <String>[for (final _QueuedTurn q in _queue) q.text];
```

每次返回新列表，`add` 加到一个随即丢弃的临时对象上——预览里的队列条从未出现过。改成 `state.streaming = true` 后调用 `send()`，走真正的入队分支。

### 12.4 测试

新增 `test/composer_flow_test.dart` 18 条：

- 队列：入队顺序、立即发送后三条全在（回归用例）、空队无操作、删除中间项、越界删除；
- 引用解析：裸路径、带空格、中文与全角括号、斜杠命令不算文件、重复路径、引号按需添加；
- 交互：空闲单键、生成中空框只有停止、**生成中打字两个键都在**（390dp 下 pump，溢出会直接失败）、超限附件拦截并出提示；
- 附件上限：图片 3MB、文本 512KB、大小未知不判超限。

全量 **116/116**，`flutter analyze` 无 error / warning。

---

## 十三、P6 队列并发修复（v3.9.1）

v3.9.0 修的是「立即发送清空队列」，这一版修的是**同一块代码里更隐蔽的一处**：队列在等下一轮启动的那 260ms 里，队头已经被摘出去了。

### 13.1 缺陷

```dart
// 修复前
void _drainQueue() {
  if (_queue.isEmpty) return;
  final _QueuedTurn next = _queue.removeAt(0);   // ← 先出队
  Future<void>.delayed(const Duration(milliseconds: 260), () {
    if (!streaming) _startTurn(next.text, ...);  // ← 再判能不能启动
  });
}
```

出队和判空隔着 260ms。这 260ms 里只要有一次 `send()` 成功启动新 turn（`streaming` 变 true），定时器醒来看到「有人正在跑」就直接返回——而那条消息**已经在外面了，没有任何地方会把它放回去**。

这是「上一轮刚修完队列丢失，同一函数里还剩一条丢法」。触发条件也不苛刻：AI 刚答完、用户看到结论立刻发下一条，正好落在这个窗口里。

### 13.2 修法

把「检查、出队、启动」压进同一个同步块，中间不留空隙：

```dart
void _drainQueue() {
  if (_queue.isEmpty) return;
  if (_queueTimer != null) return;          // 同一时刻只排一班
  _queueTimer = Timer(const Duration(milliseconds: 260), () {
    _queueTimer = null;
    if (streaming || _queue.isEmpty) return; // 队头没动，让赢家回头再排
    final _QueuedTurn next = _queue.first;   // peek，不取
    if (_startTurn(next.text, attachments: next.attachments)) {
      _queue.remove(next);
      notifyListeners();
    }
  });
}
```

三个要点：

| 点 | 为什么 |
|---|---|
| 队头用 `first` 而不是 `removeAt(0)` | 没启动成功就等于没消费过，天然幂等 |
| `_startTurn` 返回 `bool` | 「没登录 / 没配置」会拒绝启动，这种失败不能吃掉消息 |
| 出队后补一次 `notifyListeners` | `_startTurn` 内部那次通知发生在出队之前，队列条会一直挂着已经开始的那条 |

`_queueTimer` 既是去重也是节流：`finally`、`flushQueueNow`、用户连发都可能在同一帧里触发排空，重复调用现在只是 no-op，不会排进第二班。

### 13.3 @ 引用的附件：报告说「绕过检查」，实际是「没有反馈」

核对后结论要更正一半：`_fromMentions` 一直带着 `size: f.lengthSync()`，`_wireFrom` 也有 `exceedsLimit` 分支，所以超限的 `@` 文件**不会被静默丢弃**，请求里会留一条带原因的占位：

```
[Attachment omitted: shot.png is 5.0 MB, over the 3 MB limit]
```

真正的问题是**用户看不到**——输入框只校验自己那一排附件 chip，`@` 引用是在 `_startTurn` 里才解析的，拦不到。所以修在气泡：超限文件不再显示缩略图（反正不发），chip 转成错误色 + `未发送` 后缀。这是全链路唯一的可见落点，手动选的和 `@` 引用的走同一条渲染。

### 13.4 停止键的反馈

拆键解决了「打字时按不到停止」，但按下之后没有任何变化——工具正在执行时收尾可能要几秒，按钮看起来像没响应。

新增 `AppState.stopping`（`_cancelRequested && streaming`），停止键在此状态下换成 14dp 的转圈并禁用点按，tooltip / 语义标签同步变成「正在停止…」。同时补了 `Semantics(button: true)` 和 `Tooltip`，读屏用户之前只能听到一个没有标签的图标。

### 13.5 测试

**116 → 128**，新增 12 条：

| 组 | 用例 |
|---|---|
| 队列并发 | 队头在启动前不出队；重复排空不叠加；turn 运行中到点不消费；启动被拒时保留消息 |
| 窄屏 | 320 / 360 / 390dp 下双键并存，长文本不溢出 |
| 大字 | 320dp + 1.3 倍字体 |
| 多行 | 四行草稿两个键仍可达 |
| 停止态 | 请求停止后显示转圈、不再显示停止图标 |
| 气泡 | 超限 chip 出现「未发送」；正常 chip 不出现 |

窄屏那几条不靠肉眼：`RenderFlex overflow` 会直接让 `testWidgets` 失败。
