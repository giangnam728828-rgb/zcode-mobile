import 'package:flutter/material.dart';

import '../agent/tools.dart';

/// Compact transcript card for one tool invocation: what ran, whether it
/// succeeded, and the output behind a tap.
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
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final bool dark = theme.brightness == Brightness.dark;
    final ToolCall c = widget.call;

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
            onTap: body.isEmpty
                ? null
                : () => setState(() => _open = !_open),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 9, 8, 9),
              child: Row(
                children: <Widget>[
                  Icon(icon, size: 15, color: tint),
                  const SizedBox(width: 7),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
                    child: Text(
                      c.title.replaceAll('\n', ' '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                        color: cs.onSurface.withOpacity(0.78),
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
              constraints: const BoxConstraints(maxHeight: 260),
              margin: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: dark ? const Color(0xFF0C1014) : const Color(0xFF10141A),
                borderRadius: BorderRadius.circular(8),
              ),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SingleChildScrollView(
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
    );
  }
}
