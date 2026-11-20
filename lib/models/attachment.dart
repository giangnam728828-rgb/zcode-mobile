import 'dart:io';

/// A file the user pinned to a message from the workspace.
class Attachment {
  const Attachment({
    required this.path,
    required this.name,
    required this.isImage,
    this.size = 0,
    this.mediaType,
  });

  /// Workspace-relative path; the absolute path is resolved at send time.
  final String path;
  final String name;
  final bool isImage;
  final int size;
  final String? mediaType;

  static bool looksLikeImage(String name) {
    final String n = name.toLowerCase();
    return n.endsWith('.png') ||
        n.endsWith('.jpg') ||
        n.endsWith('.jpeg') ||
        n.endsWith('.webp') ||
        n.endsWith('.gif') ||
        n.endsWith('.bmp');
  }

  static String guessMediaType(String name) {
    final String n = name.toLowerCase();
    if (n.endsWith('.png')) return 'image/png';
    if (n.endsWith('.jpg') || n.endsWith('.jpeg')) return 'image/jpeg';
    if (n.endsWith('.webp')) return 'image/webp';
    if (n.endsWith('.gif')) return 'image/gif';
    if (n.endsWith('.bmp')) return 'image/bmp';
    return 'application/octet-stream';
  }

  static Future<Attachment> of(File file, String relativePath) async {
    int size = 0;
    try {
      size = await file.length();
    } catch (_) {}
    final String name = file.path.split('/').last;
    final bool image = looksLikeImage(name);
    return Attachment(
      path: relativePath,
      name: name,
      isImage: image,
      size: size,
      mediaType: image ? guessMediaType(name) : null,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'path': path,
        'name': name,
        'isImage': isImage,
        if (size > 0) 'size': size,
        if (mediaType != null) 'mediaType': mediaType,
      };

  static Attachment fromJson(Map<String, dynamic> json) => Attachment(
        path: '${json['path'] ?? ''}',
        name: '${json['name'] ?? ''}',
        isImage: json['isImage'] == true,
        size: (json['size'] as int?) ?? 0,
        mediaType: json['mediaType'] as String?,
      );

  String get sizeLabel {
    if (size <= 0) return '';
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    return '${(size / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}
