import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A mount point the user can pick a workspace from.
class StorageVolume {
  const StorageVolume({
    required this.path,
    required this.label,
    this.removable = false,
    this.free = 0,
  });

  final String path;
  final String label;
  final bool removable;

  /// Bytes available, 0 when unknown (web / desktop).
  final int free;
}

/// Facts about the device that change what the agent is allowed to do.
class DeviceInfo {
  const DeviceInfo({
    this.platform = 'unknown',
    this.sdk = 0,
    this.model = '',
    this.abis = const <String>[],
    this.appData = '',
    this.home = '',
    this.storageAccess = false,
    this.termux = false,
  });

  final String platform;
  final int sdk;
  final String model;
  final List<String> abis;
  final String appData;

  /// Public shared-storage root (`/storage/emulated/0` on a phone).
  final String home;
  final bool storageAccess;
  final bool termux;

  bool get isAndroid => platform == 'android';
}

/// Thin wrapper over the `ai.zcode/device` channel. Every call degrades
/// gracefully: on web, on tests and on desktop the app simply reports "no
/// native storage" and keeps using its private directory.
class DeviceBridge {
  static const MethodChannel _channel = MethodChannel('ai.zcode/device');
  static DeviceInfo _info = const DeviceInfo();
  static bool _probed = false;
  static bool _handler = false;
  static Map<String, dynamic>? _pending;

  /// Called when a launcher shortcut or a share-sheet item arrives.
  static void Function(Map<String, dynamic>)? onIntent;

  /// Installs the inbound channel once. The native side also caches the launch
  /// intent, because it can arrive before `AppState.init` finishes.
  static void init() {
    if (!isAndroid || _handler) return;
    _handler = true;
    _channel.setMethodCallHandler((MethodCall call) async {
      if (call.method != 'intent') return null;
      final Object? args = call.arguments;
      if (args is Map) {
        final Map<String, dynamic> map = <String, dynamic>{
          for (final Object? key in args.keys) '\$key': args[key],
        };
        _pending = map;
        onIntent?.call(map);
      }
      return null;
    });
  }

  /// Removes and returns an intent that arrived before a listener existed.
  static Map<String, dynamic>? takePendingIntent() {
    final Map<String, dynamic>? p = _pending;
    _pending = null;
    return p;
  }

  static bool get isAndroid {
    if (kIsWeb) return false;
    try {
      return Platform.isAndroid;
    } catch (_) {
      return false;
    }
  }

  static DeviceInfo get info => _info;

  /// Cached so the UI can paint without awaiting; [refresh] re-reads it.
  static Future<DeviceInfo> refresh() async {
    if (!isAndroid) {
      _probed = true;
      return _info;
    }
    try {
      final Map<Object?, Object?>? raw =
          await _channel.invokeMethod<Map<Object?, Object?>>('info');
      if (raw != null) {
        _info = DeviceInfo(
          platform: '${raw['platform'] ?? 'android'}',
          sdk: (raw['sdk'] as int?) ?? 0,
          model: '${raw['model'] ?? ''}',
          abis: '${raw['abis'] ?? ''}'
              .split(',')
              .where((String s) => s.isNotEmpty)
              .toList(),
          appData: '${raw['appData'] ?? ''}',
          home: '${raw['home'] ?? ''}',
          storageAccess: raw['storageAccess'] == true,
          termux: raw['termux'] == true,
        );
      }
    } catch (_) {
      // No plugin (web preview / unit test): keep the neutral defaults.
    }
    _probed = true;
    return _info;
  }

  static bool get probed => _probed;

  static Future<bool> hasStorageAccess() async {
    if (!isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('hasStorageAccess') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Opens the system screen that grants All-files access. Always returns
  /// immediately; call [hasStorageAccess] again after the app resumes.
  static Future<bool> requestStorageAccess() async {
    if (!isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('requestStorageAccess') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<List<StorageVolume>> volumes() async {
    if (!isAndroid) return const <StorageVolume>[];
    try {
      final List<Object?>? raw =
          await _channel.invokeListMethod<Object?>('volumes');
      if (raw == null) return const <StorageVolume>[];
      final List<StorageVolume> out = <StorageVolume>[];
      for (final Object? item in raw) {
        if (item is Map) {
          out.add(StorageVolume(
            path: '${item['path'] ?? ''}',
            label: '${item['label'] ?? ''}',
            removable: item['removable'] == true,
            free: (item['free'] as int?) ?? 0,
          ));
        }
      }
      return out;
    } catch (_) {
      return const <StorageVolume>[];
    }
  }

  static Future<int> freeSpace(String path) async {
    try {
      return await _channel.invokeMethod<int>('freeSpace', <String, dynamic>{
            'path': path,
          }) ??
          0;
    } catch (_) {
      return 0;
    }
  }

  /// Opens a file or folder with whatever app handles it.
  static Future<bool> openPath(String path) async {
    if (!isAndroid || path.isEmpty) return false;
    try {
      return await _channel.invokeMethod<bool>('openPath', <String, dynamic>{
            'path': path,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> termuxInstalled() async {
    if (!isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('termuxInstalled') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Fires the command at Termux's RUN_COMMAND service. Returns false when
  /// Termux is missing or refuses the intent (allow-external-apps off).
  static Future<bool> termuxRun({
    required String command,
    required String cwd,
    required String outFile,
    required String exitFile,
  }) async {
    if (!isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('termuxRun', <String, dynamic>{
            'command': command,
            'cwd': cwd,
            'outFile': outFile,
            'exitFile': exitFile,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// `12.4 MB` / `1.2 GB`, for storage rows.
  static String prettySize(int bytes) {
    if (bytes <= 0) return '—';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
  }
}
