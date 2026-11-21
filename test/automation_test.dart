import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zcode_mobile/services/automation.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  AutomationRule rule(
    AutomationTrigger trigger, {
    List<AutomationAction>? actions,
    bool enabled = true,
  }) {
    return AutomationRule(
      id: 'r-${trigger.kind}',
      name: trigger.kind,
      enabled: enabled,
      trigger: trigger,
      actions: actions ??
          <AutomationAction>[
            const AutomationAction('notify', <String, dynamic>{'title': 't'}),
          ],
    );
  }

  group('clock triggers', () {
    test('interval fires on first tick, then waits for the window', () async {
      final AutomationEngine engine =
          AutomationEngine(runner: (AutomationRule r, AutomationAction a) async {
        return 'ok';
      });
      final AutomationRule r = rule(
          const AutomationTrigger('interval', <String, dynamic>{'minutes': 30}));
      engine.rules.add(r);
      engine.updateSignal(const AutomationSignal());

      await engine.tick(at: DateTime(2026, 5, 1, 9, 0));
      expect(r.runCount, 1);

      await engine.tick(at: DateTime(2026, 5, 1, 9, 20));
      expect(r.runCount, 1, reason: 'still inside the 30 minute window');

      await engine.tick(at: DateTime(2026, 5, 1, 9, 31));
      expect(r.runCount, 2);
    });

    test('daily fires once per day at the configured minute', () async {
      final AutomationEngine engine =
          AutomationEngine(runner: (AutomationRule r, AutomationAction a) async {
        return 'ok';
      });
      final AutomationRule r = rule(const AutomationTrigger('daily',
          <String, dynamic>{'hour': 8, 'minute': 30, 'weekdays': <int>[]}));
      engine.rules.add(r);

      await engine.tick(at: DateTime(2026, 5, 4, 8, 29));
      expect(r.runCount, 0);

      await engine.tick(at: DateTime(2026, 5, 4, 8, 30));
      expect(r.runCount, 1);

      await engine.tick(at: DateTime(2026, 5, 4, 8, 30));
      expect(r.runCount, 1, reason: 'same minute must not double fire');

      await engine.tick(at: DateTime(2026, 5, 5, 8, 30));
      expect(r.runCount, 2);
    });

    test('weekday filter keeps weekends quiet', () async {
      final AutomationEngine engine =
          AutomationEngine(runner: (AutomationRule r, AutomationAction a) async {
        return 'ok';
      });
      final AutomationRule r = rule(const AutomationTrigger('daily',
          <String, dynamic>{
            'hour': 7,
            'minute': 0,
            'weekdays': <int>[1, 2, 3, 4, 5],
          }));
      engine.rules.add(r);

      // 2026-05-09 is a Saturday.
      await engine.tick(at: DateTime(2026, 5, 9, 7, 0));
      expect(r.runCount, 0);
      // 2026-05-11 is a Monday.
      await engine.tick(at: DateTime(2026, 5, 11, 7, 0));
      expect(r.runCount, 1);
    });
  });

  group('level triggers', () {
    test('battery_below arms once and re-arms after recovery', () async {
      final AutomationEngine engine =
          AutomationEngine(runner: (AutomationRule r, AutomationAction a) async {
        return 'ok';
      });
      final AutomationRule r = rule(const AutomationTrigger(
          'battery_below', <String, dynamic>{'level': 20}));
      engine.rules.add(r);

      engine.updateSignal(const AutomationSignal(batteryLevel: 19));
      await engine.tick(at: DateTime(2026, 5, 1, 10, 0));
      expect(r.runCount, 1);

      engine.updateSignal(const AutomationSignal(batteryLevel: 18));
      await engine.tick(at: DateTime(2026, 5, 1, 10, 1));
      expect(r.runCount, 1, reason: 'still low, must not spam');

      engine.updateSignal(const AutomationSignal(batteryLevel: 40));
      await engine.tick(at: DateTime(2026, 5, 1, 10, 2));
      expect(r.runCount, 1);

      engine.updateSignal(const AutomationSignal(batteryLevel: 15));
      await engine.tick(at: DateTime(2026, 5, 1, 10, 3));
      expect(r.runCount, 2, reason: 'a new drop is a new event');
    });

    test('wifi_on matches the ssid fragment case-insensitively', () {
      final AutomationEngine engine =
          AutomationEngine(runner: (AutomationRule r, AutomationAction a) async {
        return '';
      });
      final AutomationRule r = rule(const AutomationTrigger(
          'wifi_on', <String, dynamic>{'ssid': 'home'}));
      final DateTime now = DateTime(2026, 5, 1, 12, 0);

      expect(
        engine.shouldFire(
          r,
          const AutomationSignal(wifi: true, ssid: 'Home-5G'),
          now,
        ),
        isTrue,
      );
      expect(
        engine.shouldFire(
          r,
          const AutomationSignal(wifi: true, ssid: 'Office'),
          now,
        ),
        isFalse,
      );
      expect(
        engine.shouldFire(
          r,
          const AutomationSignal(wifi: false, ssid: 'Home'),
          now,
        ),
        isFalse,
      );
    });

    test('events fire only the matching rule', () async {
      final AutomationEngine engine =
          AutomationEngine(runner: (AutomationRule r, AutomationAction a) async {
        return 'ok';
      });
      final AutomationRule onCharge = rule(const AutomationTrigger('charging'));
      final AutomationRule onWifi = rule(const AutomationTrigger('wifi_off'));
      engine.rules.addAll(<AutomationRule>[onCharge, onWifi]);
      engine.updateSignal(const AutomationSignal(charging: false, wifi: true));

      await engine.onEvent(<String, dynamic>{'type': 'power_connected'});
      expect(onCharge.runCount, 1);
      expect(onWifi.runCount, 0);

      await engine.onEvent(<String, dynamic>{'type': 'wifi_disconnected'});
      expect(onWifi.runCount, 1);
    });
  });

  group('execution', () {
    test('actions run in order and stop on the first error', () async {
      final List<String> seen = <String>[];
      final AutomationEngine engine =
          AutomationEngine(runner: (AutomationRule r, AutomationAction a) async {
        seen.add(a.kind);
        if (a.kind == 'shell') return 'ERROR boom';
        return 'ok';
      });
      final AutomationRule r = rule(
        const AutomationTrigger('manual'),
        actions: <AutomationAction>[
          const AutomationAction('notify'),
          const AutomationAction('shell'),
          const AutomationAction('webhook'),
        ],
      );

      final String result = await engine.run(r);
      expect(seen, <String>['notify', 'shell']);
      expect(result, contains('ERROR'));
      expect(engine.logs.length, 1);
      expect(engine.logs.first.ok, isFalse);
      expect(r.runCount, 1);
    });

    test('a disabled rule never fires', () async {
      final AutomationEngine engine =
          AutomationEngine(runner: (AutomationRule r, AutomationAction a) async {
        return 'ok';
      });
      final AutomationRule r = rule(
        const AutomationTrigger('interval', <String, dynamic>{'minutes': 1}),
        enabled: false,
      );
      engine.rules.add(r);
      await engine.tick(at: DateTime(2026, 5, 1, 10, 0));
      expect(r.runCount, 0);
    });
  });

  group('serialisation', () {
    test('rule survives a JSON round trip', () {
      final AutomationRule r = AutomationRule(
        id: 'abc',
        name: '到家拉代码',
        trigger: const AutomationTrigger(
            'wifi_on', <String, dynamic>{'ssid': 'Home'}),
        actions: <AutomationAction>[
          const AutomationAction('shell', <String, dynamic>{
            'command': 'git pull',
            'mode': 'builtin',
          }),
        ],
        notify: false,
      );
      final AutomationRule back = AutomationRule.fromJson(r.toJson());
      expect(back.id, 'abc');
      expect(back.name, '到家拉代码');
      expect(back.trigger.kind, 'wifi_on');
      expect(back.trigger.args['ssid'], 'Home');
      expect(back.actions.single.kind, 'shell');
      expect(back.actions.single.args['command'], 'git pull');
      expect(back.notify, isFalse);
    });

    test('templates are usable as shipped', () {
      final List<AutomationRule> starter = AutomationTemplates.starter();
      expect(starter, isNotEmpty);
      for (final AutomationRule r in starter) {
        expect(r.actions, isNotEmpty);
        expect(r.trigger.kind, isNotEmpty);
      }
      final List<AutomationRule> market = AutomationTemplates.market();
      expect(market.length, greaterThanOrEqualTo(4));
    });
  });

  group('device actions', () {
    test('privileged actions map to a shell line, and are flagged as such', () {
      expect(DeviceAction.needsPrivilege('wifi_on'), isTrue);
      expect(DeviceAction.needsPrivilege('dnd_on'), isFalse);
      expect(DeviceAction.command('wifi_on'), 'svc wifi enable');
      expect(DeviceAction.command('force_stop', pkg: 'com.a'),
          'am force-stop com.a');
      expect(DeviceAction.command('screenshot'), isEmpty);
    });

    test('labels fall back to the id', () {
      expect(DeviceAction.label('wifi_on'), isNotEmpty);
      expect(DeviceAction.label('nope'), 'nope');
    });
  });

  group('phone events', () {
    test('notification matches app and keyword', () async {
      final AutomationEngine engine =
          AutomationEngine(runner: (AutomationRule r, AutomationAction a) async {
        return 'ok';
      });
      final AutomationRule r = rule(const AutomationTrigger(
        'notification',
        <String, dynamic>{'app': '微信', 'keyword': '验证码'},
      ));
      engine.rules.add(r);

      await engine.onEvent(<String, dynamic>{
        'type': 'notification',
        'package': 'com.tencent.mm',
        'app': '微信',
        'title': '登录提醒',
        'text': '你的验证码是 123456',
      });
      expect(r.runCount, 1);

      await engine.onEvent(<String, dynamic>{
        'type': 'notification',
        'package': 'com.tencent.mm',
        'app': '微信',
        'title': '广告',
        'text': '来看看',
      });
      expect(r.runCount, 1, reason: 'keyword missing');
    });

    test('app_foreground matches the label', () async {
      final AutomationEngine engine =
          AutomationEngine(runner: (AutomationRule r, AutomationAction a) async {
        return 'ok';
      });
      final AutomationRule r = rule(const AutomationTrigger(
        'app_foreground',
        <String, dynamic>{'package': '', 'label': '微信'},
      ));
      engine.rules.add(r);

      await engine.onEvent(<String, dynamic>{
        'type': 'app_foreground',
        'package': 'com.tencent.mm',
        'label': '微信',
      });
      expect(r.runCount, 1);

      await engine.onEvent(<String, dynamic>{
        'type': 'app_foreground',
        'package': 'com.android.chrome',
        'label': 'Chrome',
      });
      expect(r.runCount, 1);
    });

    test('screen_text sees the snapshot', () async {
      final AutomationEngine engine =
          AutomationEngine(runner: (AutomationRule r, AutomationAction a) async {
        return 'ok';
      });
      final AutomationRule r = rule(const AutomationTrigger(
        'screen_text', <String, dynamic>{'text': '构建成功'}));
      engine.rules.add(r);

      await engine.onEvent(<String, dynamic>{
        'type': 'screen',
        'package': 'com.termux',
        'text': '编译中…\n构建成功',
      });
      expect(r.runCount, 1);

      await engine.onEvent(<String, dynamic>{
        'type': 'screen',
        'package': 'com.termux',
        'text': '编译中…',
      });
      expect(r.runCount, 1);
    });

    test('battery_full only fires while charging at the top', () async {
      final AutomationEngine engine =
          AutomationEngine(runner: (AutomationRule r, AutomationAction a) async {
        return 'ok';
      });
      final AutomationRule r = rule(const AutomationTrigger('battery_full'));
      engine.rules.add(r);

      engine.updateSignal(
          const AutomationSignal(batteryLevel: 100, charging: false));
      await engine.tick(at: DateTime(2026, 5, 1, 9, 0));
      expect(r.runCount, 0);

      engine.updateSignal(
          const AutomationSignal(batteryLevel: 100, charging: true));
      await engine.tick(at: DateTime(2026, 5, 1, 9, 1));
      expect(r.runCount, 1);
    });

    test('idle waits for the configured gap while the screen is off', () async {
      final AutomationEngine engine =
          AutomationEngine(runner: (AutomationRule r, AutomationAction a) async {
        return 'ok';
      });
      final AutomationRule r = rule(
          const AutomationTrigger('idle', <String, dynamic>{'minutes': 30}));
      engine.rules.add(r);
      engine.updateSignal(const AutomationSignal(screenOn: false));

      await engine.tick(at: DateTime(2026, 5, 1, 23, 0));
      expect(r.runCount, 1);
      await engine.tick(at: DateTime(2026, 5, 1, 23, 10));
      expect(r.runCount, 1);
      await engine.tick(at: DateTime(2026, 5, 1, 23, 31));
      expect(r.runCount, 2);
    });
  });

  group('one sentence rules', () {
    test('wifi + git pull + notify', () {
      final AutomationRule r =
          AutomationDraft.parse('到家连上 Wi-Fi 就 git pull，然后通知我');
      expect(r.trigger.kind, 'wifi_on');
      expect(r.trigger.args['ssid'], '');
      expect(r.actions.any((AutomationAction a) => a.kind == 'shell'), isTrue);
      expect(r.actions.any((AutomationAction a) => a.kind == 'notify'), isTrue);
    });

    test('battery threshold dims the screen', () {
      final AutomationRule r =
          AutomationDraft.parse('电量低于 20% 调暗屏幕并提醒我');
      expect(r.trigger.kind, 'battery_below');
      expect(r.trigger.args['level'], 20);
      expect(
        r.actions.any((AutomationAction a) =>
            a.kind == 'device' && a.args['action'] == 'brightness_low'),
        isTrue,
      );
    });

    test('verification code notification is copied, not treated as an app', () {
      final AutomationRule r = AutomationDraft.parse('收到验证码通知就复制到剪贴板');
      expect(r.trigger.kind, 'notification');
      expect(r.trigger.args['app'], '');
      expect(r.trigger.args['keyword'], '验证码');
      expect(r.actions.single.kind, 'clipboard');
      expect(r.actions.single.args['text'], '{text}');
    });

    test('screen text speaks', () {
      final AutomationRule r = AutomationDraft.parse('屏幕出现「构建成功」就朗读一下');
      expect(r.trigger.kind, 'screen_text');
      expect(r.trigger.args['text'], '构建成功');
      expect(r.actions.single.kind, 'speak');
    });

    test('idle runs the agent', () {
      final AutomationRule r = AutomationDraft.parse('息屏 30 分钟后整理笔记');
      expect(r.trigger.kind, 'idle');
      expect(r.trigger.args['minutes'], 30);
      expect(r.actions.single.kind, 'agent');
    });

    test('opening an app taps a label', () {
      final AutomationRule r = AutomationDraft.parse('打开微信时按文字点「打卡」');
      expect(r.trigger.kind, 'app_foreground');
      expect(r.trigger.args['label'], '微信');
      final AutomationAction a = r.actions
          .firstWhere((AutomationAction a) => a.kind == 'a11y');
      expect(a.args['op'], 'click');
      expect(a.args['text'], '打卡');
    });

    test('a plain sentence still becomes a rule', () {
      final AutomationRule r = AutomationDraft.parse('明天记得看一下日志');
      expect(r.trigger.kind, 'manual');
      expect(r.actions, isNotEmpty);
    });
  });

  group('new device actions', () {
    test('volume is native, dark mode is a shell line', () {
      expect(DeviceAction.needsPrivilege('volume_up'), isFalse);
      expect(DeviceAction.needsPrivilege('mute'), isFalse);
      expect(DeviceAction.command('volume_up'), isEmpty);
      expect(DeviceAction.needsPrivilege('dark_on'), isTrue);
      expect(DeviceAction.command('dark_on'), 'cmd uimode night yes');
    });

    test('accessibility actions are labelled and know what they need', () {
      expect(A11yAction.label('click'), isNotEmpty);
      expect(A11yAction.needsText('click'), isTrue);
      expect(A11yAction.needsValue('click'), isFalse);
      expect(A11yAction.needsValue('input'), isTrue);
      expect(A11yAction.needsText('back'), isFalse);
    });
  });

}
