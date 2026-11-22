import 'package:flutter/material.dart';

import 'remote_connection.dart';
import 'remote_hub.dart';
import 'remote_url.dart';
import 'scanner.dart';

/// Shared "add a desktop" flows for the dock's remote view and the manager
/// page. Adding validates strictly, stores through [RemoteHub] (secure
/// storage) and returns the saved connection for the caller to open.
class RemoteAddFlow {
  RemoteAddFlow._();

  static void _toast(BuildContext context, String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(text),
        duration: const Duration(milliseconds: 2200),
      ));
  }

  /// Scans the QR the desktop shows. Returns null when nothing was added.
  static Future<RemoteConnection?> fromScan(BuildContext context) async {
    final String? raw = await scanDesktopQr(context);
    if (raw == null) return null;
    return confirm(context, raw);
  }

  /// Paste entry: desktop → phone icon → Mobile Remote Control → copy link.
  static Future<RemoteConnection?> fromPaste(BuildContext context) async {
    final TextEditingController ctl = TextEditingController();
    final String? raw = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('粘贴桌面链接'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '桌面端 → 左下角手机图标 → 移动远程控制 → 复制链接',
                style: TextStyle(fontSize: 12.5, height: 1.5),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: ctl,
              autofocus: true,
              maxLines: 3,
              style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
              decoration: const InputDecoration(
                hintText: 'https://zcode.z.ai/remote/…',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
            child: const Text('下一步'),
          ),
        ],
      ),
    );
    ctl.dispose();
    if (raw == null || raw.isEmpty) return null;
    return confirm(context, raw);
  }

  /// Validates the payload, asks for a display name and saves. Returns the
  /// saved (or already-saved) connection, or null when the user cancelled or
  /// the link was rejected. The full URL is never echoed in clear text —
  /// only the masked form.
  static Future<RemoteConnection?> confirm(
    BuildContext context,
    String raw,
  ) async {
    final RemoteHub hub = RemoteHub.instance;
    final RemoteUrlCheck check = RemoteUrl.validate(raw);
    if (!check.ok) {
      _toast(context, '无法添加：${check.problem}');
      return null;
    }
    final Uri url = check.uri!;
    // Same link already saved: just refresh its timestamp.
    final RemoteConnection? existing = hub.byUrl(url.toString());
    if (existing != null) {
      await hub.touch(existing);
      return existing;
    }

    final TextEditingController name =
        TextEditingController(text: '我的电脑');
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('保存这台电脑'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              RemoteUrl.mask(url),
              style:
                  const TextStyle(fontSize: 11.5, fontFamily: 'monospace'),
            ),
            const SizedBox(height: 4),
            const Text(
              '链接等同于桌面窗口的操作凭证：只保存在本机安全存储，'
              '删除连接时一并清除。',
              style: TextStyle(fontSize: 11.5, height: 1.5),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: name,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '设备名称',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    // Read the text before disposing the controller — reading after dispose
    // throws.
    final String label = name.text.trim().isEmpty ? '我的电脑' : name.text.trim();
    name.dispose();
    if (ok != true) return null;

    final RemoteConnection c = RemoteConnection(
      id: 'r${DateTime.now().microsecondsSinceEpoch}',
      name: label,
      url: url.toString(),
      addedAt: DateTime.now(),
      lastUsedAt: DateTime.now(),
    );
    await hub.add(c);
    return c;
  }
}
