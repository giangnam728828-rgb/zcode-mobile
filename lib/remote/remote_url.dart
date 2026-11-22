/// Validation and masking for official desktop remote-control links.
///
/// The link a desktop shows is itself the authorization: anyone holding it can
/// operate that desktop window (official Remote Control docs). That drives the
/// rules here (总方案 P0-4):
///
///   - only the official `https://zcode.z.ai/remote/…` entry family is
///     accepted — no arbitrary web pages, no other hosts;
///   - query parameters (`sid`/`hash`/device id …) are credentials, so the
///     full URL is never written to plain preferences or logs, and the UI only
///     shows a masked form.
class RemoteUrlCheck {
  const RemoteUrlCheck._(this.ok, this.problem, this.uri);

  final bool ok;
  final String? problem;
  final Uri? uri;
}

class RemoteUrl {
  RemoteUrl._();

  /// The only host the official remote page lives on.
  static const String officialHost = 'zcode.z.ai';

  /// Everything under /remote/ is accepted (v4 today, later versions later);
  /// the actual protocol is carried by the official page itself.
  static const String officialPathPrefix = '/remote/';

  /// True when [u] is an official remote-control page URL.
  static bool looksOfficial(Uri u) =>
      u.scheme == 'https' &&
      u.host == officialHost &&
      u.path.startsWith(officialPathPrefix);

  /// Validates raw user input (pasted link or a scanned QR payload) and
  /// returns the normalized URL on success. Tolerates a scanner reading extra
  /// text around the link by extracting the first https URL.
  static RemoteUrlCheck validate(String raw) {
    final String text = raw.trim();
    if (text.isEmpty) {
      return const RemoteUrlCheck._(false, '链接为空', null);
    }
    final RegExpMatch? match =
        RegExp(r'https://\S+', caseSensitive: false).firstMatch(text);
    final String candidate = match?.group(0) ?? text;
    final Uri? parsed = Uri.tryParse(candidate);
    if (parsed == null || !parsed.hasScheme) {
      return const RemoteUrlCheck._(false, '不是有效的链接', null);
    }
    if (parsed.scheme != 'https') {
      return const RemoteUrlCheck._(false, '只接受官方 https 链接', null);
    }
    if (parsed.host != officialHost) {
      return RemoteUrlCheck._(false, '只接受官方远程控制链接（$officialHost）', null);
    }
    if (!parsed.path.startsWith(officialPathPrefix)) {
      return const RemoteUrlCheck._(
          false, '这不是桌面远程控制链接（缺少 /remote/ 路径）', null);
    }
    return RemoteUrlCheck._(true, null, parsed.removeFragment());
  }

  /// Safe form for lists and dialogs: keeps host/path, collapses every query
  /// value to its last four characters. Never returns the credential itself.
  /// Assembled by hand — Uri's queryParameters would percent-encode the mask
  /// characters and defeat the point.
  static String mask(Uri u) {
    final StringBuffer out = StringBuffer('https://${u.host}${u.path}');
    final Map<String, String> params = u.queryParameters;
    if (params.isNotEmpty) {
      final String query = params.entries.map((MapEntry<String, String> e) {
        final String v = e.value.length <= 4
            ? '••••'
            : '••••${e.value.substring(e.value.length - 4)}';
        return '${e.key}=$v';
      }).join('&');
      out.write('?$query');
    }
    return out.toString();
  }
}
