import 'dart:convert';

/// Endpoint presets for GLM Coding Plan (Anthropic-compatible).
class Endpoints {
  static const String bigmodel = 'https://open.bigmodel.cn/api/anthropic';
  static const String zai = 'https://api.z.ai/api/anthropic';
}

/// Model ids offered in the picker (a custom id can always be typed in).
const List<String> kGlmModels = <String>[
  'glm-5.3',
  'glm-5.2',
  'glm-4.6',
  'glm-4.5',
  'glm-4.5-air',
];

/// Accent presets. Kept as ids so they survive restarts.
class Accent {
  const Accent(this.id, this.seed, this.label);
  final String id;
  final int seed;
  final String label;

  static const Accent indigo = Accent('indigo', 0xFF3D5AFE, '靛蓝');
  static const Accent ocean = Accent('ocean', 0xFF0E9F9F, '海青');
  static const Accent violet = Accent('violet', 0xFF8B5CF6, '紫罗兰');
  static const Accent forest = Accent('forest', 0xFF10A37F, '森林');
  static const Accent amber = Accent('amber', 0xFFE08700, '暖橙');

  static const List<Accent> all = <Accent>[indigo, ocean, violet, forest, amber];

  static Accent byId(String? id) {
    for (final Accent a in all) {
      if (a.id == id) return a;
    }
    return indigo;
  }
}

class AppConfig {
  final String provider; // 'bigmodel' | 'zai' | 'custom'
  final String baseUrl;
  final String apiKey;
  final String model;
  final String systemPrompt;
  final int maxTokens;

  /// UI preferences live here too, so one JSON round-trip carries everything.
  final String themeMode; // 'system' | 'light' | 'dark'
  final String accentId;
  final double fontScale; // 0.9 / 1.0 / 1.1 / 1.2
  final String language; // 'zh' | 'en'

  /// 'auto' | 'soft' | 'full' | 'flat'. 'auto' lets the frame probe in
  /// [GlassProbe] choose; the others are a user lock. See GlassQuality.
  final String glassQuality;

  /// Where `auto` currently sits. Persisted so the next launch starts at the
  /// tier this device actually managed, instead of flickering back up to soft
  /// for two seconds on every cold start.
  final String glassAutoTier;

  /// Whether the one-time "we lowered the glass" notice has been shown.
  final bool glassAutoHinted;

  /// Tool approval policy: 'risky' asks only for destructive shell/file writes,
  /// 'ask' asks for every tool, 'auto' lets the agent run unattended.
  final String approvalMode;

  /// Sampling temperature sent with every turn.
  final double temperature;

  /// Fold old turns into a summary before the context gets too long.
  final bool autoCompact;

  /// Hard cap on tool round-trips inside one turn.
  final int maxSteps;

  const AppConfig({
    required this.provider,
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    required this.systemPrompt,
    required this.maxTokens,
    this.themeMode = 'system',
    this.accentId = 'indigo',
    this.fontScale = 1.0,
    this.language = 'zh',
    this.glassQuality = 'auto',
    this.glassAutoTier = 'soft',
    this.glassAutoHinted = false,
    this.approvalMode = 'risky',
    this.temperature = 0.7,
    this.autoCompact = true,
    this.maxSteps = 20,
  });

  static const String defaultSystemPrompt =
      'You are ZCode, a coding agent running on the user\'s phone. '
      'Answer in the user\'s language. Be precise and practical. '
      'When you output code, always use fenced code blocks with a language tag.';

  static const AppConfig empty = AppConfig(
    provider: 'bigmodel',
    baseUrl: Endpoints.bigmodel,
    apiKey: '',
    model: 'glm-5.3',
    systemPrompt: defaultSystemPrompt,
    maxTokens: 8192,
  );

  bool get isConfigured => model.trim().isNotEmpty && baseUrl.trim().isNotEmpty;

  Accent get accent => Accent.byId(accentId);

  String get providerLabel {
    switch (provider) {
      case 'bigmodel':
        return 'BigModel (国内)';
      case 'zai':
        return 'Z.ai (海外)';
      default:
        return '自定义端点';
    }
  }

  AppConfig copyWith({
    String? provider,
    String? baseUrl,
    String? apiKey,
    String? model,
    String? systemPrompt,
    int? maxTokens,
    String? themeMode,
    String? accentId,
    double? fontScale,
    String? language,
    String? glassQuality,
    String? glassAutoTier,
    bool? glassAutoHinted,
    String? approvalMode,
    double? temperature,
    bool? autoCompact,
    int? maxSteps,
  }) {
    return AppConfig(
      provider: provider ?? this.provider,
      baseUrl: baseUrl ?? this.baseUrl,
      apiKey: apiKey ?? this.apiKey,
      model: model ?? this.model,
      systemPrompt: systemPrompt ?? this.systemPrompt,
      maxTokens: maxTokens ?? this.maxTokens,
      themeMode: themeMode ?? this.themeMode,
      accentId: accentId ?? this.accentId,
      fontScale: fontScale ?? this.fontScale,
      language: language ?? this.language,
      glassQuality: glassQuality ?? this.glassQuality,
      glassAutoTier: glassAutoTier ?? this.glassAutoTier,
      glassAutoHinted: glassAutoHinted ?? this.glassAutoHinted,
      approvalMode: approvalMode ?? this.approvalMode,
      temperature: temperature ?? this.temperature,
      autoCompact: autoCompact ?? this.autoCompact,
      maxSteps: maxSteps ?? this.maxSteps,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'provider': provider,
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        'model': model,
        'systemPrompt': systemPrompt,
        'maxTokens': maxTokens,
        'themeMode': themeMode,
        'accentId': accentId,
        'fontScale': fontScale,
        'language': language,
        'glassQuality': glassQuality,
        'glassAutoTier': glassAutoTier,
        'glassAutoHinted': glassAutoHinted,
        'approvalMode': approvalMode,
        'temperature': temperature,
        'autoCompact': autoCompact,
        'maxSteps': maxSteps,
      };

  factory AppConfig.fromJson(Map<String, dynamic> json) {
    double fs = 1.0;
    final Object? rawScale = json['fontScale'];
    if (rawScale is num) fs = rawScale.toDouble();
    double temp = 0.7;
    final Object? rawTemp = json['temperature'];
    if (rawTemp is num) temp = rawTemp.toDouble();
    // `glassAutoHinted` only exists from 3.8.0 on. A config without it predates
    // automatic tiering, so its `glassQuality` is the old hard-coded default
    // rather than a considered choice — hand it to the probe instead of
    // freezing every existing install on whatever it happened to store.
    final bool legacyGlass = !json.containsKey('glassAutoHinted');
    return AppConfig(
      provider: (json['provider'] as String?) ?? 'bigmodel',
      baseUrl: (json['baseUrl'] as String?) ?? Endpoints.bigmodel,
      apiKey: (json['apiKey'] as String?) ?? '',
      model: (json['model'] as String?) ?? 'glm-5.3',
      systemPrompt: (json['systemPrompt'] as String?) ?? defaultSystemPrompt,
      maxTokens: (json['maxTokens'] as int?) ?? 8192,
      themeMode: (json['themeMode'] as String?) ?? 'system',
      accentId: (json['accentId'] as String?) ?? 'indigo',
      fontScale: fs.clamp(0.85, 1.3),
      language: (json['language'] as String?) ?? 'zh',
      glassQuality: legacyGlass
          ? 'auto'
          : ((json['glassQuality'] as String?) ?? 'auto'),
      glassAutoTier: (json['glassAutoTier'] as String?) ?? 'soft',
      glassAutoHinted: (json['glassAutoHinted'] as bool?) ?? false,
      approvalMode: (json['approvalMode'] as String?) ?? 'risky',
      temperature: temp.clamp(0.0, 1.0),
      autoCompact: (json['autoCompact'] as bool?) ?? true,
      maxSteps: ((json['maxSteps'] as int?) ?? 20).clamp(1, 60),
    );
  }

  String encode() => jsonEncode(toJson());

  factory AppConfig.decode(String raw) =>
      AppConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);

  /// Portable token bundle shared between phone and web builds.
  /// `zcm://` + base64(json) — the API key travels with it.
  String exportBundle() {
    final Map<String, dynamic> payload = <String, dynamic>{
      'v': 1,
      'provider': provider,
      'baseUrl': baseUrl,
      'apiKey': apiKey,
      'model': model,
      'systemPrompt': systemPrompt,
      'maxTokens': maxTokens,
    };
    return 'zcm://${base64Url.encode(utf8.encode(jsonEncode(payload)))}';
  }

  /// Accepts a `zcm://` bundle or a raw JSON object.
  static AppConfig? tryImport(String raw, AppConfig fallback) {
    final String text = raw.trim();
    if (text.isEmpty) return null;
    try {
      String body = text;
      if (body.startsWith('zcm://')) {
        body = utf8.decode(base64Url.decode(body.substring(6)));
      }
      final Map<String, dynamic> json =
          jsonDecode(body) as Map<String, dynamic>;
      final AppConfig parsed = AppConfig.fromJson(json);
      if (parsed.apiKey.trim().isEmpty) return null;
      return parsed.copyWith(
        themeMode: fallback.themeMode,
        accentId: fallback.accentId,
        fontScale: fallback.fontScale,
        language: fallback.language,
      );
    } catch (_) {
      return null;
    }
  }
}
