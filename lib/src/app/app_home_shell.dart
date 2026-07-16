import 'package:flutter/material.dart';

import '../contacts/app_contact_service.dart';
import '../contacts/contacts_page.dart';
import '../discover/discover_page.dart';
import '../discovery/tenant_config.dart';
import '../im/app_im_connection.dart';
import '../media/app_media_picker.dart';
import '../media/app_media_service.dart';
import '../messaging/app_messaging_service.dart';
import '../messaging/messaging_home_page.dart';
import '../modules/client_module_registry.dart';
import '../profile/profile_page.dart';
import '../session/app_session.dart';
import 'app_theme.dart';

final class AppHomeShell extends StatefulWidget {
  const AppHomeShell({
    super.key,
    required this.tenant,
    required this.session,
    required this.im,
    required this.modules,
    required this.messaging,
    required this.contacts,
    required this.media,
    required this.mediaPicker,
    required this.onLogout,
    this.beforeMediaUpload,
  });

  final TenantConfig tenant;
  final AppSession session;
  final AppImRuntime im;
  final List<ResolvedClientModule> modules;
  final AppMessagingGateway messaging;
  final AppContactGateway contacts;
  final AppMediaGateway media;
  final AppMediaPickerGateway mediaPicker;
  final Future<void> Function() onLogout;
  final Future<void> Function(int size)? beforeMediaUpload;

  @override
  State<AppHomeShell> createState() => _AppHomeShellState();
}

final class _AppHomeShellState extends State<AppHomeShell> {
  int _index = 0;
  int _unread = 0;

  void _select(int index) {
    if (_index == index) return;
    setState(() => _index = index);
  }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      MessagingHomePage(
        key: const PageStorageKey('home-messages'),
        tenant: widget.tenant,
        session: widget.session,
        im: widget.im,
        messaging: widget.messaging,
        media: widget.media,
        mediaPicker: widget.mediaPicker,
        beforeMediaUpload: widget.beforeMediaUpload,
        onOpenContacts: () => _select(1),
        onUnreadChanged: (value) {
          if (value != _unread && mounted) setState(() => _unread = value);
        },
      ),
      ContactsPage(
        key: const PageStorageKey('home-contacts'),
        tenant: widget.tenant,
        session: widget.session,
        im: widget.im,
        contacts: widget.contacts,
        messaging: widget.messaging,
        media: widget.media,
        mediaPicker: widget.mediaPicker,
        beforeMediaUpload: widget.beforeMediaUpload,
      ),
      DiscoverPage(
        key: const PageStorageKey('home-discover'),
        tenant: widget.tenant,
        session: widget.session,
        modules: widget.modules,
      ),
      ProfilePage(
        key: const PageStorageKey('home-profile'),
        tenant: widget.tenant,
        session: widget.session,
        onLogout: widget.onLogout,
      ),
    ];

    return PopScope(
      canPop: false,
      child: Scaffold(
        body: IndexedStack(index: _index, children: pages),
        bottomNavigationBar: _B8BottomBar(
          currentIndex: _index,
          unread: _unread,
          onSelected: _select,
        ),
      ),
    );
  }
}

final class _B8BottomBar extends StatelessWidget {
  const _B8BottomBar({
    required this.currentIndex,
    required this.unread,
    required this.onSelected,
  });

  final int currentIndex;
  final int unread;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    const items = [
      (Icons.chat_bubble_outline_rounded, Icons.chat_bubble_rounded, '消息'),
      (Icons.contacts_outlined, Icons.contacts_rounded, '通讯录'),
      (Icons.explore_outlined, Icons.explore_rounded, '发现'),
      (Icons.person_outline_rounded, Icons.person_rounded, '我的'),
    ];
    return ColoredBox(
      color: B8Colors.background,
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.fromLTRB(12, 4, 12, 10),
        child: Container(
          height: 68,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: B8Colors.primary.withValues(alpha: 0.55)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x0D1F2A37),
                blurRadius: 18,
                offset: Offset(0, 6),
              ),
            ],
          ),
          child: Row(
            children: [
              for (var index = 0; index < items.length; index++)
                Expanded(
                  child: _BottomItem(
                    key: ValueKey('bottom-tab-$index'),
                    icon: items[index].$1,
                    selectedIcon: items[index].$2,
                    label: items[index].$3,
                    selected: currentIndex == index,
                    badge: index == 0 ? unread : 0,
                    onTap: () => onSelected(index),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _BottomItem extends StatelessWidget {
  const _BottomItem({
    super.key,
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.badge,
    required this.onTap,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final int badge;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? B8Colors.primary : const Color(0xFFBEC7D6);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(24),
      child: Semantics(
        selected: selected,
        label: label,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Badge(
              isLabelVisible: badge > 0,
              label: Text(badge > 99 ? '99+' : '$badge'),
              child: Icon(
                selected ? selectedIcon : icon,
                color: color,
                size: 25,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: selected ? B8Colors.text : color,
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
            const SizedBox(height: 3),
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: selected ? 22 : 0,
              height: 3,
              decoration: BoxDecoration(
                color: B8Colors.primary,
                borderRadius: BorderRadius.circular(99),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
