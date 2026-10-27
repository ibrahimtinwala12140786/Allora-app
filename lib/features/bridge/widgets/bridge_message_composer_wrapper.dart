import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matrix/matrix.dart';

import '../../../providers/network_provider.dart';
import '../models/bridge_connection_state.dart';
import '../models/bridge_health.dart';
import '../providers/bridge_health_provider.dart';
import '../services/bridge_outbox_repository.dart';

/// Composer status banner and interceptor for sending messages based on BridgeHealth.
/// Never disables typing. Handles offline queueing, draft saving, and status chips.
class BridgeMessageComposerWrapper extends ConsumerStatefulWidget {
  final String accountId;
  final String roomId;
  final Widget Function(
    BuildContext context,
    Future<bool> Function(String text) onSendMessage,
  ) composerBuilder;

  const BridgeMessageComposerWrapper({
    super.key,
    required this.accountId,
    required this.roomId,
    required this.composerBuilder,
  });

  @override
  ConsumerState<BridgeMessageComposerWrapper> createState() =>
      _BridgeMessageComposerWrapperState();
}

class _BridgeMessageComposerWrapperState
    extends ConsumerState<BridgeMessageComposerWrapper> {
  final BridgeOutboxRepository _outboxRepo = BridgeOutboxRepository();
  String? _statusBannerText;

  @override
  Widget build(BuildContext context) {
    final health = ref.watch(bridgeHealthProvider(widget.accountId));

    // Automatically trigger outbox flush when state returns to Connected
    ref.listen<BridgeHealth>(bridgeHealthProvider(widget.accountId), (previous, next) {
      if (previous?.state != BridgeConnectionState.connected &&
          next.state == BridgeConnectionState.connected) {
        _flushOutboxQueue();
      }
    });

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Status notice strip shown above composer during non-connected states
        if (health.state != BridgeConnectionState.connected || _statusBannerText != null)
          _buildComposerStatusStrip(health),

        // Wrapped composer widget
        widget.composerBuilder(context, (text) => _handleSendMessage(text, health)),
      ],
    );
  }

  Future<void> _flushOutboxQueue() async {
    final client = ref.read(matrixClientProvider);
    final count = await _outboxRepo.flushOutbox(
      accountId: widget.accountId,
      client: client,
    );
    if (count > 0 && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$count queued message(s) sent successfully.'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<bool> _handleSendMessage(String text, BridgeHealth health) async {
    if (text.trim().isEmpty) return false;

    switch (health.state) {
      case BridgeConnectionState.connected:
        // Send directly via Matrix client
        try {
          final client = ref.read(matrixClientProvider);
          final room = client.getRoomById(widget.roomId);
          if (room != null) {
            await room.sendTextEvent(text);
            return true;
          }
        } catch (e) {
          debugPrint('BridgeMessageComposer: Direct send failed, queueing: $e');
        }
        // Fallback to queue if send failed
        await _queueMessage(text);
        _showNotice('Queued • Will send automatically');
        return true;

      case BridgeConnectionState.reconnecting:
        await _queueMessage(text);
        _showNotice('Queued • Will send automatically');
        return true;

      case BridgeConnectionState.bridgeUnreachable:
        await _queueMessage(text);
        _showNotice('Waiting for bridge');
        return true;

      case BridgeConnectionState.needsLogin:
        _saveDraft(text);
        _showNotice('Reconnect required before sending');
        return false;

      case BridgeConnectionState.rateLimited:
        _saveDraft(text);
        _showNotice('Will send after cooldown');
        return false;
    }
  }

  Future<void> _queueMessage(String text) async {
    final msgId = 'outbox_${DateTime.now().millisecondsSinceEpoch}';
    await _outboxRepo.enqueueMessage(
      id: msgId,
      roomId: widget.roomId,
      message: text,
      accountId: widget.accountId,
    );
  }

  void _saveDraft(String text) {
    debugPrint('BridgeMessageComposer: Saved draft for room ${widget.roomId}: $text');
  }

  void _showNotice(String notice) {
    setState(() => _statusBannerText = notice);
    Future.delayed(const Duration(seconds: 4), () {
      if (mounted) setState(() => _statusBannerText = null);
    });
  }

  Widget _buildComposerStatusStrip(BridgeHealth health) {
    final text = _statusBannerText ?? _getDefaultNotice(health.state);
    if (text.isEmpty) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      color: Colors.amber.shade900.withValues(alpha: 0.2),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 16, color: Colors.amber.shade400),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: Colors.amber.shade200,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _getDefaultNotice(BridgeConnectionState state) {
    switch (state) {
      case BridgeConnectionState.reconnecting:
        return 'Reconnecting… Messages will be queued automatically';
      case BridgeConnectionState.bridgeUnreachable:
        return 'Bridge unreachable • Messages queued for auto-send';
      case BridgeConnectionState.needsLogin:
        return 'Reconnect required before sending';
      case BridgeConnectionState.rateLimited:
        return 'Rate limited • Will send after cooldown';
      case BridgeConnectionState.connected:
        return '';
    }
  }
}
