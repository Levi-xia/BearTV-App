import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../core/app_controller.dart';
import '../core/app_scope.dart';
import '../core/theme.dart';
import '../data/pinyin_ime.dart';
import '../data/vod/cms_models.dart';
import '../widgets/banded_focus.dart';
import '../widgets/focus_fx.dart';
import '../widgets/focusable.dart';
import '../widgets/masonry.dart';
import '../widgets/net_image.dart';

/// TMDB search page: a D-pad on-screen keyboard on the left, and a poster grid
/// of results on the right. Result cards reuse [MasonryCard] → `openTitle`, so a
/// tap runs the exact same CMS-resolve/play flow as a category card.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  String _q = ''; // committed query text
  String _py = ''; // uncommitted pinyin buffer (中文 mode only)
  bool _zh = true; // 中文 (pinyin) vs 英文/数字 direct input
  bool _shift = false; // 英文大写 (English uppercase) when true
  PinyinIme? _ime;
  List<String> _cands = const [];
  // First keyboard key's node, so we can claim focus for it on entry (autofocus
  // alone loses to the header 🔍 that opened the page).
  final FocusNode _firstKey = FocusNode();

  // The two halves of the page are separate D-pad lanes: a vertical press on the
  // keypad walks the keypad's own rows instead of jumping into the poster grid
  // beside it (and vice versa).
  final Object _inputLane = Object();
  final Object _resultsLane = Object();

  @override
  void initState() {
    super.initState();
    final app = AppScope.read(context);
    // Returning from the player (Back): the controller kept the last query +
    // results, so restore the committed query text into the box to match the
    // grid that's still showing. A fresh entry via the header 🔍 cleared these,
    // so this is simply '' then. Consume the return-focus hint either way.
    _q = app.searchQuery;
    app.pendingSearchFocusKey = null;
    // Only spin up the offline pinyin dictionary when the built-in keyboard is
    // actually in use; with the system IME on it's dead weight on a low-end box.
    if (!app.searchUseSystemIme) {
      PinyinIme.load().then((ime) {
        if (mounted) setState(() => _ime = ime);
      });
      // Land focus on the first input key rather than leaving it on the header
      // 🔍 (which held focus when it opened this page).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _firstKey.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _firstKey.dispose();
    super.dispose();
  }

  static bool _isLetter(String c) {
    if (c.length != 1) return false;
    final u = c.codeUnitAt(0);
    return (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A);
  }

  void _recompute() {
    _cands = (_zh && _ime != null) ? _ime!.candidates(_py) : const [];
  }

  void _onChar(String c) {
    setState(() {
      if (_zh && _ime != null && _isLetter(c)) {
        _py += c.toLowerCase();
        _recompute();
      } else {
        _q += c;
      }
    });
  }

  void _pick(String cand) {
    setState(() {
      _q += cand;
      _py = '';
      _recompute();
    });
  }

  // Space commits the first candidate when composing (standard IME behaviour),
  // otherwise inserts a literal space.
  void _space() {
    setState(() {
      if (_zh && _py.isNotEmpty && _cands.isNotEmpty) {
        _q += _cands.first;
        _py = '';
        _recompute();
      } else {
        _q += ' ';
      }
    });
  }

  // Backspace peels the pinyin buffer first, then the committed query.
  void _backspace() {
    setState(() {
      if (_zh && _py.isNotEmpty) {
        _py = _py.substring(0, _py.length - 1);
        _recompute();
      } else if (_q.isNotEmpty) {
        _q = _q.substring(0, _q.length - 1);
      }
    });
  }

  void _clear() => setState(() {
        _q = '';
        _py = '';
        _recompute();
      });

  void _toggleMode() => setState(() {
        _zh = !_zh;
        _py = '';
        _recompute();
      });

  void _toggleCase() => setState(() => _shift = !_shift);

  void _submit() => AppScope.read(context).search(_q);

  // Re-run a tapped search-history term: reflect it in the query box, then
  // search (which also floats it back to the front of the history list).
  void _pickHistory(String q) {
    setState(() {
      _q = q;
      _py = '';
      _recompute();
    });
    AppScope.read(context).search(q);
  }

  @override
  Widget build(BuildContext context) {
    final systemIme = AppScope.of(context).searchUseSystemIme;
    return FocusTraversalGroup(
      // Round-by-round D-pad movement: Up/Down takes the nearest row, then the
      // nearest element inside it (see [BandedTraversalPolicy]). Without it the
      // keypad's top-right key sent Up straight to the header 🔍, skipping the
      // history strip above it, because nothing overlapped that column.
      policy: const BandedTraversalPolicy(),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppDims.pad, 176, AppDims.pad, 40),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Left = input panel: either the device's system IME (native field +
            // system keyboard) or the built-in offline pinyin keyboard. The right
            // result grid gets the larger share for a nicer poster layout.
            Expanded(
              flex: 5,
              child: FocusLane(
                id: _inputLane,
                child: systemIme
                    ? const _SystemInputPanel()
                    : _KeyboardPanel(
                        query: _q,
                        pinyin: _py,
                        zh: _zh,
                        // Letters are uppercase only in English mode with Shift
                        // on; pinyin always composes lowercase.
                        upper: !_zh && _shift,
                        imeReady: _ime != null,
                        candidates: _cands,
                        onChar: _onChar,
                        onSpace: _space,
                        onBackspace: _backspace,
                        onClear: _clear,
                        onSearch: _submit,
                        onToggleMode: _toggleMode,
                        onToggleCase: _toggleCase,
                        onPick: _pick,
                        onHistoryPick: _pickHistory,
                        firstKeyNode: _firstKey,
                      ),
              ),
            ),
            const SizedBox(width: 40),
            Expanded(
              flex: 6,
              child: FocusLane(id: _resultsLane, child: const _Results()),
            ),
          ],
        ),
      ),
    );
  }
}

/// Compact segmented 结果来源 switch shown inline after the "搜索" title:
/// TMDB 匹配 (metadata + title-match) vs. 资源直搜 (search the CMS sources
/// directly). Smaller than a full chip row so it tucks beside the heading.
/// Picking one re-runs the current query via [AppController.setSearchMode].
class _ModeToggle extends StatelessWidget {
  const _ModeToggle();

  @override
  Widget build(BuildContext context) {
    final mode = AppScope.of(context).searchMode;
    final app = AppScope.read(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ModeChip(
          label: 'TMDB 匹配',
          selected: mode == SearchMode.tmdb,
          onPressed: () => app.setSearchMode(SearchMode.tmdb),
        ),
        const SizedBox(width: 8),
        _ModeChip(
          label: '资源直搜',
          selected: mode == SearchMode.cms,
          onPressed: () => app.setSearchMode(SearchMode.cms),
        ),
      ],
    );
  }
}

/// A single compact mode chip (smaller padding/font than the standard chip).
class _ModeChip extends StatelessWidget {
  const _ModeChip({
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Focusable(
      onPressed: onPressed,
      builder: (context, focused) {
        final base = BoxDecoration(
          color: selected ? const Color(0x294EA8FF) : AppColors.glass,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected ? const Color(0x994EA8FF) : AppColors.hairline,
            width: 1.5,
          ),
        );
        return FocusFx.scale(
          focused,
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: focused ? FocusFx.pill(focused, radius: 999) : base,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: focused
                    ? AppColors.focusInk
                    : (selected ? AppColors.text : AppColors.textDim),
                fontWeight: FontWeight.w600,
                fontFamilyFallback: kFontFallback,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The "搜索" page heading with the compact [_ModeToggle] tucked in beside it,
/// shared by both input panels so the toggle sits in the same spot regardless
/// of input method.
class _TitleRow extends StatelessWidget {
  const _TitleRow();

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: const [
        Text('搜索',
            style: TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.w700,
                color: AppColors.text,
                fontFamilyFallback: kFontFallback)),
        SizedBox(width: 18),
        _ModeToggle(),
      ],
    );
  }
}

/// System-IME input panel: a D-pad-focusable faux input box that, on OK, turns
/// into a real [EditableText] and requests focus — which pops the device's own
/// on-screen keyboard (so users get their familiar 中文 IME). Kept as a faux box
/// until then because a permanently-focused EditableText traps the remote's
/// arrow keys (they move the caret, not focus). Submitting or dismissing the
/// keyboard drops back to the faux box so navigation works again.
class _SystemInputPanel extends StatefulWidget {
  const _SystemInputPanel();

  @override
  State<_SystemInputPanel> createState() => _SystemInputPanelState();
}

class _SystemInputPanelState extends State<_SystemInputPanel>
    with WidgetsBindingObserver {
  final TextEditingController _ctrl = TextEditingController();
  final FocusNode _fieldFocus = FocusNode();
  final FocusNode _boxFocus = FocusNode();
  bool _editing = false;
  // Tracks whether the system keyboard has been raised this edit, so a Back
  // press (which collapses the insets) can be detected as a dismissal.
  bool _kbWasUp = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Returning from the player: restore the last committed query into the
    // native field so it matches the preserved result grid.
    _ctrl.text = AppScope.read(context).searchQuery;
    // The system keyboard opens in its own window, so while it's up the remote's
    // keys go to the IME, not us. When Back dismisses it the EditableText keeps
    // app focus but the arrows now reach us — so give the field its own key
    // handler that breaks out of edit mode on any directional / Back press
    // (otherwise the arrows just move the caret and the user is trapped).
    _fieldFocus.onKeyEvent = _onFieldKey;
    _fieldFocus.addListener(() {
      // Some IMEs do drop focus on dismiss — honour that path too.
      if (!_fieldFocus.hasFocus && _editing) _exitEditing();
    });
    // Land focus on the input box on entry so OK starts typing right away.
    // `autofocus` alone loses to whatever held focus before (e.g. the header 🔍
    // that opened this page), so claim it explicitly once mounted.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _boxFocus.requestFocus();
    });
  }

  // Runs only once the IME window is gone and the field still holds app focus.
  // Any directional key or Back leaves edit mode and hands focus back to the
  // faux box (Down then reaches the buttons; OK there re-opens the keyboard).
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
      _exitEditing();
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

  // On Android TV, Back closes the system keyboard but does NOT unfocus the
  // EditableText — so the focus listener never fires and the field keeps
  // trapping the D-pad. Watch the keyboard insets instead: once it has been up
  // and then collapses back to 0 while editing, treat that as a dismissal and
  // drop back to the faux box so the buttons become reachable again.
  @override
  void didChangeMetrics() {
    if (!mounted) return;
    final kb = View.of(context).viewInsets.bottom;
    if (kb > 0) {
      _kbWasUp = true;
    } else if (_kbWasUp && _editing) {
      _kbWasUp = false;
      _exitEditing();
    }
  }

  void _beginEdit() {
    setState(() => _editing = true);
    _kbWasUp = false;
    // Focus after the EditableText is mounted → summons the system keyboard.
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _fieldFocus.requestFocus());
  }

  // Leave edit mode and hand D-pad focus back to the faux box. Idempotent, so
  // both the focus listener and the insets watcher can call it safely.
  void _exitEditing() {
    if (!_editing) return;
    setState(() => _editing = false);
    _kbWasUp = false;
    _fieldFocus.unfocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _boxFocus.requestFocus();
    });
  }

  void _submit() {
    _fieldFocus.unfocus();
    setState(() => _editing = false);
    _kbWasUp = false;
    AppScope.read(context).search(_ctrl.text);
  }

  @override
  Widget build(BuildContext context) {
    // While editing, Back may reach us as a route pop instead of a key event
    // (platform-dependent). Intercept it here so it exits edit mode rather than
    // closing the whole search page.
    return PopScope(
      canPop: !_editing,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _editing) _exitEditing();
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _TitleRow(),
          const SizedBox(height: 16),
          _editing ? _field() : _fauxBox(),
          const SizedBox(height: 14),
          _SearchHistory(onPick: (q) {
            _ctrl.text = q;
            AppScope.read(context).search(q);
          }),
          const _Hint('选中输入框按「确定」呼出系统键盘；输入后按键盘上的完成/搜索键或下方「搜索」'),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                  child: _Key(
                      label: '搜索',
                      wide: true,
                      primary: true,
                      onPressed: _submit)),
              const SizedBox(width: 8),
              Expanded(
                  child: _Key(
                      label: '清空',
                      wide: true,
                      onPressed: () {
                        _ctrl.clear();
                        setState(() {});
                      })),
            ],
          ),
        ],
      ),
    );
  }

  Widget _fauxBox() {
    final text = _ctrl.text;
    return Focusable(
      focusNode: _boxFocus,
      autofocus: true,
      onPressed: _beginEdit,
      builder: (context, focused) {
        return Container(
          height: 58,
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
            text.isEmpty ? '输入片名 / 关键词（按确定呼出键盘）' : text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 20,
              color: text.isEmpty ? AppColors.textDim : AppColors.text,
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
        keyboardType: TextInputType.text,
        textInputAction: TextInputAction.search,
        onSubmitted: (_) => _submit(),
        onChanged: (_) => setState(() {}),
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

class _KeyboardPanel extends StatelessWidget {
  const _KeyboardPanel({
    required this.query,
    required this.pinyin,
    required this.zh,
    required this.upper,
    required this.imeReady,
    required this.candidates,
    required this.onChar,
    required this.onSpace,
    required this.onBackspace,
    required this.onClear,
    required this.onSearch,
    required this.onToggleMode,
    required this.onToggleCase,
    required this.onPick,
    required this.onHistoryPick,
    required this.firstKeyNode,
  });

  final String query;
  final String pinyin;
  final bool zh;
  final bool upper;
  final bool imeReady;
  final List<String> candidates;
  final void Function(String c) onChar;
  final VoidCallback onSpace;
  final VoidCallback onBackspace;
  final VoidCallback onClear;
  final VoidCallback onSearch;
  final VoidCallback onToggleMode;
  final VoidCallback onToggleCase;
  final void Function(String cand) onPick;
  final void Function(String query) onHistoryPick;

  /// Focus node for the first key ('1'), owned by the parent so it can claim
  /// focus on entry instead of leaving it on the header 🔍.
  final FocusNode firstKeyNode;

  static const _rows = ['1234567890', 'QWERTYUIOP', 'ASDFGHJKL', 'ZXCVBNM'];

  @override
  Widget build(BuildContext context) {
    // The title + query preview + composing bar are PINNED at the top; only the
    // keys scroll. Otherwise focusing a lower key auto-scrolled the query box
    // off-screen ("搜索框不见了").
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _TitleRow(),
        const SizedBox(height: 16),
        Container(
          height: 58,
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          decoration: BoxDecoration(
            color: AppColors.glass,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.glassBorder),
          ),
          child: Text(
            query.isEmpty ? '输入片名 / 关键词' : query,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 20,
              color: query.isEmpty ? AppColors.textDim : AppColors.text,
              fontFamilyFallback: kFontFallback,
            ),
          ),
        ),
        const SizedBox(height: 10),
        _SearchHistory(onPick: onHistoryPick),
        _ComposingBar(
          zh: zh,
          imeReady: imeReady,
          pinyin: pinyin,
          candidates: candidates,
          onPick: onPick,
        ),
        const SizedBox(height: 12),
        // Keys use Row+Expanded (never a Wrap), so each row always stays on a
        // single line and shares the panel width — the letters can no longer
        // wrap when the result grid takes its share of the row ("键位换行").
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var r = 0; r < _rows.length; r++) ...[
                  _KeyRow(
                    chars: _rows[r].split(''),
                    upper: upper,
                    autofocusFirst: r == 0,
                    firstKeyNode: r == 0 ? firstKeyNode : null,
                    onChar: onChar,
                  ),
                  const SizedBox(height: 8),
                ],
                const SizedBox(height: 8),
                // Action keys stay on one horizontal row, sharing width evenly.
                Row(
                  children: [
                    Expanded(
                        child: _Key(
                            label: zh ? '中' : 'EN',
                            wide: true,
                            onPressed: onToggleMode)),
                    const SizedBox(width: 8),
                    // Case toggle: only meaningful in English mode (pinyin always
                    // composes lowercase), so hide it when typing 拼音.
                    if (!zh) ...[
                      Expanded(
                          child: _Key(
                              label: upper ? '大写' : '小写',
                              wide: true,
                              onPressed: onToggleCase)),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                        child:
                            _Key(label: '空格', wide: true, onPressed: onSpace)),
                    const SizedBox(width: 8),
                    Expanded(
                        child: _Key(
                            label: '⌫', wide: true, onPressed: onBackspace)),
                    const SizedBox(width: 8),
                    Expanded(
                        child:
                            _Key(label: '清空', wide: true, onPressed: onClear)),
                    const SizedBox(width: 8),
                    Expanded(
                        child: _Key(
                            label: '搜索',
                            wide: true,
                            primary: true,
                            onPressed: onSearch)),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Pinned strip between the query box and the keys. In 中文 mode it shows the
/// in-progress pinyin + a horizontally-scrollable, D-pad-focusable candidate
/// bar; picking a candidate commits it to the query. Fixed height so switching
/// modes / candidates never reflows the pinned header.
class _ComposingBar extends StatelessWidget {
  const _ComposingBar({
    required this.zh,
    required this.imeReady,
    required this.pinyin,
    required this.candidates,
    required this.onPick,
  });

  final bool zh;
  final bool imeReady;
  final String pinyin;
  final List<String> candidates;
  final void Function(String cand) onPick;

  @override
  Widget build(BuildContext context) {
    Widget content;
    if (!zh) {
      content = const _Hint('英文/数字输入 · 按「中」切换拼音');
    } else if (!imeReady) {
      content = const _Hint('拼音词库加载中…');
    } else if (pinyin.isEmpty) {
      content = const _Hint('拼音输入 · 例如 beijing → 北京，选字后继续');
    } else {
      content = Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0x294EA8FF),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(pinyin,
                style: const TextStyle(
                    fontSize: 16,
                    color: AppColors.text,
                    fontFamilyFallback: kFontFallback)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: candidates.isEmpty
                ? const _Hint('无匹配，试试其它拼音或按「中」切英文')
                : SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final c in candidates) ...[
                          _CandChip(label: c, onPressed: () => onPick(c)),
                          const SizedBox(width: 8),
                        ],
                      ],
                    ),
                  ),
          ),
        ],
      );
    }
    return SizedBox(
        height: 46,
        child: Align(alignment: Alignment.centerLeft, child: content));
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Text(text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
          fontSize: 15,
          color: AppColors.textDim,
          fontFamilyFallback: kFontFallback));
}

/// Recent-search strip shown directly under the input box (both the built-in
/// keyboard and the system-IME panel). Lists up to 8 recent queries as a
/// horizontally-scrollable, D-pad-focusable chip row; tapping one re-runs the
/// search. Renders nothing when there's no history yet. Reads via
/// [AppScope.of] so it refreshes as the history list changes.
class _SearchHistory extends StatelessWidget {
  const _SearchHistory({required this.onPick});

  /// Fired with the chosen query when a history chip is activated.
  final void Function(String query) onPick;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final items = app.searchHistory.take(8).toList();
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            const Text('搜索历史',
                style: TextStyle(
                    fontSize: 13,
                    color: AppColors.textDim,
                    fontFamilyFallback: kFontFallback)),
            const SizedBox(width: 12),
            _HistoryClear(onPressed: app.clearSearchHistory),
          ],
        ),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final q in items) ...[
                _HistoryChip(label: q, onPressed: () => onPick(q)),
                const SizedBox(width: 8),
              ],
            ],
          ),
        ),
        const SizedBox(height: 14),
      ],
    );
  }
}

/// One recent-search chip: a 🕘 glyph + the query text, D-pad focusable.
class _HistoryChip extends StatelessWidget {
  const _HistoryChip({required this.label, required this.onPressed});
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Focusable(
      onPressed: onPressed,
      builder: (context, focused) {
        return FocusFx.scale(
          focused,
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            constraints: const BoxConstraints(maxWidth: 220),
            decoration: focused
                ? FocusFx.pill(focused, radius: 8)
                : BoxDecoration(
                    color: AppColors.glass,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.hairline),
                  ),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
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

/// Small "清空" action for the search-history strip.
class _HistoryClear extends StatelessWidget {
  const _HistoryClear({required this.onPressed});
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Focusable(
      onPressed: onPressed,
      builder: (context, focused) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: focused ? AppColors.glass : null,
            border: Border.all(
                color: focused ? AppColors.accent : AppColors.hairline),
          ),
          child: Text(
            '清空',
            style: TextStyle(
              fontSize: 13,
              color: focused ? AppColors.text : AppColors.textDim,
              fontFamilyFallback: kFontFallback,
            ),
          ),
        );
      },
    );
  }
}

/// A single 汉字/词 candidate chip in the composing bar.
class _CandChip extends StatelessWidget {
  const _CandChip({required this.label, required this.onPressed});
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Focusable(
      onPressed: onPressed,
      builder: (context, focused) {
        return FocusFx.scale(
          focused,
          Container(
            height: 40,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: focused
                ? FocusFx.pill(focused, radius: 10)
                : BoxDecoration(
                    color: AppColors.glass,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.hairline),
                  ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 18,
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

/// One row of the on-screen keyboard: each character key is [Expanded] so the
/// whole row fits on one line at any panel width (no [Wrap] reflow).
class _KeyRow extends StatelessWidget {
  const _KeyRow(
      {required this.chars,
      required this.onChar,
      this.upper = false,
      this.autofocusFirst = false,
      this.firstKeyNode});
  final List<String> chars;
  final void Function(String c) onChar;
  final bool upper;
  final bool autofocusFirst;

  /// When set, attached to the first key so the parent can claim focus for it.
  final FocusNode? firstKeyNode;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < chars.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: Builder(builder: (_) {
              // Rows are stored uppercase; render (and emit) in the active case
              // so English can type lowercase. Digits are unaffected.
              final c = upper ? chars[i].toUpperCase() : chars[i].toLowerCase();
              return _Key(
                label: c,
                autofocus: autofocusFirst && i == 0,
                focusNode: i == 0 ? firstKeyNode : null,
                onPressed: () => onChar(c),
              );
            }),
          ),
        ],
      ],
    );
  }
}

class _Key extends StatelessWidget {
  const _Key({
    required this.label,
    required this.onPressed,
    this.wide = false,
    this.primary = false,
    this.autofocus = false,
    this.focusNode,
  });

  final String label;
  final VoidCallback onPressed;
  final bool wide;
  final bool primary;
  final bool autofocus;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    return Focusable(
      autofocus: autofocus,
      focusNode: focusNode,
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
            width: wide ? null : 44,
            height: 50,
            constraints: wide ? const BoxConstraints(minWidth: 64) : null,
            alignment: Alignment.center,
            padding: wide ? const EdgeInsets.symmetric(horizontal: 10) : null,
            decoration: focused ? FocusFx.pill(focused, radius: 12) : base,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.clip,
              softWrap: false,
              style: TextStyle(
                fontSize: 18,
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

class _Results extends StatelessWidget {
  const _Results();

  // Columns adapt to the pane width around a target tile width, so result
  // cards stay large enough to show the title + meta without truncation (a
  // fixed 4 columns made them tiny on narrower windows). Clamped to 3..6.
  static const double _tileTarget = 200;

  SliverGridDelegate _grid(double width) {
    final cols = (width / _tileTarget).floor().clamp(3, 6);
    return SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: cols,
      crossAxisSpacing: 20,
      mainAxisSpacing: 20,
      childAspectRatio: 2 / 3,
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    if (app.searching) {
      return const _Note('正在搜索…');
    }
    // 资源直搜: each hit is one playable CMS resource → _CmsResultCard.
    if (app.searchMode == SearchMode.cms) {
      final hits = app.cmsResults;
      if (hits.isEmpty) {
        return _Note(app.searchQuery.isEmpty
            ? '输入关键词后按「搜索」，将直接搜索各资源站'
            : '未在各资源站找到「${app.searchQuery}」');
      }
      return LayoutBuilder(
        builder: (context, c) => GridView.builder(
          padding: const EdgeInsets.only(bottom: 40),
          gridDelegate: _grid(c.maxWidth),
          itemCount: hits.length,
          itemBuilder: (context, i) => _CmsResultCard(hit: hits[i]),
        ),
      );
    }
    // TMDB 匹配: metadata cards → openTitle (title → CMS resolve).
    final items = app.searchResults;
    if (items.isEmpty) {
      return _Note(app.searchQuery.isEmpty
          ? '输入关键词后按「搜索」'
          : '未找到「${app.searchQuery}」的结果');
    }
    return LayoutBuilder(
      builder: (context, c) => GridView.builder(
        padding: const EdgeInsets.only(bottom: 40),
        gridDelegate: _grid(c.maxWidth),
        itemCount: items.length,
        itemBuilder: (context, i) => MasonryCard(item: items[i]),
      ),
    );
  }
}

/// A single 资源直搜 result: one source's hit. Mirrors [MasonryCard]'s poster
/// layout and reading-order D-pad navigation, but tags the source and opens the
/// resource directly ([AppController.openCmsHit]) rather than re-matching by
/// title.
class _CmsResultCard extends StatelessWidget {
  const _CmsResultCard({required this.hit});
  final SearchHit hit;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.read(context);
    return Focusable(
      ensureVisibleAlignment: 0.5,
      onPressed: () => app.openCmsHit(hit),
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
          return KeyEventResult.ignored;
        }
        final k = event.logicalKey;
        if (k == LogicalKeyboardKey.arrowRight) {
          FocusManager.instance.primaryFocus?.nextFocus();
          return KeyEventResult.handled;
        }
        if (k == LogicalKeyboardKey.arrowLeft) {
          FocusManager.instance.primaryFocus?.previousFocus();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      builder: (context, focused) {
        return AnimatedContainer(
          duration: kFocusDur,
          curve: kEase,
          transformAlignment: Alignment.center,
          transform: focused
              ? (Matrix4.identity()..scaleByDouble(1.05, 1.05, 1.05, 1.0))
              : Matrix4.identity(),
          decoration: BoxDecoration(
            color: AppColors.cardBg,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color:
                  focused ? const Color(0xE6FFFFFF) : const Color(0x12FFFFFF),
              width: focused ? 3 : 1,
            ),
            boxShadow: focused
                ? const [
                    BoxShadow(
                        color: Color(0x804EA8FF),
                        blurRadius: 40,
                        offset: Offset(0, 16))
                  ]
                : null,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(focused ? 15 : 17),
            child: Stack(
              fit: StackFit.expand,
              children: [
                NetImage(hit.cover),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [
                        Color(0xEB03060E),
                        Color(0x1A03060E),
                        Color(0x0003060E)
                      ],
                      stops: [0.0, 0.55, 1.0],
                    ),
                  ),
                ),
                // Source badge (top-left): which resource station this hit is
                // from — the key signal in 资源直搜, where the same title can
                // appear once per source.
                Positioned(
                  left: 10,
                  top: 10,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xCC0A1830),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0x663DA2FF)),
                    ),
                    child: Text(
                      hit.sourceName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFFBFE0FF),
                        fontFamilyFallback: kFontFallback,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 14,
                  right: 14,
                  bottom: 12,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        hit.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          color: AppColors.text,
                          fontFamilyFallback: kFontFallback,
                        ),
                      ),
                      if (hit.remarks.isNotEmpty || hit.year.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          [
                            if (hit.year.isNotEmpty) hit.year,
                            if (hit.remarks.isNotEmpty) hit.remarks
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            color: Color(0xFF9DB0CB),
                            fontFamilyFallback: kFontFallback,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.only(top: 80),
        child: Text(
          text,
          style: const TextStyle(
              fontSize: 18,
              color: AppColors.textDim,
              fontFamilyFallback: kFontFallback),
        ),
      ),
    );
  }
}
