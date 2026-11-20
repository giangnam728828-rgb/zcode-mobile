import '../agent/tools.dart';

enum Sender { user, assistant, system }

/// One bubble in a conversation. Mutable on purpose: streaming appends
/// deltas in place, which keeps the list identity stable for AnimatedList.
class ChatMessage {
  ChatMessage({
    required this.id,
    required this.role,
    required this.text,
    this.thinking = '',
    DateTime? createdAt,
    this.streaming = false,
    this.error,
    this.stopped = false,
    List<ToolCall>? tools,
  })  : tools = tools ?? <ToolCall>[],
        createdAt = createdAt ?? DateTime.now();

  final String id;
  final Sender role;
  String text;

  /// Reasoning stream (GLM thinking models), shown collapsed.
  String thinking;
  final DateTime createdAt;
  bool streaming;
  String? error;
  bool stopped;

  /// Tool invocations that belong to this assistant turn.
  final List<ToolCall> tools;

  bool get isUser => role == Sender.user;
  bool get isEmpty =>
      text.trim().isEmpty && thinking.trim().isEmpty && tools.isEmpty;

  ChatMessage copy() => ChatMessage(
        id: id,
        role: role,
        text: text,
        thinking: thinking,
        createdAt: createdAt,
        streaming: streaming,
        error: error,
        stopped: stopped,
        tools: tools,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'role': role.index,
        'text': text,
        if (thinking.isNotEmpty) 'thinking': thinking,
        'createdAt': createdAt.toIso8601String(),
        if (stopped) 'stopped': true,
        if (tools.isNotEmpty) 'tools': tools.map((ToolCall t) => t.toJson()).toList(),
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final int roleIdx = (json['role'] as int?) ?? 0;
    return ChatMessage(
      id: (json['id'] as String?) ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      role: Sender.values[roleIdx.clamp(0, Sender.values.length - 1)],
      text: (json['text'] as String?) ?? '',
      thinking: (json['thinking'] as String?) ?? '',
      createdAt:
          DateTime.tryParse((json['createdAt'] as String?) ?? '') ??
              DateTime.now(),
      stopped: (json['stopped'] as bool?) ?? false,
      tools: ((json['tools'] as List?) ?? <dynamic>[])
          .whereType<Map>()
          .map((Map m) => ToolCall.fromJson(m.cast<String, dynamic>()))
          .toList(),
    );
  }
}
