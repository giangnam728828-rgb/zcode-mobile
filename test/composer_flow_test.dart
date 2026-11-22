import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_mobile/l10n/strings.dart';
import 'package:zcode_mobile/models/app_config.dart';
import 'package:zcode_mobile/models/attachment.dart';
import 'package:zcode_mobile/state/app_state.dart';
import 'package:zcode_mobile/widgets/composer.dart';

void main() {
  group('queue', () {
    AppState queueing() {
      final AppState s = AppState();
      s.config = AppConfig.empty;
      // `send` only enqueues while a turn runs; no runner is needed because
      // this branch never reaches the network.
      s.streaming = true;
      s.send('改登录页');
      s.send('优化设置页');
      s.send('修文件浏览器');
      return s;
    }

    test('send queues in order while streaming', () {
      expect(queueing().queue, <String>['改登录页', '优化设置页', '修文件浏览器']);
    });

    test('send-now keeps every queued turn', () {
      final AppState s = queueing();
      s.flushQueueNow();
      // The old implementation cleared the queue to cancel the live turn and
      // only put the head back, silently dropping the other two.
      expect(s.queue, <String>['改登录页', '优化设置页', '修文件浏览器']);
    });

    test('send-now on an empty queue is a no-op', () {
      final AppState s = AppState()..config = AppConfig.empty;
      s.flushQueueNow();
      expect(s.queue, isEmpty);
    });

    test('removing one queued turn leaves the rest in order', () {
      final AppState s = queueing();
      s.removeQueued(1);
      expect(s.queue, <String>['改登录页', '修文件浏览器']);
    });

    test('an out-of-range removal is ignored', () {
      final AppState s = queueing();
      s.removeQueued(9);
      s.removeQueued(-1);
      expect(s.queue.length, 3);
    });
  });

  group('file mentions', () {
    test('bare paths stop at whitespace', () {
      expect(parseMentions('看看 @src/main.dart 和 @README.md'),
          <String>['src/main.dart', 'README.md']);
    });

    test('quoted paths keep their spaces', () {
      expect(
        parseMentions('改一下 @"My Project/main file.dart" 的入口'),
        <String>['My Project/main file.dart'],
      );
    });

    test('chinese and bracketed paths survive', () {
      expect(
        parseMentions('@"项目/主文件（最终版）.dart" 和 @"a/b (2).txt"'),
        <String>['项目/主文件（最终版）.dart', 'a/b (2).txt'],
      );
    });

    test('a slash command is not a file', () {
      expect(parseMentions('/compact 然后看 @a.dart'), <String>['a.dart']);
    });

    test('the same path twice is kept twice here (dedupe is the caller\'s job)',
        () {
      expect(parseMentions('@a.dart @a.dart'), <String>['a.dart', 'a.dart']);
    });

    test('quoting is added only when the path needs it', () {
      expect(mentionFor('src/main.dart'), '@src/main.dart ');
      expect(mentionFor('My Project/main file.dart'), '@"My Project/main file.dart" ');
    });
  });

  group('composer keys', () {
    Future<TextEditingController> pump(
      WidgetTester tester, {
      bool streaming = false,
      List<Attachment> attachments = const <Attachment>[],
      void Function(String)? onSend,
    }) async {
      // Phone width: two 44dp keys plus the box have to fit in 390dp without
      // overflowing, which the default 800x600 test surface would hide.
      tester.view.physicalSize = const Size(390 * 3, 844 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final TextEditingController ctrl = TextEditingController();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: Composer(
              controller: ctrl,
              streaming: streaming,
              queue: const <String>[],
              s: S.zh,
              attachments: attachments,
              onSend: onSend ?? (_) {},
              onStop: () {},
              onSendNow: () {},
              onClearQueue: () {},
            ),
          ),
        ),
      ));
      await tester.pump();
      return ctrl;
    }

    testWidgets('idle shows one send key and no stop key', (tester) async {
      await pump(tester);
      expect(find.byIcon(Icons.arrow_upward_rounded), findsOneWidget);
      expect(find.byIcon(Icons.stop_rounded), findsNothing);
    });

    testWidgets('streaming with an empty box shows only stop', (tester) async {
      await pump(tester, streaming: true);
      expect(find.byIcon(Icons.stop_rounded), findsOneWidget);
      expect(find.byIcon(Icons.schedule_send_rounded), findsNothing);
    });

    testWidgets('typing while streaming keeps stop reachable', (tester) async {
      final TextEditingController ctrl = await pump(tester, streaming: true);
      ctrl.text = '排队一条';
      await tester.pump();
      // This is the regression: the old key turned into send on the first
      // keystroke, so cancelling required clearing the box.
      expect(find.byIcon(Icons.stop_rounded), findsOneWidget);
      expect(find.byIcon(Icons.schedule_send_rounded), findsOneWidget);
    });

    testWidgets('an oversized attachment blocks the send and says why',
        (tester) async {
      String? sent;
      final TextEditingController ctrl = await pump(
        tester,
        onSend: (String t) => sent = t,
        attachments: const <Attachment>[
          Attachment(
            path: 'huge.png',
            name: 'huge.png',
            isImage: true,
            size: 5 * 1024 * 1024,
          ),
        ],
      );
      ctrl.text = '看看这张图';
      await tester.pump();
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      await tester.pump();
      expect(sent, isNull, reason: 'sending without the image is the bug');
      expect(find.textContaining('超过 3 MB 上限'), findsOneWidget);
    });
  });

  group('attachment limits', () {
    test('an oversized image is flagged, a normal one is not', () {
      const Attachment big = Attachment(
        path: 'a.png',
        name: 'a.png',
        isImage: true,
        size: 4 * 1024 * 1024,
      );
      const Attachment ok = Attachment(
        path: 'b.png',
        name: 'b.png',
        isImage: true,
        size: 900 * 1024,
      );
      expect(big.exceedsLimit, isTrue);
      expect(ok.exceedsLimit, isFalse);
    });

    test('text files use the smaller ceiling', () {
      const Attachment text = Attachment(
        path: 'a.log',
        name: 'a.log',
        isImage: false,
        size: 600 * 1024,
      );
      expect(text.exceedsLimit, isTrue);
      expect(text.limitBytes, Attachment.maxTextBytes);
    });

    test('an unknown size is not treated as too large', () {
      const Attachment unknown = Attachment(
        path: 'a.png',
        name: 'a.png',
        isImage: true,
      );
      expect(unknown.exceedsLimit, isFalse);
    });
  });
}
