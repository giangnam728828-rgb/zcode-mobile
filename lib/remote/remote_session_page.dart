import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'remote_connection.dart';
import 'remote_url.dart';

/// The actual remote surface. Everything inside is the official
/// `zcode.z.ai/remote/v4` page: pairing, the relay protocol, session state and
/// reconnection are all carried by it, so the app never re-implements the
/// private relay protocol nor fakes a desktop identity (总方案 P0-3).
///
/// The native layer contributes what the page cannot: a strict navigation
/// allow-list, the desktop-execution label, and mode isolation — nothing here
/// touches the local agent, workspace or conversations.
class RemoteSessionPage extends StatefulWidget {
  const RemoteSessionPage({Key? key, required this.connection})
      : super(key: key);

  final RemoteConnection connection;

  @override
  State<RemoteSessionPage> createState() => _RemoteSessionPageState();
}

class _RemoteSessionPageState extends State<RemoteSessionPage> {
  late final WebViewController _controller;
  int _progress = 100;
  String? _failure;

  @override
  void initState() {
    super.initState();
    final Uri start = Uri.parse(widget.connection.url);
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF0C0E12))
      ..setNavigationDelegate(NavigationDelegate(
        onProgress: (int p) {
          if (mounted) setState(() => _progress = p);
        },
        onNavigationRequest: (NavigationRequest req) {
          final Uri? u = Uri.tryParse(req.url);
          // Only the official remote host navigates in-place; anything else
          // (help docs, downloads) hands off to the system browser instead of
          // hijacking the remote surface.
          if (u != null && RemoteUrl.looksOfficial(u)) {
            return NavigationDecision.navigate;
          }
          launchUrl(Uri.parse(req.url), mode: LaunchMode.externalApplication);
          return NavigationDecision.prevent;
        },
        onWebResourceError: (WebResourceError e) {
          if (mounted) {
            setState(() => _failure = e.description);
          }
        },
      ))
      ..loadRequest(start);
  }

  @override
  Widget build(BuildContext context) {
    final RemoteConnection c = widget.connection;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(c.name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16)),
            Text(
              '桌面远程 · 执行在电脑端',
              style: TextStyle(
                fontSize: 10.5,
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
      body: Stack(
        children: <Widget>[
          WebViewWidget(controller: _controller),
          if (_progress < 100)
            LinearProgressIndicator(
              value: _progress / 100,
              minHeight: 2,
            ),
          if (_failure != null)
            Positioned(
              left: 12,
              right: 12,
              bottom: 12,
              child: Material(
                elevation: 4,
                borderRadius: BorderRadius.circular(12),
                color: Theme.of(context).colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          '加载失败：$_failure\n'
                          '请确认电脑上的 ZCode 正在运行、远程控制已开启。',
                          style: TextStyle(
                            fontSize: 12.5,
                            color: Theme.of(context).colorScheme.onErrorContainer,
                            height: 1.4,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () {
                          setState(() => _failure = null);
                          _controller.loadRequest(Uri.parse(c.url));
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
    );
  }
}
