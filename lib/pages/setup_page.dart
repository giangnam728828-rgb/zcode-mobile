import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/app_config.dart';
import '../state/app_state.dart';

/// First run: pick a region, paste a Coding Plan key, start. Also accepts a
/// `zcm://` bundle so a phone and a browser can share one token.
class SetupPage extends StatefulWidget {
  const SetupPage({Key? key, required this.s}) : super(key: key);

  final S s;

  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> {
  final TextEditingController _key = TextEditingController();
  final TextEditingController _baseUrl =
      TextEditingController(text: Endpoints.bigmodel);
  String _provider = 'bigmodel';
  String _model = 'glm-5.3';
  bool _obscure = true;
  bool _busy = false;

  @override
  void dispose() {
    _key.dispose();
    _baseUrl.dispose();
    super.dispose();
  }

  void _pickProvider(String p) {
    setState(() {
      _provider = p;
      _baseUrl.text = p == 'zai' ? Endpoints.zai : Endpoints.bigmodel;
    });
  }

  Future<void> _start() async {
    final String key = _key.text.trim();
    if (key.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(widget.s.needKey)),
      );
      return;
    }
    setState(() => _busy = true);
    final AppState state = context.read<AppState>();
    final AppConfig base = state.config ?? AppConfig.empty;
    await state.saveConfig(base.copyWith(
      provider: _provider,
      baseUrl: _baseUrl.text.trim(),
      apiKey: key,
      model: _model,
    ));
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final bool dark = theme.brightness == Brightness.dark;
    final S s = widget.s;

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[
              cs.primary.withOpacity(dark ? 0.10 : 0.06),
              theme.scaffoldBackgroundColor,
            ],
            stops: const <double>[0.0, 0.42],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(22, 26, 22, 26),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    _logo(cs),
                    const SizedBox(height: 22),
                    Text(
                      s.appName,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 27,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.6,
                        color: cs.onSurface,
                      ),
                    ),
                    const SizedBox(height: 7),
                    Text(
                      s.tagline,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13.5,
                        height: 1.5,
                        color: cs.onSurface.withOpacity(0.52),
                      ),
                    ),
                    const SizedBox(height: 26),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: theme.cardTheme.color,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: cs.onSurface.withOpacity(0.08),
                        ),
                        boxShadow: <BoxShadow>[
                          BoxShadow(
                            color: Colors.black.withOpacity(dark ? 0.25 : 0.04),
                            blurRadius: 18,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          _label(s.provider, cs),
                          Row(
                            children: <Widget>[
                              Expanded(
                                child: _seg(
                                  label: 'BigModel 国内',
                                  active: _provider == 'bigmodel',
                                  onTap: () => _pickProvider('bigmodel'),
                                  cs: cs,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _seg(
                                  label: 'Z.ai 海外',
                                  active: _provider == 'zai',
                                  onTap: () => _pickProvider('zai'),
                                  cs: cs,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          _label(s.apiKey, cs),
                          TextField(
                            controller: _key,
                            obscureText: _obscure,
                            autocorrect: false,
                            enableSuggestions: false,
                            style: const TextStyle(
                              fontSize: 13.5,
                              fontFamily: 'monospace',
                            ),
                            decoration: InputDecoration(
                              hintText: s.keyHint,
                              hintStyle: const TextStyle(
                                  fontSize: 12.5, fontFamily: null),
                              isDense: true,
                              suffixIcon: IconButton(
                                icon: Icon(
                                  _obscure
                                      ? Icons.visibility_off_outlined
                                      : Icons.visibility_outlined,
                                  size: 18,
                                ),
                                onPressed: () =>
                                    setState(() => _obscure = !_obscure),
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          _label(s.model, cs),
                          Wrap(
                            spacing: 7,
                            runSpacing: 7,
                            children: <Widget>[
                              for (final String m in kGlmModels)
                                _modelChip(m, cs),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                    SizedBox(
                      height: 50,
                      child: ElevatedButton(
                        onPressed: _busy ? null : _start,
                        style: ElevatedButton.styleFrom(
                          primary: cs.primary,
                          onPrimary: Colors.white,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        child: _busy
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                      Colors.white),
                                ),
                              )
                            : Text(
                                s.start,
                                style: const TextStyle(
                                  fontSize: 15.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    TextButton(
                      onPressed: _import,
                      child: Text(
                        s.importInstead,
                        style: TextStyle(
                          fontSize: 13,
                          color: cs.primary.withOpacity(0.9),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      s.tokensNote,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 10.5,
                        height: 1.55,
                        color: cs.onSurface.withOpacity(0.32),
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

  Widget _logo(ColorScheme cs) {
    return Center(
      child: Container(
        width: 66,
        height: 66,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: <Color>[cs.primary, cs.primary.withOpacity(0.66)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(21),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: cs.primary.withOpacity(0.28),
              blurRadius: 24,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        alignment: Alignment.center,
        child: const Icon(Icons.bolt_rounded, size: 36, color: Colors.white),
      ),
    );
  }

  Widget _label(String text, ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6, left: 2),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          color: cs.onSurface.withOpacity(0.55),
        ),
      ),
    );
  }

  Widget _seg({
    required String label,
    required bool active,
    required VoidCallback onTap,
    required ColorScheme cs,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? cs.primary.withOpacity(0.11) : null,
          borderRadius: BorderRadius.circular(11),
          border: Border.all(
            color: active
                ? cs.primary.withOpacity(0.42)
                : cs.onSurface.withOpacity(0.12),
            width: active ? 1.4 : 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: active ? FontWeight.w600 : FontWeight.w400,
            color: active ? cs.primary : cs.onSurface.withOpacity(0.62),
          ),
        ),
      ),
    );
  }

  Widget _modelChip(String m, ColorScheme cs) {
    final bool active = _model == m;
    return GestureDetector(
      onTap: () => setState(() => _model = m),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        decoration: BoxDecoration(
          color: active ? cs.primary.withOpacity(0.12) : null,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(
            color: active
                ? cs.primary.withOpacity(0.45)
                : cs.onSurface.withOpacity(0.12),
          ),
        ),
        child: Text(
          m,
          style: TextStyle(
            fontSize: 12,
            fontWeight: active ? FontWeight.w600 : FontWeight.w400,
            color: active ? cs.primary : cs.onSurface.withOpacity(0.6),
          ),
        ),
      ),
    );
  }

  Future<void> _import() async {
    final TextEditingController ctrl = TextEditingController();
    final S s = widget.s;
    final AppState state = context.read<AppState>();
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(s.importConfig,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        content: TextField(
          controller: ctrl,
          minLines: 3,
          maxLines: 6,
          autofocus: true,
          style: const TextStyle(fontSize: 11.5, fontFamily: 'monospace'),
          decoration: InputDecoration(hintText: s.importHint),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(s.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(s.ok),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final bool done = state.importConfig(ctrl.text);
    if (!mounted) return;
    if (!done) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(s.importFail)));
    }
  }
}
