import 'package:flutter/material.dart';
import '../models/bridge_connection_state.dart';
import '../models/bridge_health.dart';

/// Top banner displayed on chat & chat list screens when connection requires action or user awareness.
/// Visible strictly for: `needsLogin`, `rateLimited`, `bridgeUnreachable`.
/// Hidden completely during `connected` and silent `reconnecting` states.
class BridgeStatusBanner extends StatelessWidget {
  final String networkName;
  final BridgeHealth health;
  final VoidCallback? onTapReconnect;

  const BridgeStatusBanner({
    super.key,
    required this.networkName,
    required this.health,
    this.onTapReconnect,
  });

  @override
  Widget build(BuildContext context) {
    if (!health.state.showBanner) {
      return const SizedBox.shrink();
    }

    final message = _buildMessage();
    final isDisconnected = health.state == BridgeConnectionState.needsLogin;

    return AnimatedSize(
      duration: const Duration(milliseconds: 300),
      curve: Curves.fastOutSlowIn,
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: isDisconnected ? const Color(0xFFF0FDF4) : const Color(0xFFFEF2F2),
          border: Border(
            bottom: BorderSide(
              color: isDisconnected
                  ? const Color(0xFFDCFCE7)
                  : const Color(0xFFFEE2E2),
              width: 1,
            ),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: SafeArea(
          top: false,
          bottom: false,
          child: InkWell(
            onTap: isDisconnected ? onTapReconnect : null,
            child: Row(
              children: [
                Icon(
                  _getIcon(),
                  color: isDisconnected ? const Color(0xFF16A34A) : const Color(0xFFDC2626),
                  size: 20,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    message,
                    style: TextStyle(
                      color: isDisconnected ? const Color(0xFF15803D) : const Color(0xFF991B1B),
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (isDisconnected)
                  GestureDetector(
                    onTap: onTapReconnect,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      child: Text(
                        'Reconnect',
                        style: const TextStyle(
                          color: Color(0xFF16A34A),
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  IconData _getIcon() {
    switch (health.state) {
      case BridgeConnectionState.needsLogin:
        return Icons.grid_view_rounded;
      case BridgeConnectionState.rateLimited:
        return Icons.timer_outlined;
      case BridgeConnectionState.bridgeUnreachable:
        return Icons.cloud_off_rounded;
      default:
        return Icons.info_outline;
    }
  }

  String _buildMessage() {
    switch (health.state) {
      case BridgeConnectionState.needsLogin:
        return '$networkName Disconnected';

      case BridgeConnectionState.rateLimited:
        final remainingMins = health.remainingCooldown.inMinutes;
        if (remainingMins > 0) {
          return '$networkName temporarily limited • Retrying in $remainingMins mins';
        }
        return '$networkName temporarily limited • Retrying shortly';

      case BridgeConnectionState.bridgeUnreachable:
        return 'Trouble reaching server • Retrying automatically';

      case BridgeConnectionState.connected:
      case BridgeConnectionState.reconnecting:
        return '';
    }
  }
}

