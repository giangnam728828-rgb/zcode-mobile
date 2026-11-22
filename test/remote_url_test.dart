import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_mobile/remote/remote_connection.dart';
import 'package:zcode_mobile/remote/remote_url.dart';

void main() {
  group('RemoteUrl.validate', () {
    test('accepts the official remote v4 link with credentials', () {
      final RemoteUrlCheck c = RemoteUrl.validate(
          'https://zcode.z.ai/remote/v4?sid=S1D2&hash=abcdef123456&t=123');
      expect(c.ok, isTrue);
      expect(c.uri!.host, 'zcode.z.ai');
      expect(c.uri!.path, '/remote/v4');
      expect(c.uri!.queryParameters['sid'], 'S1D2');
    });

    test('extracts the link from surrounding scanned text', () {
      final RemoteUrlCheck c = RemoteUrl.validate(
          'ZCode 远程控制 https://zcode.z.ai/remote/v4?sid=abc1&hash=h123 请勿转发');
      expect(c.ok, isTrue);
      expect(c.uri!.queryParameters['sid'], 'abc1');
    });

    test('strips fragments but keeps query', () {
      final RemoteUrlCheck c = RemoteUrl.validate(
          'https://zcode.z.ai/remote/v4?sid=abcd#intro');
      expect(c.ok, isTrue);
      expect(c.uri!.fragment, isEmpty);
      expect(c.uri!.queryParameters['sid'], 'abcd');
    });

    test('rejects plain http', () {
      expect(
          RemoteUrl.validate('http://zcode.z.ai/remote/v4?sid=a1b2').ok, isFalse);
    });

    test('rejects foreign hosts that merely look close', () {
      expect(
          RemoteUrl.validate('https://zcode.z.ai.evil.example/remote/v4').ok,
          isFalse);
      expect(RemoteUrl.validate('https://evil.example/remote/v4?sid=a1b2').ok,
          isFalse);
    });

    test('rejects non-remote paths on the official host', () {
      expect(RemoteUrl.validate('https://zcode.z.ai/login').ok, isFalse);
    });

    test('rejects garbage', () {
      expect(RemoteUrl.validate('').ok, isFalse);
      expect(RemoteUrl.validate('不是链接').ok, isFalse);
    });
  });

  group('RemoteUrl.mask', () {
    test('keeps host and path, collapses every query value', () {
      final RemoteUrlCheck c = RemoteUrl.validate(
          'https://zcode.z.ai/remote/v4?sid=SECRETVALUE123&hash=SHORT');
      final String masked = RemoteUrl.mask(c.uri!);
      expect(masked, contains('zcode.z.ai/remote/v4'));
      expect(masked, isNot(contains('SECRETVALUE123')));
      expect(masked, isNot(contains('SHORT=')));
      expect(masked, contains('••••'));
    });

    test('works without a query', () {
      final RemoteUrlCheck c = RemoteUrl.validate('https://zcode.z.ai/remote/v4');
      expect(RemoteUrl.mask(c.uri!), contains('/remote/v4'));
    });
  });

  group('RemoteConnection.fromJson', () {
    test('round-trips through toJson', () {
      final RemoteConnection c = RemoteConnection(
        id: 'r1',
        name: '工作电脑',
        url: 'https://zcode.z.ai/remote/v4?sid=abcd1234&hash=h1',
        addedAt: DateTime(2026, 11, 22, 9),
        lastUsedAt: DateTime(2026, 11, 22, 10),
      );
      final RemoteConnection? back =
          RemoteConnection.fromJson(c.toJson() as Object?);
      expect(back!.name, '工作电脑');
      expect(back.url, c.url);
      expect(back.lastUsedAt, c.lastUsedAt);
    });

    test('refuses saved entries that no longer validate', () {
      final Map<String, dynamic> evil = <String, dynamic>{
        'id': 'r2',
        'name': 'x',
        'url': 'https://evil.example/remote/v4?sid=abcd',
        'addedAt': '2026-11-22T09:00:00',
      };
      expect(RemoteConnection.fromJson(evil), isNull);
    });
  });
}
