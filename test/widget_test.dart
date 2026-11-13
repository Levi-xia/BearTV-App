import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bear_tv/app.dart';
import 'package:bear_tv/core/app_controller.dart';
import 'package:bear_tv/core/app_scope.dart';
import 'package:bear_tv/data/settings_store.dart';
import 'package:bear_tv/screens/play_screen.dart';
import 'package:bear_tv/widgets/dynamic_background.dart';

import 'fakes.dart';

Future<void> _settle(WidgetTester tester) async {
  // MockPlayerController runs a periodic timer, so pumpAndSettle would hang.
  // 40 × 120 ms = 4.8 s of fake time — past the 3.3 s splash hold + 650 ms
  // exit fade — so the home shell is actually mounted when tests assert on it.
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

const _sizes = [Size(1280, 720), Size(1920, 1080), Size(960, 540)];

void main() {
  final overflows = <String>[];

  setUp(() {
    overflows.clear();
    final prev = FlutterError.onError;
    FlutterError.onError = (details) {
      final s = details.exceptionAsString();
      if (s.contains('overflowed')) {
        overflows.add(s);
      } else {
        prev?.call(details);
      }
    };
  });

  // A controller with an injected (offline) repo → hasApiKey is true, so the
  // real home layout renders (not the "configure key" prompt).
  AppController seeded() => AppController(repository: FakeRepo());

  for (final size in _sizes) {
    testWidgets('scaled UI fills the screen (no black edge) at $size',
        (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = size;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final c = seeded();
      addTearDown(c.dispose);
      await tester.pumpWidget(NebulaApp(controller: c));
      await _settle(tester);

      // The full-bleed background must cover the entire physical screen after
      // the global UI down-scale — otherwise a black edge shows on the right or
      // bottom. getRect is in post-transform (global) coordinates.
      final rect = tester.getRect(find.byType(DynamicBackground));
      expect(rect.left, moreOrLessEquals(0, epsilon: 0.5));
      expect(rect.top, moreOrLessEquals(0, epsilon: 0.5));
      expect(rect.width, moreOrLessEquals(size.width, epsilon: 0.5));
      expect(rect.height, moreOrLessEquals(size.height, epsilon: 0.5));
    });

    testWidgets('cold start focuses the nav tab, not a hero card at $size',
        (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = size;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final c = seeded();
      addTearDown(c.dispose);
      await tester.pumpWidget(NebulaApp(controller: c));
      await _settle(tester);

      // On first entry focus must land on the top nav tab (so the big hero
      // background is shown), not on a poster deep in a rail. A focused card
      // would sit far down the (tall) hero block; the tab sits in the header.
      final focused = tester.binding.focusManager.primaryFocus;
      expect(focused, isNotNull);
      final box = focused!.context!.findRenderObject() as RenderBox;
      expect(box.localToGlobal(Offset.zero).dy, lessThan(200),
          reason: 'cold-start focus should be on the nav tab, not a card');
    });

    testWidgets('home has no overflow at $size', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = size;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final c = seeded();
      addTearDown(c.dispose);
      await tester.pumpWidget(NebulaApp(controller: c));
      await _settle(tester);

      expect(overflows, isEmpty, reason: overflows.join('\n---\n'));
    });

    testWidgets('text is not underlined at $size', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = size;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final c = seeded();
      addTearDown(c.dispose);
      await tester.pumpWidget(NebulaApp(controller: c));
      await _settle(tester);

      // The framework paints a yellow underline on text that has no Material
      // ancestor. Assert the effective style never resolves to underline.
      for (final rt in tester.widgetList<RichText>(find.byType(RichText))) {
        final span = rt.text;
        if (span is TextSpan) {
          expect(span.style?.decoration, isNot(TextDecoration.underline),
              reason: 'underlined text: "${span.toPlainText()}"');
        }
      }
    });

    testWidgets('play screen has no overflow at $size', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = size;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final c = seeded();
      addTearDown(c.dispose);
      await c.setTab(1, silent: true);
      c.currentItem = c.feed.hero.first;
      c.page = AppPage.play;

      await tester.pumpWidget(
        AppScope(
          controller: c,
          child: const Directionality(
            textDirection: TextDirection.ltr,
            child: PlayScreen(),
          ),
        ),
      );
      await _settle(tester);

      expect(overflows, isEmpty, reason: overflows.join('\n---\n'));
    });

    testWidgets('downloads page has no overflow at $size', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = size;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final c = seeded();
      addTearDown(c.dispose);
      await tester.pumpWidget(NebulaApp(controller: c));
      await _settle(tester);
      c.openDownloads();
      await _settle(tester);

      expect(c.page, AppPage.downloads);
      expect(find.text('下载管理'), findsOneWidget);
      expect(find.text('全部开始'), findsOneWidget);
      expect(find.text('全部暂停'), findsOneWidget);
      expect(find.text('暂无下载任务'), findsOneWidget);
      expect(overflows, isEmpty, reason: overflows.join('\n---\n'));

      // Back returns to the page the downloads screen was opened from.
      c.backFromKey();
      await _settle(tester);
      expect(c.page, AppPage.home);
    });

    for (final tab in [0, 2]) {
      testWidgets('home tab $tab has no overflow at $size', (tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = size;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final c = seeded();
        addTearDown(c.dispose);
        await tester.pumpWidget(NebulaApp(controller: c));
        await _settle(tester);
        AppScope.of(
          tester.element(find.byType(Shell)),
        ).setTab(tab, silent: false);
        await _settle(tester);

        expect(overflows, isEmpty, reason: overflows.join('\n---\n'));
      });
    }
  }

  testWidgets('我的 has a 下载 section whose entry opens 下载管理', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1280, 720);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final c = seeded();
    addTearDown(c.dispose);
    await tester.pumpWidget(NebulaApp(controller: c));
    await _settle(tester);
    await c.setTab(0);
    await _settle(tester);

    // Section title uses the same RailHead treatment as 最近播放.
    expect(find.text('我的下载'), findsOneWidget);
    // No storage plugin in the test binding, so the entry reports unavailable.
    expect(find.text('本地存储不可用，下载功能暂不可用'), findsOneWidget);

    await tester.tap(find.text('下载管理'));
    await _settle(tester);
    expect(c.page, AppPage.downloads);
  });

  testWidgets('without an API key the home screen prompts to open Settings',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1280, 720);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    // No injected repo and no saved key → prompt state.
    final c = AppController(settings: SettingsStore(seedDefaultKey: false));
    addTearDown(c.dispose);
    await tester.pumpWidget(NebulaApp(controller: c));
    await _settle(tester);

    expect(c.hasApiKey, isFalse);
    expect(find.text('尚未配置 TMDB API Key'), findsOneWidget);

    // 我的 is local data: the downloads entry must be reachable without a key.
    AppScope.of(tester.element(find.byType(Shell))).setTab(0, silent: false);
    await _settle(tester);
    expect(find.text('下载管理'), findsOneWidget);

    // Opening settings swaps in the settings page.
    c.openSettings();
    await _settle(tester);
    expect(find.text('设置'), findsWidgets);

    // The TMDB API Key field lives under the collapsed 高级配置 panel; scroll
    // the toggle into view and expand it.
    final advancedToggle = find.text('展开 ▼');
    await tester.ensureVisible(advancedToggle);
    await _settle(tester);
    await tester.tap(advancedToggle);
    await _settle(tester);
    expect(find.text('TMDB API Key'), findsOneWidget);
  });
}
