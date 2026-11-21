import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../platform/device_bridge.dart';
import '../services/workspace.dart';
import '../state/app_state.dart';

/// Picks a folder on the phone itself.
///
/// This deliberately browses with `dart:io` instead of SAF: the chosen path is
/// what every other part of the app (and the shell, and Termux) uses, so the
/// user's files stay ordinary files.
class WorkspacePickerPage extends StatefulWidget {
  const WorkspacePickerPage({Key? key, this.initialPath}) : super(key: key);

  /// Folder to open first; defaults to the current workspace.
  final String? initialPath;

  @override
  State<WorkspacePickerPage> createState() => _WorkspacePickerPageState();
}

class _WorkspacePickerPageState extends State<WorkspacePickerPage>
    with WidgetsBindingObserver {
  String _path = '';
  List<Directory> _dirs = <Directory>[];
  List<StorageVolume> _volumes = <StorageVolume>[];
  bool _loading = true;
  bool _applying = false;
  bool _hasAccess = false;
  bool _showHidden = false;
  int _free = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _path = widget.initialPath ?? '';
    _boot();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back from the All-files access screen: re-check and reload.
    if (state == AppLifecycleState.resumed) _boot(keepPath: true);
  }

  Future<void> _boot({bool keepPath = false}) async {
    if (kIsWeb) {
      setState(() {
        _loading = false;
        _error = '浏览器预览没有真实文件系统，请在手机上使用。';
      });
      return;
    }
    final AppState app = context.read<AppState>();
    _hasAccess = await DeviceBridge.hasStorageAccess();
    _volumes = await DeviceBridge.volumes();
    String start = keepPath ? _path : (widget.initialPath ?? app.workspacePath);
    if (start.isEmpty) {
      start = DeviceBridge.info.home.isNotEmpty
          ? DeviceBridge.info.home
          : (await WorkspaceResolver.fallback());
    }
    if (!await Directory(start).exists()) {
      start = DeviceBridge.info.home.isNotEmpty
          ? DeviceBridge.info.home
          : (await WorkspaceResolver.fallback());
    }
    _path = start;
    await _load();
    if (_hasAccess) await app.refreshDeviceState();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final Directory dir = Directory(_path);
      final List<FileSystemEntity> entries =
          await dir.list(followLinks: false).toList();
      final List<Directory> dirs = <Directory>[];
      for (final FileSystemEntity e in entries) {
        final String name = e.path.split('/').last;
        if (!_showHidden && name.startsWith('.')) continue;
        if (e is Directory) {
          dirs.add(e);
        } else {
          try {
            if (FileSystemEntity.isDirectorySync(e.path)) {
              dirs.add(Directory(e.path));
            }
          } catch (_) {}
        }
      }
      dirs.sort((Directory a, Directory b) => a.path
          .split('/')
          .last
          .toLowerCase()
          .compareTo(b.path.split('/').last.toLowerCase()));
      final int free = await DeviceBridge.freeSpace(_path);
      if (!mounted) return;
      setState(() {
        _dirs = dirs;
        _free = free;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _dirs = <Directory>[];
        _error = _hasAccess
            ? '打不开这个目录：$e'
            : '还没有「所有文件访问权限」，只能看到应用自己的目录。';
        _loading = false;
      });
    }
  }

  Future<void> _enter(String path) async {
    _path = path;
    await _load();
  }

  Future<void> _up() async {
    if (_path == '/' || _path.isEmpty) return;
    final String parent = File(_path).parent.path;
    await _enter(parent);
  }

  Future<void> _grant() async {
    await DeviceBridge.requestStorageAccess();
    // The permission screen sits on top; resumed triggers _boot().
  }

  Future<void> _newFolder() async {
    final String? name = await _prompt('新建文件夹', '文件夹名');
    if (name == null || name.trim().isEmpty) return;
    try {
      await Directory('$_path/${name.trim()}').create(recursive: true);
      await _load();
    } catch (e) {
      _toast('创建失败：$e');
    }
  }

  Future<void> _manualPath() async {
    final String? typed = await _prompt('直接输入路径', '/storage/emulated/0/ZCode',
        initial: _path);
    if (typed == null || typed.trim().isEmpty) return;
    final String p = typed.trim();
    if (!await Directory(p).exists()) {
      _toast('目录不存在');
      return;
    }
    await _enter(p);
  }

  Future<String?> _prompt(String title, String hint, {String? initial}) {
    final TextEditingController ctrl =
        TextEditingController(text: initial ?? '');
    return showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(title, style: const TextStyle(fontSize: 16)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(fontSize: 14),
          decoration: InputDecoration(hintText: hint),
          onSubmitted: (String v) => Navigator.pop(ctx, v),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  Future<void> _use() async {
    if (_applying) return;
    final AppState app = context.read<AppState>();
    setState(() => _applying = true);
    final String problem = await app.switchWorkspace(_path);
    if (!mounted) return;
    setState(() => _applying = false);
    if (problem.isNotEmpty) {
      _toast(problem);
      return;
    }
    Navigator.pop(context, true);
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(text),
        duration: const Duration(milliseconds: 2600),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final AppState app = context.watch<AppState>();
    final bool en = S.of(app.config?.language).isEnglish;
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final bool dark = theme.brightness == Brightness.dark;
    final bool sameAsNow = _path == app.workspacePath;

    return Scaffold(
      appBar: AppBar(
        title: Text(en ? 'Choose workspace' : '选择工作区'),
        actions: <Widget>[
          IconButton(
            tooltip: en ? 'Hidden folders' : '显示隐藏目录',
            icon: Icon(
              _showHidden
                  ? Icons.visibility_rounded
                  : Icons.visibility_off_outlined,
              size: 20,
            ),
            onPressed: () {
              setState(() => _showHidden = !_showHidden);
              _load();
            },
          ),
          IconButton(
            tooltip: en ? 'Enter path' : '输入路径',
            icon: const Icon(Icons.keyboard_alt_outlined, size: 20),
            onPressed: _manualPath,
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          if (DeviceBridge.isAndroid && !_hasAccess)
            _permissionBanner(cs, dark, en),
          if (_volumes.isNotEmpty) _volumeBar(cs, dark),
          _pathBar(cs, dark, en),
          if (_free > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Row(
                children: <Widget>[
                  Icon(Icons.sd_storage_outlined,
                      size: 13, color: cs.onSurface.withOpacity(0.35)),
                  const SizedBox(width: 5),
                  Text(
                    '${en ? 'Free' : '可用'} ${DeviceBridge.prettySize(_free)}',
                    style: TextStyle(
                      fontSize: 11,
                      color: cs.onSurface.withOpacity(0.4),
                    ),
                  ),
                ],
              ),
            ),
          const Divider(height: 1),
          Expanded(child: _list(cs, dark, en)),
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          decoration: BoxDecoration(
            color: dark ? const Color(0xFF12151A) : Colors.white,
            border: Border(
              top: BorderSide(color: cs.onSurface.withOpacity(0.07)),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(Icons.folder_outlined,
                      size: 16, color: cs.primary.withOpacity(0.8)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _newFolder,
                    icon: const Icon(Icons.create_new_folder_outlined, size: 16),
                    label: Text(en ? 'New' : '新建',
                        style: const TextStyle(fontSize: 12)),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                height: 44,
                child: ElevatedButton(
                  onPressed: _loading || _applying || sameAsNow ? null : _use,
                  child: _applying
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(
                          sameAsNow
                              ? (en ? 'Already the workspace' : '已经是当前工作区')
                              : (en ? 'Use this folder' : '使用这个文件夹'),
                          style: const TextStyle(fontSize: 14),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _permissionBanner(ColorScheme cs, bool dark, bool en) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      padding: const EdgeInsets.fromLTRB(13, 12, 10, 12),
      decoration: BoxDecoration(
        color: cs.primary.withOpacity(dark ? 0.14 : 0.07),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.primary.withOpacity(0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.folder_special_outlined, size: 16, color: cs.primary),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  en
                      ? 'Grant file access to use your own folders'
                      : '授予文件权限，才能用你手机上的文件夹',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: cs.primary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            en
                ? 'Android 11+ calls it "All files access". Without it ZCode only '
                    'sees its private directory, and the shell cannot reach your '
                    'projects.'
                : 'Android 11 以上叫「所有文件访问权限」。没有它，ZCode 只能看到自己的私有目录，'
                    '终端也进不到你的项目文件夹。',
            style: TextStyle(
              fontSize: 11.5,
              height: 1.5,
              color: cs.onSurface.withOpacity(0.62),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 34,
            child: ElevatedButton.icon(
              onPressed: _grant,
              icon: const Icon(Icons.lock_open_rounded, size: 15),
              label: Text(en ? 'Open settings' : '去授权',
                  style: const TextStyle(fontSize: 12.5)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _volumeBar(ColorScheme cs, bool dark) {
    return SizedBox(
      height: 46,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
        itemCount: _volumes.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (BuildContext ctx, int i) {
          final StorageVolume v = _volumes[i];
          final bool active = _path == v.path || _path.startsWith('${v.path}/');
          return ActionChip(
            avatar: Icon(
              v.removable ? Icons.sd_card_outlined : Icons.smartphone_rounded,
              size: 15,
              color: active ? cs.primary : cs.onSurface.withOpacity(0.55),
            ),
            label: Text(
              v.label,
              style: TextStyle(
                fontSize: 11.5,
                color: active ? cs.primary : cs.onSurface.withOpacity(0.75),
              ),
            ),
            backgroundColor: active
                ? cs.primary.withOpacity(dark ? 0.2 : 0.1)
                : Colors.transparent,
            side: BorderSide(
              color: active
                  ? cs.primary.withOpacity(0.4)
                  : cs.onSurface.withOpacity(0.12),
            ),
            onPressed: () => _enter(v.path),
          );
        },
      ),
    );
  }

  Widget _pathBar(ColorScheme cs, bool dark, bool en) {
    final List<String> parts =
        _path.split('/').where((String s) => s.isNotEmpty).toList();
    return SizedBox(
      height: 40,
      child: Row(
        children: <Widget>[
          IconButton(
            iconSize: 18,
            tooltip: en ? 'Up' : '上一级',
            onPressed: _path == '/' ? null : _up,
            icon: const Icon(Icons.arrow_upward_rounded),
          ),
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              reverse: true,
              itemCount: parts.length + 1,
              separatorBuilder: (_, __) => Icon(Icons.chevron_right_rounded,
                  size: 14, color: cs.onSurface.withOpacity(0.3)),
              // reverse puts index 0 at the right edge, so walk the crumbs
              // backwards to keep "root › … › current" reading left to right.
              itemBuilder: (BuildContext ctx, int i) {
                final int idx = parts.length - i;
                if (idx == 0) return _crumb('/', () => _enter('/'), cs);
                final String sub = '/${parts.take(idx).join('/')}';
                return _crumb(parts[idx - 1], () => _enter(sub), cs);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _crumb(String label, VoidCallback onTap, ColorScheme cs) {
    return Center(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: cs.onSurface.withOpacity(0.62),
              fontFamily: 'monospace',
            ),
          ),
        ),
      ),
    );
  }

  Widget _list(ColorScheme cs, bool dark, bool en) {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_dirs.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.folder_off_outlined,
                  size: 34, color: cs.onSurface.withOpacity(0.2)),
              const SizedBox(height: 10),
              Text(
                _error ?? (en ? 'No sub-folders here' : '这里没有子文件夹'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.6,
                  color: cs.onSurface.withOpacity(0.45),
                ),
              ),
              if (_error != null) ...<Widget>[
                const SizedBox(height: 12),
                TextButton(
                  onPressed: _load,
                  child: Text(en ? 'Retry' : '重试'),
                ),
              ],
            ],
          ),
        ),
      );
    }
    return ListView.builder(
      itemCount: _dirs.length,
      itemBuilder: (BuildContext ctx, int i) {
        final Directory d = _dirs[i];
        final String name = d.path.split('/').last;
        final bool isWorkspace = d.path == _path;
        return ListTile(
          dense: true,
          leading: Icon(
            name == '.zcode'
                ? Icons.settings_suggest_outlined
                : Icons.folder_rounded,
            size: 20,
            color: name.startsWith('.')
                ? cs.onSurface.withOpacity(0.3)
                : cs.primary.withOpacity(0.75),
          ),
          title: Text(
            name,
            style: const TextStyle(fontSize: 13.5),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            _hintFor(name, en),
            style: TextStyle(
              fontSize: 10.5,
              color: cs.onSurface.withOpacity(0.35),
            ),
          ),
          trailing: IconButton(
            iconSize: 18,
            tooltip: en ? 'Select this' : '直接选这个',
            icon: const Icon(Icons.check_circle_outline_rounded),
            onPressed: () {
              setState(() => _path = d.path);
              _use();
            },
          ),
          onTap: () => _enter(d.path),
          selected: isWorkspace,
        );
      },
    );
  }

  static String _hintFor(String name, bool en) {
    switch (name) {
      case 'Download':
        return en ? 'Downloads' : '下载';
      case 'Documents':
        return en ? 'Documents' : '文档';
      case 'DCIM':
        return en ? 'Camera' : '相机';
      case 'Pictures':
        return en ? 'Pictures' : '图片';
      case 'Android':
        return en ? 'App data (partly restricted)' : '应用数据（部分受限）';
      case 'ZCode':
        return en ? 'Default workspace' : '默认工作区';
      default:
        return '';
    }
  }
}
