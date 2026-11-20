import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:zcode_mobile/l10n/strings.dart';
import 'package:zcode_mobile/pages/setup_page.dart';
import 'package:zcode_mobile/state/app_state.dart';

Widget _host(Widget child) {
  return ChangeNotifierProvider<AppState>(
    create: (_) => AppState(),
    child: MaterialApp(home: child),
  );
}

void main() {
  testWidgets('setup page renders the key field and start button',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host(const SetupPage(s: S.zh)));
    await tester.pump();

    expect(find.text('ZCode'), findsOneWidget);
    expect(find.text('开始使用'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);

    await tester.tap(find.text('开始使用'));
    await tester.pump();
    expect(find.text('先填写 API Key 才能开始。'), findsOneWidget);
  });

  testWidgets('setup page idles in english', (WidgetTester tester) async {
    await tester.pumpWidget(_host(const SetupPage(s: S.en)));
    await tester.pump();
    expect(find.text('Get started'), findsOneWidget);
  });
}
