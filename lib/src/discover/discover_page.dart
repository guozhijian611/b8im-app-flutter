import 'package:flutter/material.dart';

import '../app/app_theme.dart';
import '../discovery/tenant_config.dart';
import '../modules/client_module_registry.dart';
import '../profile/profile_page.dart';
import '../session/app_session.dart';

final class DiscoverPage extends StatelessWidget {
  const DiscoverPage({
    super.key,
    required this.tenant,
    required this.session,
    required this.modules,
  });

  final TenantConfig tenant;
  final AppSession session;
  final List<ResolvedClientModule> modules;

  Future<void> _openModule(BuildContext context, ResolvedClientModule module) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => module.registration.builder(
          context,
          module.projection,
          ClientModuleContext(tenant: tenant, session: session),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ResolvedClientModule? fileMedia;
    for (final module in modules) {
      if (module.registration.moduleKey == 'file_media') {
        fileMedia = module;
        break;
      }
    }
    final fileMediaModule = fileMedia;
    return Scaffold(
      appBar: AppBar(automaticallyImplyLeading: false, title: const Text('发现')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        children: [
          _DiscoverCard(
            icon: Icons.grid_view_rounded,
            color: B8Colors.primary,
            title: '工作台',
            subtitle: modules.isEmpty
                ? '企业暂未启用扩展应用'
                : '${modules.length} 个企业应用',
            onTap: () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => WorkbenchPage(
                  tenant: tenant,
                  session: session,
                  modules: modules,
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          _DiscoverCard(
            icon: Icons.folder_copy_outlined,
            color: const Color(0xFF3B82F6),
            title: '共享文件',
            subtitle: fileMediaModule == null ? '当前企业未启用文件空间' : '群聊文件和个人文件空间',
            onTap: fileMediaModule == null
                ? null
                : () => _openModule(context, fileMediaModule),
          ),
          const SizedBox(height: 14),
          _DiscoverCard(
            icon: Icons.shield_outlined,
            color: const Color(0xFFF59E0B),
            title: '安全中心',
            subtitle: '账号、设备与线路安全',
            onTap: () => Navigator.of(context).push<void>(
              MaterialPageRoute(builder: (_) => const SecurityPage()),
            ),
          ),
          const SizedBox(height: 14),
          _DiscoverCard(
            icon: Icons.check_circle_outline_rounded,
            color: B8Colors.primary,
            title: '服务状态',
            subtitle: '消息服务运行正常',
            onTap: () => showModalBottomSheet<void>(
              context: context,
              showDragHandle: true,
              builder: (context) => SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.check_circle_rounded,
                        color: B8Colors.primary,
                        size: 54,
                      ),
                      const SizedBox(height: 14),
                      Text(
                        '服务运行正常',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${tenant.siteName} 的企业消息服务已连接',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: B8Colors.muted),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

final class _DiscoverCard extends StatelessWidget {
  const _DiscoverCard({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              Container(
                width: 54,
                height: 54,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: color, size: 28),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 5),
                    Text(
                      subtitle,
                      style: const TextStyle(color: B8Colors.muted),
                    ),
                  ],
                ),
              ),
              Icon(
                onTap == null
                    ? Icons.lock_outline_rounded
                    : Icons.chevron_right_rounded,
                color: B8Colors.muted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class WorkbenchPage extends StatelessWidget {
  const WorkbenchPage({
    super.key,
    required this.tenant,
    required this.session,
    required this.modules,
  });

  final TenantConfig tenant;
  final AppSession session;
  final List<ResolvedClientModule> modules;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('工作台')),
      body: modules.isEmpty
          ? const B8EmptyState(
              icon: Icons.apps_outlined,
              title: '暂无企业应用',
              message: '企业管理员启用应用后会显示在这里',
            )
          : GridView.builder(
              padding: const EdgeInsets.all(20),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 0.9,
              ),
              itemCount: modules.length,
              itemBuilder: (context, index) {
                final module = modules[index];
                return Card(
                  child: InkWell(
                    key: ValueKey('workbench-${module.registration.moduleKey}'),
                    onTap: () => Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (context) => module.registration.builder(
                          context,
                          module.projection,
                          ClientModuleContext(tenant: tenant, session: session),
                        ),
                      ),
                    ),
                    borderRadius: BorderRadius.circular(20),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            width: 50,
                            height: 50,
                            decoration: BoxDecoration(
                              color: B8Colors.mint,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: const Icon(
                              Icons.widgets_outlined,
                              color: B8Colors.primaryDark,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            module.title,
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}
