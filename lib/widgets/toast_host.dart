import 'dart:async';

import 'package:flutter/widgets.dart';

import '../core/app_controller.dart';
import '../core/app_scope.dart';
import '../core/theme.dart';

/// Center-top transient toast, mirroring `.toast` (slide-down + fade, 1.5s).
class ToastHost extends StatefulWidget {
  const ToastHost({super.key});

  @override
  State<ToastHost> createState() => _ToastHostState();
}

class _ToastHostState extends State<ToastHost> {
  ValueNotifier<ToastEvent?>? _source;
  String _text = '';
  bool _visible = false;
  int _lastSeq = -1;
  Timer? _timer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final src = AppScope.of(context).toast;
    if (src != _source) {
      _source?.removeListener(_onToast);
      _source = src..addListener(_onToast);
    }
  }

  void _onToast() {
    final ev = _source?.value;
    if (ev == null || ev.seq == _lastSeq) return;
    _lastSeq = ev.seq;
    setState(() {
      _text = ev.text;
      _visible = true;
    });
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _visible = false);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _source?.removeListener(_onToast);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 120,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: Center(
          child: AnimatedSlide(
            duration: const Duration(milliseconds: 300),
            curve: kEase,
            offset: _visible ? Offset.zero : const Offset(0, -0.4),
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 300),
              opacity: _visible ? 1 : 0,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 26, vertical: 13),
                decoration: BoxDecoration(
                  color: const Color(0xE60A101E),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: const Color(0x29FFFFFF)),
                ),
                child: Text(
                  _text,
                  style: const TextStyle(
                    color: AppColors.text,
                    fontSize: 16,
                    fontFamilyFallback: kFontFallback,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
