import '../discovery/tenant_config.dart';

final class WebLoginQrPayload {
  const WebLoginQrPayload({
    required this.qrId,
    required this.scanToken,
    required this.organization,
    required this.deploymentId,
  });

  factory WebLoginQrPayload.parse(String rawValue, TenantConfig tenant) {
    if (rawValue.isEmpty ||
        rawValue.length > 2048 ||
        rawValue != rawValue.trim() ||
        !rawValue.startsWith('b8im://web-login?')) {
      throw const FormatException('不是有效的 b8im Web 登录二维码');
    }
    final uri = Uri.tryParse(rawValue);
    if (uri == null ||
        uri.scheme != 'b8im' ||
        uri.host != 'web-login' ||
        uri.path.isNotEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        uri.hasFragment) {
      throw const FormatException('Web 登录二维码地址无效');
    }

    const expectedFields = {
      'qr_id',
      'scan_token',
      'organization',
      'deployment_id',
    };
    final values = uri.queryParametersAll;
    if (values.keys.toSet().difference(expectedFields).isNotEmpty ||
        expectedFields.difference(values.keys.toSet()).isNotEmpty ||
        values.values.any((items) => items.length != 1)) {
      throw const FormatException('Web 登录二维码参数无效');
    }

    final qrId = values['qr_id']!.single;
    final scanToken = values['scan_token']!.single;
    final organizationValue = values['organization']!.single;
    final deploymentId = values['deployment_id']!.single;
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(qrId) ||
        !RegExp(r'^[A-Za-z0-9_-]{32,128}$').hasMatch(scanToken)) {
      throw const FormatException('Web 登录二维码凭据格式无效');
    }
    final organization = int.tryParse(organizationValue);
    if (organization == null || organizationValue != '$organization') {
      throw const FormatException('Web 登录二维码 organization 无效');
    }
    if (organization != tenant.organization) {
      throw const FormatException('不能登录其他机构的 Web 站点');
    }
    if (deploymentId != tenant.deploymentId) {
      throw const FormatException('不能登录其他部署的 Web 站点');
    }

    return WebLoginQrPayload(
      qrId: qrId,
      scanToken: scanToken,
      organization: organization,
      deploymentId: deploymentId,
    );
  }

  final String qrId;
  final String scanToken;
  final int organization;
  final String deploymentId;
}
