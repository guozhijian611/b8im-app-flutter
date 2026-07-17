import 'package:b8im_file_media_module/b8im_file_media_module.dart';

import 'app_module_page.dart';
import 'client_module_registry.dart';

ClientModuleRegistry defaultAppModuleRegistry() => ClientModuleRegistry([
  _registration(
    'announcement',
    '公告',
    'announcement.app.page',
    'saimulti:app:announcement:index',
  ),
  _registration(
    'customer_service',
    '在线客服',
    'customer_service.app.page',
    'saimulti:app:customer_service:conversation',
  ),
  _registration(
    'favorite',
    '收藏',
    'favorite.app.page',
    'saimulti:app:favorite:index',
  ),
  ClientModuleRegistration(
    moduleKey: 'file_media',
    title: '文件媒体',
    capability: 'file_media.app.page',
    permission: 'saimulti:app:file_media:use',
    builder: (context, projection, moduleContext) => FileMediaModulePage(
      apiBaseUri: moduleContext.tenant.routing.primary.endpoints.apiServerUri,
      organization: moduleContext.tenant.organization,
      accessToken: moduleContext.session.accessToken,
      title: '文件媒体增强',
    ),
  ),
  _registration('i18n', '语言', 'i18n.app.page', 'saimulti:app:i18n:read'),
  _registration(
    'moments',
    '朋友圈',
    'moments.app.page',
    'saimulti:app:moments:use',
  ),
  _registration(
    'robot_single',
    '机器人助手',
    'robot_single.app.page',
    'saimulti:app:robot_single:use',
  ),
  _registration('search', '消息搜索', 'search.app.page', 'saimulti:app:search:use'),
  _registration(
    'sticker',
    '表情',
    'sticker.app.page',
    'saimulti:app:sticker:read',
  ),
]);

ClientModuleRegistration _registration(
  String moduleKey,
  String title,
  String capability,
  String permission,
) => ClientModuleRegistration(
  moduleKey: moduleKey,
  title: title,
  capability: capability,
  permission: permission,
  builder: (context, projection, moduleContext) => AppModulePage(
    moduleKey: moduleKey,
    title: title,
    moduleContext: moduleContext,
  ),
);
