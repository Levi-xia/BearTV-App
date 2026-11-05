import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_scope.dart';
import '../core/theme.dart';
import 'focus_fx.dart';
import 'focusable.dart';

/// Shows a text-entry modal and returns the entered text (or null if cancelled).
///
/// Which modal depends on the "搜索输入法/系统输入法" setting:
/// - ON  → a native [EditableText] that pops the device's own keyboard, so users
///   can type with the IME they already know (incl. 中文).
/// - OFF → a D-pad-friendly on-screen keyboard, since a focused EditableText on
///   Android TV traps the remote's directional keys (arrows move the caret).
///
/// [confirmLabel] lets callers name the primary action (e.g. 导入), so no extra
/// confirmation dialog is needed on top of the keyboard.
Future<String?> showOnScreenKeyboard(
  BuildContext context, {
  required String title,
  String initial = '',
  bool obscure = false,
  String hint = '',
  String confirmLabel = '完成',
}) {
  final systemIme = AppScope.read(context).searchUseSystemIme;
  return showDialog<String>(
    context: context,
    barrierColor: const Color(0xCC03060E),
    builder: (_) => systemIme
        ? _NativeInputDialog(
            title: title,
            initial: initial,
            obscure: obscure,
            hint: hint,
            confirmLabel: confirmLabel)
        : _OskDialog(
            title: title,
            initial: initial,
            obscure: obscure,
            hint: hint,
            confirmLabel: confirmLabel),
  );
}

/// Shared card chrome for both dialogs.
Widget _card({required double width, required Widget child}) {
  return Center(
    child: Material(
      type: MaterialType.transparency,
      child: Container(
        width: width,
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          color: AppColors.cardBg,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppColors.hairline),
        ),
        child: child,
      ),
    ),
  );
}

Widget _title(String text) => Text(text,
    style: const TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w700,
        color: AppColors.text,
        fontFamilyFallback: kFontFallback));

/// System-IME path. A permanently-focused [EditableText] would trap the remote's
/// D-pad (arrows move the caret, and you can't reach the buttons once done), so
/// we mirror the search page: a focusable faux box that turns into a real field
/// only while typing. Submitting or dismissing the keyboard drops focus back to
/// the box, from where the D-pad reaches 取消/完成.
class _NativeInputDialog extends StatefulWidget {
  const _NativeInputDialog(
      {required this.title,
      required this.initial,
      required this.obscure,
      required this.hint,
      required this.confirmLabel});
  final String title;
  final String initial;
  final bool obscure;
  final String hint;
  final String confirmLabel;

  @override
  State<_NativeInputDialog> createState() => _NativeInputDialogState();
}

class _NativeInputDialogState extends State<_NativeInputDialog>
    with WidgetsBindingObserver {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.initial);
  final FocusNode _fieldFocus = FocusNode();
  final FocusNode _boxFocus = FocusNode();
  bool _editing = false;
  // Whether the system keyboard has been raised this edit (see didChangeMetrics).
  bool _kbWasUp = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // While the system keyboard is up the remote's keys go to the IME's own
    // window; once Back dismisses it the EditableText keeps app focus but the
    // arrows reach us. Give the field a key handler so any directional / Back
    // press breaks out of edit mode instead of just moving the caret (which
    // left the user trapped, unable to reach 取消/完成 or re-open the keyboard).
    _fieldFocus.onKeyEvent = _onFieldKey;
    _fieldFocus.addListener(() {
      // Some IMEs do drop focus on dismiss — honour that path too.
      if (!_fieldFocus.hasFocus && _editing) _endEdit();
    });
    // Land on the faux box so it's navigable from the start; OK begins typing.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _boxFocus.requestFocus();
    });
  }

  KeyEventResult _onFieldKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final k = event.logicalKey;
    if (k == LogicalKeyboardKey.arrowUp ||
        k == LogicalKeyboardKey.arrowDown ||
        k == LogicalKeyboardKey.arrowLeft ||
        k == LogicalKeyboardKey.arrowRight ||
        k == LogicalKeyboardKey.escape ||
        k == LogicalKeyboardKey.goBack ||
        k == LogicalKeyboardKey.browserBack) {
      _endEdit();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ctrl.dispose();
    _fieldFocus.dispose();
    _boxFocus.dispose();
    super.dispose();
  }

  // On Android TV, Back closes the system keyboard but leaves the EditableText
  // focused, so the focus listener never fires and the field keeps trapping the
  // D-pad. Detect the dismissal from the keyboard insets collapsing to 0 after
  // having been raised, and drop back to the faux box so 取消/完成 are reachable.
  @override
  void didChangeMetrics() {
    if (!mounted) return;
    final kb = View.of(context).viewInsets.bottom;
    if (kb > 0) {
      _kbWasUp = true;
    } else if (_kbWasUp && _editing) {
      _endEdit();
    }
  }

  void _beginEdit() {
    setState(() => _editing = true);
    _kbWasUp = false;
    // Focus once mounted → pops the system keyboard.
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _fieldFocus.requestFocus());
  }

  // Finish typing without closing the dialog: return to the faux box so the user
  // can then choose 取消/完成 with the D-pad. Idempotent — safe to call from the
  // focus listener and the insets watcher both.
  void _endEdit() {
    if (!_editing) return;
    _fieldFocus.unfocus();
    setState(() => _editing = false);
    _kbWasUp = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _boxFocus.requestFocus();
    });
  }

  void _done() => Navigator.of(context).pop(_ctrl.text);

  @override
  Widget build(BuildContext context) {
    // While editing, a Back press may arrive as a route pop — intercept it so it
    // exits edit mode instead of dismissing the whole dialog.
    return PopScope(
      canPop: !_editing,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _editing) _endEdit();
      },
      child: _card(
        width: 720,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _title(widget.title),
            const SizedBox(height: 16),
            _editing ? _field() : _fauxBox(),
            if (widget.hint.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(widget.hint,
                  style: const TextStyle(
                      fontSize: 14,
                      color: AppColors.textDim,
                      fontFamilyFallback: kFontFallback)),
            ],
            const SizedBox(height: 22),
            Row(
              children: [
                Expanded(
                    child: _OskKey(
                        label: '取消',
                        wide: true,
                        onPressed: () => Navigator.of(context).pop())),
                const SizedBox(width: 12),
                Expanded(
                    child: _OskKey(
                        label: widget.confirmLabel,
                        wide: true,
                        primary: true,
                        onPressed: _done)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _fauxBox() {
    final text = _ctrl.text;
    final display =
        text.isEmpty ? '' : (widget.obscure ? '•' * text.length : text);
    return Focusable(
      focusNode: _boxFocus,
      autofocus: true,
      onPressed: _beginEdit,
      builder: (context, focused) {
        return Container(
          height: 58,
          width: double.infinity,
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          decoration: BoxDecoration(
            color: AppColors.glass,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
                color: focused ? AppColors.accent : AppColors.glassBorder,
                width: focused ? 2 : 1),
          ),
          child: Text(
            display.isEmpty
                ? (widget.hint.isEmpty ? '按「确定」呼出键盘输入' : widget.hint)
                : display,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 20,
              color: display.isEmpty ? AppColors.textDim : AppColors.text,
              fontFamilyFallback: kFontFallback,
            ),
          ),
        );
      },
    );
  }

  Widget _field() {
    return Container(
      height: 58,
      width: double.infinity,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      decoration: BoxDecoration(
        color: AppColors.glass,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.accent, width: 2),
      ),
      child: EditableText(
        controller: _ctrl,
        focusNode: _fieldFocus,
        maxLines: 1,
        obscureText: widget.obscure,
        keyboardType: TextInputType.text,
        textInputAction: TextInputAction.done,
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => _endEdit(),
        cursorColor: AppColors.accent,
        backgroundCursorColor: AppColors.textDim,
        style: const TextStyle(
          fontSize: 20,
          color: AppColors.text,
          fontFamilyFallback: kFontFallback,
        ),
      ),
    );
  }
}

/// Built-in on-screen keyboard path (system IME off).
class _OskDialog extends StatefulWidget {
  const _OskDialog(
      {required this.title,
      required this.initial,
      required this.obscure,
      required this.hint,
      required this.confirmLabel});
  final String title;
  final String initial;
  final bool obscure;
  final String hint;
  final String confirmLabel;

  @override
  State<_OskDialog> createState() => _OskDialogState();
}

class _OskDialogState extends State<_OskDialog> {
  late String _text = widget.initial;
  bool _shift = false;

  static const _rows = ['1234567890', 'qwertyuiop', 'asdfghjkl', 'zxcvbnm'];
  static const _symbols = '.-_:/?=&@+%#,';

  void _type(String c) => setState(() => _text += _shift ? c.toUpperCase() : c);
  void _backspace() {
    if (_text.isNotEmpty) {
      setState(() => _text = _text.substring(0, _text.length - 1));
    }
  }

  // A non-wrapping, centred row of fixed-width keys — never reflows regardless
  // of dialog width, unlike the old Wrap.
  Widget _charRow(String chars, {String? autofocusChar}) {
    final list = chars.split('');
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < list.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            _OskKey(
              label: _shift ? list[i].toUpperCase() : list[i],
              autofocus: autofocusChar != null && list[i] == autofocusChar,
              onPressed: () => _type(list[i]),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final display = _text.isEmpty
        ? widget.hint
        : (widget.obscure ? '•' * _text.length : _text);
    return _card(
      width: 900,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _title(widget.title),
          const SizedBox(height: 16),
          Container(
            height: 58,
            width: double.infinity,
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            decoration: BoxDecoration(
              color: AppColors.glass,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.glassBorder),
            ),
            child: Text(
              display,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 20,
                color: _text.isEmpty ? AppColors.textDim : AppColors.text,
                fontFamilyFallback: kFontFallback,
              ),
            ),
          ),
          const SizedBox(height: 18),
          _charRow(_rows[0], autofocusChar: '1'),
          _charRow(_rows[1]),
          _charRow(_rows[2]),
          _charRow(_rows[3]),
          _charRow(_symbols),
          const SizedBox(height: 4),
          // Actions on a single horizontal row (equal-width, never stacked).
          Row(
            children: [
              Expanded(
                  child: _OskKey(
                      label: _shift ? '⇧ 大写' : '⇧ 小写',
                      wide: true,
                      onPressed: () => setState(() => _shift = !_shift))),
              const SizedBox(width: 10),
              Expanded(
                  child: _OskKey(
                      label: '空格', wide: true, onPressed: () => _type(' '))),
              const SizedBox(width: 10),
              Expanded(
                  child: _OskKey(
                      label: '⌫ 退格', wide: true, onPressed: _backspace)),
              const SizedBox(width: 10),
              Expanded(
                  child: _OskKey(
                      label: '清空',
                      wide: true,
                      onPressed: () => setState(() => _text = ''))),
              const SizedBox(width: 10),
              Expanded(
                  child: _OskKey(
                      label: '取消',
                      wide: true,
                      onPressed: () => Navigator.of(context).pop())),
              const SizedBox(width: 10),
              Expanded(
                  child: _OskKey(
                      label: widget.confirmLabel,
                      wide: true,
                      primary: true,
                      onPressed: () => Navigator.of(context).pop(_text))),
            ],
          ),
        ],
      ),
    );
  }
}

class _OskKey extends StatelessWidget {
  const _OskKey(
      {required this.label,
      required this.onPressed,
      this.wide = false,
      this.primary = false,
      this.autofocus = false});
  final String label;
  final VoidCallback onPressed;
  final bool wide;
  final bool primary;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return Focusable(
      autofocus: autofocus,
      onPressed: onPressed,
      builder: (context, focused) {
        final base = BoxDecoration(
          gradient: primary
              ? const LinearGradient(
                  colors: [Color(0x4D4EA8FF), Color(0x2E00E5FF)])
              : null,
          color: primary ? null : AppColors.glass,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: primary ? const Color(0x6600E5FF) : AppColors.hairline),
        );
        return FocusFx.scale(
          focused,
          Container(
            width: wide ? null : 52,
            height: 52,
            constraints: wide ? const BoxConstraints(minWidth: 64) : null,
            alignment: Alignment.center,
            padding: wide ? const EdgeInsets.symmetric(horizontal: 12) : null,
            decoration: focused ? FocusFx.pill(focused, radius: 12) : base,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.clip,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: focused ? AppColors.focusInk : AppColors.text,
                fontFamilyFallback: kFontFallback,
              ),
            ),
          ),
        );
      },
    );
  }
}
