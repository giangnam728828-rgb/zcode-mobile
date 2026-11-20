import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../agent/tools.dart';

/// Compact transcript card for one tool invocation: what ran, whether it
/// succeeded, and the output behind a tap. `todo_write` gets a checklist
/// instead of a console, which is how the phone shows a plan.
class ToolCard extends StatefulWidget {
  const ToolCard({Key? key, required this.call}) : super(key: key);

  final ToolCall call;

  @override
  State<ToolCard> createState() => _ToolCardState();
}

class _ToolCardState extends State<ToolCard> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final ToolCall c = widget.call;
    if (c.name == 'todo_write' && c.todos.isNotEmpty) {
      return _PlanCard(call: c);
    }
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final bool dark = theme.brightness == Brightness.dark;

    final Color tint;
    final IconData icon;
    switch (c.status) {
      case ToolStatus.running:
        tint = cs.primary;
        icon = Icons.bolt_rounded;
        break;
      case ToolStatus.done:
        tint = const Color(0xFF12A67A);
        icon = Icons.check_circle_outline_rounded;
        break;
      case ToolStatus.failed:
        tint = const Color(0xFFD64545);
        icon = Icons.error_outline_rounded;
        break;
      case ToolStatus.denied:
        tint = cs.onSurface.withOpacity(0.45);
        icon = Icons.block_rounded;
        break;
      default:
        tint = cs.primary;
        icon = Icons.schedule_rounded;
    }

    final String label = c.isShell ? 'bash' : c.name;
    final String body = c.output.trim();
    final String detail = c.subtitle;

    return Container(
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF151A21) : const Color(0xFFF7F8FA),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: dark ? const Color(0xFF232A33) : const Color(0xFFE6E9EF),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          InkWell(
            onTap: body.isEmpty ? null : () => setState(() => _open = !_open),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 9, 8, 9),
              child: Row(
                children: <Widget>[
                  Icon(icon, size: 15, color: tint),
                  const SizedBox(width: 7),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: tint.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        color: tint,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          c.title.replaceAll('\n', ' '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            fontFamily: 'monospace',
                            color: cs.onSurface.withOpacity(0.8),
                          ),
                        ),
                        if (detail.isNotEmpty && !_open)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              detail,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 10.5,
                                height: 1.3,
                                color: cs.onSurface.withOpacity(0.38),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (c.duration != null && c.status != ToolStatus.running)
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Text(
                        _duration(c.duration!),
                        style: TextStyle(
                          fontSize: 10,
                          color: cs.onSurface.withOpacity(0.3),
                        ),
                      ),
                    ),
                  if (body.isNotEmpty)
                    Icon(
                      _open
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      size: 18,
                      color: cs.onSurface.withOpacity(0.35),
                    ),
                ],
              ),
            ),
          ),
          if (_open && body.isNotEmpty)
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 300),
              margin: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              padding: const EdgeInsets.fromLTRB(10, 6, 6, 8),
              decoration: BoxDecoration(
                color: dark ? const Color(0xFF0C1014) : const Color(0xFF10141A),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          '${body.split('\n').length} lines',
                          style: const TextStyle(
                            fontSize: 9.5,
                            color: Color(0xFF6B7684),
                          ),
                        ),
                      ),
                      InkWell(
                        onTap: () {
                          Clipboard.setData(ClipboardData(text: body));
                          ScaffoldMessenger.of(context)
                            ..hideCurrentSnackBar()
                            ..showSnackBar(const SnackBar(
                              content: Text('已复制输出'),
                              duration: Duration(milliseconds: 1100),
                            ));
                        },
                        borderRadius: BorderRadius.circular(6),
                        child: const Padding(
                          padding: EdgeInsets.all(5),
                          child: Icon(Icons.copy_rounded,
                              size: 13, color: Color(0xFF8A96A5)),
                        ),
                      ),
                    ],
                  ),
                  Flexible(
                    child: SingleChildScrollView(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Text(
                          body,
                          style: const TextStyle(
                            fontSize: 11.5,
                            height: 1.45,
                            fontFamily: 'monospace',
                            color: Color(0xFFD6DDE6),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static String _duration(Duration d) {
    if (d.inMilliseconds < 1000) return '${d.inMilliseconds}ms';
    if (d.inSeconds < 60) return '${(d.inMilliseconds / 1000).toStringAsFixed(1)}s';
    return '${d.inMinutes}m${d.inSeconds % 60}s';
  }
}

/// Renders the agent's checklist. This is the phone-sized version of a plan
/// panel: always visible, no interaction needed.
class _PlanCard extends StatelessWidget {
  const _PlanCard({required this.call});

  final ToolCall call;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final bool dark = theme.brightness == Brightness.dark;
    final List<TodoEntry> items = call.todos;
    final int done = items.where((TodoEntry t) => t.done).length;
    final double ratio = items.isEmpty ? 0 : done / items.length;

    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF141820) : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: dark ? const Color(0xFF242C37) : const Color(0xFFE4E8EF),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.checklist_rounded, size: 15, color: cs.primary),
              const SizedBox(width: 7),
              Text(
                '计划',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.2,
                  color: cs.onSurface.withOpacity(0.7),
                ),
              ),
              const Spacer(),
              Text(
                '$done/${items.length}',
                style: TextStyle(
                  fontSize: 10.5,
                  color: cs.onSurface.withOpacity(0.38),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 3,
              backgroundColor: cs.onSurface.withOpacity(0.07),
              valueColor: AlwaysStoppedAnimation<Color>(cs.primary),
            ),
          ),
          const SizedBox(height: 9),
          for (final TodoEntry t in items)
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Icon(
                      t.done
                          ? Icons.check_circle_rounded
                          : (t.active
                              ? Icons.radio_button_checked_rounded
                              : Icons.radio_button_unchecked_rounded),
                      size: 14,
                      color: t.done
                          ? const Color(0xFF12A67A)
                          : (t.active
                              ? cs.primary
                              : cs.onSurface.withOpacity(0.28)),
                    ),
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      t.content,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.45,
                        color: t.done
                            ? cs.onSurface.withOpacity(0.42)
                            : cs.onSurface.withOpacity(0.82),
                        decoration:
                            t.done ? TextDecoration.lineThrough : null,
                        decorationColor: cs.onSurface.withOpacity(0.3),
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
