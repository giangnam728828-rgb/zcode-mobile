import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../services/account.dart';
import '../state/app_state.dart';
import '../theme/tokens.dart';
import '../widgets/brand_mark.dart';

/// Bumped alongside `pubspec.yaml`. Shown in the header so a bug report can
/// name the build without opening settings.
  const String _kVersion = '3.11.1';

/// First-run screen: sign in with the platform account, exactly like the
/// desktop client. No API key is typed or stored by hand.
///
/// Layout is three bands, not one centred column:
///
///   1. a thin tool bar (icon, wordmark, build number) — this is an app, not a
///      marketing page, so it opens like one;
///   2. a cover plate with the brand art, a two-line headline and the terminal
///      prompt — the brand is a picture plus a voice, not icon-over-title;
///   3. a sheet that overlaps the cover and carries the actual decisions:
///      two sign-in ports with different weight, the account facts as a
///      three-column strip, and the capability list as a numbered manifest.
///
/// The OAuth flow below is untouched: this file only decides what the screen
/// looks like.
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
      final AccountSession? s = await state.signIn(
        region,
        onStatus: (String s) {
          if (mounted) setState(() => _status = s);
        },
        onUrl: (String url) {
          if (mounted) setState(() => _authorizeUrl = url);
        },
      );
      // A degraded session is not a full success: the account authorized, but
      // no model credential was issued. Say so right here instead of letting
      // the user hit a confusing failure on the first message.
      if (s != null && s.issueError != null && mounted) {
        setState(() =>
            _failure = '已登录，但模型凭证签发失败：${s.issueError}\n'
                '可在 设置 › 账号 点击「重新签发」重试。');
      }
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
    final AppPalette p = AppPalette.of(context);
    final S s = S.of(context.watch<AppState>().config?.language);
    final bool en = s.isEnglish;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: _Backdrop(
        child: SafeArea(
          bottom: false,
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints c) {
              final bool compact = c.maxHeight < 720;
              final double coverHeight = compact
                  ? 168
                  : (c.maxHeight * 0.205).clamp(168.0, 208.0);
              return SingleChildScrollView(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.paddingOf(context).bottom + 20,
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 470),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        _TopBar(version: _kVersion),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: AppTokens.gutter),
                          child: _Cover(
                            height: coverHeight,
                            en: en,
                            compact: compact,
                          ),
                        ),
                        // The sheet sits on top of the cover's lower edge.
                        Transform.translate(
                          offset: const Offset(0, -20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: <Widget>[
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: AppTokens.gutter),
                                child: _sheet(context, p, cs, en),
                              ),
                              const SizedBox(height: 18),
                              _Footer(en: en),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _sheet(
    BuildContext context,
    AppPalette p,
    ColorScheme cs,
    bool en,
  ) {
    final Color panel = p.isDark ? const Color(0xFF121821) : Colors.white;
    final Color edge = p.isDark ? const Color(0xFF242E3A) : const Color(0xFFE3E7ED);

    return Container(
      decoration: BoxDecoration(
        color: panel,
        borderRadius: BorderRadius.circular(AppTokens.rXl),
        border: Border.all(color: edge, width: 0.8),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: p.isDark ? 0.42 : 0.12),
            blurRadius: 28,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(18, 13, 18, 11),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _SectionHead(
            index: '01',
            title: en ? 'Sign in' : '选择账号',
            trailing: _MonoChip(en ? 'NO API KEY' : '免 API KEY'),
          ),
          const SizedBox(height: AppTokens.s3),
          if (_failure != null) ...<Widget>[
            _ErrorBox(message: _failure!),
            const SizedBox(height: AppTokens.s3),
          ],
          // The accented port is the one that matches the interface language:
          // a Chinese UI is most likely billed in RMB on BigModel, an English
          // one in USD on Z.ai. The other stays one tap away, unaccented.
          if (en) ...<Widget>[
            _ProviderCard(
              primary: true,
              title: 'Z.ai',
              region: 'Global',
              domain: 'z.ai',
              badge: 'Z',
              tag: 'Recommended',
              enabled: !_busy,
              onTap: () => _start(AccountRegion.zai),
            ),
            const SizedBox(height: 10),
            _ProviderCard(
              primary: false,
              title: 'BigModel',
              region: 'China',
              domain: 'bigmodel.cn',
              badge: 'B',
              tag: null,
              enabled: !_busy,
              onTap: () => _start(AccountRegion.bigmodel),
            ),
          ] else ...<Widget>[
            _ProviderCard(
              primary: true,
              title: 'BigModel',
              region: '国内站',
              domain: 'bigmodel.cn',
              badge: 'B',
              tag: '推荐',
              enabled: !_busy,
              onTap: () => _start(AccountRegion.bigmodel),
            ),
            const SizedBox(height: 10),
            _ProviderCard(
              primary: false,
              title: 'Z.ai',
              region: '海外站',
              domain: 'z.ai',
              badge: 'Z',
              tag: null,
              enabled: !_busy,
              onTap: () => _start(AccountRegion.zai),
            ),
          ],
          const SizedBox(height: 10),
          if (_busy)
            _BusyRow(status: _status)
          else
            _NoteRow(
              text: en
                  ? 'The two sites are separate accounts. Pick the one you are billed on.'
                  : '两个站点账号不互通，选你账单所在的那一个。',
            ),
          if (_busy && _authorizeUrl.isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            _UrlBox(
              url: _authorizeUrl,
              hint: en
                  ? 'Browser did not open? Copy the link and open it manually.'
                  : '浏览器没有自动打开？复制下面的链接手动打开：',
              onCopy: () {
                Clipboard.setData(ClipboardData(text: _authorizeUrl));
                ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(SnackBar(
                      content: Text(S.of(context.read<AppState>()
                              .config
                              ?.language)
                          .copied)));
              },
            ),
          ],
          const SizedBox(height: 12),
          _SectionHead(
            index: '02',
            title: en ? 'Account' : '账号说明',
          ),
          const SizedBox(height: 10),
          _FactStrip(
            en: en,
            edge: edge,
            surface: p.isDark ? const Color(0xFF161E27) : const Color(0xFFF6F8FB),
            // Three columns need ~100dp each to keep a six-character value on
            // one line. Below that they turn into rows, which is honest at
            // 320dp and stops "浏览器内输 / 入" from happening.
            narrow: MediaQuery.sizeOf(context).width < 360,
          ),
          const SizedBox(height: 16),
          _SectionHead(
            index: '03',
            title: en ? 'On this device' : '本机能做什么',
          ),
          const SizedBox(height: AppTokens.s2),
          _ManifestRow(
            title: en ? 'Real shell' : '真实 shell',
            detail: en
                ? 'Commands run in the app’s private workspace'
                : '命令在本应用的私有工作区里执行',
            icon: Icons.terminal_rounded,
            dividerColor: edge,
          ),
          _ManifestRow(
            title: en ? 'Project files' : '直接读写项目',
            detail: en
                ? 'The agent opens your files in place, no upload'
                : 'Agent 就地读写你的文件，不用上传',
            icon: Icons.folder_open_rounded,
            dividerColor: edge,
          ),
          _ManifestRow(
            title: en ? 'Approval gate' : '执行前确认',
            detail: en
                ? 'Risky commands wait for your tap'
                : '高风险操作先停下来等你点确认',
            icon: Icons.verified_user_outlined,
            dividerColor: edge,
            last: true,
          ),
        ],
      ),
    );
  }
}

/// Page field. Light and dark are composed separately on purpose: daylight sky
/// behind the art, a single cold glow behind the sheet at night.
class _Backdrop extends StatelessWidget {
  const _Backdrop({Key? key, required this.child}) : super(key: key);

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = AppPalette.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: p.isDark
              ? const <Color>[
                  Color(0xFF0A0E13),
                  Color(0xFF0D1319),
                  Color(0xFF0B1016),
                ]
              : const <Color>[
                  Color(0xFFF7FAFD),
                  Color(0xFFE9EEF4),
                  Color(0xFFEDF1F6),
                ],
        ),
      ),
      child: Stack(
        children: <Widget>[
          Positioned(
            top: p.isDark ? 150 : -140,
            left: p.isDark ? -70 : null,
            right: p.isDark ? -70 : -110,
            height: p.isDark ? 300 : 380,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    colors: <Color>[
                      (p.isDark ? cs.primary : const Color(0xFF8FC7EA))
                          .withValues(alpha: p.isDark ? 0.16 : 0.30),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ),
          Positioned.fill(child: child),
        ],
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({Key? key, required this.version}) : super(key: key);

  final String version;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = AppPalette.of(context);
    // At 320dp with 1.3x text the build tag and the `/ mobile` suffix cannot
    // both fit. The suffix is decoration, the version is information, so the
    // suffix is the one that gives way.
    final bool showSuffix = MediaQuery.sizeOf(context).width >= 340;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 10),
      child: Row(
        children: <Widget>[
          const AppIconTile(size: 28),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              'ZCode',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.3,
                color: p.text,
              ),
            ),
          ),
          if (showSuffix) ...<Widget>[
            const SizedBox(width: 8),
            Container(width: 1, height: 13, color: p.lineStrong),
            const SizedBox(width: 8),
            Text(
              '/mobile',
              maxLines: 1,
              style: TextStyle(
                fontSize: 10.5,
                fontFamily: 'monospace',
                color: p.textTertiary,
              ),
            ),
          ],
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: p.line, width: 0.8),
            ),
            child: Text(
              'v$version',
              style: TextStyle(
                fontSize: 9.5,
                fontFamily: 'monospace',
                letterSpacing: 0.2,
                color: p.textTertiary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The cover plate. The art is the same file as the launcher icon, cropped
/// wide; the headline is the product's voice, and the prompt line is the
/// terminal note that keeps it from reading as a lifestyle app.
class _Cover extends StatelessWidget {
  const _Cover({
    Key? key,
    required this.height,
    required this.en,
    required this.compact,
  }) : super(key: key);

  final double height;
  final bool en;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = AppPalette.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Color ink = p.isDark ? Colors.white : const Color(0xFF11161D);
    final double headSize = compact ? 26 : 30;

    return ClipRRect(
      borderRadius: BorderRadius.circular(AppTokens.rXl),
      child: SizedBox(
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            Image.asset(
              // A dedicated wide crop of the same source art: the square icon
              // cropped into a 2:1 plate lost the hat and the sunflower.
              'assets/brand/cover_banner.png',
              fit: BoxFit.cover,
              alignment: const Alignment(0.5, 0),
              filterQuality: FilterQuality.high,
            ),
            if (p.isDark)
              const ColoredBox(color: Color(0x38070A0E)),
            // The eyebrow sits on straw hat / sky, which is the brightest part
            // of the art in light mode and the busiest in dark. Without a top
            // scrim those two mono labels disappear.
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: 78,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: <Color>[
                      p.isDark
                          ? const Color(0x8C070A0E)
                          : const Color(0x66FFFFFF),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: p.isDark
                      ? const <double>[0.33, 0.73, 1]
                      : const <double>[0.36, 0.76, 1],
                  colors: p.isDark
                      ? const <Color>[
                          Color(0x000A0E13),
                          Color(0xC40A0E13),
                          Color(0xFA0A0E13),
                        ]
                      : const <Color>[
                          Color(0x00FFFFFF),
                          Color(0xB8F7FAFD),
                          Color(0xF7F0F4F8),
                        ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 26),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  // Labels sit on their own scrim rather than straight on the
                  // art: straw hat in light mode and hair in dark mode are the
                  // two worst backgrounds in the picture, and a chip is the
                  // only treatment that stays readable on both.
                  Row(
                    children: <Widget>[
                      _CoverLabel(
                        p: p,
                        child: Text.rich(
                          TextSpan(
                            children: <InlineSpan>[
                              TextSpan(
                                text: '>_',
                                style: TextStyle(
                                  color: cs.primary,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const TextSpan(text: '  zcode'),
                            ],
                          ),
                          style: TextStyle(
                            fontSize: 10,
                            fontFamily: 'monospace',
                            letterSpacing: 0.9,
                            color: ink.withValues(alpha: 0.80),
                          ),
                        ),
                      ),
                      const Spacer(),
                      _CoverLabel(
                        p: p,
                        child: Text(
                          'MOBILE',
                          style: TextStyle(
                            fontSize: 8.5,
                            fontFamily: 'monospace',
                            letterSpacing: 2.0,
                            color: ink.withValues(alpha: 0.55),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  // The headline sits in its own translucent panel. It is a
                  // terminal overlay, not text painted on the character: the
                  // face stays unobstructed above it and the caption keeps a
                  // guaranteed contrast in both themes.
                  Container(
                    padding: const EdgeInsets.fromLTRB(11, 7, 12, 8),
                    decoration: BoxDecoration(
                      color: p.isDark
                          ? const Color(0x8C0A0E13)
                          : const Color(0xDEF7FAFD),
                      borderRadius: BorderRadius.circular(AppTokens.rSm),
                      border: Border.all(
                        color: p.isDark
                            ? const Color(0x1FFFFFFF)
                            : const Color(0x1A000000),
                        width: 0.8,
                      ),
                    ),
                    child: Text(
                      en
                          ? 'The terminal,\nin your pocket.'
                          : '把终端\n装进口袋。',
                      style: TextStyle(
                        fontSize: headSize - 4,
                        height: 1.16,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.6,
                        color: ink,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // The cover fades to near-white at the bottom in light mode and
            // would otherwise merge with the sheet. A hairline keeps it a plate.
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(AppTokens.rXl),
                    border: Border.all(
                      color: p.isDark
                          ? const Color(0x14FFFFFF)
                          : const Color(0x12000000),
                      width: 0.8,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Small translucent tag used on top of the cover art.
class _CoverLabel extends StatelessWidget {
  const _CoverLabel({Key? key, required this.p, required this.child})
      : super(key: key);

  final AppPalette p;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(7, 3, 8, 3),
      decoration: BoxDecoration(
        color: p.isDark ? const Color(0x66070A0E) : const Color(0xC7FFFFFF),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: p.isDark ? const Color(0x1FFFFFFF) : const Color(0x14000000),
          width: 0.8,
        ),
      ),
      child: child,
    );
  }
}

class _SectionHead extends StatelessWidget {
  const _SectionHead({
    Key? key,
    required this.index,
    required this.title,
    this.trailing,
  }) : super(key: key);

  final String index;
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = AppPalette.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Row(
      children: <Widget>[
        Text(
          index,
          style: TextStyle(
            fontSize: 10.5,
            fontFamily: 'monospace',
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
            color: cs.primary.withValues(alpha: p.isDark ? 0.95 : 1),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.1,
              color: p.text,
            ),
          ),
        ),
        if (trailing != null) trailing!,
      ],
    );
  }
}

class _MonoChip extends StatelessWidget {
  const _MonoChip(this.text, {Key? key}) : super(key: key);

  final String text;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = AppPalette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: p.line, width: 0.8),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 9,
          fontFamily: 'monospace',
          letterSpacing: 0.8,
          color: p.textTertiary,
        ),
      ),
    );
  }
}

/// One sign-in port. [primary] is the site that matches the current language,
/// and it is the only one allowed to use the accent fill and a filled arrow:
/// two identical rows made the choice look arbitrary.
class _ProviderCard extends StatelessWidget {
  const _ProviderCard({
    Key? key,
    required this.primary,
    required this.title,
    required this.region,
    required this.domain,
    required this.badge,
    required this.tag,
    required this.enabled,
    required this.onTap,
  }) : super(key: key);

  final bool primary;
  final String title;
  final String region;
  final String domain;
  final String badge;
  final String? tag;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = AppPalette.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Color fill = primary
        ? cs.primary.withValues(alpha: p.isDark ? 0.12 : 0.05)
        : (p.isDark ? const Color(0xFF1A222C) : const Color(0xFFF5F7FA));
    final Color edge = primary
        ? cs.primary.withValues(alpha: p.isDark ? 0.38 : 0.26)
        : p.lineStrong;

    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Material(
        color: fill,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.rMd),
          side: BorderSide(color: edge, width: primary ? 1.1 : 0.8),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled ? onTap : null,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 11, 12, 10),
            child: Row(
              children: <Widget>[
                Container(
                  width: primary ? 38 : 34,
                  height: primary ? 38 : 34,
                  decoration: BoxDecoration(
                    color: primary ? cs.primary : Colors.transparent,
                    borderRadius: BorderRadius.circular(11),
                    border: primary
                        ? null
                        : Border.all(
                            color: cs.primary.withValues(alpha: 0.38),
                            width: 1),
                  ),
                  child: Center(
                    child: Text(
                      badge,
                      style: TextStyle(
                        fontSize: primary ? 17 : 14.5,
                        fontWeight: FontWeight.w800,
                        height: 1,
                        color: primary
                            ? cs.onPrimary
                            : cs.primary.withValues(alpha: 0.85),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Flexible(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: primary ? 15.5 : 14,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.1,
                                color: p.text,
                              ),
                            ),
                          ),
                          if (tag != null) ...<Widget>[
                            const SizedBox(width: 7),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 5, vertical: 1.5),
                              decoration: BoxDecoration(
                                color: cs.primary
                                    .withValues(alpha: p.isDark ? 0.20 : 0.10),
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: Text(
                                tag!,
                                style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.w600,
                                  color: cs.primary,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text.rich(
                        TextSpan(
                          children: <InlineSpan>[
                            TextSpan(text: '$region · '),
                            TextSpan(
                              text: domain,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 10.5,
                                letterSpacing: -0.1,
                              ),
                            ),
                          ],
                        ),
                        style: TextStyle(
                          fontSize: 11,
                          color: p.textTertiary,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (primary)
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: cs.primary,
                    ),
                    child: Icon(Icons.arrow_forward_rounded,
                        size: 16, color: cs.onPrimary),
                  )
                else
                  // An outlined arrow gives the second port the same "you can
                  // press me" affordance; a bare chevron read as a disabled row.
                  Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: cs.primary.withValues(alpha: 0.34),
                        width: 1,
                      ),
                    ),
                    child: Icon(Icons.arrow_forward_rounded,
                        size: 14, color: cs.primary.withValues(alpha: 0.8)),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NoteRow extends StatelessWidget {
  const _NoteRow({Key? key, required this.text}) : super(key: key);

  final String text;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = AppPalette.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(Icons.info_outline_rounded,
              size: 13, color: p.textTertiary),
        ),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 11,
              height: 1.45,
              color: p.textTertiary,
            ),
          ),
        ),
      ],
    );
  }
}

class _BusyRow extends StatelessWidget {
  const _BusyRow({Key? key, required this.status}) : super(key: key);

  final String status;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = AppPalette.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Row(
      children: <Widget>[
        SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(cs.primary),
          ),
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            status,
            style: TextStyle(
              fontSize: 11.5,
              height: 1.4,
              color: p.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}

class _UrlBox extends StatelessWidget {
  const _UrlBox({
    Key? key,
    required this.url,
    required this.hint,
    required this.onCopy,
  }) : super(key: key);

  final String url;
  final String hint;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = AppPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          hint,
          style: TextStyle(fontSize: 11, color: p.textTertiary),
        ),
        const SizedBox(height: 6),
        InkWell(
          onTap: onCopy,
          borderRadius: AppTokens.brSm,
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
                    url,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10.5,
                      fontFamily: 'monospace',
                      color: p.textTertiary,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Icon(Icons.copy_rounded, size: 14, color: p.textTertiary),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({Key? key, required this.message}) : super(key: key);

  final String message;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: cs.error.withValues(alpha: 0.10),
        borderRadius: AppTokens.brSm,
        border: Border.all(color: cs.error.withValues(alpha: 0.28), width: 0.8),
      ),
      child: Text(
        message,
        style: TextStyle(fontSize: 12, height: 1.5, color: cs.error),
      ),
    );
  }
}

/// The three account facts. A strip on a normal phone, a list on a narrow one.
class _FactStrip extends StatelessWidget {
  const _FactStrip({
    Key? key,
    required this.en,
    required this.edge,
    required this.surface,
    required this.narrow,
  }) : super(key: key);

  final bool en;
  final Color edge;
  final Color surface;
  final bool narrow;

  @override
  Widget build(BuildContext context) {
    final List<List<String>> facts = <List<String>>[
      <String>[en ? 'PASSWORD' : '密码', en ? 'in the browser' : '浏览器内输入'],
      <String>[en ? 'TOKEN' : '令牌', en ? 'this device only' : '仅存本机'],
      <String>[en ? 'QUOTA' : '额度', en ? 'with desktop' : '与桌面端共用'],
    ];

    final BoxDecoration box = BoxDecoration(
      color: surface,
      borderRadius: BorderRadius.circular(AppTokens.rMd),
      border: Border.all(color: edge, width: 0.8),
    );

    if (narrow) {
      return Container(
        decoration: box,
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          children: <Widget>[
            for (int i = 0; i < facts.length; i++) ...<Widget>[
              if (i > 0)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Container(height: 0.8, color: edge),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    SizedBox(
                      width: 62,
                      child: Text(
                        facts[i][0],
                        style: TextStyle(
                          fontSize: 9,
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.2,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        facts[i][1],
                        style: TextStyle(
                          fontSize: 11.5,
                          height: 1.4,
                          color: AppPalette.of(context).textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      );
    }

    return Container(
      decoration: box,
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (int i = 0; i < facts.length; i++) ...<Widget>[
              if (i > 0) _FactDivider(color: edge),
              Expanded(
                child: _Fact(label: facts[i][0], value: facts[i][1]),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({Key? key, required this.label, required this.value})
      : super(key: key);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = AppPalette.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: TextStyle(
              fontSize: 9,
              fontFamily: 'monospace',
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
              color: cs.primary.withValues(alpha: 0.9),
            ),
          ),
          const SizedBox(height: 5),
          Text(
            value,
            style: TextStyle(
              fontSize: 11.5,
              height: 1.4,
              color: p.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _FactDivider extends StatelessWidget {
  const _FactDivider({Key? key, required this.color}) : super(key: key);

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(width: 0.8, color: color);
  }
}

class _ManifestRow extends StatelessWidget {
  const _ManifestRow({
    Key? key,
    required this.title,
    required this.detail,
    required this.icon,
    required this.dividerColor,
    this.last = false,
  }) : super(key: key);

  final String title;
  final String detail;
  final IconData icon;
  final Color dividerColor;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = AppPalette.of(context);
    return Container(
      decoration: BoxDecoration(
        border: last
            ? null
            : Border(bottom: BorderSide(color: dividerColor, width: 0.8)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 15, color: p.textSecondary),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: p.text,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  detail,
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.35,
                    color: p.textTertiary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({Key? key, required this.en}) : super(key: key);

  final bool en;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = AppPalette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: <Widget>[
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(Icons.lock_outline_rounded, size: 11, color: p.textTertiary),
              const SizedBox(width: 5),
              Text(
                en ? 'OAUTH VIA SYSTEM BROWSER' : 'OAuth · 系统浏览器内完成',
                style: TextStyle(
                  fontSize: 9,
                  fontFamily: 'monospace',
                  letterSpacing: 0.8,
                  color: p.textTertiary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            en
                ? 'Community client · not affiliated with Zhipu or Z.ai'
                : '社区客户端 · 与智谱 / Z.ai 无隶属关系',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 10.5,
              height: 1.4,
              color: p.textTertiary.withValues(alpha: 0.9),
            ),
          ),
        ],
      ),
    );
  }
}
