import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../theme/tokens.dart';
import 'remote_add_flow.dart';
import 'remote_connection.dart';
import 'remote_hub.dart';
import 'remote_page.dart';
import 'remote_url.dart';

/// The dock's remote surface: the official remote page of the most recently
/// used desktop, one tap from the conversation tab (总方案 P0-5). Everything
/// protocol-side is carried by the official page; this widget adds the mode
/// label, the strict navigation allow-list and quick access to the manager.
class RemoteViewPage extends StatefulWidget {
  const RemoteViewPage({Key? key, this.embedded = false}) : super(key: key);

  final bool embedded;

  @override
  State<RemoteViewPage> createState() => _RemoteViewPageState();
}

class _RemoteViewPageState extends State<RemoteViewPage> {
  @override
  void initState() {
    super.initState();
    RemoteHub.instance.ensureLoaded();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: RemoteHub.instance,
      builder: (BuildContext ctx, _) {
        final RemoteHub hub = RemoteHub.instance;
        if (hub.loading) {
          return const Center(child: CircularProgressIndicator(strokeWidth: 2));
        }
        final RemoteConnection? c = hub.lastUsed;
        if (c == null) return _empty(context);
        // Keyed by URL: saving a new link swaps the page without losing the
        // old webview's state, and deleting the connection removes it.
        return RemoteWebView(key: ValueKey<String>(c.url), connection: c);
      },
    );
  }

  Widget _empty(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.computer_outlined, size: 40, color: cs.outline),
            const SizedBox(height: 12),
            const Text(
              '还没有连接过电脑',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              '在电脑端 ZCode 左下角点手机图标，\n'
              '生成二维码或复制链接；任务在桌面端执行、\n'
              '消耗桌面套餐。电脑不在线时用「对话」本地模式。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.6,
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
            const SizedBox(height: 18),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                FilledButton.icon(
                  onPressed: () => RemoteAddFlow.fromScan(context),
                  icon: const Icon(Icons.qr_code_scanner_rounded, size: 18),
                  label: const Text('扫描二维码'),
                ),
                const SizedBox(width: 10),
                OutlinedButton.icon(
                  onPressed: () => RemoteAddFlow.fromPaste(context),
                  icon: const Icon(Icons.content_paste_rounded, size: 18),
                  label: const Text('粘贴链接'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const RemotePage()),
              ),
              child: const Text('管理连接'),
            ),
          ],
        ),
      ),
    );
  }
}

/// The official page in-place, with a slim header naming the desktop and the
/// execution environment. Refresh reloads after the desktop regenerated its
/// link or came back online.
class RemoteWebView extends StatefulWidget {
  const RemoteWebView({Key? key, required this.connection}) : super(key: key);

  final RemoteConnection connection;

  @override
  State<RemoteWebView> createState() => _RemoteWebViewState();
}

class _RemoteWebViewState extends State<RemoteWebView>
    with WidgetsBindingObserver {
  late final WebViewController _controller;
  int _progress = 100;
  String? _failure;

  /// When the app went to the background; the official page's websocket dies
  /// in long backgrounds, so coming back after a while reloads instead of
  /// showing a frozen half-dead session.
  DateTime? _pausedAt;
  static const Duration _reloadAfterBackground = Duration(seconds: 45);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    RemoteHub.instance.touch(widget.connection);
    _controller = _make();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _pausedAt = DateTime.now();
      return;
    }
    if (state == AppLifecycleState.resumed && mounted) {
      final DateTime? pausedAt = _pausedAt;
      _pausedAt = null;
      final bool longBackground = pausedAt != null &&
          DateTime.now().difference(pausedAt) > _reloadAfterBackground;
      // Short gaps: the official page reconnects its own websocket. Long ones
      // or a shown error: reload the whole page.
      if (_failure != null || longBackground) {
        _reload();
      }
    }
  }

  void _reload() {
    setState(() {
      _failure = null;
      _progress = 0;
    });
    _controller.loadRequest(Uri.parse(widget.connection.url));
  }

  WebViewController _make() {
    return WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..setNavigationDelegate(NavigationDelegate(
        onProgress: (int p) {
          if (mounted) setState(() => _progress = p);
        },
        onNavigationRequest: (NavigationRequest req) {
          final Uri? u = Uri.tryParse(req.url);
          // Only the official remote host navigates in-place; anything else
          // goes to the system browser instead of hijacking the remote view.
          if (u != null && RemoteUrl.looksOfficial(u)) {
            return NavigationDecision.navigate;
          }
          launchUrl(Uri.parse(req.url), mode: LaunchMode.externalApplication);
          return NavigationDecision.prevent;
        },
        onWebResourceError: (WebResourceError e) {
          if (mounted) setState(() => _failure = e.description);
        },
      ))
      ..loadRequest(Uri.parse(widget.connection.url));
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(
              AppTokens.gutter, AppTokens.s2, AppTokens.gutter, 0),
          child: Row(
            children: <Widget>[
              Icon(Icons.computer_outlined, size: 15, color: cs.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${widget.connection.name} · 桌面远程，执行在电脑端',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: cs.primary,
                  ),
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: '刷新',
                icon: const Icon(Icons.refresh_rounded, size: 19),
                onPressed: _reload,
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: '管理连接',
                icon: const Icon(Icons.tune_rounded, size: 19),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const RemotePage()),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Stack(
            children: <Widget>[
              WebViewWidget(controller: _controller),
              if (_progress < 100)
                LinearProgressIndicator(value: _progress / 100, minHeight: 2),
              if (_failure != null)
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 12,
                  child: Material(
                    elevation: 4,
                    borderRadius: BorderRadius.circular(12),
                    color: cs.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              '加载失败：$_failure\n'
                              '请确认电脑上的 ZCode 正在运行、远程控制已开启；'
                              '桌面刷新过二维码的话，需要重新扫码添加。',
                              style: TextStyle(
                                fontSize: 12,
                                height: 1.45,
                                color: cs.onErrorContainer,
                              ),
                            ),
                          ),
                          TextButton(
                            onPressed: () {
                              setState(() => _failure = null);
                              _reload();
                            },
                            child: const Text('重试'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
