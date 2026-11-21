import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Which doorway a privileged command went through.
class PrivStatus {
  const PrivStatus({
    this.root = false,
    this.shizuku = false,
    this.shizukuGranted = false,
    this.channel = 'none',
    this.notifications = false,
    this.writeSettings = false,
    this.dndAccess = false,
    this.powerSave = false,
    this.accessibility = false,
    this.a11yConnected = false,
    this.notificationListener = false,
  });

  final bool root;

  /// Shizuku is installed and its binder is alive.
  final bool shizuku;

  /// The user has granted this app the Shizuku API permission.
  final bool shizukuGranted;
  final String channel;
  final bool notifications;
  final bool writeSettings;
  final bool dndAccess;
  final bool powerSave;

  /// Accessibility service switched on / actually running, and whether the
  /// notification listener is connected. These are the root-free superpowers.
  final bool accessibility;
  final bool a11yConnected;
  final bool notificationListener;

  bool get privileged => channel == 'root' || channel == 'shizuku';

  /// Anything that lets a rule see or touch other apps.
  bool get canSeeScreen => a11yConnected;

  bool get rich => privileged || a11yConnected || notificationListener;

  String get label {
    switch (channel) {
      case 'root':
        return 'root';
      case 'shizuku':
        return 'Shizuku';
      default:
        return '普通权限';
    }
  }

  /// What automatically becomes possible once a channel is open.
  String get unlocked {
    if (channel == 'root' || channel == 'shizuku') {
      return a11yConnected
          ? '系统开关、截屏、模拟点击，加上读屏与按文字点按'
          : '系统开关、截屏、模拟点击、强制停止、改系统设置';
    }
    if (a11yConnected) return '读屏、按文字点按、输入、返回桌面、通知触发';
    return '通知、剪贴板、震动、打开应用、音量、电池';
  }
}

class PrivResult {
  const PrivResult({
    this.channel = 'none',
    this.exit = 1,
    this.stdout = '',
    this.stderr = '',
  });

  final String channel;
  final int exit;
  final String stdout;
  final String stderr;

  bool get ok => exit == 0;

  String get text {
    final StringBuffer b = StringBuffer();
    if (stdout.trim().isNotEmpty) b.write(stdout.trim());
    if (stderr.trim().isNotEmpty) {
      if (b.isNotEmpty) b.write('\n');
      b.write('[stderr]\n${stderr.trim()}');
    }
    if (b.isEmpty) b.write('(no output)');
    b.write('\n\n[\$channel · exit \$exit]');
    return b.toString();
  }
}

/// Wrapper over the `ai.zcode/privilege` channel plus the device event stream.
///
/// Everything degrades to a no-op off Android, so the web preview and the unit
/// tests exercise the same call sites without a plugin.
class PrivilegeBridge {
  static const MethodChannel _channel = MethodChannel('ai.zcode/privilege');
  static const EventChannel _events = EventChannel('ai.zcode/device_events');

  static PrivStatus _status = const PrivStatus();
  static bool _probed = false;
  static StreamSubscription<dynamic>? _sub;

  static bool get isAndroid {
    if (kIsWeb) return false;
    try {
      return Platform.isAndroid;
    } catch (_) {
      return false;
    }
  }

  static PrivStatus get status => _status;
  static bool get probed => _probed;

  /// Preview hook: pretend a channel is open without a device. Only the
  /// developer entrypoint calls this; the real status always comes from the
  /// platform channel.
  static void debugSetStatus(PrivStatus status) {
    _status = status;
    _probed = true;
  }

  static Future<PrivStatus> refresh() async {
    if (!isAndroid) {
      _probed = true;
      return _status;
    }
    try {
      final Map<Object?, Object?>? raw =
          await _channel.invokeMethod<Map<Object?, Object?>>('capabilities');
      if (raw != null) {
        _status = PrivStatus(
          root: raw['root'] == true,
          shizuku: raw['shizuku'] == true,
          shizukuGranted: raw['shizukuGranted'] == true,
          channel: '${raw['channel'] ?? 'none'}',
          notifications: raw['notifications'] == true,
          writeSettings: raw['writeSettings'] == true,
          dndAccess: raw['dndAccess'] == true,
          powerSave: raw['powerSave'] == true,
          accessibility: raw['accessibility'] == true,
          a11yConnected: raw['a11yConnected'] == true,
          notificationListener: raw['notificationListener'] == true,
        );
      }
    } catch (_) {}
    _probed = true;
    return _status;
  }

  /// Runs `sh -c` through root or Shizuku. `mode=auto` prefers root.
  static Future<PrivResult> run(
    String command, {
    String mode = 'auto',
    int timeout = 30,
  }) async {
    if (!isAndroid || command.trim().isEmpty) {
      return const PrivResult(stderr: '提权通道只在 Android 上可用');
    }
    try {
      final Map<Object?, Object?>? raw =
          await _channel.invokeMethod<Map<Object?, Object?>>('run', <String, dynamic>{
        'command': command,
        'mode': mode,
        'timeout': timeout,
      });
      if (raw == null) return const PrivResult(stderr: 'no result');
      return PrivResult(
        channel: '${raw['channel'] ?? mode}',
        exit: (raw['exit'] as int?) ?? 1,
        stdout: '${raw['stdout'] ?? ''}',
        stderr: '${raw['stderr'] ?? ''}',
      );
    } catch (e) {
      return PrivResult(stderr: '$e');
    }
  }

  static Future<bool> requestShizuku() async {
    if (!isAndroid) return false;
    try {
      final bool ok =
          await _channel.invokeMethod<bool>('requestShizuku') ?? false;
      return ok;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> openShizuku() async {
    if (!isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('openShizuku') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> notify(
    String title,
    String body, {
    int id = 1,
  }) async {
    if (!isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('notify', <String, dynamic>{
            'id': id,
            'title': title,
            'body': body,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> requestNotifications() async {
    if (!isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('requestNotifications') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<String> clipboardGet() async {
    if (!isAndroid) return '';
    try {
      return await _channel.invokeMethod<String>('clipboardGet') ?? '';
    } catch (_) {
      return '';
    }
  }

  static Future<bool> clipboardSet(String text) async {
    if (!isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('clipboardSet', <String, dynamic>{
            'text': text,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> vibrate([int ms = 120]) async {
    if (!isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('vibrate', <String, dynamic>{
            'ms': ms,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> openApp(String target) async {
    if (!isAndroid || target.isEmpty) return false;
    try {
      return await _channel.invokeMethod<bool>('openApp', <String, dynamic>{
            'target': target,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Future<List<Map<String, String>>> apps({String query = ''}) async {
    if (!isAndroid) return const <Map<String, String>>[];
    try {
      final List<Object?>? raw = await _channel
          .invokeListMethod<Object?>('apps', <String, dynamic>{'query': query});
      if (raw == null) return const <Map<String, String>>[];
      final List<Map<String, String>> out = <Map<String, String>>[];
      for (final Object? item in raw) {
        if (item is Map) {
          out.add(<String, String>{
            'package': '${item['package'] ?? ''}',
            'label': '${item['label'] ?? ''}',
            'system': '${item['system'] == true}',
          });
        }
      }
      return out;
    } catch (_) {
      return const <Map<String, String>>[];
    }
  }

  static Future<Map<String, dynamic>> battery() async {
    if (!isAndroid) return <String, dynamic>{};
    try {
      final Map<Object?, Object?>? raw =
          await _channel.invokeMethod<Map<Object?, Object?>>('battery');
      if (raw == null) return <String, dynamic>{};
      return <String, dynamic>{
        'level': raw['level'] ?? -1,
        'charging': raw['charging'] == true,
        'temperature': raw['temperature'] ?? 0,
        'voltage': raw['voltage'] ?? 0,
        'screenOn': raw['screenOn'] == true,
        'powerSave': raw['powerSave'] == true,
      };
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  static Future<Map<String, dynamic>> volume(
    String stream, {
    int delta = 0,
  }) async {
    if (!isAndroid) return <String, dynamic>{};
    try {
      final Map<Object?, Object?>? raw = await _channel
          .invokeMethod<Map<Object?, Object?>>('volume', <String, dynamic>{
        'stream': stream,
        'delta': delta,
      });
      if (raw == null) return <String, dynamic>{};
      return <String, dynamic>{
        'stream': '${raw['stream'] ?? stream}',
        'level': raw['level'] ?? 0,
        'max': raw['max'] ?? 0,
      };
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  /// Opens the system screen for a special access: `notifications`,
  /// `write_settings`, `dnd`, `battery`, `usage`.
  static Future<bool> openSpecial(String kind) async {
    if (!isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('openSpecial', <String, dynamic>{
            'kind': kind,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Screen on/off, unlock, charger, battery and Wi-Fi transitions.
  static Stream<Map<String, dynamic>> events() {
    if (!isAndroid) return const Stream<Map<String, dynamic>>.empty();
    return _events.receiveBroadcastStream().map((dynamic raw) {
      if (raw is Map) {
        return <String, dynamic>{
          for (final Object? key in raw.keys)
            '$key': raw[key],
        };
      }
      return <String, dynamic>{};
    });
  }

  static void listen(void Function(Map<String, dynamic>) onEvent) {
    _sub?.cancel();
    try {
      _sub = events().listen(onEvent, onError: (Object _) {});
    } catch (_) {}
  }

  static void stopListening() {
    _sub?.cancel();
    _sub = null;
  }
}
