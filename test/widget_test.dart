import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:zcode_mobile/models/app_config.dart';
import 'package:zcode_mobile/pages/login_page.dart';
import 'package:zcode_mobile/pages/splash_page.dart';
import 'package:zcode_mobile/state/app_state.dart';
import 'package:zcode_mobile/widgets/brand_mark.dart';

Widget _host({Size? size, double textScale = 1.0}) {
  final Widget page = ChangeNotifierProvider<AppState>(
    create: (_) => AppState()..config = AppConfig.empty,
    child: const MaterialApp(home: LoginPage()),
  );
  if (size == null && textScale == 1.0) return page;
  return MediaQuery(
    data: MediaQueryData(
      size: size ?? const Size(390, 844),
      textScaler: TextScaler.linear(textScale),
    ),
    child: page,
  );
}

void main() {
  testWidgets('login offers both account providers',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host());
    await tester.pump();

    // Three bands: the tool bar, the cover headline, the sign-in sheet.
    expect(find.text('ZCode'), findsOneWidget);
    expect(find.text('把终端\n装进口袋。'), findsOneWidget);
    expect(find.text('BigModel'), findsOneWidget);
    expect(find.text('Z.ai'), findsOneWidget);
    // Both ports keep their region + domain, so the pair stays distinguishable.
    expect(find.textContaining('bigmodel.cn'), findsOneWidget);
    expect(find.textContaining('z.ai'), findsWidgets);
    // The old paste-a-key flow must be gone.
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('login explains the sandboxed agent and the account model',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host());
    await tester.pump();

    expect(find.textContaining('私有工作区'), findsOneWidget);
    expect(find.text('密码'), findsOneWidget);
    expect(find.text('令牌'), findsOneWidget);
    expect(find.text('额度'), findsOneWidget);
    expect(find.textContaining('无隶属关系'), findsOneWidget);
  });

  testWidgets('login reflows at 320dp with 1.3x text without overflowing',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_host(size: const Size(320, 640), textScale: 1.3));
    await tester.pump();

    expect(tester.takeException(), isNull);
    // The sheet must still be scrollable to its last item.
    await tester.drag(find.byType(SingleChildScrollView), const Offset(0, -400));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('执行前确认'), findsOneWidget);
  });

  testWidgets('login fits one screen at 390x844 without scrolling',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MediaQuery(
        // Real device insets: status bar + gesture bar.
        data: const MediaQueryData(
          size: Size(390, 844),
          padding: EdgeInsets.only(top: 24, bottom: 24),
        ),
        child: ChangeNotifierProvider<AppState>(
          create: (_) => AppState()..config = AppConfig.empty,
          child: const MaterialApp(home: LoginPage()),
        ),
      ),
    );
    await tester.pump();

    // The sheet, the three facts and the capability list should all be reachable
    // without a first scroll: this screen is a door, not an article.
    final ScrollableState scrollable =
        tester.state(find.byType(Scrollable).first);
    expect(scrollable.position.maxScrollExtent, lessThanOrEqualTo(1.0));
  });

  testWidgets('splash holds the lockup until ready, then leaves once',
      (WidgetTester tester) async {
    // Unpumped animation: ready=false must not start the exit timer, so the
    // app cannot drop onto the sign-in page before init has finished.
    bool done = false;
    await tester.pumpWidget(MaterialApp(
      home: BrandSplash(
        ready: false,
        animate: true,
        onDone: () => done = true,
      ),
    ));
    await tester.pump();
    expect(find.byType(AppIconTile), findsOneWidget);
    expect(find.text('zcode — terminal'), findsOneWidget);
    expect(done, isFalse);

    // Run the whole intro. Still no exit while init is outstanding.
    await tester.pump(const Duration(milliseconds: 900));
    expect(done, isFalse);

    // Init completes -> the splash starts its own exit and reports once.
    await tester.pumpWidget(MaterialApp(
      home: BrandSplash(
        ready: true,
        animate: true,
        onDone: () => done = true,
      ),
    ));
    await tester.pump(const Duration(milliseconds: 200));
    expect(done, isTrue);
  });

  testWidgets('reduced motion has no timeline and shows the lockup',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: BrandSplash(ready: true, animate: false),
    ));
    await tester.pump();
    expect(find.byType(AppIconTile), findsOneWidget);
    expect(find.text('ZCode'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('splash provides its own Material', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: BrandSplash(ready: true, animate: false),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('ZCode'), findsOneWidget);
    // The splash shows the launcher art, not a separately drawn glyph.
    expect(
      find.descendant(
        of: find.byType(BrandSplash),
        matching: find.byType(AppIconTile),
      ),
      findsOneWidget,
    );
    // Splash is the only screen drawn outside a Scaffold. Without a Material
    // ancestor, Text inherits Flutter's debug DefaultTextStyle, which paints a
    // yellow double underline under every glyph.
    expect(
      find.descendant(
        of: find.byType(BrandSplash),
        matching: find.byType(Material),
      ),
      findsWidgets,
    );
  });
}
