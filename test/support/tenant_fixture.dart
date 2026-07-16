import 'package:b8im_app_flutter/src/discovery/tenant_config.dart';

Map<String, Object?> tenantDataFixture({
  String clientFamily = 'app',
  String deploymentId = 'b8im-test',
}) {
  return {
    'organization': 1,
    'deployment_id': deploymentId,
    'enterprise_code': 'org_1',
    'client_family': clientFamily,
    'config_version': 1,
    'updated_at': '2026-07-16T12:00:00+08:00',
    'site_name': 'b8im 测试机构',
    'logo': '',
    'server_info': {
      'schema_version': 2,
      'route_pool_id': 'org-1-test',
      'route_pool_version': 1,
      'routing_version': 1,
      'server_time': '2099-01-01T00:00:00Z',
      'issued_at': '2026-07-16T00:00:00Z',
      'expires_at': '2099-01-02T00:00:00Z',
      'stale_if_error_until': '2099-01-03T00:00:00Z',
      'policy': {
        'mode': 'single',
        'route_bundle_required': true,
        'failover_scope': 'service',
        'primary_route_id': 'test-primary',
        'backup_route_ids': <Object?>[],
        'switch_cooldown_seconds': 0,
        'connect_timeout_ms': 5000,
      },
      'routes': [
        {
          'route_id': 'test-primary',
          'route_version': 1,
          'name': '测试主线路',
          'priority': 10,
          'weight': 100,
          'region': 'test',
          'carrier': 'test',
          'deployment_id': deploymentId,
          'endpoints': {
            'api_server_url': 'https://api.idev.love',
            'im_server_url': 'wss://ws.idev.love',
            'upload_server_url': 'https://api.idev.love',
            'web_server_url': 'https://idev.love',
          },
        },
      ],
    },
  };
}

TenantConfig tenantFixture() => TenantConfig.fromJson(tenantDataFixture());
