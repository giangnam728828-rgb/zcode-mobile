import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../agent/mcp.dart';
import '../l10n/strings.dart';
import '../services/plugins.dart';
import '../state/app_state.dart';
import 'files_page.dart';

/// Plugin hub: browse the bundled catalog, pull a manifest from a URL, and see
/// what is already installed. Installing writes straight into `.zcode/`, so the
/// next message can use the new skill/command/agent — no restart, no rebuild.
class PluginsPage extends StatefulWidget {
  const PluginsPage({Key? key}) : super(key: key);

  @override
  State<PluginsPage> createState() => _PluginsPageState();
}

class _PluginsPageState extends State<PluginsPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);
  final TextEditingController _search = TextEditingController();
  String _category = '全部';
  String _busyId = '';
  bool _fetching = false;
  List<PluginManifest> _remote = const <PluginManifest>[];

  @override
  void dispose() {
    _tabs.dispose();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppState state = context.watch<AppState>();
    final S s = S.of(state.config?.language);
    final bool en = s.isEnglish;
    final ColorScheme cs = Theme.of(context).colorScheme;
    final PluginCenter? center = state.pluginCenter;

    return Scaffold(
      appBar: AppBar(
        title: Text(en ? 'Plugins' : '插件'),
        bottom: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabs: <Widget>[
            Tab(text: en ? 'Market' : '插件市场'),
            Tab(
              text: en
                  ? 'Installed (${center?.installed.length ?? 0})'
                  : '已安装（${center?.installed.length ?? 0}）',
            ),
            Tab(text: en ? 'MCP' : 'MCP 服务'),
          ],
        ),
        actions: <Widget>[
          IconButton(
            tooltip: en ? 'Install from URL' : '从链接安装',
            icon: const Icon(Icons.link_rounded),
            onPressed: () => _installFromUrl(state, en),
          ),
        ],
      ),
      body: center == null
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabs,
              children: <Widget>[
                _market(state, center, en, cs),
                _installed(state, center, en, cs),
                _mcp(state, en, cs),
              ],
            ),
    );
  }

  // ------------------------------------------------------------------ market

  Widget _market(AppState state, PluginCenter center, bool en, ColorScheme cs) {
    final String q = _search.text.trim().toLowerCase();
    final List<PluginManifest> all = <PluginManifest>[
      ...PluginCatalog.all,
      ..._remote,
    ];
    final List<String> categories = <String>['全部'];
    for (final PluginManifest m in all) {
      if (!categories.contains(m.category)) categories.add(m.category);
    }
    final List<PluginManifest> shown = all.where((PluginManifest m) {
      if (_category != '全部' && m.category != _category) return false;
      if (q.isEmpty) return true;
      return m.name.toLowerCase().contains(q) ||
          m.id.toLowerCase().contains(q) ||
          m.description.toLowerCase().contains(q) ||
          m.tags.any((String t) => t.toLowerCase().contains(q));
    }).toList();

    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
          child: TextField(
            controller: _search,
            onChanged: (String _) => setState(() {}),
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              isDense: true,
              hintText: en ? 'Search plugins' : '搜索插件、标签',
              prefixIcon: const Icon(Icons.search_rounded, size: 18),
              suffixIcon: q.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close_rounded, size: 16),
                      onPressed: () {
                        _search.clear();
                        setState(() {});
                      },
                    ),
              filled: true,
              fillColor: cs.onSurface.withOpacity(0.04),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        SizedBox(
          height: 36,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            children: <Widget>[
              for (final String c in categories)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: Text(c, style: const TextStyle(fontSize: 11.5)),
                    selected: _category == c,
                    onSelected: (bool _) => setState(() => _category = c),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
            ],
          ),
        ),
        if (_fetching) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: shown.isEmpty
              ? Center(
                  child: Text(
                    en ? 'Nothing matches' : '没有匹配的插件',
                    style: TextStyle(
                      fontSize: 12,
                      color: cs.onSurface.withOpacity(0.4),
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(14, 8, 14, 24),
                  itemCount: shown.length,
                  separatorBuilder: (BuildContext _, int __) =>
                      const SizedBox(height: 10),
                  itemBuilder: (BuildContext c, int i) => _pluginCard(
                    state,
                    center,
                    shown[i],
                    en,
                    cs,
                  ),
                ),
        ),
      ],
    );
  }

  Widget _pluginCard(
    AppState state,
    PluginCenter center,
    PluginManifest m,
    bool en,
    ColorScheme cs,
  ) {
    final bool installed = center.isInstalled(m.id);
    final bool busy = _busyId == m.id;
    return Container(
      padding: const EdgeInsets.fromLTRB(13, 12, 12, 12),
      decoration: BoxDecoration(
        color: cs.onSurface.withOpacity(0.035),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.onSurface.withOpacity(0.07)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(m.emoji, style: const TextStyle(fontSize: 22)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Flexible(
                          child: Text(
                            m.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        _pill(m.kindLabel, cs),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      m.description,
                      style: TextStyle(
                        fontSize: 11.5,
                        height: 1.5,
                        color: cs.onSurface.withOpacity(0.5),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 9),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  <String>[
                    if (m.author.isNotEmpty) m.author,
                    'v${m.version}',
                    ...m.tags.take(2),
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.5,
                    color: cs.onSurface.withOpacity(0.32),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (installed)
                OutlinedButton.icon(
                  onPressed: busy ? null : () => _uninstall(state, center, m),
                  icon: const Icon(Icons.check_rounded, size: 15),
                  label: Text(en ? 'Installed' : '已安装',
                      style: const TextStyle(fontSize: 12)),
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                )
              else
                ElevatedButton.icon(
                  onPressed: busy ? null : () => _install(state, center, m, en),
                  icon: busy
                      ? SizedBox(
                          width: 13,
                          height: 13,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor:
                                AlwaysStoppedAnimation<Color>(cs.onPrimary),
                          ),
                        )
                      : const Icon(Icons.download_rounded, size: 15),
                  label: Text(en ? 'Install' : '安装',
                      style: const TextStyle(fontSize: 12)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: cs.primary,
                    foregroundColor: cs.onPrimary,
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _pill(String text, ColorScheme cs) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: cs.primary.withOpacity(0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 9.5,
          fontWeight: FontWeight.w600,
          color: cs.primary,
        ),
      ),
    );
  }

  Future<void> _install(
    AppState state,
    PluginCenter center,
    PluginManifest m,
    bool en,
  ) async {
    setState(() => _busyId = m.id);
    try {
      await center.install(m);
      _toast(en ? 'Installed ${m.name}' : '已安装 ${m.name}');
    } catch (e) {
      _toast('${en ? 'Install failed' : '安装失败'}：$e');
    } finally {
      if (mounted) setState(() => _busyId = '');
    }
  }

  Future<void> _uninstall(
    AppState state,
    PluginCenter center,
    PluginManifest m,
  ) async {
    final bool en = S.of(state.config?.language).isEnglish;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(en ? 'Remove plugin?' : '卸载插件？',
            style: const TextStyle(fontSize: 16)),
        content: Text(
          en
              ? '${m.name} will be removed from the workspace. Files it created are deleted.'
              : '将删除 ${m.name} 以及它写入工作区的文件。',
          style: const TextStyle(fontSize: 12.5, height: 1.5),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(en ? 'Cancel' : '取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(en ? 'Remove' : '卸载'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await center.uninstall(m.id);
    if (mounted) setState(() {});
  }

  Future<void> _installFromUrl(AppState state, bool en) async {
    final PluginCenter? center = state.pluginCenter;
    if (center == null) return;
    final TextEditingController input = TextEditingController();
    final String? url = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(en ? 'Install from URL' : '从链接安装',
            style: const TextStyle(fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              en
                  ? 'Point to a plugin manifest (JSON). One object, an array, or {"plugins": [...]} all work.'
                  : '填入插件清单 JSON 地址。单个对象、数组或 {"plugins": [...]} 都可以。',
              style: const TextStyle(fontSize: 11.5, height: 1.5),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: input,
              autofocus: true,
              keyboardType: TextInputType.url,
              style: const TextStyle(fontSize: 12.5),
              decoration: const InputDecoration(
                hintText: 'https://example.com/plugins.json',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(en ? 'Cancel' : '取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, input.text.trim()),
            child: Text(en ? 'Fetch' : '获取'),
          ),
        ],
      ),
    );
    if (url == null || url.isEmpty) return;
    setState(() => _fetching = true);
    try {
      final List<PluginManifest> list = await center.fetchManifest(url);
      setState(() {
        _remote = <PluginManifest>[
          for (final PluginManifest m in list)
            if (!PluginCatalog.all.any((PluginManifest b) => b.id == m.id)) m,
        ];
      });
      _toast(en ? 'Found ${list.length} plugins' : '找到 ${list.length} 个插件');
    } catch (e) {
      _toast('${en ? 'Fetch failed' : '获取失败'}：$e');
    } finally {
      if (mounted) setState(() => _fetching = false);
    }
  }

  // --------------------------------------------------------------- installed

  Widget _installed(
    AppState state,
    PluginCenter center,
    bool en,
    ColorScheme cs,
  ) {
    final List<InstalledPlugin> list = center.installed;
    if (list.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            en
                ? 'No plugins yet. Browse the market and tap Install.'
                : '还没有安装插件。去市场看看，点一下「安装」即可。',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12.5,
              height: 1.6,
              color: cs.onSurface.withOpacity(0.42),
            ),
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
      itemCount: list.length,
      separatorBuilder: (BuildContext _, int __) => const SizedBox(height: 10),
      itemBuilder: (BuildContext c, int i) {
        final InstalledPlugin p = list[i];
        return Container(
          padding: const EdgeInsets.fromLTRB(13, 10, 8, 10),
          decoration: BoxDecoration(
            color: cs.onSurface.withOpacity(0.035),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: cs.onSurface.withOpacity(0.07)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Text(p.manifest.emoji,
                      style: const TextStyle(fontSize: 20)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          p.manifest.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${p.manifest.kindLabel} · ${p.files.length} 个文件'
                          '${p.manifest.mcp.isEmpty ? '' : ' · MCP ${p.manifest.mcp.length}'}',
                          style: TextStyle(
                            fontSize: 10.5,
                            color: cs.onSurface.withOpacity(0.35),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: p.enabled,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onChanged: (bool v) async {
                      await center.setEnabled(p.manifest.id, v);
                      if (mounted) setState(() {});
                    },
                  ),
                  IconButton(
                    tooltip: en ? 'Remove' : '卸载',
                    icon: const Icon(Icons.delete_outline_rounded, size: 18),
                    onPressed: () => _uninstall(state, center, p.manifest),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              InkWell(
                onTap: () => _openPluginFiles(state, p, en),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          p.files.join('  ·  '),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10,
                            fontFamily: 'monospace',
                            height: 1.5,
                            color: cs.onSurface.withOpacity(0.32),
                          ),
                        ),
                      ),
                      Icon(Icons.edit_outlined,
                          size: 14, color: cs.onSurface.withOpacity(0.3)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Lets the user read or tweak what a plugin wrote — a skill is just
  /// Markdown, and editing it should not require a file browser.
  Future<void> _openPluginFiles(
    AppState state,
    InstalledPlugin p,
    bool en,
  ) async {
    final Directory? ws = state.workspace;
    if (ws == null || p.files.isEmpty) return;
    String rel = p.files.first;
    if (p.files.length > 1) {
      final String? picked = await showModalBottomSheet<String>(
        context: context,
        builder: (BuildContext ctx) {
          final ColorScheme cs = Theme.of(ctx).colorScheme;
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                  child: Text(
                    en ? 'Plugin files' : '插件文件',
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                ),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: <Widget>[
                      for (final String f in p.files)
                        ListTile(
                          dense: true,
                          leading: Icon(Icons.description_outlined,
                              size: 18, color: cs.onSurface.withOpacity(0.5)),
                          title: Text(
                            f,
                            style: const TextStyle(
                                fontSize: 12, fontFamily: 'monospace'),
                          ),
                          onTap: () => Navigator.pop(ctx, f),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          );
        },
      );
      if (picked == null) return;
      rel = picked;
    }
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => FileEditorPage(
        path: '${ws.path}/.zcode/$rel',
        relative: '.zcode/$rel',
      ),
    ));
    if (!mounted) return;
    await state.refreshPlugins();
    if (mounted) setState(() {});
  }

  // --------------------------------------------------------------------- mcp

  Widget _mcp(AppState state, bool en, ColorScheme cs) {
    final McpManager? manager = state.mcpManager;
    final List<McpStatus> list = manager == null
        ? <McpStatus>[]
        : manager.statuses.values.toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
      children: <Widget>[
        Text(
          en
              ? 'MCP servers extend the agent with tools from other apps. Edit mcp.json, then reconnect.'
              : 'MCP 服务把其他应用的能力变成智能体的工具。改完 mcp.json 后点重连即可生效。',
          style: TextStyle(
            fontSize: 11.5,
            height: 1.6,
            color: cs.onSurface.withOpacity(0.45),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: <Widget>[
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _editMcp(state, en),
                icon: const Icon(Icons.edit_note_rounded, size: 17),
                label: Text(en ? 'Edit mcp.json' : '编辑 mcp.json',
                    style: const TextStyle(fontSize: 12)),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: () async {
                  await state.reloadMcp();
                  if (mounted) setState(() {});
                },
                icon: const Icon(Icons.refresh_rounded, size: 17),
                label: Text(en ? 'Reconnect' : '重新连接',
                    style: const TextStyle(fontSize: 12)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: cs.primary,
                  foregroundColor: cs.onPrimary,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        if (list.isEmpty)
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: cs.onSurface.withOpacity(0.03),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              en
                  ? 'No servers configured. Add one in mcp.json — a url for remote, or command for a local process.'
                  : '还没有配置服务。在 mcp.json 里加一项：远程填 url，本地进程填 command。',
              style: TextStyle(
                fontSize: 11.5,
                height: 1.6,
                color: cs.onSurface.withOpacity(0.42),
              ),
            ),
          )
        else
          for (final McpStatus st in list)
            Container(
              margin: const EdgeInsets.only(bottom: 9),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: cs.onSurface.withOpacity(0.035),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: cs.onSurface.withOpacity(0.07)),
              ),
              child: Row(
                children: <Widget>[
                  Icon(
                    st.state == 'ready'
                        ? Icons.check_circle_outline_rounded
                        : st.state == 'error'
                            ? Icons.error_outline_rounded
                            : Icons.circle_outlined,
                    size: 17,
                    color: st.state == 'ready'
                        ? const Color(0xFF2E9E5B)
                        : st.state == 'error'
                            ? cs.error
                            : cs.onSurface.withOpacity(0.35),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(st.server,
                            style: const TextStyle(
                                fontSize: 12.5, fontWeight: FontWeight.w500)),
                        if (st.detail.isNotEmpty) ...<Widget>[
                          const SizedBox(height: 2),
                          Text(
                            st.detail,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 10.5,
                              height: 1.45,
                              color: cs.onSurface.withOpacity(0.4),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (st.ready)
                    Text(
                      '${st.tools} 个工具',
                      style: TextStyle(
                        fontSize: 10,
                        color: cs.onSurface.withOpacity(0.35),
                      ),
                    ),
                ],
              ),
            ),
        if (manager?.error != null && list.every((McpStatus s) => !s.ready)) ...[
          const SizedBox(height: 4),
          Text(
            manager!.error!,
            style: TextStyle(fontSize: 10.5, color: cs.error),
          ),
        ],
      ],
    );
  }

  Future<void> _editMcp(AppState state, bool en) async {
    final Directory? ws = state.workspace;
    if (ws == null) return;
    final File f = File('${ws.path}/.zcode/mcp.json');
    if (!await f.exists()) {
      await f.parent.create(recursive: true);
      await f.writeAsString('''{
  "mcpServers": {
    "demo-http": {
      "url": "https://your-host/mcp",
      "headers": { "Authorization": "Bearer YOUR_TOKEN" },
      "enabled": false
    }
  }
}
''');
    }
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => FileEditorPage(path: f.path, relative: '.zcode/mcp.json'),
    ));
    if (!mounted) return;
    await state.reloadMcp();
    if (mounted) setState(() {});
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(text),
        duration: const Duration(milliseconds: 1800),
      ));
  }
}
