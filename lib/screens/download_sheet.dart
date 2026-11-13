import 'package:flutter/material.dart';

import '../core/app_controller.dart';
import '../core/app_scope.dart';
import '../core/theme.dart';
import '../data/downloads/download_models.dart';
import '../widgets/chips.dart';
import '../widgets/episode_pager.dart';

/// 下载选集 sheet, opened from the play page (side panel or fullscreen menu).
///
/// One press on an episode adds it to the download queue immediately — there is
/// no separate confirm step. Episodes that are already cached or queued are
/// greyed out with a 「✓ 已缓存」/「下载中」 badge, paused/failed ones can be
/// pressed again to resume.
class DownloadSheet extends StatefulWidget {
  const DownloadSheet({super.key, required this.onClose});

  final VoidCallback onClose;

  @override
  State<DownloadSheet> createState() => _DownloadSheetState();
}

class _DownloadSheetState extends State<DownloadSheet> {
  FocusNode? _episodeNode;
  int _focusIndex = 0;
  final FocusScopeNode _scope = FocusScopeNode(debugLabel: 'downloadSheet');

  /// True once a leaf inside the sheet took focus; [build] retries until then
  /// (episodes can still be resolving when the sheet first mounts).
  bool _claimed = false;

  @override
  void initState() {
    super.initState();
    // Claim the current episode explicitly. A FocusScope's own autofocus only
    // focuses the scope node, which no key can act on, and the cell's autofocus
    // races the scope's — so D-pad input did nothing until something was
    // focused by hand.
    WidgetsBinding.instance.addPostFrameCallback((_) => _claimFocus());
  }

  void _claimFocus() {
    if (!mounted || _claimed) return;
    final node = _episodeNode;
    if (node != null && node.context != null) {
      node.requestFocus();
      _claimed = true;
    } else {
      _scope.requestFocus();
      _claimed = _scope.nextFocus();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_episodeNode != null) return;
    final app = AppScope.of(context);
    final eps = app.currentEpisodes;
    if (eps.isEmpty) return;
    final index = app.episodeIndex;
    _focusIndex = index < 0 || index >= eps.length ? 0 : index;
    _episodeNode = FocusNode(debugLabel: 'downloadEpisode$_focusIndex');
  }

  @override
  void dispose() {
    _episodeNode?.dispose();
    _scope.dispose();
    super.dispose();
  }

  DownloadTask? _taskFor(AppController app, int index) {
    final detail = app.currentDetail;
    final eps = app.currentEpisodes;
    if (detail == null || index < 0 || index >= eps.length) return null;
    return app.downloads.taskForEpisode(
      sourceId: detail.sourceId,
      vodId: detail.vodId,
      episodeUrl: eps[index].url,
      episodeTitle: eps[index].title,
      episodeIndex: index,
    );
  }

  /// Cached/queued episodes are shown but can't be added twice; paused or
  /// failed ones stay actionable so a press resumes them.
  bool _locked(AppController app, int index) {
    final task = _taskFor(app, index);
    if (task == null) return false;
    return task.status != DownloadStatus.paused &&
        task.status != DownloadStatus.failed;
  }

  Future<void> _onEpisode(AppController app, int index) async {
    final task = _taskFor(app, index);
    if (task == null) {
      await app.downloadEpisodes([index]);
      return;
    }
    if (task.status == DownloadStatus.paused ||
        task.status == DownloadStatus.failed) {
      await app.downloads.resume(task.id);
    }
  }

  Future<void> _downloadAll(AppController app) async {
    final indices = [
      for (var i = 0; i < app.currentEpisodes.length; i++)
        if (!_locked(app, i)) i,
    ];
    if (indices.isEmpty) {
      app.showToast('本线路剧集已全部缓存');
      return;
    }
    await app.downloadEpisodes(indices);
  }

  String? _badgeFor(AppController app, int index) {
    final task = _taskFor(app, index);
    if (task == null) return null;
    switch (task.status) {
      case DownloadStatus.completed:
        return '✓ 已缓存';
      case DownloadStatus.downloading:
        final pct = (task.progress * 100).round().clamp(0, 100);
        return '下载中 $pct%';
      case DownloadStatus.queued:
        return '等待中';
      case DownloadStatus.paused:
        return '已暂停';
      case DownloadStatus.failed:
        return '失败';
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    // Badges/counts follow the queue; the manager notifies independently of
    // the controller, so listen to it directly.
    return ListenableBuilder(
      listenable: app.downloads,
      builder: (context, _) => _buildSheet(app),
    );
  }

  Widget _buildSheet(AppController app) {
    final detail = app.currentDetail;
    final eps = app.currentEpisodes;
    if (detail == null || eps.isEmpty) return const SizedBox.shrink();
    if (!_claimed) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _claimFocus());
    }

    var cached = 0;
    var addable = 0;
    for (var i = 0; i < eps.length; i++) {
      if (_taskFor(app, i)?.isComplete ?? false) cached++;
      if (!_locked(app, i)) addable++;
    }

    return Align(
      alignment: Alignment.bottomCenter,
      child: FocusScope(
        node: _scope,
        // A group of its own so arrow keys can't walk back onto the play page
        // underneath while the sheet is open.
        child: FocusTraversalGroup(
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 1, end: 0),
            duration: const Duration(milliseconds: 240),
            curve: kEase,
            builder: (context, t, child) => FractionalTranslation(
              translation: Offset(0, t),
              child: child,
            ),
            child: Container(
              width: double.infinity,
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.78,
              ),
              padding:
                  const EdgeInsets.fromLTRB(AppDims.pad, 26, AppDims.pad, 34),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Color(0xFA04070E), Color(0xF2070C18)],
                ),
                borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
              ),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        const Text('下载选集',
                            style: TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.w700,
                                color: AppColors.text,
                                fontFamilyFallback: kFontFallback)),
                        const SizedBox(width: 14),
                        Text(
                          '${detail.sourceName} · ${detail.playLines[app.lineIndex].name} · 已缓存 $cached/${eps.length} 集',
                          style: const TextStyle(
                              fontSize: 15,
                              color: AppColors.textDim,
                              fontFamilyFallback: kFontFallback),
                        ),
                        const Spacer(),
                        const Text('选中即加入下载 · 返回关闭',
                            style: TextStyle(
                                fontSize: 14,
                                color: AppColors.textDim,
                                fontFamilyFallback: kFontFallback)),
                      ],
                    ),
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        SizedBox(
                          width: 168,
                          child: ActionButton(
                            label: '全部下载',
                            primary: true,
                            onPressed: () => _downloadAll(app),
                          ),
                        ),
                        const SizedBox(width: 14),
                        SizedBox(
                          width: 190,
                          child: ActionButton(
                            label: '前往下载管理',
                            onPressed: () {
                              widget.onClose();
                              app.openDownloads();
                            },
                          ),
                        ),
                        const SizedBox(width: 16),
                        if (addable == 0)
                          const Text('本线路剧集已全部缓存',
                              style: TextStyle(
                                  fontSize: 15,
                                  color: AppColors.textDim,
                                  fontFamilyFallback: kFontFallback)),
                      ],
                    ),
                    const SizedBox(height: 20),
                    EpisodePager(
                      episodes: eps,
                      currentIndex: app.episodeIndex,
                      onPick: (i) => _onEpisode(app, i),
                      spacing: 12,
                      badgeForIndex: (i) => _badgeFor(app, i),
                      disabledForIndex: (i) => _locked(app, i),
                      focusNodeForIndex: (i) =>
                          i == _focusIndex ? _episodeNode : null,
                      autofocusIndex: _focusIndex,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
