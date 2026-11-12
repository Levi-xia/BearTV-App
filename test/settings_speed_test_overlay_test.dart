import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bear_tv/app.dart';
import 'package:bear_tv/core/app_controller.dart';
import 'package:bear_tv/data/settings_store.dart';
import 'package:bear_tv/data/vod/cms_models.dart';

import 'fakes.dart';

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

void main() {
  testWidgets('settings speed-test button opens the per-source overlay',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1280, 720);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    const sites = [
      CmsSite(id: 'a', name: 'A站', api: 'https://a.test/api.php'),
      CmsSite(id: 'b', name: 'B站', api: 'https://b.test/api.php'),
    ];
    final c = AppController(
      repository: FakeRepo(),
      settings: SettingsStore(
        seedDefaultKey: false,
        seededCmsSites: () => sites,
        // Deselect B站 so only the selected source is probed.
        seededSelectedIds: () => ['a'],
      ),
    );
    addTearDown(c.dispose);

    await tester.pumpWidget(NebulaApp(controller: c));
    await _settle(tester);
    c.openSettings();
    await _settle(tester);

    final speedButton = find.text('测速');
    await tester.ensureVisible(speedButton);
    await _settle(tester);
    // ensureVisible aligns to the top edge, which the shell header covers —
    // nudge the page down so the button is actually hittable.
    await tester.drag(
        find.byType(SingleChildScrollView).first, const Offset(0, 220));
    await _settle(tester);
    await tester.tap(speedButton);
    await _settle(tester);

    expect(find.text('资源站测速'), findsOneWidget);
    expect(find.text('关闭'), findsOneWidget);
    // Only the selected source is probed (B站 stays behind the overlay as a
    // chip, but must not get a result row).
    expect(find.text('测速完成 · 共 1 个'), findsOneWidget);
    // flutter_test stubs HTTP with a 400 response, so the probe settles as a
    // failure rather than hanging the overlay in "测试中…".
    expect(find.text('HTTP 400'), findsOneWidget);
  });

  testWidgets('a dozen sources all fit in the grid without scrolling',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1280, 720);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final overflows = <String>[];
    final prev = FlutterError.onError;
    FlutterError.onError = (details) {
      final s = details.exceptionAsString();
      if (s.contains('overflowed')) {
        overflows.add(s);
      } else {
        prev?.call(details);
      }
    };
    addTearDown(() => FlutterError.onError = prev);

    final sites = [
      for (var i = 1; i <= 12; i++)
        CmsSite(id: 's$i', name: '源$i', api: 'https://s$i.test/api.php'),
    ];
    final c = AppController(
      repository: FakeRepo(),
      settings: SettingsStore(
        seedDefaultKey: false,
        seededCmsSites: () => sites,
        seededSelectedIds: () => [for (final s in sites) s.id],
      ),
    );
    addTearDown(c.dispose);

    await tester.pumpWidget(NebulaApp(controller: c));
    await _settle(tester);
    c.openSettings();
    await _settle(tester);

    final speedButton = find.text('测速');
    await tester.ensureVisible(speedButton);
    await _settle(tester);
    await tester.drag(
        find.byType(SingleChildScrollView).first, const Offset(0, 220));
    await _settle(tester);
    await tester.tap(speedButton);
    await _settle(tester);

    expect(find.text('测速完成 · 共 12 个'), findsOneWidget);
    final results = find.text('HTTP 400');
    expect(results, findsNWidgets(12));
    // Every card is on-screen: 3 columns × 4 rows, no scrolling needed.
    for (var i = 0; i < 12; i++) {
      final rect = tester.getRect(results.at(i));
      expect(rect.bottom, lessThanOrEqualTo(720));
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(1280));
    }
    expect(overflows, isEmpty, reason: overflows.join('\n---\n'));
  });
}
