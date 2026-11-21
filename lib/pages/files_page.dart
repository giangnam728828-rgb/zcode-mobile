import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../agent/tools.dart';
import '../l10n/strings.dart';
import '../models/attachment.dart';
import '../platform/device_bridge.dart';
import '../services/workspace.dart';
import '../state/app_state.dart';
import 'workspace_picker_page.dart';

/// Workspace browser: the phone-side equivalent of the desktop file tree.
/// Files can be created, renamed, deleted, edited and referenced in chat.
class FilesPage extends StatefulWidget {
  const FilesPage({Key? key}) : super(key: key);

  @override
  State<FilesPage> createState() => _FilesPageState();
}

class _FilesPageState extends State<FilesPage> {
  String _path = '';
  List<FileSystemEntity> _items = <FileSystemEntity>[];
  bool _loading = true;
  bool _showHidden = false;
  String? _error;
  int _epoch = -1;

  AppState get _state => context.read<AppState>();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final ToolBox? box = _state.tools;
    if (box == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final Directory dir = Directory(box.resolvePath(_path));
      final List<FileSystemEntity> all = await dir.list().toList();
      all.sort((FileSystemEntity a, FileSystemEntity b) {
        final bool ad = a is Directory;
        final bool bd = b is Directory;
        if (ad != bd) return ad ? -1 : 1;
        return a.path.toLowerCase().compareTo(b.path.toLowerCase());
      });
      if (!mounted) return;
      setState(() {
        _items = all
            .where((FileSystemEntity e) =>
                _showHidden || !e.path.split('/').last.startsWith('.'))
            .toList();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  String get _displayPath => _path.isEmpty ? '/' : '/$_path';

  String get _absolute => _state.tools?.resolvePath(_path) ?? _path;

  Future<void> _changeWorkspace() async {
    final bool? changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => WorkspacePickerPage(initialPath: _state.workspacePath),
      ),
    );
    if (changed == true && mounted) {
      setState(() => _path = '');
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppState app = context.watch<AppState>();
    final S s = S.of(app.config?.language);
    final bool en = s.isEnglish;
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;

    // A workspace switch invalidates every relative path on screen.
    if (_epoch != app.workspaceEpoch) {
      _epoch = app.workspaceEpoch;
      if (_path.isNotEmpty) {
        _path = '';
        WidgetsBinding.instance.addPostFrameCallback((_) => _load());
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(en ? 'Workspace' : '工作区文件'),
            Text(
              '${WorkspaceResolver.label(_absolute)}  ·  $_displayPath',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w400,
                color: cs.onSurface.withValues(alpha: 0.42),
              ),
            ),
          ],
        ),
        actions: <Widget>[
          IconButton(
            tooltip: en ? 'Switch workspace folder' : '切换工作区文件夹',
            icon: const Icon(Icons.drive_folder_upload_outlined, size: 20),
            onPressed: _changeWorkspace,
          ),
          IconButton(
            tooltip: en ? 'Open with another app' : '用其他应用打开',
            icon: const Icon(Icons.open_in_new_rounded, size: 19),
            onPressed: () async {
              final bool ok = await DeviceBridge.openPath(_absolute);
              if (!ok && mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(en ? 'No app can open it' : '没有可打开它的应用')),
                );
              }
            },
          ),
          IconButton(
            tooltip: en ? 'Hidden files' : '显示隐藏文件',
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
            tooltip: en ? 'Refresh' : '刷新',
            icon: const Icon(Icons.refresh_rounded, size: 20),
            onPressed: _load,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        mini: false,
        onPressed: _createSheet,
        child: const Icon(Icons.add_rounded),
      ),
      body: Column(
        children: <Widget>[
          _breadcrumb(cs, en),
          if (DeviceBridge.isAndroid && !app.storageAccess)
            _storageBanner(cs, en),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? _errorBox(cs, _error!)
                    : _items.isEmpty
                        ? _empty(cs, en)
                        : ListView.builder(
                            padding: const EdgeInsets.only(bottom: 90),
                            itemCount: _items.length,
                            itemBuilder: (BuildContext ctx, int i) =>
                                _tile(_items[i], cs, en),
                          ),
          ),
        ],
      ),
    );
  }

  Widget _storageBanner(ColorScheme cs, bool en) {
    return InkWell(
      onTap: _changeWorkspace,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(14, 9, 10, 9),
        color: cs.primary.withValues(alpha: 0.07),
        child: Row(
          children: <Widget>[
            Icon(Icons.folder_special_outlined, size: 15, color: cs.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                en
                    ? 'Only the private folder is visible. Grant file access to '
                        'open your own folders.'
                    : '现在只能看到应用私有目录。授予文件权限后就能打开手机上的文件夹。',
                style: TextStyle(
                  fontSize: 11,
                  height: 1.4,
                  color: cs.primary.withValues(alpha: 0.9),
                ),
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                size: 16, color: cs.primary.withValues(alpha: 0.6)),
          ],
        ),
      ),
    );
  }

  Widget _breadcrumb(ColorScheme cs, bool en) {
    final List<String> parts =
        _path.isEmpty ? <String>[] : _path.split('/');
    return Container(
      height: 38,
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: cs.onSurface.withValues(alpha: 0.06)),
        ),
      ),
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        children: <Widget>[
          _crumb(
            label: en ? 'root' : '根目录',
            icon: Icons.home_outlined,
            active: parts.isEmpty,
            cs: cs,
            onTap: () {
              setState(() => _path = '');
              _load();
            },
          ),
          for (int i = 0; i < parts.length; i++) ...<Widget>[
            Icon(Icons.chevron_right_rounded,
                size: 15, color: cs.onSurface.withValues(alpha: 0.25)),
            _crumb(
              label: parts[i],
              active: i == parts.length - 1,
              cs: cs,
              onTap: () {
                setState(() => _path = parts.sublist(0, i + 1).join('/'));
                _load();
              },
            ),
          ],
          if (parts.isNotEmpty) ...<Widget>[
            const SizedBox(width: 4),
            IconButton(
              padding: EdgeInsets.zero,
              iconSize: 16,
              tooltip: en ? 'Up' : '上一级',
              icon: Icon(Icons.arrow_upward_rounded,
                  color: cs.onSurface.withValues(alpha: 0.45)),
              onPressed: () {
                setState(() {
                  _path = parts.sublist(0, parts.length - 1).join('/');
                });
                _load();
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _crumb({
    required String label,
    required bool active,
    required ColorScheme cs,
    required VoidCallback onTap,
    IconData? icon,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        child: Row(
          children: <Widget>[
            if (icon != null) ...<Widget>[
              Icon(icon, size: 14, color: cs.onSurface.withValues(alpha: 0.45)),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontFamily: icon == null ? 'monospace' : null,
                fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                color: active
                    ? cs.onSurface.withValues(alpha: 0.8)
                    : cs.onSurface.withValues(alpha: 0.45),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _errorBox(ColorScheme cs, String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: cs.error),
        ),
      ),
    );
  }

  Widget _empty(ColorScheme cs, bool en) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.folder_open_rounded,
              size: 40, color: cs.onSurface.withValues(alpha: 0.2)),
          const SizedBox(height: 10),
          Text(
            en ? 'This folder is empty' : '这个目录还是空的',
            style: TextStyle(
              fontSize: 13,
              color: cs.onSurface.withValues(alpha: 0.45),
            ),
          ),
          const SizedBox(height: 14),
          TextButton(
            onPressed: _createSheet,
            child: Text(en ? 'Create a file' : '新建文件'),
          ),
        ],
      ),
    );
  }

  Widget _tile(FileSystemEntity e, ColorScheme cs, bool en) {
    final bool dir = e is Directory;
    final String name = e.path.split('/').last;
    final int size = e is File ? e.lengthSync() : 0;
    final String rel = _path.isEmpty ? name : '$_path/$name';

    return InkWell(
      onTap: () {
        if (dir) {
          setState(() => _path = rel);
          _load();
        } else {
          _openFile(File(e.path), rel);
        }
      },
      onLongPress: () => _itemSheet(e, rel, en),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 11, 8, 11),
        child: Row(
          children: <Widget>[
            _icon(e, cs, dir),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.5,
                      color: cs.onSurface.withValues(alpha: 0.86),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    dir
                        ? (en ? 'folder' : '文件夹')
                        : '${_size(size)}${Attachment.looksLikeImage(name) ? ' · image' : ''}',
                    style: TextStyle(
                      fontSize: 10.5,
                      color: cs.onSurface.withValues(alpha: 0.36),
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              iconSize: 18,
              tooltip: '',
              icon: Icon(Icons.more_horiz_rounded,
                  color: cs.onSurface.withValues(alpha: 0.32)),
              onPressed: () => _itemSheet(e, rel, en),
            ),
          ],
        ),
      ),
    );
  }

  Widget _icon(FileSystemEntity e, ColorScheme cs, bool dir) {
    final String name = e.path.split('/').last;
    IconData icon;
    Color color;
    if (dir) {
      icon = Icons.folder_rounded;
      color = cs.primary.withValues(alpha: 0.7);
    } else if (Attachment.looksLikeImage(name)) {
      icon = Icons.image_outlined;
      color = const Color(0xFF12A67A);
    } else if (name.endsWith('.md')) {
      icon = Icons.article_outlined;
      color = const Color(0xFF8B5CF6);
    } else if (name.endsWith('.json') ||
        name.endsWith('.yaml') ||
        name.endsWith('.yml') ||
        name.endsWith('.toml')) {
      icon = Icons.data_object_rounded;
      color = const Color(0xFFE08700);
    } else if (name.endsWith('.sh')) {
      icon = Icons.terminal_rounded;
      color = const Color(0xFF3D5AFE);
    } else {
      icon = Icons.insert_drive_file_outlined;
      color = cs.onSurface.withValues(alpha: 0.45);
    }
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(9),
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: 17, color: color),
    );
  }

  Future<void> _openFile(File f, String rel) async {
    final bool en = S.of(_state.config?.language).isEnglish;
    if (Attachment.looksLikeImage(rel)) {
      Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => _ImagePage(path: f.path, name: rel),
      ));
      return;
    }
    final int size = await f.length();
    if (size > 1024 * 1024) {
      if (!mounted) return;
      final bool? ok = await showDialog<bool>(
        context: context,
        builder: (BuildContext ctx) => AlertDialog(
          content: Text(
            en
                ? 'This file is ${_size(size)}. Opening it in the editor may be slow.'
                : '这个文件有 ${_size(size)}，在编辑器里打开可能会卡。',
            style: const TextStyle(fontSize: 14, height: 1.5),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(en ? 'Cancel' : '取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(en ? 'Open anyway' : '仍然打开'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => FileEditorPage(path: f.path, relative: rel),
    ));
    _state.refreshFileIndex();
    _load();
  }

  Future<void> _itemSheet(FileSystemEntity e, String rel, bool en) {
    return showModalBottomSheet<void>(
      context: context,
      builder: (BuildContext ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.alternate_email_rounded),
              title: Text(en ? 'Mention in chat' : '在聊天中引用'),
              subtitle: Text('@$rel',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11)),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.of(context).pop('@$rel');
              },
            ),
            ListTile(
              leading: const Icon(Icons.copy_rounded),
              title: Text(en ? 'Copy path' : '复制路径'),
              onTap: () {
                Clipboard.setData(ClipboardData(text: rel));
                Navigator.pop(ctx);
                _toast(en ? 'Path copied' : '路径已复制');
              },
            ),
            ListTile(
                leading: const Icon(Icons.drive_file_rename_outline_rounded),
              title: Text(en ? 'Rename' : '重命名'),
              onTap: () {
                Navigator.pop(ctx);
                _rename(e, rel, en);
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline_rounded,
                  color: Theme.of(context).colorScheme.error),
              title: Text(
                en ? 'Delete' : '删除',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _delete(e, rel, en);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _createSheet() async {
    final bool en = S.of(_state.config?.language).isEnglish;
    final String? kind = await showModalBottomSheet<String>(
      context: context,
      builder: (BuildContext ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.note_add_outlined),
              title: Text(en ? 'New file' : '新建文件'),
              onTap: () => Navigator.pop(ctx, 'file'),
            ),
            ListTile(
              leading: const Icon(Icons.create_new_folder_outlined),
              title: Text(en ? 'New folder' : '新建文件夹'),
              onTap: () => Navigator.pop(ctx, 'dir'),
            ),
          ],
        ),
      ),
    );
    if (kind == null) return;
    final String? name = await _askName(
      title: en ? (kind == 'dir' ? 'New folder' : 'New file') : (kind == 'dir' ? '新建文件夹' : '新建文件'),
      initial: kind == 'dir' ? 'notes' : 'notes.md',
    );
    if (name == null || name.trim().isEmpty) return;
    final String rel = _path.isEmpty ? name.trim() : '$_path/${name.trim()}';
    final String abs = _state.tools!.resolvePath(rel);
    try {
      if (kind == 'dir') {
        await Directory(abs).create(recursive: true);
      } else {
        final File f = File(abs);
        if (await f.exists()) {
          _toast(en ? 'Already exists' : '同名文件已存在');
          return;
        }
        await f.parent.create(recursive: true);
        await f.writeAsString('');
      }
      _state.refreshFileIndex();
      await _load();
    } catch (e) {
      _toast('$e');
    }
  }

  Future<void> _rename(FileSystemEntity e, String rel, bool en) async {
    final String name = e.path.split('/').last;
    final String? next = await _askName(
      title: en ? 'Rename' : '重命名',
      initial: name,
    );
    if (next == null || next.trim().isEmpty || next.trim() == name) return;
    final String parent = _path.isEmpty ? '' : '$_path/';
    final String targetRel = '$parent${next.trim()}';
    final String target = _state.tools!.resolvePath(targetRel);
    if (FileSystemEntity.typeSync(target) != FileSystemEntityType.notFound) {
      _toast(en ? 'Name already in use' : '这个名字已被占用');
      return;
    }
    try {
      if (e is Directory) {
        await Directory(e.path).rename(target);
      } else {
        await File(e.path).rename(target);
      }
      _state.refreshFileIndex();
      await _load();
    } catch (err) {
      _toast('$err');
    }
  }

  Future<void> _delete(FileSystemEntity e, String rel, bool en) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        content: Text(
          en ? 'Delete $rel? This cannot be undone.' : '删除 $rel？删除后无法恢复。',
          style: const TextStyle(fontSize: 14, height: 1.5),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(en ? 'Cancel' : '取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(en ? 'Delete' : '删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      if (e is Directory) {
        await Directory(e.path).delete(recursive: true);
      } else {
        await File(e.path).delete();
      }
      _state.refreshFileIndex();
      await _load();
    } catch (err) {
      _toast('$err');
    }
  }

  Future<String?> _askName({
    required String title,
    String initial = '',
  }) {
    final TextEditingController ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(fontSize: 14, fontFamily: 'monospace'),
          decoration: const InputDecoration(isDense: true),
          onSubmitted: (String v) => Navigator.pop(ctx, v),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(S.of(_state.config?.language).cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: Text(S.of(_state.config?.language).ok),
          ),
        ],
      ),
    );
  }

  void _toast(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(text),
        duration: const Duration(milliseconds: 1500),
      ));
  }

  static String _size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

/// Plain text editor with dirty tracking and a wrap toggle.
class FileEditorPage extends StatefulWidget {
  const FileEditorPage({Key? key, required this.path, required this.relative})
      : super(key: key);

  final String path;
  final String relative;

  @override
  State<FileEditorPage> createState() => _FileEditorPageState();
}

class _FileEditorPageState extends State<FileEditorPage> {
  late final TextEditingController _text;
  bool _dirty = false;
  bool _wrap = false;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    String body = '';
    try {
      body = File(widget.path).readAsStringSync();
    } catch (e) {
      _error = '$e';
    }
    _text = TextEditingController(text: body);
    _text.addListener(() {
      if (!_dirty) setState(() => _dirty = true);
    });
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await File(widget.path).writeAsString(_text.text);
      if (!mounted) return;
      setState(() {
        _dirty = false;
        _saving = false;
      });
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
          content: Text('已保存'),
          duration: Duration(milliseconds: 1200),
        ));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '$e';
      });
    }
  }

  Future<bool> _confirmLeave() async {
    if (!_dirty) return true;
    final bool en = S.of(context.read<AppState>().config?.language).isEnglish;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        content: Text(
          en ? 'Discard unsaved changes?' : '放弃未保存的修改？',
          style: const TextStyle(fontSize: 14.5, height: 1.5),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(en ? 'Keep editing' : '继续编辑'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(en ? 'Discard' : '放弃'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final bool en = S.of(context.watch<AppState>().config?.language).isEnglish;

    return WillPopScope(
      onWillPop: _confirmLeave,
      child: Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                widget.relative.split('/').last,
                style: const TextStyle(fontSize: 15),
              ),
              Text(
                '${_text.text.split('\n').length} lines'
                '${_dirty ? (en ? ' · edited' : ' · 未保存') : ''}',
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w400,
                  color: cs.onSurface.withValues(alpha: 0.4),
                ),
              ),
            ],
          ),
          actions: <Widget>[
            IconButton(
              tooltip: en ? 'Wrap lines' : '自动换行',
              icon: Icon(_wrap
                  ? Icons.wrap_text_rounded
                  : Icons.notes_rounded),
              onPressed: () => setState(() => _wrap = !_wrap),
            ),
            TextButton(
              onPressed: _dirty && !_saving ? _save : null,
              child: Text(
                en ? 'Save' : '保存',
                style: TextStyle(
                  color: _dirty ? cs.primary : cs.onSurface.withValues(alpha: 0.3),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        body: Column(
          children: <Widget>[
            if (_error != null)
              Container(
                width: double.infinity,
                color: cs.error.withValues(alpha: 0.08),
                padding: const EdgeInsets.all(10),
                child: Text(
                  _error!,
                  style: TextStyle(fontSize: 12, color: cs.error),
                ),
              ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
                child: TextField(
                  controller: _text,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  keyboardType: TextInputType.multiline,
                  style: const TextStyle(
                    fontSize: 13,
                    height: 1.5,
                    fontFamily: 'monospace',
                  ),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    hintText: en ? 'Start typing…' : '开始输入…',
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                  onChanged: (_) {
                    if (_dirty) setState(() {});
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Pinch-to-zoom image preview.
class _ImagePage extends StatelessWidget {
  const _ImagePage({required this.path, required this.name});

  final String path;
  final String name;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(name, style: const TextStyle(fontSize: 14)),
      ),
      body: Center(
        child: InteractiveViewer(
          minScale: 0.6,
          maxScale: 5,
          child: Image.file(
            File(path),
            errorBuilder: (BuildContext ctx, Object e, StackTrace? st) =>
                const Icon(Icons.broken_image_outlined,
                    color: Colors.white54, size: 48),
          ),
        ),
      ),
    );
  }
}
