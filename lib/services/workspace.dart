import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../platform/device_bridge.dart';

/// Decides where the agent's files live.
///
/// On a phone the goal is that the folder the user picks in the system picker
/// is *the* folder the agent edits — visible in any file manager, mountable by
/// Termux, syncable by a cloud app. That needs All-files access and a plain
/// directory path, so everything downstream stays `dart:io`.
class WorkspaceResolver {
  /// Default folder created on shared storage the first time the app runs.
  static const String appFolder = 'ZCode';

  /// Last-resort location when shared storage is unavailable (web, desktop,
  /// or a phone that refused the permission).
  static Future<String> fallback() async {
    final Directory base = await getApplicationSupportDirectory();
    return '${base.path}/workspace';
  }

  /// v3.1 and earlier kept everything under the app's private support dir.
  /// Upgrading users should not think their files vanished, so that folder is
  /// still honoured while it holds real content.
  static Future<String?> legacyWorkspace() async {
    try {
      final Directory base = await getApplicationSupportDirectory();
      final Directory old = Directory('${base.path}/workspace');
      if (!await old.exists()) return null;
      final List<FileSystemEntity> items = await old.list().toList();
      for (final FileSystemEntity e in items) {
        final String name = e.path.split('/').last;
        if (name == '.zcode' || name == '.tmp' || name == 'README.md') continue;
        return old.path;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Best guess for a first run: `Internal storage/ZCode`, else the sandbox.
  static Future<String> suggest() async {
    if (DeviceBridge.isAndroid) {
      final String home = DeviceBridge.info.home;
      if (home.isNotEmpty && await ensureWritable('$home/$appFolder')) {
        return '$home/$appFolder';
      }
    }
    final String f = await fallback();
    await ensureWritable(f);
    return f;
  }

  /// True when the path sits on shared storage, i.e. Termux and other apps can
  /// reach the same files.
  static bool isShared(String path) =>
      path.startsWith('/storage/') || path.startsWith('/sdcard');

  static Future<bool> isWritable(String path) async {
    try {
      final Directory dir = Directory(path);
      if (!await dir.exists()) return false;
      final File probe = File('${dir.path}/.zcode/write-test');
      await probe.parent.create(recursive: true);
      await probe.writeAsString('ok', flush: true);
      await probe.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Creates the folder (recursively) and proves it accepts writes.
  static Future<bool> ensureWritable(String path) async {
    try {
      final Directory dir = Directory(path);
      if (!await dir.exists()) await dir.create(recursive: true);
      return await isWritable(path);
    } catch (_) {
      return false;
    }
  }

  /// Empty string when the folder is usable, otherwise a message for the UI.
  static Future<String> validate(String path) async {
    final String p = path.trim();
    if (p.isEmpty) return '路径不能为空';
    if (!p.startsWith('/')) return '请使用绝对路径，例如 /storage/emulated/0/ZCode';
    try {
      final Directory dir = Directory(p);
      final bool exists = await dir.exists();
      if (!exists) {
        await dir.create(recursive: true);
      }
      if (!await isWritable(p)) {
        return '这个文件夹不可写，换一个目录，或先授予「所有文件访问权限」';
      }
      return '';
    } catch (e) {
      return '无法使用该目录：$e';
    }
  }

  /// Collapses `.` / `..` in a POSIX path without touching the file system.
  static String normalize(String path) {
    final List<String> out = <String>[];
    for (final String part in path.split('/')) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        if (out.isNotEmpty) out.removeLast();
        continue;
      }
      out.add(part);
    }
    return '/${out.join('/')}';
  }

  /// `/storage/emulated/0/Projects/app` → `内部存储/Projects/app`.
  static String label(String path) {
    const String primary = '/storage/emulated/0';
    if (path == primary) return '内部存储';
    if (path.startsWith('$primary/')) {
      return '内部存储/${path.substring(primary.length + 1)}';
    }
    if (path.startsWith('/storage/')) {
      final List<String> parts = path.substring('/storage/'.length).split('/');
      if (parts.isNotEmpty && parts.first.length >= 4) {
        parts[0] = '存储卡 ${parts.first}';
        return parts.join('/');
      }
    }
    return path;
  }

  /// Files the app owns inside the workspace. Kept in one place so a new
  /// workspace gets the same skeleton the agent expects.
  static Future<void> bootstrap(String path) async {
    final Directory root = Directory(path);
    for (final String sub in <String>[
      '.zcode/bin',
      '.zcode/skills',
      '.zcode/commands',
      '.zcode/agents',
      '.zcode/modules',
      '.zcode/backups',
      '.tmp',
    ]) {
      try {
        await Directory('${root.path}/$sub').create(recursive: true);
      } catch (_) {}
    }
    final File readme = File('${root.path}/README.md');
    try {
      if (!await readme.exists()) {
        await readme.writeAsString(
          '# 工作区\n\n'
          '这是 ZCode 在手机上的工作区，里面的文件就是手机里的真实文件：\n'
          '文件管理器能看到，Termux 能直接 cd 进来，其他 App 也能读写。\n\n'
          '- `.zcode/bin` 放你自己的脚本，终端里可直接按名字调用\n'
          '- `.zcode/skills`、`.zcode/commands`、`.zcode/agents` 放插件扩展\n'
          '- 把项目文件夹选为工作区即可让智能体直接改代码\n',
        );
      }
    } catch (_) {}
  }
}
