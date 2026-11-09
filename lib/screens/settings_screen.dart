import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../core/app_scope.dart';
import '../core/theme.dart';
import '../core/update_controller.dart';
import '../data/config_import.dart';
import '../data/danmaku/danmaku_models.dart';
import '../data/vod/cms_models.dart';
import '../widgets/chips.dart';
import '../widgets/focus_fx.dart';
import '../widgets/focusable.dart';
import '../widgets/on_screen_keyboard.dart';

/// Settings page: TMDB API key + playback source management. All text entry
/// goes through [showOnScreenKeyboard] rather than native TextFields, since a
/// focused EditableText traps the TV remote's directional keys.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _obscure = true;

  /// The advanced panel (TMDB Key + network proxy) starts collapsed — most
  /// users never touch these, so they're tucked away below the source config.
  bool _advancedExpanded = false;

  /// Source awaiting a MENU-key delete confirmation.
  CmsSite? _pendingDelete;

  /// Last import URL for this session (not persisted). Export will later reuse
  /// the same 配置导入 card.
  String _importUrl = '';

  /// Scope over the page's controls, so [_moveByRow] only considers this page's
  /// focusables (not the header/nav that live in the surrounding Shell).
  final FocusScopeNode _pageScope = FocusScopeNode(debugLabel: 'settingsScope');

  /// Two focusables are on the same visual row if their centers' dy differ by
  /// less than this. Rows here are separated by ≥40px, so 20 is safe.
  static const double _rowTol = 20;

  @override
  void dispose() {
    _pageScope.dispose();
    super.dispose();
  }

  /// D-pad Down/Up: jump to the leftmost control of the next/previous visual
  /// row (always landing 靠左), instead of geometric (which skips a left-aligned
  /// control sitting under a right-aligned one) or reading-order (which steps
  /// through every button/chip in a row). Left/Right stay geometric, so they
  /// move within the current row.
  void _moveByRow(bool forward) {
    final current = FocusManager.instance.primaryFocus;
    final nodes = _pageScope.traversalDescendants
        .where((n) => n.canRequestFocus && !n.skipTraversal)
        .toList();
    if (nodes.isEmpty) return;
    // Reading order: top-to-bottom, then left-to-right.
    nodes.sort((a, b) {
      final dy = a.rect.center.dy.compareTo(b.rect.center.dy);
      return dy != 0 ? dy : a.rect.center.dx.compareTo(b.rect.center.dx);
    });
    // Cluster into visual rows, each sorted left-to-right.
    final rows = <List<FocusNode>>[];
    for (final n in nodes) {
      if (rows.isEmpty ||
          (n.rect.center.dy - rows.last.first.rect.center.dy).abs() > _rowTol) {
        rows.add(<FocusNode>[n]);
      } else {
        rows.last.add(n);
      }
    }
    for (final r in rows) {
      r.sort((a, b) => a.rect.center.dx.compareTo(b.rect.center.dx));
    }
    // Locate the current row (by identity, else by dy).
    var curRow = -1;
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].any((n) => identical(n, current))) {
        curRow = i;
        break;
      }
    }
    if (curRow == -1 && current != null) {
      final cy = current.rect.center.dy;
      for (var i = 0; i < rows.length; i++) {
        if ((rows[i].first.rect.center.dy - cy).abs() <= _rowTol) {
          curRow = i;
          break;
        }
      }
    }
    if (curRow == -1) return;
    final target = forward ? curRow + 1 : curRow - 1;
    if (target < 0 || target >= rows.length) return;
    rows[target].first.requestFocus();
  }

  Future<void> _editKey() async {
    final app = AppScope.read(context);
    final result = await showOnScreenKeyboard(
      context,
      title: '输入 TMDB API Key',
      initial: app.settings.tmdbApiKey,
      hint: '在此输入 v3 API Key',
    );
    if (result != null && mounted) {
      app.saveApiKey(result.trim());
      app.showToast('已保存并加载');
    }
  }

  void _requestDelete(CmsSite site) {
    if (_pendingDelete == null) setState(() => _pendingDelete = site);
  }

  /// One click opens the address keyboard (cancel / 导入); confirming fetches,
  /// validates and applies in one go.
  Future<void> _openImport() async {
    final app = AppScope.read(context);
    final url = await showOnScreenKeyboard(
      context,
      title: '配置导入地址',
      initial: _importUrl,
      hint: 'https://example.com/config.json',
      confirmLabel: '导入',
    );
    if (url == null || !mounted) return;
    _importUrl = url.trim();
    if (_importUrl.isEmpty) {
      app.showToast('请填写导入地址');
      return;
    }
    app.showToast('正在导入配置…');
    try {
      final plan = await app.loadConfigImport(_importUrl);
      if (!mounted) return;
      if (plan.isEmpty) {
        app.showToast('该配置没有可导入的内容');
        return;
      }
      await app.applyConfigImport(plan);
    } on ConfigImportException catch (e) {
      if (mounted) app.showToast(e.message);
    } catch (_) {
      if (mounted) app.showToast('导入失败，请检查地址或网络');
    }
  }

  /// Full-screen confirmation for destructive actions (currently source delete).
  Widget _confirmDialog({
    required String title,
    required String body,
    required String confirmLabel,
    required VoidCallback onConfirm,
    required VoidCallback onCancel,
  }) {
    return FocusScope(
      autofocus: true,
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
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        color: AppColors.text,
                        fontFamilyFallback: kFontFallback)),
                const SizedBox(height: 10),
                Text(body,
                    style: const TextStyle(
                        fontSize: 16,
                        height: 1.6,
                        color: AppColors.textDim,
                        fontFamilyFallback: kFontFallback)),
                const SizedBox(height: 26),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    _Btn(label: '取消', autofocus: true, onPressed: onCancel),
                    const SizedBox(width: 14),
                    _Btn(
                        label: confirmLabel,
                        primary: true,
                        onPressed: onConfirm),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget? _activeOverlay() {
    final app = AppScope.read(context);
    final site = _pendingDelete;
    if (site != null) {
      return _confirmDialog(
        title: '删除资源站？',
        body: '将从配置中移除「${site.name}」。需要时可重新添加，或通过「配置导入」恢复。',
        confirmLabel: '删除',
        onCancel: () => setState(() => _pendingDelete = null),
        onConfirm: () {
          setState(() => _pendingDelete = null);
          app.removeCmsSite(site.id);
          app.showToast('已删除资源站');
        },
      );
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final overlay = _activeOverlay();
    // TV D-pad model for this mixed layout (full-width fields, horizontal
    // button rows, and a Wrap of source chips): Down/Up move by *row*,
    // Left/Right move within a row. See [_moveByRow] for why neither pure
    // geometric nor pure reading-order traversal works here.
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.arrowDown): _RowMoveIntent(true),
        SingleActivator(LogicalKeyboardKey.arrowUp): _RowMoveIntent(false),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _RowMoveIntent: CallbackAction<_RowMoveIntent>(
            onInvoke: (intent) {
              _moveByRow(intent.forward);
              return null;
            },
          ),
        },
        child: FocusScope(
          node: _pageScope,
          child: Stack(
            fit: StackFit.expand,
            children: [
              IgnorePointer(
                ignoring: overlay != null,
                child: ExcludeFocus(
                  excluding: overlay != null,
                  child: SafeArea(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(
                          AppDims.pad, 150, AppDims.pad, 60),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 900),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('设置',
                                  style: TextStyle(
                                      fontSize: 40,
                                      fontWeight: FontWeight.w800,
                                      color: AppColors.text,
                                      fontFamilyFallback: kFontFallback)),
                              const SizedBox(height: 6),
                              const Text('数据源与播放配置',
                                  style: TextStyle(
                                      fontSize: 17,
                                      color: AppColors.textDim,
                                      fontFamilyFallback: kFontFallback)),
                              const SizedBox(height: 34),
                              _sectionCard(
                                title: '配置导入',
                                subtitle:
                                    '从地址一键导入 TMDB、资源站、直播源与弹幕源配置。导入会覆盖地址中包含的配置项，未包含的项目保持不变。',
                                child: _ConfigTransferSection(
                                    onImport: _openImport),
                              ),
                              const SizedBox(height: 22),
                              _sectionCard(
                                title: '资源配置',
                                subtitle:
                                    '播放源用于按片名解析可播放地址。点击选中或取消，按菜单键(MENU)删除。',
                                child: _CmsSourcesSection(
                                    onRequestDelete: _requestDelete),
                              ),
                              const SizedBox(height: 22),
                              _sectionCard(
                                title: '直播源配置',
                                subtitle:
                                    '添加 M3U / M3U8 播放列表地址，用于「直播」标签页。可添加多个源并在直播页快捷切换。',
                                child: const _IptvSourcesSection(),
                              ),
                              const SizedBox(height: 22),
                              _sectionCard(
                                title: '弹幕源配置',
                                subtitle:
                                    '添加 dandanplay 兼容的弹幕服务（地址 + Token，Token 必填）。可添加多个源，点击名称设为默认，播放时自动使用默认源匹配弹幕。',
                                child: const _DanmakuHostsSection(),
                              ),
                              const SizedBox(height: 22),
                              _sectionCard(
                                title: '输入法配置',
                                subtitle:
                                    '开启后使用设备自带输入法：搜索页为原生输入框，选中后按「确定」呼出系统键盘（可用你熟悉的中文输入）。关闭则使用内置离线拼音键盘。',
                                child: const _SearchImeSection(),
                              ),
                              const SizedBox(height: 22),
                              _sectionCard(
                                title: '版本更新',
                                subtitle:
                                    '检查仓库 main 分支 pubspec.yaml 声明的版本；发现新版本时按当前设备架构下载对应 APK，下载完成后交给系统安装器完成更新。',
                                child: const _UpdaterSection(),
                              ),
                              const SizedBox(height: 22),
                              _advancedPanel(),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (overlay != null) Positioned.fill(child: overlay),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionCard(
      {required String title,
      required String subtitle,
      required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: AppColors.text,
                  fontFamilyFallback: kFontFallback)),
          const SizedBox(height: 8),
          Text(subtitle,
              style: const TextStyle(
                  fontSize: 15,
                  height: 1.6,
                  color: AppColors.textDim,
                  fontFamilyFallback: kFontFallback)),
          const SizedBox(height: 20),
          child,
        ],
      ),
    );
  }

  /// Collapsible "高级配置" card: a focusable header row that toggles between the
  /// TMDB API Key and network-proxy controls. Collapsed by default so the source
  /// config stays front-and-center. When collapsed the inner controls are absent
  /// from the tree, so [_moveByRow] naturally skips them.
  Widget _advancedPanel() {
    final app = AppScope.of(context);
    final key = app.settings.tmdbApiKey;
    final masked =
        key.isEmpty ? '' : (_obscure ? '•' * key.length.clamp(0, 24) : key);
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Focusable(
            onPressed: () =>
                setState(() => _advancedExpanded = !_advancedExpanded),
            builder: (context, focused) {
              return Container(
                padding: const EdgeInsets.all(28),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: focused ? AppColors.accent : const Color(0x00000000),
                    width: 2,
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: const [
                          Text('高级配置',
                              style: TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.text,
                                  fontFamilyFallback: kFontFallback)),
                          SizedBox(height: 8),
                          Text('TMDB API Key 与网络代理，一般无需修改。',
                              style: TextStyle(
                                  fontSize: 15,
                                  height: 1.6,
                                  color: AppColors.textDim,
                                  fontFamilyFallback: kFontFallback)),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    Text(_advancedExpanded ? '收起 ▲' : '展开 ▼',
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color:
                                focused ? AppColors.accent : AppColors.textDim,
                            fontFamilyFallback: kFontFallback)),
                  ],
                ),
              );
            },
          ),
          if (_advancedExpanded) ...[
            Container(height: 1, color: AppColors.hairline),
            Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _SubLabel('TMDB API Key'),
                  const SizedBox(height: 8),
                  const Text(
                      '内容目录来自 TMDB。请在 themoviedb.org → 账号设置 → API 申请 v3 Key 并填入此处。',
                      style: TextStyle(
                          fontSize: 15,
                          height: 1.6,
                          color: AppColors.textDim,
                          fontFamilyFallback: kFontFallback)),
                  const SizedBox(height: 16),
                  _ValueField(
                    value: masked,
                    hint: '未设置（点此输入 API Key）',
                    onPressed: _editKey,
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      _Btn(label: '修改 Key', primary: true, onPressed: _editKey),
                      const SizedBox(width: 14),
                      _Btn(
                          label: _obscure ? '显示' : '隐藏',
                          onPressed: () =>
                              setState(() => _obscure = !_obscure)),
                    ],
                  ),
                  const SizedBox(height: 28),
                  const _SubLabel('网络代理'),
                  const SizedBox(height: 8),
                  const Text(
                      'TMDB 接口与海报图片在部分网络（如国内电视盒子）无法直连。开启后经此代理访问；关闭则直连 themoviedb.org 原域名。代理需按 TMDB 路径转发（<代理>/3 接口、<代理>/t/p 图片）。',
                      style: TextStyle(
                          fontSize: 15,
                          height: 1.6,
                          color: AppColors.textDim,
                          fontFamilyFallback: kFontFallback)),
                  const SizedBox(height: 16),
                  const _ProxySection(),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A D-pad-focusable faux input: shows the current value (or hint) and opens the
/// on-screen keyboard when activated. Replaces native TextFields on this page.
class _ValueField extends StatelessWidget {
  const _ValueField(
      {required this.value, required this.hint, required this.onPressed});
  final String value;
  final String hint;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Focusable(
      onPressed: onPressed,
      ensureVisibleAlignment: 0.5,
      builder: (context, focused) {
        return Container(
          height: 56,
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          decoration: BoxDecoration(
            color: const Color(0x14FFFFFF),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: focused ? AppColors.accent : AppColors.glassBorder,
                width: focused ? 2 : 1),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  value.isEmpty ? hint : value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 18,
                      color: value.isEmpty ? AppColors.textDim : AppColors.text,
                      fontFamilyFallback: kFontFallback),
                ),
              ),
              const SizedBox(width: 12),
              Text('修改',
                  style: TextStyle(
                      fontSize: 15,
                      color: focused ? AppColors.accent : AppColors.textDim,
                      fontFamilyFallback: kFontFallback)),
            ],
          ),
        );
      },
    );
  }
}

/// TMDB network proxy controls: an on/off toggle plus an editable proxy origin.
class _ProxySection extends StatelessWidget {
  const _ProxySection();

  Future<void> _editBase(BuildContext context) async {
    final app = AppScope.read(context);
    final result = await showOnScreenKeyboard(
      context,
      title: '代理地址',
      initial: app.proxyBase,
      hint: '例如：https://your-proxy.example.com',
    );
    if (result == null) return;
    final v = result.trim();
    if (v.isEmpty) {
      app.showToast('代理地址不能为空');
      return;
    }
    if (!v.startsWith('http://') && !v.startsWith('https://')) {
      app.showToast('代理地址需以 http 开头');
      return;
    }
    await app.setProxyBase(v);
    app.showToast('已保存代理地址');
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final on = app.proxyEnabled;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _Btn(
              label: on ? '代理：已开启' : '代理：已关闭',
              primary: on,
              onPressed: () => app.setProxyEnabled(!on),
            ),
            const SizedBox(width: 14),
            Text(
              on ? '经代理访问 TMDB' : '直连 themoviedb.org',
              style: const TextStyle(
                  fontSize: 15,
                  color: AppColors.textDim,
                  fontFamilyFallback: kFontFallback),
            ),
          ],
        ),
        const SizedBox(height: 16),
        const _SubLabel('代理地址'),
        const SizedBox(height: 12),
        _ValueField(
          value: app.proxyBase,
          hint: '例如：https://your-proxy.example.com',
          onPressed: () => _editBase(context),
        ),
      ],
    );
  }
}

/// Search input-method toggle: system IME (native field + system keyboard) vs.
/// the built-in offline pinyin keyboard.
class _SearchImeSection extends StatelessWidget {
  const _SearchImeSection();

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final on = app.searchUseSystemIme;
    return Row(
      children: [
        _Btn(
          label: on ? '系统输入法：已开启' : '系统输入法：已关闭',
          primary: on,
          onPressed: () => app.setSearchUseSystemIme(!on),
        ),
        const SizedBox(width: 14),
        Text(
          on ? '原生输入框 · 确定呼出系统键盘' : '内置离线拼音键盘',
          style: const TextStyle(
              fontSize: 15,
              color: AppColors.textDim,
              fontFamilyFallback: kFontFallback),
        ),
      ],
    );
  }
}

/// In-app updater: shows the installed version, checks GitHub for a newer
/// release, downloads the APK matching this device's ABI, and hands it to the
/// system installer. Owns a private [UpdateController] — nothing here touches
/// app-wide state.
class _UpdaterSection extends StatefulWidget {
  const _UpdaterSection();

  @override
  State<_UpdaterSection> createState() => _UpdaterSectionState();
}

class _UpdaterSectionState extends State<_UpdaterSection> {
  late final UpdateController _c = UpdateController();

  @override
  void initState() {
    super.initState();
    _c.addListener(_onChanged);
    _c.check();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _c.removeListener(_onChanged);
    _c.dispose();
    super.dispose();
  }

  static String _fmtSize(int bytes) =>
      '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';

  static const _dim = TextStyle(
      fontSize: 15, color: AppColors.textDim, fontFamilyFallback: kFontFallback);
  static const _info = TextStyle(
      fontSize: 16, color: AppColors.text, fontFamilyFallback: kFontFallback);

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final app = c.appInfo;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const _SubLabel('当前版本'),
            const SizedBox(width: 14),
            Text(
              app == null
                  ? '读取中…'
                  : 'v${app.versionName} · Build ${app.versionCode}',
              style: _info,
            ),
          ],
        ),
        if (app != null && app.supportedAbis.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text('设备架构：${app.supportedAbis.join(' / ')}', style: _dim),
        ],
        const SizedBox(height: 18),
        ..._statusRows(c),
      ],
    );
  }

  /// Status line + action row, one slot per state.
  ///
  /// The action button keeps the same child position across every state, so
  /// re-rendering never unmounts the focused control: pressing 重新检查 /
  /// 下载更新 / 安装更新 leaves the D-pad focus on that button (shown as
  /// 检查中… / 下载中… meanwhile) instead of falling back to the page's first
  /// focusable. _Btn is stateless w.r.t. focus — the FocusNode rides on the
  /// reused Element.
  List<Widget> _statusRows(UpdateController c) {
    final Widget status;
    final List<Widget> actions;
    switch (c.state) {
      case UpdateState.idle:
        status = const Text('尚未检查', style: _dim);
        actions = [_primary('检查更新', c.check, primary: true)];
        break;
      case UpdateState.checking:
        status = const Text('正在检查更新…', style: _dim);
        // Same slot as the button that started the check — keeps its focus.
        actions = [_primary('检查中…', c.check)];
        break;
      case UpdateState.upToDate:
        status =
            Text('已是最新版本 v${c.appInfo?.versionName ?? ''} ✓', style: _info);
        actions = [_primary('重新检查', c.check)];
        break;
      case UpdateState.failed:
        status = Text(c.error ?? '操作失败，请重试', style: _errorStyle);
        actions = [_primary('重试', c.retry)];
        break;
      case UpdateState.available:
        final r = c.release!;
        final abi = c.abi;
        if (abi == null) {
          status = const Text('该版本没有提供此设备架构可用的安装包', style: _dim);
          actions = const [];
        } else {
          status = Text('发现新版本 v${r.baseVersion}', style: _info);
          actions = [_primary('下载更新（$abi）', c.download, primary: true)];
        }
        break;
      case UpdateState.downloading:
        status = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _ProgressBar(value: c.progress),
            const SizedBox(height: 8),
            Text(
              c.progress <= 0
                  ? '正在连接…'
                  : '下载中 ${(c.progress * 100).round()}%',
              style: _dim,
            ),
          ],
        );
        actions = [_primary('下载中…', () {})];
        break;
      case UpdateState.downloaded:
        status = Text('更新包已下载（${_fmtSize(c.apkSize)}）', style: _info);
        actions = [
          _primary('安装更新', c.install, primary: true),
          const SizedBox(width: 10),
          _primary('重新下载', c.download),
        ];
        break;
    }
    return [
      status,
      const SizedBox(height: 14),
      ...actions,
    ];
  }

  /// A section action button; [primary] styles it as the main action.
  static Widget _primary(String label, VoidCallback onPressed,
          {bool primary = false}) =>
      _Btn(label: label, primary: primary, onPressed: onPressed);

  static const _errorStyle = TextStyle(
      fontSize: 15,
      color: Color(0xFFFF8A80),
      fontFamilyFallback: kFontFallback);
}

/// Thin progress track; a value <= 0 means "starting" (content length unknown
/// yet), rendered as a small accent nub so the row still reads as in progress.
class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.value});
  final double value;

  @override
  Widget build(BuildContext context) {
    final v = value.clamp(0.0, 1.0);
    return Container(
      height: 10,
      decoration: BoxDecoration(
        color: const Color(0x14FFFFFF),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: v <= 0 ? 0.08 : v,
          child: Container(
            decoration: const BoxDecoration(
              color: AppColors.accent,
              borderRadius: BorderRadius.horizontal(right: Radius.circular(5)),
            ),
          ),
        ),
      ),
    );
  }
}

/// CMS source management (资源配置): every configured source — build-time,
/// imported or manually added — is one chip. OK toggles it, MENU asks to delete
/// it. URLs are deliberately not shown; the add form below is the only place a
/// URL appears.
class _CmsSourcesSection extends StatefulWidget {
  const _CmsSourcesSection({required this.onRequestDelete});

  /// Raised on MENU. The page owns the confirmation overlay so it can cover the
  /// whole screen instead of just this card.
  final ValueChanged<CmsSite> onRequestDelete;

  @override
  State<_CmsSourcesSection> createState() => _CmsSourcesSectionState();
}

class _CmsSourcesSectionState extends State<_CmsSourcesSection> {
  String _name = '';
  String _api = '';

  Future<void> _editName() async {
    final r = await showOnScreenKeyboard(context,
        title: '源名称', initial: _name, hint: '例如：我的采集');
    if (r != null && mounted) setState(() => _name = r.trim());
  }

  Future<void> _editApi() async {
    final r = await showOnScreenKeyboard(context,
        title: 'apiv3 接口地址',
        initial: _api,
        hint: 'https://host/api.php/provide/vod');
    if (r != null && mounted) setState(() => _api = r.trim());
  }

  Future<void> _add() async {
    final app = AppScope.read(context);
    final err = await app.addCmsSite(_name, _api);
    if (!mounted) return;
    if (err != null) {
      app.showToast(err);
    } else {
      setState(() {
        _name = '';
        _api = '';
      });
      app.showToast('已添加播放源');
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final sites = app.settings.cmsSites;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (sites.isEmpty)
          const Text(
            '当前没有资源站，可在下方添加，或通过「配置导入」批量导入。',
            style: TextStyle(
                fontSize: 15,
                color: AppColors.textDim,
                fontFamilyFallback: kFontFallback),
          )
        else ...[
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (var i = 0; i < sites.length; i++)
                SelectableChip(
                  label: sites[i].name,
                  selected: app.isSiteSelected(sites[i].id),
                  onPressed: () => app.toggleSite(sites[i].id),
                  onMenu: () => widget.onRequestDelete(sites[i]),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text('共 ${sites.length} 个 · 按菜单键(MENU)删除',
              style: const TextStyle(
                  fontSize: 14,
                  color: AppColors.textDim,
                  fontFamilyFallback: kFontFallback)),
        ],
        const SizedBox(height: 22),
        const _SubLabel('添加资源站'),
        const SizedBox(height: 12),
        _ValueField(value: _name, hint: '源名称，例如：我的采集', onPressed: _editName),
        const SizedBox(height: 12),
        _ValueField(
            value: _api,
            hint: 'apiv3 接口，例如：https://host/api.php/provide/vod',
            onPressed: _editApi),
        const SizedBox(height: 16),
        _Btn(label: '添加', primary: true, onPressed: _add),
      ],
    );
  }
}

/// Config transfer actions. Today only import exists; export will be added as a
/// sibling button in the same row, sharing the dialog/overlay plumbing below.
class _ConfigTransferSection extends StatelessWidget {
  const _ConfigTransferSection({required this.onImport});
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _Btn(
            label: '导入配置', primary: true, autofocus: true, onPressed: onImport),
      ],
    );
  }
}

class _SubLabel extends StatelessWidget {
  const _SubLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: AppColors.text,
            fontFamilyFallback: kFontFallback),
      );
}

class _Btn extends StatelessWidget {
  const _Btn(
      {required this.label,
      required this.onPressed,
      this.primary = false,
      this.autofocus = false});
  final String label;
  final VoidCallback onPressed;
  final bool primary;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return Focusable(
      onPressed: onPressed,
      autofocus: autofocus,
      ensureVisibleAlignment: 0.5,
      builder: (context, focused) {
        final active = focused || primary;
        return FocusFx.scale(
          focused,
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 15),
            decoration: focused
                ? FocusFx.pill(focused, radius: 12)
                : BoxDecoration(
                    color: primary ? const Color(0x334EA8FF) : AppColors.glass,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: primary ? AppColors.accent : AppColors.hairline),
                  ),
            child: Text(label,
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: focused
                      ? AppColors.focusInk
                      : (active ? AppColors.text : AppColors.textDim),
                  fontFamilyFallback: kFontFallback,
                )),
          ),
        );
      },
    );
  }
}

/// IPTV (直播) source management: list + remove existing playlist sources and
/// add a new one (name + M3U/M3U8 URL). Mirrors [_CustomSourcesSection] but
/// targets [IptvController] instead of the CMS source list. Wrapped in an
/// AnimatedBuilder since the IPTV state lives in its own notifier.
class _IptvSourcesSection extends StatefulWidget {
  const _IptvSourcesSection();

  @override
  State<_IptvSourcesSection> createState() => _IptvSourcesSectionState();
}

class _IptvSourcesSectionState extends State<_IptvSourcesSection> {
  String _name = '';
  String _url = '';

  Future<void> _editName() async {
    final r = await showOnScreenKeyboard(context,
        title: '直播源名称', initial: _name, hint: '例如：我的直播源');
    if (r != null && mounted) setState(() => _name = r.trim());
  }

  Future<void> _editUrl() async {
    final r = await showOnScreenKeyboard(context,
        title: 'M3U / M3U8 地址',
        initial: _url,
        hint: 'https://host/playlist.m3u');
    if (r != null && mounted) setState(() => _url = r.trim());
  }

  Future<void> _add() async {
    final app = AppScope.read(context);
    final err = await app.iptv.addSource(_name, _url);
    if (!mounted) return;
    if (err != null) {
      app.showToast(err);
    } else {
      setState(() {
        _name = '';
        _url = '';
      });
      app.showToast('已添加直播源');
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return AnimatedBuilder(
      animation: app.iptv,
      builder: (context, _) {
        final sources = app.iptv.sources;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (sources.isNotEmpty) ...[
              const _SubLabel('已添加'),
              const SizedBox(height: 12),
              for (final s in sources)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    children: [
                      SelectableChip(
                        label: s.name,
                        selected: s.id == app.iptv.selectedSourceId,
                        onPressed: () => app.iptv.selectSource(s.id),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(s.url,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 13,
                                color: AppColors.textDim,
                                fontFamilyFallback: kFontFallback)),
                      ),
                      const SizedBox(width: 12),
                      _Btn(
                          label: '删除',
                          onPressed: () => app.iptv.removeSource(s.id)),
                    ],
                  ),
                ),
              const SizedBox(height: 22),
            ],
            const _SubLabel('添加直播源'),
            const SizedBox(height: 12),
            _ValueField(
                value: _name, hint: '名称，例如：我的直播源', onPressed: _editName),
            const SizedBox(height: 12),
            _ValueField(
                value: _url,
                hint: 'M3U 地址，例如：https://host/playlist.m3u',
                onPressed: _editUrl),
            const SizedBox(height: 16),
            _Btn(label: '添加', primary: true, onPressed: _add),
          ],
        );
      },
    );
  }
}

/// Danmaku (弹幕) source management: list + remove existing dandanplay-compatible
/// hosts (address + token) and add a new one. Tapping a host's name makes it the
/// default used for auto-matching. Mirrors [_IptvSourcesSection]; wrapped in an
/// AnimatedBuilder since the state lives on the danmaku controller.
class _DanmakuHostsSection extends StatefulWidget {
  const _DanmakuHostsSection();

  @override
  State<_DanmakuHostsSection> createState() => _DanmakuHostsSectionState();
}

class _DanmakuHostsSectionState extends State<_DanmakuHostsSection> {
  String _name = '';
  String _baseUrl = '';
  String _token = '';

  Future<void> _editName() async {
    final r = await showOnScreenKeyboard(context,
        title: '弹幕源名称', initial: _name, hint: '可选，例如：我的弹幕源');
    if (r != null && mounted) setState(() => _name = r.trim());
  }

  Future<void> _editBaseUrl() async {
    final r = await showOnScreenKeyboard(context,
        title: '弹幕服务地址', initial: _baseUrl, hint: 'https://danmu.example.com');
    if (r != null && mounted) setState(() => _baseUrl = r.trim());
  }

  Future<void> _editToken() async {
    final r = await showOnScreenKeyboard(context,
        title: '弹幕服务 Token', initial: _token, hint: '必填，弹幕服务的访问 Token');
    if (r != null && mounted) setState(() => _token = r.trim());
  }

  Future<void> _add() async {
    final app = AppScope.read(context);
    final err = await app.danmaku.addHost(_name, _baseUrl, _token);
    if (!mounted) return;
    if (err != null) {
      app.showToast(err);
    } else {
      setState(() {
        _name = '';
        _baseUrl = '';
        _token = '';
      });
      app.showToast('已添加弹幕源');
    }
  }

  /// One-line description with the token partially masked.
  static String _describe(DanmakuHost h) {
    final t = h.token.trim();
    final mask = t.length <= 4
        ? '••••'
        : '${t.substring(0, 2)}••••${t.substring(t.length - 2)}';
    return '${h.baseUrl} · Token $mask';
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return AnimatedBuilder(
      animation: app.danmaku,
      builder: (context, _) {
        final d = app.danmaku;
        final hosts = d.hosts;
        final activeId = d.activeHostId;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (hosts.isNotEmpty) ...[
              const _SubLabel('已添加'),
              const SizedBox(height: 8),
              const Text('点击名称设为默认，播放时自动使用默认源匹配弹幕。',
                  style: TextStyle(
                      fontSize: 14,
                      color: AppColors.textDim,
                      fontFamilyFallback: kFontFallback)),
              const SizedBox(height: 12),
              for (final h in hosts)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    children: [
                      SelectableChip(
                        label: h.id == activeId ? '${h.label} · 默认' : h.label,
                        selected: h.id == activeId,
                        onPressed: () => d.setDefaultHost(h.id),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(_describe(h),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 13,
                                color: AppColors.textDim,
                                fontFamilyFallback: kFontFallback)),
                      ),
                      const SizedBox(width: 12),
                      _Btn(label: '删除', onPressed: () => d.removeHost(h.id)),
                    ],
                  ),
                ),
              const SizedBox(height: 22),
            ] else
              const Padding(
                padding: EdgeInsets.only(bottom: 20),
                child: Text('尚未添加弹幕源，添加后播放页会自动匹配弹幕。',
                    style: TextStyle(
                        fontSize: 15,
                        color: AppColors.textDim,
                        fontFamilyFallback: kFontFallback)),
              ),
            const _SubLabel('添加弹幕源'),
            const SizedBox(height: 12),
            _ValueField(
                value: _name, hint: '名称（可选），例如：我的弹幕源', onPressed: _editName),
            const SizedBox(height: 12),
            _ValueField(
                value: _baseUrl,
                hint: '服务地址，例如：https://danmu.example.com',
                onPressed: _editBaseUrl),
            const SizedBox(height: 12),
            _ValueField(
                value: _token, hint: 'Token（必填）', onPressed: _editToken),
            const SizedBox(height: 16),
            _Btn(label: '添加', primary: true, onPressed: _add),
          ],
        );
      },
    );
  }
}

/// Intent for D-pad Down/Up on the settings page — see [_moveByRow].
class _RowMoveIntent extends Intent {
  const _RowMoveIntent(this.forward);
  final bool forward;
}
