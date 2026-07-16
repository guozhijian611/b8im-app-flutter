import 'dart:async';

import 'package:b8im_file_media_module/b8im_file_media_module.dart';
import 'package:flutter/material.dart';

import '../config/app_environment.dart';
import '../discovery/tenant_config.dart';
import '../discovery/tenant_discovery_client.dart';
import '../im/app_im_connection.dart';
import '../im/web_socket_im_socket.dart';
import '../messaging/app_messaging_service.dart';
import '../messaging/messaging_home_page.dart';
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

final class B8imApp extends StatefulWidget {
  const B8imApp({
    super.key,
    this.environment,
    this.discoveryGateway,
    this.deviceIdLoader,
    this.moduleRegistry,
    this.sessionBootstrapGateway,
    this.messagingGateway,
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
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF16A66A),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF4F7F6),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
          filled: true,
          fillColor: Colors.white,
        ),
        useMaterial3: true,
      ),
      home: BootstrapPage(
        environment: _environment,
        discoveryGateway: _discoveryGateway,
        deviceIdLoader: _deviceIdLoader,
        moduleRegistry: _moduleRegistry,
        sessionBootstrapGateway: _sessionBootstrapGateway,
        messagingGateway: _messagingGateway,
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
      if (mounted) setState(() => _error = error.toString());
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
      if (mounted) setState(() => _sessionResult = result);
    } on Object catch (error) {
      if (mounted) setState(() => _sessionError = error.toString());
    } finally {
      if (mounted) setState(() => _sessionLoading = false);
    }
  }

  Future<void> _openMessaging() async {
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
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => MessagingHomePage(
            tenant: tenant,
            session: result.session,
            im: result.im,
            messaging: widget.messagingGateway,
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
          ),
        ),
      );
    } finally {
      preflightClient?.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('b8im'), centerTitle: false),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              '连接你的企业',
              style: Theme.of(
                context,
              ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              'Android / iOS 统一从受信线路配置启动，模块能力由服务端授权与 App 固定注册表共同决定。',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),
            TextField(
              key: const ValueKey('enterprise-code'),
              controller: _enterpriseCodeController,
              autocorrect: false,
              enableSuggestions: false,
              textCapitalization: TextCapitalization.none,
              decoration: const InputDecoration(
                labelText: '企业码',
                hintText: '例如：your_company',
                prefixIcon: Icon(Icons.apartment_rounded),
              ),
              onSubmitted: (_) => _loading ? null : _discover(),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const ValueKey('discover-button'),
              onPressed: _loading ? null : _discover,
              icon: _loading
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.verified_user_outlined),
              label: Text(_loading ? '正在验证线路…' : '安全连接'),
            ),
            const SizedBox(height: 16),
            _InfoRow(
              label: '发现服务',
              value: widget.environment.discoveryBaseUri.toString(),
            ),
            _InfoRow(
              label: 'App 模块注册数',
              value: widget.moduleRegistry.length.toString(),
            ),
            if (_error case final error?) ...[
              const SizedBox(height: 16),
              _MessageCard(
                color: Theme.of(context).colorScheme.errorContainer,
                icon: Icons.error_outline,
                title: '连接失败',
                message: error,
              ),
            ],
            if (_tenant case final tenant?) ...[
              const SizedBox(height: 16),
              _TenantCard(tenant: tenant),
              const SizedBox(height: 16),
              _LoginCard(
                accountController: _accountController,
                passwordController: _passwordController,
                loading: _sessionLoading,
                os: widget.runtime.os,
                onLogin: _connectSession,
              ),
            ],
            if (_sessionError case final error?) ...[
              const SizedBox(height: 16),
              _MessageCard(
                color: Theme.of(context).colorScheme.errorContainer,
                icon: Icons.error_outline,
                title: '登录或 IM 初始化失败',
                message: error,
              ),
            ],
            if (_sessionResult case final result?) ...[
              const SizedBox(height: 16),
              _SessionCard(
                tenant: _tenant!,
                result: result,
                onOpenMessaging: _openMessaging,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

final class _LoginCard extends StatelessWidget {
  const _LoginCard({
    required this.accountController,
    required this.passwordController,
    required this.loading,
    required this.os,
    required this.onLogin,
  });

  final TextEditingController accountController;
  final TextEditingController passwordController;
  final bool loading;
  final String os;
  final Future<void> Function() onLogin;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '登录并连接 IM',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text('当前平台：$os · 密码仅用于本次登录，不会持久化'),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('login-account'),
              controller: accountController,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: '账号',
                prefixIcon: Icon(Icons.person_outline),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('login-password'),
              controller: passwordController,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: '密码',
                prefixIcon: Icon(Icons.lock_outline),
              ),
              onSubmitted: (_) => loading ? null : onLogin(),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const ValueKey('login-button'),
              onPressed: loading ? null : onLogin,
              icon: loading
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.login_rounded),
              label: Text(loading ? '正在建立安全会话…' : '登录并同步'),
            ),
          ],
        ),
      ),
    );
  }
}

final class _SessionCard extends StatelessWidget {
  const _SessionCard({
    required this.tenant,
    required this.result,
    required this.onOpenMessaging,
  });

  final TenantConfig tenant;
  final AppSessionBootstrapResult result;
  final Future<void> Function() onOpenMessaging;

  @override
  Widget build(BuildContext context) {
    final user = result.session.user;
    final im = result.im.bootstrap;
    return Card(
      color: Theme.of(context).colorScheme.primaryContainer,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.sync_lock_rounded),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'AUTH + SYNC 已完成',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _InfoRow(label: '用户', value: '${user.nickname} (${user.account})'),
            _InfoRow(label: '授权模块', value: '${result.modules.length}'),
            _InfoRow(label: 'IM Client', value: im.clientId),
            _InfoRow(
              label: '全局游标',
              value: '${im.previousGlobalSeq} → ${im.nextGlobalSeq}',
            ),
            _InfoRow(label: '同步消息', value: '${im.syncedMessages.length}'),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                key: const ValueKey('open-messaging'),
                onPressed: onOpenMessaging,
                icon: const Icon(Icons.forum_outlined),
                label: const Text('进入消息'),
              ),
            ),
            for (final module in result.modules) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton.tonalIcon(
                  key: ValueKey('open-module-${module.registration.moduleKey}'),
                  onPressed: () => Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (context) => module.registration.builder(
                        context,
                        module.projection,
                        ClientModuleContext(
                          tenant: tenant,
                          session: result.session,
                        ),
                      ),
                    ),
                  ),
                  icon: const Icon(Icons.extension_outlined),
                  label: Text(module.title),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

final class _TenantCard extends StatelessWidget {
  const _TenantCard({required this.tenant});

  final TenantConfig tenant;

  @override
  Widget build(BuildContext context) {
    final endpoints = tenant.routing.primary.endpoints;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.check_circle,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    tenant.siteName,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            _InfoRow(label: 'Organization', value: '${tenant.organization}'),
            _InfoRow(label: 'Deployment', value: tenant.deploymentId),
            _InfoRow(
              label: 'Routing version',
              value: '${tenant.routing.routingVersion}',
            ),
            _InfoRow(label: 'API', value: endpoints.apiServerUri.toString()),
            _InfoRow(label: 'IM', value: endpoints.imServerUri.toString()),
          ],
        ),
      ),
    );
  }
}

final class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 132,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

final class _MessageCard extends StatelessWidget {
  const _MessageCard({
    required this.color,
    required this.icon,
    required this.title,
    required this.message,
  });

  final Color color;
  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: color,
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(message),
      ),
    );
  }
}
