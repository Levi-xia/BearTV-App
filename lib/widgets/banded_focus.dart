import 'package:flutter/foundation.dart' show mergeSort;
import 'package:flutter/widgets.dart';

/// Marks a subtree as one vertical "lane" for [BandedTraversalPolicy].
///
/// A lane is how a page says "these elements are stacked in one column". The
/// search page puts its input panel and its result grid in separate lanes, so a
/// vertical press inside the keypad walks the keypad's own rows (keys → history
/// → mode chips) instead of hopping sideways into the poster grid.
class FocusLane extends InheritedWidget {
  const FocusLane({super.key, required this.id, required super.child});

  /// Identity of the lane. Any [Object] works: it only has to be stable across
  /// rebuilds, and different from the page's other lanes.
  final Object id;

  static Object? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<FocusLane>()?.id;

  @override
  bool updateShouldNotify(FocusLane oldWidget) => id != oldWidget.id;
}

/// Directional focus that walks a page row by row, staying inside its lane.
///
/// Flutter's default policy ([ReadingOrderTraversalPolicy], via its directional
/// mixin) picks the candidate whose edge is nearest in the requested direction
/// and falls back to *horizontal* distance when nothing sits in the focused
/// element's column. On a page of stacked rows that reads as a jump: Up from
/// the keyboard's top-right key left the keypad entirely and landed on the mode
/// chips (or the header 🔍), skipping the search-history row underneath.
///
/// This policy keeps the rows intact:
///   • Up/Down picks the *nearest row* in that direction (edge-to-edge, not
///     center-to-center), then the closest element inside that row. Which
///     spelling of "nearest" is used no longer depends on whether some element
///     happens to overlap the current column.
///   • Up/Down prefers elements in the same [FocusLane], and only leaves the
///     lane when it has nothing left in that direction — so a vertical press
///     never slides across to the neighbouring panel while its own column still
///     has content.
///   • Left/Right stays on the current row when it can, otherwise it takes the
///     nearest element sideways (this is also what carries focus from the
///     keypad into the result grid).
class BandedTraversalPolicy extends FocusTraversalPolicy {
  const BandedTraversalPolicy({super.requestFocusCallback});

  /// Two candidates closer than this vertically are treated as one row. Real
  /// rows are at least a gap apart; this only absorbs the few pixels between a
  /// label and the smaller chip beside it.
  static const double _rowSlop = 8;

  @override
  Iterable<FocusNode> sortDescendants(
    Iterable<FocusNode> descendants,
    FocusNode currentNode,
  ) {
    final list = descendants.toList();
    // Reading order: top to bottom, then left to right. Used for Tab traversal
    // and for "first/last focus" fallbacks, not for arrow keys.
    mergeSort(list, compare: (a, b) {
      final byTop = a.rect.top.compareTo(b.rect.top);
      return byTop != 0 ? byTop : a.rect.left.compareTo(b.rect.left);
    });
    return list;
  }

  @override
  FocusNode? findFirstFocusInDirection(
    FocusNode currentNode,
    TraversalDirection direction,
  ) {
    final candidates = _candidates(currentNode, direction);
    return candidates.isEmpty ? null : candidates.first;
  }

  @override
  bool inDirection(FocusNode currentNode, TraversalDirection direction) {
    final candidates = _candidates(currentNode, direction);
    if (candidates.isEmpty) return false;
    requestFocusCallback(
      candidates.first,
      alignmentPolicy:
          direction == TraversalDirection.up || direction == TraversalDirection.left
              ? ScrollPositionAlignmentPolicy.keepVisibleAtStart
              : ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
    );
    return true;
  }

  /// All reachable nodes in [direction], best first.
  List<FocusNode> _candidates(FocusNode from, TraversalDirection direction) {
    final Rect fromRect = from.rect;
    final bool vertical = direction == TraversalDirection.up ||
        direction == TraversalDirection.down;
    final Object? lane = _laneOf(from);

    final sameLane = <FocusNode>[];
    final anywhere = <FocusNode>[];
    for (final node in from.nearestScope?.traversalDescendants ??
        const <FocusNode>[]) {
      if (node == from) continue;
      final Rect rect = node.rect;
      if (rect.isEmpty) continue; // laid out but zero-sized (collapsed row)
      if (!_isInDirection(fromRect, rect, direction)) continue;
      anywhere.add(node);
      if (vertical && _laneOf(node) == lane) sameLane.add(node);
    }

    // A vertical press keeps to its own column while that column still has
    // something in the requested direction; sideways presses may cross lanes.
    final pool = vertical && sameLane.isNotEmpty ? sameLane : anywhere;
    if (pool.isEmpty) return const [];
    return vertical
        ? _nearestRow(fromRect, pool, up: direction == TraversalDirection.up)
        : _nearestInRow(fromRect, pool);
  }

  /// The row closest to [from] in the requested direction, ordered by how close
  /// each element is horizontally.
  static List<FocusNode> _nearestRow(
    Rect from,
    List<FocusNode> pool, {
    required bool up,
  }) {
    double gapTo(FocusNode node) {
      final Rect r = node.rect;
      return up ? from.top - r.bottom : r.top - from.bottom;
    }

    final sorted = pool.toList()
      ..sort((a, b) {
        final byGap = gapTo(a).compareTo(gapTo(b));
        return byGap != 0 ? byGap : a.rect.center.dx.compareTo(b.rect.center.dx);
      });

    // The nearest element anchors the row; anything sharing its vertical band
    // is in the same row, however far apart the elements are horizontally.
    final Rect anchor = sorted.first.rect;
    final row = sorted
        .where((n) =>
            (n.rect.center.dy - anchor.center.dy).abs() <= _rowSlop ||
            _overlapsVertically(anchor, n.rect))
        .toList();
    row.sort((a, b) => _rowOrder(from, a.rect, b.rect));
    return row;
  }

  /// The elements closest to [from] sideways, preferring ones on its own row.
  static List<FocusNode> _nearestInRow(Rect from, List<FocusNode> pool) {
    final sameRow = <FocusNode>[];
    final rest = <FocusNode>[];
    for (final node in pool) {
      (_overlapsVertically(from, node.rect) ? sameRow : rest).add(node);
    }
    final row = sameRow.isNotEmpty ? sameRow : rest;
    row.sort((a, b) {
      final byX = _horizontalGap(from, a.rect)
          .compareTo(_horizontalGap(from, b.rect));
      if (byX != 0) return byX;
      return _verticalGap(from, a.rect).compareTo(_verticalGap(from, b.rect));
    });
    return row;
  }

  /// Horizontal gap first, then distance from the centre line — so a row of
  /// equal-width keys is crossed by the key straight above/below.
  static int _rowOrder(Rect from, Rect a, Rect b) {
    final byX = _horizontalGap(from, a).compareTo(_horizontalGap(from, b));
    if (byX != 0) return byX;
    return (a.center.dx - from.center.dx)
        .abs()
        .compareTo((b.center.dx - from.center.dx).abs());
  }

  static bool _isInDirection(
    Rect from,
    Rect to,
    TraversalDirection direction,
  ) {
    // Flutter's own rule: the candidate's *centre* has to clear this element's
    // near edge. Anything sharing our row therefore never counts as "above".
    return switch (direction) {
      TraversalDirection.up => to.center.dy < from.top,
      TraversalDirection.down => to.center.dy > from.bottom,
      TraversalDirection.left => to.center.dx < from.left,
      TraversalDirection.right => to.center.dx > from.right,
    };
  }

  static bool _overlapsVertically(Rect a, Rect b) =>
      a.top < b.bottom && b.top < a.bottom;

  /// Distance between the two rects' horizontal edges; 0 when they overlap.
  static double _horizontalGap(Rect from, Rect to) {
    if (to.right <= from.left) return from.left - to.right;
    if (to.left >= from.right) return to.left - from.right;
    return 0;
  }

  static double _verticalGap(Rect from, Rect to) {
    if (to.bottom <= from.top) return from.top - to.bottom;
    if (to.top >= from.bottom) return to.top - from.bottom;
    return 0;
  }

  static Object? _laneOf(FocusNode node) {
    final BuildContext? context = node.context;
    return context == null ? null : FocusLane.maybeOf(context);
  }
}
