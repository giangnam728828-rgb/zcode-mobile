import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'remote_connection.dart';

/// Where connection JSON lives; production uses Android Keystore-backed
/// secure storage, tests swap an in-memory fake.
abstract class RemoteVault {
  Future<String?> read();
  Future<void> write(String value);
  Future<void> clear();
}

class SecureRemoteVault implements RemoteVault {
  static const FlutterSecureStorage _store = FlutterSecureStorage();
  static const String _key = 'zcode.remote.connections.v1';

  @override
  Future<String?> read() => _store.read(key: _key);

  @override
  Future<void> write(String value) => _store.write(key: _key, value: value);

  @override
  Future<void> clear() => _store.delete(key: _key);
}

/// Persists saved desktop connections in secure storage (Android Keystore
/// backing), keeping the authorization-bearing URL out of plain preferences.
class RemoteRepository {
  RemoteRepository({RemoteVault? vault}) : _vault = vault ?? SecureRemoteVault();

  final RemoteVault _vault;

  Future<List<RemoteConnection>> load() async {
    try {
      final String? raw = await _vault.read();
      if (raw == null || raw.isEmpty) return <RemoteConnection>[];
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List) return <RemoteConnection>[];
      return decoded
          .map(RemoteConnection.fromJson)
          .whereType<RemoteConnection>()
          .toList();
    } catch (_) {
      return <RemoteConnection>[];
    }
  }

  Future<void> persist(List<RemoteConnection> list) =>
      _vault.write(jsonEncode(list.map((RemoteConnection c) => c.toJson()).toList()));

  /// Deleting a connection also deletes its link material (总方案 P0-4).
  Future<void> clear() => _vault.clear();
}
