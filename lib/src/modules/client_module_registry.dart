import 'dart:convert';

import 'package:flutter/widgets.dart';

import '../discovery/tenant_config.dart';
import '../session/app_session.dart';

typedef ClientModuleBuilder =
    Widget Function(
      BuildContext context,
      ClientModuleProjection projection,
      ClientModuleContext moduleContext,
    );

final class ClientModuleContext {
  const ClientModuleContext({required this.tenant, required this.session});

  final TenantConfig tenant;
  final AppSession session;
}

final class ClientModuleRegistration {
  const ClientModuleRegistration({
    required this.moduleKey,
    required this.title,
    required this.capability,
    required this.permission,
    required this.builder,
  });

  final String moduleKey;
  final String title;
  final String capability;
  final String permission;
  final ClientModuleBuilder builder;
}

final class ClientModuleProjection {
  const ClientModuleProjection({
    required this.moduleKey,
    required this.version,
    required this.available,
    required this.capabilities,
    required this.permissions,
    required this.config,
  });

  final String moduleKey;
  final String version;
  final bool available;
  final Set<String> capabilities;
  final Set<String> permissions;
  final Map<String, Object?> config;
}

final class ResolvedClientModule {
  const ResolvedClientModule({
    required this.registration,
    required this.projection,
    required this.title,
  });

  final ClientModuleRegistration registration;
  final ClientModuleProjection projection;
  final String title;
}

final class ClientModuleRegistry {
  ClientModuleRegistry(Iterable<ClientModuleRegistration> registrations)
    : _registrations = _buildRegistry(registrations);

  final Map<String, ClientModuleRegistration> _registrations;

  int get length => _registrations.length;
  Set<String> get moduleKeys => Set.unmodifiable(_registrations.keys.toSet());

  List<ResolvedClientModule> resolve({
    required Object? payload,
    required TenantConfig tenant,
  }) {
    final config = _map(payload, '客户端配置');
    final version = config['version'];
    if (version is! int || version <= 0) {
      throw const FormatException('客户端配置 version 无效');
    }
    if (config['organization'].toString() != tenant.organization.toString()) {
      throw const FormatException('客户端配置 organization 与登录上下文不一致');
    }
    if (config['deployment_id'] != tenant.deploymentId) {
      throw const FormatException('客户端配置 deployment_id 与发现上下文不一致');
    }

    final features = _map(config['features'], '客户端配置 features');
    final rawModules = config['modules'];
    if (rawModules is! List) {
      throw const FormatException('客户端配置 modules 格式无效');
    }
    final projections = <String, ClientModuleProjection>{};
    for (final rawModule in rawModules) {
      if (rawModule is! Map) continue;
      final module = rawModule.map(
        (key, value) => MapEntry(key.toString(), value),
      );
      final moduleKey = module['module_key'];
      if (moduleKey is! String || !_registrations.containsKey(moduleKey)) {
        continue;
      }
      if (projections.containsKey(moduleKey)) {
        throw FormatException('客户端配置 modules 含重复模块: $moduleKey');
      }
      final capabilities = _strings(module['capabilities'], 'capabilities');
      final permissions = _strings(module['permissions'], 'permissions');
      // Server may omit config or send null for modules without runtime knobs.
      final moduleConfig = _optionalMap(module['config'], '$moduleKey.config');
      final moduleVersion = module['version'];
      final available = module['available'];
      if (moduleVersion is! String ||
          moduleVersion.trim().isEmpty ||
          available is! bool) {
        throw FormatException('$moduleKey 投影格式无效');
      }
      projections[moduleKey] = ClientModuleProjection(
        moduleKey: moduleKey,
        version: moduleVersion.trim(),
        available: available,
        capabilities: capabilities,
        permissions: permissions,
        config: Map.unmodifiable(moduleConfig),
      );
    }

    final titles = <String, String>{};
    final tabbarKeys = <String>{};
    final tabbar = config['tabbar'];
    if (tabbar is! List) {
      throw const FormatException('客户端配置 tabbar 格式无效');
    }
    for (final rawItem in tabbar) {
      if (rawItem is! Map) continue;
      final item = rawItem.map((key, value) => MapEntry(key.toString(), value));
      final moduleKey = item['module_key'];
      final title = item['title'];
      if (moduleKey is String &&
          _registrations.containsKey(moduleKey) &&
          title is String &&
          title.trim().isNotEmpty) {
        if (!tabbarKeys.add(moduleKey)) {
          throw FormatException('客户端配置 tabbar 含重复模块: $moduleKey');
        }
        titles[moduleKey] = title.trim();
      }
    }

    final resolved = <ResolvedClientModule>[];
    for (final registration in _registrations.values) {
      final projection = projections[registration.moduleKey];
      if (projection == null ||
          !projection.available ||
          features[registration.moduleKey] != true ||
          !tabbarKeys.contains(registration.moduleKey) ||
          !projection.capabilities.contains(registration.capability) ||
          !projection.permissions.contains(registration.permission)) {
        continue;
      }
      resolved.add(
        ResolvedClientModule(
          registration: registration,
          projection: projection,
          title: titles[registration.moduleKey] ?? registration.title,
        ),
      );
    }
    return List.unmodifiable(resolved);
  }

  static Map<String, ClientModuleRegistration> _buildRegistry(
    Iterable<ClientModuleRegistration> registrations,
  ) {
    final result = <String, ClientModuleRegistration>{};
    for (final registration in registrations) {
      if (!RegExp(r'^[a-z][a-z0-9_]{1,63}$').hasMatch(registration.moduleKey)) {
        throw ArgumentError.value(
          registration.moduleKey,
          'moduleKey',
          '模块 key 格式无效',
        );
      }
      if (result.containsKey(registration.moduleKey)) {
        throw ArgumentError('重复注册 App 模块: ${registration.moduleKey}');
      }
      result[registration.moduleKey] = registration;
    }
    return Map.unmodifiable(result);
  }

  static Map<String, Object?> _map(Object? value, String field) {
    if (value is! Map) throw FormatException('$field 格式无效');
    return value.map((key, item) => MapEntry(key.toString(), item));
  }

  /// Treats null / empty-string / empty-list config as empty object.
  /// Accepts Map, or a JSON object string; rejects other shapes.
  static Map<String, Object?> _optionalMap(Object? value, String field) {
    if (value == null) {
      return const <String, Object?>{};
    }
    if (value is Map) {
      return value.map((key, item) => MapEntry(key.toString(), item));
    }
    if (value is List && value.isEmpty) {
      return const <String, Object?>{};
    }
    if (value is String) {
      final trimmed = value.trim();
      if (trimmed.isEmpty || trimmed == '{}' || trimmed == 'null') {
        return const <String, Object?>{};
      }
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded == null) {
          return const <String, Object?>{};
        }
        if (decoded is Map) {
          return decoded.map((key, item) => MapEntry(key.toString(), item));
        }
      } on FormatException {
        throw FormatException('$field 格式无效');
      }
    }
    throw FormatException('$field 格式无效');
  }

  static Set<String> _strings(Object? value, String field) {
    if (value is! List ||
        value.any((item) => item is! String || item.trim().isEmpty)) {
      throw FormatException('$field 格式无效');
    }
    return Set.unmodifiable(value.cast<String>().map((item) => item.trim()));
  }
}
