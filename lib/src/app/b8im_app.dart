import 'dart:async';

import 'package:b8im_file_media_module/b8im_file_media_module.dart';
import 'package:flutter/material.dart';

import '../contacts/app_contact_service.dart';
import '../config/app_environment.dart';
import '../discovery/tenant_config.dart';
import '../discovery/tenant_discovery_client.dart';
import '../im/app_im_connection.dart';
import '../im/web_socket_im_socket.dart';
import '../messaging/app_messaging_service.dart';
import '../media/app_media_picker.dart';
import '../media/app_media_service.dart';
import '../modules/app_module_catalog.dart';
import '../modules/client_module_registry.dart';
import '../network/app_api_client.dart';
import '../security/routing_signature_verifier.dart';
import '../session/app_session.dart';
import '../session/app_session_bootstrapper.dart';
import '../session/app_session_service.dart';
import '../storage/device_identity_store.dart';
import '../storage/im_sync_cursor_store.dart';
import 'app_home_shell.dart';
import 'app_theme.dart';

final class B8imApp extends StatefulWidget {
  const B8imApp({
    super.key,
    this.environment,
    this.discoveryGateway,
    this.deviceIdLoader,
    this.moduleRegistry,
    this.sessionBootstrapGateway,
    this.messagingGateway,
    this.contactGateway,
    this.mediaGateway,
    this.mediaPicker,
    this.runtime,
  });

  final AppEnvironment? environment;
  final TenantDiscoveryGateway? discoveryGateway;
  final Future<String> Function()? deviceIdLoader;
  final ClientModuleRegistry? moduleRegistry;
  final AppSessionBootstrapGateway? sessionBootstrapGateway;
  final AppMessagingGateway? messagingGateway;
  final AppContactGateway? contactGateway;
  final AppMediaGateway? mediaGateway;
  final AppMediaPickerGateway? mediaPicker;
  final AppClientRuntime? runtime;

  @override
  State<B8imApp> createState() => _B8imAppState();
}

final class _B8imAppState extends State<B8imApp> {
  late final AppEnvironment _environment;
  late final TenantDiscoveryGateway _discoveryGateway;
  late final Future<String> Function() _deviceIdLoader;
  late final ClientModuleRegistry _moduleRegistry;
  late final AppSessionBootstrapGateway _sessionBootstrapGateway;
  late final AppMessagingGateway _messagingGateway;
  late final AppContactGateway _contactGateway;
  late final AppMediaGateway _mediaGateway;
  late final AppMediaPickerGateway _mediaPicker;
  late final AppClientRuntime _runtime;
  TenantDiscoveryClient? _ownedDiscoveryClient;
  AppApiClient? _ownedApiClient;
  AppMediaService? _ownedMediaService;

  @override
  void initState() {
    super.initState();
    _environment = widget.environment ?? AppEnvironment.fromCompileTime();
    if (widget.discoveryGateway case final gateway?) {
      _discoveryGateway = gateway;
    } else {
      final client = TenantDiscoveryClient(
        discoveryBaseUri: _environment.discoveryBaseUri,
        signatureVerifier: RoutingSignatureVerifier(
          _environment.routingPublicKeys,
        ),
      );
      _ownedDiscoveryClient = client;
      _discoveryGateway = client;
    }
    _deviceIdLoader =
        widget.deviceIdLoader ?? DeviceIdentityStore().loadOrCreate;
    _moduleRegistry = widget.moduleRegistry ?? defaultAppModuleRegistry();
    _runtime = widget.runtime ?? AppClientRuntime.current();
    AppApiClient? apiClient;
    if (widget.sessionBootstrapGateway == null ||
        widget.messagingGateway == null ||
        widget.contactGateway == null ||
        widget.mediaGateway == null) {
      apiClient = AppApiClient();
      _ownedApiClient = apiClient;
    }
    if (widget.sessionBootstrapGateway case final gateway?) {
      _sessionBootstrapGateway = gateway;
    } else {
      final sessionService = AppSessionService(apiClient!);
      _sessionBootstrapGateway = AppSessionBootstrapper(
        sessionService: sessionService,
        moduleRegistry: _moduleRegistry,
        imConnector: AppImConnector(
          sessionService: sessionService,
          cursorStore: ImSyncCursorStore(),
          socketFactory: WebSocketImSocket.connect,
        ),
      );
    }
    _messagingGateway =
        widget.messagingGateway ?? AppMessagingService(apiClient!);
    _contactGateway = widget.contactGateway ?? AppContactService(apiClient!);
    if (widget.mediaGateway case final gateway?) {
      _mediaGateway = gateway;
    } else {
      final service = AppMediaService(apiClient!);
      _ownedMediaService = service;
      _mediaGateway = service;
    }
    _mediaPicker = widget.mediaPicker ?? DeviceAppMediaPicker();
  }

  @override
  void dispose() {
    _ownedDiscoveryClient?.close();
    _ownedApiClient?.close();
    _ownedMediaService?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'b8im',
      debugShowCheckedModeBanner: false,
      theme: B8Theme.light(),
      home: BootstrapPage(
        environment: _environment,
        discoveryGateway: _discoveryGateway,
        deviceIdLoader: _deviceIdLoader,
        moduleRegistry: _moduleRegistry,
        sessionBootstrapGateway: _sessionBootstrapGateway,
        messagingGateway: _messagingGateway,
        contactGateway: _contactGateway,
        mediaGateway: _mediaGateway,
        mediaPicker: _mediaPicker,
        runtime: _runtime,
      ),
    );
  }
}

final class BootstrapPage extends StatefulWidget {
  const BootstrapPage({
    super.key,
    required this.environment,
    required this.discoveryGateway,
    required this.deviceIdLoader,
    required this.moduleRegistry,
    required this.sessionBootstrapGateway,
    required this.messagingGateway,
    required this.contactGateway,
    required this.mediaGateway,
    required this.mediaPicker,
    required this.runtime,
  });

  final AppEnvironment environment;
  final TenantDiscoveryGateway discoveryGateway;
  final Future<String> Function() deviceIdLoader;
  final ClientModuleRegistry moduleRegistry;
  final AppSessionBootstrapGateway sessionBootstrapGateway;
  final AppMessagingGateway messagingGateway;
  final AppContactGateway contactGateway;
  final AppMediaGateway mediaGateway;
  final AppMediaPickerGateway mediaPicker;
  final AppClientRuntime runtime;

  @override
  State<BootstrapPage> createState() => _BootstrapPageState();
}

final class _BootstrapPageState extends State<BootstrapPage> {
  late final TextEditingController _enterpriseCodeController;
  late final TextEditingController _accountController;
  late final TextEditingController _passwordController;
  String? _deviceId;
  TenantConfig? _tenant;
  AppSessionBootstrapResult? _sessionResult;
  String? _error;
  String? _sessionError;
  bool _loading = false;
  bool _sessionLoading = false;

  @override
  void initState() {
    super.initState();
    _enterpriseCodeController = TextEditingController(
      text: widget.environment.initialEnterpriseCode,
    );
    _accountController = TextEditingController();
    _passwordController = TextEditingController();
    widget.deviceIdLoader().then((value) {
      if (mounted) setState(() => _deviceId = value);
    });
  }

  @override
  void dispose() {
    unawaited(_sessionResult?.im.close());
    _enterpriseCodeController.dispose();
    _accountController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _discover() async {
    FocusScope.of(context).unfocus();
    final previous = _sessionResult;
    setState(() {
      _loading = true;
      _error = null;
      _tenant = null;
      _sessionResult = null;
      _sessionError = null;
    });
    if (previous != null) await previous.im.close();
    try {
      final tenant = await widget.discoveryGateway.discoverByEnterpriseCode(
        _enterpriseCodeController.text,
        deviceId: _deviceId,
      );
      if (mounted) setState(() => _tenant = tenant);
    } on Object catch (error) {
      if (mounted) setState(() => _error = _discoveryError(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _connectSession() async {
    final tenant = _tenant;
    final deviceId = _deviceId;
    if (tenant == null || deviceId == null || deviceId.isEmpty) {
      setState(() => _sessionError = '设备标识尚未就绪，请稍后重试');
      return;
    }
    final account = _accountController.text.trim();
    final password = _passwordController.text;
    if (account.isEmpty || password.isEmpty) {
      setState(() => _sessionError = '请输入账号和密码');
      return;
    }

    FocusScope.of(context).unfocus();
    final previous = _sessionResult;
    setState(() {
      _sessionLoading = true;
      _sessionError = null;
      _sessionResult = null;
    });
    if (previous != null) await previous.im.close();
    try {
      final result = await widget.sessionBootstrapGateway.connect(
        tenant: tenant,
        account: account,
        password: password,
        deviceId: deviceId,
        runtime: widget.runtime,
      );
      _passwordController.clear();
      if (mounted) {
        setState(() => _sessionResult = result);
        await _openAppHome();
      }
    } on Object catch (error) {
      if (mounted) setState(() => _sessionError = _loginError(error));
    } finally {
      if (mounted) setState(() => _sessionLoading = false);
    }
  }

  Future<void> _openAppHome() async {
    final tenant = _tenant;
    final result = _sessionResult;
    if (tenant == null || result == null) return;
    final fileMediaEnabled = result.modules.any(
      (module) => module.registration.moduleKey == 'file_media',
    );
    final preflightClient = fileMediaEnabled
        ? FileMediaModuleClient(
            apiBaseUri: tenant.routing.primary.endpoints.apiServerUri,
            organization: tenant.organization,
            accessToken: result.session.accessToken,
          )
        : null;
    try {
      final logout = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          settings: const RouteSettings(name: 'app-home'),
          builder: (shellContext) => AppHomeShell(
            tenant: tenant,
            session: result.session,
            im: result.im,
            modules: result.modules,
            messaging: widget.messagingGateway,
            contacts: widget.contactGateway,
            media: widget.mediaGateway,
            mediaPicker: widget.mediaPicker,
            beforeMediaUpload: preflightClient == null
                ? null
                : (size) async {
                    final check = await preflightClient.checkUpload(size);
                    if (!check.allowed) {
                      throw FileMediaModuleException(check.reason);
                    }
                  },
            onLogout: () async {
              final navigator = Navigator.of(shellContext);
              navigator.popUntil((route) => route.settings.name == 'app-home');
              navigator.pop(true);
            },
          ),
        ),
      );
      if (logout == true) {
        await result.im.close();
        if (mounted) {
          setState(() {
            _sessionResult = null;
            _sessionError = null;
          });
        }
      }
    } finally {
      preflightClient?.close();
    }
  }

  Future<void> _switchTenant() async {
    final previous = _sessionResult;
    setState(() {
      _tenant = null;
      _sessionResult = null;
      _sessionError = null;
      _error = null;
    });
    _passwordController.clear();
    if (previous != null) await previous.im.close();
  }

  String _discoveryError(Object error) {
    if (error is TenantDiscoveryException) return error.message;
    if (error is StateError) {
      return '客户端安全配置异常，请更新 App 后重试';
    }
    if (error is FormatException) {
      return '企业信息校验失败，请确认企业码或联系管理员';
    }
    return '暂时无法连接，请检查网络后重试';
  }

  String _loginError(Object error) {
    if (error is AppApiException &&
        (error.statusCode == 400 ||
            error.statusCode == 401 ||
            error.statusCode == 403 ||
            error.statusCode == 422)) {
      return error.message;
    }
    if (error is AppImConnectionException) {
      return '消息服务连接失败，请稍后重试';
    }
    return '登录失败，请检查账号、密码或网络后重试';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          child: _tenant == null
              ? _WorkspaceEntry(
                  key: const ValueKey('workspace-entry'),
                  controller: _enterpriseCodeController,
                  loading: _loading,
                  error: _error,
                  onContinue: _discover,
                )
              : _LoginCard(
                  key: ValueKey('login-${_tenant!.organization}'),
                  tenant: _tenant!,
                  accountController: _accountController,
                  passwordController: _passwordController,
                  loading: _sessionLoading,
                  error: _sessionError,
                  onLogin: _connectSession,
                  onSwitchTenant: _switchTenant,
                ),
        ),
      ),
    );
  }
}

final class _WorkspaceEntry extends StatelessWidget {
  const _WorkspaceEntry({
    super.key,
    required this.controller,
    required this.loading,
    required this.error,
    required this.onContinue,
  });

  final TextEditingController controller;
  final bool loading;
  final String? error;
  final Future<void> Function() onContinue;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: IntrinsicHeight(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 56),
                const Align(child: _BrandMark()),
                const SizedBox(height: 34),
                Text(
                  '欢迎使用 B8 IM',
                  textAlign: TextAlign.center,
                  style: textTheme.headlineMedium?.copyWith(
                    color: B8Colors.text,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.6,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  '请输入企业码，连接到您的企业',
                  textAlign: TextAlign.center,
                  style: textTheme.bodyLarge?.copyWith(
                    color: B8Colors.muted,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 34),
                TextField(
                  key: const ValueKey('enterprise-code'),
                  controller: controller,
                  autocorrect: false,
                  enableSuggestions: false,
                  textCapitalization: TextCapitalization.none,
                  textInputAction: TextInputAction.done,
                  decoration: const InputDecoration(
                    labelText: '企业码',
                    hintText: '请输入企业码',
                    prefixIcon: Icon(Icons.business_outlined),
                  ),
                  onSubmitted: (_) => loading ? null : onContinue(),
                ),
                if (error case final message?) ...[
                  const SizedBox(height: 14),
                  _InlineError(message: message),
                ],
                const SizedBox(height: 18),
                FilledButton(
                  key: const ValueKey('discover-button'),
                  onPressed: loading ? null : onContinue,
                  child: loading
                      ? const _ButtonProgress(label: '正在连接…')
                      : const Text('继续'),
                ),
                const Spacer(),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 28),
                  child: Text(
                    '不知道企业码？请联系你的企业管理员',
                    textAlign: TextAlign.center,
                    style: textTheme.bodySmall?.copyWith(color: B8Colors.muted),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _LoginCard extends StatefulWidget {
  const _LoginCard({
    super.key,
    required this.tenant,
    required this.accountController,
    required this.passwordController,
    required this.loading,
    required this.error,
    required this.onLogin,
    required this.onSwitchTenant,
  });

  final TenantConfig tenant;
  final TextEditingController accountController;
  final TextEditingController passwordController;
  final bool loading;
  final String? error;
  final Future<void> Function() onLogin;
  final Future<void> Function() onSwitchTenant;

  @override
  State<_LoginCard> createState() => _LoginCardState();
}

final class _LoginCardState extends State<_LoginCard> {
  bool _obscurePassword = true;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: IntrinsicHeight(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 18),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const ValueKey('switch-tenant'),
                    onPressed: widget.loading ? null : widget.onSwitchTenant,
                    icon: const Icon(Icons.arrow_back_rounded, size: 20),
                    label: const Text('切换企业'),
                  ),
                ),
                const SizedBox(height: 36),
                Align(child: _TenantLogo(tenant: widget.tenant, size: 76)),
                const SizedBox(height: 20),
                Text(
                  widget.tenant.siteName,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.headlineSmall?.copyWith(
                    color: B8Colors.text,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.3,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '登录企业账号',
                  textAlign: TextAlign.center,
                  style: textTheme.bodyLarge?.copyWith(color: B8Colors.muted),
                ),
                const SizedBox(height: 36),
                TextField(
                  key: const ValueKey('login-account'),
                  controller: widget.accountController,
                  autocorrect: false,
                  enableSuggestions: false,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: '账号',
                    hintText: '请输入账号',
                    prefixIcon: Icon(Icons.person_outline_rounded),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  key: const ValueKey('login-password'),
                  controller: widget.passwordController,
                  obscureText: _obscurePassword,
                  enableSuggestions: false,
                  autocorrect: false,
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(
                    labelText: '密码',
                    hintText: '请输入密码',
                    prefixIcon: const Icon(Icons.lock_outline_rounded),
                    suffixIcon: IconButton(
                      key: const ValueKey('toggle-password'),
                      onPressed: () =>
                          setState(() => _obscurePassword = !_obscurePassword),
                      icon: Icon(
                        _obscurePassword
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                      tooltip: _obscurePassword ? '显示密码' : '隐藏密码',
                    ),
                  ),
                  onSubmitted: (_) => widget.loading ? null : widget.onLogin(),
                ),
                if (widget.error case final message?) ...[
                  const SizedBox(height: 14),
                  _InlineError(message: message),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  key: const ValueKey('login-button'),
                  onPressed: widget.loading ? null : widget.onLogin,
                  child: widget.loading
                      ? const _ButtonProgress(label: '正在登录…')
                      : const Text('登录'),
                ),
                const Spacer(),
                const SizedBox(height: 28),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _BrandMark extends StatelessWidget {
  const _BrandMark();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [B8Colors.primary, B8Colors.primaryDark],
            ),
            borderRadius: BorderRadius.circular(15),
            boxShadow: const [
              BoxShadow(
                color: Color(0x3325C06D),
                blurRadius: 18,
                offset: Offset(0, 8),
              ),
            ],
          ),
          child: const Icon(
            Icons.apartment_rounded,
            color: Colors.white,
            size: 25,
          ),
        ),
        const SizedBox(width: 13),
        Text(
          'B8 IM',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            color: B8Colors.text,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
          ),
        ),
      ],
    );
  }
}

final class _TenantLogo extends StatelessWidget {
  const _TenantLogo({required this.tenant, required this.size});

  final TenantConfig tenant;
  final double size;

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      alignment: Alignment.center,
      color: B8Colors.mint,
      child: Text(
        tenant.siteName.trim().isEmpty ? '企' : tenant.siteName.trim()[0],
        style: TextStyle(
          color: B8Colors.primaryDark,
          fontSize: size * 0.36,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(size * 0.28),
        border: Border.all(color: B8Colors.line),
        boxShadow: const [
          BoxShadow(
            color: Color(0x120F172A),
            blurRadius: 24,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: tenant.logoUri == null
          ? fallback
          : Image.network(
              tenant.logoUri.toString(),
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => fallback,
            ),
    );
  }
}

final class _InlineError extends StatelessWidget {
  const _InlineError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF1F2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFFD5D9)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: Icon(
              Icons.error_outline_rounded,
              color: Color(0xFFD92D20),
              size: 19,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: const Color(0xFFB42318),
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

final class _ButtonProgress extends StatelessWidget {
  const _ButtonProgress({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox.square(
          dimension: 18,
          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
        ),
        const SizedBox(width: 10),
        Text(label),
      ],
    );
  }
}
