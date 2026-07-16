import 'package:b8im_file_media_module/b8im_file_media_module.dart';

import 'client_module_registry.dart';

ClientModuleRegistry defaultAppModuleRegistry() => ClientModuleRegistry([
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
]);
