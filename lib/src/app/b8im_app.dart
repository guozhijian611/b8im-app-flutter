import 'package:flutter/material.dart';

import '../config/app_environment.dart';
import '../discovery/tenant_config.dart';
import '../discovery/tenant_discovery_client.dart';
import '../modules/client_module_registry.dart';
import '../security/routing_signature_verifier.dart';
import '../storage/device_identity_store.dart';

final class B8imApp extends StatefulWidget {
  const B8imApp({
    super.key,
    this.environment,
    this.discoveryGateway,
    this.deviceIdLoader,
    this.moduleRegistry,
  });

  final AppEnvironment? environment;
  final TenantDiscoveryGateway? discoveryGateway;
  final Future<String> Function()? deviceIdLoader;
  final ClientModuleRegistry? moduleRegistry;

  @override
  State<B8imApp> createState() => _B8imAppState();
}

final class _B8imAppState extends State<B8imApp> {
  late final AppEnvironment _environment;
  late final TenantDiscoveryGateway _discoveryGateway;
  late final Future<String> Function() _deviceIdLoader;
  late final ClientModuleRegistry _moduleRegistry;

  @override
  void initState() {
    super.initState();
    _environment = widget.environment ?? AppEnvironment.fromCompileTime();
    _discoveryGateway =
        widget.discoveryGateway ??
        TenantDiscoveryClient(
          discoveryBaseUri: _environment.discoveryBaseUri,
          signatureVerifier: RoutingSignatureVerifier(
            _environment.routingPublicKeys,
          ),
        );
    _deviceIdLoader =
        widget.deviceIdLoader ?? DeviceIdentityStore().loadOrCreate;
    _moduleRegistry = widget.moduleRegistry ?? ClientModuleRegistry(const []);
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
  });

  final AppEnvironment environment;
  final TenantDiscoveryGateway discoveryGateway;
  final Future<String> Function() deviceIdLoader;
  final ClientModuleRegistry moduleRegistry;

  @override
  State<BootstrapPage> createState() => _BootstrapPageState();
}

final class _BootstrapPageState extends State<BootstrapPage> {
  late final TextEditingController _enterpriseCodeController;
  String? _deviceId;
  TenantConfig? _tenant;
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _enterpriseCodeController = TextEditingController(
      text: widget.environment.initialEnterpriseCode,
    );
    widget.deviceIdLoader().then((value) {
      if (mounted) setState(() => _deviceId = value);
    });
  }

  @override
  void dispose() {
    _enterpriseCodeController.dispose();
    super.dispose();
  }

  Future<void> _discover() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _error = null;
      _tenant = null;
    });
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
