import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

import '../core/app_controller.dart';
import '../core/app_scope.dart';
import '../core/theme.dart';
import '../data/iptv/iptv_models.dart';
import '../data/iptv/iptv_probe.dart';
import '../player/player_controller.dart';
import '../player/video_adapter.dart';
import '../widgets/chips.dart';
import '../widgets/focus_fx.dart';
import '../widgets/focusable.dart';
import '../widgets/net_image.dart';
import '../widgets/on_screen_keyboard.dart';

/// The 直播 (IPTV) tab body. The small (non-fullscreen) view is a clean,
/// full-width inline player that opens straight onto the first channel — a lean
/// "big preview" that only plays: it does not switch channels. OK expands to the
/// D-pad fullscreen live view, where ↑/↓ or OK raises the channel-switch overlay
/// (浮层): a two-level 分组 / 频道 picker that also hosts the 搜索 entry and source
/// switching.
class IptvBrowser extends StatefulWidget {
  const IptvBrowser({super.key});

  @override
  State<IptvBrowser> createState() => _IptvBrowserState();
}

class _IptvBrowserState extends State<IptvBrowser> {
  // Shared with the fullscreen layer so focus is handed back on exit.
  final FocusNode _playerFocus = FocusNode(debugLabel: 'iptvPlayer');

  @override
  void dispose() {
    _playerFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        Padding(
          // Clear the two-row header (logo row + nav tab strip), then let the
          // player fill the rest — the small screen is a lean, big live preview
          // with nothing else on it, so it takes as much room as possible.
          // The box is 16:9 inside a 16:9 area, so its size is bounded by the
          // *vertical* budget: every pixel shaved off top/bottom grows the
          // width too. Top keeps a clear gap below the tab strip (146 sat
          // right under it); bottom keeps just a thin TV-overscan margin.
          padding: const EdgeInsets.fromLTRB(32, 166, 32, 14),
          child: _LiveStage(playerFocus: _playerFocus),
        ),
        if (app.fullscreen) _LiveFullscreen(playerFocus: _playerFocus),
      ],
    );
  }
}

// PLACEHOLDER_APPEND

/// The inline (small-screen) live player: a big, centered 16:9 surface that
/// fills the available area, with the channel name + an "OK 全屏" hint overlaid
/// on its bottom edge. It only plays the auto-selected channel — Up hops back to
/// the nav tabs, the other arrows are swallowed, and OK expands to fullscreen
/// (where channel switching + search live).
class _LiveStage extends StatelessWidget {
  const _LiveStage({required this.playerFocus});

  final FocusNode playerFocus;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final iptv = app.iptv;
    return AnimatedBuilder(
      // Rebuild the whole player subtree on player state changes too (not just
      // iptv): the inline VideoPlayer texture only paints its first frame once
      // this Focusable's builder re-runs after `ready` flips.
      animation: Listenable.merge([iptv, app.player]),
      builder: (context, _) {
        return Center(
          child: Focusable(
            focusNode: playerFocus,
            ensureVisibleAlignment: 0.5,
            onPressed: () {
              if (iptv.currentChannel != null) app.setFullscreen(true);
            },
            // Small screen just plays: Up returns to the nav tab strip so tabs
            // stay reachable; Down/←/→ are swallowed (nothing to switch to here)
            // so focus can't drift off the player. Channel switching lives in
            // fullscreen (OK to enter).
            onKeyEvent: (node, event) {
              if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
                return KeyEventResult.ignored;
              }
              final k = event.logicalKey;
              if (k == LogicalKeyboardKey.arrowUp) {
                return app.focusActiveTab()
                    ? KeyEventResult.handled
                    : KeyEventResult.ignored;
              }
              if (k == LogicalKeyboardKey.arrowDown ||
                  k == LogicalKeyboardKey.arrowLeft ||
                  k == LogicalKeyboardKey.arrowRight) {
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            builder: (context, focused) {
              return AspectRatio(
                aspectRatio: 16 / 9,
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF05070E),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color:
                          focused ? AppColors.accent2 : AppColors.hairline,
                      width: focused ? 2.5 : 1,
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      const _LiveVideoSurface(),
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: _LiveInfoBar(channel: iptv.currentChannel),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

/// A gradient info bar over the bottom of the inline player: LIVE badge +
/// channel name on the left, an "OK 全屏" hint on the right.
class _LiveInfoBar extends StatelessWidget {
  const _LiveInfoBar({required this.channel});
  final IptvChannel? channel;

  @override
  Widget build(BuildContext context) {
    final ch = channel;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 44, 20, 16),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Color(0xCC05070E), Color(0x0005070E)],
        ),
      ),
      child: Row(
        children: [
          if (ch != null) ...[
            const _LiveBadge(),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Text(
              ch == null
                  ? '正在载入频道…'
                  : (ch.group.isNotEmpty && ch.group != '未分组'
                      ? '${ch.name} · ${ch.group}'
                      : ch.name),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 19,
                color: ch == null ? AppColors.textDim : AppColors.text,
                fontWeight: FontWeight.w700,
                fontFamilyFallback: kFontFallback,
              ),
            ),
          ),
          const SizedBox(width: 12),
          const Text(
            'OK 全屏',
            style: TextStyle(
              fontSize: 14,
              color: AppColors.textDim,
              fontFamilyFallback: kFontFallback,
            ),
          ),
        ],
      ),
    );
  }
}

// PLACEHOLDER_APPEND2

/// Red used for the one verdict that means "nothing will ever play".
const Color _warnRed = Color(0xFFFF5F6D);

/// The live player's status chip. Reads "LIVE" while the signal is genuinely
/// live, and the probe's verdict when it isn't — so a channel that "always
/// shows the same thing" says so on the player instead of looking normal.
///
/// Listens to [LiveProbeController] directly (via [AppScope.read]) rather than
/// to the AppController: a verdict change must repaint this chip and nothing
/// else, and the iptv notification path rebuilds the whole channel list.
class _LiveBadge extends StatelessWidget {
  const _LiveBadge({
    this.fontSize = 13,
    this.padding = const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
  });

  final double fontSize;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final probe = AppScope.read(context).liveProbe;
    return AnimatedBuilder(
      animation: probe,
      builder: (context, _) {
        final v = probe.verdict;
        final style = switch (v) {
          LiveVerdict.live => (
              fg: AppColors.live,
              bg: const Color(0x2948E08A),
              border: const Color(0x9948E08A),
            ),
          // Recoverable-ish: the stream is there, it just isn't live.
          LiveVerdict.vod || LiveVerdict.frozen => (
              fg: AppColors.gold,
              bg: const Color(0x29FFCE4D),
              border: const Color(0x99FFCE4D),
            ),
          LiveVerdict.dead => (
              fg: _warnRed,
              bg: const Color(0x29FF5F6D),
              border: const Color(0x99FF5F6D),
            ),
          LiveVerdict.checking => (
              fg: AppColors.textDim,
              bg: AppColors.glass,
              border: AppColors.glassBorder,
            ),
        };
        return Container(
          padding: padding,
          decoration: BoxDecoration(
            color: style.bg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: style.border),
          ),
          child: Text(
            v.label,
            style: TextStyle(
              fontSize: fontSize,
              color: style.fg,
              fontWeight: FontWeight.w700,
              fontFamilyFallback: kFontFallback,
            ),
          ),
        );
      },
    );
  }
}

/// The inline/fullscreen video texture. Renders [VideoPlayer] once ready, else
/// a poster (channel logo + a state hint). Mirrors play_screen's _VideoSurface.
///
/// Listens to `iptv` itself (via [AnimatedBuilder]) so a channel change — which
/// notifies iptv + the player, not the AppController — refreshes the current
/// channel here even though this widget is mounted as a `const` child. It also
/// bumps [_attach] once per controller, changing the [VideoPlayer] key so the
/// texture re-attaches and starts painting on boxes that otherwise stay black.
class _LiveVideoSurface extends StatefulWidget {
  const _LiveVideoSurface();

  @override
  State<_LiveVideoSurface> createState() => _LiveVideoSurfaceState();
}

class _LiveVideoSurfaceState extends State<_LiveVideoSurface> {
  int _attach = 0;
  Object? _kickedFor; // controller instance we've already nudged (once each)

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    // Subscribe to iptv directly. A channel change goes through openChannel,
    // which notifies iptv + the player but NOT the AppController — and this
    // surface sits in the tree as a `const` child, so a parent rebuild alone
    // won't refresh it. Without listening to iptv it therefore kept a stale
    // (null) currentChannel and showed the "select a channel" poster even while
    // audio was already playing — the real cause of the "no picture on first
    // open" report. (Switching tabs / entering fullscreen rebuilt it with the
    // real channel, which is why those appeared to "fix" it.)
    return AnimatedBuilder(
      // Also listen to the probe: when it concludes the source is broken the
      // poster must say so rather than sit on "缓冲中…" forever.
      animation: Listenable.merge([app.iptv, app.liveProbe]),
      builder: (context, _) {
        final ch = app.iptv.currentChannel;

        Widget hint(String text) => Center(
              child: Text(
                text,
                style: const TextStyle(
                  fontSize: 16,
                  color: AppColors.textDim,
                  fontFamilyFallback: kFontFallback,
                ),
              ),
            );

        Widget poster(String text) => Stack(
              fit: StackFit.expand,
              children: [
                const ColoredBox(color: Color(0xFF05070E)),
                if (ch != null && ch.logo.isNotEmpty)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(40),
                      child: NetImage(ch.logo, fit: BoxFit.contain),
                    ),
                  ),
                hint(text),
              ],
            );

        final p = app.player;
        if (p is! VideoAdapter) return poster(ch == null ? '选择频道开始播放' : '');
        return ValueListenableBuilder<PlayerValue>(
          valueListenable: p,
          builder: (context, v, _) {
            final raw = p.raw;
            if (ch == null) return poster('选择频道开始播放');
            if (!v.ready || raw == null || !raw.value.isInitialized) {
              // A broken source never becomes ready, so the generic "缓冲中…"
              // reads as "still loading" indefinitely — the exact shape of the
              // original complaint. Once the probe knows better, say so.
              final verdict = app.liveProbe.verdict;
              return poster(verdict.faulty ? verdict.reason : '缓冲中…');
            }
            // A new channel = a freshly recreated controller (see
            // VideoAdapter.open). Nudge a one-shot re-attach per controller so
            // the inline texture starts painting without a fullscreen round-trip.
            if (!identical(_kickedFor, raw)) {
              _kickedFor = raw;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) setState(() => _attach++);
              });
            }
            return ColoredBox(
              color: const Color(0xFF000000),
              child: Center(
                child: AspectRatio(
                  aspectRatio: raw.value.aspectRatio == 0
                      ? 16 / 9
                      : raw.value.aspectRatio,
                  child: VideoPlayer(
                    raw,
                    key: ValueKey('live_${identityHashCode(raw)}_$_attach'),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

// PLACEHOLDER_APPEND3

/// The two-level channel picker: a left column of groups (with 搜索 as the
/// trailing group-level item) and a right column of the selected group's
/// channels.
///
/// Focus model (deterministic by construction — no post-frame retries, no
/// scroll-estimate nudging, no race):
///   • BOTH columns are *never virtualized* (plain Columns in scroll views), so
///     every group's AND every channel's FocusNode is always built. Focusing
///     any of them — on open, on ←/→ between the columns, or on ↑/↓ within a
///     column — is therefore always a direct, reliable `requestFocus()` that can
///     never land on a detached node. (The old right-column `ListView` was
///     virtualized, so the row we wanted to focus often wasn't built yet; the
///     retry/scroll/bail machinery papered over that with a race that
///     intermittently bounced focus back to the group — "can't enter the
///     channel column". Non-virtualizing it removes that failure entirely.)
///   • ← from any channel returns to the group you entered from; → / OK on a
///     group dives into its channels. Column ends swallow ↑/↓ so focus can never
///     drift out via geometric traversal.
///   • Per-group channel counts are modest (the full playlist is split across
///     groups), so building every row up front is cheap.
class _ChannelList extends StatefulWidget {
  const _ChannelList({
    required this.onPick,
    this.previewOnFocus = false,
    this.focusCurrentOnMount = false,
  });

  /// OK / tap on a row.
  final void Function(IptvChannel) onPick;

  /// When true, focusing a row surfs to it (debounced preview).
  final bool previewOnFocus;

  /// When true, focus the currently-playing channel's row as soon as the list
  /// mounts — so the overlay opens on the live channel.
  final bool focusCurrentOnMount;

  @override
  State<_ChannelList> createState() => _ChannelListState();
}

class _ChannelListState extends State<_ChannelList> {
  final ScrollController _scroll = ScrollController(); // right (channel) column
  final ScrollController _groupScroll = ScrollController(); // left (group) col

  // The 搜索 item lives at the bottom of the group column (group-level).
  final FocusNode _searchNode = FocusNode(debugLabel: 'iptvSearch');

  // One focus node per *position* in each column (not per channel/group),
  // reused across rebuilds so a cell never swaps its node mid-focus. The pools
  // grow to the largest list seen.
  final List<FocusNode> _rowNodes = [];
  final List<FocusNode> _groupNodes = [];

  FocusNode _rowNode(int i) {
    while (_rowNodes.length <= i) {
      _rowNodes.add(FocusNode(debugLabel: 'iptvRow${_rowNodes.length}'));
    }
    return _rowNodes[i];
  }

  FocusNode _groupNode(int i) {
    while (_groupNodes.length <= i) {
      _groupNodes.add(FocusNode(debugLabel: 'iptvGroup${_groupNodes.length}'));
    }
    return _groupNodes[i];
  }

  @override
  void initState() {
    super.initState();
    if (widget.focusCurrentOnMount) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openOnCurrent();
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    _groupScroll.dispose();
    _searchNode.dispose();
    for (final n in _rowNodes) {
      n.dispose();
    }
    for (final n in _groupNodes) {
      n.dispose();
    }
    super.dispose();
  }

  /// On open: sync the active group to the live channel's group and land focus
  /// on that channel's row in the right column. With nothing playing (or no
  /// channels), fall back to the first group / the 搜索 item so focus is never
  /// stranded. Called once on mount.
  void _openOnCurrent() {
    final iptv = AppScope.read(context).iptv;
    final cur = iptv.currentChannel;
    if (cur == null) {
      _backToGroup();
      return;
    }
    // If the live channel sits in a different group than the one shown, syncing
    // to it rebuilds the channel column next frame — so defer the focus until
    // that rebuild lands (the row pool is positional, so focusing before it
    // would briefly land on, and preview, the old group's row at that index).
    final needsRebuild = cur.group != iptv.activeGroup;
    iptv.selectGroup(cur.group); // activeGroup updates synchronously
    if (needsRebuild) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _enterChannels();
      });
    } else {
      _enterChannels();
    }
  }

  /// Move focus from a group into the channel column, landing on the current
  /// channel when it's in the active group, else the first row.
  void _enterChannels() {
    final iptv = AppScope.read(context).iptv;
    final list = iptv.channelsInActiveGroup;
    if (list.isEmpty) return;
    final cur = iptv.currentChannel;
    var idx = cur == null ? 0 : list.indexWhere((c) => c.url == cur.url);
    if (idx < 0) idx = 0;
    _focusChannel(idx);
  }

  /// ← from a channel row (also the mount / no-channel fallback): focus the
  /// group you entered from — the active group — in the left column. Every group
  /// node is always built, so this is a direct, always-reliable requestFocus;
  /// with no groups at all we land on the 搜索 item instead.
  void _backToGroup() {
    final iptv = AppScope.read(context).iptv;
    final groups = iptv.groups;
    if (groups.isEmpty) {
      _searchNode.requestFocus();
      return;
    }
    final active = iptv.activeGroup;
    var idx = active == null ? 0 : groups.indexOf(active);
    if (idx < 0) idx = 0;
    _groupNode(idx).requestFocus();
  }

  /// Open the on-screen keyboard from the 搜索 group-level item.
  Future<void> _openSearch() async {
    final app = AppScope.read(context);
    final q = await showOnScreenKeyboard(
      context,
      title: '搜索频道',
      initial: app.iptv.query,
      hint: '频道名 / 分组',
    );
    if (q != null) app.iptv.search(q.trim());
  }

  /// Focus channel row [idx] in the (non-virtualized) channel column. Every row
  /// node is always built, so this is normally a direct, reliable requestFocus.
  /// The single exception is the instant right after a group change — the new
  /// group's rows are laid out on the next frame — so if the node isn't attached
  /// yet we focus it one frame later. Its `ensureVisibleAlignment` then scrolls
  /// it into view. No retries, no scroll estimates, no fallback-to-group bounce.
  void _focusChannel(int idx) {
    final node = _rowNode(idx);
    if (node.context != null) {
      node.requestFocus();
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _rowNode(idx).requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final iptv = AppScope.of(context).iptv;
    return AnimatedBuilder(
      animation: iptv,
      builder: (context, _) {
        final groups = iptv.groups;
        final active = iptv.activeGroup;
        final grouped = iptv.groupedChannels;
        final channels = iptv.channelsInActiveGroup;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Left column: groups + trailing 搜索. Never virtualized (a plain
            // Column, not a ListView.builder) so every group's FocusNode is
            // always built — ← back-to-group and ↑/↓ between groups are then
            // direct, always-reliable requestFocus calls. Groups are few, so the
            // cost is negligible.
            SizedBox(
              width: 176,
              child: SingleChildScrollView(
                controller: _groupScroll,
                padding: const EdgeInsets.only(right: 6, bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < groups.length; i++)
                      _GroupItem(
                        label: '${groups[i]} (${grouped[groups[i]]?.length ?? 0})',
                        selected: groups[i] == active,
                        focusNode: _groupNode(i),
                        // Focus selects the group so the right column follows the
                        // highlight; → / OK dives into its channels.
                        onFocused: () => iptv.selectGroup(groups[i]),
                        onPressed: _enterChannels,
                        onRight: _enterChannels,
                        onUp: i == 0
                            ? null
                            : () => _groupNode(i - 1).requestFocus(),
                        onDown: i < groups.length - 1
                            ? () => _groupNode(i + 1).requestFocus()
                            : () => _searchNode.requestFocus(),
                      ),
                    _GroupItem(
                      label: iptv.query.isEmpty ? '🔍 搜索' : '🔍 ${iptv.query}',
                      selected: false,
                      focusNode: _searchNode,
                      onPressed: _openSearch,
                      onUp: groups.isEmpty
                          ? null
                          : () => _groupNode(groups.length - 1).requestFocus(),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            // Right column: the selected group's channels. Like the group
            // column, this is NEVER virtualized (a plain Column in a scroll
            // view), so every channel row's FocusNode is always built —
            // entering a group (→ / OK) and stepping rows (↑/↓) are then direct,
            // always-reliable requestFocus calls with no post-frame retries,
            // scroll nudging, or "bounce back to the group" race.
            Expanded(
              child: channels.isEmpty
                  ? const Center(
                      child: Text(
                        '暂无频道',
                        style: TextStyle(
                          fontSize: 15,
                          color: AppColors.textDim,
                          fontFamilyFallback: kFontFallback,
                        ),
                      ),
                    )
                  : SingleChildScrollView(
                      controller: _scroll,
                      padding: const EdgeInsets.only(top: 2, bottom: 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var i = 0; i < channels.length; i++)
                            _ChannelRow(
                              channel: channels[i],
                              current:
                                  channels[i].url == iptv.currentChannel?.url,
                              focusNode: _rowNode(i),
                              onFocused: widget.previewOnFocus
                                  ? () => AppScope.read(context)
                                      .previewChannel(channels[i])
                                  : null,
                              // ← returns to the group you came from; ↑/↓ step
                              // rows (swallowed at the ends); → is swallowed —
                              // focus never drifts out of the column.
                              onLeft: _backToGroup,
                              onUp: i == 0
                                  ? null
                                  : () => _rowNode(i - 1).requestFocus(),
                              onDown: i < channels.length - 1
                                  ? () => _rowNode(i + 1).requestFocus()
                                  : null,
                              onPressed: () => widget.onPick(channels[i]),
                            ),
                        ],
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }
}

/// A left-column item in the two-level picker: a group (selects on focus, → or
/// OK opens its channels on the right) or the trailing 搜索 entry. Vertical moves
/// are explicit ([onUp]/[onDown]); a null handler swallows that key so focus
/// stays inside the menu rather than drifting via geometric traversal. ← is
/// always swallowed — the group column is the leftmost thing in the panel.
class _GroupItem extends StatelessWidget {
  const _GroupItem({
    required this.label,
    required this.selected,
    required this.onPressed,
    this.focusNode,
    this.onFocused,
    this.onUp,
    this.onDown,
    this.onRight,
  });
  final String label;
  final bool selected;
  final VoidCallback onPressed;
  final FocusNode? focusNode;
  final VoidCallback? onFocused;
  final VoidCallback? onUp;
  final VoidCallback? onDown;
  final VoidCallback? onRight;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Focusable(
        focusNode: focusNode,
        onFocused: onFocused,
        onPressed: onPressed,
        ensureVisibleAlignment: 0.5,
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
            return KeyEventResult.ignored;
          }
          final k = event.logicalKey;
          if (k == LogicalKeyboardKey.arrowUp) {
            onUp?.call();
            return KeyEventResult.handled; // swallow at the top
          }
          if (k == LogicalKeyboardKey.arrowDown) {
            onDown?.call();
            return KeyEventResult.handled; // swallow at the bottom
          }
          if (k == LogicalKeyboardKey.arrowRight) {
            onRight?.call();
            return KeyEventResult.handled; // → dives into channels (or swallow)
          }
          if (k == LogicalKeyboardKey.arrowLeft) {
            return KeyEventResult.handled; // leftmost — nothing to the left
          }
          return KeyEventResult.ignored;
        },
        builder: (context, focused) {
          final base = BoxDecoration(
            color: selected ? const Color(0x294EA8FF) : AppColors.glass,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? const Color(0x994EA8FF) : AppColors.hairline,
              width: 2,
            ),
          );
          return FocusFx.scale(
            focused,
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: focused ? FocusFx.pill(focused, radius: 12) : base,
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 15,
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
      ),
    );
  }
}

/// One focusable channel row (logo + name), with a playing indicator.
///
/// D-pad within a row is owned explicitly (not left to Flutter's geometric
/// traversal, which drifts across boundaries): [onUp]/[onDown] step rows (null
/// at the ends swallows the key), [onLeft] hops back to the group column, and →
/// is swallowed so focus can never escape sideways off the list.
class _ChannelRow extends StatelessWidget {
  const _ChannelRow({
    required this.channel,
    required this.current,
    required this.onPressed,
    this.focusNode,
    this.onFocused,
    this.onLeft,
    this.onUp,
    this.onDown,
  });
  final IptvChannel channel;
  final bool current;
  final VoidCallback onPressed;
  final FocusNode? focusNode;

  /// Called when the row gains focus (used for debounced channel surfing).
  final VoidCallback? onFocused;

  /// ← handler: returns to the group column. → is always swallowed.
  final VoidCallback? onLeft;

  /// ↑/↓ handlers (step to the prev/next row). Null swallows that key so focus
  /// stays put at the list's ends instead of drifting off via traversal.
  final VoidCallback? onUp;
  final VoidCallback? onDown;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Focusable(
        focusNode: focusNode,
        onPressed: onPressed,
        onFocused: onFocused,
        ensureVisibleAlignment: 0.5,
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
            return KeyEventResult.ignored;
          }
          final k = event.logicalKey;
          if (k == LogicalKeyboardKey.arrowRight) {
            return KeyEventResult.handled; // nothing to the right — swallow
          }
          if (k == LogicalKeyboardKey.arrowLeft) {
            onLeft?.call(); // ← back to the group column
            return KeyEventResult.handled;
          }
          if (k == LogicalKeyboardKey.arrowUp) {
            onUp?.call();
            return KeyEventResult.handled; // swallow at the top row
          }
          if (k == LogicalKeyboardKey.arrowDown) {
            onDown?.call();
            return KeyEventResult.handled; // swallow at the bottom row
          }
          return KeyEventResult.ignored;
        },
        builder: (context, focused) {
          final bg = focused
              ? AppColors.accent
              : (current ? const Color(0x1F48E08A) : AppColors.glass);
          final fg = focused
              ? AppColors.focusInk
              : (current ? AppColors.live : AppColors.text);
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 40,
                  height: 28,
                  child: channel.logo.isEmpty
                      ? const SizedBox.shrink()
                      : NetImage(channel.logo, fit: BoxFit.contain),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    channel.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 16,
                      color: fg,
                      fontWeight: current ? FontWeight.w700 : FontWeight.w500,
                      fontFamilyFallback: kFontFallback,
                    ),
                  ),
                ),
                if (current)
                  Text(
                    '▶',
                    style: TextStyle(
                      fontSize: 14,
                      color: fg,
                      fontFamilyFallback: kFontFallback,
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

// PLACEHOLDER_APPEND4

/// Fullscreen live view. D-pad: ←/→ prev/next channel, ↑/↓/OK opens the channel
/// list overlay (OK too so phones without a D-pad can reach it), Back exits (or
/// closes the overlay first). Rendered inside the home layer, above everything,
/// when [AppController.fullscreen].
class _LiveFullscreen extends StatefulWidget {
  const _LiveFullscreen({required this.playerFocus});

  /// The inline player's focus node. The inline layer stays mounted underneath
  /// this overlay, so we restore focus to it on exit (and must steal focus from
  /// it on entry — see [_rootFocus]).
  final FocusNode playerFocus;

  @override
  State<_LiveFullscreen> createState() => _LiveFullscreenState();
}

class _LiveFullscreenState extends State<_LiveFullscreen> {
  bool _menuOpen = false;
  String? _osd;
  Timer? _osdTimer;
  late final bool Function() _backIntercept;

  // Our own key handler's focus node. `autofocus` alone can't claim focus here
  // because the inline player's node (a sibling FocusScope descendant that
  // stays mounted below us) already holds it — so we explicitly steal focus on
  // mount and hand it back on unmount.
  final FocusNode _rootFocus = FocusNode(debugLabel: 'iptvFullscreenRoot');

  /// Captured on mount so [dispose] can unregister without an inherited-widget
  /// lookup: by the time `dispose` runs the element is already defunct, and
  /// looking up an ancestor then trips an assertion ("Looking up a deactivated
  /// widget's ancestor is unsafe") on every fullscreen exit.
  late final AppController _app;

  @override
  void initState() {
    super.initState();
    _app = AppScope.read(context);
    _backIntercept = () {
      if (_menuOpen) {
        _closeMenu();
        return true;
      }
      return false;
    };
    _app.fullscreenBackInterceptor = _backIntercept;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _rootFocus.requestFocus();
    });
  }

  /// Close the channel overlay and pull key handling back to the fullscreen root
  /// (the overlay's list stole focus when it opened).
  void _closeMenu() {
    setState(() => _menuOpen = false);
    _rootFocus.requestFocus();
  }

  /// Raise the channel picker. Driven both by the TV remote (↑/↓/OK in [_onKey])
  /// and by a screen tap (phones have no D-pad — a tap is a pointer event, not a
  /// `select` key, so it can't go through [_onKey]).
  void _openMenu() {
    if (!_menuOpen) setState(() => _menuOpen = true);
  }

  @override
  void dispose() {
    if (_app.fullscreenBackInterceptor == _backIntercept) {
      _app.fullscreenBackInterceptor = null;
    }
    _osdTimer?.cancel();
    // Return focus to the inline player we stole it from (post-frame: this node
    // is being torn down this frame). Capture the node before the async gap.
    final restore = widget.playerFocus;
    WidgetsBinding.instance.addPostFrameCallback((_) => restore.requestFocus());
    _rootFocus.dispose();
    super.dispose();
  }

  void _flashOsd(String text) {
    setState(() => _osd = text);
    _osdTimer?.cancel();
    _osdTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _osd = null);
    });
  }

  /// Step to the previous/next channel within the current filtered list.
  void _step(int delta) {
    final app = AppScope.read(context);
    final list = app.iptv.filteredChannels;
    if (list.isEmpty) return;
    final cur = app.iptv.currentChannel;
    var idx = cur == null ? -1 : list.indexWhere((c) => c.url == cur.url);
    idx = (idx + delta) % list.length;
    if (idx < 0) idx += list.length;
    final next = list[idx];
    app.openChannel(next);
    _flashOsd(next.name);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (_menuOpen) return KeyEventResult.ignored;
    final k = event.logicalKey;
    // ↑ / ↓ / OK all raise the channel picker — OK included so phones (which
    // have no D-pad, only a tap that maps to select) can reach channel
    // switching. It syncs to the live channel's group and lands focus on the
    // current row (see [_ChannelList]).
    if (k == LogicalKeyboardKey.arrowUp ||
        k == LogicalKeyboardKey.arrowDown ||
        k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter ||
        k == LogicalKeyboardKey.gameButtonA) {
      setState(() => _menuOpen = true);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft) {
      _step(-1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight) {
      _step(1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return Focus(
      focusNode: _rootFocus,
      autofocus: true,
      // Excluded from arrow/tab traversal so the channel overlay can never
      // accidentally hand focus back to the root (which would strand the D-pad);
      // we still drive it via explicit requestFocus.
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: ColoredBox(
        color: const Color(0xFF000000),
        child: Stack(
          fit: StackFit.expand,
          children: [
            const _LiveVideoSurface(),
            // Touch input (phones have no D-pad): a tap on the video raises the
            // channel picker, and a tap on the empty area beside/around the open
            // panel closes it. Sits above the video but below the overlay panel,
            // so taps on the panel's own rows still reach them.
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _menuOpen ? _closeMenu() : _openMenu(),
              ),
            ),
            // Channel name + status chip, bottom-left.
            const Positioned(
              left: 36,
              bottom: 32,
              child: _LiveChannelTag(),
            ),
            if (_osd != null)
              Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 26, vertical: 16),
                  decoration: BoxDecoration(
                    color: const Color(0x99000000),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    _osd!,
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w700,
                      color: AppColors.text,
                      fontFamilyFallback: kFontFallback,
                    ),
                  ),
                ),
              ),
            if (_menuOpen)
              _ChannelOverlay(
                // Keep the overlay open while switching — picking (or focusing)
                // a channel plays it in place. Back closes the overlay.
                onPick: (c) => app.openChannel(c),
              ),
          ],
        ),
      ),
    );
  }
}

// PLACEHOLDER_APPEND5

/// The fullscreen player's bottom-left "now playing" tag: the status chip plus
/// the channel name.
///
/// It listens to `iptv` itself rather than reading `currentChannel` in
/// [_LiveFullscreenState.build]. A channel change goes through `openChannel`,
/// which notifies `iptv` + the player but NOT the AppController — and the
/// fullscreen root only rebuilds on AppController notifications and its own
/// `setState`. Reading the channel there therefore froze the name at whatever
/// was playing when the layer mounted: picking a channel with the 浮层 open
/// (the overlay keeps itself open by design, so no `setState` fires) left the
/// old name on screen until the overlay was closed. Same trap, same fix as
/// [_LiveVideoSurface].
class _LiveChannelTag extends StatelessWidget {
  const _LiveChannelTag();

  @override
  Widget build(BuildContext context) {
    final iptv = AppScope.read(context).iptv;
    return AnimatedBuilder(
      animation: iptv,
      builder: (context, _) {
        return Row(
          children: [
            const _LiveBadge(
              fontSize: 14,
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            ),
            const SizedBox(width: 12),
            Text(
              iptv.currentChannel?.name ?? '未选择频道',
              style: const TextStyle(
                fontSize: 22,
                color: AppColors.text,
                fontWeight: FontWeight.w700,
                fontFamilyFallback: kFontFallback,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Right-docked channel switcher (浮层) for the fullscreen live view (↑/↓/OK
/// raises it). Styled like the play screen's 播放设置 side panel (right-aligned
/// gradient scrim). The header shows the 频道 title + count; a source-switch row
/// appears when more than one source is configured; below is the two-level
/// picker (groups on the left with 搜索 as the last group-level item, channels on
/// the right). Moving focus surfs channels in place (the overlay stays open); OK
/// plays a channel immediately.
class _ChannelOverlay extends StatelessWidget {
  const _ChannelOverlay({required this.onPick});
  final void Function(IptvChannel) onPick;

  @override
  Widget build(BuildContext context) {
    final iptv = AppScope.of(context).iptv;
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        width: 560,
        height: double.infinity,
        padding: const EdgeInsets.fromLTRB(28, 40, 24, 32),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.centerRight,
            end: Alignment.centerLeft,
            colors: [Color(0xF2060A14), Color(0xB3060A14), Color(0x00060A14)],
          ),
        ),
        child: FocusTraversalGroup(
          child: AnimatedBuilder(
            animation: iptv,
            builder: (context, _) {
              final multiSource = iptv.sources.length > 1;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Title + count. Search now lives inside the picker's left
                  // column as the trailing group-level item.
                  Row(
                    children: [
                      const Text(
                        '频道',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
                          color: AppColors.text,
                          fontFamilyFallback: kFontFallback,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        '${iptv.filteredChannels.length}',
                        style: const TextStyle(
                          fontSize: 15,
                          color: AppColors.textDim,
                          fontFamilyFallback: kFontFallback,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    '← → 切换分组与频道 · 返回关闭',
                    style: TextStyle(
                      fontSize: 14,
                      color: AppColors.textDim,
                      fontFamilyFallback: kFontFallback,
                    ),
                  ),
                  if (multiSource) ...[
                    const SizedBox(height: 14),
                    _SourceRow(),
                  ],
                  const SizedBox(height: 16),
                  Expanded(
                    child: _ChannelList(
                      previewOnFocus: true,
                      focusCurrentOnMount: true,
                      onPick: onPick,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Horizontal source-switch chips shown in the overlay when more than one
/// direct source is configured.
class _SourceRow extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final iptv = AppScope.of(context).iptv;
    return SizedBox(
      height: 46,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final s in iptv.sources)
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: SelectableChip(
                label: s.name,
                selected: s.id == iptv.selectedSourceId,
                onPressed: () => iptv.selectSource(s.id),
              ),
            ),
        ],
      ),
    );
  }
}





