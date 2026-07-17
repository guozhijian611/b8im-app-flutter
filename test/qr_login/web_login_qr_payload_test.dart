import 'package:b8im_app_flutter/src/qr_login/web_login_qr_payload.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/tenant_fixture.dart';

const _qrId = '0123456789abcdef0123456789abcdef';
const _scanToken = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';

String _uri({
  String scheme = 'b8im',
  String host = 'web-login',
  String qrId = _qrId,
  String scanToken = _scanToken,
  String organization = '1',
  String deploymentId = 'b8im-test',
  String suffix = '',
}) =>
    '$scheme://$host?qr_id=$qrId&scan_token=$scanToken'
    '&organization=$organization&deployment_id=$deploymentId$suffix';

void main() {
  test('解析当前机构与部署的 Web 登录二维码', () {
    final payload = WebLoginQrPayload.parse(_uri(), tenantFixture());

    expect(payload.qrId, _qrId);
    expect(payload.scanToken, _scanToken);
    expect(payload.organization, 1);
    expect(payload.deploymentId, 'b8im-test');
  });

  test('拒绝错误 scheme、host、路径、额外参数和重复参数', () {
    final tenant = tenantFixture();
    final invalid = [
      _uri(scheme: 'https'),
      _uri(host: 'login'),
      _uri().replaceFirst('web-login?', 'web-login/path?'),
      _uri(suffix: '&unexpected=1'),
      _uri(suffix: '&qr_id=$_qrId'),
      '${_uri()}#fragment',
      ' ${_uri()}',
    ];

    for (final value in invalid) {
      expect(
        () => WebLoginQrPayload.parse(value, tenant),
        throwsFormatException,
        reason: value,
      );
    }
  });

  test('拒绝无效凭据、跨机构和跨部署二维码', () {
    final tenant = tenantFixture();
    final invalid = [
      _uri(qrId: 'short'),
      _uri(scanToken: 'not-a-token'),
      _uri(organization: '01'),
      _uri(organization: '2'),
      _uri(deploymentId: 'another-deployment'),
    ];

    for (final value in invalid) {
      expect(
        () => WebLoginQrPayload.parse(value, tenant),
        throwsFormatException,
        reason: value,
      );
    }
  });
}
