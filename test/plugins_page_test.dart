import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:zcode_mobile/agent/commands.dart';
import 'package:zcode_mobile/agent/tools.dart';
import 'package:zcode_mobile/models/app_config.dart';
import 'package:zcode_mobile/pages/plugins_page.dart';
import 'package:zcode_mobile/services/plugins.dart';
import 'package:zcode_mobile/state/app_state.dart';

void main() {
  test('installed plugin becomes a slash command and expands its prompt',
      () async {
    final Directory dir =
        Directory.systemTemp.createTempSync('zcode_cmd_plugins');
    addTearDown(() => dir.deleteSync(recursive: true));

    final AppState state = AppState();
    state.config = AppConfig.empty;
    state.debugUseWorkspace(ToolBox.at(dir));
    state.pluginCenter = PluginCenter(dir);

    final PluginManifest commit = PluginCatalog.all
        .firstWhere((PluginManifest m) => m.id == 'commit-msg');
    await state.pluginCenter!.install(commit);
    await state.debugReloadExtensions();

    final SlashCommand? cmd = state.customCommands
        .cast<SlashCommand?>()
        .firstWhere((SlashCommand? c) => c?.name == 'commit',
            orElse: () => null);
    expect(cmd, isNotNull);
    expect(cmd!.takesArg, isTrue);

    final String? prompt = state.customCommandPrompt('commit', '只改了 README');
    expect(prompt, isNotNull);
    expect(prompt, contains('只改了 README'));
    expect(prompt, isNot(contains(r'$ARGUMENTS')));
  });

  testWidgets('plugin market installs a catalog entry end to end',
      (WidgetTester tester) async {
    final Directory dir =
        Directory.systemTemp.createTempSync('zcode_page_plugins');
    addTearDown(() => dir.deleteSync(recursive: true));

    final AppState state = AppState();
    state.config = AppConfig.empty;
    state.pluginCenter = PluginCenter(dir);
    state.ready = true;

    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const MaterialApp(home: PluginsPage()),
    ));
    // The market animates its tab indicator forever, so settle by hand.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('代码评审'), findsOneWidget);
    expect(find.text('插件市场'), findsWidgets);

    final Finder btn = find
        .ancestor(
          of: find.byIcon(Icons.download_rounded).first,
          matching: find.byWidgetPredicate((Widget w) => w is ButtonStyleButton),
        )
        .first;
    final ButtonStyleButton button = tester.widget<ButtonStyleButton>(btn);
    // Run the callback inside the real async zone so file IO can complete.
    await tester.runAsync(() async {
      button.onPressed!();
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    // File writes are real IO; fake time alone will not complete them.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      File('${dir.path}/.zcode/skills/code-review.md').existsSync(),
      isTrue,
    );
    expect(state.pluginCenter!.isInstalled('code-review'), isTrue);
    expect(find.text('已安装'), findsWidgets);
  });
}
