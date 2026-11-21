import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A file a plugin drops into `.zcode/`. Paths are relative to that folder so
/// `skills/foo.md` lands next to the agent's other skills and is picked up by
/// the next turn without a restart.
class PluginFile {
  const PluginFile(this.path, this.content);

  final String path;
  final String content;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'path': path,
        'content': content,
      };

  static PluginFile fromJson(Map<String, dynamic> json) =>
      PluginFile('${json['path']}', '${json['content'] ?? ''}');
}

/// Kinds map one-to-one onto what the desktop client loads at startup.
class PluginKind {
  static const String skill = 'skill';
  static const String command = 'command';
  static const String agent = 'agent';
  static const String mcp = 'mcp';
  static const String bundle = 'bundle';
}

class PluginManifest {
  const PluginManifest({
    required this.id,
    required this.name,
    required this.description,
    this.emoji = '🧩',
    this.author = 'community',
    this.version = '1.0.0',
    this.kind = PluginKind.skill,
    this.category = '工具',
    this.tags = const <String>[],
    this.homepage = '',
    this.files = const <PluginFile>[],
    this.mcp = const <String, dynamic>{},
    this.source = 'builtin',
  });

  final String id;
  final String name;
  final String description;
  final String emoji;
  final String author;
  final String version;
  final String kind;
  final String category;
  final List<String> tags;
  final String homepage;
  final List<PluginFile> files;

  /// Raw `mcpServers` fragment, merged into `.zcode/mcp.json` on install.
  final Map<String, dynamic> mcp;
  final String source;

  bool get isMcp => kind == PluginKind.mcp || mcp.isNotEmpty;

  String get kindLabel {
    switch (kind) {
      case PluginKind.skill:
        return '技能';
      case PluginKind.command:
        return '命令';
      case PluginKind.agent:
        return '子智能体';
      case PluginKind.mcp:
        return 'MCP';
      default:
        return '组合包';
    }
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'description': description,
        'emoji': emoji,
        'author': author,
        'version': version,
        'kind': kind,
        'category': category,
        'tags': tags,
        'homepage': homepage,
        'files': files.map((PluginFile f) => f.toJson()).toList(),
        if (mcp.isNotEmpty) 'mcp': mcp,
        'source': source,
      };

  static PluginManifest fromJson(Map<String, dynamic> json) {
    final List<PluginFile> files = <PluginFile>[];
    final Object? rawFiles = json['files'];
    if (rawFiles is List) {
      for (final Object? item in rawFiles) {
        if (item is Map) {
          final String path = '${item['path'] ?? ''}';
          if (path.isNotEmpty) {
            files.add(PluginFile(path, '${item['content'] ?? ''}'));
          }
        }
      }
    }
    return PluginManifest(
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? json['id'] ?? ''}',
      description: '${json['description'] ?? ''}',
      emoji: '${json['emoji'] ?? '🧩'}',
      author: '${json['author'] ?? 'community'}',
      version: '${json['version'] ?? '1.0.0'}',
      kind: '${json['kind'] ?? PluginKind.skill}',
      category: '${json['category'] ?? '工具'}',
      tags: ((json['tags'] as List?) ?? <dynamic>[])
          .map((dynamic e) => '$e')
          .toList(),
      homepage: '${json['homepage'] ?? ''}',
      files: files,
      mcp: (json['mcp'] as Map?)?.cast<String, dynamic>() ??
          (json['mcpServers'] as Map?)?.cast<String, dynamic>() ??
          <String, dynamic>{},
      source: '${json['source'] ?? 'remote'}',
    );
  }
}

class InstalledPlugin {
  InstalledPlugin({
    required this.manifest,
    required this.files,
    DateTime? installedAt,
    this.enabled = true,
  }) : installedAt = installedAt ?? DateTime.now();

  final PluginManifest manifest;

  /// Relative paths under `.zcode/` that this plugin owns.
  final List<String> files;
  final DateTime installedAt;
  bool enabled;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'manifest': manifest.toJson(),
        'files': files,
        'installedAt': installedAt.toIso8601String(),
        'enabled': enabled,
      };

  static InstalledPlugin fromJson(Map<String, dynamic> json) => InstalledPlugin(
        manifest: PluginManifest.fromJson(
          (json['manifest'] as Map?)?.cast<String, dynamic>() ??
              <String, dynamic>{},
        ),
        files: ((json['files'] as List?) ?? <dynamic>[])
            .map((dynamic e) => '$e')
            .toList(),
        installedAt:
            DateTime.tryParse('${json['installedAt']}') ?? DateTime.now(),
        enabled: (json['enabled'] as bool?) ?? true,
      );
}

/// Installs plugins the way DSH-style clients do: pick one from the catalog (or
/// paste a manifest URL) and it is downloaded straight into the workspace,
/// ready for the next message. No rebuild, no companion app.
class PluginCenter {
  PluginCenter(this.workspace);

  /// Null only in the web preview, where there is no file system.
  final Directory? workspace;
  final Map<String, InstalledPlugin> _installed = <String, InstalledPlugin>{};
  bool loaded = false;
  String? error;

  /// Fired after every install / remove / toggle so the app can re-read
  /// skills. The flag says whether mcp.json changed, because reconnecting
  /// servers is slow and pointless for a plain skill.
  void Function(bool mcpChanged)? onChanged;

  Directory get _zcode => Directory('${workspace!.path}/.zcode');
  File get _stateFile => File('${_zcode.path}/plugins.json');

  List<InstalledPlugin> get installed {
    final List<InstalledPlugin> list = _installed.values.toList();
    list.sort((InstalledPlugin a, InstalledPlugin b) =>
        b.installedAt.compareTo(a.installedAt));
    return list;
  }

  bool isInstalled(String id) => _installed.containsKey(id);

  Future<void> load() async {
    loaded = true;
    try {
      if (!await _stateFile.exists()) return;
      final Object? raw = jsonDecode(await _stateFile.readAsString());
      if (raw is! Map) return;
      _installed.clear();
      raw.forEach((dynamic key, dynamic value) {
        if (value is Map) {
          final InstalledPlugin p =
              InstalledPlugin.fromJson(value.cast<String, dynamic>());
          if (p.manifest.id.isNotEmpty) _installed['$key'] = p;
        }
      });
    } catch (e) {
      error = '读取插件状态失败：$e';
    }
  }

  Future<void> _persist() async {
    await _zcode.create(recursive: true);
    final Map<String, dynamic> data = <String, dynamic>{};
    _installed.forEach((String id, InstalledPlugin p) {
      data[id] = p.toJson();
    });
    await _stateFile.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
  }

  /// Downloads a manifest. Accepts a single object, a bare array, or the
  /// `{ "plugins": [...] }` registry shape so most community indexes work.
  Future<List<PluginManifest>> fetchManifest(String url) async {
    final Uri? uri = Uri.tryParse(url.trim());
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      throw ArgumentError('只支持 http(s) 地址');
    }
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..userAgent = 'ZCode-Mobile/3.1';
    try {
      final HttpClientRequest req = await client.getUrl(uri);
      req.headers.set('accept', 'application/json');
      final HttpClientResponse resp = await req.close();
      final String body = await resp
          .transform(const Utf8Decoder(allowMalformed: true))
          .join()
          .timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) {
        throw StateError('获取插件清单失败（HTTP ${resp.statusCode}）');
      }
      final Object? raw = jsonDecode(body);
      final List<dynamic> rows = raw is List
          ? raw
          : raw is Map && raw['plugins'] is List
              ? raw['plugins'] as List<dynamic>
              : raw is Map
                  ? <dynamic>[raw]
                  : <dynamic>[];
      final List<PluginManifest> out = <PluginManifest>[];
      for (final Object? row in rows) {
        if (row is! Map) continue;
        final PluginManifest m = PluginManifest.fromJson(
          row.cast<String, dynamic>(),
        );
        if (m.id.isNotEmpty && (m.files.isNotEmpty || m.mcp.isNotEmpty)) {
          out.add(m);
        }
      }
      if (out.isEmpty) throw StateError('清单里没有可安装的插件');
      return out;
    } finally {
      client.close(force: true);
    }
  }

  /// Writes every file, merges MCP servers and records the install. Replaces an
  /// older version of the same id so updates are a single tap.
  Future<InstalledPlugin> install(PluginManifest manifest) async {
    final String id = _safeId(manifest.id);
    if (id.isEmpty) throw ArgumentError('插件 id 无效');
    for (final PluginFile f in manifest.files) {
      final String rel = _safeRel(f.path);
      if (rel.isEmpty) continue;
      final File target = File('${_zcode.path}/$rel');
      await target.parent.create(recursive: true);
      await target.writeAsString(f.content);
    }
    if (manifest.mcp.isNotEmpty) await _mergeMcp(manifest.mcp);

    final List<String> owned = <String>[
      for (final PluginFile f in manifest.files)
        if (_safeRel(f.path).isNotEmpty) _safeRel(f.path),
    ];
    // Files from a previous version that the new manifest dropped.
    final InstalledPlugin? old = _installed[id];
    if (old != null) {
      for (final String rel in old.files) {
        if (owned.contains(rel)) continue;
        try {
          final File f = File('${_zcode.path}/$rel');
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }
    final InstalledPlugin p = InstalledPlugin(
      manifest: manifest,
      files: owned,
    );
    _installed[id] = p;
    await _persist();
    onChanged?.call(manifest.mcp.isNotEmpty ||
        (old != null && old.manifest.mcp.isNotEmpty));
    return p;
  }

  Future<void> uninstall(String id) async {
    final InstalledPlugin? p = _installed[id];
    if (p == null) return;
    for (final String rel in p.files) {
      try {
        final File f = File('${_zcode.path}/$rel');
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    if (p.manifest.mcp.isNotEmpty) {
      await _dropMcp(p.manifest.mcp.keys.toList());
    }
    _installed.remove(id);
    await _persist();
    onChanged?.call(p.manifest.mcp.isNotEmpty);
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final InstalledPlugin? p = _installed[id];
    if (p == null) return;
    p.enabled = enabled;
    // Disabled plugins still keep their bytes; only the MCP registration is
    // pulled so a broken server cannot block every turn.
    if (p.manifest.mcp.isNotEmpty) {
      if (enabled) {
        await _mergeMcp(p.manifest.mcp);
      } else {
        await _dropMcp(p.manifest.mcp.keys.toList());
      }
    }
    await _persist();
    onChanged?.call(p.manifest.mcp.isNotEmpty);
  }

  // ------------------------------------------------------------------ helpers

  String _safeId(String raw) => raw
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9._-]'), '-')
      .replaceAll(RegExp('-{2,}'), '-')
      .replaceAll(RegExp(r'^-|-$'), '');

  /// Rejects absolute paths and `..` so a manifest cannot write outside
  /// `.zcode/`.
  static String _safeRel(String raw) {
    final String path = raw.replaceAll('\\', '/').trim();
    if (path.isEmpty || path.startsWith('/')) return '';
    final List<String> parts = <String>[];
    for (final String part in path.split('/')) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') return '';
      parts.add(part);
    }
    if (parts.isEmpty) return '';
    final String joined = parts.join('/');
    if (!joined.startsWith('skills/') &&
        !joined.startsWith('commands/') &&
        !joined.startsWith('agents/') &&
        !joined.startsWith('plugins/')) {
      return '';
    }
    return joined;
  }

  File get _mcpFile => File('${_zcode.path}/mcp.json');

  Future<Map<String, dynamic>> _readMcp() async {
    try {
      if (!await _mcpFile.exists()) return <String, dynamic>{};
      final Object? raw = jsonDecode(await _mcpFile.readAsString());
      if (raw is Map && raw['mcpServers'] is Map) {
        return (raw['mcpServers'] as Map).cast<String, dynamic>();
      }
    } catch (_) {}
    return <String, dynamic>{};
  }

  Future<void> _mergeMcp(Map<String, dynamic> servers) async {
    final Map<String, dynamic> current = await _readMcp();
    servers.forEach((String key, dynamic value) {
      current[key] = value;
    });
    await _zcode.create(recursive: true);
    await _mcpFile.writeAsString(
      const JsonEncoder.withIndent('  ')
          .convert(<String, dynamic>{'mcpServers': current}),
    );
  }

  Future<void> _dropMcp(List<String> keys) async {
    final Map<String, dynamic> current = await _readMcp();
    for (final String key in keys) {
      current.remove(key);
    }
    await _mcpFile.writeAsString(
      const JsonEncoder.withIndent('  ')
          .convert(<String, dynamic>{'mcpServers': current}),
    );
  }
}

/// Built-in catalog. Everything ships as text inside the APK, so installing is
/// instant and works offline — the same "download and it just works" feel as
/// the DSH plugin flow, without a server round-trip.
class PluginCatalog {
  static const List<PluginManifest> all = <PluginManifest>[
    PluginManifest(
      id: 'code-review',
      name: '代码评审',
      emoji: '🔍',
      description: '按严重程度分级评审改动，先找真实缺陷，再谈风格。',
      kind: PluginKind.skill,
      category: '工程',
      tags: <String>['review', '质量'],
      files: <PluginFile>[
        PluginFile('skills/code-review.md', '''
# 代码评审

被要求评审代码或改动时，按下面的顺序读，不要一上来就挑格式。

## 1. 先建立上下文
- 用 `glob` / `grep` 找到调用方和测试，确认这段代码的契约是什么。
- 读 `AGENTS.md`，遵守项目自己的约定，不要套用外部风格。

## 2. 按严重程度找问题
- **必须改**：空指针/越界、资源未释放、并发竞争、注入与越权、吞异常、错误的边界条件。
- **建议改**：重复逻辑、命名误导、可测试性差、复杂度失控。
- **可选**：风格、注释、微优化。

## 3. 输出格式
每条问题给出：文件:行号 → 问题 → 触发条件 → 建议改法（能直接用的代码）。
没有问题就直说，不要为了凑数编造。

## 4. 收尾
给出「是否建议合入」的结论，并说明你实际读过哪些文件、有没有跑测试。
'''),
      ],
    ),
    PluginManifest(
      id: 'bug-hunter',
      name: '缺陷猎手',
      emoji: '🐛',
      description: '独立的排障子智能体：复现、二分、定位根因，再谈修复。',
      kind: PluginKind.agent,
      category: '工程',
      tags: <String>['debug', '子智能体'],
      files: <PluginFile>[
        PluginFile('agents/bug-hunter.md', '''
你是缺陷排查专家。你只做定位，不在没复现之前改代码。

## 方法
1. 先复现：找到能稳定触发的最小命令或输入。复现不了就说明还缺什么信息。
2. 缩小范围：用日志、`grep`、二分注释、打印关键变量，把范围切到最小。
3. 说清根因：不要停在「这里报错」，要回答「为什么这里会拿到这个值」。
4. 给出修复：最小改动 + 为什么不会引入回归。
5. 验证：真的跑一遍，把输出贴出来。

## 输出
- 复现步骤（可复制）
- 根因（一句话 + 证据）
- 修复（diff 或具体文件行）
- 验证结果
'''),
      ],
    ),
    PluginManifest(
      id: 'test-writer',
      name: '测试编写',
      emoji: '🧪',
      description: '为指定模块补测试：先覆盖行为，再覆盖边界，最后才追求覆盖率数字。',
      kind: PluginKind.agent,
      category: '工程',
      tags: <String>['test', '子智能体'],
      files: <PluginFile>[
        PluginFile('agents/test-writer.md', '''
你是测试工程师。目标是把「这段代码应该怎样」写成能跑的断言。

## 步骤
1. 读实现与现有测试，沿用同样的框架、命名与目录结构。
2. 列出行为清单：正常路径、边界值、错误路径、并发/重复调用、空输入。
3. 优先写最容易回归的那几条，不要一次生成几十个凑数用例。
4. 每个测试只断言一件事，名字要能说明失败原因。
5. 跑测试；失败时先判断是实现错还是测试错，并把结论说清楚。

## 禁止
- 不要 mock 掉被测对象本身。
- 不要为了让测试通过而放宽断言。
'''),
      ],
    ),
    PluginManifest(
      id: 'refactorer',
      name: '重构助手',
      emoji: '🧱',
      description: '小步重构：每次一个可验证的动作，保持行为不变。',
      kind: PluginKind.agent,
      category: '工程',
      tags: <String>['refactor', '子智能体'],
      files: <PluginFile>[
        PluginFile('agents/refactorer.md', '''
你是重构专家，原则是「行为不变、步子要小、每步可回滚」。

## 流程
1. 先用测试或命令记录当前行为基线。
2. 找出真实的坏味道：重复、过长函数、隐式耦合、可变全局状态。
3. 一次只做一个动作（提取函数、改名、搬移、内联）。
4. 每步之后跑验证；失败就退回上一步，不要继续叠。
5. 最后总结结构变化，并确认外部行为完全一致。

不要顺手改需求，也不要重写整个文件。
'''),
      ],
    ),
    PluginManifest(
      id: 'commit-msg',
      name: '提交信息',
      emoji: '📝',
      description: '斜杠命令 /commit：读改动生成符合约定的提交信息。',
      kind: PluginKind.command,
      category: '工程',
      tags: <String>['git', '命令'],
      files: <PluginFile>[
        PluginFile('commands/commit.md', '''
---
name: commit
description: 根据当前改动生成提交信息
usage: /commit
---
请检查工作区当前的改动（用 `bash` 跑 git status / git diff，若没有 git 就直接读改动文件），然后：

1. 用一句话概括这次改动的目的（为什么改，而不是改了哪几行）。
2. 按 Conventional Commits 给出标题：`type(scope): subject`，不超过 72 字符。
3. 列出 2-4 条正文要点，说明影响范围与验证方式。
4. 如果有破坏性变更或需要迁移，单独标注 BREAKING CHANGE。

只输出提交信息本身，不要执行 commit。

\$ARGUMENTS
'''),
      ],
    ),
    PluginManifest(
      id: 'explain-code',
      name: '代码讲解',
      emoji: '💡',
      description: '斜杠命令 /explain：把一段代码讲清结构、数据流和坑。',
      kind: PluginKind.command,
      category: '学习',
      tags: <String>['explain', '命令'],
      files: <PluginFile>[
        PluginFile('commands/explain.md', '''
---
name: explain
description: 讲解指定文件或代码片段
usage: /explain <文件或问题>
---
请讲解下面的目标，面向「能写代码但没读过这个项目」的读者：

1. 它解决什么问题，在整体里处于什么位置。
2. 关键数据从哪里来、经过哪些变换、到哪里去。
3. 逐个说明最重要的 3-5 个函数或类，用具体行号定位。
4. 指出容易踩的坑：隐含假设、边界条件、性能陷阱。
5. 最后给一个最小可运行的调用示例。

需要时先读文件再回答，不要凭空猜测。

\$ARGUMENTS
'''),
      ],
    ),
    PluginManifest(
      id: 'android-shell',
      name: 'Android Shell',
      emoji: '🤖',
      description: '在手机上操作系统的实用命令：截图、剪贴板、应用、存储。',
      kind: PluginKind.skill,
      category: '设备',
      tags: <String>['android', 'shell'],
      files: <PluginFile>[
        PluginFile('skills/android-shell.md', '''
# Android Shell 手册

工作区里只有 sh + toybox，没有 root。下面这些命令通常可用，用之前先 `command -v` 确认。

## 查看环境
- `getprop ro.build.version.release` 系统版本
- `wm size` / `wm density` 屏幕分辨率与密度
- `df -h` 磁盘，`free -m` 内存

## 截图与录屏
- `screencap -p shot.png` 截屏到工作区
- `screenrecord --time-limit 10 clip.mp4` 录屏十秒

## 应用
- `pm list packages | grep 关键字` 找包名
- `am start -n 包名/Activity` 启动界面
- `am force-stop 包名`

## 注意
- 不要尝试 `su`，绝大多数设备没有 root。
- 读写外部存储需要权限，优先在应用私有工作区里操作。
- 命令不存在时不要假装成功，明确告诉用户缺什么。
'''),
      ],
    ),
    PluginManifest(
      id: 'web-research',
      name: '联网调研',
      emoji: '🌐',
      description: '多来源检索、交叉验证、给出处，拒绝单一来源的结论。',
      kind: PluginKind.skill,
      category: '写作',
      tags: <String>['research', 'web'],
      files: <PluginFile>[
        PluginFile('skills/web-research.md', '''
# 联网调研

## 流程
1. 把问题拆成 2-4 个可检索的子问题。
2. 每个子问题至少查两个独立来源；官方文档优先于博客，博客优先于聚合站。
3. 用 `web_fetch` 打开原文核对关键数字，不要只读搜索摘要。
4. 冲突的信息要并列呈现，说明哪个更可信以及理由。
5. 结论部分只写有来源支撑的内容，推断要明确标注为推断。

## 输出
- 先给三句话结论。
- 再给分点论据，每条后面附来源链接。
- 最后列出「仍不确定的地方」。

不要编造 URL、版本号或发布日期。抓不到页面就直说。
'''),
      ],
    ),
    PluginManifest(
      id: 'api-debug',
      name: '接口调试',
      emoji: '🔌',
      description: '用 curl 复现请求、定位状态码与鉴权问题，并给出可复用命令。',
      kind: PluginKind.skill,
      category: '工程',
      tags: <String>['api', 'curl'],
      files: <PluginFile>[
        PluginFile('skills/api-debug.md', '''
# 接口调试

## 步骤
1. 先构造最小请求：`curl -i -sS -X POST URL -H 'content-type: application/json' -d '{...}'`
2. 看状态码分类：4xx 是请求问题（路径、参数、鉴权），5xx 是服务端问题。
3. 逐步加回 header、cookie、body 字段，找出哪个因素导致失败。
4. 需要看耗时加 `-w '\\n%{http_code} %{time_total}s\\n'`。
5. 成功之后把可用命令整理成一行，方便用户直接复用。

## 注意
- 不要把真实 token 写进回复或文件，用 \$TOKEN 占位。
- 涉及生产环境的写操作先停下来问用户。
- 手机网络可能被代理拦截，先确认 `curl -I https://example.com` 是否通。
'''),
      ],
    ),
    PluginManifest(
      id: 'git-workflow',
      name: 'Git 工作流',
      emoji: '🌿',
      description: '分支、暂存、冲突处理的固定套路，避免误操作。',
      kind: PluginKind.skill,
      category: '工程',
      tags: <String>['git'],
      files: <PluginFile>[
        PluginFile('skills/git-workflow.md', '''
# Git 工作流

手机上的 git 可能未安装。先用 `command -v git` 检查；没有就提示用户在「扩展模块」里安装，不要假装提交成功。

## 安全规则
- 不用 `git reset --hard`、`git checkout -- .`、`push --force`，除非用户明确要求。
- 提交前先 `git status` + `git diff`，确认没有把密钥、构建产物带进去。
- 不跳过 hooks（不加 `--no-verify`）。

## 常用流程
1. `git status --short` 看改动范围。
2. `git diff` 逐块确认。
3. `git add -A`（或指定文件）。
4. `git commit -m "type(scope): subject"`，正文说明动机与验证。
5. 推送失败先 `git pull --rebase`，冲突逐个解决后继续。

## 冲突
读懂两边意图再合并，不要无脑取一边。解决后跑一次测试再继续。
'''),
      ],
    ),
    PluginManifest(
      id: 'mobile-ui',
      name: '移动端 UI',
      emoji: '📱',
      description: '小屏布局、触控目标、暗色模式与流畅度的检查清单。',
      kind: PluginKind.skill,
      category: '设计',
      tags: <String>['ui', 'flutter'],
      files: <PluginFile>[
        PluginFile('skills/mobile-ui.md', '''
# 移动端 UI 规范

## 布局
- 以 360dp 宽为底线设计，任何一行都不能溢出；长文本必须 ellipsis 或换行。
- 触控目标不小于 44×44dp，图标按钮要有足够的 padding。
- 键盘弹起时输入框必须可见；列表底部留出 safe area。

## 视觉
- 正文 14-16sp，行高 1.5 左右；次要信息 11-12sp 且不要低于 0.38 透明度。
- 颜色一律取自主题 ColorScheme，不要在深色模式里硬编码白色。
- 圆角统一（8/12/16），阴影克制。

## 流畅度
- 长列表用 builder 懒加载，只渲染可见窗口。
- 流式输出合帧刷新，不要每个 token 都 setState。
- 重活（解压、下载、扫描）放后台，UI 只显示进度。

## 验收
在 360×780 与 820×900 两个尺寸、明暗两套主题下各看一遍，再截图确认没有裁切。
'''),
      ],
    ),
    PluginManifest(
      id: 'security-audit',
      name: '安全自查',
      emoji: '🛡️',
      description: '提交前过一遍注入、越权、密钥泄露与依赖风险。',
      kind: PluginKind.skill,
      category: '安全',
      tags: <String>['security', 'audit'],
      files: <PluginFile>[
        PluginFile('skills/security-audit.md', '''
# 安全自查

按下面五项过一遍，发现问题直接给修复代码。

1. **输入**：所有外部输入是否校验类型、长度、范围？拼接 SQL/命令时是否参数化？
2. **越权**：文件路径是否限制在允许目录？接口是否校验资源归属？有没有 `../` 穿越？
3. **密钥**：仓库里是否出现 token、keystore、`.env`？日志是否打印敏感字段？
4. **传输**：是否强制 https？是否校验证书？重定向会不会把 token 带到别的域？
5. **依赖**：有没有明显过时或已知漏洞的包？是否锁定了版本？

输出格式：风险等级 / 位置 / 攻击方式 / 修复。没有发现就写「未发现」，不要凑数。
'''),
      ],
    ),
    PluginManifest(
      id: 'doc-writer',
      name: '文档撰写',
      emoji: '📚',
      description: '把零散材料整理成结构清晰、可直接交付的文档。',
      kind: PluginKind.agent,
      category: '写作',
      tags: <String>['doc', '子智能体'],
      files: <PluginFile>[
        PluginFile('agents/doc-writer.md', '''
你是技术文档作者。目标读者是第一次接触这个项目的人。

## 结构
1. 一句话说明这是什么、解决什么问题。
2. 快速开始：从零到跑起来的最短路径，命令必须可复制。
3. 核心概念：只解释读者必须知道的 3-5 个。
4. 常见任务：按「我想做 X」组织，而不是按代码结构组织。
5. 排障：真实会遇到的报错与解法。

## 要求
- 先读代码与现有文档，术语与项目保持一致。
- 不写空话，每段都要有信息量。
- 命令、路径、版本号必须核对过。
'''),
      ],
    ),
    PluginManifest(
      id: 'starter-web',
      name: '网页起手模板',
      emoji: '🎨',
      description: '一个可直接改的单页站点：语义化 HTML + 响应式 CSS + 原生 JS。',
      kind: PluginKind.bundle,
      category: '资源',
      tags: <String>['web', '模板'],
      files: <PluginFile>[
        PluginFile('plugins/starter-web/index.html', '''
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>起手页</title>
  <link rel="stylesheet" href="style.css">
</head>
<body>
  <header class="bar">
    <strong>项目名</strong>
    <nav><a href="#work">工作</a><a href="#about">关于</a></nav>
  </header>
  <main>
    <section class="hero">
      <h1>一句话说清你在做什么</h1>
      <p>补充一句给谁解决什么问题。</p>
      <button id="cta" class="btn">主要操作</button>
    </section>
    <section id="work" class="grid">
      <article><h2>卡片一</h2><p>说明。</p></article>
      <article><h2>卡片二</h2><p>说明。</p></article>
      <article><h2>卡片三</h2><p>说明。</p></article>
    </section>
  </main>
  <footer id="about">© 2026</footer>
  <script src="app.js"></script>
</body>
</html>
'''),
        PluginFile('plugins/starter-web/style.css', '''
:root {
  --bg: #ffffff;
  --fg: #14161a;
  --muted: #5b6472;
  --accent: #2f6df6;
  --line: #e6e9ef;
}
@media (prefers-color-scheme: dark) {
  :root { --bg: #0e1014; --fg: #eef1f5; --muted: #9aa4b2; --line: #232833; }
}
* { box-sizing: border-box; }
body {
  margin: 0; background: var(--bg); color: var(--fg);
  font: 16px/1.65 system-ui, -apple-system, "Noto Sans SC", sans-serif;
}
.bar {
  display: flex; align-items: center; justify-content: space-between;
  padding: 14px 20px; border-bottom: 1px solid var(--line);
}
.bar nav a { color: var(--muted); text-decoration: none; margin-left: 16px; }
main { max-width: 960px; margin: 0 auto; padding: 0 20px; }
.hero { padding: 64px 0 40px; }
.hero h1 { font-size: clamp(26px, 6vw, 44px); line-height: 1.2; margin: 0 0 12px; }
.hero p { color: var(--muted); margin: 0 0 22px; }
.btn {
  border: 0; border-radius: 10px; padding: 12px 20px;
  background: var(--accent); color: #fff; font-size: 15px; cursor: pointer;
}
.grid {
  display: grid; gap: 14px; padding-bottom: 56px;
  grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
}
.grid article { border: 1px solid var(--line); border-radius: 14px; padding: 18px; }
.grid h2 { font-size: 16px; margin: 0 0 6px; }
.grid p { margin: 0; color: var(--muted); font-size: 14px; }
footer { padding: 24px 20px; border-top: 1px solid var(--line); color: var(--muted); font-size: 13px; }
'''),
        PluginFile('plugins/starter-web/app.js', '''
const cta = document.getElementById('cta');
cta?.addEventListener('click', () => {
  cta.textContent = '已触发 · ' + new Date().toLocaleTimeString();
});
'''),
      ],
    ),
    PluginManifest(
      id: 'python-toolbox',
      name: 'Python 小工具箱',
      emoji: '🐍',
      description: '三个常用脚本：批量压图、CSV 转 JSON、文本去重排序。',
      kind: PluginKind.bundle,
      category: '资源',
      tags: <String>['python', '脚本'],
      files: <PluginFile>[
        PluginFile('plugins/python-toolbox/img_resize.py', '''
# 批量把图片缩到最长边 N 像素。用法：python img_resize.py 目录 1280
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: img_resize.py <dir> [max_edge]")
        return 2
    try:
        from PIL import Image
    except ImportError:
        print("need Pillow: pip install pillow")
        return 3
    root = Path(sys.argv[1])
    limit = int(sys.argv[2]) if len(sys.argv) > 2 else 1280
    done = 0
    for p in root.rglob("*"):
        if p.suffix.lower() not in {".jpg", ".jpeg", ".png", ".webp"}:
            continue
        try:
            im = Image.open(p)
            im.thumbnail((limit, limit))
            im.save(p, optimize=True, quality=82)
            done += 1
        except Exception as e:
            print(f"skip {p}: {e}")
    print(f"resized {done} files")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
'''),
        PluginFile('plugins/python-toolbox/csv2json.py', '''
# CSV 转 JSON 数组。用法：python csv2json.py in.csv out.json
import csv
import json
import sys


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: csv2json.py <in.csv> [out.json]")
        return 2
    src = sys.argv[1]
    dst = sys.argv[2] if len(sys.argv) > 2 else src.rsplit(".", 1)[0] + ".json"
    with open(src, newline="", encoding="utf-8-sig") as f:
        rows = list(csv.DictReader(f))
    with open(dst, "w", encoding="utf-8") as f:
        json.dump(rows, f, ensure_ascii=False, indent=2)
    print(f"{len(rows)} rows -> {dst}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
'''),
        PluginFile('plugins/python-toolbox/text_tidy.py', '''
# 文本清洗：去空行、去首尾空格、去重并排序。用法：python text_tidy.py in.txt
import sys


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: text_tidy.py <file>")
        return 2
    p = sys.argv[1]
    with open(p, encoding="utf-8") as f:
        lines = [l.strip() for l in f]
    out = sorted({l for l in lines if l})
    with open(p, "w", encoding="utf-8") as f:
        f.write("\\n".join(out) + "\\n")
    print(f"{len(lines)} -> {len(out)} lines")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
'''),
        PluginFile('plugins/python-toolbox/README.md', '''
# Python 小工具箱

需要手机上有 python。没有的话先在「扩展模块」里装一个运行时。

- `python img_resize.py 图片目录 1280` 批量压图（需 Pillow）
- `python csv2json.py data.csv` 转 JSON
- `python text_tidy.py notes.txt` 去空行、去重、排序

直接让智能体「跑一下 img_resize」即可，它会自己在 PATH 里找。
'''),
      ],
    ),
    PluginManifest(
      id: 'mcp-http-template',
      name: 'MCP 接入示例',
      emoji: '🔗',
      description: '演示如何把远程 MCP 服务挂进 App：安装后编辑 mcp.json 填地址即可。',
      kind: PluginKind.mcp,
      category: '扩展',
      tags: <String>['mcp'],
      homepage: 'https://modelcontextprotocol.io',
      mcp: <String, dynamic>{
        'demo-http': <String, dynamic>{
          'url': 'https://example.com/mcp',
          'enabled': false,
        },
      },
      files: <PluginFile>[
        PluginFile('plugins/mcp-http-template/README.md', '''
# 接入一个 MCP 服务

安装后打开工作区的 `.zcode/mcp.json`，把 `demo-http` 改成真实服务：

```json
{
  "mcpServers": {
    "filesystem": {
      "url": "https://your-host/mcp",
      "headers": { "Authorization": "Bearer YOUR_TOKEN" }
    }
  }
}
```

支持的字段：
- `url`：Streamable HTTP 端点，最省事。
- `command` + `args`：本地 stdio 服务，需要手机上有对应可执行文件。
- `enabled`：设为 false 可临时停用。

保存后回到「插件」页下拉刷新，或在设置里重连 MCP。连接成功时，它的工具会以
`mcp__服务器名__工具名` 出现在智能体可用的工具列表里。
'''),
      ],
    ),
  ];
}
