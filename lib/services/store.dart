import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_config.dart';
import '../models/chat_message.dart';
import '../models/conversation.dart';

/// All persistence goes through SharedPreferences: one JSON blob for the
/// config, one for every conversation. Cheap enough for phone-sized data and
/// identical on web (localStorage), which is what makes the native build and
/// the web build share the same shape.
class Store {
  static const String _kConfig = 'zcode.config.v2';
  static const String _kConvos = 'zcode.conversations.v2';
  static const String _kLegacyMessages = 'zcode.messages.v1';

  static Future<AppConfig?> loadConfig() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(_kConfig);
    if (raw == null || raw.isEmpty) return null;
    try {
      return AppConfig.decode(raw);
    } catch (_) {
      return null;
    }
  }

  static Future<void> saveConfig(AppConfig config) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kConfig, config.encode());
  }

  static Future<List<Conversation>> loadConversations() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(_kConvos);
    if (raw != null && raw.isNotEmpty) {
      try {
        final List<dynamic> list = jsonDecode(raw) as List<dynamic>;
        return list
            .map((dynamic e) => Conversation.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {
        // fall through to legacy migration
      }
    }
    return _migrateLegacy(prefs);
  }

  /// v0.1 kept a single message list; fold it into one conversation.
  static Future<List<Conversation>> _migrateLegacy(
      SharedPreferences prefs) async {
    final String? raw = prefs.getString(_kLegacyMessages);
    if (raw == null || raw.isEmpty) return <Conversation>[];
    try {
      final List<dynamic> list = jsonDecode(raw) as List<dynamic>;
      if (list.isEmpty) return <Conversation>[];
      final Conversation c = Conversation(
        id: 'legacy',
        messages: list
            .map((dynamic e) => ChatMessage.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
      await prefs.remove(_kLegacyMessages);
      return <Conversation>[c];
    } catch (_) {
      return <Conversation>[];
    }
  }

  static Future<void> saveConversations(List<Conversation> items) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String raw =
        jsonEncode(items.map((Conversation c) => c.toJson()).toList());
    await prefs.setString(_kConvos, raw);
  }

  static Future<void> clearConversations() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kConvos);
  }

  static Future<void> clearAll() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kConfig);
    await prefs.remove(_kConvos);
    await prefs.remove(_kLegacyMessages);
  }

  // ---------------------------------------------------------------- workspace

  static const String _kWorkspace = 'zcode.workspace.path';
  static const String _kRecentWorkspaces = 'zcode.workspace.recent';

  /// Absolute path of the folder the agent works in, or null before the first
  /// run (the caller then asks the resolver for a suggestion).
  static Future<String?> loadWorkspace() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? path = prefs.getString(_kWorkspace);
    if (path == null || path.trim().isEmpty) return null;
    return path;
  }

  static Future<void> saveWorkspace(String path) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kWorkspace, path);
    final List<String> recent = prefs.getStringList(_kRecentWorkspaces) ??
        <String>[];
    recent.remove(path);
    recent.insert(0, path);
    while (recent.length > 8) {
      recent.removeLast();
    }
    await prefs.setStringList(_kRecentWorkspaces, recent);
  }

  static Future<List<String>> loadRecentWorkspaces() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_kRecentWorkspaces) ?? <String>[];
  }

  // --------------------------------------------------------------- automation

  static const String _kAutomation = 'zcode.automation.v1';

  static Future<String?> loadAutomation() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kAutomation);
  }

  static Future<void> saveAutomation(String raw) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kAutomation, raw);
  }

  // ------------------------------------------------------------------- flags

  /// One-shot flags written by the native side (currently only `boot`).
  static Future<bool> takeFlag(String key) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final bool value = prefs.getBool('zcode.flag.$key') ?? false;
    if (value) await prefs.remove('zcode.flag.$key');
    return value;
  }
}
