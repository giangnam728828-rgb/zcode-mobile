# Flutter 3.0 → 3.50.1 升级记录

> 目的：拿到 `ImageFilter.shader` / `FragmentProgram`，使真液态玻璃（折射 + 色散）成为可能。
> 结果：已完成，构建通过，73 条测试全绿。

## 版本对照

| 项 | 升级前 | 升级后 |
|---|---|---|
| Flutter | 3.0.0 | **3.50.1** |
| Dart | 2.17 | **3.14.0** |
| Gradle | 7.4 | **9.5.0** |
| AGP | 7.1.2 | **9.3.1** |
| Kotlin | 1.6.10 | **2.4.20** |
| compileSdk / targetSdk | 33 | **36** |
| Java | 8 | **17** |
| CI JDK | 11 | **17** |

## 依赖

九个包全部升级，其中三个跨大版本：

| 包 | 旧 | 新 |
|---|---|---|
| `http` | 0.13.5 | 1.6.0 |
| `flutter_secure_storage` | 5.0.2 | 11.2.0 |
| `flutter_markdown` | 0.6.12 | 0.7.7+1 |
| `markdown` | 6.0.0 | 7.3.1 |
| `shared_preferences` | 2.0.15 | 2.5.6 |
| `path_provider` | 2.0.11 | 2.1.6 |
| `url_launcher` | 6.1.0 | 6.3.3 |
| `provider` | 6.0.3 | 6.1.5 |
| `flutter_lints` | 2.0.0 | 5.0.0 |

新增：`liquid_glass_widgets: 1.19.0`（MIT、零第三方依赖、要求 Flutter ≥ 3.41）。

## 代码改动

| 类型 | 数量 | 说明 |
|---|---|---|
| 编译错误修复 | 10 | `styleFrom(primary:/onPrimary:)` → `backgroundColor:/foregroundColor:` 8 处；`CardTheme`/`DialogTheme` → `*ThemeData` 2 处 |
| 弃用 API 清理 | 310 | `withOpacity(x)` → `withValues(alpha: x)` |
| 构建系统 | 4 文件 | `settings.gradle` 改为 declarative plugins block、`build.gradle` 去 buildscript、`app/build.gradle` 用 plugins{} + namespace、wrapper 换 9.5.0-bin |

## 踩到的五个坑

1. **Gradle 9.5 404** —— 模板版本是 `9.5.0`，`9.5` 不存在；另换 `-bin` 包，CI 少下 90 MB。
2. **`app_plugin_loader.gradle` 被移除** —— Flutter 3.50 不再允许 `apply from` 方式，必须写 `plugins { id "dev.flutter.flutter-gradle-plugin" }` 并在 `settings.gradle` 里 `includeBuild` 工具链。
3. **AGP 9 只做 v2/v3 签名** —— 旧校验脚本找 `META-INF/*.RSA` 必然失败，改用 `apksigner verify --print-certs`。
4. **指纹格式不一致** —— apksigner 输出小写无冒号，存储的是大写带冒号，比较前需归一化（不是签名错，是格式错）。
5. **`flutter analyze` 判 info 为失败** —— 309 个 `withOpacity` 弃用 + 55 个 `material.dart` 弃用。前者真修，后者加 `deprecated_member_use: ignore` 并在 CI 用 `--no-fatal-infos`。

## 验证

| 项 | 结果 |
|---|---|
| `flutter analyze` | 0 error，20 info（`use_super_parameters` 等风格建议） |
| `flutter test` | **73/73** 通过，未修改任何测试 |
| APK 构建 | [Actions 44888780418](https://github.com/giangnam728828-rgb/zcode-mobile/actions/runs/44888780418) 成功，apksigner 校验通过 |
| 签名 | 与 3.4.0 同一把钥匙（SHA-256 `320ba94f…`），可覆盖安装 |
| 玻璃库编译 | `GlassScaffold` / `GlassAppBar` / `GlassTabBar.bottom` / `GlassGroupedSection` / `GlassListTile` / `GlassContainer.card` 全部通过 analyze |

## 遗留

- `package:flutter/material.dart` 已在 3.47 弃用，官方迁移目标是 `package:material_ui/material_ui.dart`。涉及 55 个 import，建议与 UI 重构一起做，而不是单独一轮。
- `liquid_glass_widgets` 的 `GlassCard` 已弃用，用 `GlassContainer.card`；README 里的 `GlassBottomBar` 也已更名为 `GlassTabBar.bottom`。
- Impeller 才有完整 shader 管线（Android 默认开启）；Skia/Web 走 lightweight shader，折射与色散会弱一些，因此 Web 预览不能代表真机效果。
