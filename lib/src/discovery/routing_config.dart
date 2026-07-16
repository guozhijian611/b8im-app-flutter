final class RoutingEndpoints {
  const RoutingEndpoints({
    required this.apiServerUri,
    required this.imServerUri,
    required this.uploadServerUri,
    required this.webServerUri,
  });

  factory RoutingEndpoints.fromJson(Map<String, Object?> value) {
    return RoutingEndpoints(
      apiServerUri: _endpoint(value, 'api_server_url', 'https'),
      imServerUri: _endpoint(value, 'im_server_url', 'wss'),
      uploadServerUri: _endpoint(value, 'upload_server_url', 'https'),
      webServerUri: _endpoint(value, 'web_server_url', 'https'),
    );
  }

  final Uri apiServerUri;
  final Uri imServerUri;
  final Uri uploadServerUri;
  final Uri webServerUri;

  static Uri _endpoint(
    Map<String, Object?> value,
    String field,
    String scheme,
  ) {
    final raw = _requiredString(value, field);
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        uri.scheme != scheme ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw FormatException('server_info.$field 必须是安全且无凭据的 $scheme 地址');
    }
    return uri.replace(path: uri.path.replaceFirst(RegExp(r'/+$'), ''));
  }
}

final class RoutingRoute {
  const RoutingRoute({
    required this.routeId,
    required this.routeVersion,
    required this.name,
    required this.deploymentId,
    required this.endpoints,
  });

  factory RoutingRoute.fromJson(
    Map<String, Object?> value,
    String expectedDeploymentId,
  ) {
    final routeId = _requiredString(value, 'route_id');
    if (!RegExp(r'^[a-z0-9][a-z0-9_-]{1,63}$').hasMatch(routeId)) {
      throw const FormatException('server_info.routes.route_id 格式无效');
    }
    final deploymentId = _requiredString(value, 'deployment_id');
    if (deploymentId != expectedDeploymentId) {
      throw const FormatException('线路 deployment_id 与企业信息不一致');
    }
    return RoutingRoute(
      routeId: routeId,
      routeVersion: _positiveInt(value, 'route_version'),
      name: _requiredString(value, 'name'),
      deploymentId: deploymentId,
      endpoints: RoutingEndpoints.fromJson(_requiredMap(value, 'endpoints')),
    );
  }

  final String routeId;
  final int routeVersion;
  final String name;
  final String deploymentId;
  final RoutingEndpoints endpoints;
}

final class RoutingPolicy {
  const RoutingPolicy({
    required this.mode,
    required this.primaryRouteId,
    required this.backupRouteIds,
    required this.connectTimeoutMs,
    required this.switchCooldownSeconds,
  });

  factory RoutingPolicy.fromJson(Map<String, Object?> value) {
    final mode = _requiredString(value, 'mode');
    if (mode != 'single' && mode != 'primary_backup') {
      throw const FormatException('App 暂不支持该线路模式');
    }
    if (value['route_bundle_required'] != true ||
        value['failover_scope'] != 'service') {
      throw const FormatException('线路 bundle 或切换范围无效');
    }
    final backups = value['backup_route_ids'];
    if (backups is! List ||
        backups.any((item) => item is! String || item.trim().isEmpty)) {
      throw const FormatException('backup_route_ids 格式无效');
    }
    final backupRouteIds = backups
        .cast<String>()
        .map((item) => item.trim())
        .toList();
    if (mode == 'single' && backupRouteIds.isNotEmpty) {
      throw const FormatException('single 模式不能包含备线');
    }
    if (mode == 'primary_backup' && backupRouteIds.isEmpty) {
      throw const FormatException('primary_backup 模式缺少备线');
    }
    return RoutingPolicy(
      mode: mode,
      primaryRouteId: _requiredString(value, 'primary_route_id'),
      backupRouteIds: List.unmodifiable(backupRouteIds),
      connectTimeoutMs: _positiveInt(value, 'connect_timeout_ms'),
      switchCooldownSeconds: _nonNegativeInt(value, 'switch_cooldown_seconds'),
    );
  }

  final String mode;
  final String primaryRouteId;
  final List<String> backupRouteIds;
  final int connectTimeoutMs;
  final int switchCooldownSeconds;
}

final class RoutingConfig {
  const RoutingConfig({
    required this.routePoolId,
    required this.routePoolVersion,
    required this.routingVersion,
    required this.issuedAt,
    required this.expiresAt,
    required this.staleIfErrorUntil,
    required this.policy,
    required this.routes,
  });

  factory RoutingConfig.fromJson(
    Map<String, Object?> value, {
    required String deploymentId,
    DateTime? now,
  }) {
    if (value['schema_version'] != 2) {
      throw const FormatException('server_info.schema_version 必须为 2');
    }
    final issuedAt = _date(value, 'issued_at');
    final expiresAt = _date(value, 'expires_at');
    final staleIfErrorUntil = _date(value, 'stale_if_error_until');
    _date(value, 'server_time');
    final current = (now ?? DateTime.now()).toUtc();
    if (!expiresAt.isAfter(current)) {
      throw const FormatException('线路配置已经过期');
    }
    if (!expiresAt.isAfter(issuedAt) || staleIfErrorUntil.isBefore(expiresAt)) {
      throw const FormatException('线路配置有效期无效');
    }

    final policy = RoutingPolicy.fromJson(_requiredMap(value, 'policy'));
    final rawRoutes = value['routes'];
    if (rawRoutes is! List || rawRoutes.isEmpty) {
      throw const FormatException('server_info.routes 不能为空');
    }
    final seen = <String>{};
    final byId = <String, RoutingRoute>{};
    for (final rawRoute in rawRoutes) {
      if (rawRoute is! Map) {
        throw const FormatException('server_info.routes 格式无效');
      }
      final route = RoutingRoute.fromJson(
        rawRoute.map((key, item) => MapEntry(key.toString(), item)),
        deploymentId,
      );
      if (!seen.add(route.routeId)) {
        throw const FormatException('server_info.routes 含重复 route_id');
      }
      byId[route.routeId] = route;
    }
    final orderedIds = [policy.primaryRouteId, ...policy.backupRouteIds];
    if (orderedIds.any((routeId) => !byId.containsKey(routeId))) {
      throw const FormatException('线路策略引用了不存在的 route_id');
    }

    return RoutingConfig(
      routePoolId: _requiredString(value, 'route_pool_id'),
      routePoolVersion: _positiveInt(value, 'route_pool_version'),
      routingVersion: _positiveInt(value, 'routing_version'),
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      staleIfErrorUntil: staleIfErrorUntil,
      policy: policy,
      routes: List.unmodifiable(orderedIds.map((id) => byId[id]!)),
    );
  }

  final String routePoolId;
  final int routePoolVersion;
  final int routingVersion;
  final DateTime issuedAt;
  final DateTime expiresAt;
  final DateTime staleIfErrorUntil;
  final RoutingPolicy policy;
  final List<RoutingRoute> routes;

  RoutingRoute get primary => routes.first;
}

Map<String, Object?> _requiredMap(Map<String, Object?> value, String field) {
  final item = value[field];
  if (item is! Map) throw FormatException('$field 格式无效');
  return item.map((key, child) => MapEntry(key.toString(), child));
}

String _requiredString(Map<String, Object?> value, String field) {
  final item = value[field];
  if (item is! String || item.trim().isEmpty) {
    throw FormatException('$field 格式无效');
  }
  return item.trim();
}

int _positiveInt(Map<String, Object?> value, String field) {
  final item = value[field];
  if (item is! int || item <= 0) throw FormatException('$field 格式无效');
  return item;
}

int _nonNegativeInt(Map<String, Object?> value, String field) {
  final item = value[field];
  if (item is! int || item < 0) throw FormatException('$field 格式无效');
  return item;
}

DateTime _date(Map<String, Object?> value, String field) {
  final parsed = DateTime.tryParse(_requiredString(value, field));
  if (parsed == null) throw FormatException('$field 格式无效');
  return parsed.toUtc();
}
