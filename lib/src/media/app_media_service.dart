import 'dart:io';

import 'package:http/http.dart' as http;

import '../discovery/tenant_config.dart';
import '../network/app_api_client.dart';
import '../session/app_session.dart';
import 'app_documents_directory.dart';

enum AppMediaKind {
  image(messageType: 2, wireName: 'image'),
  file(messageType: 3, wireName: 'file');

  const AppMediaKind({required this.messageType, required this.wireName});

  final int messageType;
  final String wireName;
}

final class AppMediaUpload {
  const AppMediaUpload({
    required this.fileId,
    required this.kind,
    required this.name,
    required this.size,
    required this.mimeType,
    required this.extension,
  });

  factory AppMediaUpload.fromJson(Object? value) {
    final map = _map(value, 'upload');
    final kind = switch (_string(map, 'kind')) {
      'image' => AppMediaKind.image,
      'file' => AppMediaKind.file,
      _ => throw const FormatException('upload.kind 无效'),
    };
    final fileId = _string(map, 'file_id');
    if (!RegExp(r'^[a-f0-9]{40}$').hasMatch(fileId)) {
      throw const FormatException('upload.file_id 无效');
    }
    return AppMediaUpload(
      fileId: fileId,
      kind: kind,
      name: _string(map, 'name'),
      size: _integer(map, 'size'),
      mimeType: _string(map, 'mime_type', allowEmpty: true),
      extension: _string(map, 'extension'),
    );
  }

  final String fileId;
  final AppMediaKind kind;
  final String name;
  final int size;
  final String mimeType;
  final String extension;
}

abstract interface class AppMediaGateway {
  Future<AppMediaUpload> upload({
    required TenantConfig tenant,
    required AppSession session,
    required AppMediaKind kind,
    required String filePath,
    required String filename,
    required int size,
    required String mimeType,
  });

  Future<Uri> resolve({
    required TenantConfig tenant,
    required AppSession session,
    required String fileId,
    required String conversationId,
    required String messageId,
  });

  Future<String> download({
    required TenantConfig tenant,
    required AppSession session,
    required String fileId,
    required String conversationId,
    required String messageId,
    required String filename,
  });
}

final class AppMediaService implements AppMediaGateway {
  AppMediaService(
    this._api, {
    http.Client? downloadClient,
    Future<Directory> Function()? documentsDirectory,
    this.uploadTimeout = const Duration(minutes: 10),
  }) : _downloadClient = downloadClient ?? http.Client(),
       _ownsDownloadClient = downloadClient == null,
       _documentsDirectory = documentsDirectory ?? defaultAppDocumentsDirectory;

  final AppApiClient _api;
  final http.Client _downloadClient;
  final bool _ownsDownloadClient;
  final Future<Directory> Function() _documentsDirectory;
  final Duration uploadTimeout;
  final Map<String, _ResolvedAsset> _resolved = {};

  @override
  Future<AppMediaUpload> upload({
    required TenantConfig tenant,
    required AppSession session,
    required AppMediaKind kind,
    required String filePath,
    required String filename,
    required int size,
    required String mimeType,
  }) async {
    if (size <= 0 || filename.trim().isEmpty || mimeType.trim().isEmpty) {
      throw const FormatException('上传文件元数据无效');
    }
    final prepared = _map(
      await _api.request(
        tenant,
        '/saimulti/app/im/prepareUpload',
        method: AppApiMethod.post,
        accessToken: session.accessToken,
        body: {
          'kind': kind.wireName,
          'filename': filename,
          'size': size,
          'mime_type': mimeType,
        },
      ),
      'prepare upload',
    );
    final uploadPath = _string(prepared, 'upload_path');
    if (prepared['mode'] != 'proxy' ||
        prepared['method'] != 'POST' ||
        uploadPath != '/saimulti/app/im/upload') {
      throw const FormatException('App 上传准备响应无效');
    }
    final upload = AppMediaUpload.fromJson(
      await _api.multipart(
        tenant,
        uploadPath,
        accessToken: session.accessToken,
        filePath: filePath,
        filename: filename,
        mimeType: mimeType,
        fields: {'kind': kind.wireName},
        requestTimeout: uploadTimeout,
      ),
    );
    if (upload.kind != kind || upload.name != filename || upload.size != size) {
      throw const FormatException('上传结果与源文件不一致');
    }
    return upload;
  }

  @override
  Future<Uri> resolve({
    required TenantConfig tenant,
    required AppSession session,
    required String fileId,
    required String conversationId,
    required String messageId,
  }) async {
    final key =
        '${tenant.organization}:${session.user.userId}:'
        '$fileId:$conversationId:$messageId';
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final cached = _resolved[key];
    if (cached != null && cached.expiresAt > now + 10) return cached.url;
    final payload = _map(
      await _api.request(
        tenant,
        '/saimulti/app/im/resolveAssetUrl',
        method: AppApiMethod.post,
        accessToken: session.accessToken,
        body: {
          'file_id': fileId,
          'conversation_id': conversationId,
          'message_id': messageId,
        },
      ),
      'asset url',
    );
    if (_string(payload, 'file_id') != fileId) {
      throw const FormatException('附件地址与 file_id 不一致');
    }
    final url = Uri.parse(_string(payload, 'url'));
    final expiresAt = _integer(payload, 'expires_at');
    if (url.scheme != 'https' || !url.hasAuthority || expiresAt <= now) {
      throw const FormatException('附件签名地址无效');
    }
    _resolved[key] = _ResolvedAsset(url, expiresAt);
    return url;
  }

  @override
  Future<String> download({
    required TenantConfig tenant,
    required AppSession session,
    required String fileId,
    required String conversationId,
    required String messageId,
    required String filename,
  }) async {
    final url = await resolve(
      tenant: tenant,
      session: session,
      fileId: fileId,
      conversationId: conversationId,
      messageId: messageId,
    );
    final base = await _documentsDirectory();
    final directory = Directory(
      '${base.path}${Platform.pathSeparator}b8im_downloads',
    );
    await directory.create(recursive: true);
    final safeName = _safeFilename(filename);
    var target = File('${directory.path}${Platform.pathSeparator}$safeName');
    if (await target.exists()) {
      final dot = safeName.lastIndexOf('.');
      final stem = dot > 0 ? safeName.substring(0, dot) : safeName;
      final suffix = dot > 0 ? safeName.substring(dot) : '';
      target = File(
        '${directory.path}${Platform.pathSeparator}'
        '${stem}_${DateTime.now().millisecondsSinceEpoch}$suffix',
      );
    }
    try {
      final response = await _downloadClient.send(http.Request('GET', url));
      if (response.statusCode != 200) {
        throw AppApiException('附件下载失败（HTTP ${response.statusCode}）');
      }
      await response.stream.pipe(target.openWrite());
      return target.path;
    } on Object {
      if (await target.exists()) await target.delete();
      rethrow;
    }
  }

  void close() {
    if (_ownsDownloadClient) _downloadClient.close();
  }
}

final class _ResolvedAsset {
  const _ResolvedAsset(this.url, this.expiresAt);

  final Uri url;
  final int expiresAt;
}

Map<String, Object?> _map(Object? value, String field) {
  if (value is! Map) throw FormatException('$field 格式无效');
  return value.map((key, item) => MapEntry(key.toString(), item));
}

String _string(
  Map<String, Object?> map,
  String key, {
  bool allowEmpty = false,
}) {
  final value = map[key];
  if (value is! String || (!allowEmpty && value.trim().isEmpty)) {
    throw FormatException('$key 格式无效');
  }
  return value.trim();
}

int _integer(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! int) throw FormatException('$key 格式无效');
  return value;
}

String _safeFilename(String value) {
  final normalized = value.trim().replaceAll(
    RegExp(r'[\\/:*?"<>|\x00-\x1F]'),
    '_',
  );
  if (normalized.isEmpty || normalized == '.' || normalized == '..') {
    return 'b8im_file';
  }
  return normalized.length <= 180 ? normalized : normalized.substring(0, 180);
}
