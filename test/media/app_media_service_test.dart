import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:b8im_app_flutter/src/im/group_member_access.dart';
import 'package:b8im_app_flutter/src/media/app_media_service.dart';
import 'package:b8im_app_flutter/src/network/app_api_client.dart';
import 'package:b8im_app_flutter/src/session/app_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../support/tenant_fixture.dart';

void main() {
  test('App 图片执行 prepare、multipart upload 和私有地址解析', () async {
    final directory = await Directory.systemTemp.createTemp('b8im-media-test-');
    final file = File('${directory.path}/photo.png');
    await file.writeAsBytes([137, 80, 78, 71]);
    final paths = <String>[];
    Future<http.Response> handleApi(http.Request request) async {
      paths.add(request.url.path);
      expect(request.headers['app-id'], '1');
      expect(request.headers['authorization'], 'Bearer access-token');
      final data = switch (request.url.path) {
        '/saimulti/app/im/prepareUpload' => {
          'mode': 'proxy',
          'upload_path': '/saimulti/app/im/upload',
          'method': 'POST',
          'filename': 'photo.png',
          'size': 4,
          'mime_type': 'image/png',
          'extension': 'png',
        },
        '/saimulti/app/im/upload' => {
          'file_id': _aFileId,
          'kind': 'image',
          'name': 'photo.png',
          'size': 4,
          'mime_type': 'image/png',
          'extension': 'png',
        },
        '/saimulti/app/im/resolveAssetUrl' => {
          'file_id': _aFileId,
          'url': 'https://private.example.test/signed-photo',
          'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 300,
        },
        _ => throw StateError('unexpected path ${request.url.path}'),
      };
      return http.Response(
        jsonEncode({'code': 200, 'message': 'success', 'data': data}),
        200,
      );
    }

    final api = AppApiClient(
      httpClient: MockClient(handleApi),
      requestClientFactory: () => MockClient(handleApi),
    );
    final service = AppMediaService(
      api,
      downloadTransportFactory: () => MockClient((_) async {
        throw StateError('download should not run');
      }),
    );

    final upload = await service.upload(
      tenant: tenantFixture(),
      session: _session,
      kind: AppMediaKind.image,
      conversationType: 1,
      conversationId: 'conversation-01',
      filePath: file.path,
      filename: 'photo.png',
      size: 4,
      mimeType: 'image/png',
    );
    final url = await service.resolve(
      tenant: tenantFixture(),
      session: _session,
      fileId: upload.fileId,
      conversationType: 1,
      conversationId: 'conversation-01',
      messageId: 'message-01',
      messageSeq: 1,
    );

    expect(upload.kind, AppMediaKind.image);
    expect(url.toString(), 'https://private.example.test/signed-photo');
    expect(paths, [
      '/saimulti/app/im/prepareUpload',
      '/saimulti/app/im/upload',
      '/saimulti/app/im/resolveAssetUrl',
    ]);
    service.close();
    api.close();
    await directory.delete(recursive: true);
  });

  test('文件下载使用签名地址并流式写入 App 文档目录', () async {
    final directory = await Directory.systemTemp.createTemp(
      'b8im-download-test-',
    );
    Future<http.Response> handleResolve(http.Request request) async =>
        http.Response(
          jsonEncode({
            'code': 200,
            'message': 'success',
            'data': {
              'file_id': _bFileId,
              'url': 'https://private.example.test/signed-file',
              'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 300,
            },
          }),
          200,
        );
    final api = AppApiClient(
      httpClient: MockClient(handleResolve),
      requestClientFactory: () => MockClient(handleResolve),
    );
    final service = AppMediaService(
      api,
      downloadTransportFactory: () => MockClient((request) async {
        expect(
          request.url.toString(),
          'https://private.example.test/signed-file',
        );
        return http.Response.bytes([1, 2, 3, 4], 200);
      }),
      documentsDirectory: () async => directory,
    );

    final path = await service.download(
      tenant: tenantFixture(),
      session: _session,
      fileId: _bFileId,
      conversationType: 1,
      conversationId: 'conversation-01',
      messageId: 'message-02',
      messageSeq: 2,
      filename: 'report.pdf',
    );

    expect(await File(path).readAsBytes(), [1, 2, 3, 4]);
    expect(path, contains('b8im_downloads'));
    service.close();
    api.close();
    await directory.delete(recursive: true);
  });

  test('群缩权取消在途下载、清临时文件并使重加入不复用旧 URL', () async {
    final directory = await Directory.systemTemp.createTemp(
      'b8im-group-download-test-',
    );
    final registry =
        GroupMemberAccessRegistry(organization: 1, userId: 'user-01')..replace(
          GroupMemberAccessSnapshot(
            snapshotId: '1',
            entries: {'group-1': _groupEntry('1')},
          ),
        );
    var resolveCount = 0;
    Future<http.Response> handleResolve(http.Request request) async {
      resolveCount += 1;
      return http.Response(
        jsonEncode({
          'code': 200,
          'message': 'success',
          'data': {
            'file_id': _bFileId,
            'url': 'https://private.example.test/signed-$resolveCount',
            'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 300,
          },
        }),
        200,
      );
    }

    final api = AppApiClient(
      httpClient: MockClient(handleResolve),
      requestClientFactory: () => MockClient(handleResolve),
    );
    final downloadClient = _ControlledDownloadClient();
    final service = AppMediaService(
      api,
      downloadTransportFactory: () => downloadClient,
      documentsDirectory: () async => directory,
    );

    final pending = service.download(
      tenant: tenantFixture(),
      session: _session,
      fileId: _bFileId,
      conversationType: 2,
      conversationId: 'group-1',
      messageId: 'message-02',
      messageSeq: 2,
      filename: 'secret.pdf',
    );
    await downloadClient.started.future;
    downloadClient.bytes.add([1, 2]);
    registry.failClose();
    await expectLater(pending, throwsStateError);
    expect(downloadClient.closeCalled, isTrue);
    expect(directory.listSync(recursive: true).whereType<File>(), isEmpty);

    await registry.replace(
      GroupMemberAccessSnapshot(
        snapshotId: '2',
        entries: {'group-1': _groupEntry('2')},
      ),
    );
    final refreshed = await service.resolve(
      tenant: tenantFixture(),
      session: _session,
      fileId: _bFileId,
      conversationType: 2,
      conversationId: 'group-1',
      messageId: 'message-02',
      messageSeq: 2,
    );
    expect(refreshed.toString(), endsWith('signed-2'));
    expect(resolveCount, 2);

    service.close();
    api.close();
    await directory.delete(recursive: true);
  });

  test('群访问代完成的下载产物在缩权后删除且重加入不恢复', () async {
    final directory = await Directory.systemTemp.createTemp(
      'b8im-group-artifact-test-',
    );
    final registry =
        GroupMemberAccessRegistry(organization: 1, userId: 'user-01')..replace(
          GroupMemberAccessSnapshot(
            snapshotId: '10',
            entries: {'group-1': _groupEntry('10')},
          ),
        );
    Future<http.Response> handleResolve(http.Request request) async =>
        http.Response(
          jsonEncode({
            'code': 200,
            'message': 'success',
            'data': {
              'file_id': _bFileId,
              'url': 'https://private.example.test/group-artifact',
              'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 300,
            },
          }),
          200,
        );
    final api = AppApiClient(
      httpClient: MockClient(handleResolve),
      requestClientFactory: () => MockClient(handleResolve),
    );
    var deleteAttempts = 0;
    final service = AppMediaService(
      api,
      downloadTransportFactory: () =>
          MockClient((_) async => http.Response.bytes([7, 8], 200)),
      documentsDirectory: () async => directory,
      deleteFile: (file) async {
        deleteAttempts += 1;
        if (deleteAttempts < 3) {
          throw FileSystemException('injected delete failure', file.path);
        }
        await file.delete();
      },
    );

    final path = await service.download(
      tenant: tenantFixture(),
      session: _session,
      fileId: _bFileId,
      conversationType: 2,
      conversationId: 'group-1',
      messageId: 'message-10',
      messageSeq: 2,
      filename: 'authorized.bin',
    );
    expect(await File(path).exists(), isTrue);

    registry.failClose();
    final replacement = registry.replace(
      GroupMemberAccessSnapshot(
        snapshotId: '11',
        entries: {'group-1': _groupEntry('11')},
      ),
    );
    expect(registry.isReady, isFalse);
    await replacement;
    expect(deleteAttempts, 3);
    expect(await File(path).exists(), isFalse);

    service.close();
    api.close();
    await directory.delete(recursive: true);
  });

  test('普通下载清理失败保留 dirty ledger 并由后续 replacement 重试', () async {
    final directory = await Directory.systemTemp.createTemp(
      'b8im-dirty-download-test-',
    );
    final registry =
        GroupMemberAccessRegistry(organization: 1, userId: 'user-01')..replace(
          GroupMemberAccessSnapshot(
            snapshotId: '15',
            entries: {'group-1': _groupEntry('15')},
          ),
        );
    Future<http.Response> handleResolve(http.Request request) async =>
        http.Response(
          jsonEncode({
            'code': 200,
            'message': 'success',
            'data': {
              'file_id': _bFileId,
              'url': 'https://private.example.test/dirty-download',
              'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 300,
            },
          }),
          200,
        );
    final api = AppApiClient(
      httpClient: MockClient(handleResolve),
      requestClientFactory: () => MockClient(handleResolve),
    );
    var allowDelete = false;
    var deleteAttempts = 0;
    final service = AppMediaService(
      api,
      downloadTransportFactory: _FailingDownloadClient.new,
      documentsDirectory: () async => directory,
      deleteFile: (file) async {
        deleteAttempts += 1;
        if (!allowDelete) {
          throw FileSystemException(
            'injected persistent delete failure',
            file.path,
          );
        }
        await file.delete();
      },
    );

    await expectLater(
      service.download(
        tenant: tenantFixture(),
        session: _session,
        fileId: _bFileId,
        conversationType: 2,
        conversationId: 'group-1',
        messageId: 'message-15',
        messageSeq: 2,
        filename: 'dirty.bin',
      ),
      throwsA(isA<FileSystemException>()),
    );
    final dirtyFiles = directory
        .listSync(recursive: true)
        .whereType<File>()
        .toList(growable: false);
    expect(dirtyFiles, isNotEmpty);
    expect(deleteAttempts, 3);

    await expectLater(
      registry.replace(
        GroupMemberAccessSnapshot(
          snapshotId: '16',
          entries: {'group-1': _groupEntry('16')},
        ),
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(registry.isReady, isFalse);
    expect(deleteAttempts, 6);
    expect(dirtyFiles.any((file) => file.existsSync()), isTrue);

    allowDelete = true;
    await registry.replace(
      GroupMemberAccessSnapshot(
        snapshotId: '16',
        entries: {'group-1': _groupEntry('16')},
      ),
    );
    expect(registry.isReady, isTrue);
    expect(directory.listSync(recursive: true).whereType<File>(), isEmpty);

    service.close();
    api.close();
    await directory.delete(recursive: true);
  });

  test('群上传在访问 epoch 失效时立即取消结果', () async {
    final directory = await Directory.systemTemp.createTemp(
      'b8im-group-upload-cancel-test-',
    );
    final file = File(directory.uri.resolve('secret.bin').toFilePath());
    await file.writeAsBytes([1, 2, 3]);
    final registry =
        GroupMemberAccessRegistry(organization: 1, userId: 'user-01')..replace(
          GroupMemberAccessSnapshot(
            snapshotId: '20',
            entries: {'group-1': _groupEntry('20')},
          ),
        );
    final uploadTransport = _ControlledRequestClient();
    var transportCount = 0;
    http.Client createApiTransport() {
      transportCount += 1;
      if (transportCount == 1) {
        return MockClient(
          (request) async => http.Response(
            jsonEncode({
              'code': 200,
              'message': 'success',
              'data': {
                'mode': 'proxy',
                'upload_path': '/saimulti/app/im/upload',
                'method': 'POST',
              },
            }),
            200,
          ),
        );
      }
      return uploadTransport;
    }

    final api = AppApiClient(
      httpClient: MockClient((_) async => throw StateError('shared transport')),
    );
    final service = AppMediaService(
      api,
      apiTransportFactory: createApiTransport,
      downloadTransportFactory: () =>
          MockClient((_) async => http.Response('', 500)),
    );

    final pending = service.upload(
      tenant: tenantFixture(),
      session: _session,
      kind: AppMediaKind.file,
      conversationType: 2,
      conversationId: 'group-1',
      filePath: file.path,
      filename: 'secret.bin',
      size: 3,
      mimeType: 'application/octet-stream',
    );
    await uploadTransport.started.future;
    registry.failClose();
    await expectLater(pending, throwsStateError);
    expect(uploadTransport.closeCalled, isTrue);
    expect(
      uploadTransport.respond(
        http.Response(
          jsonEncode({
            'code': 200,
            'message': 'success',
            'data': {
              'file_id': _bFileId,
              'kind': 'file',
              'name': 'secret.bin',
              'size': 3,
              'mime_type': 'application/octet-stream',
              'extension': 'bin',
            },
          }),
          200,
        ),
      ),
      isFalse,
    );
    await registry.replace(
      GroupMemberAccessSnapshot(
        snapshotId: '21',
        entries: {'group-1': _groupEntry('21')},
      ),
    );
    expect(registry.isReady, isTrue);
    service.close();
    api.close();
    await directory.delete(recursive: true);
  });

  test('群私有地址解析在撤权时关闭请求 transport 并拒绝迟到响应', () async {
    final registry =
        GroupMemberAccessRegistry(organization: 1, userId: 'user-01')..replace(
          GroupMemberAccessSnapshot(
            snapshotId: '30',
            entries: {'group-1': _groupEntry('30')},
          ),
        );
    final resolveTransport = _ControlledRequestClient();
    final api = AppApiClient(
      httpClient: MockClient((_) async => throw StateError('shared transport')),
    );
    final service = AppMediaService(
      api,
      apiTransportFactory: () => resolveTransport,
      downloadTransportFactory: () =>
          MockClient((_) async => http.Response('', 500)),
    );

    final pending = service.resolve(
      tenant: tenantFixture(),
      session: _session,
      fileId: _bFileId,
      conversationType: 2,
      conversationId: 'group-1',
      messageId: 'message-30',
      messageSeq: 2,
    );
    await resolveTransport.started.future;
    registry.failClose();

    await expectLater(pending, throwsStateError);
    expect(resolveTransport.closeCalled, isTrue);
    expect(
      resolveTransport.respond(
        http.Response(
          jsonEncode({
            'code': 200,
            'message': 'success',
            'data': {
              'file_id': _bFileId,
              'url': 'https://private.example.test/late-url',
              'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 300,
            },
          }),
          200,
        ),
      ),
      isFalse,
    );
    await registry.replace(
      GroupMemberAccessSnapshot(
        snapshotId: '31',
        entries: {'group-1': _groupEntry('31')},
      ),
    );
    service.close();
    api.close();
  });
}

GroupMemberAccessEntry _groupEntry(String version) =>
    GroupMemberAccessEntry.fromJson({
      'conversation_id': 'group-1',
      'conversation_type': 2,
      'access_version': version,
      'access_state': 'active',
      'last_message_seq': '10',
      'last_change_seq': '1',
      'periods': [
        {'period_no': '1', 'from_seq': '1', 'to_seq': null},
      ],
    });

final class _ControlledDownloadClient extends http.BaseClient {
  final Completer<void> started = Completer<void>();
  final StreamController<List<int>> bytes = StreamController<List<int>>();
  bool closeCalled = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (!started.isCompleted) started.complete();
    return http.StreamedResponse(bytes.stream, 200);
  }

  @override
  void close() {
    if (closeCalled) return;
    closeCalled = true;
    if (!bytes.isClosed) {
      bytes.addError(StateError('download transport cancelled'));
      unawaited(bytes.close());
    }
  }
}

final class _ControlledRequestClient extends http.BaseClient {
  final Completer<void> started = Completer<void>();
  final Completer<http.StreamedResponse> _response = Completer();
  bool closeCalled = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (!started.isCompleted) started.complete();
    return _response.future;
  }

  bool respond(http.Response response) {
    if (_response.isCompleted || closeCalled) return false;
    _response.complete(
      http.StreamedResponse(
        Stream<List<int>>.value(response.bodyBytes),
        response.statusCode,
        headers: response.headers,
      ),
    );
    return true;
  }

  @override
  void close() {
    if (closeCalled) return;
    closeCalled = true;
    if (!_response.isCompleted) {
      _response.completeError(StateError('request transport cancelled'));
    }
  }
}

final class _FailingDownloadClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final bytes = StreamController<List<int>>();
    scheduleMicrotask(() {
      bytes.add([1, 2, 3]);
      bytes.addError(StateError('injected stream failure'));
      unawaited(bytes.close());
    });
    return http.StreamedResponse(bytes.stream, 200);
  }
}

const _session = AppSession(
  accessToken: 'access-token',
  expireAt: 4102444800,
  organization: 1,
  deploymentId: 'b8im-test',
  deviceId: 'device-01',
  runtime: AppClientRuntime(os: 'ios'),
  user: AppUser(
    id: '9',
    userId: 'user-01',
    account: 'acceptance',
    nickname: '验收用户',
  ),
);

const _aFileId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _bFileId = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
