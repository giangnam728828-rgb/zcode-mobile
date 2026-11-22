import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import '../widgets/page_shell.dart';
import 'remote_add_flow.dart';
import 'remote_connection.dart';
import 'remote_hub.dart';
import 'remote_session_page.dart';
import 'remote_url.dart';

/// Saved desktop remote-control entries — the manager behind the dock's
/// remote tab. The phone-side duties (总方案 P0-3/P0-4): keep the entry list,
/// take a link from the official QR or the clipboard, validate it strictly,
/// store it in secure storage, open the official page. Session state lives on
/// the official page; nothing here mixes with the local agent's conversations.
class RemotePage extends StatefulWidget {
  const RemotePage({Key? key}) : super(key: key);

  @override
  State<RemotePage> createState() => _RemotePageState();
}

class _RemotePageState extends State<RemotePage> {
  @override
  void initState() {
    super.initState();
    RemoteHub.instance.ensureLoaded();
  }

  Future<void> _open(RemoteConnection c) async {
    await RemoteHub.instance.touch(c);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
          builder: (_) => RemoteSessionPage(connection: c)),
    );
    if (mounted) setState(() {});
  }

  Future<void> _rename(RemoteConnection c) async {
    final TextEditingController ctl = TextEditingController(text: c.name);
    final String? next = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('重命名设备'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '设备名称',
            border: OutlineInputBorder(),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    ctl.dispose();
    if (next == null || next.isEmpty || next == c.name) return;
    await RemoteHub.instance.rename(c, next);
    if (mounted) setState(() {});
  }

  Future<void> _delete(RemoteConnection c) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('删除连接'),
        content: Text('删除「${c.name}」？\n对应的远程链接会一并从本机清除；'
            '桌面端不受影响，也不会退出登录。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await RemoteHub.instance.remove(c.id);
    if (mounted) setState(() {});
  }

  // ------------------------------------------------------------------- build

  String _two(int v) => v.toString().padLeft(2, '0');

  String _when(DateTime? t) {
    if (t == null) return '未连接过';
    final DateTime l = t.toLocal();
    return '上次连接 ${l.month}-${_two(l.day)} ${_two(l.hour)}:${_two(l.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: RemoteHub.instance,
      builder: (BuildContext ctx, _) {
        final RemoteHub hub = RemoteHub.instance;
        final List<RemoteConnection> items = hub.items;
        return PageShell(
          title: '桌面远程控制',
          subtitle: const Text('连接电脑上的 ZCode，任务在桌面端执行',
              maxLines: 1, overflow: TextOverflow.ellipsis),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
                AppTokens.gutter, AppTokens.s2, AppTokens.gutter, 40),
            children: <Widget>[
              if (hub.loading) const LinearProgressIndicator(minHeight: 2),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.07),
                  borderRadius: AppTokens.brMd,
                  border:
                      Border.all(color: cs.primary.withValues(alpha: 0.25)),
                ),
                child: const Text(
                  '在电脑端 ZCode 左下角点手机图标，生成二维码或复制链接。\n'
                  '链接等同于桌面窗口的操作凭证，请勿转发；'
                  '桌面端退出后远程会话随之中断；'
                  '桌面刷新过二维码的话，旧链接作废、需要重新添加。'
                  '电脑不在线时，用「对话」页的本地模式即可。',
                  style: TextStyle(fontSize: 12.5, height: 1.55),
                ),
              ),
              const SizedBox(height: 12),
              for (final RemoteConnection c in items) _card(c, cs),
              if (!hub.loading && items.isEmpty) _empty(cs),
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () async {
                        final RemoteConnection? c =
                            await RemoteAddFlow.fromScan(context);
                        if (c != null) await _open(c);
                      },
                      icon: const Icon(Icons.qr_code_scanner_rounded,
                          size: 18),
                      label: const Text('扫描二维码'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        final RemoteConnection? c =
                            await RemoteAddFlow.fromPaste(context);
                        if (c != null) await _open(c);
                      },
                      icon: const Icon(Icons.content_paste_rounded, size: 18),
                      label: const Text('粘贴链接'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _card(RemoteConnection c, ColorScheme cs) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
      decoration: BoxDecoration(
        borderRadius: AppTokens.brMd,
        border: Border.all(
            color: Theme.of(context).dividerTheme.color ?? cs.outlineVariant),
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: cs.primary.withValues(alpha: 0.12),
              borderRadius: AppTokens.brSm,
            ),
            child: Icon(Icons.computer_outlined, size: 20, color: cs.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  c.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  RemoteUrl.mask(Uri.parse(c.url)),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontFamily: 'monospace',
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _when(c.lastUsedAt),
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ),
              ],
            ),
          ),
          PopupMenuButton<String>(
            onSelected: (String v) {
              if (v == 'open') _open(c);
              if (v == 'rename') _rename(c);
              if (v == 'delete') _delete(c);
            },
            itemBuilder: (BuildContext ctx) => const <PopupMenuEntry<String>>[
              PopupMenuItem<String>(value: 'open', child: Text('打开')),
              PopupMenuItem<String>(value: 'rename', child: Text('重命名')),
              PopupMenuItem<String>(value: 'delete', child: Text('删除')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _empty(ColorScheme cs) {
    return Container(
      margin: const EdgeInsets.only(top: 6, bottom: 6),
      padding: const EdgeInsets.symmetric(vertical: 26, horizontal: 18),
      alignment: Alignment.center,
      child: Column(
        children: <Widget>[
          Icon(Icons.computer_outlined, size: 34,
              color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 10),
          const Text(
            '还没有连接过电脑\n扫描桌面端二维码，或粘贴它生成的链接',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, height: 1.6),
          ),
        ],
      ),
    );
  }
}
