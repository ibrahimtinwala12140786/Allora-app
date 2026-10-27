import 'package:flutter/foundation.dart';
import '../models/bridge_connection_state.dart';
import '../models/bridge_health.dart';

/// Notification decision engine for Bridge Connection Health System.
/// Suppresses noise during short transient reconnects and respects quiet hours.
class BridgeNotificationService {
  final bool quietHoursEnabled;
  final int quietHoursStartHour; // 0-23 (e.g. 22 for 10 PM)
  final int quietHoursEndHour; // 0-23 (e.g. 7 for 7 AM)

  const BridgeNotificationService({
    this.quietHoursEnabled = false,
    this.quietHoursStartHour = 22,
    this.quietHoursEndHour = 7,
  });

  /// Evaluates whether a notification should be triggered for a state transition.
  bool shouldNotify(BridgeHealth health) {
    if (isQuietHours()) {
      debugPrint('BridgeNotificationService: Suppressing notification due to quiet hours.');
      return false;
    }

    switch (health.state) {
      case BridgeConnectionState.connected:
        return false;

      case BridgeConnectionState.reconnecting:
        // Do NOT notify for short transient reconnects (< 2 minutes)
        final durationDisconnected = DateTime.now().difference(health.since);
        return durationDisconnected >= const Duration(minutes: 2);

      case BridgeConnectionState.needsLogin:
      case BridgeConnectionState.rateLimited:
      case BridgeConnectionState.bridgeUnreachable:
        return true;
    }
  }

  /// Checks if current local time falls within configured quiet hours window.
  bool isQuietHours() {
    if (!quietHoursEnabled) return false;
    final now = DateTime.now().hour;
    if (quietHoursStartHour > quietHoursEndHour) {
      // Overnight range, e.g., 22:00 to 07:00
      return now >= quietHoursStartHour || now < quietHoursEndHour;
    } else {
      // Same-day range, e.g., 01:00 to 06:00
      return now >= quietHoursStartHour && now < quietHoursEndHour;
    }
  }

  /// Generates human-readable notification titles and body strings.
  Map<String, String>? getNotificationContent({
    required String networkName,
    required BridgeHealth health,
  }) {
    if (!shouldNotify(health)) return null;

    switch (health.state) {
      case BridgeConnectionState.needsLogin:
        return {
          'title': '$networkName Disconnected',
          'body': 'Action required: Tap to reconnect your $networkName account.',
        };

      case BridgeConnectionState.rateLimited:
        final mins = health.remainingCooldown.inMinutes;
        return {
          'title': '$networkName Rate Limited',
          'body': '$networkName is temporarily limited. Retrying automatically in ${mins > 0 ? '$mins min' : 'a moment'}.',
        };

      case BridgeConnectionState.bridgeUnreachable:
        return {
          'title': 'Trouble Reaching $networkName',
          'body': 'Unable to reach bridge servers. Allora is automatically retrying in the background.',
        };

      case BridgeConnectionState.reconnecting:
        return {
          'title': '$networkName Reconnecting',
          'body': 'Connection delayed for over 2 minutes. Allora is silently attempting to reconnect.',
        };

      case BridgeConnectionState.connected:
        return null;
    }
  }
}
