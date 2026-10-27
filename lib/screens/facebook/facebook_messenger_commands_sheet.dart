// ignore_for_file: deprecated_member_use, use_build_context_synchronously
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:matrix/matrix.dart';

import '../../core/theme/app_theme.dart';
import 'facebook_disconnect.dart';

/// Shows the interactive Facebook Messenger Bridge Commands Console
void showFacebookMessengerCommandsSheet({
  required BuildContext context,
  required Client client,
}) {
  HapticFeedback.lightImpact();
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => FacebookMessengerCommandsSheet(client: client),
  );
}

class FacebookMessengerCommandsSheet extends StatefulWidget {
  final Client client;

  const FacebookMessengerCommandsSheet({
    super.key,
    required this.client,
  });

  @override
  State<FacebookMessengerCommandsSheet> createState() =>
      _FacebookMessengerCommandsSheetState();
}

class _FacebookMessengerCommandsSheetState
    extends State<FacebookMessengerCommandsSheet> {
  final TextEditingController _customCmdController = TextEditingController();
  final ScrollController _terminalScrollController = ScrollController();

  Room? _botRoom;
  StreamSubscription<Event>? _sub;

  final List<String> _logs = [
    '🤖 Messenger Bridge Management Terminal Ready.',
    '💡 Tip: Commands in management room do not require !fb prefix.',
  ];

  bool _isSending = false;
  static const Color kMessengerBlue = Color(0xFF0084FF);

  @override
  void initState() {
    super.initState();
    _initRoom();
  }

  @override
  void dispose() {
    _customCmdController.dispose();
    _terminalScrollController.dispose();
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _initRoom() async {
    _botRoom = await FacebookMessengerDisconnectService.findOrCreateManagementRoom(
      widget.client,
      createIfMissing: true,
    );

    if (_botRoom != null && mounted) {
      _listenToRoom(_botRoom!);
    } else if (mounted) {
      setState(() {
        _logs.add('❌ Could not connect to Facebook Messenger management room.');
      });
    }
  }

  void _listenToRoom(Room room) {
    _sub?.cancel();
    _sub = widget.client.onTimelineEvent.stream.listen((Event event) {
      if (event.roomId != room.id || event.senderId == widget.client.userID) {
        return;
      }

      final body = (event.content['body'] as String? ?? '').trim();
      if (body.isEmpty) return;

      if (mounted) {
        setState(() {
          _logs.add('📥 Bot: $body');
        });
        _scrollToBottom();
      }
    });
  }

  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_terminalScrollController.hasClients) {
        _terminalScrollController.animateTo(
          _terminalScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _sendCommand(String rawCmd) async {
    final cmd = rawCmd.trim();
    if (cmd.isEmpty) return;

    if (_botRoom == null) {
      await _initRoom();
      if (_botRoom == null) {
        setState(() => _logs.add('❌ Management room unavailable.'));
        return;
      }
    }

    setState(() {
      _isSending = true;
      _logs.add('📤 Sent: $cmd');
    });
    _scrollToBottom();

    try {
      await _botRoom!.sendTextEvent(cmd);
    } catch (e) {
      setState(() {
        _logs.add('❌ Error sending command: $e');
      });
    } finally {
      if (mounted) {
        setState(() => _isSending = false);
      }
    }
  }

  void _showInputDialog({
    required String title,
    required String hint,
    required String label,
    required void Function(String val) onConfirm,
  }) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.allora.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          title,
          style: GoogleFonts.poppins(
            fontWeight: FontWeight.w700,
            fontSize: 17,
            color: context.allora.text,
          ),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: GoogleFonts.poppins(color: context.allora.text),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: GoogleFonts.poppins(color: context.allora.textTertiary),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: GoogleFonts.poppins(color: context.allora.textSecondary)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: kMessengerBlue,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () {
              final text = controller.text.trim();
              Navigator.pop(ctx);
              if (text.isNotEmpty) {
                onConfirm(text);
              }
            },
            child: Text(label, style: GoogleFonts.poppins(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.allora;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      margin: EdgeInsets.only(bottom: bottomInset),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 32,
            offset: const Offset(0, -8),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
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

              // Header
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: kMessengerBlue.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(Icons.terminal_rounded, color: kMessengerBlue, size: 20),
                      ),
                      const SizedBox(width: 10),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Bridge Management Console',
                            style: GoogleFonts.poppins(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: c.text,
                            ),
                          ),
                          Text(
                            'Facebook / Messenger Bot Control',
                            style: GoogleFonts.poppins(
                              fontSize: 11.5,
                              color: c.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  IconButton(
                    icon: Icon(Icons.close_rounded, color: c.textSecondary),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),

              const SizedBox(height: 14),

              // Quick Actions Grid
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _buildQuickActionChip('🔄 Sync Portals', () => _sendCommand('sync-portal')),
                  _buildQuickActionChip('👥 List Logins', () => _sendCommand('list-logins')),
                  _buildQuickActionChip('🤖 Ping Matrix', () => _sendCommand('ping-matrix')),
                  _buildQuickActionChip('🔒 Toggle Encryption', () => _sendCommand('toggle-encryption')),
                  _buildQuickActionChip('ℹ️ Version', () => _sendCommand('version')),
                  _buildQuickActionChip('❓ Help', () => _sendCommand('help')),
                  _buildQuickActionChip('🔍 Search User', () {
                    _showInputDialog(
                      title: 'Search Messenger Users',
                      hint: 'Name or email',
                      label: 'Search',
                      onConfirm: (val) => _sendCommand('search $val'),
                    );
                  }),
                  _buildQuickActionChip('💬 Start Chat', () {
                    _showInputDialog(
                      title: 'Start Chat with User',
                      hint: 'User ID or identifier',
                      label: 'Start Chat',
                      onConfirm: (val) => _sendCommand('start-chat $val'),
                    );
                  }),
                  _buildQuickActionChip('🏷️ Resolve ID', () {
                    _showInputDialog(
                      title: 'Resolve Identifier',
                      hint: 'Messenger identifier',
                      label: 'Resolve',
                      onConfirm: (val) => _sendCommand('resolve-identifier $val'),
                    );
                  }),
                  _buildQuickActionChip('🛑 Cancel Action', () => _sendCommand('cancel')),
                ],
              ),

              const SizedBox(height: 14),

              // Interactive Terminal Logs View
              Container(
                height: 180,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF090D16),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.blueGrey.withValues(alpha: 0.25)),
                ),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'TERMINAL OUTPUT',
                          style: GoogleFonts.firaCode(
                            color: Colors.cyanAccent,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        GestureDetector(
                          onTap: () => setState(() => _logs.clear()),
                          child: Text(
                            'CLEAR',
                            style: GoogleFonts.firaCode(color: Colors.grey, fontSize: 10),
                          ),
                        ),
                      ],
                    ),
                    const Divider(color: Colors.white12, height: 10),
                    Expanded(
                      child: ListView.builder(
                        controller: _terminalScrollController,
                        itemCount: _logs.length,
                        itemBuilder: (context, idx) {
                          final log = _logs[idx];
                          final isOut = log.startsWith('📤');
                          final isErr = log.startsWith('❌');
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: SelectableText(
                              log,
                              style: GoogleFonts.firaCode(
                                fontSize: 11,
                                color: isErr
                                    ? const Color(0xFFF87171)
                                    : (isOut
                                        ? const Color(0xFF60A5FA)
                                        : const Color(0xFF94A3B8)),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 12),

              // Command Input Bar
              Row(
                children: [
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: c.surfaceAlt,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: c.outline),
                      ),
                      child: TextField(
                        controller: _customCmdController,
                        style: GoogleFonts.firaCode(fontSize: 13, color: c.text),
                        onSubmitted: (val) {
                          _sendCommand(val);
                          _customCmdController.clear();
                        },
                        decoration: InputDecoration(
                          hintText: 'Enter command (e.g. sync-portal, search John)...',
                          hintStyle: GoogleFonts.poppins(fontSize: 12.5, color: c.textTertiary),
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          prefixIcon: Icon(Icons.chevron_right_rounded, color: c.textSecondary, size: 20),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    height: 48,
                    width: 48,
                    decoration: BoxDecoration(
                      color: kMessengerBlue,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: IconButton(
                      icon: _isSending
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation(Colors.white),
                              ),
                            )
                          : const Icon(Icons.send_rounded, color: Colors.white, size: 20),
                      onPressed: () {
                        _sendCommand(_customCmdController.text);
                        _customCmdController.clear();
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildQuickActionChip(String label, VoidCallback onTap) {
    final c = context.allora;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: c.surfaceAlt,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: c.outline),
        ),
        child: Text(
          label,
          style: GoogleFonts.poppins(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: c.text,
          ),
        ),
      ),
    );
  }
}
