import 'package:flutter/foundation.dart';

/// Whether the floating dock is currently tucked away.
///
/// Lives outside [AppState] on purpose: this changes several times per scroll
/// gesture, and rebuilding the whole provider tree for it would be wasteful.
/// The conversation updates it; the shell listens.
class DockVisibility {
  DockVisibility._();

  static final ValueNotifier<bool> tucked = ValueNotifier<bool>(false);

  static void set(bool value) {
    if (tucked.value != value) tucked.value = value;
  }

  /// Called when the page goes away so a fresh screen never opens dockless.
  static void reset() => set(false);
}
