// ignore_for_file: deprecated_member_use
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:matrix/matrix.dart';

import '../../core/theme/app_theme.dart';
import '../../data/services/account_lifecycle.dart';
import '../../data/services/connection_manager.dart';
import '../../screens/networks/network_connection_cache.dart';
import '../../screens/networks/network_meta.dart';

/// Opens a universal connection bottom sheet for any messaging platform
/// (Signal, Email, LinkedIn, LINE, etc.) using its Matrix bridge bot.
void showGenericNetworkConnectSheet({
  required BuildContext context,
  required Client client,
  required NetworkMeta meta,
  VoidCallback? onConnected,
}) {
  HapticFeedback.lightImpact();
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => GenericNetworkConnectSheet(
      client: client,
      meta: meta,
      onConnected: onConnected,
    ),
  );
}

class GenericNetworkConnectSheet extends StatefulWidget {
  final Client client;
  final NetworkMeta meta;
  final VoidCallback? onConnected;

  const GenericNetworkConnectSheet({
    super.key,
    required this.client,
    required this.meta,
    this.onConnected,
  });

  @override
  State<GenericNetworkConnectSheet> createState() =>
      _GenericNetworkConnectSheetState();
}

class _GenericNetworkConnectSheetState
    extends State<GenericNetworkConnectSheet> {
  final TextEditingController _inputController = TextEditingController();
  bool _isLoading = false;
  String? _error;
  bool _connected = false;

  @override
  void dispose() {
    _inputController.dispose();
    super.dispose();
  }

  Future<void> _sendLoginCommand() async {
    final input = _inputController.text.trim();
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      Room? room;
      final userDomain = widget.client.userID!.split(':').last;
      // ── Try to reuse the existing management DM first ────────────────────
      // Creating a NEW DM with the bot on every reconnect is the root cause
      // of the kick→rejoin→kick loop: the bridge detects two rooms for the
      // same remote contact and resolves the conflict by removing the user
      // from the old portal.  We must find the existing one first.
      final botMxidFull = '@${widget.meta.botAlias}bot:$userDomain';
      final botMxidAlt  = '@${widget.meta.botAlias}:$userDomain';
      for (final r in widget.client.rooms) {
        final dm = (r.directChatMatrixID ?? '').toLowerCase();
        if (dm == botMxidFull.toLowerCase() ||
            dm == botMxidAlt.toLowerCase()) {
          room = r;
          break;
        }
      }
      // Fallback: use the AccountLifecycleService finder which also checks
      // bot display-name heuristics.
      room ??= AccountLifecycleService.findManagementRoom(
          widget.client, widget.meta.id);

      if (room == null) {
        // No existing DM found — create one for the first time only.
        final roomId = await widget.client.createRoom(
          name: '${widget.meta.displayName} Bridge',
          isDirect: true,
          preset: CreateRoomPreset.trustedPrivateChat,
        );
        int retries = 0;
        while (room == null && retries < 10) {
          await Future.delayed(const Duration(milliseconds: 500));
          room = widget.client.getRoomById(roomId);
          retries++;
        }
        if (room != null) {
          await room.invite(botMxidFull);
        }
      }
      if (room == null) {
        setState(() {
          _error = 'Could not reach ${widget.meta.displayName} bridge bot.';
          _isLoading = false;
        });
        return;
      }

      final command = input.isEmpty ? 'login' : 'login $input';
      await room.sendTextEvent(command);

      // Give bridge bot a moment to process or confirm
      await Future.delayed(const Duration(seconds: 2));

      if (mounted) {
        setState(() {
          _isLoading = false;
          _connected = true;
        });
        NetworkConnectionCache.markConnected(widget.meta.id,
            accountLabel: 'Connected', lastSynced: 'Just now', force: true);
        ConnectionManager.instance
            ?.noteJustConnected(widget.meta.id, syncFor: const Duration(seconds: 8));
        widget.onConnected?.call();
        Future.delayed(const Duration(milliseconds: 1200), () {
          if (mounted && Navigator.canPop(context)) {
            Navigator.pop(context);
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Failed to communicate with bridge bot: $e';
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.allora;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      padding: EdgeInsets.fromLTRB(24, 20, 24, 24 + bottomInset),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 30,
            offset: const Offset(0, -8),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Drag handle
          Container(
            width: 38,
            height: 4,
            decoration: BoxDecoration(
              color: c.textTertiary.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 20),
          // Brand Icon
          Container(
            width: 68,
            height: 68,
            decoration: BoxDecoration(
              color: widget.meta.brandColor.withValues(alpha: 0.14),
              shape: BoxShape.circle,
              border: Border.all(
                color: widget.meta.brandColor.withValues(alpha: 0.3),
                width: 1.5,
              ),
            ),
            alignment: Alignment.center,
            child: widget.meta.asset != null
                ? Image.asset(widget.meta.asset!, width: 36, height: 36)
                : Icon(
                    widget.meta.icon ?? Icons.chat_bubble_rounded,
                    color: widget.meta.brandColor,
                    size: 34,
                  ),
          ),
          const SizedBox(height: 16),
          Text(
            'Connect ${widget.meta.displayName}',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: c.text,
              letterSpacing: -0.4,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Link your ${widget.meta.displayName} account to sync conversations, send messages, and receive real-time notifications.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              color: c.textSecondary,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 24),
          if (_connected) ...[
            Container(
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
              decoration: BoxDecoration(
                color: c.success.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: c.success.withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.check_circle_rounded,
                      color: c.success, size: 24),
                  const SizedBox(width: 10),
                  Text(
                    '${widget.meta.displayName} Connected!',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: c.success,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ] else ...[
            TextField(
              controller: _inputController,
              decoration: InputDecoration(
                hintText: 'Optional login token or pairing code...',
                hintStyle: TextStyle(color: c.textTertiary),
                filled: true,
                fillColor: c.surfaceAlt,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide.none,
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
              ),
              style: TextStyle(color: c.text, fontSize: 15),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: const TextStyle(
                  color: Color(0xFFFF3B30),
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton(
                onPressed: _isLoading ? null : _sendLoginCommand,
                style: ElevatedButton.styleFrom(
                  backgroundColor: widget.meta.brandColor,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: _isLoading
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          valueColor:
                              AlwaysStoppedAnimation<Color>(Colors.white),
                        ),
                      )
                    : Text(
                        'Connect ${widget.meta.displayName}',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.2,
                        ),
                      ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              'Cancel',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: c.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
