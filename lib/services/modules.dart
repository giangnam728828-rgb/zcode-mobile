import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A tool the phone can opt into. Built-ins ship as small POSIX shell scripts
/// written into the workspace, which keeps the APK tiny and works on any
/// Android version without extra native code.
class ModuleSpec {
  const ModuleSpec({
    required this.id,
    required this.name,
    required this.description,
    required this.commands,
    this.builtin = true,
    this.url = '',
    this.sizeHint = '',
  });

  final String id;
  final String name;
  final String description;
  final List<String> commands;
  final bool builtin;
  final String url;
  final String sizeHint;
}

class InstalledModule {
  InstalledModule({
    required this.id,
    required this.name,
    required this.dir,
    required this.source,
    required this.commands,
    DateTime? installedAt,
  }) : installedAt = installedAt ?? DateTime.now();

  final String id;
  final String name;
  final String dir;
  final String source;
  final List<String> commands;
  final DateTime installedAt;

  String get binPath => '$dir/bin';

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'dir': dir,
        'source': source,
        'commands': commands,
        'installedAt': installedAt.toIso8601String(),
      };

  static InstalledModule fromJson(Map<String, dynamic> json) => InstalledModule(
        id: '${json['id']}',
        name: '${json['name']}',
        dir: '${json['dir']}',
        source: '${json['source']}',
        commands: ((json['commands'] as List?) ?? <dynamic>[])
            .map((dynamic e) => '$e')
            .toList(),
        installedAt:
            DateTime.tryParse('${json['installedAt']}') ?? DateTime.now(),
      );
}

/// Installs, lists and removes optional command-line tools for the agent.
class ModuleCenter {
  ModuleCenter(this.workspace);

  final Directory workspace;
  final Map<String, InstalledModule> _installed =
      <String, InstalledModule>{};
  bool loaded = false;
  String? error;

  Directory get _root => Directory('${workspace.path}/.zcode/modules');
  File get _stateFile => File('${workspace.path}/.zcode/modules.json');

  static const List<ModuleSpec> catalog = <ModuleSpec>[
    ModuleSpec(
      id: 'tree',
      name: 'tree',
      description: '以树形列出目录，比 ls -R 更好读，适合让模型快速了解项目结构。',
      commands: <String>['tree'],
    ),
    ModuleSpec(
      id: 'peek',
      name: 'peek',
      description: '同时查看文件的行数、大小、开头与结尾，排查日志很省事。',
      commands: <String>['peek'],
    ),
    ModuleSpec(
      id: 'findtext',
      name: 'findtext',
      description: '在工作区递归搜索文本，自动跳过 .git，输出前 80 条命中。',
      commands: <String>['findtext'],
    ),
    ModuleSpec(
      id: 'space',
      name: 'space',
      description: '按体积排序列出目录占用，找出把存储吃掉的元凶。',
      commands: <String>['space'],
    ),
    ModuleSpec(
      id: 'sysinfo',
      name: 'sysinfo',
      description: '查看系统版本、内核、可用运行时与磁盘空间，安装依赖前先摸底。',
      commands: <String>['sysinfo'],
    ),
  ];

  static const Map<String, String> _scripts = <String, String>{
    'tree': r'''#!/system/bin/sh
# tree [dir] [maxdepth]
dir="${1:-.}"
depth="${2:-4}"
if [ ! -d "$dir" ]; then
  echo "not a directory: $dir" >&2
  exit 2
fi
find "$dir" -maxdepth "$depth" -not -path '*/.git/*' 2>/dev/null | awk -F/ '{
  n = NF
  indent = ""
  for (i = 2; i < n; i++) indent = indent "  "
  print indent $NF
}'
''',
    'peek': r'''#!/system/bin/sh
# peek <file> [lines]
f="$1"
n="${2:-40}"
if [ -z "$f" ]; then
  echo "usage: peek <file> [lines]" >&2
  exit 2
fi
if [ ! -f "$f" ]; then
  echo "not a file: $f" >&2
  exit 2
fi
echo "== $f  ($(wc -c < "$f") bytes, $(wc -l < "$f") lines)"
echo "--- head"
head -n "$n" "$f"
echo "--- tail"
tail -n "$n" "$f"
''',
    'findtext': r'''#!/system/bin/sh
# findtext <pattern> [dir]
pat="$1"
dir="${2:-.}"
if [ -z "$pat" ]; then
  echo "usage: findtext <pattern> [dir]" >&2
  exit 2
fi
grep -rn "$pat" "$dir" 2>/dev/null | grep -v '/.git/' | head -80
''',
    'space': r'''#!/system/bin/sh
# space [dir]
dir="${1:-.}"
du -k "$dir"/* 2>/dev/null | sort -n | tail -20 |
  awk '{ printf "%8.1f MB  %s\n", $1 / 1024, $2 }'
''',
    'sysinfo': r'''#!/system/bin/sh
echo "workspace: ${ZCODE_WORKSPACE:-$PWD}"
uname -a
if command -v node >/dev/null 2>&1; then
  echo "node: $(node -v 2>/dev/null)"
else
  echo "node: not installed"
fi
if command -v python3 >/dev/null 2>&1; then
  echo "python3: $(python3 -V 2>&1)"
elif command -v python >/dev/null 2>&1; then
  echo "python: $(python -V 2>&1)"
else
  echo "python: not installed"
fi
if command -v git >/dev/null 2>&1; then
  echo "git: $(git --version 2>/dev/null)"
else
  echo "git: not installed"
fi
ver="$(getprop ro.build.version.release 2>/dev/null)"
[ -n "$ver" ] && echo "android: $ver"
df -h "$PWD" 2>/dev/null | tail -2
''',
  };

  List<InstalledModule> get installed => _installed.values.toList()
    ..sort((InstalledModule a, InstalledModule b) =>
        a.name.compareTo(b.name));

  List<String> get binPaths => <String>[
        for (final InstalledModule m in _installed.values)
          if (Directory(m.binPath).existsSync()) m.binPath,
      ];

  bool isInstalled(String id) => _installed.containsKey(id);

  List<ModuleSpec> get available => catalog
      .where((ModuleSpec m) => !_installed.containsKey(m.id))
      .toList();

  Future<void> load() async {
    try {
      if (!await _root.exists()) await _root.create(recursive: true);
      if (await _stateFile.exists()) {
        final Object? raw = jsonDecode(await _stateFile.readAsString());
        if (raw is List) {
          for (final Object? item in raw) {
            if (item is! Map) continue;
            final InstalledModule m =
                InstalledModule.fromJson(item.cast<String, dynamic>());
            if (Directory(m.dir).existsSync()) _installed[m.id] = m;
          }
        }
      }
      // Make sure previously created scripts are still executable.
      for (final InstalledModule m in _installed.values) {
        await _chmod(Directory(m.binPath));
      }
    } catch (e) {
      error = '$e';
    } finally {
      loaded = true;
    }
  }

  Future<InstalledModule> install(
    ModuleSpec spec, {
    void Function(double progress)? onProgress,
  }) async {
    if (spec.builtin) {
      onProgress?.call(0.2);
      final Directory dir = Directory('${_root.path}/${spec.id}');
      final Directory bin = Directory('${dir.path}/bin');
      await bin.create(recursive: true);
      final String body = _scripts[spec.id] ?? '#!/system/bin/sh\necho "${spec.name}"\n';
      for (final String cmd in spec.commands) {
        final File f = File('${bin.path}/$cmd');
        await f.writeAsString(body);
        await _chmodFile(f);
      }
      onProgress?.call(1);
      final InstalledModule m = InstalledModule(
        id: spec.id,
        name: spec.name,
        dir: dir.path,
        source: 'builtin',
        commands: spec.commands,
      );
      _installed[m.id] = m;
      await _persist();
      return m;
    }
    return installArchive(spec.url, name: spec.name, onProgress: onProgress);
  }

  /// Downloads a `.tar.gz` / `.tgz` / `.zip` and unpacks it under modules/.
  /// The archive must contain a `bin` directory; those files become commands.
  Future<InstalledModule> installArchive(
    String url, {
    String? name,
    void Function(double progress)? onProgress,
  }) async {
    final Uri? uri = Uri.tryParse(url.trim());
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      throw ArgumentError('只支持 http(s) 下载地址');
    }
    final String lower = uri.path.toLowerCase();
    final bool zip = lower.endsWith('.zip');
    if (!zip && !lower.endsWith('.tar.gz') && !lower.endsWith('.tgz')) {
      throw ArgumentError('仅支持 .tar.gz / .tgz / .zip 压缩包');
    }
    final String id = _slug(name ?? uri.pathSegments.last);
    final Directory downloadDir = Directory('${workspace.path}/.zcode/download');
    await downloadDir.create(recursive: true);
    final File archive =
        File('${downloadDir.path}/$id.${zip ? 'zip' : 'tar.gz'}');
    onProgress?.call(0.02);

    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20)
      ..userAgent = 'ZCode-Mobile/3.0';
    try {
      final HttpClientRequest req = await client.getUrl(uri);
      final HttpClientResponse resp = await req.close();
      if (resp.statusCode != 200) {
        throw StateError('下载失败（HTTP ${resp.statusCode}）');
      }
      final int total = resp.contentLength;
      final IOSink sink = archive.openWrite();
      int received = 0;
      try {
        await for (final List<int> chunk in resp) {
          received += chunk.length;
          sink.add(chunk);
          if (total > 0) {
            onProgress?.call(0.02 + 0.88 * (received / total));
          }
        }
      } finally {
        await sink.flush();
        await sink.close();
      }
    } finally {
      client.close(force: true);
    }

    final Directory dest = Directory('${_root.path}/$id');
    if (await dest.exists()) await dest.delete(recursive: true);
    await dest.create(recursive: true);
    onProgress?.call(0.92);
    final String tool = zip ? 'unzip' : 'tar';
    final List<String> args =
        zip ? <String>['-o', '-q', archive.path, '-d', dest.path]
            : <String>['-xzf', archive.path, '-C', dest.path];
    final ProcessResult r = await Process.run(
      tool,
      args,
      environment: <String, String>{'PATH': '/system/bin:/system/xbin:/vendor/bin:/bin'},
    ).timeout(const Duration(seconds: 90), onTimeout: () {
      throw TimeoutException('解压超时');
    });
    if (r.exitCode != 0) {
      await dest.delete(recursive: true).catchError((Object _) => dest);
      throw StateError('解压失败（$tool 退出码 ${r.exitCode}）：${r.stderr}');
    }
    final List<Directory> bins = await _findBins(dest);
    if (bins.isEmpty) {
      await dest.delete(recursive: true).catchError((Object _) => dest);
      throw StateError('压缩包里没有 bin 目录，无法注册命令');
    }
    final List<String> commands = <String>[];
    for (final Directory bin in bins) {
      await _chmod(bin);
      await for (final FileSystemEntity e in bin.list()) {
        if (e is File) commands.add(e.path.split('/').last);
      }
    }
    commands.sort();
    try {
      await archive.delete();
    } catch (_) {}
    onProgress?.call(1);
    final InstalledModule m = InstalledModule(
      id: id,
      name: name?.trim().isNotEmpty == true ? name!.trim() : id,
      dir: dest.path,
      source: uri.toString(),
      commands: commands,
    );
    _installed[m.id] = m;
    await _persist();
    return m;
  }

  Future<void> remove(String id) async {
    final InstalledModule? m = _installed.remove(id);
    if (m != null) {
      try {
        await Directory(m.dir).delete(recursive: true);
      } catch (_) {}
      await _persist();
    }
  }

  Future<List<Directory>> _findBins(Directory root) async {
    final List<Directory> out = <Directory>[];
    await for (final FileSystemEntity e
        in root.list(recursive: true, followLinks: false)) {
      if (e is! Directory) continue;
      if (e.path.split('/').last != 'bin') continue;
      out.add(e);
      if (out.length >= 4) break;
    }
    return out;
  }

  Future<void> _chmod(Directory dir) async {
    try {
      await for (final FileSystemEntity e in dir.list()) {
        if (e is File) await _chmodFile(e);
      }
    } catch (_) {}
  }

  Future<void> _chmodFile(File f) async {
    try {
      final ProcessResult r =
          await Process.run('chmod', <String>['755', f.path]);
      if (r.exitCode != 0) {
        // Some ROMs lack chmod; the shell can still run it via `sh <path>`.
      }
    } catch (_) {}
  }

  Future<void> _persist() async {
    try {
      await _stateFile.parent.create(recursive: true);
      final String raw = jsonEncode(
          _installed.values.map((InstalledModule m) => m.toJson()).toList());
      await _stateFile.writeAsString(raw);
    } catch (e) {
      error = '$e';
    }
  }

  static String _slug(String raw) {
    final String s = raw
        .toLowerCase()
        .replaceAll(RegExp(r'\.(tar\.gz|tgz|zip)$'), '')
        .replaceAll(RegExp(r'[^a-z0-9._-]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return s.isEmpty ? 'module-${DateTime.now().millisecondsSinceEpoch}' : s;
  }
}
