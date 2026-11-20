import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/strings.dart';

/// The single-input composer. One send key: while a turn runs, text is queued
/// instead of blocked (same model as DSH Go), and the key becomes stop when
/// the box is empty.
class Composer extends StatefulWidget {
  const Composer({
    Key? key,
    required this.controller,
    required this.streaming,
    required this.queue,
    required this.s,
    required this.onSend,
    required this.onStop,
    required this.onSendNow,
    required this.onClearQueue,
  }) : super(key: key);

  final TextEditingController controller;
  final bool streaming;
  final List<String> queue;
  final S s;
  final ValueChanged<String> onSend;
  final VoidCallback onStop;
  final VoidCallback onSendNow;
  final VoidCallback onClearQueue;

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  final FocusNode _focus = FocusNode();
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onText);
    _hasText = widget.controller.text.trim().isNotEmpty;
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onText);
    _focus.dispose();
    super.dispose();
  }

  void _onText() {
    final bool next = widget.controller.text.trim().isNotEmpty;
    if (next != _hasText) setState(() => _hasText = next);
  }

  void _submit() {
    final String text = widget.controller.text.trim();
    if (text.isEmpty) return;
    widget.controller.clear();
    widget.onSend(text);
    if (!widget.streaming) _focus.requestFocus();
  }

  bool get _desktopLike =>
      kIsWeb || defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final bool dark = theme.brightness == Brightness.dark;
    final Color border = dark ? const Color(0xFF262D38) : const Color(0xFFE3E8F0);

    return Container(
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF101318) : Colors.white,
        border: Border(top: BorderSide(color: border)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (widget.queue.isNotEmpty) _queueBar(cs, dark),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  Expanded(
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 44),
                      decoration: BoxDecoration(
                        color: dark
                            ? const Color(0xFF171B21)
                            : const Color(0xFFF4F6F9),
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(
                          color: _focus.hasFocus
                              ? cs.primary.withOpacity(0.55)
                              : Colors.transparent,
                          width: 1.2,
                        ),
                      ),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 2),
                      child: Focus(
                        onKey: (FocusNode node, RawKeyEvent event) {
                          if (event is! RawKeyDownEvent) {
                            return KeyEventResult.ignored;
                          }
                          final bool enter = event.logicalKey ==
                                  LogicalKeyboardKey.enter ||
                              event.logicalKey ==
                                  LogicalKeyboardKey.numpadEnter;
                          if (!enter) return KeyEventResult.ignored;
                          final bool shift = HardwareKeyboard
                              .instance.logicalKeysPressed
                              .contains(LogicalKeyboardKey.shiftLeft) ||
                              HardwareKeyboard.instance.logicalKeysPressed
                                  .contains(LogicalKeyboardKey.shiftRight);
                          if (shift || !_desktopLike) {
                            return KeyEventResult.ignored;
                          }
                          _submit();
                          return KeyEventResult.handled;
                        },
                        child: TextField(
                          controller: widget.controller,
                          focusNode: _focus,
                          minLines: 1,
                          maxLines: 6,
                          keyboardType: TextInputType.multiline,
                          textInputAction: TextInputAction.newline,
                          style: TextStyle(
                            fontSize: 15,
                            height: 1.45,
                            color: cs.onSurface,
                          ),
                          decoration: InputDecoration(
                            hintText: widget.s.inputHint,
                            isDense: true,
                            filled: false,
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            contentPadding: const EdgeInsets.symmetric(
                                vertical: 11),
                            hintStyle: TextStyle(
                              color: cs.onSurface.withOpacity(0.38),
                              fontSize: 15,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _sendKey(cs, dark),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _queueBar(ColorScheme cs, bool dark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
      child: Row(
        children: <Widget>[
          Icon(Icons.schedule_send_outlined,
              size: 15, color: cs.primary.withOpacity(0.8)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '${widget.s.queued} · ${widget.queue.length}',
              style: TextStyle(
                fontSize: 12.5,
                color: cs.onSurface.withOpacity(0.62),
              ),
            ),
          ),
          _PillButton(
            label: widget.s.sendNow,
            onTap: widget.onSendNow,
            emphasized: true,
          ),
          const SizedBox(width: 6),
          _PillButton(
            label: widget.s.clearQueue,
            onTap: widget.onClearQueue,
            emphasized: false,
          ),
        ],
      ),
    );
  }

  Widget _sendKey(ColorScheme cs, bool dark) {
    final bool showStop = widget.streaming && !_hasText;
    final bool enabled = showStop || _hasText;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: enabled
            ? (showStop
                ? (dark ? const Color(0xFF2A3140) : const Color(0xFFEDF0F5))
                : cs.primary)
            : cs.onSurface.withOpacity(0.07),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: showStop
              ? widget.onStop
              : (_hasText ? _submit : null),
          child: Icon(
            showStop ? Icons.stop_rounded : Icons.arrow_upward_rounded,
            size: showStop ? 20 : 21,
            color: enabled
                ? (showStop ? cs.onSurface.withOpacity(0.75) : Colors.white)
                : cs.onSurface.withOpacity(0.3),
          ),
        ),
      ),
    );
  }
}

class _PillButton extends StatelessWidget {
  const _PillButton({
    required this.label,
    required this.onTap,
    required this.emphasized,
  });

  final String label;
  final VoidCallback onTap;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: emphasized ? cs.primary.withOpacity(0.12) : null,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: emphasized
                ? cs.primary.withOpacity(0.35)
                : cs.onSurface.withOpacity(0.16),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: emphasized ? cs.primary : cs.onSurface.withOpacity(0.6),
          ),
        ),
      ),
    );
  }
}
