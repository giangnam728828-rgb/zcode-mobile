import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

/// Account sign-in for ZCode, mirroring the flow the official open-source
/// client uses (see zai-org/ZCode):
///
///   browser authorize  ->  authCode on a loopback callback
///   POST zcode token route  ->  login JWT (+ BigModel access token)
///   POST .../api_keys/{id}/access_tokens  ->  short-lived project token
///
/// Credential rules enforced here (总方案 P0-1):
///
///   - the BigModel OAuth access token is an *account* credential used to
///     re-issue project tokens; it is never sent to the model endpoint;
///   - a session is only marked model-capable once a real project token was
///     issued — issuance failure is surfaced, not silently downgraded;
///   - callback errors are accepted only when the OAuth state matches, and the
///     loopback listener is closed on every exit path, success or not;
///   - errors carry the failing step and HTTP status, never token material.
class AccountRegion {
  const AccountRegion._(this.id, this.label, this.authorizeUrl, this.apiBase);

  final String id;
  final String label;
  final String authorizeUrl;
  final String apiBase;

  static const AccountRegion bigmodel = AccountRegion._(
    'bigmodel',
    'BigModel（国内）',
    'https://bigmodel.cn/login',
    'https://open.bigmodel.cn',
  );

  static const AccountRegion zai = AccountRegion._(
    'zai',
    'Z.ai（海外）',
    'https://z.ai/login',
    'https://api.z.ai',
  );

  static AccountRegion byId(String? id) =>
      id == 'zai' ? AccountRegion.zai : AccountRegion.bigmodel;

  String get modelBase => '$apiBase/api/anthropic';
}

/// What the string in [AccountSession.projectToken] actually is. The model
/// endpoint behaves differently for each, so provenance must survive
/// persistence instead of being inferred.
enum CredentialSource {
  /// Short-lived token from `POST .../api_keys/{id}/access_tokens`. The only
  /// credential that may call the BigModel model endpoint.
  projectToken('project-token'),

  /// Z.ai overseas: the token-route JWT is itself the model credential; there
  /// is no separate project-token issuance on that region.
  zaiJwt('zai-jwt'),

  /// Sessions persisted by v3.10.1 and earlier carry no provenance: the stored
  /// string may be a real project token or a downgraded access token. They are
  /// honoured until their expiry, then the refresh path re-issues properly.
  legacy('legacy');

  const CredentialSource(this.id);
  final String id;

  static CredentialSource? byId(String? id) {
    for (final CredentialSource v in CredentialSource.values) {
      if (v.id == id) return v;
    }
    return null;
  }
}

/// Sign-in / issuance failure. [step] says which leg of the chain failed,
/// [statusCode] carries the HTTP status when there was one, and [reauth] marks
/// failures that can only be fixed by signing in again.
class AccountError implements Exception {
  AccountError(this.message, {this.step, this.statusCode, this.reauth = false});

  /// 'authorize' | 'exchange' | 'customer-info' | 'api-keys' | 'issue'
  final String? step;
  final int? statusCode;
  final bool reauth;
  final String message;

  @override
  String toString() => message;
}

class AccountSession {
  AccountSession({
    required this.region,
    required this.accessToken,
    this.zcodeJwt,
    this.projectToken,
    this.expiresAt,
    this.credentialSource,
    this.issueError,
    this.orgId,
    this.projectId,
    this.keyId,
    this.displayName,
    this.planLabel,
  });

  final String region;

  /// Login JWT / business access token; used to re-issue project tokens.
  /// Never sent to the model endpoint on the BigModel region.
  final String accessToken;
  final String? zcodeJwt;

  /// Credential actually sent to the model endpoint, or null when no usable
  /// model credential was issued (see [issueError]).
  final String? projectToken;
  final DateTime? expiresAt;

  /// Where [projectToken] came from; null only when there is no credential.
  final CredentialSource? credentialSource;

  /// Why the last issuance attempt failed, if it did. Sanitized: status codes
  /// and server prose, never token material.
  final String? issueError;

  final String? orgId;
  final String? projectId;
  final String? keyId;
  final String? displayName;
  final String? planLabel;

  bool get hasModelCredential =>
      projectToken != null &&
      projectToken!.isNotEmpty &&
      (expiresAt == null || DateTime.now().isBefore(expiresAt!));

  bool get expired =>
      !hasModelCredential &&
      expiresAt != null &&
      DateTime.now().isAfter(expiresAt!);

  AccountRegion get accountRegion => AccountRegion.byId(region);

  /// Model credential for the agent runners; callers must check
  /// [hasModelCredential] first — this getter throws otherwise, so a degraded
  /// session can never quietly reach the network layer.
  String get modelCredential {
    final String? t = projectToken;
    if (t == null || t.isEmpty || !hasModelCredential) {
      throw AccountError(
        '模型凭证不可用${issueError == null ? '' : '：$issueError'}，请到 设置 › 账号 重新签发',
        step: 'issue',
        reauth: false,
      );
    }
    return t;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'region': region,
        'accessToken': accessToken,
        'zcodeJwt': zcodeJwt,
        'projectToken': projectToken ?? '',
        if (expiresAt != null) 'expiresAt': expiresAt!.toIso8601String(),
        if (credentialSource != null) 'credentialSource': credentialSource!.id,
        if (issueError != null) 'issueError': issueError,
        'orgId': orgId,
        'projectId': projectId,
        'keyId': keyId,
        'displayName': displayName,
        'planLabel': planLabel,
      };

  static AccountSession? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final String token = '${raw['projectToken'] ?? ''}';
    final CredentialSource? source = CredentialSource.byId(
      raw['credentialSource'] as String?,
    );
    return AccountSession(
      region: '${raw['region'] ?? 'bigmodel'}',
      accessToken: '${raw['accessToken'] ?? ''}',
      zcodeJwt: raw['zcodeJwt'] as String?,
      projectToken: token.isEmpty ? null : token,
      expiresAt: DateTime.tryParse('${raw['expiresAt']}'),
      // Sessions written before provenance existed may hold either a real
      // project token or the downgraded access token; mark them so the next
      // refresh re-issues instead of trusting them indefinitely.
      credentialSource: source ??
          (token.isEmpty ? null : CredentialSource.legacy),
      issueError: raw['issueError'] as String?,
      orgId: raw['orgId'] as String?,
      projectId: raw['projectId'] as String?,
      keyId: raw['keyId'] as String?,
      displayName: raw['displayName'] as String?,
      planLabel: raw['planLabel'] as String?,
    );
  }

  AccountSession copyWith({
    String? projectToken,
    DateTime? expiresAt,
    String? accessToken,
    String? zcodeJwt,
    CredentialSource? credentialSource,
    String? issueError,
    bool clearIssueError = false,
    String? orgId,
    String? projectId,
    String? keyId,
    String? displayName,
    String? planLabel,
  }) =>
      AccountSession(
        region: region,
        accessToken: accessToken ?? this.accessToken,
        zcodeJwt: zcodeJwt ?? this.zcodeJwt,
        projectToken: projectToken ?? this.projectToken,
        expiresAt: expiresAt ?? this.expiresAt,
        credentialSource: credentialSource ?? this.credentialSource,
        issueError: clearIssueError ? null : (issueError ?? this.issueError),
        orgId: orgId ?? this.orgId,
        projectId: projectId ?? this.projectId,
        keyId: keyId ?? this.keyId,
        displayName: displayName ?? this.displayName,
        planLabel: planLabel ?? this.planLabel,
      );
}

/// Where the session JSON lives. Production uses Android Keystore-backed
/// secure storage; tests swap in an in-memory fake, so no platform channel is
/// needed to exercise the credential chain.
abstract class SessionVault {
  Future<String?> read();
  Future<void> write(String value);
  Future<void> clear();
}

class SecureSessionVault implements SessionVault {
  static const FlutterSecureStorage _store = FlutterSecureStorage();
  static const String _key = 'zcode.session.v1';

  @override
  Future<String?> read() => _store.read(key: _key);

  @override
  Future<void> write(String value) => _store.write(key: _key, value: value);

  @override
  Future<void> clear() => _store.delete(key: _key);
}

class AccountService {
  AccountService({http.Client? client, SessionVault? vault})
      : _http = client ?? http.Client(),
        _vault = vault ?? SecureSessionVault();

  static const String _apiKeyName = 'zcode-api-key';
  static const String _tokenRoute = 'https://zcode.z.ai/api/v1/oauth/token';
  static const String _appId = 'zcode';
  static const String _clientVersion = '1.0.1';

  final http.Client _http;
  final SessionVault _vault;
  HttpServer? _server;

  // ---------------------------------------------------------------- session

  Future<AccountSession?> restore() async {
    try {
      final String? raw = await _vault.read();
      if (raw == null || raw.isEmpty) return null;
      return AccountSession.fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  Future<void> persist(AccountSession s) => _vault.write(jsonEncode(s.toJson()));

  Future<void> logout() async {
    await _vault.clear();
    await _stopServer();
  }

  // ------------------------------------------------------------------ login

  /// Runs the whole sign-in: opens the system browser, waits for the callback
  /// and exchanges the code for a usable model credential.
  ///
  /// [onProgress] receives short status strings for the UI; [onUrl] exposes the
  /// authorize URL so the user can open it manually if the browser did not.
  ///
  /// On the BigModel region a successful login always means a real project
  /// token was issued; if issuance fails the returned session carries
  /// `issueError` and no credential — it is never silently downgraded to the
  /// OAuth access token.
  Future<AccountSession> login(
    AccountRegion region, {
    void Function(String status)? onProgress,
    void Function(String url)? onUrl,
    Duration timeout = const Duration(minutes: 10),
  }) async {
    // A previous attempt that timed out or threw must not leave a listener
    // behind binding the port range.
    await _stopServer();
    final HttpServer server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    final String redirect = 'http://127.0.0.1:${server.port}/callback';
    final String state = _randomState();
    final Uri authorize = Uri.parse('${region.authorizeUrl}?redirect=${Uri.encodeComponent(redirect)}'
        '&appId=$_appId&state=$state');
    onUrl?.call(authorize.toString());

    try {
      try {
        await launchUrl(authorize, mode: LaunchMode.externalApplication);
      } catch (_) {
        // The URL is surfaced to the UI; the user can paste it into a browser.
      }

      onProgress?.call('正在打开浏览器授权…');
      final String code = await _waitForCode(server, state, timeout);
      onProgress?.call('授权成功，正在换取登录凭证…');

      final Map<String, dynamic> tokens =
          await _exchangeCode(region, code, redirect, state);
      final String access =
          _pickToken(tokens, <String>['access_token', 'accessToken']) ?? '';
      final String? zcodeJwt = _pickToken(tokens, <String>['token', 'zcodeJwt', 'jwt']);

      AccountSession session = AccountSession(
        region: region.id,
        accessToken: access,
        zcodeJwt: zcodeJwt,
        // No model credential yet — one is issued below or the session stays
        // explicitly degraded. The access token is account material only.
        projectToken: null,
        expiresAt: null,
        credentialSource: null,
      );

      if (region.id == 'zai') {
        // Overseas accounts have no separate project-token issuance: the
        // token-route JWT is the credential the model endpoint accepts.
        final String credential = access.isNotEmpty
            ? access
            : (zcodeJwt ?? '');
        if (credential.isEmpty) {
          throw AccountError(
            '登录失败：授权接口没有返回账号凭证',
            step: 'exchange',
          );
        }
        session = session.copyWith(
          projectToken: credential,
          expiresAt: DateTime.now().add(const Duration(minutes: 30)),
          credentialSource: CredentialSource.zaiJwt,
        );
      } else {
        onProgress?.call('正在获取套餐信息…');
        // Required step: without a project token the account must not be
        // marked model-capable. Record the failure on the session instead of
        // masking it with the access token.
        try {
          session = await _issueProjectToken(session, onProgress: onProgress);
        } on AccountError catch (e) {
          session = session.copyWith(issueError: e.message);
          onProgress?.call('已登录，但模型凭证签发失败：${e.message}');
        }
      }

      await persist(session);
      return session;
    } finally {
      // Success, failure, timeout or cancellation all land here: the loopback
      // listener must never outlive the attempt.
      await _stopServer();
    }
  }

  /// Re-issues the model credential. Throws [AccountError] with `reauth: true`
  /// when the account itself is no longer valid (401/403), so callers can
  /// distinguish "sign in again" from "try again later".
  Future<AccountSession> refresh(AccountSession current) async {
    if (current.region == 'zai') {
      // Nothing to re-issue server-side; an expired Z.ai session needs a
      // fresh interactive login.
      if (current.hasModelCredential) return current;
      throw AccountError('Z.ai 授权已过期，请重新登录', step: 'issue', reauth: true);
    }
    // BigModel: always run the full chain — a stored session may be missing
    // org/key ids (previous failure) or carry a legacy credential.
    final AccountSession next = await _issueProjectToken(current);
    await persist(next);
    return next;
  }

  // ---------------------------------------------------------------- helpers

  Future<String> _waitForCode(HttpServer server, String state, Duration timeout) {
    final Completer<String> done = Completer<String>();
    late StreamSubscription<HttpRequest> sub;
    sub = server.listen((HttpRequest req) async {
      final Uri uri = req.uri;
      if (uri.path != '/callback') {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }
      final String? gotState = uri.queryParameters['state'];
      final String? code =
          uri.queryParameters['authCode'] ?? uri.queryParameters['code'];
      final String? error = uri.queryParameters['error'];
      req.response.headers.contentType = ContentType.html;
      req.response.write(_callbackPage(error == null && code != null && gotState == state));
      await req.response.close();
      // Both success and error callbacks must match our state: a mismatched
      // request is someone else's, not the authorization server's answer.
      if (gotState != state) return;
      if (!done.isCompleted) {
        if (error != null) {
          done.completeError(AccountError('授权被拒绝：$error', step: 'authorize'));
        } else if (code != null) {
          done.complete(code);
        }
      }
    });

    return done.future.timeout(timeout, onTimeout: () {
      sub.cancel();
      throw AccountError('授权超时，请重试', step: 'authorize');
    });
  }

  Future<Map<String, dynamic>> _exchangeCode(
    AccountRegion region,
    String code,
    String redirect,
    String state,
  ) async {
    final http.Response resp = await _http
        .post(Uri.parse(_tokenRoute),
            headers: <String, String>{'content-type': 'application/json'},
            body: jsonEncode(<String, dynamic>{
              'provider': region.id,
              'code': code,
              'redirect_uri': redirect,
              'state': state,
            }))
        .timeout(const Duration(seconds: 30));
    final Map<String, dynamic> body = _decode(resp.body);
    if (resp.statusCode >= 400) {
      throw AccountError(
        '登录失败（${resp.statusCode}）：${_messageOf(body)}',
        step: 'exchange',
        statusCode: resp.statusCode,
        reauth: resp.statusCode == 401 || resp.statusCode == 403,
      );
    }
    return body;
  }

  Future<AccountSession> _issueProjectToken(
    AccountSession session, {
    void Function(String)? onProgress,
  }) async {
    final String base = session.accountRegion.apiBase;
    AccountSession out = session;

    // 1. Which organisation / project does this account belong to?
    if (out.orgId == null || out.projectId == null) {
      final Map<String, dynamic> info = await _getJson(
        '$base/api/biz/customer/getCustomerInfo',
        headers: <String, String>{'Authorization': out.accessToken},
      );
      final String? org = _deepString(info, <String>[
        'organizationId',
        'organization_id',
        'orgId',
        'org_id',
      ]);
      final String? project = _deepString(info, <String>[
        'projectId',
        'project_id',
        'defaultProjectId',
      ]);
      final String? name = _deepString(info, <String>[
        'customerName',
        'nickName',
        'name',
      ]);
      final String? plan = _deepString(info, <String>[
        'planName',
        'packageName',
        'productName',
      ]);
      out = out.copyWith(
        orgId: org,
        projectId: project,
        displayName: name,
        planLabel: plan,
      );
      if (org == null || project == null) {
        // Guessing ids to push through is explicitly forbidden: fail loudly.
        throw AccountError(
          '无法确定账号所属组织或项目，无法签发模型凭证',
          step: 'customer-info',
        );
      }
    }

    onProgress?.call('正在签发项目 Token…');
    final String keysPath =
        '$base/api/biz/v1/organization/${out.orgId}/projects/${out.projectId}/api_keys';

    // 2. Reuse the dedicated key, creating it once if missing.
    String? keyId = out.keyId;
    if (keyId == null) {
      final Map<String, dynamic> list = await _getJson(keysPath,
          headers: <String, String>{'Authorization': out.accessToken});
      keyId = _findKeyId(list, _apiKeyName);
      if (keyId == null) {
        final Map<String, dynamic> created = await _postJson(
          keysPath,
          headers: <String, String>{
            'Authorization': out.accessToken,
            'content-type': 'application/json',
          },
          body: <String, dynamic>{'name': _apiKeyName, 'usageScene': 1},
        );
        keyId = _deepString(created, <String>['id', 'apiKeyId', 'keyId']);
      }
    }
    if (keyId == null) {
      throw AccountError('无法创建或定位专用 API Key（$_apiKeyName）', step: 'api-keys');
    }

    // 3. Trade the key id for a short-lived project token.
    final Map<String, dynamic> issued = await _postJson(
      '$keysPath/$keyId/access_tokens',
      headers: <String, String>{
        'Authorization': 'Bearer ${out.accessToken}',
        'content-type': 'application/json',
      },
      body: <String, dynamic>{
        'clientType': 'zcode',
        'clientVersion': _clientVersion,
      },
    );
    final String? token =
        _deepString(issued, <String>['token', 'accessToken', 'access_token']);
    if (token == null || token.isEmpty) {
      throw AccountError(
        '签发接口没有返回有效 Token',
        step: 'issue',
        statusCode: null,
      );
    }

    final int ttl = _deepInt(issued, <String>['expiresIn', 'expires_in']) ?? 1800;
    return out.copyWith(
      projectToken: token,
      expiresAt: DateTime.now().add(Duration(seconds: ttl)),
      credentialSource: CredentialSource.projectToken,
      clearIssueError: true,
      keyId: keyId,
    );
  }

  Future<Map<String, dynamic>> _getJson(
    String url, {
    required Map<String, String> headers,
  }) async {
    final http.Response resp = await _http
        .get(Uri.parse(url), headers: headers)
        .timeout(const Duration(seconds: 25));
    if (resp.statusCode >= 400) {
      throw AccountError(
        '接口返回 ${resp.statusCode}',
        step: url.contains('getCustomerInfo') ? 'customer-info' : 'api-keys',
        statusCode: resp.statusCode,
        reauth: resp.statusCode == 401 || resp.statusCode == 403,
      );
    }
    return _decode(resp.body);
  }

  Future<Map<String, dynamic>> _postJson(
    String url, {
    required Map<String, String> headers,
    required Map<String, dynamic> body,
  }) async {
    final http.Response resp = await _http
        .post(Uri.parse(url), headers: headers, body: jsonEncode(body))
        .timeout(const Duration(seconds: 25));
    if (resp.statusCode >= 400) {
      throw AccountError(
        '接口返回 ${resp.statusCode}',
        step: url.endsWith('/access_tokens') ? 'issue' : 'api-keys',
        statusCode: resp.statusCode,
        reauth: resp.statusCode == 401 || resp.statusCode == 403,
      );
    }
    return _decode(resp.body);
  }

  Future<void> _stopServer() async {
    await _server?.close(force: true);
    _server = null;
  }

  void dispose() {
    _stopServer();
    _http.close();
  }

  // ------------------------------------------------------------- json utils

  static Map<String, dynamic> _decode(String body) {
    if (body.trim().isEmpty) return <String, dynamic>{};
    try {
      final Object? v = jsonDecode(body);
      return v is Map<String, dynamic> ? v : <String, dynamic>{'raw': v};
    } catch (_) {
      return <String, dynamic>{'raw': body};
    }
  }

  static String? _messageOf(Map<String, dynamic> body) {
    final String? msg =
        _deepString(body, <String>['msg', 'message', 'error_description', 'error']);
    return msg;
  }

  static String? _pickToken(Map<String, dynamic> body, List<String> keys) {
    // token route nests values under data / data.bigmodel
    final Object? data = body['data'];
    if (data is Map) {
      for (final String k in keys) {
        final Object? v = data[k];
        if (v is String && v.isNotEmpty) return v;
      }
      final Object? bm = data['bigmodel'];
      if (bm is Map) {
        for (final String k in keys) {
          final Object? v = bm[k];
          if (v is String && v.isNotEmpty) return v;
        }
      }
    }
    for (final String k in keys) {
      final Object? v = body[k];
      if (v is String && v.isNotEmpty) return v;
    }
    return null;
  }

  /// Depth-first search so small schema changes upstream do not break sign-in.
  static String? _deepString(Object? node, List<String> keys, [int depth = 0]) {
    if (depth > 6 || node == null) return null;
    if (node is Map) {
      for (final String k in keys) {
        final Object? v = node[k];
        if (v is String && v.trim().isNotEmpty) return v.trim();
      }
      for (final Object? v in node.values) {
        final String? hit = _deepString(v, keys, depth + 1);
        if (hit != null) return hit;
      }
    } else if (node is List) {
      for (final Object? v in node) {
        final String? hit = _deepString(v, keys, depth + 1);
        if (hit != null) return hit;
      }
    }
    return null;
  }

  static int? _deepInt(Object? node, List<String> keys, [int depth = 0]) {
    if (depth > 6 || node == null) return null;
    if (node is Map) {
      for (final String k in keys) {
        final Object? v = node[k];
        if (v is int) return v;
        if (v is String) {
          final int? parsed = int.tryParse(v);
          if (parsed != null) return parsed;
        }
      }
      for (final Object? v in node.values) {
        final int? hit = _deepInt(v, keys, depth + 1);
        if (hit != null) return hit;
      }
    }
    return null;
  }

  static String? _findKeyId(Map<String, dynamic> body, String name) {
    List<Object?> candidates = <Object?>[];
    final Object? data = body['data'];
    if (data is List) candidates = data;
    if (data is Map) {
      for (final Object? v in data.values) {
        if (v is List) candidates = v;
      }
    }
    for (final Object? item in candidates) {
      if (item is! Map) continue;
      final String itemName = '${item['name'] ?? item['keyName'] ?? ''}';
      if (itemName == name) {
        final Object? id = item['id'] ?? item['apiKeyId'] ?? item['keyId'];
        if (id != null) return '$id';
      }
    }
    return null;
  }

  static String _randomState() {
    final Random r = Random.secure();
    final StringBuffer b = StringBuffer();
    for (int i = 0; i < 32; i++) {
      b.write(r.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return b.toString();
  }

  static String _callbackPage(bool ok) => '''
<!doctype html><meta charset="utf-8">
<title>ZCode</title>
<body style="font-family:system-ui;background:#0C0E12;color:#fff;display:grid;place-items:center;height:100vh;margin:0">
<div style="text-align:center">
  <div style="font-size:44px">${ok ? '✓' : '✕'}</div>
  <p style="font-size:16px">${ok ? '授权成功，请返回 ZCode' : '授权失败，请返回 ZCode 重试'}</p>
</div>
</body>''';
}
