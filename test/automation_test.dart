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
}
