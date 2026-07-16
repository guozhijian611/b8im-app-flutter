import 'package:flutter/material.dart';

import '../app/app_theme.dart';
import '../discovery/tenant_config.dart';
import '../session/app_session.dart';

final class ProfilePage extends StatelessWidget {
  const ProfilePage({
    super.key,
    required this.tenant,
    required this.session,
    required this.onLogout,
  });

  final TenantConfig tenant;
  final AppSession session;
  final Future<void> Function() onLogout;

  @override
  Widget build(BuildContext context) {
    final user = session.user;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 28, 20, 24),
          children: [
            _ProfileHeader(tenant: tenant, session: session),
            const SizedBox(height: 18),
            Card(
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 10,
                ),
                leading: const _FeatureIcon(
                  icon: Icons.apartment_rounded,
                  color: B8Colors.primary,
                ),
                title: Text(tenant.siteName),
                subtitle: Text('企业码：${tenant.enterpriseCode}'),
              ),
            ),
            const SizedBox(height: 24),
            const B8SectionTitle('常用功能'),
            const SizedBox(height: 14),
            GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: 2,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 1.32,
              children: [
                _FunctionCard(
                  icon: Icons.notifications_none_rounded,
                  title: '通知设置',
                  onTap: () => Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => const NotificationSettingsPage(),
                    ),
                  ),
                ),
                _FunctionCard(
                  icon: Icons.shield_outlined,
                  title: '安全与隐私',
                  onTap: () => Navigator.of(context).push<void>(
                    MaterialPageRoute(builder: (_) => const SecurityPage()),
                  ),
                ),
                _FunctionCard(
                  icon: Icons.manage_accounts_outlined,
                  title: '个人资料',
                  onTap: () => Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) =>
                          ProfileDetailsPage(tenant: tenant, session: session),
                    ),
                  ),
                ),
                _FunctionCard(
                  icon: Icons.settings_outlined,
                  title: '设置',
                  onTap: () => Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => SettingsPage(
                        tenant: tenant,
                        session: session,
                        onLogout: onLogout,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Text(
              user.signature.isEmpty ? '让沟通更简单，让协作更高效' : user.signature,
              textAlign: TextAlign.center,
              style: const TextStyle(color: B8Colors.muted),
            ),
          ],
        ),
      ),
    );
  }
}

final class _ProfileHeader extends StatelessWidget {
  const _ProfileHeader({required this.tenant, required this.session});

  final TenantConfig tenant;
  final AppSession session;

  @override
  Widget build(BuildContext context) {
    final user = session.user;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 30),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFDDF7E9), Color(0xFFF4FBF7)],
        ),
        borderRadius: BorderRadius.circular(28),
      ),
      child: Column(
        children: [
          B8Avatar(
            label: user.nickname,
            imageUrl: user.avatarUrl,
            size: 84,
            backgroundColor: Colors.white,
          ),
          const SizedBox(height: 16),
          Text(user.nickname, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 6),
          Text(
            'B8 ID：${user.imShortNo.isEmpty ? user.userId : user.imShortNo}',
            style: const TextStyle(color: B8Colors.muted),
          ),
        ],
      ),
    );
  }
}

final class _FunctionCard extends StatelessWidget {
  const _FunctionCard({
    required this.icon,
    required this.title,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: B8Colors.text, size: 30),
            const SizedBox(height: 12),
            Text(title),
          ],
        ),
      ),
    );
  }
}

final class _FeatureIcon extends StatelessWidget {
  const _FeatureIcon({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(15),
      ),
      child: Icon(icon, color: color),
    );
  }
}

final class ProfileDetailsPage extends StatelessWidget {
  const ProfileDetailsPage({
    super.key,
    required this.tenant,
    required this.session,
  });

  final TenantConfig tenant;
  final AppSession session;

  @override
  Widget build(BuildContext context) {
    final user = session.user;
    return Scaffold(
      appBar: AppBar(title: const Text('个人信息')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Card(
            child: Column(
              children: [
                _SettingsRow(label: '昵称', value: user.nickname),
                _SettingsRow(label: '账号', value: user.account),
                _SettingsRow(
                  label: 'B8 ID',
                  value: user.imShortNo.isEmpty ? user.userId : user.imShortNo,
                ),
                if (user.mobile.isNotEmpty)
                  _SettingsRow(label: '手机号', value: user.mobile),
                _SettingsRow(
                  label: '个性签名',
                  value: user.signature.isEmpty ? '未设置' : user.signature,
                ),
                _SettingsRow(label: '所属企业', value: tenant.siteName),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

final class NotificationSettingsPage extends StatefulWidget {
  const NotificationSettingsPage({super.key});

  @override
  State<NotificationSettingsPage> createState() =>
      _NotificationSettingsPageState();
}

final class _NotificationSettingsPageState
    extends State<NotificationSettingsPage> {
  bool _message = true;
  bool _sound = true;
  bool _preview = true;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('通知设置')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  title: const Text('接收新消息通知'),
                  value: _message,
                  onChanged: (value) => setState(() => _message = value),
                ),
                SwitchListTile(
                  title: const Text('消息提示音'),
                  value: _sound,
                  onChanged: _message
                      ? (value) => setState(() => _sound = value)
                      : null,
                ),
                SwitchListTile(
                  title: const Text('通知显示消息预览'),
                  value: _preview,
                  onChanged: _message
                      ? (value) => setState(() => _preview = value)
                      : null,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

final class SecurityPage extends StatelessWidget {
  const SecurityPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('安全与隐私')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: const [
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: Icon(Icons.lock_outline_rounded),
                  title: Text('登录密码'),
                  subtitle: Text('由企业管理员统一管理'),
                ),
                ListTile(
                  leading: Icon(Icons.devices_outlined),
                  title: Text('当前设备'),
                  subtitle: Text('已通过 App 安全会话验证'),
                ),
                ListTile(
                  leading: Icon(Icons.verified_user_outlined),
                  title: Text('线路安全'),
                  subtitle: Text('企业线路配置已完成签名校验'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

final class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.tenant,
    required this.session,
    required this.onLogout,
  });

  final TenantConfig tenant;
  final AppSession session;
  final Future<void> Function() onLogout;

  Future<void> _confirmLogout(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('确定退出当前企业账号吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('退出', style: TextStyle(color: B8Colors.danger)),
          ),
        ],
      ),
    );
    if (confirmed == true) await onLogout();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Card(
            child: Column(
              children: [
                ListTile(
                  title: const Text('账号与安全'),
                  subtitle: Text(session.user.account),
                  leading: const Icon(Icons.shield_outlined),
                ),
                ListTile(
                  title: const Text('当前企业'),
                  subtitle: Text(
                    '${tenant.siteName} · ${tenant.enterpriseCode}',
                  ),
                  leading: const Icon(Icons.apartment_rounded),
                ),
                const ListTile(
                  title: Text('关于 B8 IM'),
                  subtitle: Text('版本 0.1.0'),
                  leading: Icon(Icons.info_outline_rounded),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          OutlinedButton(
            key: const ValueKey('logout-button'),
            onPressed: () => _confirmLogout(context),
            style: OutlinedButton.styleFrom(
              foregroundColor: B8Colors.danger,
              side: const BorderSide(color: Color(0xFFFFC7C8)),
              minimumSize: const Size.fromHeight(52),
              backgroundColor: Colors.white,
              shape: const StadiumBorder(),
            ),
            child: const Text('退出登录'),
          ),
        ],
      ),
    );
  }
}

final class _SettingsRow extends StatelessWidget {
  const _SettingsRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(label, style: const TextStyle(color: B8Colors.muted)),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}
