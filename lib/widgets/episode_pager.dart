import 'package:flutter/widgets.dart';

import '../data/vod/cms_models.dart';
import 'chips.dart';
import 'focus_fx.dart';

/// Number of episodes shown per page in [EpisodePager].
const int kEpisodesPerPage = 100;

/// D-pad-friendly, paginated 选集 grid shared by the inline 选集 rail, the
/// fullscreen 选集 drawer and the 下载选集 sheet.
///
/// Long series — 柯南 runs to thousands of episodes — are both laggy and a focus
/// hazard when every cell is built at once, so episodes are split into pages of
/// [kEpisodesPerPage]. A horizontally-scrollable row of range chips (1-100,
/// 101-200, …) switches pages and only the active page's cells are built; the
/// selector hides entirely for a single page. On open the view lands on (and
/// scrolls the selector to) the page holding [currentIndex].
///
/// Selection mode is opt-in: when [onToggle] is set the cells toggle
/// [selected] instead of picking, and [badgeForIndex] can label each cell with
/// its download state.
class EpisodePager extends StatefulWidget {
  const EpisodePager({
    super.key,
    required this.episodes,
    required this.currentIndex,
    required this.onPick,
    this.spacing = 12,
    this.selected,
    this.onToggle,
    this.badgeForIndex,
    this.disabledForIndex,
    this.focusNodeForIndex,
    this.autofocusIndex,
  });

  final List<Episode> episodes;
  final int currentIndex;

  /// Play this episode (ignored when [onToggle] is set).
  final void Function(int index) onPick;

  final double spacing;

  /// Selected episode indices for download mode.
  final Set<int>? selected;

  /// Toggle selection of an episode (enables multi-select mode).
  final void Function(int index)? onToggle;

  /// e.g. 「✓ 已缓存」「下载中」; null when the cell has no status.
  final String? Function(int index)? badgeForIndex;

  /// Greys out cells that can't be acted on (already cached / downloading).
  final bool Function(int index)? disabledForIndex;

  /// Per-cell focus nodes, so a sheet can send initial focus to one episode.
  final FocusNode? Function(int index)? focusNodeForIndex;

  /// Episode that takes focus when this pager (re)builds.
  final int? autofocusIndex;

  @override
  State<EpisodePager> createState() => _EpisodePagerState();
}

class _EpisodePagerState extends State<EpisodePager> {
  late int _page = widget.currentIndex ~/ kEpisodesPerPage;
  // Tracks the episode count last reflected in [_page]; a change means a new
  // show was loaded, so the view re-syncs to the current episode's page.
  late int _syncedCount = widget.episodes.length;
  // Horizontal scroller for the range chips. We drive it directly (rather than
  // Scrollable.ensureVisible) so revealing the active chip only ever moves THIS
  // row — never the enclosing vertical page / fullscreen menu scroll.
  final ScrollController _chips = ScrollController();
  final GlobalKey _viewportKey = GlobalKey();
  final GlobalKey _activeChipKey = GlobalKey();
  bool _didRevealChip = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealActiveChip());
  }

  @override
  void dispose() {
    _chips.dispose();
    super.dispose();
  }

  /// Scrolls the chip row (and only the chip row) so the active page's chip is
  /// centred. Never touches ancestor scrollables.
  void _revealActiveChip() {
    if (!mounted || _didRevealChip || !_chips.hasClients) return;
    final chipBox =
        _activeChipKey.currentContext?.findRenderObject() as RenderBox?;
    final viewBox =
        _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (chipBox == null || viewBox == null) return;
    _didRevealChip = true;
    final chipLeft =
        viewBox.globalToLocal(chipBox.localToGlobal(Offset.zero)).dx;
    final target = _chips.offset +
        chipLeft -
        (viewBox.size.width - chipBox.size.width) / 2;
    _chips.jumpTo(target.clamp(
        _chips.position.minScrollExtent, _chips.position.maxScrollExtent));
  }

  @override
  Widget build(BuildContext context) {
    // A new show (different episode count) resets to the current episode's page.
    if (_syncedCount != widget.episodes.length) {
      _syncedCount = widget.episodes.length;
      _page = widget.currentIndex ~/ kEpisodesPerPage;
      _didRevealChip = false;
      WidgetsBinding.instance.addPostFrameCallback((_) => _revealActiveChip());
    }
    final pageCount = (widget.episodes.length / kEpisodesPerPage).ceil();
    final page = _page.clamp(0, pageCount - 1);
    final start = page * kEpisodesPerPage;
    final end = (start + kEpisodesPerPage).clamp(0, widget.episodes.length);
    final unit = episodeUnit(widget.episodes);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (pageCount > 1) ...[
          SingleChildScrollView(
            key: _viewportKey,
            controller: _chips,
            scrollDirection: Axis.horizontal,
            // A horizontal viewport clips at the row's own height / edges, so
            // the focused chip's 1.06 scale and glow would be sliced off at the
            // ends. The slack keeps them intact; the grid below starts a little
            // lower, which is harmless and only applies past 100 episodes.
            padding: const EdgeInsets.symmetric(
                horizontal: 8, vertical: kFocusSlack / 2),
            child: Row(
              children: [
                for (var p = 0; p < pageCount; p++)
                  Padding(
                    key: p == page ? _activeChipKey : null,
                    padding: EdgeInsets.only(right: widget.spacing),
                    child: SelectableChip(
                      label: _rangeLabel(p),
                      selected: p == page,
                      onPressed: () {
                        if (p != page) setState(() => _page = p);
                      },
                    ),
                  ),
              ],
            ),
          ),
          SizedBox(height: widget.spacing + 6),
        ],
        Wrap(
          spacing: widget.spacing,
          runSpacing: widget.spacing,
          children: [
            for (var i = start; i < end; i++)
              SizedBox(
                width: 150,
                child: EpisodeCell(
                  label: episodeLabel(widget.episodes[i].title, i, unit: unit),
                  current: i == widget.currentIndex,
                  selected: widget.selected?.contains(i) ?? false,
                  badge: widget.badgeForIndex?.call(i),
                  disabled: widget.disabledForIndex?.call(i) ?? false,
                  focusNode: widget.focusNodeForIndex?.call(i),
                  autofocus: widget.autofocusIndex == i,
                  onPressed: () => widget.onToggle != null
                      ? widget.onToggle!(i)
                      : widget.onPick(i),
                ),
              ),
          ],
        ),
      ],
    );
  }

  String _rangeLabel(int p) {
    final first = p * kEpisodesPerPage + 1;
    final last = ((p + 1) * kEpisodesPerPage).clamp(0, widget.episodes.length);
    return '$first-$last';
  }
}
