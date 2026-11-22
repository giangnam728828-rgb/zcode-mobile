import 'remote_url.dart';

/// A saved desktop remote-control entry.
///
/// [url] is the sensitive part — the official link carries its own
/// authorization — so it only ever travels through [RemoteRepository]
/// (secure storage) and is shown to the user exclusively via [RemoteUrl.mask].
class RemoteConnection {
  RemoteConnection({
    required this.id,
    required this.name,
    required this.url,
    required this.addedAt,
    this.lastUsedAt,
  });

  final String id;
  String name;
  final String url;
  final DateTime addedAt;
  DateTime? lastUsedAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'url': url,
        'addedAt': addedAt.toIso8601String(),
        if (lastUsedAt != null) 'lastUsedAt': lastUsedAt!.toIso8601String(),
      };

  static RemoteConnection? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final String url = '${raw['url'] ?? ''}';
    // Refuse to resurrect anything the current validation rules reject: a
    // saved entry predating a tightening of the rules stays dead.
    final RemoteUrlCheck check = RemoteUrl.validate(url);
    if (!check.ok) return null;
    return RemoteConnection(
      id: '${raw['id'] ?? ''}',
      name: '${raw['name'] ?? ''}',
      url: check.uri.toString(),
      addedAt: DateTime.tryParse('${raw['addedAt']}') ?? DateTime.now(),
      lastUsedAt: DateTime.tryParse('${raw['lastUsedAt'] ?? ''}'),
    );
  }
}
