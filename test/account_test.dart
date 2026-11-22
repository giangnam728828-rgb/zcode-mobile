import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:zcode_mobile/services/account.dart';

/// In-memory stand-in so the credential chain runs without the platform
/// channel that real secure storage needs.
class MemoryVault implements SessionVault {
  final Map<String, String> data = <String, String>{};

  @override
  Future<String?> read() async => data['session'];

  @override
  Future<void> write(String value) async => data['session'] = value;

  @override
  Future<void> clear() async => data.remove('session');
}

/// Canned-response client: routes by request path so the whole issuance chain
/// runs against scripted replies.
class FakeClient extends http.BaseClient {
  FakeClient(this.handler);
  final Future<http.Response> Function(http.BaseRequest request) handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final http.Response r = await handler(request);
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(r.body)),
      r.statusCode,
      headers: r.headers,
    );
  }
}

Future<http.Response> json(Map<String, dynamic> body, [int status = 200]) =>
    Future<http.Response>.value(http.Response(jsonEncode(body), status,
        headers: <String, String>{'content-type': 'application/json'}));

/// Standard BigModel chain, mirroring the official client's schemas:
/// envelope {code:200,...} everywhere, getCustomerInfo returns
/// organizations[].projects[], key entries carry their id in `apiKey`.
FakeClient bigmodelClient({
  Map<String, dynamic> tokenBody = const <String, dynamic>{
    'code': 200,
    'data': <String, dynamic>{
      'token': 'jwt-1',
      'bigmodel': <String, dynamic>{'access_token': 'acct-1'},
    },
  },
  Map<String, dynamic> infoBody = const <String, dynamic>{
    'code': 200,
    'data': <String, dynamic>{
      'customerName': '测试用户',
      'planName': 'GLM Coding Plan',
      'organizations': <Map<String, dynamic>>[
        <String, dynamic>{
          'organizationId': 'org-1',
          'organizationName': '默认机构',
          'projects': <Map<String, dynamic>>[
            <String, dynamic>{'projectId': 'proj-1', 'projectName': '默认项目'},
          ],
        },
      ],
    },
  },
  Object? keysBody = const <String, dynamic>{
    'code': 200,
    'data': <Map<String, dynamic>>[
      <String, dynamic>{'apiKey': 'key-1', 'name': 'zcode-api-key'},
    ],
  },
  int keysStatus = 200,
  Map<String, dynamic> issueBody = const <String, dynamic>{
    'code': 200,
    'data': <String, dynamic>{
      'token': 'proj-token-1',
      'enabled': true,
      'expiresIn': 1800,
    },
  },
  int issueStatus = 200,
  List<String>? seenPaths,
}) {
  return FakeClient((http.BaseRequest request) async {
    if (seenPaths != null) seenPaths.add(request.url.path);
    final String path = request.url.path;
    if (path.endsWith('/oauth/token')) return json(tokenBody);
    if (path.contains('getCustomerInfo')) return json(infoBody);
    if (path.endsWith('/api_keys')) {
      return keysStatus == 200
          ? json(keysBody! as Map<String, dynamic>)
          : http.Response('{"error":"denied"}', keysStatus);
    }
    if (path.endsWith('/access_tokens')) {
      return issueStatus == 200
          ? json(issueBody)
          : http.Response('{"error":"denied"}', issueStatus);
    }
    return http.Response('not found', 404);
  });
}

/// Parses the authorize URL surfaced through `onUrl` into the loopback
/// redirect and the OAuth state we generated.
Future<({String redirect, String state})> callbackParamsOf(
    String authorizeUrl) async {
  final Uri u = Uri.parse(authorizeUrl);
  return (
    redirect: u.queryParameters['redirect']!,
    state: u.queryParameters['state']!,
  );
}

/// Runs a full sign-in: starts login, then completes the browser leg over a
/// real HTTP call to the loopback callback with the right state.
Future<AccountSession> runLogin(
  AccountService svc,
  AccountRegion region, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final Completer<String> urlReady = Completer<String>();
  final Future<AccountSession> pending = svc.login(
    region,
    onUrl: urlReady.complete,
    timeout: timeout,
  );
  final ({String redirect, String state}) params =
      await callbackParamsOf(await urlReady.future);
  await http.get(Uri.parse('${params.redirect}?state=${params.state}&code=c9'));
  return pending;
}

void main() {
  test('login issues a project token and never keeps the access token as one',
      () async {
    final MemoryVault vault = MemoryVault();
    final AccountService svc =
        AccountService(client: bigmodelClient(), vault: vault);

    final AccountSession s = await runLogin(svc, AccountRegion.bigmodel);
    expect(s.projectToken, 'proj-token-1');
    expect(s.credentialSource, CredentialSource.projectToken);
    expect(s.hasModelCredential, isTrue);
    expect(s.issueError, isNull);
    expect(s.orgId, 'org-1');
    expect(s.planLabel, 'GLM Coding Plan');

    // The persisted session records provenance, not a silent downgrade.
    final Map<String, dynamic> stored =
        jsonDecode(vault.data['session']!) as Map<String, dynamic>;
    expect(stored['credentialSource'], 'project-token');
    expect(stored['projectToken'], 'proj-token-1');
  });

  test('the loopback listener is closed once login completes', () async {
    final AccountService svc =
        AccountService(client: bigmodelClient(), vault: MemoryVault());
    final Completer<String> urlReady = Completer<String>();
    final Future<AccountSession> pending = svc.login(
      AccountRegion.bigmodel,
      onUrl: urlReady.complete,
      timeout: const Duration(seconds: 5),
    );
    final ({String redirect, String state}) params =
        await callbackParamsOf(await urlReady.future);
    await http.get(
        Uri.parse('${params.redirect}?state=${params.state}&code=c9'));
    expect((await pending).projectToken, isNotEmpty);

    final int port = Uri.parse(params.redirect).port;
    // The callback server must be gone: the port can be bound again.
    final HttpServer probe =
        await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    await probe.close(force: true);
  });

  test('issuance failure is explicit: degraded session, no fallback token',
      () async {
    final MemoryVault vault = MemoryVault();
    final AccountService svc = AccountService(
      client: bigmodelClient(keysStatus: 403),
      vault: vault,
    );

    final AccountSession s = await runLogin(svc, AccountRegion.bigmodel);
    // Account leg succeeded; the model credential did not — and the session
    // says so instead of hiding behind the access token.
    expect(s.accessToken, 'acct-1');
    expect(s.projectToken, isNull);
    expect(s.hasModelCredential, isFalse);
    expect(s.issueError, contains('403'));
    expect(s.credentialSource, isNull);

    final Map<String, dynamic> stored =
        jsonDecode(vault.data['session']!) as Map<String, dynamic>;
    expect(stored['projectToken'], '');
    expect(stored['issueError'], contains('403'));
  });

  test('team projects are skipped when picking a personal project',
      () async {
    final List<String> seen = <String>[];
    final AccountService svc = AccountService(
      client: bigmodelClient(
        infoBody: <String, dynamic>{
          'code': 200,
          'data': <String, dynamic>{
            'organizations': <Map<String, dynamic>>[
              <String, dynamic>{
                'organizationId': 'org-1',
                'organizationName': '默认机构',
                'projects': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'projectId': 'proj-team',
                    'projectName': '团队项目',
                    'projectType': 2,
                  },
                  <String, dynamic>{'projectId': 'proj-personal'},
                ],
              },
            ],
          },
        },
        seenPaths: seen,
      ),
      vault: MemoryVault(),
    );
    final AccountSession s = await runLogin(svc, AccountRegion.bigmodel);
    expect(s.orgId, 'org-1');
    // The key management happened on the personal project, not the team one.
    expect(
      seen.where((String p) => p.contains('/api_keys')).first,
      contains('/projects/proj-personal/'),
    );
    expect(s.hasModelCredential, isTrue);
  });

  test('a business error envelope surfaces its code and message', () async {
    final AccountService svc = AccountService(
      client: bigmodelClient(
        issueBody: <String, dynamic>{
          'code': 5001,
          'msg': '没有签发权限',
        },
      ),
      vault: MemoryVault(),
    );
    final AccountSession s = await runLogin(svc, AccountRegion.bigmodel);
    expect(s.hasModelCredential, isFalse);
    expect(s.issueError, contains('业务码 5001'));
    expect(s.issueError, contains('没有签发权限'));
  });

  test('a create response without the apiKey field names what came back',
      () async {
    final AccountService svc = AccountService(
      client: FakeClient((http.BaseRequest request) async {
        final String path = request.url.path;
        if (path.endsWith('/oauth/token')) {
          return json(<String, dynamic>{
            'code': 200,
            'data': <String, dynamic>{
              'token': 'jwt-1',
              'bigmodel': <String, dynamic>{'access_token': 'acct-1'},
            },
          });
        }
        if (path.contains('getCustomerInfo')) {
          return json(<String, dynamic>{
            'code': 200,
            'data': <String, dynamic>{
              'organizations': <Map<String, dynamic>>[
                <String, dynamic>{
                  'organizationId': 'org-1',
                  'organizationName': '默认机构',
                  'projects': <Map<String, dynamic>>[
                    <String, dynamic>{'projectId': 'proj-1'},
                  ],
                },
              ],
            },
          });
        }
        if (path.endsWith('/api_keys')) {
          if (request.method == 'GET') {
            // No dedicated key yet.
            return json(<String, dynamic>{'code': 200, 'data': <Object?>[]});
          }
          // Create succeeds but the payload lacks the official `apiKey` id.
          return json(<String, dynamic>{
            'code': 200,
            'data': <String, dynamic>{'unexpected': true},
          });
        }
        return http.Response('not found', 404);
      }),
      vault: MemoryVault(),
    );
    final AccountSession s = await runLogin(svc, AccountRegion.bigmodel);
    expect(s.hasModelCredential, isFalse);
    expect(s.issueError, contains('缺少 apiKey 字段'));
    expect(s.issueError, contains('unexpected'));
  });

  test('missing organizations in customer info fails loudly, no guessing',
      () async {
    final AccountService svc = AccountService(
      client: bigmodelClient(
          infoBody: <String, dynamic>{
            'code': 200,
            'data': <String, dynamic>{'customerName': 'x'},
          }),
      vault: MemoryVault(),
    );
    final AccountSession s = await runLogin(svc, AccountRegion.bigmodel);
    expect(s.hasModelCredential, isFalse);
    expect(s.issueError, contains('无法确定账号所属组织或项目'));
  });

  test('a forged error callback with the wrong state is ignored', () async {
    final AccountService svc =
        AccountService(client: bigmodelClient(), vault: MemoryVault());
    final Completer<String> urlReady = Completer<String>();
    final Future<AccountSession> pending = svc.login(
      AccountRegion.bigmodel,
      onUrl: urlReady.complete,
      timeout: const Duration(seconds: 6),
    );

    final ({String redirect, String state}) params =
        await callbackParamsOf(await urlReady.future);
    // Wrong state: not our transaction — the login must keep waiting.
    await http.get(
        Uri.parse('${params.redirect}?state=WRONG&error=access_denied'));
    await Future<void>.delayed(const Duration(milliseconds: 120));
    // Now the real callback with the right state completes the flow.
    await http.get(
        Uri.parse('${params.redirect}?state=${params.state}&code=c9'));
    expect(await pending, isA<AccountSession>());
  });

  test('an error callback with the right state fails the login', () async {
    final AccountService svc =
        AccountService(client: bigmodelClient(), vault: MemoryVault());
    final Completer<String> urlReady = Completer<String>();
    final Future<AccountSession> pending = svc.login(
      AccountRegion.bigmodel,
      onUrl: urlReady.complete,
      timeout: const Duration(seconds: 6),
    );
    final ({String redirect, String state}) params =
        await callbackParamsOf(await urlReady.future);
    await http.get(Uri.parse(
        '${params.redirect}?state=${params.state}&error=access_denied'));
    await expectLater(pending, throwsA(isA<AccountError>()));
  });

  test('login timeout throws and releases the loopback port', () async {
    final AccountService svc =
        AccountService(client: bigmodelClient(), vault: MemoryVault());
    final Completer<String> urlReady = Completer<String>();
    final Future<AccountSession> pending = svc.login(
      AccountRegion.bigmodel,
      onUrl: urlReady.complete,
      timeout: const Duration(milliseconds: 250),
    );
    final ({String redirect, String state}) params =
        await callbackParamsOf(await urlReady.future);
    await expectLater(pending, throwsA(isA<AccountError>()));

    final int port = Uri.parse(params.redirect).port;
    final HttpServer probe =
        await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    await probe.close(force: true);
  });

  test('z.ai login uses the token-route JWT as the model credential', () async {
    final AccountService svc = AccountService(
      client: FakeClient((http.BaseRequest request) async {
        if (request.url.path.endsWith('/oauth/token')) {
          return json(<String, dynamic>{
            'data': <String, dynamic>{'token': 'jwt-zai-1'},
          });
        }
        return http.Response('not found', 404);
      }),
      vault: MemoryVault(),
    );
    final AccountSession s = await runLogin(svc, AccountRegion.zai);
    expect(s.projectToken, 'jwt-zai-1');
    expect(s.credentialSource, CredentialSource.zaiJwt);
    expect(s.hasModelCredential, isTrue);
  });

  test('refresh re-issues a project token for bigmodel', () async {
    final MemoryVault vault = MemoryVault();
    final AccountService svc =
        AccountService(client: bigmodelClient(), vault: vault);
    final AccountSession s = await runLogin(svc, AccountRegion.bigmodel);
    final AccountSession next = await svc.refresh(
      s.copyWith(projectToken: null, expiresAt: DateTime.now()),
    );
    expect(next.projectToken, 'proj-token-1');
    expect(next.hasModelCredential, isTrue);
    expect(vault.data['session'], contains('project-token'));
  });

  test('a business 404 on issuance drops the cached location and retries',
      () async {
    final MemoryVault vault = MemoryVault();
    int issueCalls = 0;
    final AccountService svc = AccountService(
      client: FakeClient((http.BaseRequest request) async {
        final String path = request.url.path;
        if (path.endsWith('/oauth/token')) {
          return json(<String, dynamic>{
            'code': 200,
            'data': <String, dynamic>{
              'token': 'jwt-1',
              'bigmodel': <String, dynamic>{'access_token': 'acct-1'},
            },
          });
        }
        if (path.contains('getCustomerInfo')) {
          return json(<String, dynamic>{
            'code': 200,
            'data': <String, dynamic>{
              'organizations': <Map<String, dynamic>>[
                <String, dynamic>{
                  'organizationId': 'org-fresh',
                  'organizationName': '默认机构',
                  'projects': <Map<String, dynamic>>[
                    <String, dynamic>{'projectId': 'proj-fresh'},
                  ],
                },
              ],
            },
          });
        }
        if (path.endsWith('/api_keys')) {
          return json(<String, dynamic>{
            'code': 200,
            'data': <Map<String, dynamic>>[
              <String, dynamic>{'apiKey': 'key-fresh', 'name': 'zcode-api-key'},
            ],
          });
        }
        if (path.endsWith('/access_tokens')) {
          issueCalls++;
          if (issueCalls == 1) {
            // The cached key/project is gone: business 404 in a 200 body.
            return json(<String, dynamic>{'code': 404, 'msg': 'not found'});
          }
          return json(<String, dynamic>{
            'code': 200,
            'data': <String, dynamic>{
              'token': 'proj-token-fresh',
              'enabled': true,
            },
          });
        }
        return http.Response('not found', 404);
      }),
      vault: vault,
    );

    final AccountSession stale = AccountSession(
      region: 'bigmodel',
      accessToken: 'acct-1',
      projectToken: 'old',
      expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
      credentialSource: CredentialSource.projectToken,
      orgId: 'org-stale',
      projectId: 'proj-stale',
      keyId: 'key-stale',
    );
    final AccountSession next = await svc.refresh(stale);
    expect(issueCalls, 2);
    expect(next.orgId, 'org-fresh');
    expect(next.projectId, 'proj-fresh');
    expect(next.keyId, 'key-fresh');
    expect(next.projectToken, 'proj-token-fresh');
  });

  test('refresh surfaces an invalid account as reauth', () async {
    final AccountService svc = AccountService(
      client: bigmodelClient(issueStatus: 401),
      vault: MemoryVault(),
    );
    final AccountSession stale = AccountSession(
      region: 'bigmodel',
      accessToken: 'acct-1',
      projectToken: 'old',
      expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
      credentialSource: CredentialSource.projectToken,
      orgId: 'org-1',
      projectId: 'proj-1',
      keyId: 'key-1',
    );
    try {
      await svc.refresh(stale);
      fail('refresh should have thrown');
    } on AccountError catch (e) {
      expect(e.reauth, isTrue);
      expect(e.step, 'issue');
    }
  });

  test('z.ai refresh cannot heal an expired session', () async {
    final AccountService svc =
        AccountService(client: bigmodelClient(), vault: MemoryVault());
    final AccountSession stale = AccountSession(
      region: 'zai',
      accessToken: 'jwt-zai-1',
      projectToken: 'jwt-zai-1',
      expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
      credentialSource: CredentialSource.zaiJwt,
    );
    try {
      await svc.refresh(stale);
      fail('refresh should have thrown');
    } on AccountError catch (e) {
      expect(e.reauth, isTrue);
    }
  });

  test('modelCredential refuses to hand out a degraded session', () {
    final AccountSession degraded = AccountSession(
      region: 'bigmodel',
      accessToken: 'acct-1',
      issueError: '接口返回 403',
    );
    expect(degraded.hasModelCredential, isFalse);
    expect(
      () => degraded.modelCredential,
      throwsA(isA<AccountError>()),
    );
  });

  test('legacy sessions keep provenance unknown but stay usable once',
      () async {
    final MemoryVault vault = MemoryVault();
    vault.data['session'] = jsonEncode(<String, dynamic>{
      'region': 'bigmodel',
      'accessToken': 'acct-1',
      'projectToken': 'legacy-or-real',
      'expiresAt': DateTime.now()
          .add(const Duration(minutes: 20))
          .toIso8601String(),
    });
    final AccountService svc =
        AccountService(client: bigmodelClient(), vault: vault);
    final AccountSession? s = await svc.restore();
    expect(s, isNotNull);
    expect(s!.credentialSource, CredentialSource.legacy);
    expect(s.hasModelCredential, isTrue);
  });

  test('restore tolerates a session without any project token', () async {
    final MemoryVault vault = MemoryVault();
    vault.data['session'] = jsonEncode(<String, dynamic>{
      'region': 'bigmodel',
      'accessToken': 'acct-1',
      'projectToken': '',
    });
    final AccountService svc =
        AccountService(client: bigmodelClient(), vault: vault);
    final AccountSession? s = await svc.restore();
    expect(s, isNotNull);
    expect(s!.hasModelCredential, isFalse);
  });
}
