// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matrix/matrix.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/allora_avatar.dart';
import '../../core/widgets/empty_state.dart';
import '../../core/widgets/skeleton.dart';
import '../../data/services/connection_manager.dart';
import '../../data/services/disappearing_message_service.dart';
import '../../data/services/room_wipe_service.dart';
import '../../data/settings/app_settings.dart';
import '../../data/settings/labels.dart';
import '../labels/labels_management_screen.dart';
import '../../providers/network_provider.dart';
import '../../screens/connection_screen/connect_networks_screen.dart';
import '../../screens/networks/network_meta.dart';
import '../bridge/providers/bridge_health_provider.dart';
import '../bridge/widgets/bridge_status_banner.dart';
import '../ai/ai_chat_screen.dart';
import '../status/status_screen.dart';
import '../chat/chat_screen.dart';
import '../chat/widgets/disappearing_sheet.dart';
import '../search/global_search_screen.dart';
import '../settings/settings_screen.dart';
import 'archived_chats_screen.dart';
import 'chat_list_providers.dart';
import 'widgets/chat_tile.dart';
import 'widgets/platform_sidebar_drawer.dart';

class ChatListScreen extends ConsumerStatefulWidget {
  const ChatListScreen({super.key});

  @override
  ConsumerState<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends ConsumerState<ChatListScreen> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();
  int _currentNavIndex = 0;

  @override
  void initState() {
    super.initState();
    Future.microtask(
        () => ref.read(connectionManagerProvider.notifier).probeNetworks());
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _openChat(ChatEntry entry) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ChatScreen(room: entry.room)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final client = ref.watch(matrixClientProvider);
    final data = ref.watch(chatListProvider);
    final conn = ref.watch(connectionManagerProvider);
    final wiping = ref.watch(wipePendingProvider);
    final firstSyncDone = client.prevBatch != null;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final canvasBg = isDark ? const Color(0xFF0E1015) : const Color(0xFFF8F9FA);

    return Scaffold(
      key: _scaffoldKey,
      drawer: PlatformSidebarDrawer(client: client),
      backgroundColor: canvasBg,
      bottomNavigationBar: _ExecutiveBottomNavBar(
        currentIndex: _currentNavIndex,
        onTabSelected: (index) {
          if (index == 0) {
            setState(() => _currentNavIndex = 0);
          } else if (index == 1) {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const GlobalSearchScreen()),
            );
          } else if (index == 2) {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const StatusScreen()),
            );
          } else if (index == 3) {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            );
          }
        },
      ),
      body: SafeArea(
        bottom: false,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () => FocusScope.of(context).unfocus(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Header: Allora logo + Search & Compose actions ──
              _ExecutiveHeader(
                onSearchTap: () => _searchFocus.requestFocus(),
                onNewChatTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const GlobalSearchScreen()),
                ),
                onMenuTap: () => _scaffoldKey.currentState?.openDrawer(),
              ),



              // ── Filter Pills: All | Unread | Priority | Archived ──
              const _FilterPillsBar(),

              // ── Search Input: "Search conversations..." ──
              _ExecutiveSearchBar(
                controller: _searchController,
                focusNode: _searchFocus,
                onChanged: (v) =>
                    ref.read(chatSearchQueryProvider.notifier).state = v,
                onClear: () {
                  _searchController.clear();
                  ref.read(chatSearchQueryProvider.notifier).state = '';
                },
              ),

              // ── Banners & Bridge Health (if active) ──
              if (wiping.isNotEmpty) _WipeBanner(count: wiping.length),
              if (!conn.matrix.isHealthy &&
                  conn.matrix != ConnState.connecting)
                _ConnectionBanner(state: conn.matrix),
              Consumer(
                builder: (context, ref, _) {
                  final health = ref.watch(bridgeHealthProvider('whatsapp'));
                  return BridgeStatusBanner(
                    networkName: 'WhatsApp',
                    health: health,
                    onTapReconnect: () => openNetworkConnectFlow(
                      context,
                      client,
                      NetworkId.whatsapp,
                    ),
                  );
                },
              ),

              // ── Conversation Feed (PINNED Card + Conversation List) ──
              Expanded(
                child: !firstSyncDone
                    ? const ChatListSkeleton()
                    : data.isEmpty
                        ? _emptyState(client)
                        : _buildList(data),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _emptyState(Client client) {
    final query = ref.watch(chatSearchQueryProvider);
    final filter = ref.watch(chatFilterProvider);

    if (query.trim().isNotEmpty) {
      return EmptyState(
        icon: Icons.search_off_rounded,
        title: 'No results',
        message: 'No chats match "$query".',
      );
    }
    if (filter == ChatFilter.unread) {
      return const EmptyState(
        icon: Icons.mark_chat_read_rounded,
        title: 'All caught up',
        message: 'You have no unread messages right now.',
      );
    }
    if (filter == ChatFilter.archived) {
      return const EmptyState(
        icon: Icons.archive_outlined,
        title: 'No archived chats',
        message: 'Swipe any chat left to archive it.',
      );
    }
    final netFilter = ref.watch(networkFilterProvider);
    if (netFilter != null) {
      final meta = metaFor(netFilter);
      return EmptyState(
        icon: Icons.chat_bubble_outline_rounded,
        title: 'No ${meta.displayName} conversations',
        message: 'No messages found for ${meta.displayName}.',
        actionLabel: 'Show all conversations',
        onAction: () => ref.read(networkFilterProvider.notifier).state = null,
      );
    }
    return EmptyState(
      icon: Icons.forum_rounded,
      title: 'Your inbox is quiet',
      message:
          'Connect WhatsApp, Telegram, Instagram, Slack and more to read and '
          'reply to everything from Allora.',
      actionLabel: 'Connect a network',
      onAction: () => Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => ConnectNetworksScreen(client: client))),
    );
  }

  Widget _buildList(ChatListData data) {
    final filter = ref.watch(chatFilterProvider);
    final query = ref.watch(chatSearchQueryProvider);
    final isSearching = query.trim().isNotEmpty;

    // Resolve pinned contacts for the PINNED section card (max 4)
    final pinnedContacts = data.pinned.take(4).toList();
    final showPinnedSection = !isSearching &&
        filter == ChatFilter.all &&
        pinnedContacts.isNotEmpty;

    // Pinned conversations appear at the top of the list
    final conversationList = [...data.pinned, ...data.chats];

    return CustomScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics()),
      slivers: [
        // ── PINNED Card Section ──
        if (showPinnedSection) ...[
          SliverToBoxAdapter(
            child: _PinnedSectionCard(
              contacts: pinnedContacts,
              onOpenChat: _openChat,
              onLongPressChat: _showChatMenu,
            ),
          ),
        ],

        // ── Main Conversations List ──
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) {
              if (index >= conversationList.length) {
                return const SizedBox(height: 32);
              }
              final entry = conversationList[index];
              return _tile(entry);
            },
            childCount: conversationList.length + 1,
          ),
        ),
      ],
    );
  }

  Widget _tile(ChatEntry entry) {
    final c = context.allora;
    return RepaintBoundary(
      key: ValueKey(entry.room.id),
      child: Dismissible(
        key: ValueKey('swipe_${entry.room.id}'),
        confirmDismiss: (direction) async {
          HapticFeedback.lightImpact();
          if (direction == DismissDirection.startToEnd) {
            await _toggleRead(entry);
            return false;
          }
          _archive(entry);
          return false;
        },
        background: _SwipeAction(
          alignment: Alignment.centerLeft,
          color: const Color(0xFF1E2238),
          icon: entry.isUnread
              ? Icons.mark_chat_read_rounded
              : Icons.mark_chat_unread_rounded,
          label: entry.isUnread ? 'Read' : 'Unread',
        ),
        secondaryBackground: _SwipeAction(
          alignment: Alignment.centerRight,
          color: c.textSecondary,
          icon: Icons.archive_rounded,
          label: 'Archive',
        ),
        child: ChatTile(
          entry: entry,
          onTap: () => _openChat(entry),
          onLongPress: () => _showChatMenu(entry),
        ),
      ),
    );
  }

  Future<void> _toggleRead(ChatEntry entry) async {
    final room = entry.room;
    try {
      if (entry.isUnread) {
        Event? target = room.lastEvent;
        if (target != null && target.eventId.startsWith('AlloraClient-')) {
          target = null;
        }
        if (target != null &&
            !ref.read(settingsProvider).effectiveHideReadReceipts) {
          await room.setReadMarker(target.eventId, mRead: target.eventId);
        }
        await room.markUnread(false);
      } else {
        await room.markUnread(true);
      }
    } catch (e) {
      debugPrint('toggleRead failed: $e');
    }
  }

  void _archive(ChatEntry entry) {
    ref.read(settingsProvider.notifier).setArchived(entry.room.id, true);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('${entry.title} archived'),
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () => ref
            .read(settingsProvider.notifier)
            .setArchived(entry.room.id, false),
      ),
    ));
  }

  void _showChatMenu(ChatEntry entry) {
    HapticFeedback.mediumImpact();
    final c = context.allora;
    final settings = ref.read(settingsProvider.notifier);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.72),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                  child: Row(
                    children: [
                      AlloraAvatar(
                        name: entry.title,
                        mxcUri: entry.room.avatar,
                        client: entry.room.client,
                        size: 44,
                        network: entry.network,
                        showNetworkBadge: true,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              entry.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: c.text,
                              ),
                            ),
                            if (entry.network != null)
                              Text(
                                entry.network!.displayName,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  color: c.textSecondary,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Divider(color: c.outline),
                _menuItem(
                  ctx,
                  icon: entry.pinned
                      ? Icons.push_pin_outlined
                      : Icons.push_pin_rounded,
                  label: entry.pinned ? 'Unpin conversation' : 'Pin conversation',
                  onTap: () {
                    final ok = settings.togglePinned(entry.room.id);
                    if (!ok && mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: const Text(
                              'You can only pin up to 4 chats. Please unpin a chat first.'),
                          behavior: SnackBarBehavior.floating,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                      );
                    }
                  },
                ),
                _menuItem(
                  ctx,
                  icon: entry.muted
                      ? Icons.notifications_active_rounded
                      : Icons.notifications_off_rounded,
                  label: entry.muted ? 'Unmute' : 'Mute',
                  onTap: () async {
                    try {
                      await entry.room.setPushRuleState(entry.muted
                          ? PushRuleState.notify
                          : PushRuleState.dontNotify);
                    } catch (e) {
                      debugPrint('mute failed: $e');
                    }
                  },
                ),
                _menuItem(
                  ctx,
                  icon: entry.isUnread
                      ? Icons.mark_chat_read_rounded
                      : Icons.mark_chat_unread_rounded,
                  label: entry.isUnread ? 'Mark as read' : 'Mark as unread',
                  onTap: () => _toggleRead(entry),
                ),
                _menuItem(
                  ctx,
                  icon: Icons.timer_outlined,
                  label: 'Disappearing messages',
                  trailing: DisappearingMessageService.labelFor(ref
                          .read(settingsProvider)
                          .disappearingSeconds[entry.room.id] ??
                      0),
                  onTap: () => showDisappearingSheet(context, ref, entry.room),
                ),
                _menuItem(
                  ctx,
                  icon: Icons.label_outline_rounded,
                  label: 'Labels',
                  trailing: entry.labels.isEmpty
                      ? null
                      : entry.labels.map((l) => l.name).join(', '),
                  onTap: () => showAssignLabelsSheet(
                      context, ref, entry.room.id, entry.title),
                ),
                _menuItem(
                  ctx,
                  icon: Icons.archive_outlined,
                  label: 'Archive conversation',
                  onTap: () => _archive(entry),
                ),
                _menuItem(
                  ctx,
                  icon: Icons.visibility_off_outlined,
                  label: 'Hide chat',
                  onTap: () {
                    settings.setHidden(entry.room.id, true);
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text(
                            'Hidden. Reveal it from Settings → Privacy → Hidden chats.')));
                  },
                ),
                _menuItem(
                  ctx,
                  icon: Icons.delete_outline_rounded,
                  label: 'Delete chat',
                  destructive: true,
                  onTap: () => _confirmDelete(entry),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _menuItem(
    BuildContext sheetContext, {
    required IconData icon,
    required String label,
    String? trailing,
    bool destructive = false,
    required VoidCallback onTap,
  }) {
    final c = context.allora;
    final color = destructive ? c.danger : c.text;
    return ListTile(
      leading: Icon(icon, color: destructive ? c.danger : c.textSecondary),
      title: Text(label,
          style: TextStyle(
              color: color, fontSize: 15, fontWeight: FontWeight.w500)),
      trailing: trailing != null
          ? Text(trailing,
              style: TextStyle(color: c.textTertiary, fontSize: 13))
          : null,
      onTap: () {
        Navigator.pop(sheetContext);
        onTap();
      },
    );
  }

  void _confirmDelete(ChatEntry entry) {
    final c = context.allora;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete chat?'),
        content: Text(
          'This removes "${entry.title}" from Allora. If the conversation is '
          'bridged, it stays on the original network.',
          style: TextStyle(color: c.textSecondary, height: 1.4),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await RoomWipeService.enqueue(
                  entry.room.client, [entry.room.id]);
              ref.read(settingsProvider.notifier).forgetRooms([entry.room.id]);
              ref.read(labelsProvider.notifier).forgetRooms([entry.room.id]);
            },
            child: Text('Delete', style: TextStyle(color: c.danger)),
          ),
        ],
      ),
    );
  }
}

// ─── Header: Editorial Allora logo + Platforms & Actions ─────────────────────

class _ExecutiveHeader extends ConsumerWidget {
  final VoidCallback onSearchTap;
  final VoidCallback onNewChatTap;
  final VoidCallback onMenuTap;

  const _ExecutiveHeader({
    required this.onSearchTap,
    required this.onNewChatTap,
    required this.onMenuTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final titleColor = isDark ? const Color(0xFFF8FAFC) : const Color(0xFF0F172A);
    final iconColor = isDark ? const Color(0xFFF1F5F9) : const Color(0xFF1E293B);
    final aiEnabled = ref.watch(settingsProvider.select((s) => s.aiEnabled));
    final activeNetwork = ref.watch(networkFilterProvider);
    final activeMeta = activeNetwork != null ? metaFor(activeNetwork) : null;
    final hub = ref.watch(networkHubProvider);
    final connectedCount = hub.networks
        .where((n) => n.status == NetworkStatus.connected)
        .length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Social platforms sidebar trigger button
          IconButton(
            icon: Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(Icons.menu_rounded, size: 26, color: iconColor),
                if (activeMeta != null)
                  Positioned(
                    right: -1,
                    top: -1,
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: activeMeta.brandColor,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Theme.of(context).scaffoldBackgroundColor,
                          width: 1.5,
                        ),
                      ),
                    ),
                  )
                else if (connectedCount > 0)
                  Positioned(
                    right: -1,
                    top: -1,
                    child: Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: const Color(0xFF1F9D55),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Theme.of(context).scaffoldBackgroundColor,
                          width: 1.5,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            tooltip: 'Social Platforms Sidebar',
            splashRadius: 22,
            onPressed: onMenuTap,
          ),
          const SizedBox(width: 4),

          // High-fashion / Editorial Allora Logo
          Text(
            'Allora',
            style: TextStyle(
              fontSize: 34,
              fontWeight: FontWeight.w700,
              fontFamily: 'serif',
              letterSpacing: -0.7,
              color: titleColor,
            ),
          ),

          const Spacer(),

          // Allora AI action (if enabled)
          if (aiEnabled)
            IconButton(
              icon: const Icon(Icons.auto_awesome_rounded,
                  size: 21, color: Color(0xFF7C5CFC)),
              tooltip: 'Allora AI',
              splashRadius: 22,
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const AiChatScreen()),
              ),
            ),

          // Search quick-focus icon button
          IconButton(
            icon: Icon(Icons.search_rounded, size: 24, color: iconColor),
            tooltip: 'Search',
            splashRadius: 22,
            onPressed: onSearchTap,
          ),

          // Compose / New Message icon button
          IconButton(
            icon: Icon(Icons.edit_square, size: 22, color: iconColor),
            tooltip: 'New conversation',
            splashRadius: 22,
            onPressed: onNewChatTap,
          ),
        ],
      ),
    );
  }
}

// ─── Filter Pills Bar: [ All ] [ Unread ] [ Priority ] [ Archived ] ─────────

class _FilterPillsBar extends ConsumerWidget {
  const _FilterPillsBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentFilter = ref.watch(chatFilterProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final filters = [
      (filter: ChatFilter.all, label: 'All'),
      (filter: ChatFilter.unread, label: 'Unread'),
      (filter: ChatFilter.priority, label: 'Priority'),
      (filter: ChatFilter.archived, label: 'Archived'),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 12),
      child: Row(
        children: filters.map((item) {
          final isSelected = currentFilter == item.filter;
          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3.5),
              child: GestureDetector(
                onTap: () {
                  HapticFeedback.selectionClick();
                  ref.read(chatFilterProvider.notifier).state = item.filter;
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOutCubic,
                  height: 36,
                  decoration: BoxDecoration(
                    color: isSelected
                        ? (isDark
                            ? const Color(0xFF7C5CFC)
                            : const Color(0xFF1E2238))
                        : (isDark
                            ? const Color(0xFF171920)
                            : Colors.white),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: isSelected
                          ? Colors.transparent
                          : (isDark
                              ? const Color(0xFF242732)
                              : const Color(0xFFE8EAED)),
                      width: 1,
                    ),
                    boxShadow: isSelected
                        ? [
                            BoxShadow(
                              color: (isDark
                                      ? const Color(0xFF7C5CFC)
                                      : const Color(0xFF1E2238))
                                  .withValues(alpha: 0.28),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ]
                        : null,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    item.label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight:
                          isSelected ? FontWeight.w700 : FontWeight.w600,
                      color: isSelected
                          ? Colors.white
                          : (isDark
                              ? const Color(0xFF94A3B8)
                              : const Color(0xFF64748B)),
                    ),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

// ─── Executive Search Bar: "Search conversations..." ─────────────────────────

class _ExecutiveSearchBar extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  const _ExecutiveSearchBar({
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isSearching = controller.text.isNotEmpty;

    final fillBg = isDark ? const Color(0xFF171920) : Colors.white;
    final borderColor = isDark ? const Color(0xFF242732) : const Color(0xFFEEF0F4);
    final iconColor = const Color(0xFF94A3B8);
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: fillBg,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: borderColor, width: 1),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF0F172A)
                  .withValues(alpha: isDark ? 0.25 : 0.03),
              blurRadius: 10,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            Icon(Icons.search_rounded, size: 20, color: iconColor),
            const SizedBox(width: 9),
            Expanded(
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                onChanged: onChanged,
                textInputAction: TextInputAction.search,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: textColor,
                ),
                decoration: InputDecoration(
                  hintText: 'Search conversations...',
                  hintStyle: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w400,
                    color: iconColor,
                  ),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  disabledBorder: InputBorder.none,
                  errorBorder: InputBorder.none,
                  focusedErrorBorder: InputBorder.none,
                  filled: false,
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ),
            if (isSearching)
              GestureDetector(
                onTap: onClear,
                child: Icon(Icons.cancel_rounded, size: 18, color: iconColor),
              ),
          ],
        ),
      ),
    );
  }
}

// ─── PINNED Section Card ────────────────────────────────────────────────────

class _PinnedSectionCard extends StatelessWidget {
  final List<ChatEntry> contacts;
  final ValueChanged<ChatEntry> onOpenChat;
  final ValueChanged<ChatEntry>? onLongPressChat;

  const _PinnedSectionCard({
    required this.contacts,
    required this.onOpenChat,
    this.onLongPressChat,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardBg = isDark ? const Color(0xFF171920) : Colors.white;
    final borderColor = isDark ? const Color(0xFF242732) : const Color(0xFFEEF0F4);
    final headerColor = isDark ? const Color(0xFF64748B) : const Color(0xFF8E95A5);
    final titleColor = isDark ? const Color(0xFFF8FAFC) : const Color(0xFF0F172A);

    // Strictly maximum 4 pinned chats
    final pinnedList = contacts.take(4).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Section Header: PINNED (X/4) •••
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 16, 6),
          child: Row(
            children: [
              Text(
                'PINNED (${pinnedList.length}/4)',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                  color: headerColor,
                ),
              ),
              const Spacer(),
              PopupMenuButton<String>(
                icon: Icon(
                  Icons.more_horiz_rounded,
                  size: 20,
                  color: headerColor,
                ),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
                onSelected: (val) {
                  if (val == 'archived') {
                    Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const ArchivedChatsScreen()));
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'archived',
                    child: Row(
                      children: [
                        Icon(Icons.archive_outlined, size: 18),
                        SizedBox(width: 8),
                        Text('Archived conversations'),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),

        // Elevated Rounded Card
        Container(
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 14),
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 10),
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: borderColor, width: 1),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF0F172A)
                    .withValues(alpha: isDark ? 0.35 : 0.04),
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: pinnedList.map((entry) {
              final firstName = entry.title.split(' ').first;

              return Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    HapticFeedback.lightImpact();
                    onOpenChat(entry);
                  },
                  onLongPress: () {
                    HapticFeedback.mediumImpact();
                    onLongPressChat?.call(entry);
                  },
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Avatar with platform badge
                      AlloraAvatar(
                        name: entry.title,
                        mxcUri: AlloraAvatar.resolveUri(entry.room),
                        client: entry.room.client,
                        size: 56,
                        network: entry.network,
                        showNetworkBadge: true,
                      ),
                      const SizedBox(height: 7),
                      // First Name
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: Text(
                          firstName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: titleColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }
}



// ─── Bottom Navigation Bar: Chats | Contacts | Activity | Settings ───────────

class _ExecutiveBottomNavBar extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTabSelected;

  const _ExecutiveBottomNavBar({
    required this.currentIndex,
    required this.onTabSelected,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final navBg = isDark ? const Color(0xFF12141A) : Colors.white;
    final borderColor = isDark ? const Color(0xFF1E212A) : const Color(0xFFEEF0F4);

    final activeColor = isDark ? Colors.white : const Color(0xFF1E2238);
    final inactiveColor = isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8);

    return Container(
      decoration: BoxDecoration(
        color: navBg,
        border: Border(top: BorderSide(color: borderColor, width: 1)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.03),
            blurRadius: 10,
            offset: const Offset(0, -3),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _NavItem(
                icon: Icons.chat_bubble_outline_rounded,
                activeIcon: Icons.chat_bubble_rounded,
                label: 'Chats',
                isSelected: currentIndex == 0,
                activeColor: activeColor,
                inactiveColor: inactiveColor,
                onTap: () => onTabSelected(0),
              ),
              _NavItem(
                icon: Icons.people_outline_rounded,
                activeIcon: Icons.people_rounded,
                label: 'Contacts',
                isSelected: currentIndex == 1,
                activeColor: activeColor,
                inactiveColor: inactiveColor,
                onTap: () => onTabSelected(1),
              ),
              _NavItem(
                icon: Icons.notifications_none_rounded,
                activeIcon: Icons.notifications_rounded,
                label: 'Activity',
                isSelected: currentIndex == 2,
                activeColor: activeColor,
                inactiveColor: inactiveColor,
                onTap: () => onTabSelected(2),
              ),
              _NavItem(
                icon: Icons.settings_outlined,
                activeIcon: Icons.settings_rounded,
                label: 'Settings',
                isSelected: currentIndex == 3,
                activeColor: activeColor,
                inactiveColor: inactiveColor,
                onTap: () => onTabSelected(3),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool isSelected;
  final Color activeColor;
  final Color inactiveColor;
  final VoidCallback onTap;

  const _NavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.isSelected,
    required this.activeColor,
    required this.inactiveColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isSelected ? activeIcon : icon,
              size: 24,
              color: isSelected ? activeColor : inactiveColor,
            ),
            const SizedBox(height: 3),
            Text(
              label,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                color: isSelected ? activeColor : inactiveColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Banners & Status Bits ──────────────────────────────────────────────────

class _WipeBanner extends StatelessWidget {
  final int count;
  const _WipeBanner({required this.count});

  @override
  Widget build(BuildContext context) {
    final c = context.allora;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 2, 16, 6),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: c.accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2, color: c.accent),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Removing $count disconnected ${count == 1 ? 'chat' : 'chats'}…',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: c.accent,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ConnectionBanner extends StatelessWidget {
  final ConnState state;
  const _ConnectionBanner({required this.state});

  @override
  Widget build(BuildContext context) {
    final c = context.allora;
    final isError = state == ConnState.error || state == ConnState.expired;
    final color = isError ? c.danger : c.warning;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 2, 16, 6),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            isError ? Icons.cloud_off_rounded : Icons.sync_rounded,
            size: 16,
            color: color,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              state == ConnState.expired
                  ? 'Session expired — please sign in again'
                  : state == ConnState.error
                      ? 'Can\u2019t reach Allora — retrying automatically'
                      : state.label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SwipeAction extends StatelessWidget {
  final Alignment alignment;
  final Color color;
  final IconData icon;
  final String label;

  const _SwipeAction({
    required this.alignment,
    required this.color,
    required this.icon,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: color,
      alignment: alignment,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: Colors.white, size: 22),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
