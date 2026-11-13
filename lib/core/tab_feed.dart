import 'package:flutter/foundation.dart';

import '../data/models.dart';

/// Per-tab loading state, cached in [AppController] so switching tabs never
/// refetches an already-loaded page. Library + status are [ValueNotifier]s so
/// appending pages repaints only the grid/footer, not the hero rail.
enum FeedStatus { idle, loading, loadingMore, error, end }

class TabFeed {
  TabFeed(this.tabIndex);

  final int tabIndex;

  List<VodItem> hero = const [];
  String? heroBgUrl;

  final ValueNotifier<List<VodItem>> library =
      ValueNotifier<List<VodItem>>(const []);
  final ValueNotifier<FeedStatus> status =
      ValueNotifier<FeedStatus>(FeedStatus.idle);

  int page = 0;
  bool hasMore = true;
  bool inFlight = false;
  double scrollOffset = 0;
  int segIndex = 0; // selected segment chip (cosmetic filter)

  /// True once the first page has been fetched (success or terminal).
  bool get loaded => page > 0 || status.value == FeedStatus.end;

  void dispose() {
    library.dispose();
    status.dispose();
  }
}
