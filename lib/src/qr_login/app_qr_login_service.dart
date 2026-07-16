import '../discovery/tenant_config.dart';
import '../network/app_api_client.dart';
import '../session/app_session.dart';
import 'web_login_qr_payload.dart';

final class WebLoginScanResult {
  const WebLoginScanResult({
    required this.qrId,
    required this.organizationName,
    required this.webOrigin,
    required this.browserDevice,
    required this.expiresAt,
  });

  final String qrId;
  final String organizationName;
  final Uri webOrigin;
  final String browserDevice;
  final DateTime expiresAt;
}

abstract interface class AppQrLoginGateway {
  Future<WebLoginScanResult> scan({
    required TenantConfig tenant,
    required AppSession session,
    required WebLoginQrPayload payload,
  });

  Future<void> confirm({
    required TenantConfig tenant,
    required AppSession session,
    required String qrId,
  });
}

final class AppQrLoginService implements AppQrLoginGateway {
  const AppQrLoginService(this._api, {this.now = DateTime.now});

  final AppApiClient _api;
  final DateTime Function() now;

  @override
  Future<WebLoginScanResult> scan({
    required TenantConfig tenant,
    required AppSession session,
    required WebLoginQrPayload payload,
  }) async {
    _validateContext(tenant, session);
    if (payload.organization != tenant.organization ||
        payload.deploymentId != tenant.deploymentId) {
      throw const FormatException('二维码与当前登录上下文不一致');
    }
    final response = _map(
      await _api.request(
        tenant,
        '/saimulti/app/im/qrLogin/scan',
        method: AppApiMethod.post,
        accessToken: session.accessToken,
        body: {'qr_id': payload.qrId, 'scan_token': payload.scanToken},
      ),
      'qr login scan',
    );
    if (_string(response, 'qr_id') != payload.qrId ||
        response['status'] != 'scanned' ||
        response['organization'] != tenant.organization) {
      throw const FormatException('扫码登录响应与二维码不一致');
    }
    final organizationName = _string(response, 'organization_name');
    final webOrigin = Uri.tryParse(_string(response, 'web_origin'));
    if (webOrigin == null ||
        webOrigin.scheme != 'https' ||
        webOrigin.host.isEmpty ||
        webOrigin.userInfo.isNotEmpty ||
        (webOrigin.path.isNotEmpty && webOrigin.path != '/') ||
        webOrigin.hasQuery ||
        webOrigin.hasFragment) {
      throw const FormatException('扫码登录响应 web_origin 无效');
    }
    final browserDevice = _string(response, 'browser_device');
    final expiresAtValue = response['expires_at'];
    if (expiresAtValue is! int || expiresAtValue <= 0) {
      throw const FormatException('扫码登录响应 expires_at 无效');
    }
    final expiresAt = DateTime.fromMillisecondsSinceEpoch(
      expiresAtValue * 1000,
      isUtc: true,
    );
    if (!expiresAt.isAfter(now().toUtc())) {
      throw const FormatException('Web 登录二维码已过期');
    }
    return WebLoginScanResult(
      qrId: payload.qrId,
      organizationName: organizationName,
      webOrigin: webOrigin,
      browserDevice: browserDevice,
      expiresAt: expiresAt,
    );
  }

  @override
  Future<void> confirm({
    required TenantConfig tenant,
    required AppSession session,
    required String qrId,
  }) async {
    _validateContext(tenant, session);
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(qrId)) {
      throw const FormatException('qr_id 格式无效');
    }
    final response = _map(
      await _api.request(
        tenant,
        '/saimulti/app/im/qrLogin/confirm',
        method: AppApiMethod.post,
        accessToken: session.accessToken,
        body: {'qr_id': qrId},
      ),
      'qr login confirm',
    );
    if (_string(response, 'qr_id') != qrId ||
        response['status'] != 'confirmed') {
      throw const FormatException('扫码登录确认响应无效');
    }
  }

  static void _validateContext(TenantConfig tenant, AppSession session) {
    if (session.organization != tenant.organization ||
        session.deploymentId != tenant.deploymentId ||
        session.accessToken.trim().isEmpty) {
      throw const FormatException('App 登录上下文无效');
    }
  }
}

Map<String, Object?> _map(Object? value, String field) {
  if (value is! Map) throw FormatException('$field 格式无效');
  return value.map((key, item) => MapEntry(key.toString(), item));
}

String _string(Map<String, Object?> value, String field) {
  final item = value[field];
  if (item is! String || item.trim().isEmpty) {
    throw FormatException('$field 格式无效');
  }
  return item.trim();
}
