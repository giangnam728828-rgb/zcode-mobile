import 'chat_message.dart';

/// A chat thread. Title is derived from the first user message until the
/// user renames it.
class Conversation {
  Conversation({
    required this.id,
    this.title = '',
    List<ChatMessage>? messages,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.pinned = false,
    this.archived = false,
  })  : messages = messages ?? <ChatMessage>[],
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  final String id;
  String title;
  final List<ChatMessage> messages;
  final DateTime createdAt;
  DateTime updatedAt;
  bool pinned;
  bool archived;

  bool get isUntitled => title.trim().isEmpty;

  /// First user line, trimmed for the drawer.
  String previewTitle() {
    if (title.trim().isNotEmpty) return title;
    for (final ChatMessage m in messages) {
      if (m.isUser && m.text.trim().isNotEmpty) {
        final String t = m.text.trim().replaceAll(RegExp(r'\s+'), ' ');
        return t.length > 28 ? '${t.substring(0, 28)}…' : t;
      }
    }
    return '';
  }

  int get userTurns => messages.where((ChatMessage m) => m.isUser).length;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'title': title,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'pinned': pinned,
        'archived': archived,
        'messages': messages.map((ChatMessage m) => m.toJson()).toList(),
      };

  factory Conversation.fromJson(Map<String, dynamic> json) {
    final List<dynamic> raw =
        (json['messages'] as List<dynamic>?) ?? <dynamic>[];
    return Conversation(
      id: (json['id'] as String?) ?? _newId(),
      title: (json['title'] as String?) ?? '',
      messages: raw
          .map((dynamic e) => ChatMessage.fromJson(e as Map<String, dynamic>))
          .toList(),
      createdAt: DateTime.tryParse((json['createdAt'] as String?) ?? ''),
      updatedAt: DateTime.tryParse((json['updatedAt'] as String?) ?? ''),
      pinned: (json['pinned'] as bool?) ?? false,
      archived: (json['archived'] as bool?) ?? false,
    );
  }

  static String _newId() =>
      'c${DateTime.now().microsecondsSinceEpoch}';

  factory Conversation.fresh() => Conversation(id: _newId());

  /// Markdown transcript, used by share/export.
  String toMarkdown() {
    final StringBuffer b = StringBuffer();
    final String name = previewTitle();
    b.writeln('# ${name.isEmpty ? 'ZCode Chat' : name}');
    b.writeln();
    b.writeln('_${createdAt.toIso8601String().substring(0, 16).replaceFirst('T', ' ')}_');
    b.writeln();
    for (final ChatMessage m in messages) {
      if (m.isEmpty) continue;
      b.writeln(m.isUser ? '## You' : '## ZCode');
      if (m.thinking.trim().isNotEmpty) {
        b.writeln();
        b.writeln('<details><summary>Thinking</summary>');
        b.writeln();
        b.writeln(m.thinking.trim());
        b.writeln();
        b.writeln('</details>');
      }
      b.writeln();
      b.writeln(m.text.trim());
      b.writeln();
    }
    return b.toString();
  }
}
