import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_mobile/models/app_config.dart';
import 'package:zcode_mobile/models/chat_message.dart';
import 'package:zcode_mobile/models/conversation.dart';
import 'package:zcode_mobile/services/glm_client.dart';

ChatMessage _user(String t) => ChatMessage(id: '1', role: Sender.user, text: t);

void main() {
  test('parses SSE text deltas into one stream', () async {
    final HttpServer server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest req) async {
      req.response.headers.contentType =
          ContentType('text', 'event-stream', charset: 'utf-8');
      req.response.write(
          'event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}\n\n');
      req.response.write(
          'event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"lo "}}\n\n');
      req.response.write(
          'event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ZCode"}}\n\n');
      req.response.write('event: message_stop\ndata: {"type":"message_stop"}\n\n');
      await req.response.flush();
      await req.response.close();
    });

    final AppConfig cfg = AppConfig.empty.copyWith(
      baseUrl: 'http://127.0.0.1:${server.port}',
      apiKey: 'test-key',
    );
    final GlmClient client = GlmClient(cfg);

    final StringBuffer buf = StringBuffer();
    await for (final GlmDelta d
        in client.streamChat(<ChatMessage>[_user('hi')])) {
      buf.write(d.text);
    }

    expect(buf.toString(), 'Hello ZCode');
    await server.close(force: true);
  });

  test('keeps reasoning deltas separate from answer text', () async {
    final HttpServer server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest req) async {
      req.response.headers.contentType =
          ContentType('text', 'event-stream', charset: 'utf-8');
      req.response.write(
          'data: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"weighing options"}}\n\n');
      req.response.write(
          'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"done"}}\n\n');
      await req.response.close();
    });

    final GlmClient client = GlmClient(AppConfig.empty.copyWith(
      baseUrl: 'http://127.0.0.1:${server.port}',
      apiKey: 'k',
    ));

    final StringBuffer thinking = StringBuffer();
    final StringBuffer text = StringBuffer();
    await for (final GlmDelta d
        in client.streamChat(<ChatMessage>[_user('hi')])) {
      if (d.thinking) {
        thinking.write(d.text);
      } else {
        text.write(d.text);
      }
    }

    expect(thinking.toString(), 'weighing options');
    expect(text.toString(), 'done');
    await server.close(force: true);
  });

  test('throws GlmApiException on non-200', () async {
    final HttpServer server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest req) async {
      req.response.statusCode = 401;
      req.response.write('{"error":{"message":"bad key"}}');
      await req.response.close();
    });

    final GlmClient client = GlmClient(AppConfig.empty.copyWith(
      baseUrl: 'http://127.0.0.1:${server.port}',
      apiKey: 'bad',
    ));

    Object? caught;
    try {
      await client.streamChat(<ChatMessage>[_user('hi')]).drain<void>();
    } catch (e) {
      caught = e;
    }
    expect(caught, isA<GlmApiException>());
    await server.close(force: true);
  });

  test('config bundle round-trips the token', () {
    final AppConfig cfg = AppConfig.empty.copyWith(
      apiKey: 'abc123',
      model: 'glm-4.6',
      baseUrl: Endpoints.zai,
      provider: 'zai',
      accentId: 'ocean',
      language: 'en',
    );
    final String bundle = cfg.exportBundle();
    expect(bundle.startsWith('zcm://'), isTrue);

    final AppConfig? back = AppConfig.tryImport(bundle, AppConfig.empty);
    expect(back, isNotNull);
    expect(back!.apiKey, 'abc123');
    expect(back.model, 'glm-4.6');
    expect(back.baseUrl, Endpoints.zai);
    // Appearance stays with the importing device.
    expect(back.accentId, 'indigo');
  });

  test('conversation markdown includes both turns', () {
    final Conversation c = Conversation(
      id: 'c1',
      messages: <ChatMessage>[
        _user('write a cache'),
        ChatMessage(id: 'a1', role: Sender.assistant, text: 'sure'),
      ],
    );
    final String md = c.toMarkdown();
    expect(md.contains('write a cache'), isTrue);
    expect(md.contains('sure'), isTrue);
    expect(c.previewTitle(), 'write a cache');
  });
}
