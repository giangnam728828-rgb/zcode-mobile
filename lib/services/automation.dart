import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'store.dart';

/// A condition that starts a rule.
///
/// Kinds are plain strings rather than subclasses so the whole rule survives a
/// round trip through JSON without a discriminator table.
class AutomationTrigger {
  const AutomationTrigger(this.kind, [this.args = const <String, dynamic>{}]);

  final String kind;
  final Map<String, dynamic> args;

  /// Time-of-day triggers need a minute of tolerance; everything else is level
  /// based and gets re-armed when the condition goes away.
  bool get isClock =>
      kind == 'interval' || kind == 'daily' || kind == 'idle';

  Map<String, dynamic> toJson() => <String, dynamic>{'kind': kind, 'args': args};

  static AutomationTrigger fromJson(Map<String, dynamic> json) {
    return AutomationTrigger(
      '${json['kind'] ?? 'manual'}',
      (json['args'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{},
    );
  }

  String get summary {
    switch (kind) {
      case 'interval':
        final int m = (args['minutes'] as num?)?.toInt() ?? 30;
        if (m % 60 == 0) return '每 ${m ~/ 60} 小时';
        return '每 $m 分钟';
      case 'daily':
        final int h = (args['hour'] as num?)?.toInt() ?? 9;
        final int m = (args['minute'] as num?)?.toInt() ?? 0;
        final List<dynamic> days =
            (args['weekdays'] as List<dynamic>?) ?? const <dynamic>[];
        final String clock =
            '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
        if (days.isEmpty) return '每天 $clock';
        if (days.length == 7) return '每天 $clock';
        final List<int> sorted =
            days.map((dynamic d) => (d as num).toInt()).toList()..sort();
        if (sorted.length == 5 &&
            sorted[0] == 1 &&
            sorted[1] == 2 &&
            sorted[2] == 3 &&
            sorted[3] == 4 &&
            sorted[4] == 5) {
          return '工作日 $clock';
        }
        if (sorted.length == 2 && sorted[0] == 6 && sorted[1] == 7) {
          return '周末 $clock';
        }
        const List<String> names = <String>['一', '二', '三', '四', '五', '六', '日'];
        final String label = days
            .map((dynamic d) => names[((d as num).toInt() - 1).clamp(0, 6)])
            .join('、');
        return '周$label $clock';
      case 'battery_below':
        return '电量低于 ${(args['level'] as num?)?.toInt() ?? 20}%';
      case 'battery_above':
        return '电量高于 ${(args['level'] as num?)?.toInt() ?? 80}%';
      case 'charging':
        return '插上电源';
      case 'unplugged':
        return '拔掉电源';
      case 'wifi_on':
        final String ssid = '${args['ssid'] ?? ''}';
        return ssid.isEmpty ? '连上 Wi-Fi' : '连上 Wi-Fi「$ssid」';
      case 'wifi_off':
        return '断开 Wi-Fi';
      case 'screen_on':
        return '点亮屏幕';
      case 'unlock':
        return '解锁手机';
      case 'boot':
        return '开机后首次打开';
      case 'battery_full':
        return '电量充满';
      case 'idle':
        final int m = (args['minutes'] as num?)?.toInt() ?? 30;
        return '息屏 $m 分钟后';
      case 'app_foreground':
        final String label = '${args['label'] ?? ''}';
        final String pkg = '${args['package'] ?? ''}';
        final String name = label.isNotEmpty ? label : pkg;
        return name.isEmpty ? '打开任意应用' : '打开「$name」时';
      case 'notification':
        final String app = '${args['app'] ?? ''}';
        final String key = '${args['keyword'] ?? ''}';
        if (key.isNotEmpty) {
          return app.isEmpty ? '通知含「$key」' : '「$app」通知含「$key」';
        }
        return app.isEmpty ? '收到任意通知' : '收到「$app」通知';
      case 'screen_text':
        final String t = '${args['text'] ?? ''}';
        return t.isEmpty ? '屏幕文字变化' : '屏幕出现「$t」';
      case 'manual':
      default:
        return '仅手动运行';
    }
  }
}

/// One step a rule performs. Steps run in order and stop at the first failure.
class AutomationAction {
  const AutomationAction(this.kind, [this.args = const <String, dynamic>{}]);

  final String kind;
  final Map<String, dynamic> args;

  Map<String, dynamic> toJson() => <String, dynamic>{'kind': kind, 'args': args};

  static AutomationAction fromJson(Map<String, dynamic> json) {
    return AutomationAction(
      '${json['kind'] ?? 'notify'}',
      (json['args'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{},
    );
  }

  String get summary {
    switch (kind) {
      case 'agent':
        final String p = '${args['prompt'] ?? ''}'.replaceAll('\n', ' ');
        return p.length > 42 ? '智能体：${p.substring(0, 42)}…' : '智能体：$p';
      case 'shell':
        final String c = '${args['command'] ?? ''}'.replaceAll('\n', ' ');
        final String mode = '${args['mode'] ?? 'auto'}';
        final String tag = mode == 'auto'
            ? ''
            : (mode == 'builtin'
                ? 'sh · '
                : (mode == 'termux' ? 'Termux · ' : '$mode · '));
        return '命令：$tag${c.length > 34 ? '${c.substring(0, 34)}…' : c}';
      case 'notify':
        return '通知：${args['title'] ?? ''}';
      case 'device':
        return '设备：${DeviceAction.label('${args['action'] ?? ''}')}';
      case 'webhook':
        return '请求：${args['url'] ?? ''}';
      case 'a11y':
        return '屏幕：${A11yAction.label('${args['op'] ?? ''}')}'
            '${'${args['text'] ?? ''}'.isEmpty ? '' : '「${args['text']}」'}';
      case 'speak':
        final String s = '${args['text'] ?? ''}'.replaceAll('\n', ' ');
        return '朗读：${s.length > 30 ? '${s.substring(0, 30)}…' : s}';
      case 'clipboard':
        return '复制到剪贴板';
      case 'open_app':
        return '打开应用：${args['package'] ?? ''}';
      case 'delay':
        return '等待 ${(args['seconds'] as num?)?.toInt() ?? 5} 秒';
      default:
        return kind;
    }
  }
}

/// A saved rule: when to run, what to run, and what happened last time.
class AutomationRule {
  AutomationRule({
    required this.id,
    required this.name,
    required this.trigger,
    required this.actions,
    this.enabled = true,
    this.notify = true,
    this.lastRunMs = 0,
    this.runCount = 0,
    this.lastResult = '',
    this.builtin = false,
  });

  String id;
  String name;
  bool enabled;
  AutomationTrigger trigger;
  List<AutomationAction> actions;
  bool notify;
  int lastRunMs;
  int runCount;
  String lastResult;

  /// Built-in templates are still copied into the user's list on demand, but
  /// the flag lets the UI show them differently.
  final bool builtin;

  DateTime? get lastRun =>
      lastRunMs == 0 ? null : DateTime.fromMillisecondsSinceEpoch(lastRunMs);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'enabled': enabled,
        'trigger': trigger.toJson(),
        'actions': actions.map((AutomationAction a) => a.toJson()).toList(),
        'notify': notify,
        'lastRunMs': lastRunMs,
        'runCount': runCount,
        'lastResult': lastResult,
      };

  static AutomationRule fromJson(Map<String, dynamic> json) {
    return AutomationRule(
      id: '${json['id'] ?? DateTime.now().microsecondsSinceEpoch}',
      name: '${json['name'] ?? '未命名规则'}',
      enabled: json['enabled'] != false,
      trigger: AutomationTrigger.fromJson(
          (json['trigger'] as Map?)?.cast<String, dynamic>() ??
              <String, dynamic>{}),
      actions: ((json['actions'] as List<dynamic>?) ?? const <dynamic>[])
          .map((dynamic e) =>
              AutomationAction.fromJson((e as Map).cast<String, dynamic>()))
          .toList(),
      notify: json['notify'] != false,
      lastRunMs: (json['lastRunMs'] as num?)?.toInt() ?? 0,
      runCount: (json['runCount'] as num?)?.toInt() ?? 0,
      lastResult: '${json['lastResult'] ?? ''}',
    );
  }

  AutomationRule copy() => AutomationRule(
        id: id,
        name: name,
        trigger: trigger,
        actions: List<AutomationAction>.from(actions),
        enabled: enabled,
        notify: notify,
        lastRunMs: lastRunMs,
        runCount: runCount,
        lastResult: lastResult,
      );
}

/// A single execution record, kept short so the log stays readable.
class AutomationLog {
  const AutomationLog({
    required this.ruleName,
    required this.at,
    required this.ok,
    required this.detail,
  });

  final String ruleName;
  final DateTime at;
  final bool ok;
  final String detail;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'rule': ruleName,
        'at': at.millisecondsSinceEpoch,
        'ok': ok,
        'detail': detail,
      };

  static AutomationLog fromJson(Map<String, dynamic> json) => AutomationLog(
        ruleName: '${json['rule'] ?? ''}',
        at: DateTime.fromMillisecondsSinceEpoch(
            (json['at'] as num?)?.toInt() ?? 0),
        ok: json['ok'] == true,
        detail: '${json['detail'] ?? ''}',
      );
}

/// Everything the engine knows about the phone at one moment. Kept explicit so
/// the decision function is pure and testable without a device.
class AutomationSignal {
  const AutomationSignal({
    this.batteryLevel = -1,
    this.charging = false,
    this.wifi = false,
    this.ssid = '',
    this.screenOn = true,
    this.booted = false,
    this.foreground = '',
    this.foregroundLabel = '',
    this.notifPackage = '',
    this.notifApp = '',
    this.notifTitle = '',
    this.notifText = '',
    this.screenText = '',
  });

  final int batteryLevel;
  final bool charging;
  final bool wifi;
  final String ssid;
  final bool screenOn;
  final bool booted;

  /// Package and label of the app that just came to the front.
  final String foreground;
  final String foregroundLabel;

  /// Last notification seen by the listener.
  final String notifPackage;
  final String notifApp;
  final String notifTitle;
  final String notifText;

  /// Text of the most recent screen snapshot taken by the a11y service.
  final String screenText;

  AutomationSignal copyWith({
    int? batteryLevel,
    bool? charging,
    bool? wifi,
    String? ssid,
    bool? screenOn,
    bool? booted,
    String? foreground,
    String? foregroundLabel,
    String? notifPackage,
    String? notifApp,
    String? notifTitle,
    String? notifText,
    String? screenText,
  }) {
    return AutomationSignal(
      batteryLevel: batteryLevel ?? this.batteryLevel,
      charging: charging ?? this.charging,
      wifi: wifi ?? this.wifi,
      ssid: ssid ?? this.ssid,
      screenOn: screenOn ?? this.screenOn,
      booted: booted ?? this.booted,
      foreground: foreground ?? this.foreground,
      foregroundLabel: foregroundLabel ?? this.foregroundLabel,
      notifPackage: notifPackage ?? this.notifPackage,
      notifApp: notifApp ?? this.notifApp,
      notifTitle: notifTitle ?? this.notifTitle,
      notifText: notifText ?? this.notifText,
      screenText: screenText ?? this.screenText,
    );
  }
}

/// Screen operations that run through the accessibility service instead of a
/// shell. They work without root, which is the whole point.
class A11yAction {
  const A11yAction(this.id, this.zh, this.en);

  final String id;
  final String zh;
  final String en;

  static const List<A11yAction> all = <A11yAction>[
    A11yAction('read', '读取屏幕文字', 'Read screen'),
    A11yAction('click', '按文字点击', 'Tap text'),
    A11yAction('long_click', '长按文字', 'Long-press text'),
    A11yAction('input', '输入文字', 'Type text'),
    A11yAction('scroll_down', '向下滚动', 'Scroll down'),
    A11yAction('scroll_up', '向上滚动', 'Scroll up'),
    A11yAction('back', '返回键', 'Back'),
    A11yAction('home', '回到桌面', 'Home'),
    A11yAction('recents', '最近任务', 'Recents'),
    A11yAction('notifications', '拉下通知栏', 'Notification shade'),
    A11yAction('screenshot', '系统截屏', 'Screenshot'),
    A11yAction('lock', '锁屏', 'Lock'),
  ];

  static String label(String id) {
    for (final A11yAction a in all) {
      if (a.id == id) return a.zh;
    }
    return id.isEmpty ? '未选择' : id;
  }

  static bool needsText(String id) =>
      id == 'click' || id == 'long_click' || id == 'input';

  static bool needsValue(String id) => id == 'input';
}

/// Human labels and the shell a device action turns into. Kept in one place so
/// the picker, the editor and the executor cannot drift apart.
class DeviceAction {
  const DeviceAction(this.id, this.zh, this.en);

  final String id;
  final String zh;
  final String en;

  static const List<DeviceAction> all = <DeviceAction>[
    DeviceAction('wifi_on', '打开 Wi-Fi', 'Wi-Fi on'),
    DeviceAction('wifi_off', '关闭 Wi-Fi', 'Wi-Fi off'),
    DeviceAction('data_on', '打开移动数据', 'Mobile data on'),
    DeviceAction('data_off', '关闭移动数据', 'Mobile data off'),
    DeviceAction('airplane_on', '飞行模式开', 'Airplane mode on'),
    DeviceAction('airplane_off', '飞行模式关', 'Airplane mode off'),
    DeviceAction('dnd_on', '勿扰模式开', 'Do not disturb on'),
    DeviceAction('dnd_off', '勿扰模式关', 'Do not disturb off'),
    DeviceAction('brightness_low', '亮度调到最低', 'Dim screen'),
    DeviceAction('brightness_high', '亮度调到最高', 'Bright screen'),
    DeviceAction('lock', '锁屏', 'Lock screen'),
    DeviceAction('screenshot', '截屏到工作区', 'Screenshot to workspace'),
    DeviceAction('notification_panel', '拉下通知栏', 'Open notification shade'),
    DeviceAction('back', '返回键', 'Back'),
    DeviceAction('home', '回到桌面', 'Home'),
    DeviceAction('recents', '最近任务', 'Recents'),
    DeviceAction('force_stop', '强制停止应用', 'Force-stop app'),
    DeviceAction('clear_recents', '清空最近任务', 'Clear recents'),
    DeviceAction('stay_awake', '充电时保持唤醒', 'Stay awake while charging'),
    DeviceAction('volume_up', '音量加一格', 'Volume up'),
    DeviceAction('volume_down', '音量减一格', 'Volume down'),
    DeviceAction('mute', '静音', 'Mute'),
    DeviceAction('media_play', '播放 / 暂停', 'Play or pause'),
    DeviceAction('media_next', '下一首', 'Next track'),
    DeviceAction('media_prev', '上一首', 'Previous track'),
    DeviceAction('dark_on', '深色模式开', 'Dark mode on'),
    DeviceAction('dark_off', '深色模式关', 'Dark mode off'),
    DeviceAction('screen_off', '直接息屏', 'Screen off'),
  ];

  /// Actions implemented by a native call rather than a shell line. They work
  /// on an unrooted phone, so no privilege flag is attached.
  static const Set<String> native = <String>{
    'volume_up',
    'volume_down',
    'mute',
  };

  static String label(String id) {
    for (final DeviceAction a in all) {
      if (a.id == id) return a.zh;
    }
    return id;
  }

  /// Actions that need root or Shizuku; the UI greys them out otherwise.
  static bool needsPrivilege(String id) {
    const Set<String> needs = <String>{
      'wifi_on',
      'wifi_off',
      'data_on',
      'data_off',
      'airplane_on',
      'airplane_off',
      'brightness_low',
      'brightness_high',
      'lock',
      'screenshot',
      'notification_panel',
      'back',
      'home',
      'recents',
      'force_stop',
      'clear_recents',
      'stay_awake',
      'media_play',
      'media_next',
      'media_prev',
      'dark_on',
      'dark_off',
      'screen_off',
    };
    return needs.contains(id);
  }

  /// Turns an action id into the shell line that implements it.
  ///
  /// `pkg` comes from the rule args and is only used by the two app actions.
  static String command(String id, {String pkg = ''}) {
    switch (id) {
      case 'wifi_on':
        return 'svc wifi enable';
      case 'wifi_off':
        return 'svc wifi disable';
      case 'data_on':
        return 'svc data enable';
      case 'data_off':
        return 'svc data disable';
      case 'airplane_on':
        return 'settings put global airplane_mode_on 1; '
            'am broadcast -a android.intent.action.AIRPLANE_MODE --ez state true';
      case 'airplane_off':
        return 'settings put global airplane_mode_on 0; '
            'am broadcast -a android.intent.action.AIRPLANE_MODE --ez state false';
      case 'dnd_on':
        return 'cmd notification set_dnd on';
      case 'dnd_off':
        return 'cmd notification set_dnd off';
      case 'brightness_low':
        return 'settings put system screen_brightness 10';
      case 'brightness_high':
        return 'settings put system screen_brightness 255';
      case 'lock':
        return 'input keyevent 26';
      case 'notification_panel':
        return 'cmd statusbar expand-notifications';
      case 'back':
        return 'input keyevent 4';
      case 'home':
        return 'input keyevent 3';
      case 'recents':
        return 'input keyevent 187';
      case 'force_stop':
        return 'am force-stop $pkg';
      case 'clear_recents':
        return 'am kill-all';
      case 'stay_awake':
        return 'svc power stayon true';
      case 'media_play':
        return 'input keyevent 85';
      case 'media_next':
        return 'input keyevent 87';
      case 'media_prev':
        return 'input keyevent 88';
      case 'dark_on':
        return 'cmd uimode night yes';
      case 'dark_off':
        return 'cmd uimode night no';
      case 'screen_off':
        return 'input keyevent 223';
      case 'volume_up':
      case 'volume_down':
      case 'mute':
        // Handled by AudioManager through the bridge, no shell needed.
        return '';
      case 'screenshot':
      default:
        return '';
    }
  }
}

/// Runs rules and keeps their history. The actual side effects are injected as
/// [AutomationRunner] so the engine stays testable and has no import cycle with
/// `AppState`.
class AutomationEngine extends ChangeNotifier {
  AutomationEngine({required this.runner});

  final Future<String> Function(AutomationRule rule, AutomationAction action)
      runner;

  /// Called after every run so the app can raise a system notification. Kept
  /// as a hook so the engine itself stays free of platform imports.
  Future<void> Function(AutomationRule rule, bool ok, String detail)?
      onFinished;

  final List<AutomationRule> rules = <AutomationRule>[];
  final List<AutomationLog> logs = <AutomationLog>[];

  /// Rules whose level condition is currently satisfied, so a battery threshold
  /// fires once instead of every tick.
  final Map<String, bool> _fired = <String, bool>{};

  Timer? _ticker;
  bool _busy = false;
  AutomationSignal _signal = const AutomationSignal();
  Future<void> _saveTimer = Future<void>.value();

  bool get busy => _busy;
  AutomationSignal get signal => _signal;

  List<AutomationRule> get enabledRules =>
      rules.where((AutomationRule r) => r.enabled).toList();

  int get todayRuns {
    final DateTime now = DateTime.now();
    int n = 0;
    for (final AutomationLog l in logs) {
      if (l.at.year == now.year &&
          l.at.month == now.month &&
          l.at.day == now.day) {
        n++;
      }
    }
    return n;
  }

  Future<void> load() async {
    final String? raw = await Store.loadAutomation();
    if (raw == null || raw.isEmpty) {
      rules
        ..clear()
        ..addAll(AutomationTemplates.starter());
      logs.clear();
      await _persist();
      return;
    }
    try {
      final Map<String, dynamic> json =
          (jsonDecode(raw) as Map).cast<String, dynamic>();
      rules
        ..clear()
        ..addAll(((json['rules'] as List<dynamic>?) ?? const <dynamic>[])
            .map((dynamic e) =>
                AutomationRule.fromJson((e as Map).cast<String, dynamic>())));
      logs
        ..clear()
        ..addAll(((json['logs'] as List<dynamic>?) ?? const <dynamic>[])
            .map((dynamic e) =>
                AutomationLog.fromJson((e as Map).cast<String, dynamic>())));
    } catch (_) {
      rules
        ..clear()
        ..addAll(AutomationTemplates.starter());
    }
    notifyListeners();
  }

  Future<void> _persist() {
    final String raw = jsonEncode(<String, dynamic>{
      'rules': rules.map((AutomationRule r) => r.toJson()).toList(),
      'logs': logs.map((AutomationLog l) => l.toJson()).toList(),
    });
    // Serialise writes: two rapid toggles must not interleave.
    _saveTimer = _saveTimer.then((_) => Store.saveAutomation(raw));
    return _saveTimer;
  }

  Future<void> save() async {
    await _persist();
    notifyListeners();
  }

  void start() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) {
      unawaited(tick());
    });
  }

  void stop() {
    _ticker?.cancel();
    _ticker = null;
  }

  void updateSignal(AutomationSignal next) {
    _signal = next;
  }

  /// Feeds a raw event from the native stream (`screen_on`, `unlock`,
  /// `wifi_connected`, `battery`, `app_foreground`, `notification`, `screen`, …).
  Future<void> onEvent(Map<String, dynamic> event) async {
    final String type = '${event['type'] ?? ''}';
    if (type.isEmpty) return;
    switch (type) {
      case 'battery':
        _signal = _signal.copyWith(
          batteryLevel: (event['level'] as num?)?.toInt(),
          charging: event['charging'] == true,
        );
        break;
      case 'power_connected':
        _signal = _signal.copyWith(charging: true);
        break;
      case 'power_disconnected':
        _signal = _signal.copyWith(charging: false);
        break;
      case 'wifi_connected':
        _signal = _signal.copyWith(wifi: true, ssid: '${event['ssid'] ?? ''}');
        break;
      case 'wifi_disconnected':
        _signal = _signal.copyWith(wifi: false, ssid: '');
        break;
      case 'screen_on':
        _signal = _signal.copyWith(screenOn: true);
        break;
      case 'screen_off':
        _signal = _signal.copyWith(screenOn: false);
        break;
      case 'app_foreground':
        _signal = _signal.copyWith(
          foreground: '${event['package'] ?? ''}',
          foregroundLabel: '${event['label'] ?? ''}',
        );
        break;
      case 'notification':
        _signal = _signal.copyWith(
          notifPackage: '${event['package'] ?? ''}',
          notifApp: '${event['app'] ?? ''}',
          notifTitle: '${event['title'] ?? ''}',
          notifText: '${event['text'] ?? ''}',
        );
        break;
      case 'screen':
        _signal = _signal.copyWith(
          screenText: '${event['text'] ?? ''}',
          foreground: '${event['package'] ?? _signal.foreground}',
          foregroundLabel: '${event['app'] ?? _signal.foregroundLabel}',
        );
        break;
      case 'notification_listener':
      case 'a11y_connected':
      case 'a11y_disconnected':
        notifyListeners();
        return;
    }
    await _fireEvent(type);
    notifyListeners();
  }

  /// True when [rule] should run for [signal] at [now] — the whole matching
  /// policy lives here so a unit test can pin it down.
  bool shouldFire(AutomationRule rule, AutomationSignal signal, DateTime now) {
    if (!rule.enabled) return false;
    final AutomationTrigger t = rule.trigger;
    switch (t.kind) {
      case 'interval':
        final int minutes = (t.args['minutes'] as num?)?.toInt() ?? 30;
        if (minutes <= 0) return false;
        final DateTime? last = rule.lastRun;
        if (last == null) return true;
        return now.difference(last).inMinutes >= minutes;
      case 'daily':
        final int hour = (t.args['hour'] as num?)?.toInt() ?? 9;
        final int minute = (t.args['minute'] as num?)?.toInt() ?? 0;
        if (now.hour != hour || now.minute != minute) return false;
        final List<dynamic> days =
            (t.args['weekdays'] as List<dynamic>?) ?? const <dynamic>[];
        if (days.isNotEmpty &&
            !days.any((dynamic d) => (d as num).toInt() == now.weekday)) {
          return false;
        }
        final DateTime? last = rule.lastRun;
        return last == null ||
            last.year != now.year ||
            last.month != now.month ||
            last.day != now.day ||
            last.hour != now.hour ||
            last.minute != now.minute;
      case 'battery_below':
        final int level = (t.args['level'] as num?)?.toInt() ?? 20;
        return signal.batteryLevel >= 0 && signal.batteryLevel <= level;
      case 'battery_above':
        final int level = (t.args['level'] as num?)?.toInt() ?? 80;
        return signal.batteryLevel >= 0 && signal.batteryLevel >= level;
      case 'charging':
        return signal.charging;
      case 'unplugged':
        return !signal.charging;
      case 'wifi_on':
        if (!signal.wifi) return false;
        final String ssid = '${t.args['ssid'] ?? ''}';
        if (ssid.isEmpty) return true;
        return signal.ssid.toLowerCase().contains(ssid.toLowerCase());
      case 'wifi_off':
        return !signal.wifi;
      case 'screen_on':
        return signal.screenOn;
      case 'battery_full':
        return signal.charging && signal.batteryLevel >= 99;
      case 'idle':
        final int minutes = (t.args['minutes'] as num?)?.toInt() ?? 30;
        if (signal.screenOn) return false;
        if (minutes <= 0) return false;
        final DateTime? idleLast = rule.lastRun;
        return idleLast == null || now.difference(idleLast).inMinutes >= minutes;
      case 'app_foreground':
        final String pkg = '${t.args['package'] ?? ''}'.toLowerCase();
        final String label = '${t.args['label'] ?? ''}'.toLowerCase();
        final String fg = signal.foreground.toLowerCase();
        final String fgLabel = signal.foregroundLabel.toLowerCase();
        if (fg.isEmpty && fgLabel.isEmpty) return false;
        if (pkg.isEmpty && label.isEmpty) {
          // "any app" would otherwise fire on every transition; two minutes
          // between runs is a sensible floor.
          final DateTime? anyLast = rule.lastRun;
          return anyLast == null || now.difference(anyLast).inMinutes >= 2;
        }
        final bool packageHit = pkg.isNotEmpty && fg.contains(pkg);
        final bool labelHit =
            label.isNotEmpty && (fgLabel.contains(label) || fg.contains(label));
        if (!packageHit && !labelHit) return false;
        final DateTime? appLast = rule.lastRun;
        return appLast == null || now.difference(appLast).inSeconds >= 45;
      case 'notification':
        if (signal.notifApp.isEmpty && signal.notifPackage.isEmpty) return false;
        final String app = '${t.args['app'] ?? ''}'.toLowerCase();
        if (app.isNotEmpty) {
          final String hay =
              '${signal.notifApp} ${signal.notifPackage}'.toLowerCase();
          if (!hay.contains(app)) return false;
        }
        final String key = '${t.args['keyword'] ?? ''}'.toLowerCase();
        if (key.isNotEmpty) {
          final String body =
              '${signal.notifTitle} ${signal.notifText}'.toLowerCase();
          if (!body.contains(key)) return false;
        }
        return true;
      case 'screen_text':
        final String needle = '${t.args['text'] ?? ''}'.toLowerCase();
        if (needle.isEmpty) return signal.screenText.isNotEmpty;
        if (!signal.screenText.toLowerCase().contains(needle)) return false;
        final DateTime? textLast = rule.lastRun;
        return textLast == null || now.difference(textLast).inSeconds >= 30;
      default:
        return false;
    }
  }

  bool _armed(AutomationRule rule) => _fired[rule.id] != true;

  /// Clock and level triggers are evaluated on a timer; events are evaluated
  /// directly. Keeping them apart avoids a battery rule firing on every tick.
  Future<void> tick({DateTime? at}) async {
    final DateTime now = at ?? DateTime.now();
    for (final AutomationRule rule in enabledRules) {
      final String kind = rule.trigger.kind;
      if (kind == 'manual' || kind == 'boot' || _isEventKind(kind)) continue;
      if (!shouldFire(rule, _signal, now)) {
        _fired.remove(rule.id);
        continue;
      }
      // Clock rules carry their own "already ran" check in shouldFire (minute
      // and date based), so the level hysteresis must not apply to them.
      if (rule.trigger.isClock) {
        await run(rule, auto: true, at: now);
        continue;
      }
      if (!_armed(rule)) continue;
      _fired[rule.id] = true;
      await run(rule, auto: true, at: now);
    }
  }

  static bool _isEventKind(String kind) {
    const Set<String> events = <String>{
      'screen_on',
      'unlock',
      'wifi_on',
      'wifi_off',
      'charging',
      'unplugged',
      'app_foreground',
      'notification',
      'screen_text',
    };
    return events.contains(kind);
  }

  Future<void> _fireEvent(String type) async {
    for (final AutomationRule rule in enabledRules) {
      final String kind = rule.trigger.kind;
      if (!_isEventKind(kind)) continue;
      final bool match = (kind == 'unlock' && type == 'unlock') ||
          (kind == 'screen_on' && type == 'screen_on') ||
          (kind == 'wifi_on' && type == 'wifi_connected') ||
          (kind == 'wifi_off' && type == 'wifi_disconnected') ||
          (kind == 'charging' && type == 'power_connected') ||
          (kind == 'unplugged' && type == 'power_disconnected') ||
          (kind == 'app_foreground' && type == 'app_foreground') ||
          (kind == 'notification' && type == 'notification') ||
          (kind == 'screen_text' && type == 'screen');
      if (!match) {
        _fired.remove(rule.id);
        continue;
      }
      if (!shouldFire(rule, _signal, DateTime.now())) continue;
      if (!_armed(rule)) continue;
      _fired[rule.id] = true;
      await run(rule, auto: true);
    }
  }

  /// Runs a rule's actions in order. Returns the last message, and records a
  /// log line either way.
  Future<String> run(
    AutomationRule rule, {
    bool auto = false,
    DateTime? at,
  }) async {
    final DateTime stamp = at ?? DateTime.now();
    if (_busy) return '已有自动化正在执行';
    _busy = true;
    notifyListeners();
    final StringBuffer detail = StringBuffer();
    bool ok = true;
    try {
      if (rule.actions.isEmpty) {
        detail.write('没有配置动作');
      }
      for (final AutomationAction action in rule.actions) {
        final String result = await runner(rule, action);
        detail.writeln('${action.summary} → $result');
        if (result.startsWith('ERROR')) {
          ok = false;
          break;
        }
      }
    } catch (e) {
      ok = false;
      detail.writeln('异常：$e');
    } finally {
      _busy = false;
    }
    final String text = detail.toString().trim();
    rule
      ..lastRunMs = stamp.millisecondsSinceEpoch
      ..runCount = rule.runCount + 1
      ..lastResult = text.length > 600 ? text.substring(0, 600) : text;
    logs.insert(
      0,
      AutomationLog(
        ruleName: rule.name,
        at: stamp,
        ok: ok,
        detail: rule.lastResult,
      ),
    );
    while (logs.length > 60) {
      logs.removeLast();
    }
    await _persist();
    notifyListeners();
    if (onFinished != null) {
      try {
        await onFinished!(rule, ok, text);
      } catch (_) {}
    }
    return text.isEmpty ? (ok ? '完成' : '失败') : text;
  }

  void add(AutomationRule rule) {
    rules.insert(0, rule);
    unawaited(save());
  }

  void replace(AutomationRule rule) {
    final int i = rules.indexWhere((AutomationRule r) => r.id == rule.id);
    if (i >= 0) {
      rules[i] = rule;
    } else {
      rules.insert(0, rule);
    }
    unawaited(save());
  }

  void remove(String id) {
    rules.removeWhere((AutomationRule r) => r.id == id);
    _fired.remove(id);
    unawaited(save());
  }

  void toggle(String id, bool value) {
    for (final AutomationRule r in rules) {
      if (r.id == id) r.enabled = value;
    }
    unawaited(save());
  }

  void clearLogs() {
    logs.clear();
    unawaited(save());
  }
}

/// Ready-made rules. They are written into the list on first launch so the page
/// is not empty on a fresh install, and can be added again from the template
/// sheet after being deleted.
class AutomationTemplates {
  static List<AutomationRule> starter() => <AutomationRule>[
        _nightly(),
        _lowBattery(),
      ];

  static AutomationRule _nightly() => AutomationRule(
        id: 'builtin-nightly',
        name: '每晚收工汇总',
        trigger: const AutomationTrigger('daily', <String, dynamic>{
          'hour': 22,
          'minute': 30,
          'weekdays': <int>[],
        }),
        actions: <AutomationAction>[
          const AutomationAction('agent', <String, dynamic>{
            'prompt': '看一下工作区今天改了什么（git status / git diff --stat），'
                '用三句话总结，并列出明天要接着做的事。',
          }),
        ],
      );

  static AutomationRule _lowBattery() => AutomationRule(
        id: 'builtin-battery',
        name: '低电量提醒',
        trigger: const AutomationTrigger('battery_below', <String, dynamic>{
          'level': 20,
        }),
        actions: <AutomationAction>[
          const AutomationAction('device', <String, dynamic>{
            'action': 'brightness_low',
          }),
          const AutomationAction('notify', <String, dynamic>{
            'title': '电量低于 20%',
            'body': '已调低亮度。要现在把没跑完的任务停掉吗？',
          }),
        ],
        notify: false,
      );

  /// Shown in the "add" sheet. Each entry is a factory so ids and timestamps
  /// stay unique.
  static List<AutomationRule> market() => <AutomationRule>[
        _nightly(),
        _lowBattery(),
        AutomationRule(
          id: 'tpl-wifi-home',
          name: '到家自动拉代码',
          trigger: const AutomationTrigger('wifi_on', <String, dynamic>{
            'ssid': 'Home',
          }),
          actions: <AutomationAction>[
            const AutomationAction('shell', <String, dynamic>{
              'command': 'git pull --ff-only',
              'mode': 'builtin',
            }),
            const AutomationAction('notify', <String, dynamic>{
              'title': '代码已更新',
              'body': '工作区执行了 git pull。',
            }),
          ],
        ),
        AutomationRule(
          id: 'tpl-morning',
          name: '早间构建检查',
          trigger: const AutomationTrigger('daily', <String, dynamic>{
            'hour': 8,
            'minute': 30,
            'weekdays': <int>[1, 2, 3, 4, 5],
          }),
          actions: <AutomationAction>[
            const AutomationAction('agent', <String, dynamic>{
              'prompt': '跑一次项目的检查和测试（优先看 README 或 package.json 里定义的命令），'
                  '把结果整理成三条以内的结论。',
              'title': '早间检查',
            }),
          ],
        ),
        AutomationRule(
          id: 'tpl-unlock-brief',
          name: '解锁时看一眼待办',
          trigger: const AutomationTrigger('unlock'),
          actions: <AutomationAction>[
            const AutomationAction('notify', <String, dynamic>{
              'title': '待办',
              'body': '打开 ZCode 看看今天剩下的任务。',
            }),
          ],
          notify: false,
        ),
        AutomationRule(
          id: 'tpl-charge-clean',
          name: '睡前插电自动清理',
          trigger: const AutomationTrigger('charging'),
          actions: <AutomationAction>[
            const AutomationAction('device', <String, dynamic>{
              'action': 'clear_recents',
            }),
            const AutomationAction('notify', <String, dynamic>{
              'title': '已清理后台',
              'body': '充电中，顺手清掉了最近任务。',
            }),
          ],
          notify: false,
        ),
        AutomationRule(
          id: 'tpl-notify-boss',
          name: '重要消息立刻提醒',
          trigger: const AutomationTrigger('notification', <String, dynamic>{
            'app': '',
            'keyword': '',
          }),
          actions: <AutomationAction>[
            const AutomationAction('vibrate', <String, dynamic>{'ms': 260}),
            const AutomationAction('notify', <String, dynamic>{
              'title': '{app} 来消息了',
              'body': '{title}：{text}',
            }),
          ],
          notify: false,
        ),
        AutomationRule(
          id: 'tpl-code-copy',
          name: '验证码自动进剪贴板',
          trigger: const AutomationTrigger('notification', <String, dynamic>{
            'app': '',
            'keyword': '验证码',
          }),
          actions: <AutomationAction>[
            const AutomationAction('clipboard', <String, dynamic>{
              'text': '{text}',
            }),
            const AutomationAction('notify', <String, dynamic>{
              'title': '验证码已复制',
              'body': '{text}',
            }),
          ],
          notify: false,
        ),
        AutomationRule(
          id: 'tpl-wechat-checkin',
          name: '微信自动打卡（按文字点）',
          trigger: const AutomationTrigger('app_foreground', <String, dynamic>{
            'package': 'com.tencent.mm',
            'label': '微信',
          }),
          actions: <AutomationAction>[
            const AutomationAction('delay', <String, dynamic>{'seconds': 3}),
            const AutomationAction('a11y', <String, dynamic>{
              'op': 'click',
              'text': '打卡',
            }),
            const AutomationAction('notify', <String, dynamic>{
              'title': '打卡',
              'body': '在微信里找到了「打卡」并点了一下。',
            }),
          ],
          notify: false,
        ),
        AutomationRule(
          id: 'tpl-build-done',
          name: '构建成功就播报',
          trigger: const AutomationTrigger('screen_text', <String, dynamic>{
            'text': '构建成功',
          }),
          actions: <AutomationAction>[
            const AutomationAction('speak', <String, dynamic>{
              'text': '构建完成了',
            }),
            const AutomationAction('vibrate', <String, dynamic>{'ms': 180}),
          ],
          notify: false,
        ),
        AutomationRule(
          id: 'tpl-idle-notes',
          name: '息屏半小时整理笔记',
          trigger: const AutomationTrigger('idle', <String, dynamic>{
            'minutes': 30,
          }),
          actions: <AutomationAction>[
            const AutomationAction('agent', <String, dynamic>{
              'prompt': '看一眼工作区里今天改动过的文件，把值得记的三条写进 '
                  'notes/daily.md（没有就新建），最后回一句结论。',
            }),
          ],
          notify: false,
        ),
        AutomationRule(
          id: 'tpl-full-unplug',
          name: '充满提醒拔电',
          trigger: const AutomationTrigger('battery_full'),
          actions: <AutomationAction>[
            const AutomationAction('vibrate', <String, dynamic>{'ms': 400}),
            const AutomationAction('notify', <String, dynamic>{
              'title': '电池已充满',
              'body': '拔掉充电器，别一直插着。',
            }),
          ],
          notify: false,
        ),
        AutomationRule(
          id: 'tpl-open-app-dnd',
          name: '打开专注应用时静音',
          trigger: const AutomationTrigger('app_foreground', <String, dynamic>{
            'package': '',
            'label': '',
          }),
          actions: <AutomationAction>[
            const AutomationAction('device', <String, dynamic>{'action': 'mute'}),
            const AutomationAction('notify', <String, dynamic>{
              'title': '已静音',
              'body': '打开了 {app}，顺手把媒体音量关掉了。',
            }),
          ],
          notify: false,
        ),
      ];
}

/// Turns one sentence into a rule.
///
/// The point is "less tapping", so the parser is deliberately local and
/// forgiving: it looks for a trigger phrase, then for the actions the sentence
/// implies. Everything it produces opens in the normal editor, so a wrong guess
/// costs one correction rather than a failed automation.
class AutomationDraft {
  static AutomationRule parse(String raw) {
    final String text = raw.trim();
    final AutomationTrigger trigger = triggerOf(text);
    return AutomationRule(
      id: 'r${DateTime.now().microsecondsSinceEpoch}',
      name: nameOf(text),
      trigger: trigger,
      actions: actionsOf(text, trigger),
      notify: false,
    );
  }

  static String nameOf(String text) {
    final String clean = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (clean.isEmpty) return '自定义规则';
    return clean.length > 18 ? '${clean.substring(0, 18)}…' : clean;
  }

  static AutomationTrigger triggerOf(String text) {
    final String t = text;
    // Every N minutes / hours first: "每 30 分钟" also contains 每.
    final RegExpMatch? everyMin =
        RegExp(r'每\s*(\d+)\s*分钟', caseSensitive: false).firstMatch(t);
    if (everyMin != null) {
      return AutomationTrigger('interval', <String, dynamic>{
        'minutes': int.tryParse(everyMin.group(1) ?? '') ?? 30,
      });
    }
    final RegExpMatch? everyHour =
        RegExp(r'每\s*(\d+)\s*(?:个)?小时', caseSensitive: false).firstMatch(t);
    if (everyHour != null) {
      return AutomationTrigger('interval', <String, dynamic>{
        'minutes': (int.tryParse(everyHour.group(1) ?? '') ?? 1) * 60,
      });
    }
    final RegExpMatch? clock = RegExp(
      r'每(天|日|早|晚|周[一二三四五六日天])?\s*(\d{1,2})\s*[:：点时]\s*(\d{1,2})?',
      caseSensitive: false,
    ).firstMatch(t);
    if (clock != null) {
      final String head = (clock.group(1) ?? '').trim();
      List<int> days = <int>[];
      if (head.contains('工作日')) {
        days = <int>[1, 2, 3, 4, 5];
      } else if (head.contains('周末')) {
        days = <int>[6, 7];
      }
      return AutomationTrigger('daily', <String, dynamic>{
        'hour': int.tryParse(clock.group(2) ?? '') ?? 9,
        'minute': int.tryParse(clock.group(3) ?? '') ?? 0,
        'weekdays': days,
      });
    }
    if (RegExp(r'工作日\s*(\d{1,2})\s*[:：点时]').hasMatch(t)) {
      final RegExpMatch m =
          RegExp(r'工作日\s*(\d{1,2})\s*[:：点时]\s*(\d{1,2})?').firstMatch(t)!;
      return AutomationTrigger('daily', <String, dynamic>{
        'hour': int.tryParse(m.group(1) ?? '') ?? 9,
        'minute': int.tryParse(m.group(2) ?? '') ?? 0,
        'weekdays': <int>[1, 2, 3, 4, 5],
      });
    }

    final RegExpMatch? low =
        RegExp(r'电量\s*(?:低于|少于|小于|不足)\s*(\d{1,3})').firstMatch(t);
    if (low != null) {
      return AutomationTrigger('battery_below', <String, dynamic>{
        'level': int.tryParse(low.group(1) ?? '') ?? 20,
      });
    }
    final RegExpMatch? high =
        RegExp(r'电量\s*(?:高于|超过|大于)\s*(\d{1,3})').firstMatch(t);
    if (high != null) {
      return AutomationTrigger('battery_above', <String, dynamic>{
        'level': int.tryParse(high.group(1) ?? '') ?? 80,
      });
    }
    if (RegExp(r'充满|满电|充电完成|充到 100').hasMatch(t)) {
      return const AutomationTrigger('battery_full');
    }
    if (RegExp(r'(拔掉|断开)\s*(电源|充电器|充电)').hasMatch(t)) {
      return const AutomationTrigger('unplugged');
    }
    if (RegExp(r'(插上|接上|连上)\s*(电源|充电器|充电)').hasMatch(t)) {
      return const AutomationTrigger('charging');
    }

    final RegExpMatch? wifi = RegExp(
      r'(?:连上|连接|接入)\s*(?:家里的\s*)?(?:wifi|wi-fi|无线网|无线|网络)\s*[「"\x27]?([^」"\x27\s，。]{1,24})?',
      caseSensitive: false,
    ).firstMatch(t);
    if (wifi != null) {
      return AutomationTrigger('wifi_on', <String, dynamic>{
        'ssid': _cleanSsid(wifi.group(1) ?? ''),
      });
    }
    if (RegExp(r'(断开|掉线|离开)\s*(wifi|wi-fi|无线|网络)', caseSensitive: false)
        .hasMatch(t)) {
      return const AutomationTrigger('wifi_off');
    }

    final RegExpMatch? idle =
        RegExp(r'(?:息屏|锁屏|黑屏|灭屏)\s*(\d+)\s*分钟').firstMatch(t);
    if (idle != null) {
      return AutomationTrigger('idle', <String, dynamic>{
        'minutes': int.tryParse(idle.group(1) ?? '') ?? 30,
      });
    }

    final RegExpMatch? screenText = RegExp(
      r'屏幕(?:上)?(?:出现|显示)\s*[「"\x27]?([^」"\x27\n]{1,24})[」"\x27]?',
    ).firstMatch(t);
    if (screenText != null) {
      return AutomationTrigger('screen_text', <String, dynamic>{
        'text': (screenText.group(1) ?? '').trim(),
      });
    }

    final RegExpMatch? notif = RegExp(
      r'(?:收到|来|接到)\s*([^\s，。的]{1,12}?)\s*(?:的)?\s*(?:消息|通知|推送)',
    ).firstMatch(t);
    if (notif != null) {
      String app = (notif.group(1) ?? '').trim();
      final RegExpMatch? key = RegExp(
        r'(?:含有?|带上?|包含)\s*[「"\x27]?([^」"\x27\s，。]{1,16})',
      ).firstMatch(t);
      String keyword = (key?.group(1) ?? '').trim();
      // "收到验证码通知" is about the content, not the sender.
      if (_keywordish(app)) {
        if (keyword.isEmpty) keyword = app;
        app = '';
      }
      return AutomationTrigger('notification', <String, dynamic>{
        'app': app,
        'keyword': keyword,
      });
    }

    final RegExpMatch? app = RegExp(
      r'打开\s*([^\s，。]{1,16}?)\s*(?:的)?\s*(?:时|后|的时候)',
    ).firstMatch(t);
    if (app != null) {
      return AutomationTrigger('app_foreground', <String, dynamic>{
        'package': '',
        'label': (app.group(1) ?? '').trim(),
      });
    }

    if (RegExp(r'解锁').hasMatch(t)) return const AutomationTrigger('unlock');
    if (RegExp(r'开机').hasMatch(t)) return const AutomationTrigger('boot');
    if (RegExp(r'点亮屏幕|亮屏').hasMatch(t)) {
      return const AutomationTrigger('screen_on');
    }
    return const AutomationTrigger('manual');
  }

  static List<AutomationAction> actionsOf(
    String text,
    AutomationTrigger trigger,
  ) {
    final List<AutomationAction> out = <AutomationAction>[];
    final String lower = text.toLowerCase();
    bool has(String s) => lower.contains(s.toLowerCase());

    if (has('git pull') || has('拉代码') || has('更新代码')) {
      out.add(const AutomationAction('shell', <String, dynamic>{
        'command': 'git pull --ff-only',
        'mode': 'builtin',
      }));
    }
    if (has('截屏') || has('截图')) {
      out.add(const AutomationAction('device', <String, dynamic>{
        'action': 'screenshot',
      }));
    }
    if (has('调暗') || has('最低亮度') || has('降低亮度')) {
      out.add(const AutomationAction('device', <String, dynamic>{
        'action': 'brightness_low',
      }));
    }
    if (has('静音')) {
      out.add(const AutomationAction('device', <String, dynamic>{
        'action': 'mute',
      }));
    }
    if (has('勿扰')) {
      out.add(const AutomationAction('device', <String, dynamic>{
        'action': 'dnd_on',
      }));
    }
    if (has('打卡')) {
      out.add(const AutomationAction('a11y', <String, dynamic>{
        'op': 'click',
        'text': '打卡',
      }));
    }
    if (has('复制') || has('剪贴板')) {
      out.add(const AutomationAction('clipboard', <String, dynamic>{
        'text': '{text}',
      }));
    }
    final bool wantsSpeech =
        has('朗读') || has('念一下') || has('播报') || has('读出来');
    if (wantsSpeech) {
      out.add(AutomationAction('speak', <String, dynamic>{
        'text': _spoken(text),
      }));
    }
    final bool wantsAgent = !wantsSpeech &&
        (has('总结') ||
            has('整理') ||
            has('检查') ||
            has('构建') ||
            has('测试') ||
            has('写') ||
            has('跑一遍') ||
            has('跑一次') ||
            has('分析'));
    if (wantsAgent) {
      out.add(AutomationAction('agent', <String, dynamic>{'prompt': text}));
    }
    final bool wantsNotify =
        has('通知') || has('提醒') || has('告诉我') || has('告我');
    final bool copies = has('复制') || has('剪贴板');
    if (wantsNotify && !wantsAgent && !copies) {
      out.add(AutomationAction('notify', <String, dynamic>{
        'title': nameOf(text),
        'body': text,
      }));
    }
    if (out.isEmpty) {
      out.add(AutomationAction('notify', <String, dynamic>{
        'title': nameOf(text),
        'body': text,
      }));
    }
    return out;
  }

  /// Strips instruction words so "连上 Wi-Fi 就 git pull" does not turn into an
  /// SSID called "就".
  static String _cleanSsid(String raw) {
    String out = raw.trim();
    const List<String> stop = <String>[
      '就',
      '时',
      '后',
      '然后',
      '再',
      '并',
      '自动',
      '以后',
    ];
    for (final String word in stop) {
      if (out == word) return '';
      if (out.startsWith(word)) {
        out = out.substring(word.length).trim();
      }
    }
    return out;
  }

  static bool _keywordish(String token) {
    if (token.isEmpty) return false;
    const List<String> words = <String>[
      '验证码',
      '短信',
      '快递',
      '外卖',
      '消息',
      '通知',
      '推送',
      '转账',
      '账单',
      '日程',
      '会议',
      '提醒',
      '日程',
      '告警',
      '报警',
      '失败',
    ];
    for (final String w in words) {
      if (token.contains(w)) return true;
    }
    return false;
  }

  /// Strips the instruction words so a spoken sentence does not read like a
  /// prompt ("朗读一下：构建完成" → "构建完成").
  static String _spoken(String text) {
    String out = text;
    for (final String lead in <String>[
      '朗读一下',
      '朗读',
      '念一下',
      '念',
      '播报一下',
      '播报',
      '读出来',
    ]) {
      out = out.replaceAll(lead, '');
    }
    out = out.replaceAll(RegExp(r'^[:：，,\s]+'), '').trim();
    return out.isEmpty ? text : out;
  }
}
