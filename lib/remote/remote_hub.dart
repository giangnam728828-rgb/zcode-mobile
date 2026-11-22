import 'package:flutter/foundation.dart';

import 'remote_connection.dart';
import 'remote_repository.dart';

/// Connection store shared by the dock's remote view and the manager page.
///
/// Deliberately a standalone singleton, not part of [AppState]: the remote
/// surface must stay isolated from local session/workspace state (总方案
/// P0-3/P0-5). Both pages listen here, so an edit in one is reflected in the
/// other instantly.
class RemoteHub extends ChangeNotifier {
  RemoteHub._();
  static final RemoteHub instance = RemoteHub._();

  final RemoteRepository _repo = RemoteRepository();
  List<RemoteConnection> items = <RemoteConnection>[];
  bool loading = true;

  bool _loaded = false;

  /// Idempotent boot: both pages call this in initState.
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    await reload();
  }

  Future<void> reload() async {
    items = await _repo.load();
    loading = false;
    notifyListeners();
  }

  /// Most recently used connection, or null when nothing is saved yet.
  RemoteConnection? get lastUsed {
    RemoteConnection? best;
    for (final RemoteConnection c in items) {
      if (best == null) {
        best = c;
        continue;
      }
      final DateTime? a = c.lastUsedAt;
      final DateTime? b = best.lastUsedAt;
      if (b == null || (a != null && a.isAfter(b))) best = c;
    }
    return best;
  }

  RemoteConnection? byUrl(String url) {
    for (final RemoteConnection c in items) {
      if (c.url == url) return c;
    }
    return null;
  }

  Future<void> add(RemoteConnection c) async {
    items.add(c);
    await persist();
  }

  Future<void> remove(String id) async {
    // Deleting a connection also drops its link material (总方案 P0-4).
    items.removeWhere((RemoteConnection e) => e.id == id);
    await persist();
  }

  Future<void> rename(RemoteConnection c, String name) async {
    c.name = name;
    await persist();
  }

  Future<void> touch(RemoteConnection c) async {
    c.lastUsedAt = DateTime.now();
    await persist();
  }

  Future<void> persist() async {
    await _repo.persist(items);
    notifyListeners();
  }
}
