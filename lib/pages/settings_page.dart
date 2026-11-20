import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/app_config.dart';
import '../state/app_state.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({Key? key}) : super(key: key);

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _key;
  late final TextEditingController _baseUrl;
  late final TextEditingController _model;
  late final TextEditingController _system;
  late final TextEditingController _maxTokens;
  bool _obscure = true;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    final AppConfig c = context.read<AppState>().config ?? AppConfig.empty;
    _key = TextEditingController(text: c.apiKey);
    _baseUrl = TextEditingController(text: c.baseUrl);
    _model = TextEditingController(text: c.model);
    _system = TextEditingController(text: c.systemPrompt);
    _maxTokens = TextEditingController(text: '${c.maxTokens}');
    for (final TextEditingController ctrl in <TextEditingController>[
      _key,
      _baseUrl,
      _model,
      _system,
      _maxTokens,
    ]) {
      ctrl.addListener(_markDirty);
    }
  }

  void _markDirty() {
    if (!_dirty) setState(() => _dirty = true);
  }

  @override
  void dispose() {
    _key.dispose();
    _baseUrl.dispose();
    _model.dispose();
    _system.dispose();
    _maxTokens.dispose();
    super.dispose();
  }

  Future<void> _save(AppState state) async {
    final AppConfig base = state.config ?? AppConfig.empty;
    final int maxTokens =
        int.tryParse(_maxTokens.text.trim()) ?? base.maxTokens;
    await state.saveConfig(base.copyWith(
      apiKey: _key.text.trim(),
      baseUrl: _baseUrl.text.trim(),
      model: _model.text.trim(),
      systemPrompt: _system.text,
      maxTokens: maxTokens.clamp(256, 65536),
    ));
    if (!mounted) return;
    setState(() => _dirty = false);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(S.of(state.config?.language).saved),
        duration: const Duration(milliseconds: 1400),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final AppState state = context.watch<AppState>();
    final AppConfig c = state.config ?? AppConfig.empty;
    final S s = S.of(c.language);
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(s.settings),
        actions: <Widget>[
          if (_dirty)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: TextButton(
                onPressed: () => _save(state),
                child: Text(
                  s.ok,
                  style: TextStyle(
                    color: cs.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 40),
        children: <Widget>[
          _section(s.account, cs),
          _card(<Widget>[
            _providerRow(c, state, s, cs),
            const _Gap(),
            _label(s.baseUrl, cs),
            TextField(
              controller: _baseUrl,
              style: const TextStyle(fontSize: 13.5),
              decoration: const InputDecoration(isDense: true),
            ),
            const _Gap(),
            _label(s.apiKey, cs),
            TextField(
              controller: _key,
              obscureText: _obscure,
              style: const TextStyle(fontSize: 13.5, fontFamily: 'monospace'),
              decoration: InputDecoration(
                isDense: true,
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscure
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    size: 18,
                  ),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
            const _Gap(),
            _label(s.model, cs),
            TextField(
              controller: _model,
              style: const TextStyle(fontSize: 13.5),
              decoration: const InputDecoration(isDense: true),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: <Widget>[
                  for (final String m in kGlmModels)
                    _chip(
                      label: m,
                      active: _model.text.trim() == m,
                      onTap: () {
                        _model.text = m;
                        setState(() {});
                      },
                      cs: cs,
                    ),
                ],
              ),
            ),
            const _Gap(),
            _label(s.systemPrompt, cs),
            TextField(
              controller: _system,
              minLines: 2,
              maxLines: 5,
              style: const TextStyle(fontSize: 13, height: 1.5),
              decoration: const InputDecoration(isDense: true),
            ),
            const _Gap(),
            _label(s.maxTokens, cs),
            TextField(
              controller: _maxTokens,
              keyboardType: TextInputType.number,
              inputFormatters: <TextInputFormatter>[
                FilteringTextInputFormatter.digitsOnly,
              ],
              style: const TextStyle(fontSize: 13.5),
              decoration: const InputDecoration(isDense: true),
            ),
          ]),
          const SizedBox(height: 18),
          _section(s.appearance, cs),
          _card(<Widget>[
            _label(s.theme, cs),
            const SizedBox(height: 6),
            _segmented(
              options: <String>[s.themeSystem, s.themeLight, s.themeDark],
              values: <String>['system', 'light', 'dark'],
              selected: c.themeMode,
              cs: cs,
              onPick: (String v) => state.updatePrefs(themeMode: v),
            ),
            const _Gap(),
            _label(s.accent, cs),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                for (final Accent a in Accent.all)
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: GestureDetector(
                      onTap: () => state.updatePrefs(accentId: a.id),
                      child: Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: Color(a.seed),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: c.accentId == a.id
                                ? cs.onSurface.withOpacity(0.75)
                                : Colors.transparent,
                            width: 2.2,
                          ),
                        ),
                        child: c.accentId == a.id
                            ? const Icon(Icons.check_rounded,
                                size: 17, color: Colors.white)
                            : null,
                      ),
                    ),
                  ),
              ],
            ),
            const _Gap(),
            _label('${s.fontSize}  ${_fontLabel(c.fontScale, s)}', cs),
            const SizedBox(height: 6),
            _segmented(
              options: <String>['A-', 'A', 'A+', 'A++'],
              values: <String>['0.9', '1.0', '1.1', '1.2'],
              selected: c.fontScale.toStringAsFixed(1),
              cs: cs,
              onPick: (String v) =>
                  state.updatePrefs(fontScale: double.parse(v)),
            ),
            const _Gap(),
            _label(s.language, cs),
            const SizedBox(height: 6),
            _segmented(
              options: <String>['简体中文', 'English'],
              values: <String>['zh', 'en'],
              selected: c.language,
              cs: cs,
              onPick: (String v) => state.updatePrefs(language: v),
            ),
          ]),
          const SizedBox(height: 18),
          _section(s.dataSection, cs),
          _card(<Widget>[
            _actionRow(
              icon: Icons.key_outlined,
              label: s.exportConfig,
              hint: s.exportHint,
              onTap: () => _showExport(state, c, s),
            ),
            const Divider(height: 18),
            _actionRow(
              icon: Icons.download_outlined,
              label: s.importConfig,
              hint: s.importHint,
              onTap: () => _showImport(state, s),
            ),
            const Divider(height: 18),
            _actionRow(
              icon: Icons.delete_forever_outlined,
              label: s.clearAll,
              hint: s.clearAllConfirm,
              danger: true,
              onTap: () => _confirmWipe(state, s),
            ),
          ]),
          const SizedBox(height: 18),
          _section(s.about, cs),
          _card(<Widget>[
            Row(
              children: <Widget>[
                Text(
                  '${s.appName} Mobile',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                  ),
                ),
                const Spacer(),
                Text(
                  'v0.2.0',
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurface.withOpacity(0.4),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              s.disclaimer,
              style: TextStyle(
                fontSize: 12,
                height: 1.55,
                color: cs.onSurface.withOpacity(0.45),
              ),
            ),
          ]),
          if (_dirty)
            Padding(
              padding: const EdgeInsets.only(top: 22),
              child: SizedBox(
                height: 46,
                child: ElevatedButton(
                  onPressed: () => _save(state),
                  style: ElevatedButton.styleFrom(
                    primary: cs.primary,
                    onPrimary: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(13),
                    ),
                  ),
                  child: Text(
                    s.ok,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _fontLabel(double scale, S s) {
    if (scale <= 0.92) return 'S';
    if (scale <= 1.02) return 'M';
    if (scale <= 1.12) return 'L';
    return 'XL';
  }

  Widget _section(String title, ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 10, 4, 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3,
          color: cs.onSurface.withOpacity(0.42),
        ),
      ),
    );
  }

  Widget _card(List<Widget> children) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).cardTheme.color,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Theme.of(context).dividerTheme.color ?? Colors.transparent,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }

  Widget _label(String text, ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 5, left: 2),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          color: cs.onSurface.withOpacity(0.55),
        ),
      ),
    );
  }

  Widget _providerRow(AppConfig c, AppState state, S s, ColorScheme cs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _label(s.provider, cs),
        Row(
          children: <Widget>[
            _chip(
              label: 'BigModel 国内',
              active: c.provider == 'bigmodel',
              onTap: () {
                _baseUrl.text = Endpoints.bigmodel;
                state.saveConfig(c.copyWith(
                  provider: 'bigmodel',
                  baseUrl: Endpoints.bigmodel,
                ));
              },
              cs: cs,
            ),
            const SizedBox(width: 8),
            _chip(
              label: 'Z.ai 海外',
              active: c.provider == 'zai',
              onTap: () {
                _baseUrl.text = Endpoints.zai;
                state.saveConfig(c.copyWith(
                  provider: 'zai',
                  baseUrl: Endpoints.zai,
                ));
              },
              cs: cs,
            ),
          ],
        ),
      ],
    );
  }

  Widget _chip({
    required String label,
    required bool active,
    required VoidCallback onTap,
    required ColorScheme cs,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
        decoration: BoxDecoration(
          color: active ? cs.primary.withOpacity(0.12) : null,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: active
                ? cs.primary.withOpacity(0.4)
                : cs.onSurface.withOpacity(0.14),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: active ? FontWeight.w600 : FontWeight.w400,
            color:
                active ? cs.primary : cs.onSurface.withOpacity(0.65),
          ),
        ),
      ),
    );
  }

  Widget _segmented({
    required List<String> options,
    required List<String> values,
    required String selected,
    required ColorScheme cs,
    required ValueChanged<String> onPick,
  }) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: cs.onSurface.withOpacity(0.05),
        borderRadius: BorderRadius.circular(11),
      ),
      child: Row(
        children: <Widget>[
          for (int i = 0; i < options.length; i++)
            Expanded(
              child: GestureDetector(
                onTap: () => onPick(values[i]),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    color: selected == values[i]
                        ? (Theme.of(context).brightness == Brightness.dark
                            ? const Color(0xFF262D38)
                            : Colors.white)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(9),
                    boxShadow: selected == values[i]
                        ? <BoxShadow>[
                            BoxShadow(
                              color: Colors.black.withOpacity(0.06),
                              blurRadius: 4,
                              offset: const Offset(0, 1),
                            ),
                          ]
                        : null,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    options[i],
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: selected == values[i]
                          ? FontWeight.w600
                          : FontWeight.w400,
                      color: selected == values[i]
                          ? cs.onSurface
                          : cs.onSurface.withOpacity(0.55),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _actionRow({
    required IconData icon,
    required String label,
    required String hint,
    required VoidCallback onTap,
    bool danger = false,
  }) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Color color = danger ? cs.error : cs.onSurface;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(icon, size: 18, color: color.withOpacity(0.7)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 13.5,
                      color: danger ? cs.error : cs.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    hint,
                    style: TextStyle(
                      fontSize: 11.5,
                      height: 1.45,
                      color: cs.onSurface.withOpacity(0.4),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showExport(AppState state, AppConfig c, S s) {
    final String bundle = c.exportBundle();
    showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(s.exportConfig,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              s.exportHint,
              style: const TextStyle(fontSize: 12.5, height: 1.5),
            ),
            const SizedBox(height: 10),
            Container(
              constraints: const BoxConstraints(maxHeight: 150),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Theme.of(ctx).colorScheme.onSurface.withOpacity(0.05),
                borderRadius: BorderRadius.circular(10),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  bundle,
                  style: const TextStyle(
                      fontSize: 10.5, fontFamily: 'monospace', height: 1.4),
                ),
              ),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(s.cancel),
          ),
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: bundle));
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context)
                  .showSnackBar(SnackBar(content: Text(s.copied)));
            },
            child: Text(s.copy),
          ),
        ],
      ),
    );
  }

  void _showImport(AppState state, S s) {
    final TextEditingController ctrl = TextEditingController();
    showDialog<void>(
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
            onPressed: () => Navigator.pop(ctx),
            child: Text(s.cancel),
          ),
          TextButton(
            onPressed: () async {
              final bool ok = state.importConfig(ctrl.text);
              Navigator.pop(ctx);
              if (ok) {
                final AppConfig? now = state.config;
                if (now != null) {
                  _key.text = now.apiKey;
                  _baseUrl.text = now.baseUrl;
                  _model.text = now.model;
                  _system.text = now.systemPrompt;
                  _maxTokens.text = '${now.maxTokens}';
                }
                setState(() => _dirty = false);
              }
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(ok ? s.importOk : s.importFail)),
              );
            },
            child: Text(s.ok),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmWipe(AppState state, S s) async {
    final bool? yes = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        content: Text(s.clearAllConfirm,
            style: const TextStyle(fontSize: 14.5, height: 1.5)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(s.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(s.delete, style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
          ),
        ],
      ),
    );
    if (yes != true) return;
    await state.clearAllData();
    if (mounted) Navigator.of(context).pop();
  }
}

class _Gap extends StatelessWidget {
  const _Gap();
  @override
  Widget build(BuildContext context) => const SizedBox(height: 12);
}
