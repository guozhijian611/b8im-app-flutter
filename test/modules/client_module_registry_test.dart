import 'package:b8im_app_flutter/src/modules/app_module_catalog.dart';
import 'package:b8im_app_flutter/src/modules/client_module_registry.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/tenant_fixture.dart';

Map<String, Object?> _payload({
  List<Map<String, Object?>> modules = const [],
  Map<String, Object?> features = const {},
  List<Map<String, Object?>> tabbar = const [],
  int organization = 1,
  String deploymentId = 'b8im-test',
}) {
  return {
    'version': 1,
    'organization': organization,
    'deployment_id': deploymentId,
    'features': features,
    'modules': modules,
    'tabbar': tabbar,
  };
}

Map<String, Object?> _module({
  required String moduleKey,
  required bool available,
  required List<String> capabilities,
  required List<String> permissions,
  String version = '0.2.0',
}) {
  return {
    'module_key': moduleKey,
    'version': version,
    'available': available,
    'capabilities': capabilities,
    'permissions': permissions,
    'config': <String, Object?>{},
  };
}

void main() {
  final announcement = ClientModuleRegistration(
    moduleKey: 'announcement',
    title: '公告',
    capability: 'announcement.app.page',
    permission: 'saimulti:app:announcement:index',
    builder: (_, _, _) => const SizedBox.shrink(),
  );

  test('默认注册表包含九个正式企业模块', () {
    expect(defaultAppModuleRegistry().moduleKeys, {
      'announcement',
      'customer_service',
      'favorite',
      'file_media',
      'i18n',
      'moments',
      'robot_single',
      'search',
      'sticker',
    });
  });

  test('只解析 App 已内置且服务端授权的模块', () {
    final registry = ClientModuleRegistry([announcement]);
    final resolved = registry.resolve(
      tenant: tenantFixture(),
      payload: _payload(
        features: {'announcement': true, 'unknown': true},
        modules: [
          _module(
            moduleKey: 'announcement',
            available: true,
            capabilities: ['announcement.app.page'],
            permissions: ['saimulti:app:announcement:index'],
          ),
          _module(
            moduleKey: 'unknown',
            available: true,
            capabilities: ['unknown.app.page'],
            permissions: ['unknown'],
          ),
        ],
        tabbar: [
          {'module_key': 'announcement', 'title': '企业公告'},
        ],
      ),
    );

    expect(resolved, hasLength(1));
    expect(resolved.single.registration.moduleKey, 'announcement');
    expect(resolved.single.title, '企业公告');
  });

  test('file_media 在投影授权完整时通过默认注册表解析', () {
    final registry = defaultAppModuleRegistry();
    final resolved = registry.resolve(
      tenant: tenantFixture(),
      payload: _payload(
        features: {'file_media': true},
        modules: [
          _module(
            moduleKey: 'file_media',
            available: true,
            capabilities: ['file_media.app.page'],
            permissions: ['saimulti:app:file_media:use'],
          ),
        ],
        tabbar: [
          {'module_key': 'file_media', 'title': '文件增强'},
        ],
      ),
    );

    expect(resolved, hasLength(1));
    expect(resolved.single.registration.moduleKey, 'file_media');
    expect(resolved.single.title, '文件增强');
    expect(resolved.single.projection.available, isTrue);
    expect(
      resolved.single.projection.capabilities,
      contains('file_media.app.page'),
    );
    expect(
      resolved.single.projection.permissions,
      contains('saimulti:app:file_media:use'),
    );
  });

  test('available=false 的模块不可打开', () {
    final registry = defaultAppModuleRegistry();
    final resolved = registry.resolve(
      tenant: tenantFixture(),
      payload: _payload(
        features: {'file_media': true},
        modules: [
          _module(
            moduleKey: 'file_media',
            available: false,
            capabilities: ['file_media.app.page'],
            permissions: ['saimulti:app:file_media:use'],
          ),
        ],
      ),
    );
    expect(resolved, isEmpty);
  });

  test('features 显式 false 时不可打开', () {
    final registry = defaultAppModuleRegistry();
    final resolved = registry.resolve(
      tenant: tenantFixture(),
      payload: _payload(
        features: {'file_media': false},
        modules: [
          _module(
            moduleKey: 'file_media',
            available: true,
            capabilities: ['file_media.app.page'],
            permissions: ['saimulti:app:file_media:use'],
          ),
        ],
      ),
    );
    expect(resolved, isEmpty);
  });

  test('缺少 capability 时不可打开', () {
    final registry = defaultAppModuleRegistry();
    final resolved = registry.resolve(
      tenant: tenantFixture(),
      payload: _payload(
        modules: [
          _module(
            moduleKey: 'file_media',
            available: true,
            capabilities: ['other.capability'],
            permissions: ['saimulti:app:file_media:use'],
          ),
        ],
      ),
    );
    expect(resolved, isEmpty);
  });

  test('缺少 permission 时不可打开', () {
    final registry = defaultAppModuleRegistry();
    final resolved = registry.resolve(
      tenant: tenantFixture(),
      payload: _payload(
        modules: [
          _module(
            moduleKey: 'file_media',
            available: true,
            capabilities: ['file_media.app.page'],
            permissions: ['saimulti:app:other:use'],
          ),
        ],
      ),
    );
    expect(resolved, isEmpty);
  });

  test('投影中不存在的模块不可打开（即使本地注册）', () {
    final registry = defaultAppModuleRegistry();
    final resolved = registry.resolve(
      tenant: tenantFixture(),
      payload: _payload(features: {'file_media': true}, modules: const []),
    );
    expect(resolved, isEmpty);
  });

  test('organization 不一致拒绝解析', () {
    final registry = defaultAppModuleRegistry();
    expect(
      () => registry.resolve(
        tenant: tenantFixture(),
        payload: _payload(
          organization: 99,
          modules: [
            _module(
              moduleKey: 'file_media',
              available: true,
              capabilities: ['file_media.app.page'],
              permissions: ['saimulti:app:file_media:use'],
            ),
          ],
        ),
      ),
      throwsFormatException,
    );
  });

  test('模块 config 为 null 或空列表时按空对象处理', () {
    final registry = defaultAppModuleRegistry();
    for (final config in [null, <Object?>[]]) {
      final resolved = registry.resolve(
        tenant: tenantFixture(),
        payload: {
          'version': 1,
          'organization': 1,
          'deployment_id': 'b8im-test',
          'features': {'file_media': true},
          'modules': [
            {
              'module_key': 'file_media',
              'version': '0.2.0',
              'available': true,
              'capabilities': ['file_media.app.page'],
              'permissions': ['saimulti:app:file_media:use'],
              'config': config,
            },
          ],
          'tabbar': [
            {'module_key': 'file_media', 'title': '文件媒体'},
          ],
        },
      );
      expect(resolved, hasLength(1));
      expect(resolved.single.projection.config, isEmpty);
    }
  });

  test('拒绝重复模块注册', () {
    expect(
      () => ClientModuleRegistry([announcement, announcement]),
      throwsArgumentError,
    );
  });
}
