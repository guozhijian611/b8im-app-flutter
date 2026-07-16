import 'package:b8im_app_flutter/src/modules/client_module_registry.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/tenant_fixture.dart';

void main() {
  final announcement = ClientModuleRegistration(
    moduleKey: 'announcement',
    title: '公告',
    capability: 'announcement.app.page',
    permission: 'saimulti:app:announcement:index',
    builder: (_, _, _) => const SizedBox.shrink(),
  );

  test('只解析 App 已内置且服务端授权的模块', () {
    final registry = ClientModuleRegistry([announcement]);
    final resolved = registry.resolve(
      tenant: tenantFixture(),
      payload: {
        'version': 1,
        'organization': 1,
        'deployment_id': 'b8im-test',
        'features': {'announcement': true, 'unknown': true},
        'modules': [
          {
            'module_key': 'announcement',
            'version': '0.1.0',
            'available': true,
            'capabilities': ['announcement.app.page'],
            'permissions': ['saimulti:app:announcement:index'],
            'config': <String, Object?>{},
          },
          {
            'module_key': 'unknown',
            'version': '1.0.0',
            'available': true,
            'capabilities': ['unknown.app.page'],
            'permissions': ['unknown'],
            'config': <String, Object?>{},
          },
        ],
        'tabbar': [
          {'module_key': 'announcement', 'title': '企业公告'},
        ],
      },
    );

    expect(resolved, hasLength(1));
    expect(resolved.single.registration.moduleKey, 'announcement');
    expect(resolved.single.title, '企业公告');
  });

  test('拒绝重复模块注册', () {
    expect(
      () => ClientModuleRegistry([announcement, announcement]),
      throwsArgumentError,
    );
  });
}
