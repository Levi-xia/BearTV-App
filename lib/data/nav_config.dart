/// Top-nav tabs and the static chip pools. These are UI configuration (not
/// content) — the actual catalogue comes from TMDB via [ContentRepository].
///
/// 直播 is appended last on purpose: keeping indices 0–7 fixed means the TMDB
/// category mapping in `TmdbRepository._query` (case 1–7) and the
/// continue-watch check (`currentTab == 1`) don't shift.
const List<String> kTabs = [
  '我的',
  '推荐',
  '电影',
  '电视剧',
  '美剧',
  '动漫',
  '综艺',
  '纪录片',
  '直播',
];

/// Index of the 直播 (IPTV) tab within [kTabs]. This tab is special-cased in
/// [AppController.setTab] and [HomeScreen.build]: it renders the IPTV browser
/// instead of a TMDB feed and never hits [ContentRepository].
const int kIptvTab = 8;

/// Display order of the nav tabs (values are [kTabs] indices). 直播 is shown
/// first (left of 我的) per product design, but its *logical* index stays 8 so
/// none of the index-based logic (TMDB `_query` cases, `currentTab == 1`) moves.
/// The header renders tabs in this order and steps Left/Right along it.
const List<int> kTabOrder = [kIptvTab, 0, 1, 2, 3, 4, 5, 6, 7];

/// Segment chips under 全部片库. Each maps to a TMDB sort/filter mode
/// (see TmdbRepository): 热门=popularity, 高分=vote_average, 最新=release date,
/// 经典=vote_count.
const List<String> kSegments = ['热门', '高分', '最新', '经典'];

/// Playback speed presets (BearTV PLAYBACK_RATES). Remembered per title.
const List<double> kPlaybackRates = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0];
