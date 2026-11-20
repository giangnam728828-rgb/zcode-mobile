import '../agent/tools.dart';
import 'attachment.dart';

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
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.compacted = false,
    List<ToolCall>? tools,
    List<Attachment>? attachments,
  })  : tools = tools ?? <ToolCall>[],
        attachments = attachments ?? <Attachment>[],
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

  /// Usage reported by the API for this turn.
  int inputTokens;
  int outputTokens;

  /// Older turns folded into the conversation summary are skipped on replay.
  bool compacted;

  /// Tool invocations that belong to this assistant turn.
  final List<ToolCall> tools;

  /// Files the user attached to this message.
  final List<Attachment> attachments;

  bool get isUser => role == Sender.user;
  bool get isEmpty =>
      text.trim().isEmpty && thinking.trim().isEmpty && tools.isEmpty;

  bool get hasImageAttachment =>
      attachments.any((Attachment a) => a.isImage);

  String get tokenLabel {
    if (inputTokens <= 0 && outputTokens <= 0) return '';
    String fmt(int n) =>
        n >= 1000 ? '${(n / 1000).toStringAsFixed(1)}k' : '$n';
    return '${fmt(inputTokens)} in · ${fmt(outputTokens)} out';
  }

  ChatMessage copy() => ChatMessage(
        id: id,
        role: role,
        text: text,
        thinking: thinking,
        createdAt: createdAt,
        streaming: streaming,
        error: error,
        stopped: stopped,
        inputTokens: inputTokens,
        outputTokens: outputTokens,
        compacted: compacted,
        tools: tools,
        attachments: attachments,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'role': role.index,
        'text': text,
        if (thinking.isNotEmpty) 'thinking': thinking,
        'createdAt': createdAt.toIso8601String(),
        if (stopped) 'stopped': true,
        if (inputTokens > 0) 'in': inputTokens,
        if (outputTokens > 0) 'out': outputTokens,
        if (compacted) 'compacted': true,
        if (tools.isNotEmpty)
          'tools': tools.map((ToolCall t) => t.toJson()).toList(),
        if (attachments.isNotEmpty)
          'attachments': attachments.map((Attachment a) => a.toJson()).toList(),
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final int roleIdx = (json['role'] as int?) ?? 0;
    return ChatMessage(
      id: (json['id'] as String?) ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      role: Sender.values[roleIdx.clamp(0, Sender.values.length - 1)],
      text: (json['text'] as String?) ?? '',
      thinking: (json['thinking'] as String?) ?? '',
      createdAt: DateTime.tryParse((json['createdAt'] as String?) ?? '') ??
          DateTime.now(),
      stopped: (json['stopped'] as bool?) ?? false,
      inputTokens: (json['in'] as int?) ?? 0,
      outputTokens: (json['out'] as int?) ?? 0,
      compacted: (json['compacted'] as bool?) ?? false,
      tools: ((json['tools'] as List?) ?? <dynamic>[])
          .whereType<Map>()
          .map((Map m) => ToolCall.fromJson(m.cast<String, dynamic>()))
          .toList(),
      attachments: ((json['attachments'] as List?) ?? <dynamic>[])
          .whereType<Map>()
          .map((Map m) => Attachment.fromJson(m.cast<String, dynamic>()))
          .toList(),
    );
  }
}
