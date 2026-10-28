import 'package:bear_tv/data/models.dart';
import 'package:bear_tv/data/repository.dart';

/// In-memory [ContentRepository] for tests: deterministic pages, finite so
/// infinite-scroll termination can be exercised without a network.
class FakeRepo implements ContentRepository {
  FakeRepo({this.pageSize = 10, this.maxPages = 3});
  final int pageSize;
  final int maxPages;
  final List<String> calls = [];

  int callsFor(int tab, int page) => calls.where((c) => c == '$tab:$page').length;

  @override
  Future<FeedPage> loadFeed(int tabIndex, int page, {int sort = 0}) async {
    calls.add('$tabIndex:$page');
    final start = (page - 1) * pageSize;
    final items = [
      for (var i = 0; i < pageSize; i++)
        VodItem(
          id: tabIndex * 1000 + start + i,
          title: '条目 ${start + i}',
          en: 'ITEM ${start + i}',
          genre: '剧情',
          desc: '简介简介简介。',
          year: 2020,
          score: '8.0',
          ep: 12,
          hd: 'HD',
          neu: false,
          bgUrl: '',
          cardUrl: '',
          posterUrl: '',
        ),
    ];
    return FeedPage(items: items, page: page, hasMore: page < maxPages);
  }

  @override
  Future<VodItem> loadDetail(VodItem item) async => item;

  @override
  Future<String?> resolvePlayUrl(VodItem item, int episode, {String line = '线路一'}) async => null;

  @override
  Future<FeedPage> search(String query, int page) async =>
      FeedPage(items: const [], page: page, hasMore: false);
}
