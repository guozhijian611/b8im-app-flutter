import 'dart:convert';
import 'dart:io';

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
    final api = AppApiClient(
      httpClient: MockClient((request) async {
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
      }),
    );
    final service = AppMediaService(
      api,
      downloadClient: MockClient((_) async {
        throw StateError('download should not run');
      }),
    );

    final upload = await service.upload(
      tenant: tenantFixture(),
      session: _session,
      kind: AppMediaKind.image,
      filePath: file.path,
      filename: 'photo.png',
      size: 4,
      mimeType: 'image/png',
    );
    final url = await service.resolve(
      tenant: tenantFixture(),
      session: _session,
      fileId: upload.fileId,
      conversationId: 'conversation-01',
      messageId: 'message-01',
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
    final api = AppApiClient(
      httpClient: MockClient(
        (request) async => http.Response(
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
        ),
      ),
    );
    final service = AppMediaService(
      api,
      downloadClient: MockClient((request) async {
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
      conversationId: 'conversation-01',
      messageId: 'message-02',
      filename: 'report.pdf',
    );

    expect(await File(path).readAsBytes(), [1, 2, 3, 4]);
    expect(path, contains('b8im_downloads'));
    service.close();
    api.close();
    await directory.delete(recursive: true);
  });
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
