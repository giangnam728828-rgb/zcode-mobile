import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../services/account.dart';
import '../state/app_state.dart';
import '../theme/glass.dart';
import '../theme/tokens.dart';

/// First-run screen: sign in with the platform account, exactly like the
/// desktop client. No API key is typed or stored by hand.
class LoginPage extends StatefulWidget {
  const LoginPage({Key? key}) : super(key: key);

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  bool _busy = false;
  String _status = '';
  String _authorizeUrl = '';
  String? _failure;

  bool get _en => S.of(context.read<AppState>().config?.language).isEnglish;

  Future<void> _start(AccountRegion region) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _failure = null;
      _status = _en ? 'Opening the browser…' : '正在打开浏览器授权…';
    });
    final AppState state = context.read<AppState>();
    try {
      await state.signIn(
        region,
        onStatus: (String s) {
          if (mounted) setState(() => _status = s);
        },
        onUrl: (String url) {
          if (mounted) setState(() => _authorizeUrl = url);
        },
      );
    } catch (e) {
      if (mounted) setState(() => _failure = '$e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = '';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final S s = S.of(context.watch<AppState>().config?.language);
    final bool en = s.isEnglish;

    final AppPalette p = AppPalette.of(context);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: LiquidBackground(
        drift: false,
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 28, 24, 32),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        width: 58,
                        height: 58,
                        decoration: BoxDecoration(
                          // One flat accent block instead of a two-stop gradient:
                          // a blue-to-cyan tile is the single most templated
                          // "AI app" opener there is.
                          color: cs.primary,
                          borderRadius: AppTokens.brMd,
                        ),
                        child: Center(
                          child: Text(
                            '>_',
                            style: TextStyle(
                              color: cs.onPrimary,
                              fontSize: 23,
                              fontWeight: FontWeight.w700,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 22),
                    Text(
                      en ? 'Sign in to ZCode' : '登录 ZCode',
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w700,
                        color: cs.onSurface,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      en
                          ? 'Use your platform account. The browser handles the password — '
                              'this app only keeps the token, and spends the same plan quota '
                              'as your desktop.'
                          : '用平台账号登录。密码只在浏览器里输入，App 只保存令牌；'
                              '和桌面端共用同一份套餐额度，不需要填 API Key。',
                      style: TextStyle(
                        fontSize: 13.5,
                        height: 1.65,
                        color: cs.onSurface.withValues(alpha: 0.62),
                      ),
                    ),
                    const SizedBox(height: 26),
                    _ProviderButton(
                      title: en ? 'Continue with BigModel' : '使用 BigModel 账号登录',
                      subtitle:
                          en ? 'China · bigmodel.cn' : '国内站 · bigmodel.cn',
                      badge: 'B',
                      enabled: !_busy,
                      onTap: () => _start(AccountRegion.bigmodel),
                    ),
                    const SizedBox(height: 12),
                    _ProviderButton(
                      title: en ? 'Continue with Z.ai' : '使用 Z.ai 账号登录',
                      subtitle: en ? 'Global · z.ai' : '海外站 · z.ai',
                      badge: 'Z',
                      enabled: !_busy,
                      onTap: () => _start(AccountRegion.zai),
                    ),
                    if (_busy) ...<Widget>[
                      const SizedBox(height: 22),
                      Row(
                        children: <Widget>[
                          const SizedBox(
                            width: 15,
                            height: 15,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _status,
                              style: TextStyle(
                                fontSize: 12.5,
                                color: cs.onSurface.withValues(alpha: 0.6),
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (_authorizeUrl.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 10),
                        Text(
                          en
                              ? 'Browser did not open? Copy the link and open it manually.'
                              : '浏览器没有自动打开？复制下面的链接手动打开：',
                          style: TextStyle(
                            fontSize: 12,
                            color: cs.onSurface.withValues(alpha: 0.45),
                          ),
                        ),
                        const SizedBox(height: 6),
                        InkWell(
                          onTap: () {
                            Clipboard.setData(
                                ClipboardData(text: _authorizeUrl));
                            ScaffoldMessenger.of(context)
                              ..hideCurrentSnackBar()
                              ..showSnackBar(SnackBar(content: Text(s.copied)));
                          },
                          child: Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: p.surfaceRaised,
                              borderRadius: AppTokens.brSm,
                              border: Border.all(color: p.line, width: 0.8),
                            ),
                            child: Row(
                              children: <Widget>[
                                Expanded(
                                  child: Text(
                                    _authorizeUrl,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontFamily: 'monospace',
                                      color:
                                          cs.onSurface.withValues(alpha: 0.6),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Icon(Icons.copy_rounded,
                                    size: 15,
                                    color: cs.onSurface.withValues(alpha: 0.4)),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ],
                    if (_failure != null) ...<Widget>[
                      const SizedBox(height: 18),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: cs.error.withValues(alpha: 0.10),
                          borderRadius: AppTokens.brSm,
                          border: Border.all(
                              color: cs.error.withValues(alpha: 0.28),
                              width: 0.8),
                        ),
                        child: Text(
                          _failure!,
                          style: TextStyle(
                            fontSize: 12.5,
                            height: 1.5,
                            color: cs.error,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 26),
                    Container(
                      padding: const EdgeInsets.all(13),
                      decoration: BoxDecoration(
                        color: p.surface,
                        borderRadius: AppTokens.brMd,
                        border: Border.all(color: p.line, width: 0.8),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Icon(Icons.terminal_rounded,
                              size: 16,
                              color: cs.onSurface.withValues(alpha: 0.45)),
                          const SizedBox(width: 9),
                          Expanded(
                            child: Text(
                              en
                                  ? 'The agent runs real shell commands and file edits '
                                      'inside this app\'s private workspace. Every risky '
                                      'command asks for your approval first.'
                                  : 'Agent 会在本应用的私有工作区里真实执行 shell 命令、'
                                      '读写文件。高风险操作执行前会先征求你的同意。',
                              style: TextStyle(
                                fontSize: 12,
                                height: 1.55,
                                color: cs.onSurface.withValues(alpha: 0.5),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      en
                          ? 'Community client. Not affiliated with Zhipu or Z.ai.'
                          : '社区客户端，与智谱 / Z.ai 无隶属关系。',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 11,
                        color: cs.onSurface.withValues(alpha: 0.32),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ProviderButton extends StatelessWidget {
  const _ProviderButton({
    Key? key,
    required this.title,
    required this.subtitle,
    required this.badge,
    required this.enabled,
    required this.onTap,
  }) : super(key: key);

  final String title;
  final String subtitle;
  final String badge;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final AppPalette p = AppPalette.of(context);
    return Opacity(
      opacity: enabled ? 1 : 0.55,
      child: Material(
        color: p.surface,
        shape: RoundedRectangleBorder(
          borderRadius: AppTokens.brLg,
          side: BorderSide(color: p.line, width: 0.8),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled ? onTap : null,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            child: Row(
              children: <Widget>[
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: cs.primary.withValues(alpha: 0.12),
                    borderRadius: AppTokens.brSm,
                  ),
                  child: Center(
                    child: Text(
                      badge,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: cs.primary,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600,
                          color: cs.onSurface,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: cs.onSurface.withValues(alpha: 0.45),
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.arrow_forward_rounded,
                    size: 18, color: cs.onSurface.withValues(alpha: 0.35)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
