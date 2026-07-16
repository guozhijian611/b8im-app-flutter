import 'routing_config.dart';

final class TenantConfig {
  const TenantConfig({
    required this.organization,
    required this.deploymentId,
    required this.enterpriseCode,
    required this.configVersion,
    required this.updatedAt,
    required this.siteName,
    required this.logoUri,
    required this.routing,
  });

  factory TenantConfig.fromJson(Map<String, Object?> value, {DateTime? now}) {
    final organization = value['organization'];
    final configVersion = value['config_version'];
    if (organization is! int || organization <= 0) {
      throw const FormatException('organization 格式无效');
    }
    if (configVersion is! int || configVersion <= 0) {
      throw const FormatException('config_version 格式无效');
    }
    if (value['client_family'] != 'app') {
      throw const FormatException('client_family 与 App 请求不一致');
    }
    final deploymentId = _string(value, 'deployment_id');
    if (!RegExp(r'^[a-z0-9][a-z0-9_-]{1,63}$').hasMatch(deploymentId)) {
      throw const FormatException('deployment_id 格式无效');
    }
    final enterpriseCode = _string(value, 'enterprise_code');
    if (!RegExp(r'^[a-z0-9][a-z0-9_-]{1,63}$').hasMatch(enterpriseCode)) {
      throw const FormatException('enterprise_code 格式无效');
    }
    final updatedAt = DateTime.tryParse(_string(value, 'updated_at'));
    if (updatedAt == null) throw const FormatException('updated_at 格式无效');
    final serverInfo = _map(value['server_info'], 'server_info');
    final logo = value['logo'];

    return TenantConfig(
      organization: organization,
      deploymentId: deploymentId,
      enterpriseCode: enterpriseCode,
      configVersion: configVersion,
      updatedAt: updatedAt.toUtc(),
      siteName: _string(value, 'site_name'),
      logoUri: logo is String && logo.trim().isNotEmpty
          ? _optionalHttpsUri(logo, 'logo')
          : null,
      routing: RoutingConfig.fromJson(
        serverInfo,
        deploymentId: deploymentId,
        now: now,
      ),
    );
  }

  final int organization;
  final String deploymentId;
  final String enterpriseCode;
  final int configVersion;
  final DateTime updatedAt;
  final String siteName;
  final Uri? logoUri;
  final RoutingConfig routing;

  static Map<String, Object?> signaturePayload(Map<String, Object?> value) => {
    'organization': value['organization'],
    'deployment_id': value['deployment_id'],
    'enterprise_code': value['enterprise_code'],
    'client_family': value['client_family'],
    'server_info': value['server_info'],
  };
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

Uri _optionalHttpsUri(String value, String field) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment) {
    throw FormatException('$field 必须是安全 HTTPS 地址');
  }
  return uri;
}
