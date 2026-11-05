import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bear_tv/core/app_controller.dart';
import 'package:bear_tv/core/app_scope.dart';
import 'package:bear_tv/data/iptv/iptv_models.dart';
import 'package:bear_tv/player/player_controller.dart';
import 'package:bear_tv/screens/iptv_screen.dart';

const _cctv1 = IptvChannel(
  id: 'a',
  sourceId: 's',
  name: 'CCTV1',
  group: '央视',
  logo: '',
  tvgId: '',
  url: 'http://x/cctv1.m3u8',
);
const _hunan = IptvChannel(
  id: 'b',
  sourceId: 's',
  name: '湖南卫视',
  group: '卫视',
  logo: '',
  tvgId: '',
  url: 'http://x/hunan.m3u8',
);

/// A bare host for [IptvBrowser]: just enough ancestor plumbing for text to lay
/// out. No Material, no navigation — the point is the widget's own listening,
/// not the app shell.
Widget _host(AppController app) => Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
        data: const MediaQueryData(size: Size(1920, 1080)),
        child: DefaultTextStyle(
          style: const TextStyle(),
          child: AppScope(controller: app, child: const IptvBrowser()),
        ),
      ),
    );

void main() {
  /// `openChannel` notifies `iptv` and the player but NOT the AppController —
  /// a trap the file documents twice. The fullscreen layer's bottom-left tag
  /// used to read `currentChannel` in its own `build`, so with the 浮层 open
  /// (which keeps itself open by design, firing no `setState`) it kept showing
  /// whatever was playing when the layer mounted, and only caught up when the
  /// overlay was closed. It must track `iptv` on its own.
  testWidgets('fullscreen channel name follows a channel change with the '
      'picker open', (tester) async {
    final app = AppController(player: MockPlayerController());
    addTearDown(app.dispose);

    app.fullscreen = true;
    app.iptv.selectChannel(_cctv1);

    await tester.pumpWidget(_host(app));
    await tester.pump();
    expect(find.text('CCTV1'), findsOneWidget);

    // Exactly what picking another channel does, minus the player: notify iptv
    // only. The fullscreen root gets no notification and does not rebuild.
    app.iptv.selectChannel(_hunan);
    await tester.pump();

    expect(find.text('湖南卫视'), findsOneWidget);
    expect(find.text('CCTV1'), findsNothing);
  });

  testWidgets('fullscreen tag shows a placeholder before any channel is picked',
      (tester) async {
    final app = AppController(player: MockPlayerController());
    addTearDown(app.dispose);
    app.fullscreen = true;

    await tester.pumpWidget(_host(app));
    await tester.pump();

    expect(find.text('未选择频道'), findsOneWidget);
  });

  /// Fullscreen used to be layered *over* the inline stage, and both rendered
  /// a `_LiveVideoSurface` — so two `VideoPlayer` widgets stayed bound to the
  /// same controller, one invisibly composited under an opaque box every frame.
  /// The layers must now be mutually exclusive.
  testWidgets('fullscreen replaces the inline stage: one video surface only',
      (tester) async {
    final app = AppController(player: MockPlayerController());
    addTearDown(app.dispose);

    await tester.pumpWidget(_host(app));
    await tester.pump();
    expect(find.text('选择频道开始播放'), findsOneWidget);
    expect(find.text('OK 全屏'), findsOneWidget); // inline hint

    app.setFullscreen(true);
    await tester.pump();
    expect(find.text('选择频道开始播放'), findsOneWidget,
        reason: 'no hidden second surface under the fullscreen layer');
    expect(find.text('OK 全屏'), findsNothing,
        reason: 'the inline stage must be unmounted');

    app.setFullscreen(false);
    await tester.pump();
    expect(find.text('选择频道开始播放'), findsOneWidget);
    expect(find.text('OK 全屏'), findsOneWidget);
  });
}
