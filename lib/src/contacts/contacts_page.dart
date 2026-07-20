import 'dart:async';

import 'package:flutter/material.dart';

import '../app/app_theme.dart';
import '../discovery/tenant_config.dart';
import '../im/app_im_connection.dart';
import '../media/app_media_picker.dart';
import '../media/app_media_service.dart';
import '../messaging/app_im_models.dart';
import '../messaging/app_messaging_service.dart';
import '../messaging/messaging_home_page.dart';
import '../session/app_session.dart';
import 'app_contact_models.dart';
import 'app_contact_service.dart';

String _contactIdentityKey(int organization, String userId) =>
    '$organization:${userId.trim()}';

String? _friendRequestPeerKey(
  AppFriendRequest request,
  int currentOrganization,
) {
  if (!request.hasAuthoritativeContext(currentOrganization)) return null;
  final user = request.displayUser!;
  return _contactIdentityKey(user.organization, user.userId);
}

final class ContactsPage extends StatefulWidget {
  const ContactsPage({
    super.key,
    required this.tenant,
    required this.session,
    required this.im,
    required this.contacts,
    required this.messaging,
    required this.media,
    required this.mediaPicker,
    this.beforeMediaUpload,
  });

  final TenantConfig tenant;
  final AppSession session;
  final AppImRuntime im;
  final AppContactGateway contacts;
  final AppMessagingGateway messaging;
  final AppMediaGateway media;
  final AppMediaPickerGateway mediaPicker;
  final Future<void> Function(int size)? beforeMediaUpload;

  @override
  State<ContactsPage> createState() => _ContactsPageState();
}

final class _ContactsPageState extends State<ContactsPage> {
  final _searchController = TextEditingController();
  List<AppContact> _contacts = const [];
  List<AppFriendRequest> _requests = const [];
  int _pendingRequests = 0;
  bool _loading = true;
  String? _error;
  StreamSubscription<AppImEvent>? _eventSubscription;
  late final AppImAccessEventGate _accessGate;
  final Set<String> _revokedPeerIdentities = {};
  final Set<String> _pendingRestorePeerIdentities = {};
  int _accessEpoch = 0;

  List<AppContact> get _filtered {
    final keyword = _searchController.text.trim().toLowerCase();
    if (keyword.isEmpty) return _contacts;
    return _contacts
        .where((contact) {
          return [
            contact.displayName,
            contact.account,
            contact.mobile,
            contact.imShortNo,
          ].any((value) => value.toLowerCase().contains(keyword));
        })
        .toList(growable: false);
  }

  @override
  void initState() {
    super.initState();
    _accessGate = AppImAccessEventGate(
      widget.im.bootstrap.highestCrossOrgAccessSnapshotId,
    );
    _accessGate.reconcileConnectionSnapshot(
      current: widget.im.bootstrap.crossOrgAccessSnapshotId,
      highestPositive: widget.im.bootstrap.highestCrossOrgAccessSnapshotId,
    );
    _eventSubscription = widget.im.events.listen(
      (event) {
        if (event.accessChanged case final accessChanged?) {
          _applyAccessChanged(accessChanged);
        }
        if (event.connectionStatus == AppImConnectionStatus.connected) {
          final snapshot = _accessGate.reconcileConnectionSnapshot(
            current: widget.im.bootstrap.crossOrgAccessSnapshotId,
            highestPositive:
                widget.im.bootstrap.highestCrossOrgAccessSnapshotId,
          );
          if (snapshot == AppImAccessSnapshotObservation.invalid ||
              snapshot == AppImAccessSnapshotObservation.stale ||
              _accessGate.isCrossOrganizationFailClosed) {
            _failCloseCrossOrganization();
          } else {
            _accessEpoch += 1;
            _hideCrossOrganizationData();
            _revokedPeerIdentities.clear();
            _pendingRestorePeerIdentities.clear();
            for (final accessChanged in widget.im.recentAccessChanges) {
              _applyAccessChanged(accessChanged);
            }
            unawaited(_load());
          }
        }
      },
      onError: (Object error) {
        if (isAppImAccessSnapshotFailure(error)) {
          _failCloseCrossOrganization(error: error);
        }
      },
    );
    for (final accessChanged in widget.im.recentAccessChanges) {
      _applyAccessChanged(accessChanged);
    }
    if (_accessGate.isCrossOrganizationFailClosed) {
      _failCloseCrossOrganization();
    }
    unawaited(_load());
  }

  @override
  void dispose() {
    unawaited(_eventSubscription?.cancel());
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load({String? restoringPeerKey}) async {
    final accessEpoch = _accessEpoch;
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final results = await Future.wait<Object>([
        widget.contacts.fetchContacts(
          tenant: widget.tenant,
          session: widget.session,
        ),
        widget.contacts.fetchFriendRequests(
          tenant: widget.tenant,
          session: widget.session,
        ),
      ]);
      final contacts = results[0] as List<AppContact>;
      final requests = results[1] as List<AppFriendRequest>;
      if (accessEpoch != _accessEpoch) return;
      if (restoringPeerKey != null) {
        _pendingRestorePeerIdentities.add(restoringPeerKey);
      }
      final confirmedRestoreKeys = <String>{
        for (final contact in contacts)
          _contactIdentityKey(contact.organization, contact.userId),
        ...requests
            .map(
              (request) =>
                  _friendRequestPeerKey(request, widget.session.organization),
            )
            .whereType<String>(),
      }.where(_pendingRestorePeerIdentities.contains).toSet();
      _revokedPeerIdentities.removeAll(confirmedRestoreKeys);
      _pendingRestorePeerIdentities.removeAll(confirmedRestoreKeys);
      final visibleContacts = contacts
          .where(
            (item) =>
                (item.organization == widget.session.organization ||
                    !_accessGate.isCrossOrganizationFailClosed) &&
                !_revokedPeerIdentities.contains(
                  _contactIdentityKey(item.organization, item.userId),
                ),
          )
          .toList(growable: false);
      final visibleRequests = requests
          .where((item) {
            final key = _friendRequestPeerKey(
              item,
              widget.session.organization,
            );
            return key != null &&
                (item.peerOrganization == widget.session.organization ||
                    !_accessGate.isCrossOrganizationFailClosed) &&
                !_revokedPeerIdentities.contains(key);
          })
          .toList(growable: false);
      if (mounted) {
        setState(() {
          _contacts = visibleContacts;
          _requests = visibleRequests;
          _pendingRequests = visibleRequests
              .where((item) => item.isPendingIncoming)
              .length;
        });
      }
    } on Object catch (error) {
      if (mounted && accessEpoch == _accessEpoch) {
        setState(() => _error = _contactLoadMessage(error));
      }
    } finally {
      if (mounted && accessEpoch == _accessEpoch) {
        setState(() => _loading = false);
      }
    }
  }

  void _applyAccessChanged(AppImConversationAccessChanged accessChanged) {
    if (!appImSameIdentity(
          accessChanged.targetOrganization,
          accessChanged.targetUserId,
          widget.session.organization,
          widget.session.user.userId,
        ) ||
        _accessGate.observe(accessChanged) != AppImAccessEventDecision.apply) {
      return;
    }
    final key = _contactIdentityKey(
      accessChanged.peerOrganization,
      accessChanged.peerUserId,
    );
    _accessEpoch += 1;
    if (accessChanged.allowed) {
      _pendingRestorePeerIdentities.add(key);
      _revokedPeerIdentities.add(key);
      _hidePeerData(key);
      unawaited(_load(restoringPeerKey: key));
      return;
    } else {
      _pendingRestorePeerIdentities.remove(key);
      _revokedPeerIdentities.add(key);
      _hidePeerData(key);
    }
    unawaited(_load());
  }

  void _hidePeerData(String key) {
    if (!mounted) return;
    setState(() {
      _loading = false;
      _contacts = _contacts
          .where(
            (item) =>
                _contactIdentityKey(item.organization, item.userId) != key,
          )
          .toList(growable: false);
      _requests = _requests
          .where((item) {
            final requestKey = _friendRequestPeerKey(
              item,
              widget.session.organization,
            );
            return requestKey != null && requestKey != key;
          })
          .toList(growable: false);
      _pendingRequests = _requests
          .where((item) => item.isPendingIncoming)
          .length;
    });
  }

  void _hideCrossOrganizationData() {
    if (!mounted) return;
    setState(() {
      _loading = false;
      _contacts = _contacts
          .where((item) => item.organization == widget.session.organization)
          .toList(growable: false);
      _requests = _requests
          .where((item) {
            return _friendRequestPeerKey(item, widget.session.organization) !=
                    null &&
                item.peerOrganization == widget.session.organization;
          })
          .toList(growable: false);
      _pendingRequests = _requests
          .where((item) => item.isPendingIncoming)
          .length;
    });
  }

  void _failCloseCrossOrganization({Object? error}) {
    _accessEpoch += 1;
    _accessGate.resetSnapshot('0');
    _pendingRestorePeerIdentities.clear();
    final contacts = _contacts
        .where((item) => item.organization == widget.session.organization)
        .toList(growable: false);
    final requests = _requests
        .where((item) {
          return _friendRequestPeerKey(item, widget.session.organization) !=
                  null &&
              item.peerOrganization == widget.session.organization;
        })
        .toList(growable: false);
    if (mounted) {
      setState(() {
        _loading = false;
        _contacts = contacts;
        _requests = requests;
        _pendingRequests = requests
            .where((item) => item.isPendingIncoming)
            .length;
        if (error != null) _error = error.toString();
      });
    }
  }

  Future<void> _openContact(AppContact contact) async {
    final accessEpoch = _accessEpoch;
    final key = _contactIdentityKey(contact.organization, contact.userId);
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ContactProfilePage(
          contact: contact,
          session: widget.session,
          im: widget.im,
          initiallyAvailable:
              accessEpoch == _accessEpoch &&
              (contact.organization == widget.session.organization ||
                  (!_accessGate.isCrossOrganizationFailClosed &&
                      !_revokedPeerIdentities.contains(key))),
          onMessage: () => _openChat(contact),
        ),
      ),
    );
  }

  Future<void> _openChat(AppContact contact) async {
    final navigator = Navigator.of(context);
    if (navigator.canPop()) navigator.pop();
    await navigator.push<void>(
      MaterialPageRoute(
        builder: (_) => ConversationPage(
          tenant: widget.tenant,
          session: widget.session,
          im: widget.im,
          messaging: widget.messaging,
          media: widget.media,
          mediaPicker: widget.mediaPicker,
          beforeMediaUpload: widget.beforeMediaUpload,
          conversation: AppImConversation.virtualSingle(
            organization: contact.organization,
            userId: contact.userId,
            title: contact.displayName,
            account: contact.account,
            avatarUrl: contact.avatarUrl,
            companyName: contact.companyName,
            isCrossOrganization: contact.isCrossOrganization,
          ),
        ),
      ),
    );
  }

  Future<void> _openRequests() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => FriendRequestsPage(
          tenant: widget.tenant,
          session: widget.session,
          im: widget.im,
          contacts: widget.contacts,
        ),
      ),
    );
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('通讯录'),
        actions: [
          IconButton(
            key: const ValueKey('add-friend-action'),
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => AddFriendPage(
                  tenant: widget.tenant,
                  session: widget.session,
                  im: widget.im,
                  contacts: widget.contacts,
                ),
              ),
            ),
            icon: const Icon(Icons.person_add_alt_1_rounded),
            tooltip: '添加好友',
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          key: const ValueKey('contacts-list'),
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          children: [
            _ContactQuickActions(
              pendingRequests: _pendingRequests,
              onRequests: _openRequests,
              onGroups: () => Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => SavedGroupsPage(
                    tenant: widget.tenant,
                    session: widget.session,
                    im: widget.im,
                    messaging: widget.messaging,
                    media: widget.media,
                    mediaPicker: widget.mediaPicker,
                    beforeMediaUpload: widget.beforeMediaUpload,
                  ),
                ),
              ),
              onAdd: () => Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => AddFriendPage(
                    tenant: widget.tenant,
                    session: widget.session,
                    im: widget.im,
                    contacts: widget.contacts,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
            TextField(
              key: const ValueKey('contact-search'),
              controller: _searchController,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                hintText: '搜索联系人',
                prefixIcon: Icon(Icons.search_rounded),
                isDense: true,
              ),
            ),
            const SizedBox(height: 24),
            const B8SectionTitle('联系人'),
            const SizedBox(height: 14),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(40),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error case final error?)
              _ContactStateCard(
                icon: Icons.wifi_off_rounded,
                message: error,
                onRetry: _load,
              )
            else if (_filtered.isEmpty)
              const _ContactStateCard(
                icon: Icons.people_outline_rounded,
                message: '暂无联系人',
              )
            else
              for (final contact in _filtered) ...[
                _ContactTile(
                  key: ValueKey(
                    'contact-${contact.organization}-${contact.userId}',
                  ),
                  contact: contact,
                  onTap: () => _openContact(contact),
                ),
                const SizedBox(height: 10),
              ],
          ],
        ),
      ),
    );
  }
}

String _contactLoadMessage(Object error) {
  final message = error.toString().toLowerCase();
  if (message.contains('401') || message.contains('unauthorized')) {
    return '登录状态已失效，请重新登录';
  }
  if (message.contains('404') || message.contains('not found')) {
    return '通讯录服务正在更新，请稍后重试';
  }
  return '通讯录暂时不可用，请稍后重试';
}

final class _ContactQuickActions extends StatelessWidget {
  const _ContactQuickActions({
    required this.pendingRequests,
    required this.onRequests,
    required this.onGroups,
    required this.onAdd,
  });

  final int pendingRequests;
  final VoidCallback onRequests;
  final VoidCallback onGroups;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 18),
        child: Row(
          children: [
            Expanded(
              child: _QuickAction(
                icon: Icons.person_add_alt_1_rounded,
                label: '新的朋友',
                badge: pendingRequests,
                onTap: onRequests,
              ),
            ),
            Expanded(
              child: _QuickAction(
                icon: Icons.forum_outlined,
                label: '群聊',
                onTap: onGroups,
              ),
            ),
            Expanded(
              child: _QuickAction(
                icon: Icons.search_rounded,
                label: '添加好友',
                onTap: onAdd,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _QuickAction extends StatelessWidget {
  const _QuickAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.badge = 0,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final int badge;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          children: [
            Badge(
              isLabelVisible: badge > 0,
              label: Text(badge > 99 ? '99+' : '$badge'),
              child: Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: B8Colors.mint,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(icon, color: B8Colors.primaryDark, size: 27),
              ),
            ),
            const SizedBox(height: 10),
            Text(label, style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}

final class _ContactTile extends StatelessWidget {
  const _ContactTile({super.key, required this.contact, required this.onTap});

  final AppContact contact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        onTap: onTap,
        leading: B8Avatar(
          label: contact.displayName,
          imageUrl: contact.avatarUrl,
          size: 48,
        ),
        title: Text(contact.displayName),
        subtitle: Text(
          contact.subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: B8Colors.muted),
        ),
        trailing: const Icon(
          Icons.chevron_right_rounded,
          color: B8Colors.muted,
        ),
      ),
    );
  }
}

final class ContactProfilePage extends StatefulWidget {
  const ContactProfilePage({
    super.key,
    required this.contact,
    required this.session,
    required this.im,
    required this.initiallyAvailable,
    required this.onMessage,
  });

  final AppContact contact;
  final AppSession session;
  final AppImRuntime im;
  final bool initiallyAvailable;
  final Future<void> Function() onMessage;

  @override
  State<ContactProfilePage> createState() => _ContactProfilePageState();
}

final class _ContactProfilePageState extends State<ContactProfilePage> {
  StreamSubscription<AppImEvent>? _eventSubscription;
  bool _invalidated = false;

  @override
  void initState() {
    super.initState();
    if (!widget.initiallyAvailable) {
      _invalidated = true;
      _schedulePop();
      return;
    }
    if (!widget.contact.isCrossOrganization) return;
    _eventSubscription = widget.im.events.listen(
      (event) {
        if (event.connectionStatus == AppImConnectionStatus.connected) {
          _invalidate();
          return;
        }
        final accessChanged = event.accessChanged;
        if (accessChanged != null &&
            appImSameIdentity(
              accessChanged.targetOrganization,
              accessChanged.targetUserId,
              widget.session.organization,
              widget.session.user.userId,
            ) &&
            appImSameIdentity(
              accessChanged.peerOrganization,
              accessChanged.peerUserId,
              widget.contact.organization,
              widget.contact.userId,
            )) {
          _invalidate();
        }
      },
      onError: (Object error) {
        if (isAppImAccessSnapshotFailure(error)) _invalidate();
      },
    );
  }

  void _invalidate() {
    if (_invalidated || !mounted) return;
    setState(() => _invalidated = true);
    _schedulePop();
  }

  void _schedulePop() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    });
  }

  @override
  void dispose() {
    unawaited(_eventSubscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final contact = widget.contact;
    return Scaffold(
      appBar: AppBar(title: const Text('个人名片')),
      body: _invalidated
          ? const Center(child: Text('联系人访问状态已更新'))
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      children: [
                        B8Avatar(
                          label: contact.displayName,
                          imageUrl: contact.avatarUrl,
                          size: 82,
                        ),
                        const SizedBox(height: 18),
                        Text(
                          contact.displayName,
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          contact.signature.isEmpty
                              ? '暂无个性签名'
                              : contact.signature,
                          style: const TextStyle(color: B8Colors.muted),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Card(
                  child: Column(
                    children: [
                      _ProfileRow(label: '账号', value: contact.account),
                      _ProfileRow(
                        label: 'B8 ID',
                        value: contact.imShortNo.isEmpty
                            ? contact.userId
                            : contact.imShortNo,
                      ),
                      if (contact.mobile.isNotEmpty)
                        _ProfileRow(label: '手机号', value: contact.mobile),
                      if (contact.isCrossOrganization &&
                          contact.companyName.isNotEmpty)
                        _ProfileRow(label: '所属公司', value: contact.companyName),
                    ],
                  ),
                ),
                const SizedBox(height: 22),
                FilledButton.icon(
                  key: const ValueKey('contact-message'),
                  onPressed: widget.onMessage,
                  icon: const Icon(Icons.chat_bubble_outline_rounded),
                  label: const Text('发消息'),
                ),
              ],
            ),
    );
  }
}

final class _ProfileRow extends StatelessWidget {
  const _ProfileRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
      child: Row(
        children: [
          SizedBox(
            width: 74,
            child: Text(label, style: const TextStyle(color: B8Colors.muted)),
          ),
          Expanded(child: Text(value.isEmpty ? '未设置' : value)),
        ],
      ),
    );
  }
}

final class FriendRequestsPage extends StatefulWidget {
  const FriendRequestsPage({
    super.key,
    required this.tenant,
    required this.session,
    required this.im,
    required this.contacts,
  });

  final TenantConfig tenant;
  final AppSession session;
  final AppImRuntime im;
  final AppContactGateway contacts;

  @override
  State<FriendRequestsPage> createState() => _FriendRequestsPageState();
}

final class _FriendRequestsPageState extends State<FriendRequestsPage> {
  List<AppFriendRequest> _requests = const [];
  bool _loading = true;
  String? _error;
  StreamSubscription<AppImEvent>? _eventSubscription;
  late final AppImAccessEventGate _accessGate;
  final Set<String> _revokedPeerIdentities = {};
  final Set<String> _pendingRestorePeerIdentities = {};
  int _accessEpoch = 0;

  @override
  void initState() {
    super.initState();
    _accessGate = AppImAccessEventGate(
      widget.im.bootstrap.highestCrossOrgAccessSnapshotId,
    );
    _accessGate.reconcileConnectionSnapshot(
      current: widget.im.bootstrap.crossOrgAccessSnapshotId,
      highestPositive: widget.im.bootstrap.highestCrossOrgAccessSnapshotId,
    );
    _eventSubscription = widget.im.events.listen(
      (event) {
        if (event.connectionStatus == AppImConnectionStatus.connected) {
          final snapshot = _accessGate.reconcileConnectionSnapshot(
            current: widget.im.bootstrap.crossOrgAccessSnapshotId,
            highestPositive:
                widget.im.bootstrap.highestCrossOrgAccessSnapshotId,
          );
          if (snapshot == AppImAccessSnapshotObservation.invalid ||
              snapshot == AppImAccessSnapshotObservation.stale ||
              _accessGate.isCrossOrganizationFailClosed) {
            _failCloseCrossOrganization();
          } else {
            _accessEpoch += 1;
            _hideCrossOrganizationRequests();
            _revokedPeerIdentities.clear();
            _pendingRestorePeerIdentities.clear();
            for (final accessChanged in widget.im.recentAccessChanges) {
              _applyAccessChanged(accessChanged);
            }
            unawaited(_load());
          }
          return;
        }
        final accessChanged = event.accessChanged;
        if (accessChanged != null) _applyAccessChanged(accessChanged);
      },
      onError: (Object error) {
        if (isAppImAccessSnapshotFailure(error)) {
          _failCloseCrossOrganization(error: error);
        }
      },
    );
    for (final accessChanged in widget.im.recentAccessChanges) {
      _applyAccessChanged(accessChanged);
    }
    if (_accessGate.isCrossOrganizationFailClosed) {
      _failCloseCrossOrganization();
    }
    unawaited(_load());
  }

  void _applyAccessChanged(AppImConversationAccessChanged accessChanged) {
    if (!appImSameIdentity(
          accessChanged.targetOrganization,
          accessChanged.targetUserId,
          widget.session.organization,
          widget.session.user.userId,
        ) ||
        _accessGate.observe(accessChanged) != AppImAccessEventDecision.apply) {
      return;
    }
    final key = _contactIdentityKey(
      accessChanged.peerOrganization,
      accessChanged.peerUserId,
    );
    _accessEpoch += 1;
    if (accessChanged.allowed) {
      _pendingRestorePeerIdentities.add(key);
      _revokedPeerIdentities.add(key);
      _hidePeerRequest(key);
      unawaited(_load(restoringPeerKey: key));
      return;
    } else {
      _pendingRestorePeerIdentities.remove(key);
      _revokedPeerIdentities.add(key);
      _hidePeerRequest(key);
    }
    unawaited(_load());
  }

  void _hidePeerRequest(String key) {
    if (!mounted) return;
    setState(() {
      _loading = false;
      _requests = _requests
          .where((item) {
            final requestKey = _friendRequestPeerKey(
              item,
              widget.session.organization,
            );
            return requestKey != null && requestKey != key;
          })
          .toList(growable: false);
    });
  }

  void _hideCrossOrganizationRequests() {
    if (!mounted) return;
    setState(() {
      _loading = false;
      _requests = _requests
          .where((item) {
            return _friendRequestPeerKey(item, widget.session.organization) !=
                    null &&
                item.peerOrganization == widget.session.organization;
          })
          .toList(growable: false);
    });
  }

  void _failCloseCrossOrganization({Object? error}) {
    _accessEpoch += 1;
    _accessGate.resetSnapshot('0');
    _pendingRestorePeerIdentities.clear();
    final visible = _requests
        .where((item) {
          return _friendRequestPeerKey(item, widget.session.organization) !=
                  null &&
              item.peerOrganization == widget.session.organization;
        })
        .toList(growable: false);
    if (mounted) {
      setState(() {
        _loading = false;
        _requests = visible;
        if (error != null) _error = error.toString();
      });
    }
  }

  @override
  void dispose() {
    unawaited(_eventSubscription?.cancel());
    super.dispose();
  }

  Future<void> _load({String? restoringPeerKey}) async {
    final accessEpoch = _accessEpoch;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await widget.contacts.fetchFriendRequests(
        tenant: widget.tenant,
        session: widget.session,
      );
      if (accessEpoch != _accessEpoch) return;
      if (restoringPeerKey != null) {
        _pendingRestorePeerIdentities.add(restoringPeerKey);
      }
      final confirmedRestoreKeys = result
          .map(
            (request) =>
                _friendRequestPeerKey(request, widget.session.organization),
          )
          .whereType<String>()
          .where(_pendingRestorePeerIdentities.contains)
          .toSet();
      _revokedPeerIdentities.removeAll(confirmedRestoreKeys);
      _pendingRestorePeerIdentities.removeAll(confirmedRestoreKeys);
      final visible = result
          .where((item) {
            final key = _friendRequestPeerKey(
              item,
              widget.session.organization,
            );
            return key != null &&
                (item.peerOrganization == widget.session.organization ||
                    !_accessGate.isCrossOrganizationFailClosed) &&
                !_revokedPeerIdentities.contains(key);
          })
          .toList(growable: false);
      if (mounted) setState(() => _requests = visible);
    } on Object catch (error) {
      if (mounted && accessEpoch == _accessEpoch) {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted && accessEpoch == _accessEpoch) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _handle(AppFriendRequest request, bool accept) async {
    final accessEpoch = _accessEpoch;
    final peerKey = _friendRequestPeerKey(request, widget.session.organization);
    if (peerKey == null ||
        !request.isPendingIncoming ||
        (request.peerOrganization != widget.session.organization &&
            (_accessGate.isCrossOrganizationFailClosed ||
                _revokedPeerIdentities.contains(peerKey)))) {
      return;
    }
    try {
      await widget.contacts.handleFriendRequest(
        tenant: widget.tenant,
        session: widget.session,
        request: request,
        accept: accept,
      );
      if (!mounted || accessEpoch != _accessEpoch) return;
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(accept ? '已通过好友申请' : '已拒绝好友申请')));
      }
      await _load();
    } on Object catch (error) {
      if (mounted && accessEpoch == _accessEpoch) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('新的朋友')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? _ContactStateCard(
              icon: Icons.error_outline_rounded,
              message: _error!,
              onRetry: _load,
            )
          : _requests.isEmpty
          ? const B8EmptyState(
              icon: Icons.person_add_alt_1_rounded,
              title: '暂无好友申请',
              message: '新的好友申请会显示在这里',
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView.separated(
                padding: const EdgeInsets.all(20),
                itemCount: _requests.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final request = _requests[index];
                  final user = request.displayUser;
                  return Card(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Row(
                        children: [
                          B8Avatar(
                            label: user?.displayName ?? '友',
                            imageUrl: user?.avatarUrl ?? '',
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(user?.displayName ?? '未知用户'),
                                const SizedBox(height: 4),
                                Text(
                                  request.message.isEmpty
                                      ? request.statusText
                                      : request.message,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: B8Colors.muted),
                                ),
                              ],
                            ),
                          ),
                          if (request.isPendingIncoming)
                            PopupMenuButton<bool>(
                              onSelected: (accept) => _handle(request, accept),
                              itemBuilder: (_) => const [
                                PopupMenuItem(value: true, child: Text('通过')),
                                PopupMenuItem(value: false, child: Text('拒绝')),
                              ],
                            )
                          else
                            Text(
                              request.statusText,
                              style: const TextStyle(color: B8Colors.muted),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
    );
  }
}

final class AddFriendPage extends StatefulWidget {
  const AddFriendPage({
    super.key,
    required this.tenant,
    required this.session,
    required this.im,
    required this.contacts,
  });

  final TenantConfig tenant;
  final AppSession session;
  final AppImRuntime im;
  final AppContactGateway contacts;

  @override
  State<AddFriendPage> createState() => _AddFriendPageState();
}

final class _AddFriendPageState extends State<AddFriendPage> {
  final _controller = TextEditingController();
  List<AppContact> _results = const [];
  bool _searching = false;
  String? _error;
  StreamSubscription<AppImEvent>? _eventSubscription;
  late final AppImAccessEventGate _accessGate;
  final Set<String> _revokedPeerIdentities = {};
  final Set<String> _pendingRestorePeerIdentities = {};
  int _accessEpoch = 0;

  @override
  void initState() {
    super.initState();
    _accessGate = AppImAccessEventGate(
      widget.im.bootstrap.highestCrossOrgAccessSnapshotId,
    );
    _accessGate.reconcileConnectionSnapshot(
      current: widget.im.bootstrap.crossOrgAccessSnapshotId,
      highestPositive: widget.im.bootstrap.highestCrossOrgAccessSnapshotId,
    );
    _eventSubscription = widget.im.events.listen(
      (event) {
        if (event.connectionStatus == AppImConnectionStatus.connected) {
          final snapshot = _accessGate.reconcileConnectionSnapshot(
            current: widget.im.bootstrap.crossOrgAccessSnapshotId,
            highestPositive:
                widget.im.bootstrap.highestCrossOrgAccessSnapshotId,
          );
          if (snapshot == AppImAccessSnapshotObservation.invalid ||
              snapshot == AppImAccessSnapshotObservation.stale ||
              _accessGate.isCrossOrganizationFailClosed) {
            _failCloseCrossOrganization();
          } else {
            _accessEpoch += 1;
            _hideCrossOrganizationResults();
            _revokedPeerIdentities.clear();
            _pendingRestorePeerIdentities.clear();
            for (final accessChanged in widget.im.recentAccessChanges) {
              _applyAccessChanged(accessChanged);
            }
            if (_controller.text.trim().isNotEmpty) unawaited(_search());
          }
          return;
        }
        final accessChanged = event.accessChanged;
        if (accessChanged != null) _applyAccessChanged(accessChanged);
      },
      onError: (Object error) {
        if (isAppImAccessSnapshotFailure(error)) {
          _failCloseCrossOrganization(error: error);
        }
      },
    );
    for (final accessChanged in widget.im.recentAccessChanges) {
      _applyAccessChanged(accessChanged);
    }
    if (_accessGate.isCrossOrganizationFailClosed) {
      _failCloseCrossOrganization();
    }
  }

  void _applyAccessChanged(AppImConversationAccessChanged accessChanged) {
    if (!appImSameIdentity(
          accessChanged.targetOrganization,
          accessChanged.targetUserId,
          widget.session.organization,
          widget.session.user.userId,
        ) ||
        _accessGate.observe(accessChanged) != AppImAccessEventDecision.apply) {
      return;
    }
    final key = _contactIdentityKey(
      accessChanged.peerOrganization,
      accessChanged.peerUserId,
    );
    _accessEpoch += 1;
    if (accessChanged.allowed) {
      _pendingRestorePeerIdentities.add(key);
      _revokedPeerIdentities.add(key);
      _hidePeerResult(key);
      if (_controller.text.trim().isNotEmpty) unawaited(_search());
      return;
    } else {
      _pendingRestorePeerIdentities.remove(key);
      _revokedPeerIdentities.add(key);
      _hidePeerResult(key);
    }
  }

  void _hidePeerResult(String key) {
    if (!mounted) return;
    setState(() {
      _searching = false;
      _results = _results
          .where(
            (item) =>
                _contactIdentityKey(item.organization, item.userId) != key,
          )
          .toList(growable: false);
    });
  }

  void _hideCrossOrganizationResults() {
    if (!mounted) return;
    setState(() {
      _searching = false;
      _results = _results
          .where((item) => item.organization == widget.session.organization)
          .toList(growable: false);
    });
  }

  void _failCloseCrossOrganization({Object? error}) {
    _accessEpoch += 1;
    _accessGate.resetSnapshot('0');
    _pendingRestorePeerIdentities.clear();
    final visible = _results
        .where((item) => item.organization == widget.session.organization)
        .toList(growable: false);
    if (mounted) {
      setState(() {
        _searching = false;
        _results = visible;
        if (error != null) _error = error.toString();
      });
    }
  }

  @override
  void dispose() {
    unawaited(_eventSubscription?.cancel());
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final keyword = _controller.text.trim();
    if (keyword.isEmpty) return;
    final accessEpoch = _accessEpoch;
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final result = await widget.contacts.searchUsers(
        tenant: widget.tenant,
        session: widget.session,
        keyword: keyword,
      );
      if (accessEpoch != _accessEpoch) return;
      for (final item in result) {
        final key = _contactIdentityKey(item.organization, item.userId);
        if (_pendingRestorePeerIdentities.remove(key)) {
          _revokedPeerIdentities.remove(key);
        }
      }
      final visible = result
          .where(
            (item) =>
                (item.organization == widget.session.organization ||
                    !_accessGate.isCrossOrganizationFailClosed) &&
                !_revokedPeerIdentities.contains(
                  _contactIdentityKey(item.organization, item.userId),
                ),
          )
          .toList(growable: false);
      if (mounted) setState(() => _results = visible);
    } on Object catch (error) {
      if (mounted && accessEpoch == _accessEpoch) {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted && accessEpoch == _accessEpoch) {
        setState(() => _searching = false);
      }
    }
  }

  Future<void> _add(AppContact contact) async {
    final accessEpoch = _accessEpoch;
    final key = _contactIdentityKey(contact.organization, contact.userId);
    if (contact.organization != widget.session.organization &&
        (_accessGate.isCrossOrganizationFailClosed ||
            _revokedPeerIdentities.contains(key))) {
      return;
    }
    try {
      final message = await widget.contacts.sendFriendRequest(
        tenant: widget.tenant,
        session: widget.session,
        organization: contact.organization,
        userId: contact.userId,
        message: '我是 ${widget.session.user.nickname}',
      );
      if (!mounted || accessEpoch != _accessEpoch) return;
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
      await _search();
    } on Object catch (error) {
      if (mounted && accessEpoch == _accessEpoch) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('添加好友')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          TextField(
            key: const ValueKey('add-friend-search'),
            controller: _controller,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _search(),
            decoration: InputDecoration(
              hintText: '搜索账号、昵称、手机号或短号',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: IconButton(
                onPressed: _searching ? null : _search,
                icon: const Icon(Icons.arrow_forward_rounded),
              ),
            ),
          ),
          const SizedBox(height: 18),
          if (_searching)
            const Center(child: CircularProgressIndicator())
          else if (_error case final error?)
            _ContactStateCard(
              icon: Icons.error_outline_rounded,
              message: error,
              onRetry: _search,
            )
          else if (_results.isEmpty)
            const B8EmptyState(
              icon: Icons.person_search_rounded,
              title: '查找企业用户',
              message: '输入账号、昵称、手机号或 B8 短号',
            )
          else
            for (final contact in _results) ...[
              Card(
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 6,
                  ),
                  leading: B8Avatar(
                    label: contact.displayName,
                    imageUrl: contact.avatarUrl,
                  ),
                  title: Text(contact.displayName),
                  subtitle: Text(contact.account),
                  trailing: contact.relationStatus == 'friend'
                      ? const Text('已是好友')
                      : TextButton(
                          onPressed: () => _add(contact),
                          child: const Text('添加'),
                        ),
                ),
              ),
              const SizedBox(height: 10),
            ],
        ],
      ),
    );
  }
}

final class SavedGroupsPage extends StatefulWidget {
  const SavedGroupsPage({
    super.key,
    required this.tenant,
    required this.session,
    required this.im,
    required this.messaging,
    required this.media,
    required this.mediaPicker,
    this.beforeMediaUpload,
  });

  final TenantConfig tenant;
  final AppSession session;
  final AppImRuntime im;
  final AppMessagingGateway messaging;
  final AppMediaGateway media;
  final AppMediaPickerGateway mediaPicker;
  final Future<void> Function(int size)? beforeMediaUpload;

  @override
  State<SavedGroupsPage> createState() => _SavedGroupsPageState();
}

final class _SavedGroupsPageState extends State<SavedGroupsPage> {
  List<AppImConversation> _groups = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final conversations = await widget.messaging.fetchConversations(
        tenant: widget.tenant,
        session: widget.session,
      );
      if (mounted) {
        setState(() {
          _groups = conversations
              .where((item) => item.conversationType == 2)
              .toList(growable: false);
          _error = null;
        });
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('群聊')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? _ContactStateCard(
              icon: Icons.error_outline_rounded,
              message: _error!,
              onRetry: _load,
            )
          : _groups.isEmpty
          ? const B8EmptyState(
              icon: Icons.forum_outlined,
              title: '暂无群聊',
              message: '加入或创建群聊后会显示在这里',
            )
          : ListView.separated(
              padding: const EdgeInsets.all(20),
              itemCount: _groups.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final group = _groups[index];
                return Card(
                  child: ListTile(
                    key: ValueKey('group-${group.conversationId}'),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 6,
                    ),
                    leading: B8Avatar(
                      label: group.title,
                      imageUrl: group.avatarUrl,
                    ),
                    title: Text(group.title),
                    subtitle: Text(
                      group.lastMessageSummary.isEmpty
                          ? '暂无消息'
                          : group.lastMessageSummary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) => ConversationPage(
                          tenant: widget.tenant,
                          session: widget.session,
                          im: widget.im,
                          messaging: widget.messaging,
                          media: widget.media,
                          mediaPicker: widget.mediaPicker,
                          beforeMediaUpload: widget.beforeMediaUpload,
                          conversation: group,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

final class _ContactStateCard extends StatelessWidget {
  const _ContactStateCard({
    required this.icon,
    required this.message,
    this.onRetry,
  });

  final IconData icon;
  final String message;
  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Icon(icon, color: B8Colors.muted, size: 34),
            const SizedBox(height: 10),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: B8Colors.muted),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 12),
              TextButton(onPressed: onRetry, child: const Text('重试')),
            ],
          ],
        ),
      ),
    );
  }
}
