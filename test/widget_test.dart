import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:zcode_mobile/models/app_config.dart';
import 'package:zcode_mobile/pages/login_page.dart';
import 'package:zcode_mobile/state/app_state.dart';

Widget _host() {
  return ChangeNotifierProvider<AppState>(
    create: (_) => AppState()..config = AppConfig.empty,
    child: const MaterialApp(home: LoginPage()),
  );
}

void main() {
  testWidgets('login offers both account providers',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host());
    await tester.pump();

    expect(find.text('登录 ZCode'), findsOneWidget);
    expect(find.text('使用 BigModel 账号登录'), findsOneWidget);
    expect(find.text('使用 Z.ai 账号登录'), findsOneWidget);
    // The old paste-a-key flow must be gone.
    expect(find.text('API Key'), findsNothing);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('login page explains the sandboxed agent',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host());
    await tester.pump();

    expect(find.textContaining('真实执行 shell 命令'), findsOneWidget);
  });
}
