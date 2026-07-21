import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../discovery/tenant_config.dart';
import '../im/group_member_access.dart';
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
    required int conversationType,
    required String conversationId,
    required String filePath,
    required String filename,
    required int size,
    required String mimeType,
  });

  Future<Uri> resolve({
    required TenantConfig tenant,
    required AppSession session,
    required String fileId,
    required int conversationType,
    required String conversationId,
    required String messageId,
    required int messageSeq,
  });

  Future<String> download({
    required TenantConfig tenant,
    required AppSession session,
    required String fileId,
    required int conversationType,
    required String conversationId,
    required String messageId,
    required int messageSeq,
    required String filename,
  });
}

final class AppMediaService implements AppMediaGateway {
  AppMediaService(
    AppApiClient api, {
    http.Client Function()? apiTransportFactory,
    http.Client Function()? downloadTransportFactory,
    Future<Directory> Function()? documentsDirectory,
    Future<void> Function(File file)? deleteFile,
    this.uploadTimeout = const Duration(minutes: 10),
  }) : _api = api,
       _apiTransportFactory = apiTransportFactory ?? api.createRequestClient,
       _downloadTransportFactory =
           downloadTransportFactory ?? api.createRequestClient,
       _documentsDirectory = documentsDirectory ?? defaultAppDocumentsDirectory,
       _deleteFile = deleteFile ?? _defaultDeleteFile;

  final AppApiClient _api;
  final http.Client Function() _apiTransportFactory;
  final http.Client Function() _downloadTransportFactory;
  final Future<Directory> Function() _documentsDirectory;
  final Future<void> Function(File file) _deleteFile;
  final Duration uploadTimeout;
  final Map<String, _ResolvedAsset> _resolved = {};
  final Map<String, int> _watchedGroupGenerations = {};
  final Map<String, Set<String>> _groupDownloadArtifacts = {};
  final Map<String, Set<_MediaCancelableOperation>> _groupOperations = {};
  final Set<_MediaCancelableOperation> _allOperations = {};
  bool _closed = false;

  @override
  Future<AppMediaUpload> upload({
    required TenantConfig tenant,
    required AppSession session,
    required AppMediaKind kind,
    required int conversationType,
    required String conversationId,
    required String filePath,
    required String filename,
    required int size,
    required String mimeType,
  }) async {
    if (size <= 0 || filename.trim().isEmpty || mimeType.trim().isEmpty) {
      throw const FormatException('上传文件元数据无效');
    }
    final access = _captureAccess(
      session,
      conversationType: conversationType,
      conversationId: conversationId,
      requireActive: true,
    );
    final operation = _beginOperation(access);
    try {
      final preparedPayload = await _withTransport(
        operation,
        _apiTransportFactory,
        (client) => _api.request(
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
          requestClient: client,
        ),
      );
      access.assertCurrent();
      final prepared = _map(preparedPayload, 'prepare upload');
      final uploadPath = _string(prepared, 'upload_path');
      if (prepared['mode'] != 'proxy' ||
          prepared['method'] != 'POST' ||
          uploadPath != '/saimulti/app/im/upload') {
        throw const FormatException('App 上传准备响应无效');
      }
      final upload = AppMediaUpload.fromJson(
        await _withTransport(
          operation,
          _apiTransportFactory,
          (client) => _api.multipart(
            tenant,
            uploadPath,
            accessToken: session.accessToken,
            filePath: filePath,
            filename: filename,
            mimeType: mimeType,
            fields: {'kind': kind.wireName},
            requestTimeout: uploadTimeout,
            requestClient: client,
          ),
        ),
      );
      access.assertCurrent();
      if (upload.kind != kind ||
          upload.name != filename ||
          upload.size != size) {
        throw const FormatException('上传结果与源文件不一致');
      }
      access.assertCurrent();
      return upload;
    } finally {
      _finishOperation(access, operation);
    }
  }

  @override
  Future<Uri> resolve({
    required TenantConfig tenant,
    required AppSession session,
    required String fileId,
    required int conversationType,
    required String conversationId,
    required String messageId,
    required int messageSeq,
  }) async {
    final access = _captureAccess(
      session,
      conversationType: conversationType,
      conversationId: conversationId,
      messageSeq: messageSeq,
      requireActive: false,
    );
    final key = '${access.cachePrefix}:$fileId:$conversationId:$messageId';
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final cached = _resolved[key];
    if (cached != null && cached.expiresAt > now + 10) {
      access.assertCurrent();
      return cached.url;
    }
    final operation = _beginOperation(access);
    try {
      final rawPayload = await _withTransport(
        operation,
        _apiTransportFactory,
        (client) => _api.request(
          tenant,
          '/saimulti/app/im/resolveAssetUrl',
          method: AppApiMethod.post,
          accessToken: session.accessToken,
          body: {
            'file_id': fileId,
            'conversation_id': conversationId,
            'message_id': messageId,
          },
          requestClient: client,
        ),
      );
      access.assertCurrent();
      final payload = _map(rawPayload, 'asset url');
      if (_string(payload, 'file_id') != fileId) {
        throw const FormatException('附件地址与 file_id 不一致');
      }
      final url = Uri.parse(_string(payload, 'url'));
      final expiresAt = _integer(payload, 'expires_at');
      if (url.scheme != 'https' || !url.hasAuthority || expiresAt <= now) {
        throw const FormatException('附件签名地址无效');
      }
      access.assertCurrent();
      _resolved[key] = _ResolvedAsset(
        url,
        expiresAt,
        groupScope: access.groupScope,
        groupGeneration: access.groupGeneration,
      );
      access.assertCurrent();
      return url;
    } finally {
      _finishOperation(access, operation);
    }
  }

  @override
  Future<String> download({
    required TenantConfig tenant,
    required AppSession session,
    required String fileId,
    required int conversationType,
    required String conversationId,
    required String messageId,
    required int messageSeq,
    required String filename,
  }) async {
    final access = _captureAccess(
      session,
      conversationType: conversationType,
      conversationId: conversationId,
      messageSeq: messageSeq,
      requireActive: false,
    );
    final operation = _beginOperation(access);
    try {
      final url = await operation.waitCurrent(
        resolve(
          tenant: tenant,
          session: session,
          fileId: fileId,
          conversationType: conversationType,
          conversationId: conversationId,
          messageId: messageId,
          messageSeq: messageSeq,
        ),
      );
      access.assertCurrent();
      final base = await operation.waitCurrent(_documentsDirectory());
      access.assertCurrent();
      final directory = Directory(
        '${base.path}${Platform.pathSeparator}b8im_downloads',
      );
      await operation.waitCurrent(directory.create(recursive: true));
      access.assertCurrent();
      final safeName = _safeFilename(filename);
      var target = File('${directory.path}${Platform.pathSeparator}$safeName');
      final targetExists = await operation.waitCurrent(target.exists());
      access.assertCurrent();
      if (targetExists) {
        final dot = safeName.lastIndexOf('.');
        final stem = dot > 0 ? safeName.substring(0, dot) : safeName;
        final suffix = dot > 0 ? safeName.substring(dot) : '';
        target = File(
          '${directory.path}${Platform.pathSeparator}'
          '${stem}_${DateTime.now().millisecondsSinceEpoch}$suffix',
        );
      }
      final temporary = File(
        '${directory.path}${Platform.pathSeparator}.'
        '$safeName.${DateTime.now().microsecondsSinceEpoch}.part',
      );
      operation.trackPath(temporary.path);
      operation.trackPath(target.path);
      final client = _downloadTransportFactory();
      operation.attachTransport(client);
      try {
        final response = await operation.waitCurrent(
          client.send(http.Request('GET', url)),
        );
        access.assertCurrent();
        if (response.statusCode != 200) {
          throw AppApiException('附件下载失败（HTTP ${response.statusCode}）');
        }
        await _pipeWithAccessCancellation(
          response.stream,
          temporary,
          operation,
        );
      } finally {
        operation.detachTransport(client);
        client.close();
      }
      access.assertCurrent();
      await operation.waitCurrent(temporary.rename(target.path));
      operation.untrackPath(temporary.path);
      access.assertCurrent();
      access.rememberArtifact(target.path);
      operation.untrackPath(target.path);
      access.assertCurrent();
      return target.path;
    } on Object catch (error, stackTrace) {
      try {
        await operation.cleanupFiles(_deleteWithRetry);
      } on Object catch (cleanupError, cleanupStackTrace) {
        Error.throwWithStackTrace(cleanupError, cleanupStackTrace);
      }
      Error.throwWithStackTrace(error, stackTrace);
    } finally {
      _finishOperation(access, operation);
    }
  }

  Future<void> _pipeWithAccessCancellation(
    http.ByteStream stream,
    File target,
    _MediaCancelableOperation operation,
  ) async {
    final sink = target.openWrite();
    final complete = Completer<void>();
    late final StreamSubscription<List<int>> subscription;
    var settled = false;
    Future<void> finishError(Object error, StackTrace stackTrace) async {
      if (settled) return;
      settled = true;
      await subscription.cancel();
      await sink.close();
      if (!complete.isCompleted) complete.completeError(error, stackTrace);
    }

    subscription = stream.listen(
      sink.add,
      onError: (Object error, StackTrace stackTrace) {
        unawaited(finishError(error, stackTrace));
      },
      onDone: () async {
        if (settled) return;
        settled = true;
        try {
          await sink.flush();
          await sink.close();
          if (!complete.isCompleted) complete.complete();
        } on Object catch (error, stackTrace) {
          if (!complete.isCompleted) complete.completeError(error, stackTrace);
        }
      },
      cancelOnError: true,
    );
    operation.trackStream(complete.future);
    unawaited(
      operation.cancelled.then((_) {
        return finishError(StateError('群访问快照已变化，附件下载已取消'), StackTrace.current);
      }),
    );
    await complete.future;
  }

  Future<T> _withTransport<T>(
    _MediaCancelableOperation operation,
    http.Client Function() factory,
    Future<T> Function(http.Client client) request,
  ) async {
    if (_closed) throw StateError('媒体服务已关闭');
    final client = factory();
    operation.attachTransport(client);
    try {
      return await operation.waitCurrent(request(client));
    } finally {
      operation.detachTransport(client);
      client.close();
    }
  }

  _MediaCancelableOperation _beginOperation(_MediaAccessGuard access) {
    if (_closed) throw StateError('媒体服务已关闭');
    final operation = _MediaCancelableOperation();
    _allOperations.add(operation);
    if (access.groupGenerationKey case final key?) {
      (_groupOperations[key] ??= <_MediaCancelableOperation>{}).add(operation);
    }
    return operation;
  }

  void _finishOperation(
    _MediaAccessGuard access,
    _MediaCancelableOperation operation,
  ) {
    operation.finish();
    if (operation.hasDirtyFiles) return;
    _allOperations.remove(operation);
    if (access.groupGenerationKey case final key?) {
      final operations = _groupOperations[key];
      operations?.remove(operation);
      if (operations?.isEmpty ?? false) _groupOperations.remove(key);
    }
  }

  Future<void> _cleanupGroupGeneration(String scope, int generation) async {
    final key = '$scope:$generation';
    _resolved.removeWhere(
      (_, asset) =>
          asset.groupScope == scope && asset.groupGeneration == generation,
    );
    final operationCleanups = <Future<void>>[];
    for (final operation in List<_MediaCancelableOperation>.of(
      _groupOperations[key] ?? const <_MediaCancelableOperation>{},
    )) {
      operationCleanups.add(operation.cancelAndCleanup(_deleteWithRetry));
    }
    await Future.wait<void>(operationCleanups, eagerError: false);
    for (final operation in List<_MediaCancelableOperation>.of(
      _groupOperations[key] ?? const <_MediaCancelableOperation>{},
    )) {
      if (!operation.hasDirtyFiles) _allOperations.remove(operation);
    }

    final paths = _groupDownloadArtifacts[key];
    if (paths != null) {
      for (final path in List<String>.of(paths)) {
        await _deleteWithRetry(File(path));
        paths.remove(path);
      }
      if (paths.isEmpty) _groupDownloadArtifacts.remove(key);
    }
    _groupOperations.remove(key);
    if (_watchedGroupGenerations[scope] == generation) {
      _watchedGroupGenerations.remove(scope);
    }
  }

  Future<void> _deleteWithRetry(File file) async {
    Object? lastError;
    StackTrace? lastStackTrace;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        if (!await file.exists()) return;
        await _deleteFile(file);
        if (await file.exists()) {
          throw FileSystemException('媒体受控文件删除后仍存在', file.path);
        }
        return;
      } on Object catch (error, stackTrace) {
        lastError = error;
        lastStackTrace = stackTrace;
        if (attempt < 2) {
          await Future<void>.delayed(
            Duration(milliseconds: 10 * (attempt + 1)),
          );
        }
      }
    }
    Error.throwWithStackTrace(lastError!, lastStackTrace!);
  }

  static Future<void> _defaultDeleteFile(File file) async {
    await file.delete();
  }

  _MediaAccessGuard _captureAccess(
    AppSession session, {
    required int conversationType,
    required String conversationId,
    required bool requireActive,
    int? messageSeq,
  }) {
    if (conversationType == 1) {
      return _MediaAccessGuard.single(
        '${session.organization}:${session.user.userId}:single',
      );
    }
    if (conversationType != 2) {
      throw const FormatException('附件 conversation_type 无效');
    }
    final registry = GroupMemberAccessRegistry.lookup(
      session.organization,
      session.user.userId,
    );
    if (registry == null) throw StateError('群成员访问快照尚未初始化');
    final entry = requireActive
        ? registry.assertActive(conversationId)
        : registry.assertVisible(conversationId);
    if (messageSeq != null && !entry.containsMessageSequence(messageSeq)) {
      throw StateError('附件消息超出群访问周期');
    }
    final epoch = registry.captureEpoch();
    final scope = '${session.organization}:${session.user.userId}:group';
    _watchGroupAccess(scope, epoch);
    return _MediaAccessGuard.group(
      epoch: epoch,
      cachePrefix:
          '$scope:${epoch.generation}:${entry.accessVersion}:${entry.conversationId}',
      groupScope: scope,
      rememberArtifact: (path) {
        final key = '$scope:${epoch.generation}';
        (_groupDownloadArtifacts[key] ??= <String>{}).add(path);
      },
    );
  }

  void _watchGroupAccess(String scope, GroupMemberAccessEpoch epoch) {
    if (_watchedGroupGenerations[scope] == epoch.generation) return;
    _watchedGroupGenerations[scope] = epoch.generation;
    final generation = epoch.generation;
    epoch.registerInvalidationCleanup(
      () => _cleanupGroupGeneration(scope, generation),
    );
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final operation in List<_MediaCancelableOperation>.of(
      _allOperations,
    )) {
      unawaited(operation.cancelAndCleanup(_deleteWithRetry));
    }
  }
}

final class _ResolvedAsset {
  const _ResolvedAsset(
    this.url,
    this.expiresAt, {
    required this.groupScope,
    required this.groupGeneration,
  });

  final Uri url;
  final int expiresAt;
  final String? groupScope;
  final int? groupGeneration;
}

final class _MediaAccessGuard {
  const _MediaAccessGuard._({
    required this.epoch,
    required this.cachePrefix,
    required this.groupScope,
    required this.rememberArtifact,
  });

  factory _MediaAccessGuard.single(String cachePrefix) => _MediaAccessGuard._(
    epoch: null,
    cachePrefix: cachePrefix,
    groupScope: null,
    rememberArtifact: (_) {},
  );

  factory _MediaAccessGuard.group({
    required GroupMemberAccessEpoch epoch,
    required String cachePrefix,
    required String groupScope,
    required void Function(String path) rememberArtifact,
  }) => _MediaAccessGuard._(
    epoch: epoch,
    cachePrefix: cachePrefix,
    groupScope: groupScope,
    rememberArtifact: rememberArtifact,
  );

  final GroupMemberAccessEpoch? epoch;
  final String cachePrefix;
  final String? groupScope;
  final void Function(String path) rememberArtifact;

  bool get isGroup => epoch != null;
  int? get groupGeneration => epoch?.generation;
  String? get groupGenerationKey =>
      groupScope == null ? null : '$groupScope:${epoch!.generation}';

  void assertCurrent() => epoch?.assertCurrent();
}

final class _MediaCancelableOperation {
  final Completer<void> _cancelled = Completer<void>();
  final Set<http.Client> _transports = {};
  final Set<String> _paths = {};
  Future<void> _streamSettled = Future<void>.value();
  Future<void>? _cleanupTask;

  Future<void> get cancelled => _cancelled.future;
  bool get hasDirtyFiles => _paths.isNotEmpty;

  void attachTransport(http.Client client) {
    if (_cancelled.isCompleted) {
      client.close();
      throw StateError('群访问快照已变化，媒体 transport 已取消');
    }
    _transports.add(client);
  }

  void detachTransport(http.Client client) => _transports.remove(client);

  void trackPath(String path) => _paths.add(path);

  void untrackPath(String path) => _paths.remove(path);

  void trackStream(Future<void> settled) {
    _streamSettled = settled.then<void>((_) {}, onError: (_, _) {});
  }

  Future<T> waitCurrent<T>(Future<T> operation) => Future.any<T>([
    operation,
    cancelled.then<T>((_) => throw StateError('群访问快照已变化，媒体操作已取消')),
  ]);

  Future<void> cancelAndCleanup(Future<void> Function(File file) deleteFile) {
    for (final transport in List<http.Client>.of(_transports)) {
      transport.close();
    }
    _transports.clear();
    if (!_cancelled.isCompleted) _cancelled.complete();
    return cleanupFiles(deleteFile);
  }

  Future<void> cleanupFiles(Future<void> Function(File file) deleteFile) {
    final existing = _cleanupTask;
    if (existing != null) return existing;
    late final Future<void> cleanup;
    cleanup = () async {
      await _streamSettled;
      for (final path in List<String>.of(_paths)) {
        await deleteFile(File(path));
        _paths.remove(path);
      }
    }();
    _cleanupTask = cleanup;
    return cleanup.whenComplete(() {
      if (identical(_cleanupTask, cleanup) && _paths.isNotEmpty) {
        _cleanupTask = null;
      }
    });
  }

  void finish() {
    for (final transport in List<http.Client>.of(_transports)) {
      transport.close();
    }
    _transports.clear();
  }
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
