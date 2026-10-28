import 'package:flutter_test/flutter_test.dart';
import 'package:bear_tv/core/app_controller.dart';
import 'package:bear_tv/core/tab_feed.dart';

import 'fakes.dart';

void main() {
  test('setTab caches: switching back does not refetch', () async {
    final repo = FakeRepo();
    final c = AppController(repository: repo);
    addTearDown(c.dispose);

    await c.setTab(1, silent: true);
    expect(repo.callsFor(1, 1), 1);

    await c.setTab(2, silent: true);
    expect(repo.callsFor(2, 1), 1);

    // Back to tab 1 — served from cache, no new request.
    await c.setTab(1, silent: true);
    expect(repo.callsFor(1, 1), 1);
    expect(c.feed.library.value.length, repo.pageSize);
  });

  test('loadMore appends the next page and dedups concurrent calls', () async {
    final repo = FakeRepo();
    final c = AppController(repository: repo);
    addTearDown(c.dispose);

    await c.setTab(1, silent: true);
    expect(c.feed.library.value.length, repo.pageSize);

    // Fire two loadMore calls before the first completes: inFlight must dedup.
    final f1 = c.loadMore();
    final f2 = c.loadMore();
    await Future.wait([f1, f2]);

    expect(repo.callsFor(1, 2), 1); // page 2 fetched exactly once
    expect(c.feed.library.value.length, repo.pageSize * 2);
    expect(c.feed.page, 2);
  });

  test('loadMore stops once hasMore is false', () async {
    final repo = FakeRepo(maxPages: 1); // only page 1 exists
    final c = AppController(repository: repo);
    addTearDown(c.dispose);

    await c.setTab(1, silent: true);
    expect(c.feed.status.value, FeedStatus.end);
    expect(c.feed.hasMore, isFalse);

    await c.loadMore();
    expect(repo.callsFor(1, 2), 0); // never requested
    expect(c.feed.library.value.length, repo.pageSize);
  });

  test('tab 0 (我的) is local-only and never hits the repository', () async {
    final repo = FakeRepo();
    final c = AppController(repository: repo);
    addTearDown(c.dispose);

    await c.setTab(0, silent: true);
    expect(repo.calls, isEmpty);
    expect(c.feed.status.value, FeedStatus.end);
  });

  test('selectSegment re-fetches page 1 and resets the grid', () async {
    final repo = FakeRepo();
    final c = AppController(repository: repo);
    addTearDown(c.dispose);

    await c.setTab(1, silent: true);
    await c.loadMore(); // now on page 2 with 2× items
    expect(c.feed.page, 2);
    expect(c.feed.library.value.length, repo.pageSize * 2);

    await c.selectSegment(1); // 高分
    expect(c.segIndex, 1);
    expect(c.feed.page, 1); // reset to first page
    expect(c.feed.library.value.length, repo.pageSize);
    expect(repo.callsFor(1, 1), 2); // initial load + segment reload

    // Selecting the same segment again is a no-op (no extra request).
    await c.selectSegment(1);
    expect(repo.callsFor(1, 1), 2);
  });
}
