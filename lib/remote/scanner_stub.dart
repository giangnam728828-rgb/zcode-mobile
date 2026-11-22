import 'package:flutter/material.dart';

/// Web build stand-in: the in-app camera scanner is a native (Android) surface
/// and is not compiled into the web dev preview at all.
Future<String?> scanDesktopQr(BuildContext context) async {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(const SnackBar(
      content: Text('网页预览不支持扫码，请复制桌面端链接后使用「粘贴链接」'),
      duration: Duration(milliseconds: 2600),
    ));
  return null;
}
