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
  bool get isClock => kind == 'interval' || kind == 'daily';

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
  });

  final int batteryLevel;
  final bool charging;
  final bool wifi;
  final String ssid;
  final bool screenOn;
  final bool booted;
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
  ];

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
  /// `wifi_connected`, `battery`, `power_connected`, …).
  Future<void> onEvent(Map<String, dynamic> event) async {
    final String type = '${event['type'] ?? ''}';
    if (type.isEmpty) return;
    switch (type) {
      case 'battery':
        _signal = AutomationSignal(
          batteryLevel: (event['level'] as num?)?.toInt() ?? _signal.batteryLevel,
          charging: event['charging'] == true,
          wifi: _signal.wifi,
          ssid: _signal.ssid,
          screenOn: _signal.screenOn,
          booted: _signal.booted,
        );
        break;
      case 'power_connected':
        _signal = AutomationSignal(
          batteryLevel: _signal.batteryLevel,
          charging: true,
          wifi: _signal.wifi,
          ssid: _signal.ssid,
          screenOn: _signal.screenOn,
          booted: _signal.booted,
        );
        break;
      case 'power_disconnected':
        _signal = AutomationSignal(
          batteryLevel: _signal.batteryLevel,
          charging: false,
          wifi: _signal.wifi,
          ssid: _signal.ssid,
          screenOn: _signal.screenOn,
          booted: _signal.booted,
        );
        break;
      case 'wifi_connected':
        _signal = AutomationSignal(
          batteryLevel: _signal.batteryLevel,
          charging: _signal.charging,
          wifi: true,
          ssid: '${event['ssid'] ?? ''}',
          screenOn: _signal.screenOn,
          booted: _signal.booted,
        );
        break;
      case 'wifi_disconnected':
        _signal = AutomationSignal(
          batteryLevel: _signal.batteryLevel,
          charging: _signal.charging,
          wifi: false,
          ssid: '',
          screenOn: _signal.screenOn,
          booted: _signal.booted,
        );
        break;
      case 'screen_on':
        _signal = AutomationSignal(
          batteryLevel: _signal.batteryLevel,
          charging: _signal.charging,
          wifi: _signal.wifi,
          ssid: _signal.ssid,
          screenOn: true,
          booted: _signal.booted,
        );
        break;
      case 'screen_off':
        _signal = AutomationSignal(
          batteryLevel: _signal.batteryLevel,
          charging: _signal.charging,
          wifi: _signal.wifi,
          ssid: _signal.ssid,
          screenOn: false,
          booted: _signal.booted,
        );
        break;
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
          (kind == 'unplugged' && type == 'power_disconnected');
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
      ];
}
