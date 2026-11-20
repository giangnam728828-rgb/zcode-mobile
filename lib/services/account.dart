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
/// The project token is what model requests carry, so no API key is ever
/// pasted by the user and the phone spends the same plan quota as the desktop.
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

class AccountError implements Exception {
  AccountError(this.message);
  final String message;
  @override
  String toString() => message;
}

class AccountSession {
  AccountSession({
    required this.region,
    required this.accessToken,
    required this.projectToken,
    required this.expiresAt,
    this.zcodeJwt,
    this.orgId,
    this.projectId,
    this.keyId,
    this.displayName,
    this.planLabel,
  });

  final String region;

  /// Login JWT / business access token; used to re-issue project tokens.
  final String accessToken;
  final String? zcodeJwt;

  /// Credential actually sent to the model endpoint.
  final String projectToken;
  final DateTime expiresAt;
  final String? orgId;
  final String? projectId;
  final String? keyId;
  final String? displayName;
  final String? planLabel;

  bool get expired => DateTime.now().isAfter(expiresAt);

  AccountRegion get accountRegion => AccountRegion.byId(region);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'region': region,
        'accessToken': accessToken,
        'zcodeJwt': zcodeJwt,
        'projectToken': projectToken,
        'expiresAt': expiresAt.toIso8601String(),
        'orgId': orgId,
        'projectId': projectId,
        'keyId': keyId,
        'displayName': displayName,
        'planLabel': planLabel,
      };

  static AccountSession? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final String token = '${raw['projectToken'] ?? ''}';
    if (token.isEmpty) return null;
    return AccountSession(
      region: '${raw['region'] ?? 'bigmodel'}',
      accessToken: '${raw['accessToken'] ?? ''}',
      zcodeJwt: raw['zcodeJwt'] as String?,
      projectToken: token,
      expiresAt: DateTime.tryParse('${raw['expiresAt']}') ??
          DateTime.now().add(const Duration(minutes: 30)),
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
    String? displayName,
    String? planLabel,
  }) =>
      AccountSession(
        region: region,
        accessToken: accessToken ?? this.accessToken,
        zcodeJwt: zcodeJwt ?? this.zcodeJwt,
        projectToken: projectToken ?? this.projectToken,
        expiresAt: expiresAt ?? this.expiresAt,
        orgId: orgId,
        projectId: projectId,
        keyId: keyId,
        displayName: displayName ?? this.displayName,
        planLabel: planLabel ?? this.planLabel,
      );
}

class AccountService {
  AccountService({http.Client? client}) : _http = client ?? http.Client();

  static const String _storeKey = 'zcode.session.v1';
  static const FlutterSecureStorage _vault = FlutterSecureStorage();
  static const String _tokenRoute = 'https://zcode.z.ai/api/v1/oauth/token';
  static const String _appId = 'zcode';
  static const String _clientVersion = '1.0.1';
  static const String _apiKeyName = 'zcode-api-key';

  final http.Client _http;
  HttpServer? _server;

  // ---------------------------------------------------------------- session

  Future<AccountSession?> restore() async {
    try {
      final String? raw = await _vault.read(key: _storeKey);
      if (raw == null || raw.isEmpty) return null;
      return AccountSession.fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  Future<void> persist(AccountSession s) =>
      _vault.write(key: _storeKey, value: jsonEncode(s.toJson()));

  Future<void> logout() async {
    await _vault.delete(key: _storeKey);
    await _stopServer();
  }

  // ------------------------------------------------------------------ login

  /// Runs the whole sign-in: opens the system browser, waits for the callback
  /// and exchanges the code for a usable model credential.
  ///
  /// [onProgress] receives short status strings for the UI; [onUrl] exposes the
  /// authorize URL so the user can open it manually if the browser did not.
  Future<AccountSession> login(
    AccountRegion region, {
    void Function(String status)? onProgress,
    void Function(String url)? onUrl,
    Duration timeout = const Duration(minutes: 10),
  }) async {
    onProgress?.call('正在打开浏览器授权…');
    final HttpServer server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    final String redirect = 'http://127.0.0.1:${server.port}/callback';
    final String state = _randomState();
    final Uri authorize = Uri.parse('${region.authorizeUrl}?redirect=${Uri.encodeComponent(redirect)}'
        '&appId=$_appId&state=$state');
    onUrl?.call(authorize.toString());

    try {
      await launchUrl(authorize, mode: LaunchMode.externalApplication);
    } catch (_) {
      // The URL is surfaced to the UI; the user can paste it into a browser.
    }

    final String code = await _waitForCode(server, state, timeout);
    onProgress?.call('授权成功，正在换取登录凭证…');

    final Map<String, dynamic> tokens = await _exchangeCode(region, code, redirect, state);
    final String access = _pickToken(tokens, <String>['access_token', 'accessToken']) ?? '';
    final String? zcodeJwt = _pickToken(tokens, <String>['token', 'zcodeJwt', 'jwt']);
    if (access.isEmpty) {
      throw AccountError('登录失败：授权接口没有返回账号凭证');
    }

    onProgress?.call('正在获取套餐信息…');
    AccountSession session = AccountSession(
      region: region.id,
      accessToken: access,
      zcodeJwt: zcodeJwt,
      projectToken: access,
      expiresAt: DateTime.now().add(const Duration(minutes: 30)),
    );

    if (region.id == 'bigmodel') {
      // Best effort: resolve the project token. If any step is unavailable we
      // keep the account token so the user can still talk to the model.
      try {
        session = await _issueProjectToken(session, onProgress: onProgress);
      } catch (_) {
        // kept as-is
      }
    }

    await persist(session);
    await _stopServer();
    return session;
  }

  Future<AccountSession> refresh(AccountSession current) async {
    if (current.region != 'bigmodel' || current.orgId == null) {
      return current;
    }
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
      final String? code = uri.queryParameters['authCode'] ?? uri.queryParameters['code'];
      final String? error = uri.queryParameters['error'];
      req.response.headers.contentType = ContentType.html;
      req.response.write(_callbackPage(error == null && code != null));
      await req.response.close();
      if (error != null && !done.isCompleted) {
        done.completeError(AccountError('授权被拒绝：$error'));
      } else if (gotState == state && code != null && !done.isCompleted) {
        done.complete(code);
      }
    });

    return done.future.timeout(timeout, onTimeout: () {
      sub.cancel();
      throw AccountError('授权超时，请重试');
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
      throw AccountError('登录失败（${resp.statusCode}）：${_messageOf(body)}');
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
      out = AccountSession(
        region: out.region,
        accessToken: out.accessToken,
        zcodeJwt: out.zcodeJwt,
        projectToken: out.projectToken,
        expiresAt: out.expiresAt,
        orgId: org,
        projectId: project,
        keyId: out.keyId,
        displayName: name ?? out.displayName,
        planLabel: plan ?? out.planLabel,
      );
      if (org == null || project == null) return out;
    }

    onProgress?.call('正在签发项目 Token…');
    final String keysPath =
        '$base/api/biz/v1/organization/${out.orgId}/projects/${out.projectId}/api_keys';

    // 2. Reuse the dedicated key, creating it once if missing.
    String? keyId = out.keyId;
    if (keyId == null) {
      final Map<String, dynamic> list =
          await _getJson(keysPath, headers: <String, String>{'Authorization': out.accessToken});
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
    if (keyId == null) return out;

    // 3. Trade the key id for a short-lived project token.
    final Map<String, dynamic> issued = await _postJson(
      '$keysPath/$keyId/access_tokens',
      headers: <String, String>{
        'Authorization': 'Bearer ${out.accessToken}',
        'content-type': 'application/json',
      },
      body: <String, dynamic>{
        'clientType': _clientVersion == '' ? 'zcode' : 'zcode',
        'clientVersion': _clientVersion,
      },
    );
    final String? token = _deepString(issued, <String>['token', 'accessToken', 'access_token']);
    if (token == null) return out;

    final int ttl = _deepInt(issued, <String>['expiresIn', 'expires_in']) ?? 1800;
    return AccountSession(
      region: out.region,
      accessToken: out.accessToken,
      zcodeJwt: out.zcodeJwt,
      projectToken: token,
      expiresAt: DateTime.now().add(Duration(seconds: ttl)),
      orgId: out.orgId,
      projectId: out.projectId,
      keyId: keyId,
      displayName: out.displayName,
      planLabel: out.planLabel,
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
      throw AccountError('接口返回 ${resp.statusCode}');
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
      throw AccountError('接口返回 ${resp.statusCode}');
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
