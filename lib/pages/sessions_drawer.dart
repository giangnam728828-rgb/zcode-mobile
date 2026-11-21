import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/conversation.dart';
import '../state/app_state.dart';
import 'settings_page.dart';

/// Conversation list used both as the phone drawer and as the wide-screen
/// sidebar. Grouping mirrors what you'd expect from a chat app: pinned first,
/// then today / yesterday / week / earlier.
class SessionsPanel extends StatefulWidget {
  const SessionsPanel({
    Key? key,
    required this.s,
    this.onPicked,
    this.showSettings = true,
  }) : super(key: key);

  final S s;
  final VoidCallback? onPicked;
  final bool showSettings;

  @override
  State<SessionsPanel> createState() => _SessionsPanelState();
}

class _SessionsPanelState extends State<SessionsPanel> {
  final TextEditingController _search = TextEditingController();
  String _query = '';
  bool _showArchived = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final AppState state = context.watch<AppState>();
    final S s = widget.s;

    final List<Conversation> visible = state.conversations.where((Conversation c) {
      if (c.archived != _showArchived) return false;
      if (_query.isEmpty) return true;
      final String q = _query.toLowerCase();
      if (c.previewTitle().toLowerCase().contains(q)) return true;
      return c.messages.any((dynamic m) => (m.text as String)
          .toLowerCase()
          .contains(q));
    }).toList();

    final List<Conversation> pinned =
        visible.where((Conversation c) => c.pinned).toList();
    final List<Conversation> rest =
        visible.where((Conversation c) => !c.pinned).toList();

    final DateTime now = DateTime.now();
    final List<Conversation> today = <Conversation>[];
    final List<Conversation> yesterday = <Conversation>[];
    final List<Conversation> week = <Conversation>[];
    final List<Conversation> older = <Conversation>[];
    for (final Conversation c in rest) {
      final int days = _dayDiff(now, c.updatedAt);
      if (days <= 0) {
        today.add(c);
      } else if (days == 1) {
        yesterday.add(c);
      } else if (days < 7) {
        week.add(c);
      } else {
        older.add(c);
      }
    }

    final int archivedCount =
        state.conversations.where((Conversation c) => c.archived).length;

    return Container(
      color: theme.brightness == Brightness.dark
          ? const Color(0xFF0A0C10)
          : const Color(0xFFFAFBFC),
      child: SafeArea(
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 8, 8),
              child: Row(
                children: <Widget>[
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: <Color>[
                          cs.primary,
                          cs.primary.withValues(alpha: 0.72),
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    alignment: Alignment.center,
                    child: const Icon(Icons.bolt_rounded,
                        size: 17, color: Colors.white),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          s.appName,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: cs.onSurface,
                            height: 1.2,
                          ),
                        ),
                        Text(
                          '${state.conversations.length} ${s.sessionsCount}',
                          style: TextStyle(
                            fontSize: 11,
                            color: cs.onSurface.withValues(alpha: 0.45),
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: s.newChat,
                    icon: const Icon(Icons.add_rounded, size: 21),
                    onPressed: () {
                      state.newConversation();
                      widget.onPicked?.call();
                    },
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
              child: SizedBox(
                height: 36,
                child: TextField(
                  controller: _search,
                  onChanged: (String v) => setState(() => _query = v.trim()),
                  style: const TextStyle(fontSize: 13.5),
                  decoration: InputDecoration(
                    hintText: s.searchHint,
                    isDense: true,
                    prefixIcon: Icon(Icons.search_rounded,
                        size: 17, color: cs.onSurface.withValues(alpha: 0.4)),
                    prefixIconConstraints:
                        const BoxConstraints(minWidth: 34, minHeight: 30),
                    contentPadding:
                        const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                    fillColor: theme.brightness == Brightness.dark
                        ? const Color(0xFF141821)
                        : Colors.white,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(
                        color: cs.onSurface.withValues(alpha: 0.10),
                      ),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(
                        color: cs.onSurface.withValues(alpha: 0.10),
                      ),
                    ),
                    suffixIcon: _query.isEmpty
                        ? null
                        : InkWell(
                            onTap: () {
                              _search.clear();
                              setState(() => _query = '');
                            },
                            child: Icon(Icons.close_rounded,
                                size: 15,
                                color: cs.onSurface.withValues(alpha: 0.4)),
                          ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: visible.isEmpty
                  ? Center(
                      child: Text(
                        s.noResults,
                        style: TextStyle(
                          fontSize: 13,
                          color: cs.onSurface.withValues(alpha: 0.38),
                        ),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.only(bottom: 12),
                      children: <Widget>[
                        if (pinned.isNotEmpty) ...<Widget>[
                          _groupHeader(s.pinned, cs),
                          ...pinned.map((Conversation c) => _tile(c, state, cs)),
                        ],
                        if (today.isNotEmpty) ...<Widget>[
                          _groupHeader(s.today, cs),
                          ...today.map((Conversation c) => _tile(c, state, cs)),
                        ],
                        if (yesterday.isNotEmpty) ...<Widget>[
                          _groupHeader(s.yesterday, cs),
                          ...yesterday
                              .map((Conversation c) => _tile(c, state, cs)),
                        ],
                        if (week.isNotEmpty) ...<Widget>[
                          _groupHeader(s.last7, cs),
                          ...week.map((Conversation c) => _tile(c, state, cs)),
                        ],
                        if (older.isNotEmpty) ...<Widget>[
                          _groupHeader(s.earlier, cs),
                          ...older.map((Conversation c) => _tile(c, state, cs)),
                        ],
                      ],
                    ),
            ),
            if (archivedCount > 0 || _showArchived)
              _archiveToggle(archivedCount, cs, s),
            if (widget.showSettings) _footer(cs, s),
          ],
        ),
      ),
    );
  }

  Widget _archiveToggle(int count, ColorScheme cs, S s) {
    return InkWell(
      onTap: () => setState(() => _showArchived = !_showArchived),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 6, 14, 6),
        child: Row(
          children: <Widget>[
            Icon(
              _showArchived
                  ? Icons.unarchive_outlined
                  : Icons.archive_outlined,
              size: 15,
              color: cs.onSurface.withValues(alpha: 0.45),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _showArchived ? s.hideArchived : '${s.archived} · $count',
                style: TextStyle(
                  fontSize: 12.5,
                  color: cs.onSurface.withValues(alpha: 0.5),
                ),
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                size: 16, color: cs.onSurface.withValues(alpha: 0.3)),
          ],
        ),
      ),
    );
  }

  Widget _footer(ColorScheme cs, S s) {
    return InkWell(
      onTap: () {
        widget.onPicked?.call();
        Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
        );
      },
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: cs.onSurface.withValues(alpha: 0.08)),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(18, 13, 14, 13),
        child: Row(
          children: <Widget>[
            Icon(Icons.settings_outlined,
                size: 18, color: cs.onSurface.withValues(alpha: 0.55)),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                s.settings,
                style: TextStyle(
                  fontSize: 13.5,
                  color: cs.onSurface.withValues(alpha: 0.7),
                ),
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                size: 16, color: cs.onSurface.withValues(alpha: 0.3)),
          ],
        ),
      ),
    );
  }

  Widget _groupHeader(String label, ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
          color: cs.onSurface.withValues(alpha: 0.38),
        ),
      ),
    );
  }

  Widget _tile(Conversation c, AppState state, ColorScheme cs) {
    final bool active = c.id == state.currentId;
    final String title =
        c.previewTitle().isEmpty ? widget.s.newChat : c.previewTitle();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Material(
        color: active ? cs.primary.withValues(alpha: 0.10) : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () {
            state.selectConversation(c.id);
            widget.onPicked?.call();
          },
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 9, 2, 9),
            child: Row(
              children: <Widget>[
                if (c.pinned)
                  Padding(
                    padding: const EdgeInsets.only(right: 5),
                    child: Icon(Icons.push_pin_rounded,
                        size: 12, color: cs.primary.withValues(alpha: 0.8)),
                  ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13.5,
                          height: 1.35,
                          fontWeight:
                              active ? FontWeight.w600 : FontWeight.w500,
                          color: active
                              ? cs.primary
                              : cs.onSurface.withValues(alpha: 0.86),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _subtitle(c),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.onSurface.withValues(alpha: 0.38),
                        ),
                      ),
                    ],
                  ),
                ),
                _menu(c, state, cs),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _menu(Conversation c, AppState state, ColorScheme cs) {
    return PopupMenuButton<String>(
      padding: EdgeInsets.zero,
      iconSize: 17,
      tooltip: '',
      icon: Icon(Icons.more_horiz_rounded,
          size: 17, color: cs.onSurface.withValues(alpha: 0.35)),
      onSelected: (String value) async {
        switch (value) {
          case 'pin':
            state.togglePin(c.id);
            break;
          case 'archive':
            state.toggleArchive(c.id);
            break;
          case 'rename':
            final String? name = await _askName(c);
            if (name != null) state.renameConversation(c.id, name);
            break;
          case 'duplicate':
            state.duplicateConversation(c.id);
            widget.onPicked?.call();
            break;
          case 'delete':
            final bool? yes = await _confirmDelete();
            if (yes == true) state.deleteConversation(c.id);
            break;
        }
      },
      itemBuilder: (BuildContext ctx) => <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          value: 'rename',
          child: _menuRow(Icons.edit_outlined, widget.s.rename),
        ),
        PopupMenuItem<String>(
          value: 'duplicate',
          child: _menuRow(Icons.copy_all_outlined,
              widget.s.isEnglish ? 'Duplicate' : '复制会话'),
        ),
        PopupMenuItem<String>(
          value: 'pin',
          child: _menuRow(
            c.pinned ? Icons.push_pin_outlined : Icons.push_pin_rounded,
            c.pinned ? widget.s.unpin : widget.s.pin,
          ),
        ),
        PopupMenuItem<String>(
          value: 'archive',
          child: _menuRow(
            c.archived ? Icons.unarchive_outlined : Icons.archive_outlined,
            c.archived ? widget.s.unarchive : widget.s.archive,
          ),
        ),
        PopupMenuItem<String>(
          value: 'delete',
          child: _menuRow(Icons.delete_outline_rounded, widget.s.delete),
        ),
      ],
    );
  }

  Widget _menuRow(IconData icon, String label) {
    return Row(
      children: <Widget>[
        Icon(icon, size: 17),
        const SizedBox(width: 10),
        Text(label, style: const TextStyle(fontSize: 13.5)),
      ],
    );
  }

  Future<String?> _askName(Conversation c) {
    final TextEditingController ctrl =
        TextEditingController(text: c.previewTitle());
    return showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(widget.s.rename,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 60,
          decoration: const InputDecoration(counterText: ''),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(widget.s.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: Text(widget.s.ok),
          ),
        ],
      ),
    );
  }

  Future<bool?> _confirmDelete() {
    return showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        content: Text(widget.s.deleteChatConfirm,
            style: const TextStyle(fontSize: 14.5, height: 1.5)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(widget.s.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(widget.s.delete),
          ),
        ],
      ),
    );
  }

  String _subtitle(Conversation c) {
    final int turns = c.userTurns;
    final String when = _relative(c.updatedAt);
    if (turns == 0) return when;
    return '$turns \u00b7 $when';
  }

  /// Compact, language-neutral stamps: 5m / 3h / 2d / 2026-11-20.
  String _relative(DateTime t) {
    final int mins = DateTime.now().difference(t).inMinutes;
    if (mins < 1) return 'now';
    if (mins < 60) return '${mins}m';
    final int hours = mins ~/ 60;
    if (hours < 24) return '${hours}h';
    final int days = hours ~/ 24;
    if (days < 30) return '${days}d';
    return '${t.year}-${_two(t.month)}-${_two(t.day)}';
  }

  static String _two(int v) => v < 10 ? '0$v' : '$v';
}

int _dayDiff(DateTime now, DateTime then) {
  final DateTime a = DateTime(now.year, now.month, now.day);
  final DateTime b = DateTime(then.year, then.month, then.day);
  return a.difference(b).inDays;
}
