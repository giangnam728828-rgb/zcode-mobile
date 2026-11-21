import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What the accessibility bridge can currently do.
class A11yStatus {
  const A11yStatus({
    this.enabled = false,
    this.connected = false,
    this.notificationListener = false,
    this.foreground = '',
    this.foregroundLabel = '',
  });

  /// The user switched the service on in Settings.
  final bool enabled;

  /// The service is actually running and can answer queries.
  final bool connected;
  final bool notificationListener;

  /// Package and label of the app that was last in front.
  final String foreground;
  final String foregroundLabel;

  bool get usable => connected;
  bool get any => enabled || notificationListener;

  String get label {
    if (connected) return '已连接';
    if (enabled) return '已开启，等待系统拉起';
    return '未开启';
  }
}

/// One node of the screen tree, flattened for the model and for the UI.
class A11yNode {
  A11yNode({
    required this.text,
    required this.desc,
    required this.cls,
    required this.clickable,
    required this.editable,
    required this.bounds,
  });

  final String text;
  final String desc;
  final String cls;
  final bool clickable;
  final bool editable;

  /// `left,top,right,bottom` in screen pixels.
  final String bounds;

  String get label => text.isNotEmpty ? text : desc;

  String get short => cls.split('.').last;
}

/// A point-in-time picture of the active window.
class A11ySnapshot {
  A11ySnapshot({
    required this.connected,
    required this.package,
    required this.app,
    required this.text,
    required this.nodes,
  });

  const A11ySnapshot.empty()
      : connected = false,
        package = '',
        app = '',
        text = '',
        nodes = const <A11yNode>[];

  final bool connected;
  final String package;
  final String app;
  final String text;
  final List<A11yNode> nodes;

  bool get isEmpty => text.trim().isEmpty && nodes.isEmpty;
}

/// Thin wrapper over the accessibility side of `ai.zcode/privilege`.
///
/// Every call degrades to a no-op off Android so the web preview and unit tests
/// can use the same code path.
class A11yBridge {
  static const MethodChannel _channel = MethodChannel('ai.zcode/privilege');

  static bool get isAndroid {
    if (kIsWeb) return false;
    try {
      return Platform.isAndroid;
    } catch (_) {
      return false;
    }
  }

  static A11yStatus _status = const A11yStatus();

  static A11yStatus get status => _status;

  static void debugSetStatus(A11yStatus next) {
    _status = next;
  }

  static Future<A11yStatus> refresh() async {
    if (!isAndroid) return _status;
    try {
      final Map<Object?, Object?>? raw =
          await _channel.invokeMethod<Map<Object?, Object?>>('a11yStatus');
      if (raw != null) {
        _status = A11yStatus(
          enabled: raw['enabled'] == true,
          connected: raw['connected'] == true,
          notificationListener: raw['notificationListener'] == true,
          foreground: '${raw['foreground'] ?? ''}',
          foregroundLabel: '${raw['foregroundLabel'] ?? ''}',
        );
      }
    } catch (_) {}
    return _status;
  }

  /// Opens Settings → Accessibility, or the notification-access list.
  static Future<bool> openSettings({bool notifications = false}) async {
    if (!isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('a11yEnable', <String, dynamic>{
            'notifications': notifications,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Reads the active window. [limit] caps the number of labelled nodes.
  static Future<A11ySnapshot> snapshot({int limit = 60}) async {
    if (!isAndroid) return const A11ySnapshot.empty();
    try {
      final Map<Object?, Object?>? raw = await _channel
          .invokeMethod<Map<Object?, Object?>>('a11ySnapshot', <String, dynamic>{
        'limit': limit,
      });
      if (raw == null) return const A11ySnapshot.empty();
      final List<A11yNode> nodes = <A11yNode>[];
      final Object? list = raw['nodes'];
      if (list is List) {
        for (final Object? item in list) {
          if (item is! Map) continue;
          nodes.add(A11yNode(
            text: '${item['text'] ?? ''}',
            desc: '${item['desc'] ?? ''}',
            cls: '${item['class'] ?? ''}',
            clickable: item['clickable'] == true,
            editable: item['editable'] == true,
            bounds: '${item['bounds'] ?? ''}',
          ));
        }
      }
      return A11ySnapshot(
        connected: raw['connected'] == true,
        package: '${raw['package'] ?? ''}',
        app: '${raw['app'] ?? ''}',
        text: '${raw['text'] ?? ''}',
        nodes: nodes,
      );
    } catch (_) {
      return const A11ySnapshot.empty();
    }
  }

  /// Taps the node whose text (or content description) matches.
  static Future<bool> click(
    String text, {
    int index = 0,
    bool byDesc = false,
    bool longPress = false,
  }) async {
    if (!isAndroid || text.isEmpty) return false;
    try {
      return await _channel.invokeMethod<bool>('a11yClick', <String, dynamic>{
            'text': text,
            'index': index,
            'desc': byDesc,
            'long': longPress,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> setText(String text, {String target = ''}) async {
    if (!isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('a11ySetText', <String, dynamic>{
            'text': text,
            'target': target,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> scroll({bool forward = true, int times = 1}) async {
    if (!isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('a11yScroll', <String, dynamic>{
            'forward': forward,
            'times': times,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// `back`, `home`, `recents`, `notifications`, `quick_settings`, `power`,
  /// `lock`, `screenshot`.
  static Future<bool> global(String action) async {
    if (!isAndroid || action.isEmpty) return false;
    try {
      return await _channel.invokeMethod<bool>('a11yGlobal', <String, dynamic>{
            'action': action,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> tap(int x, int y) async {
    if (!isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('a11yTap', <String, dynamic>{
            'x': x,
            'y': y,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> swipe(
    int x1,
    int y1,
    int x2,
    int y2, {
    int millis = 300,
  }) async {
    if (!isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('a11ySwipe', <String, dynamic>{
            'x': x1,
            'y': y1,
            'x2': x2,
            'y2': y2,
            'ms': millis,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Text to speech, no service required.
  static Future<bool> speak(String text) async {
    if (!isAndroid || text.isEmpty) return false;
    try {
      return await _channel.invokeMethod<bool>('speak', <String, dynamic>{
            'text': text,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// A compact, model-friendly rendering of the screen.
  static Future<String> describe({int limit = 40}) async {
    final A11ySnapshot snap = await snapshot(limit: limit);
    if (!snap.connected) return '无障碍服务没有连接（去 设置 → 无障碍 打开 ZCode 屏幕助手）';
    if (snap.isEmpty) return '当前窗口没有可读文字（${snap.package}）';
    final StringBuffer out = StringBuffer();
    out.writeln('app: ${snap.app.isEmpty ? snap.package : snap.app}');
    out.writeln('---');
    for (final A11yNode n in snap.nodes.take(limit)) {
      final String tag = n.clickable ? ' [可点]' : (n.editable ? ' [可输入]' : '');
      out.writeln('${n.label}$tag');
    }
    return out.toString().trim();
  }
}
