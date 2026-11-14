import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_controller.dart';
import '../core/app_scope.dart';
import '../core/format.dart';
import '../core/theme.dart';
import '../data/downloads/download_manager.dart';
import '../data/downloads/download_models.dart';
import '../widgets/chips.dart';
import '../widgets/focus_fx.dart';
import '../widgets/focusable.dart';
import '../widgets/net_image.dart';

/// 下载管理: one collapsible card per 剧 + 资源来源.
///
/// Deliberately dense — no progress bars, no 下载中/已完成 filters, no footer:
///   • 全部开始 / 全部暂停 sit in the header and act on whatever is resumable
///     or running, so the page never needs a filter to pick a subset.
///   • 设置 opens an overlay for the simultaneous-download count.
///   • A card collapses to a single row (poster / title / source / counts /
///     size), so a long download list stays scannable; OK expands its episodes.
///
/// TV interactions:
///   • OK on a card header → expand/collapse; OK on an episode → play it when
///     cached, pause/resume it when still in flight.
///   • MENU on an episode → delete that episode; MENU on a card header (or the
///     删除该剧 chip) → delete the whole card.
///   • 去播放 always opens the show at its 播放记录 episode; the play page itself
///     decides the transport (finished cache / 边下边播 prefix / online m3u8).
///   • Back is the remote's own key (handled by the controller).
class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key});

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  DownloadTask? _deleteTask;
  DownloadGroup? _deleteGroup;
  bool _showSettings = false;

  /// Cards the user explicitly opened or closed. Untouched cards open
  /// themselves when they have work in flight, or when they are the only one —
  /// a finished single-show download shouldn't look empty on arrival.
  final Map<String, bool> _open = {};
  final FocusNode _firstCardNode = FocusNode(debugLabel: 'downloadsFirstCard');
  final FocusNode _settingsNode = FocusNode(debugLabel: 'downloadsSettings');
  AppController? _app;
  bool _placedFocus = false;
  bool _spaceRequested = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = AppScope.of(context);
    if (!identical(app, _app)) {
      _app = app;
      app.downloadsBackInterceptor = _handleBack;
    }
    if (_spaceRequested) return;
    _spaceRequested = true;
    // The header shows the box's free space, which the manager doesn't track
    // before the page asks for it.
    final downloads = app.downloads;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(downloads.refreshFreeSpace());
    });
  }

  @override
  void dispose() {
    if (_app?.downloadsBackInterceptor == _handleBack) {
      _app?.downloadsBackInterceptor = null;
    }
    _firstCardNode.dispose();
    _settingsNode.dispose();
    super.dispose();
  }

  /// Remote Back is delivered by the controller (not as a widget key event on
  /// Android), so the overlay registers here — otherwise Back popped the page
  /// and left the overlay behind.
  bool _handleBack() {
    if (!_showSettings) return false;
    _closeSettings();
    return true;
  }

  void _openSettings() => setState(() => _showSettings = true);

  void _closeSettings() {
    if (!_showSettings) return;
    setState(() => _showSettings = false);
    // The overlay's chip took focus; hand it back to the 设置 button.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _settingsNode.requestFocus();
    });
  }

  bool _isOpen(DownloadGroup group, int groupCount) =>
      _open[group.key] ?? (group.isActive || groupCount == 1);

  void _toggle(DownloadGroup group, int groupCount) {
    setState(() => _open[group.key] = !_isOpen(group, groupCount));
  }

  /// With no 返回 chip the page needs its own landing spot: the first card.
  void _focusFirstCard() {
    if (_placedFocus) return;
    _placedFocus = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _firstCardNode.canRequestFocus) {
        _firstCardNode.requestFocus();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return ListenableBuilder(
      listenable: app.downloads,
      builder: (context, _) {
        final groups = app.downloads.groups;
        if (groups.isNotEmpty) _focusFirstCard();
        var bytes = 0;
        for (final g in groups) {
          bytes += g.totalBytes;
        }
        final free = app.downloads.freeSpaceBytes;
        final speed = app.downloads.totalSpeed;
        final showSpeed = speed > 0 || app.downloads.runningCount > 0;
        final space = '占用 ${formatBytes(bytes)}'
            ' · 剩余 ${free == null ? '—' : formatBytes(free)}'
            '${showSpeed ? ' · 速度 ${formatSpeed(speed)}' : ''}';

        return Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 150),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppDims.pad),
                  child: Row(
                    children: [
                      const Text('下载管理',
                          style: TextStyle(
                              fontSize: 30,
                              fontWeight: FontWeight.w700,
                              color: AppColors.text,
                              fontFamilyFallback: kFontFallback)),
                      const SizedBox(width: 14),
                      // Flexible so 占用/剩余/速度 truncates on narrow TVs
                      // instead of overflowing the header row.
                      Expanded(
                        child: Text(space,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 15,
                                color: AppColors.textDim,
                                fontFamilyFallback: kFontFallback)),
                      ),
                      const SizedBox(width: 16),
                      SelectableChip(
                        label: '全部开始',
                        selected: false,
                        autofocus: groups.isEmpty,
                        onPressed: app.downloads.resumeAll,
                      ),
                      const SizedBox(width: 10),
                      SelectableChip(
                        label: '全部暂停',
                        selected: false,
                        onPressed: app.downloads.pauseAll,
                      ),
                      const SizedBox(width: 10),
                      SelectableChip(
                        label: '设置',
                        selected: false,
                        focusNode: _settingsNode,
                        onPressed: _openSettings,
                      ),
                    ],
                  ),
                ),
                if (!app.downloads.available)
                  const Padding(
                    padding:
                        EdgeInsets.fromLTRB(AppDims.pad, 14, AppDims.pad, 0),
                    child: Text('本地存储不可用，下载功能暂不可用。',
                        style: TextStyle(
                            fontSize: 15,
                            color: AppColors.gold,
                            fontFamilyFallback: kFontFallback)),
                  ),
                const SizedBox(height: 12),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: AppDims.pad),
                  child: Text('OK 展开剧集 · 菜单键删除整部剧',
                      style: TextStyle(
                          fontSize: 14,
                          color: AppColors.textDim,
                          fontFamilyFallback: kFontFallback)),
                ),
                const SizedBox(height: 14),
                const Divider(
                  height: 1,
                  thickness: 1,
                  color: AppColors.hairline,
                  indent: AppDims.pad,
                  endIndent: AppDims.pad,
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: groups.isEmpty
                      ? _empty()
                      : ListView.separated(
                          // Top slack: the first card's focused 1.06 scale and
                          // glow must not be cut by the viewport edge (the
                          // card is flush with it at scroll offset 0).
                          padding: const EdgeInsets.fromLTRB(
                              AppDims.pad, 12, AppDims.pad, 40),
                          itemCount: groups.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 14),
                          itemBuilder: (context, index) => _GroupCard(
                            app: app,
                            group: groups[index],
                            expanded: _isOpen(groups[index], groups.length),
                            firstFocusNode: index == 0 ? _firstCardNode : null,
                            onToggle: () =>
                                _toggle(groups[index], groups.length),
                            onDeleteTask: (t) =>
                                setState(() => _deleteTask = t),
                            onDeleteGroup: (g) =>
                                setState(() => _deleteGroup = g),
                          ),
                        ),
                ),
              ],
            ),
            if (_deleteTask != null)
              _DeleteConfirm(
                title: '删除这一集？',
                message: '将删除「${_deleteTask!.item.title}」的本地文件，观看进度记录会保留。',
                onCancel: () => setState(() => _deleteTask = null),
                onConfirm: () {
                  final task = _deleteTask!;
                  setState(() => _deleteTask = null);
                  app.deleteDownload(task);
                },
              ),
            if (_deleteGroup != null)
              _DeleteConfirm(
                title: '删除整部剧的下载？',
                message:
                    '将删除「${_deleteGroup!.item.title}」在「${_deleteGroup!.sourceName}」的全部缓存（${_deleteGroup!.tasks.length} 集）。',
                onCancel: () => setState(() => _deleteGroup = null),
                onConfirm: () {
                  final group = _deleteGroup!;
                  setState(() => _deleteGroup = null);
                  app.deleteDownloadGroup(group);
                },
              ),
            if (_showSettings)
              _DownloadSettings(
                downloads: app.downloads,
                onClose: _closeSettings,
              ),
          ],
        );
      },
    );
  }

  Widget _empty() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('暂无下载任务',
              style: TextStyle(
                  fontSize: 22,
                  color: AppColors.textDim,
                  fontFamilyFallback: kFontFallback)),
          SizedBox(height: 10),
          Text('在播放页选择「下载选集」即可添加',
              style: TextStyle(
                  fontSize: 15,
                  color: AppColors.textDim,
                  fontFamilyFallback: kFontFallback)),
        ],
      ),
    );
  }
}

/// One 剧 + 来源 group: a collapsible header row plus its episode grid.
class _GroupCard extends StatelessWidget {
  const _GroupCard({
    required this.app,
    required this.group,
    required this.expanded,
    required this.onToggle,
    required this.onDeleteTask,
    required this.onDeleteGroup,
    this.firstFocusNode,
  });

  final AppController app;
  final DownloadGroup group;
  final bool expanded;
  final VoidCallback onToggle;
  final void Function(DownloadTask) onDeleteTask;
  final void Function(DownloadGroup) onDeleteGroup;
  final FocusNode? firstFocusNode;

  int _count(DownloadStatus status) =>
      group.tasks.where((t) => t.status == status).length;

  /// State counts in plain words. Not "已缓存 x/y 集": y was the number of
  /// tasks the user added, so it read like the show's total episode count.
  /// The group's own throughput is appended while it is transferring.
  String get _meta {
    final cached = group.completedCount;
    final inFlight =
        _count(DownloadStatus.downloading) + _count(DownloadStatus.queued);
    final paused = _count(DownloadStatus.paused);
    final failed = _count(DownloadStatus.failed);
    final speed = app.downloads.groupSpeed(group.key);
    final text = StringBuffer('${group.sourceName} · 已缓存 $cached 集');
    if (inFlight > 0) text.write(' · 缓存中 $inFlight 集');
    if (paused > 0) text.write(' · 已暂停 $paused 集');
    if (failed > 0) text.write(' · 失败 $failed 集');
    if (speed > 0) text.write(' · ${formatSpeed(speed)}');
    return text.toString();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Focusable(
                  focusNode: firstFocusNode,
                  onPressed: onToggle,
                  onKeyEvent: (node, event) {
                    if ((event is KeyDownEvent || event is KeyRepeatEvent) &&
                        event.logicalKey == LogicalKeyboardKey.contextMenu) {
                      onDeleteGroup(group);
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                  builder: (context, focused) => FocusFx.scale(
                    focused,
                    Container(
                      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                      decoration:
                          focused ? FocusFx.pill(focused, radius: 15) : null,
                      child: Row(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: SizedBox(
                              width: 52,
                              height: 72,
                              child: NetImage(group.item.posterUrl),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(group.item.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontSize: 19,
                                        fontWeight: FontWeight.w700,
                                        color: focused
                                            ? AppColors.focusInk
                                            : AppColors.text,
                                        fontFamilyFallback: kFontFallback)),
                                const SizedBox(height: 4),
                                Text(_meta,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontSize: 13.5,
                                        color: focused
                                            ? const Color(0xB304121F)
                                            : AppColors.textDim,
                                        fontFamilyFallback: kFontFallback)),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          // Size and chevron live on the card's centring row, not
                          // in the title line, so they line up with the poster.
                          Text(formatBytes(group.totalBytes),
                              style: TextStyle(
                                  fontSize: 13.5,
                                  color: focused
                                      ? const Color(0xB304121F)
                                      : AppColors.textDim,
                                  fontFamilyFallback: kFontFallback)),
                          const SizedBox(width: 12),
                          Text(expanded ? '▾' : '▸',
                              style: TextStyle(
                                  fontSize: 16,
                                  color: focused
                                      ? AppColors.focusInk
                                      : AppColors.textDim,
                                  fontFamilyFallback: kFontFallback)),
                        ],
                      ),
                    ),
                    // No scale: the header sits next to the action chips and a
                    // 1.06 pop used to paint the focus pill over 删除该剧.
                    to: 1.0,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SelectableChip(
                label: '去播放',
                selected: false,
                onPressed: () => app.openDownloadGroup(group),
              ),
              const SizedBox(width: 10),
              SelectableChip(
                label: '删除该剧',
                selected: false,
                onPressed: () => onDeleteGroup(group),
              ),
              const SizedBox(width: 16),
            ],
          ),
          if (expanded) ...[
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 18),
              child:
                  Divider(height: 1, thickness: 1, color: AppColors.hairline),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
              child: Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final task in group.tasks)
                    SizedBox(
                      width: 150,
                      child: _TaskCell(
                        task: task,
                        onPressed: () => _activate(task),
                        onMenu: () => onDeleteTask(task),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _activate(DownloadTask task) async {
    if (task.isComplete) {
      await app.openDownloadEpisode(task);
    } else if (task.isRunning || task.isQueued) {
      await app.downloads.pause(task.id);
    } else {
      await app.downloads.resume(task.id);
    }
  }
}

/// A one-line episode chip: 「第 3 集」 plus a short status on the right.
class _TaskCell extends StatelessWidget {
  const _TaskCell({
    required this.task,
    required this.onPressed,
    required this.onMenu,
  });

  final DownloadTask task;
  final VoidCallback onPressed;
  final VoidCallback onMenu;

  String get _label {
    if (task.episodeTitle.trim().isNotEmpty) return task.episodeTitle;
    return '第${task.episodeIndex + 1}集';
  }

  String get _status {
    switch (task.status) {
      case DownloadStatus.completed:
        return '✓';
      case DownloadStatus.downloading:
        return '${(task.progress * 100).round().clamp(0, 100)}%';
      case DownloadStatus.queued:
        return '等待';
      case DownloadStatus.paused:
        return '暂停';
      case DownloadStatus.failed:
        return '失败';
    }
  }

  Color get _statusColor {
    switch (task.status) {
      case DownloadStatus.completed:
        return AppColors.live;
      case DownloadStatus.failed:
        return AppColors.gold;
      default:
        return AppColors.textDim;
    }
  }

  /// Translucent bar painted behind the label: how much of this episode is
  /// already on disk. Null when there is nothing to show (queued/completed) or
  /// when the cell is focused (the focus pill would hide it anyway).
  Color? get _fillColor {
    switch (task.status) {
      case DownloadStatus.downloading:
        return const Color(0x4000E5FF);
      case DownloadStatus.paused:
        return const Color(0x1FFFFFFF);
      case DownloadStatus.failed:
        return const Color(0x40FFC83D);
      case DownloadStatus.queued:
      case DownloadStatus.completed:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final complete = task.isComplete;
    return Focusable(
      onPressed: onPressed,
      ensureVisibleAlignment: 0.5,
      onKeyEvent: (node, event) {
        if ((event is KeyDownEvent || event is KeyRepeatEvent) &&
            event.logicalKey == LogicalKeyboardKey.contextMenu) {
          onMenu();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      builder: (context, focused) {
        final base = BoxDecoration(
          color: complete ? const Color(0x1F00E5FF) : AppColors.glass,
          borderRadius: BorderRadius.circular(11),
          border: Border.all(
            color: complete ? const Color(0x8C00E5FF) : AppColors.hairline,
          ),
        );
        final fill = focused ? null : _fillColor;
        return FocusFx.scale(
          focused,
          Container(
            height: 40,
            decoration: focused ? FocusFx.pill(focused, radius: 11) : base,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Progress as a left-anchored wash behind the label, so the
                  // cell reads as a bar without a separate progress widget.
                  if (fill != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FractionallySizedBox(
                        key: ValueKey('downloadProgressFill:${task.id}'),
                        widthFactor: task.progress,
                        heightFactor: 1,
                        child: ColoredBox(color: fill),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 11),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w600,
                              color:
                                  focused ? AppColors.focusInk : AppColors.text,
                              fontFamilyFallback: kFontFallback,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _status,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: focused
                                ? const Color(0xB304121F)
                                : _statusColor,
                            fontFamilyFallback: kFontFallback,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 同时下载数 overlay. Back and 关闭 both dismiss it without leaving the page.
///
/// Back is deliberately NOT handled here as a raw key event: on Android it is
/// delivered through the controller's PopScope path, and swallowing the key
/// here would bypass the app-level duplicate-press guard (one physical press
/// can arrive as a key event *and* a pop). The screen registers
/// [AppController.downloadsBackInterceptor] instead.
class _DownloadSettings extends StatelessWidget {
  const _DownloadSettings({required this.downloads, required this.onClose});

  final DownloadManager downloads;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: FocusScope(
        autofocus: true,
        child: FocusTraversalGroup(
          child: ColoredBox(
            color: const Color(0xB3000000),
            child: Center(
              child: Container(
                width: 560,
                padding: const EdgeInsets.fromLTRB(32, 28, 32, 24),
                decoration: BoxDecoration(
                  color: AppColors.cardBg,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: AppColors.hairline),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('同时下载数',
                        style: TextStyle(
                            fontSize: 23,
                            fontWeight: FontWeight.w800,
                            color: AppColors.text,
                            fontFamilyFallback: kFontFallback)),
                    const SizedBox(height: 10),
                    const Text('同时下载的集数。盒子的网络和存储越好，可以调得越高；调整后立即生效。',
                        style: TextStyle(
                            fontSize: 15,
                            height: 1.5,
                            color: AppColors.textDim,
                            fontFamilyFallback: kFontFallback)),
                    const SizedBox(height: 24),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        for (final n in DownloadManager.concurrencyOptions)
                          SelectableChip(
                            label: '$n 集',
                            selected: downloads.concurrency == n,
                            autofocus: downloads.concurrency == n,
                            onPressed: () {
                              unawaited(downloads.setConcurrency(n));
                              onClose();
                            },
                          ),
                      ],
                    ),
                    const SizedBox(height: 26),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        SizedBox(
                          width: 130,
                          child: ActionButton(
                            label: '关闭',
                            onPressed: onClose,
                          ),
                        ),
                      ],
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

class _DeleteConfirm extends StatelessWidget {
  const _DeleteConfirm({
    required this.title,
    required this.message,
    required this.onCancel,
    required this.onConfirm,
  });

  final String title;
  final String message;
  final VoidCallback onCancel;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: FocusScope(
        autofocus: true,
        child: FocusTraversalGroup(
          child: ColoredBox(
            color: const Color(0xB3000000),
            child: Center(
              child: Container(
                width: 520,
                padding: const EdgeInsets.fromLTRB(32, 30, 32, 26),
                decoration: BoxDecoration(
                  color: AppColors.cardBg,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: AppColors.hairline),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            fontSize: 23,
                            fontWeight: FontWeight.w800,
                            color: AppColors.text,
                            fontFamilyFallback: kFontFallback)),
                    const SizedBox(height: 10),
                    Text(message,
                        style: const TextStyle(
                            fontSize: 15,
                            height: 1.5,
                            color: AppColors.textDim,
                            fontFamilyFallback: kFontFallback)),
                    const SizedBox(height: 26),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        SizedBox(
                          width: 130,
                          child: ActionButton(
                            label: '取消',
                            autofocus: true,
                            onPressed: onCancel,
                          ),
                        ),
                        const SizedBox(width: 14),
                        SizedBox(
                          width: 150,
                          child: ActionButton(
                            label: '删除',
                            primary: true,
                            onPressed: onConfirm,
                          ),
                        ),
                      ],
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
