import '../discovery/tenant_config.dart';
import '../im/app_im_connection.dart';
import '../modules/client_module_registry.dart';
import 'app_session.dart';
import 'app_session_service.dart';

final class AppSessionBootstrapResult {
  const AppSessionBootstrapResult({
    required this.session,
    required this.modules,
    required this.im,
  });

  final AppSession session;
  final List<ResolvedClientModule> modules;
  final AppImRuntime im;
}

abstract interface class AppSessionBootstrapGateway {
  Future<AppSessionBootstrapResult> connect({
    required TenantConfig tenant,
    required String account,
    required String password,
    required String deviceId,
    required AppClientRuntime runtime,
  });
}

final class AppSessionBootstrapper implements AppSessionBootstrapGateway {
  AppSessionBootstrapper({
    required this.sessionService,
    required this.moduleRegistry,
    required this.imConnector,
  });

  final AppSessionService sessionService;
  final ClientModuleRegistry moduleRegistry;
  final AppImConnectorGateway imConnector;

  @override
  Future<AppSessionBootstrapResult> connect({
    required TenantConfig tenant,
    required String account,
    required String password,
    required String deviceId,
    required AppClientRuntime runtime,
  }) async {
    final session = await sessionService.login(
      tenant: tenant,
      account: account,
      password: password,
      deviceId: deviceId,
      runtime: runtime,
    );
    final clientConfig = await sessionService.fetchClientConfig(
      tenant: tenant,
      session: session,
    );
    final modules = moduleRegistry.resolve(
      payload: clientConfig,
      tenant: tenant,
    );
    final im = await imConnector.connect(tenant: tenant, session: session);

    return AppSessionBootstrapResult(
      session: session,
      modules: modules,
      im: im,
    );
  }
}
