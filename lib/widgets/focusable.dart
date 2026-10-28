import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../core/theme.dart';

/// Keys that "activate" (OK / DPAD-center / Enter / Space) a focused element.
const Map<ShortcutActivator, Intent> _activateShortcuts = {
  SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
  SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
  SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
  SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
  SingleActivator(LogicalKeyboardKey.gameButtonA): ActivateIntent(),
};

/// A generic DPAD-focusable element.
///
/// Directional (arrow-key) movement is handled by Flutter's default traversal
/// policy, which also keeps the focused node visible inside scroll views —
/// mirroring the geometric spatial-navigation in the reference HTML.
class Focusable extends StatefulWidget {
  const Focusable({
    super.key,
    required this.builder,
    this.onPressed,
    this.onFocused,
    this.autofocus = false,
    this.ensureVisibleAlignment,
    this.focusNode,
    this.onKeyEvent,
  });

  /// Builds the child; [focused] drives the `.on` visual state.
  final Widget Function(BuildContext context, bool focused) builder;
  final VoidCallback? onPressed;
  final VoidCallback? onFocused;
  final bool autofocus;

  /// If set, center/scroll the element to this alignment when focused
  /// (0.0 = start, 0.5 = center, 1.0 = end). Null = rely on default traversal.
  final double? ensureVisibleAlignment;
  final FocusNode? focusNode;

  /// Optional raw key hook. Fires while this element is focused, BEFORE
  /// Flutter converts arrow keys into directional traversal — so returning
  /// [KeyEventResult.handled] lets a caller override default D-pad movement
  /// (e.g. player → 播放设置 on Right).
  final KeyEventResult Function(FocusNode node, KeyEvent event)? onKeyEvent;

  @override
  State<Focusable> createState() => _FocusableState();
}

class _FocusableState extends State<Focusable> {
  FocusNode? _internal;
  bool _focused = false;

  FocusNode get _node => widget.focusNode ?? (_internal ??= FocusNode());

  void _handleFocusChange(bool focused) {
    if (focused == _focused) return;
    setState(() => _focused = focused);
    if (focused) {
      widget.onFocused?.call();
      final align = widget.ensureVisibleAlignment;
      if (align != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          Scrollable.ensureVisible(
            context,
            alignment: align,
            duration: const Duration(milliseconds: 320),
            curve: kEase,
            alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
          );
        });
      }
    }
  }

  @override
  void dispose() {
    _internal?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final detector = FocusableActionDetector(
      focusNode: _node,
      autofocus: widget.autofocus,
      mouseCursor: SystemMouseCursors.click,
      shortcuts: _activateShortcuts,
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onPressed?.call();
            return null;
          },
        ),
      },
      onFocusChange: _handleFocusChange,
      // Hover focuses the element too (matches the HTML mouseover behaviour).
      onShowHoverHighlight: (hovering) {
        if (hovering && !_node.hasFocus) _node.requestFocus();
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          _node.requestFocus();
          widget.onPressed?.call();
        },
        child: widget.builder(context, _focused),
      ),
    );
    if (widget.onKeyEvent == null) return detector;
    // A non-focusable wrapper that sits above the detector in the focus chain,
    // so it sees raw key events while the detector is focused — ahead of the
    // WidgetsApp shortcuts that would otherwise turn arrows into traversal.
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: widget.onKeyEvent,
      child: detector,
    );
  }
}
