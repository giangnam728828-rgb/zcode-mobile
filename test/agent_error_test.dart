import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_mobile/agent/agent_runner.dart';

void main() {
  group('AgentException.classifyError', () {
    test('a 429 with an exhausted-quota code is quota, not rate limit', () {
      expect(
        AgentException.classifyError(429,
            '{"error":{"code":"1113","message":"账户余额不足或已欠费"}}'),
        AgentErrorKind.quotaExhausted,
      );
    });

    test('a plain 429 is a rate limit', () {
      expect(
        AgentException.classifyError(
            429, '{"error":{"code":"1302","message":"请求速度超过限制"}}'),
        AgentErrorKind.rateLimited,
      );
      expect(AgentException.classifyError(429, ''), AgentErrorKind.rateLimited);
    });

    test('401 defaults to invalid credential', () {
      expect(
        AgentException.classifyError(
            401, '{"error":{"code":"1002","message":"token invalid"}}'),
        AgentErrorKind.authInvalid,
      );
      expect(AgentException.classifyError(401, ''), AgentErrorKind.authInvalid);
    });

    test('403 without invalid-credential markers is a model access problem',
        () {
      expect(
        AgentException.classifyError(403, '{"error":{"message":"禁止访问"}}'),
        AgentErrorKind.noModelAccess,
      );
    });

    test('a 403 carrying quota markers is quota exhaustion', () {
      expect(
        AgentException.classifyError(403, '{"code":"1113","message":"欠费"}'),
        AgentErrorKind.quotaExhausted,
      );
    });

    test('gateway errors are transient server errors', () {
      expect(AgentException.classifyError(502, 'Bad Gateway'),
          AgentErrorKind.server);
      expect(AgentException.classifyError(504, ''), AgentErrorKind.server);
    });

    test('4xx request problems are badRequest', () {
      expect(AgentException.classifyError(400, '{"error":"bad shape"}'),
          AgentErrorKind.badRequest);
      expect(AgentException.classifyError(404, 'no route'),
          AgentErrorKind.badRequest);
      expect(AgentException.classifyError(422, '{}'), AgentErrorKind.badRequest);
    });
  });

  group('AgentException.errorCodeOf', () {
    test('reads the Anthropic shape', () {
      expect(
        AgentException.errorCodeOf(
            '{"type":"error","error":{"type":"invalid_request_error","code":"1302"}}'),
        '1302',
      );
    });

    test('reads the flat BigModel shape', () {
      expect(AgentException.errorCodeOf('{"code":"1113","msg":"余额不足"}'),
          '1113');
    });

    test('returns null for non-JSON bodies', () {
      expect(AgentException.errorCodeOf('Bad Gateway'), isNull);
    });
  });

  group('AgentException.message', () {
    test('quota exhaustion says retrying will not help and carries detail',
        () {
      final AgentException e = AgentException(
        429,
        '{"error":{"code":"1113","message":"余额不足"}}',
        kind: AgentErrorKind.quotaExhausted,
        errorCode: '1113',
        model: 'glm-4.6',
        provider: 'bigmodel',
        environment: 'local',
      );
      expect(e.message, contains('额度已用尽'));
      expect(e.message, contains('重试不会恢复额度'));
      expect(e.message, contains('HTTP 429'));
      expect(e.message, contains('glm-4.6'));
      expect(e.message, contains('bigmodel'));
    });

    test('rate limiting explicitly says it is not quota exhaustion', () {
      final AgentException e = AgentException(
        429,
        '{"error":{"code":"1302","message":"请求速度超过限制"}}',
        kind: AgentErrorKind.rateLimited,
        errorCode: '1302',
      );
      expect(e.message, contains('请求过于频繁'));
      expect(e.message, contains('这不是额度耗尽'));
    });

    test('invalid credentials point at re-issuing or re-login', () {
      final AgentException e = AgentException(
        401,
        '{"error":{"code":"1002","message":"token invalid"}}',
        kind: AgentErrorKind.authInvalid,
        model: 'glm-4.6',
        tokenRefreshed: true,
      );
      expect(e.message, contains('重新签发'));
      expect(e.message, contains('本轮已刷新凭证'));
    });
  });
}
