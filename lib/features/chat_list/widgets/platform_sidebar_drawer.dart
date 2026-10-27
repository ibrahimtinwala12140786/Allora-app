import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matrix/matrix.dart';

import '../../../core/theme/app_theme.dart';
import '../../../providers/network_provider.dart';
import '../../../screens/connection_screen/connect_networks_screen.dart';
import '../../../screens/networks/network_meta.dart';
import '../chat_list_providers.dart';

/// An executive sidebar drawer that displays all connected social platforms,
/// their connection and sync status, unread message counts, and allows
/// filtering the chat list to a specific platform or viewing all platforms.
class PlatformSidebarDrawer extends ConsumerWidget {
  final Client client;

  const PlatformSidebarDrawer({
    super.key,
    required this.client,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.allora;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final hub = ref.watch(networkHubProvider);
    final activeFilter = ref.watch(networkFilterProvider);
    final unreadCounts = ref.watch(unreadCountsPerNetworkProvider);
    final chatData = ref.watch(chatListProvider);

    final connectedNetworks = hub.networks
        .where((n) => n.status == NetworkStatus.connected)
        .toList();
    final otherNetworks = hub.networks
        .where((n) => n.status != NetworkStatus.connected)
        .toList();

    final drawerBg = isDark ? const Color(0xFF13151B) : Colors.white;
    final cardBg = isDark ? const Color(0xFF1B1E27) : const Color(0xFFF7F8FA);
    final borderColor = isDark ? const Color(0xFF262A37) : const Color(0xFFE9ECF2);
    final sectionTitleColor = isDark ? const Color(0xFF7E889B) : const Color(0xFF8A93A6);

    return Drawer(
      backgroundColor: drawerBg,
      surfaceTintColor: Colors.transparent,
      elevation: 16,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.horizontal(right: Radius.circular(24)),
      ),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ─── Header: Allora Branding & Close Button ──────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
              child: Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          c.accent,
                          c.accent.withValues(alpha: 0.75),
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: c.accent.withValues(alpha: 0.35),
                          blurRadius: 10,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.hub_rounded,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Platforms',
                          style: TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.3,
                            color: c.text,
                          ),
                        ),
                        Text(
                          '${connectedNetworks.length} connected · ${chatData.chats.length + chatData.pinned.length} chats',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: c.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.close_rounded, size: 22, color: c.textSecondary),
                    splashRadius: 20,
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),

            Divider(color: borderColor, height: 1),

            // ─── Scrollable Platforms List ──────────────────────────────────
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                physics: const BouncingScrollPhysics(),
                children: [
                  // ── All Platforms (Unified Inbox) ──
                  _PlatformFilterTile(
                    isSelected: activeFilter == null,
                    glyph: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: activeFilter == null
                            ? c.accent
                            : (isDark ? const Color(0xFF232733) : const Color(0xFFECEEF2)),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        Icons.all_inbox_rounded,
                        color: activeFilter == null ? Colors.white : c.textSecondary,
                        size: 20,
                      ),
                    ),
                    title: 'All Platforms',
                    subtitle: 'Unified inbox with all messages',
                    unreadCount: chatData.totalUnread,
                    isDark: isDark,
                    onTap: () {
                      HapticFeedback.selectionClick();
                      ref.read(networkFilterProvider.notifier).state = null;
                      Navigator.pop(context);
                    },
                  ),

                  const SizedBox(height: 18),

                  // ── Section: Connected Platforms ──
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                    child: Row(
                      children: [
                        Text(
                          'CONNECTED PLATFORMS',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.1,
                            color: sectionTitleColor,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: c.success,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          '${connectedNetworks.length}',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: sectionTitleColor,
                          ),
                        ),
                      ],
                    ),
                  ),

                  if (connectedNetworks.isEmpty) ...[
                    Container(
                      margin: const EdgeInsets.symmetric(vertical: 8),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: cardBg,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: borderColor),
                      ),
                      child: Column(
                        children: [
                          Icon(Icons.sensors_off_rounded,
                              size: 32, color: c.textTertiary),
                          const SizedBox(height: 8),
                          Text(
                            'No platforms connected yet',
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w700,
                              color: c.text,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Connect WhatsApp, Instagram, or Telegram below to view chats.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 12,
                              color: c.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ] else ...[
                    ...connectedNetworks.map((net) {
                      final isSelected = activeFilter == net.meta.id;
                      final unread = unreadCounts[net.meta.id] ?? 0;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: _PlatformFilterTile(
                          isSelected: isSelected,
                          glyph: _PlatformGlyph(meta: net.meta),
                          title: net.meta.displayName,
                          subtitle: net.accountLabel != null &&
                                  net.accountLabel!.isNotEmpty
                              ? net.accountLabel!
                              : 'Connected · Tap to view',
                          statusColor: c.success,
                          unreadCount: unread,
                          isDark: isDark,
                          onTap: () {
                            HapticFeedback.selectionClick();
                            ref.read(networkFilterProvider.notifier).state =
                                net.meta.id;
                            Navigator.pop(context);
                          },
                        ),
                      );
                    }),
                  ],

                  const SizedBox(height: 18),

                  // ── Section: Available to Connect ──
                  if (otherNetworks.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                      child: Row(
                        children: [
                          Text(
                            'AVAILABLE TO CONNECT',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1.1,
                              color: sectionTitleColor,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            '${otherNetworks.length}',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: sectionTitleColor,
                            ),
                          ),
                        ],
                      ),
                    ),
                    ...otherNetworks.map((net) {
                      final isComingSoon =
                          net.status == NetworkStatus.comingSoon;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: _PlatformConnectTile(
                          net: net,
                          isDark: isDark,
                          onTap: isComingSoon
                              ? null
                              : () {
                                  Navigator.pop(context);
                                  openNetworkConnectFlow(
                                    context,
                                    client,
                                    net.meta.id,
                                    onConnected: () => ref
                                        .read(networkHubProvider.notifier)
                                        .refreshCache(),
                                  );
                                },
                        ),
                      );
                    }),
                  ],
                ],
              ),
            ),

            // ─── Footer: Manage Accounts Action ─────────────────────────────
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF101217) : const Color(0xFFF9FAFC),
                border: Border(top: BorderSide(color: borderColor)),
              ),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.settings_outlined, size: 18),
                  label: const Text(
                    'Manage Connected Accounts',
                    style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: c.text,
                    side: BorderSide(color: borderColor),
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  onPressed: () {
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ConnectNetworksScreen(client: client),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Sub-widgets ─────────────────────────────────────────────────────────────

class _PlatformFilterTile extends StatelessWidget {
  final bool isSelected;
  final Widget glyph;
  final String title;
  final String subtitle;
  final Color? statusColor;
  final int unreadCount;
  final bool isDark;
  final VoidCallback onTap;

  const _PlatformFilterTile({
    required this.isSelected,
    required this.glyph,
    required this.title,
    required this.subtitle,
    this.statusColor,
    required this.unreadCount,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.allora;
    final selectedBg = c.accent.withValues(alpha: isDark ? 0.16 : 0.08);
    final selectedBorder = c.accent.withValues(alpha: 0.45);
    final idleBorder = isDark ? const Color(0xFF222632) : const Color(0xFFEEF0F5);
    final idleBg = isDark ? const Color(0xFF171A22) : Colors.white;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          decoration: BoxDecoration(
            color: isSelected ? selectedBg : idleBg,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isSelected ? selectedBorder : idleBorder,
              width: isSelected ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              glyph,
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Text(
                          title,
                          style: TextStyle(
                            fontSize: 14.5,
                            fontWeight: isSelected ? FontWeight.w700 : FontWeight.w600,
                            color: isSelected ? c.accent : c.text,
                          ),
                        ),
                        if (statusColor != null) ...[
                          const SizedBox(width: 6),
                          Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: statusColor,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: isSelected
                            ? c.accent.withValues(alpha: 0.85)
                            : c.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              if (unreadCount > 0) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                  decoration: BoxDecoration(
                    color: c.accent,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    unreadCount > 99 ? '99+' : '$unreadCount',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
              ],
              if (isSelected)
                Icon(Icons.check_circle_rounded, color: c.accent, size: 19)
              else
                Icon(Icons.chevron_right_rounded,
                    color: c.textTertiary, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlatformConnectTile extends StatelessWidget {
  final NetworkAccount net;
  final bool isDark;
  final VoidCallback? onTap;

  const _PlatformConnectTile({
    required this.net,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.allora;
    final isComingSoon = net.status == NetworkStatus.comingSoon;
    final cardBg = isDark ? const Color(0xFF151820) : const Color(0xFFFAFAFC);
    final borderColor = isDark ? const Color(0xFF222530) : const Color(0xFFEEF0F5);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: borderColor),
          ),
          child: Row(
            children: [
              Opacity(
                opacity: isComingSoon ? 0.4 : 0.85,
                child: _PlatformGlyph(meta: net.meta),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      net.meta.displayName,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: isComingSoon ? c.textTertiary : c.text,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      isComingSoon ? 'Coming soon' : 'Not connected',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: c.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
              if (isComingSoon)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF252834) : const Color(0xFFE8EAEE),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'Soon',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      color: c.textTertiary,
                    ),
                  ),
                )
              else
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4.5),
                  decoration: BoxDecoration(
                    color: c.accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: c.accent.withValues(alpha: 0.3),
                      width: 1,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.add_rounded, size: 14, color: c.accent),
                      const SizedBox(width: 3),
                      Text(
                        'Connect',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: c.accent,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlatformGlyph extends StatelessWidget {
  final NetworkMeta meta;

  const _PlatformGlyph({required this.meta});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: meta.brandColor,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: meta.brandColor.withValues(alpha: 0.25),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Center(
        child: meta.asset != null
            ? Padding(
                padding: const EdgeInsets.all(8),
                child: Image.asset(meta.asset!),
              )
            : Icon(meta.icon ?? Icons.chat_bubble_rounded,
                color: Colors.white, size: 18),
      ),
    );
  }
}
