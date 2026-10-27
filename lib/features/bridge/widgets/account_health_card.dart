import 'package:flutter/material.dart';
import '../models/bridge_connection_state.dart';
import '../models/bridge_health.dart';
import 'bridge_status_dot.dart';

/// Comprehensive Account Health Card widget for Settings & Profile screens.
/// Displays state telemetry, uptime since, retry count, and last error.
/// Grays out bridge-dependent features when offline while keeping profile parameters editable.
class AccountHealthCard extends StatelessWidget {
  final String accountLabel;
  final String networkName;
  final BridgeHealth health;
  final VoidCallback? onEditProfile;
  final ValueChanged<bool>? onToggleNotifications;
  final ValueChanged<bool>? onToggleStickerSync;
  final bool notificationsEnabled;
  final bool stickerSyncEnabled;

  const AccountHealthCard({
    super.key,
    required this.accountLabel,
    required this.networkName,
    required this.health,
    this.onEditProfile,
    this.onToggleNotifications,
    this.onToggleStickerSync,
    this.notificationsEnabled = true,
    this.stickerSyncEnabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final isOnline = health.state == BridgeConnectionState.connected;
    final theme = Theme.of(context);

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: theme.dividerColor.withValues(alpha: 0.2),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header Row: Account Identity & Health Status Indicator
            Row(
              children: [
                BridgeStatusDot(state: health.state, size: 14),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        accountLabel.isNotEmpty ? accountLabel : '$networkName Account',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        health.state.label,
                        style: TextStyle(
                          fontSize: 13,
                          color: health.state.statusColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.edit_outlined, size: 20),
                  onPressed: onEditProfile,
                  tooltip: 'Edit Profile & Account Label',
                ),
              ],
            ),
            const Divider(height: 24),

            // Diagnostic Telemetry Summary
            _buildTelemetryRow('Connected Since', _formatDate(health.since)),
            if (health.retryCount > 0)
              _buildTelemetryRow('Retry Attempt', '${health.retryCount} / 5'),
            if (health.lastError != null && health.lastError!.isNotEmpty)
              _buildTelemetryRow('Last Issue', health.lastError!, isError: true),
            if (health.isThrottled)
              _buildTelemetryRow(
                'Cooldown',
                '${health.remainingCooldown.inMinutes} mins remaining',
                isError: true,
              ),

            const SizedBox(height: 16),

            // Editable Profile Controls (Always Active)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.badge_outlined),
              title: const Text('Account Label'),
              subtitle: Text(accountLabel.isNotEmpty ? accountLabel : 'Default'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: onEditProfile,
            ),

            // Bridge-only Settings (Grayed out when not connected)
            Opacity(
              opacity: isOnline ? 1.0 : 0.4,
              child: IgnorePointer(
                ignoring: !isOnline,
                child: Column(
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      secondary: const Icon(Icons.notifications_active_outlined),
                      title: const Text('Bridge Notifications'),
                      subtitle: const Text('Push alerts for incoming bridge messages'),
                      value: notificationsEnabled,
                      onChanged: onToggleNotifications,
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      secondary: const Icon(Icons.sticky_note_2_outlined),
                      title: const Text('Sticker Sync'),
                      subtitle: const Text('Sync WhatsApp/Telegram sticker packs'),
                      value: stickerSyncEnabled,
                      onChanged: onToggleStickerSync,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTelemetryRow(String label, String value, {bool isError = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 13, color: Colors.grey),
          ),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: isError ? Colors.redAccent : null,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime dt) {
    return '${dt.day}/${dt.month}/${dt.year} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}
