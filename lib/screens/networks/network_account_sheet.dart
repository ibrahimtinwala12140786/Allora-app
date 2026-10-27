// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:matrix/matrix.dart';

import '../../core/theme/app_theme.dart';
import '../../data/services/account_lifecycle.dart';
import '../connection_screen/connect_networks_screen.dart';

import 'network_connection_cache.dart';
import 'network_meta.dart';
import '../whatsapp/whatsapp_disconnect_service.dart';
import '../../data/services/instagram_service.dart';


/// Account detail + disconnect sheet, shared by every network.
Future<void> showNetworkAccountSheet({
  required BuildContext context,
  required Client client,
  required NetworkMeta meta,
  String? accountLabel,
  String? lastSynced,
  VoidCallback? onDisconnected,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    isDismissible: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => _NetworkAccountSheet(
      client: client,
      meta: meta,
      accountLabel: accountLabel,
      lastSynced: lastSynced,
      onDisconnected: onDisconnected,
    ),
  );
}

enum _Phase { idle, confirming, working, done, error }

class _NetworkAccountSheet extends StatefulWidget {
  final Client client;
  final NetworkMeta meta;
  final String? accountLabel;
  final String? lastSynced;
  final VoidCallback? onDisconnected;

  const _NetworkAccountSheet({
    required this.client,
    required this.meta,
    this.accountLabel,
    this.lastSynced,
    this.onDisconnected,
  });

  @override
  State<_NetworkAccountSheet> createState() => _NetworkAccountSheetState();
}

class _NetworkAccountSheetState extends State<_NetworkAccountSheet> {
  _Phase _phase = _Phase.idle;
  DisconnectResult? _result;
  String? _error;
  bool _notificationsEnabled = true;

  void _disconnect() {
    HapticFeedback.heavyImpact();
    if (widget.meta.id == NetworkId.instagram) {
      InstagramService.instance.disconnect();
    }
    AccountLifecycleService.disconnectInBackground(
        widget.client, widget.meta.id);
    widget.onDisconnected?.call();
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.allora;
    return Container(
      decoration: BoxDecoration(
        color: c.canvas,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).padding.bottom + 16,
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
            child: _body(),
          ),
        ),
      ),
    );
  }

  Widget _body() {
    switch (_phase) {
      case _Phase.idle:
        return _idle();
      case _Phase.confirming:
        return _confirm();
      case _Phase.working:
        return _working();
      case _Phase.done:
        return _done();
      case _Phase.error:
        return _errorView();
    }
  }

  Widget _idle() {
    final c = context.allora;
    final isConnected = NetworkConnectionCache.get(widget.meta.id).connected;
    final displayName = widget.meta.displayName;
    final accountText = widget.accountLabel != null && widget.accountLabel!.isNotEmpty
        ? widget.accountLabel!
        : 'Connected Account';

    return Column(
      key: const ValueKey('idle'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Sheet Drag Handle
        Center(
          child: Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: c.outline,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),

        // Header Title
        Text(
          '$displayName ($accountText)',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: c.text,
          ),
        ),
        const SizedBox(height: 16),

        // Disconnected Warning Banner Card (Screenshot 3 & 4)
        if (!isConnected)
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: c.outline),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: const Color(0xFFEFF6FF),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.info_outline_rounded,
                    color: Color(0xFF2563EB),
                    size: 20,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Account Disconnected',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: c.text,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'You\'re not logged into $displayName. Relogin to continue using the connection.',
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.4,
                    color: c.textSecondary,
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  height: 44,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF2563EB),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(22),
                      ),
                    ),
                    onPressed: () {
                      Navigator.pop(context);
                      openNetworkConnectFlow(context, widget.client, widget.meta.id);
                    },
                    child: const Text(
                      'Reconnect',
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          )
        else
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: c.outline),
            ),
            child: Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: const BoxDecoration(
                    color: Color(0xFF10B981),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  'Connected and active',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: c.text,
                  ),
                ),
              ],
            ),
          ),

        const SizedBox(height: 20),

        // Profile Details Card
        Container(
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: c.outline),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              CircleAvatar(
                radius: 26,
                backgroundColor: widget.meta.brandColor,
                child: widget.meta.asset != null
                    ? Image.asset(widget.meta.asset!, width: 28, height: 28)
                    : Icon(widget.meta.icon ?? Icons.person, color: Colors.white, size: 24),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Name',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: c.textTertiary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      accountText,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: c.text,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 20),

        // Account Settings Header
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            'Account settings',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: c.textTertiary,
            ),
          ),
        ),

        // Account Settings List Card
        Container(
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: c.outline),
          ),
          child: Column(
            children: [
              ListTile(
                title: Text('Show in All Chats',
                    style: TextStyle(fontSize: 14.5, color: c.text)),
                trailing: Text('All Messages',
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: c.accent)),
              ),
              Divider(height: 1, color: c.outline, indent: 16),
              SwitchListTile(
                title: Text('Allow Notifications',
                    style: TextStyle(fontSize: 14.5, color: c.text)),
                subtitle: Text('Notify when new messages are received on this account',
                    style: TextStyle(fontSize: 12.5, color: c.textSecondary)),
                value: _notificationsEnabled,
                activeColor: c.accent,
                onChanged: (v) => setState(() => _notificationsEnabled = v),
              ),
              Divider(height: 1, color: c.outline, indent: 16),
              ListTile(
                title: Text('Manage image packs',
                    style: TextStyle(fontSize: 14.5, color: c.text)),
                subtitle: Text('Import stickers or emotes from the remote network',
                    style: TextStyle(fontSize: 12.5, color: c.textSecondary)),
                onTap: () {},
              ),
              Divider(height: 1, color: c.outline, indent: 16),
              ListTile(
                title: Text('Sync groups & rejoin chats',
                    style: TextStyle(fontSize: 14.5, color: c.text)),
                subtitle: Text('Fix missing chats or if bridge bot removed you during sync',
                    style: TextStyle(fontSize: 12.5, color: c.textSecondary)),
                trailing: Icon(Icons.sync_rounded, color: c.accent, size: 20),
                onTap: () {
                  HapticFeedback.mediumImpact();
                  if (widget.meta.id == NetworkId.whatsapp) {
                    WhatsAppDisconnectService.forceSyncGroups(widget.client, createPortals: true);
                  } else {
                    final mgmt = AccountLifecycleService.findManagementRoom(widget.client, widget.meta.id);
                    mgmt?.sendTextEvent('sync groups');
                  }
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Syncing chats with ${widget.meta.displayName}...'),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                },
              ),
            ],
          ),
        ),

        const SizedBox(height: 24),

        // Bottom Action Button: Remove Account
        SizedBox(
          height: 48,
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFDC2626),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            onPressed: () => setState(() => _phase = _Phase.confirming),
            child: const Text(
              'Remove Account',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ],
    );
  }


  Widget _confirm() {
    final c = context.allora;
    return Column(
      key: const ValueKey('confirm'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(Icons.link_off_rounded, size: 40, color: c.danger),
        const SizedBox(height: 14),
        Text(
          'Disconnect ${widget.meta.displayName}?',
          textAlign: TextAlign.center,
          style: TextStyle(
              fontSize: 18, fontWeight: FontWeight.w800, color: c.text),
        ),
        const SizedBox(height: 8),
        Text(
          'Allora will sign out your ${widget.meta.displayName} session and '
          'immediately remove every synced chat, group and file from this '
          'app. Nothing is deleted on ${widget.meta.displayName} itself.',
          textAlign: TextAlign.center,
          style: TextStyle(
              fontSize: 13.5, color: c.textSecondary, height: 1.5),
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => setState(() => _phase = _Phase.idle),
                child: const Text('Cancel'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: c.danger),
                onPressed: _disconnect,
                child: const Text('Disconnect'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _working() {
    final c = context.allora;
    return Column(
      key: const ValueKey('working'),
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 10),
        SizedBox(
          width: 40,
          height: 40,
          child: CircularProgressIndicator(strokeWidth: 3, color: c.accent),
        ),
        const SizedBox(height: 18),
        Text('Disconnecting…',
            style: TextStyle(
                fontSize: 16, fontWeight: FontWeight.w700, color: c.text)),
        const SizedBox(height: 6),
        Text(
          'Signing out and removing synced chats',
          style: TextStyle(fontSize: 13, color: c.textSecondary),
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _done() {
    final c = context.allora;
    final result = _result!;
    return Column(
      key: const ValueKey('done'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: const Duration(milliseconds: 450),
          curve: Curves.elasticOut,
          builder: (context, t, child) =>
              Transform.scale(scale: t, child: child),
          child: Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              color: c.success.withValues(alpha: 0.14),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.check_rounded, size: 32, color: c.success),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'Disconnected',
          textAlign: TextAlign.center,
          style: TextStyle(
              fontSize: 18, fontWeight: FontWeight.w800, color: c.text),
        ),
        const SizedBox(height: 8),
        Text(
          result.userMessage +
              (result.roomsWiped > 0
                  ? ' ${result.roomsWiped} ${result.roomsWiped == 1 ? 'chat is' : 'chats are'} being removed now.'
                  : ''),
          textAlign: TextAlign.center,
          style: TextStyle(
              fontSize: 13.5, color: c.textSecondary, height: 1.5),
        ),
        const SizedBox(height: 18),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }

  Widget _errorView() {
    final c = context.allora;
    return Column(
      key: const ValueKey('error'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(Icons.error_outline_rounded, size: 40, color: c.danger),
        const SizedBox(height: 12),
        Text('Something went wrong',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 17, fontWeight: FontWeight.w800, color: c.text)),
        const SizedBox(height: 6),
        Text(
          _error ?? 'Please try again.',
          textAlign: TextAlign.center,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 13, color: c.textSecondary),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton(
                onPressed: _disconnect,
                child: const Text('Retry'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
