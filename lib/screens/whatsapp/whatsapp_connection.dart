// ignore_for_file: unnecessary_non_null_assertion, unused_element, curly_braces_in_flow_control_structures, unused_import, unnecessary_string_interpolations, use_build_context_synchronously, deprecated_member_use

import 'dart:async';
import 'package:flutter/material.dart' hide Visibility;
import '../../features/connect/connection_sequence.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:matrix/matrix.dart';

import '../../core/theme/app_theme.dart';
import '../../data/services/account_lifecycle.dart';
import '../../data/services/room_wipe_service.dart';
import 'whatsapp_disconnect_service.dart';
import '../networks/network_connection_cache.dart';
import '../bridge/bridge_room_classifier.dart';
import 'package:http/http.dart' as http;
import '../networks/network_meta.dart';

// ─── BRAND COLORS ────────────────────────────────────────────────────────────
const Color kBeeperBlue = Color(0xFF0052FF);
const Color kWaGreen = Color(0xFF25D366);

// ─── COUNTRY LIST ─────────────────────────────────────────────────────────────
final List<Map<String, String>> _allCountries = [
  {"name": "Australia", "code": "+61", "flag": "🇦🇺"},
  {"name": "Brazil", "code": "+55", "flag": "🇧🇷"},
  {"name": "Canada", "code": "+1", "flag": "🇨🇦"},
  {"name": "France", "code": "+33", "flag": "🇫🇷"},
  {"name": "Germany", "code": "+49", "flag": "🇩🇪"},
  {"name": "India", "code": "+91", "flag": "🇮🇳"},
  {"name": "Indonesia", "code": "+62", "flag": "🇮🇩"},
  {"name": "Italy", "code": "+39", "flag": "🇮🇹"},
  {"name": "Mexico", "code": "+52", "flag": "🇲🇽"},
  {"name": "Nigeria", "code": "+234", "flag": "🇳🇬"},
  {"name": "Pakistan", "code": "+92", "flag": "🇵🇰"},
  {"name": "Philippines", "code": "+63", "flag": "🇵🇭"},
  {"name": "South Africa", "code": "+27", "flag": "🇿🇦"},
  {"name": "United Arab Emirates", "code": "+971", "flag": "🇦🇪"},
  {"name": "United Kingdom", "code": "+44", "flag": "🇬🇧"},
  {"name": "United States", "code": "+1", "flag": "🇺🇸"},
];

// ─── PUBLIC ENTRY POINT ───────────────────────────────────────────────────────
void showWhatsAppConnectSheet({
  required BuildContext context,
  required Client client,
  VoidCallback? onPairingCodeReceived,
  VoidCallback? onConnected,
}) {
  HapticFeedback.lightImpact();
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => WhatsAppConnectSheet(
      client: client,
      onPairingCodeReceived: onPairingCodeReceived,
      onConnected: onConnected,
    ),
  );
}

// ─── THE CONNECT SHEET ────────────────────────────────────────────────────────
class WhatsAppConnectSheet extends StatefulWidget {
  final Client client;
  final VoidCallback? onPairingCodeReceived;
  final VoidCallback? onConnected;

  const WhatsAppConnectSheet({
    super.key,
    required this.client,
    this.onPairingCodeReceived,
    this.onConnected,
  });

  @override
  State<WhatsAppConnectSheet> createState() => _WhatsAppConnectSheetState();
}

class _WhatsAppConnectSheetState extends State<WhatsAppConnectSheet> {
  final TextEditingController _phoneController = TextEditingController();

  StreamSubscription? _activeSub;

  bool _sheetLoading = false;
  String? _sheetError;
  String? _generatedPairingCode;
  String _lastSanitizedNumber = '';

  // New state flag for the success screen
  bool _isConnected = false;
  
  List<String> _debugLogs = [];

  String _selectedCountryCode = "+91";
  String _selectedCountryFlag = "🇮🇳";

  @override
  void initState() {
    super.initState();
    // Beeper behaviour: Pre-populate previously known phone number from cache
    final cached = NetworkConnectionCache.get(NetworkId.whatsapp);
    if (cached.accountLabel != null && cached.accountLabel!.isNotEmpty) {
      final label = cached.accountLabel!;
      for (final country in _allCountries) {
        final code = country['code']!;
        if (label.startsWith(code)) {
          _selectedCountryCode = code;
          _selectedCountryFlag = country['flag']!;
          _phoneController.text =
              label.substring(code.length).replaceAll(RegExp(r'\D'), '');
          break;
        }
      }
      if (_phoneController.text.isEmpty) {
        _phoneController.text = label.replaceAll(RegExp(r'\D'), '');
      }
    }
  }

  @override
  void dispose() {
    _phoneController.dispose();
    _activeSub?.cancel();
    super.dispose();
  }

  // ─── PIPELINE ──────────────────────────────────────────────────────
  Future<void> _executeUnifiedPipeline() async {
    FocusManager.instance.primaryFocus?.unfocus();

    final rawNumber = _phoneController.text.trim();
    if (rawNumber.isEmpty || rawNumber.length < 5) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Please enter a valid phone number.'),
            backgroundColor: Colors.redAccent),
      );
      return;
    }

    setState(() {
      _sheetError = null;
      _sheetLoading = true;
      _generatedPairingCode = null;
      _isConnected = false;
      _debugLogs = ['Starting connection pipeline...'];
    });

    try {
      Room? activeRoom;
      
      setState(() => _debugLogs.add('Searching for active WhatsApp bridge bot room...'));

      final userDomain = widget.client.userID!.split(':').last;
      final botMxid = '@whatsappbot:$userDomain';

      // 1. Try finding management room via AccountLifecycleService (prefer unencrypted)
      activeRoom = AccountLifecycleService.findManagementRoom(
          widget.client, NetworkId.whatsapp);
      if (activeRoom != null && activeRoom.encrypted) {
        debugPrint('WhatsAppConnect: management room is encrypted (bridge does not support E2EE) — searching for unencrypted room');
        activeRoom = null;
      }

      // 2. Try finding unencrypted room by directChatMatrixID, participant, or name
      if (activeRoom == null) {
        for (final room in widget.client.rooms) {
          if (room.encrypted) continue;
          final hasPuppet = room.getParticipants().any((p) {
            final id = p.id.toLowerCase();
            return id.contains('_whatsapp_') || id.contains('@whatsapp_') || id.contains('@wa_');
          });
          if (hasPuppet) continue; // Never select a bridged portal room!

          final dm = (room.directChatMatrixID ?? '').toLowerCase();
          final name = room.displayname.toLowerCase().trim();
          if (dm == botMxid.toLowerCase() ||
              name == 'whatsapp bridge' ||
              name == 'whatsapp bridge bot') {
            activeRoom = room;
            break;
          }
          for (final m in room.getParticipants()) {
            if (m.id.toLowerCase() == botMxid.toLowerCase() || m.id.toLowerCase().startsWith('@whatsappbot:')) {
              activeRoom = room;
              break;
            }
          }
          if (activeRoom != null) break;
        }
      }

      // 3. If still null, create a clean unencrypted room
      if (activeRoom == null) {
        setState(() => _debugLogs.add('Creating fresh unencrypted WhatsApp bridge room...'));
        try {
          final roomId = await widget.client.createRoom(
            name: 'WhatsApp Bridge',
            isDirect: false,
            preset: CreateRoomPreset.privateChat,
            invite: [botMxid],
          );

          int retries = 0;
          while (activeRoom == null && retries < 15) {
            activeRoom = widget.client.getRoomById(roomId);
            if (activeRoom != null) break;
            try {
              await widget.client.sync();
            } catch (_) {}
            await Future.delayed(const Duration(milliseconds: 300));
            retries++;
          }

          if (activeRoom == null) throw Exception('Room $roomId not found after sync');
        } catch (e) {
          debugPrint('WhatsAppConnect error finding/creating room: $e');
          setState(() {
            _sheetError =
                "Could not find or create WhatsApp bridge room. Ensure the bridge is running.";
            _sheetLoading = false;
          });
          return;
        }
      }

      String cleanInput = rawNumber.replaceAll(RegExp(r'[^\d]'), '');
      String codeOnly = _selectedCountryCode.replaceAll(RegExp(r'[^\d]'), '');
      if (cleanInput.startsWith(codeOnly) && cleanInput.length > 10) {
        cleanInput = cleanInput.substring(codeOnly.length);
      }
      final sanitizedNumber = '+$codeOnly$cleanInput';
      _lastSanitizedNumber = sanitizedNumber;
      setState(() => _debugLogs.add('Sanitized phone number: $sanitizedNumber'));

      // If connecting a new account, clean up stale portal rooms from any previous account
      final stalePortals = <String>[];
      for (final room in widget.client.rooms) {
        if (WhatsAppDisconnectService.isWhatsAppRoom(room, client: widget.client) &&
            !WhatsAppDisconnectService.isManagementRoom(room)) {
          stalePortals.add(room.id);
        }
      }
      if (stalePortals.isNotEmpty) {
        debugPrint('WhatsAppConnect: purging ${stalePortals.length} stale portal rooms before fresh login');
        await RoomWipeService.enqueue(widget.client, stalePortals);
      }

      final Set<String> processedEventIds = {};
      _activeSub?.cancel();
      setState(() => _debugLogs.add('Listening for bot replies...'));
      _activeSub = widget.client.onTimelineEvent.stream.listen((event) {
        if (event.roomId != activeRoom?.id) return;
        if (event.senderId == widget.client.userID) return;
        if (processedEventIds.contains(event.eventId)) return;

        final body = event.body.trim();
        if (body.isEmpty) return;
        
        processedEventIds.add(event.eventId);
        setState(() => _debugLogs.add('Bot: $body'));
        debugPrint('WhatsApp Bridge Bot replied: $body');

        final lower = body.toLowerCase();

          // 🟢 INSTANT SUCCESS CHECK
          if (lower.contains('logged in') || lower.contains('connected')) {
            HapticFeedback.heavyImpact();
            _activeSub?.cancel();

            if (mounted) {
              _handleSuccessfulConnection();
            }
            return;
          }
          
          // 🟡 PROMPT CHECK
          if (lower.contains('please reply with your phone number') || lower.contains('enter your phone number') || lower.contains('phone number')) {
            debugPrint('WhatsApp Bridge Bot requested phone number, sending $sanitizedNumber');
            setState(() => _debugLogs.add('Bot requested number. Sending number...'));
            activeRoom?.sendTextEvent('!wa $sanitizedNumber');
            return;
          }

          // 🔵 PAIRING CODE CHECK
          final codeMatch =
              RegExp(r'\b([A-Z0-9]{4}[- ]?[A-Z0-9]{4})\b').firstMatch(body);
          if (codeMatch != null) {
            String rawCode = codeMatch.group(0)!.replaceAll(RegExp(r'[- ]'), '');
            if (rawCode.length == 8) {
              HapticFeedback.mediumImpact();
              setState(() {
                _generatedPairingCode =
                    '${rawCode.substring(0, 4)}-${rawCode.substring(4)}';
                _sheetLoading = false;
              });
              widget.onPairingCodeReceived?.call();
            }
          }

        // 🔴 ERROR CHECK
        if (lower.contains('invalid') ||
            lower.contains('error') ||
            lower.contains('unknown command') ||
            lower.contains('failed')) {
          HapticFeedback.heavyImpact();
          setState(() {
            _sheetError = body;
            _sheetLoading = false;
          });
          widget.onPairingCodeReceived?.call();
        }

      });

      Future.delayed(const Duration(seconds: 45), () {
        if (mounted &&
            _sheetLoading &&
            _generatedPairingCode == null &&
            !_isConnected) {
          setState(() {
            _debugLogs.add('Error: 45s passed with NO reply from the bot.');
            _sheetError = "The bridge bot did not reply. The server bridge might be offline, or your app is still syncing old messages in the background.";
            _sheetLoading = false;
          });
        }
      });

      setState(() => _debugLogs.add('Sending "!wa logout" and "!wa cancel" to clear previous session...'));
      try {
        await activeRoom.sendTextEvent('!wa logout');
        await Future.delayed(const Duration(milliseconds: 300));
      } catch (_) {}
      final cancelEventId = await activeRoom.sendTextEvent('!wa cancel');
      setState(() => _debugLogs.add('Server confirmed cancel (ID: $cancelEventId)'));
      
      await Future.delayed(const Duration(milliseconds: 500));
      
      setState(() => _debugLogs.add('Sending "!wa login phone" command...'));
      final loginEventId = await activeRoom.sendTextEvent('!wa login phone $sanitizedNumber');
      setState(() => _debugLogs.add('Server confirmed login command (ID: $loginEventId)'));
    } catch (e) {
      setState(() {
        _debugLogs.add('Error: $e');
        _sheetLoading = false;
        _sheetError =
            "An unexpected connection error occurred. Please try again.";
      });
    }
  }

  // ─── SUCCESS HANDLER ──────────────────────────────────────────────────────

  Future<void> _handleSuccessfulConnection() async {
    try {
      // ──────────────────────────────────────────────────────────────────────
      // STEP 1: Update UI immediately (show success screen)
      // ──────────────────────────────────────────────────────────────────────
      setState(() {
        _isConnected = true;
        _sheetLoading = false;
        _generatedPairingCode = null;
      });

      // ──────────────────────────────────────────────────────────────────────
      // STEP 2: Update NetworkConnectionCache immediately (button state)
      // ──────────────────────────────────────────────────────────────────────
      await NetworkConnectionCache.markConnected(
        NetworkId.whatsapp,
        force: true,
        accountLabel: _lastSanitizedNumber.isNotEmpty ? _lastSanitizedNumber : 'Connected',
        lastSynced: 'Just now',
      );
      debugPrint('✅ WhatsApp marked as connected in cache');

      // ──────────────────────────────────────────────────────────────────────
      // STEP 3: Clear classifier cache for fresh room identification
      // ──────────────────────────────────────────────────────────────────────
      BridgeRoomClassifier.clearCache();
      debugPrint('✅ Classifier cache cleared');

      // ──────────────────────────────────────────────────────────────────────
      // STEP 3.5: Force bridge group sync & create portals to prevent sync lag kicks
      // ──────────────────────────────────────────────────────────────────────
      unawaited(
        WhatsAppDisconnectService.forceSyncGroups(widget.client, createPortals: true),
      );
      unawaited(
        Future.delayed(
          const Duration(seconds: 6),
          () => WhatsAppDisconnectService.forceSyncGroups(widget.client, createPortals: true),
        ),
      );
      unawaited(
        Future.delayed(
          const Duration(seconds: 15),
          () => WhatsAppDisconnectService.forceSyncGroups(widget.client, createPortals: true),
        ),
      );

      // ──────────────────────────────────────────────────────────────────────
      // STEP 4: Trigger Matrix sync to fetch new WhatsApp rooms
      // ──────────────────────────────────────────────────────────────────────
      _triggerMatrixSync();

      // ──────────────────────────────────────────────────────────────────────
      // STEP 5: Notify Matrix server of connection event
      // ──────────────────────────────────────────────────────────────────────
      _notifyMatrixServerOfConnection();

      // ──────────────────────────────────────────────────────────────────────
      // STEP 6: Call parent callback for UI refresh
      // ──────────────────────────────────────────────────────────────────────
      widget.onConnected?.call();

      // STEP 7: the ConnectionSequence widget now owns the success
      // animation and closes the sheet itself when it completes.
    } catch (e) {
      debugPrint('❌ Error in success handler: $e');
      if (mounted) {
        setState(() {
          _sheetError = 'An error occurred. Please check your connection.';
          _sheetLoading = false;
        });
      }
    }
  }

  Future<void> _triggerMatrixSync() async {
    try {
      // Start a fresh sync to fetch new WhatsApp rooms from Matrix
      // without blocking the UI. Use syncUpdate() if available, or
      // trigger a full sync in the background.
      unawaited(
        Future.delayed(
          const Duration(milliseconds: 500),
          () => widget.client.sync(),
        ),
      );
      debugPrint('📡 Matrix sync triggered to fetch new rooms');
    } catch (e) {
      debugPrint('⚠️  Could not trigger sync: $e');
    }
  }

  Future<void> _notifyMatrixServerOfConnection() async {
    try {
      // Optional: send webhook/event to Matrix server or backend
      // This can be used for logging, analytics, or triggering additional setup
      final userId = widget.client.userID;
      if (userId != null) {
        debugPrint('📤 WhatsApp connection event for $userId');
        // Could send to a webhook:
        // await http.post(Uri.parse('https://your-backend.com/api/platform-connected'),
        //   headers: {'Content-Type': 'application/json'},
        //   body: jsonEncode({'user': userId, 'platform': 'whatsapp', 'timestamp': DateTime.now().toIso8601String()}),
        // );
      }
    } catch (e) {
      debugPrint('⚠️  Could not notify Matrix server: $e');
      // Non-fatal error, continue anyway
    }
  }

  // ─── UI HELPERS ───────────────────────────────────────────────────────────

  Widget _buildTopDragHandle() {
    return Center(
      child: Container(
        width: 40,
        height: 5,
        margin: const EdgeInsets.only(bottom: 24),
        decoration: BoxDecoration(
          color: context.allora.outline,
          borderRadius: BorderRadius.circular(10),
        ),
      ),
    );
  }

  Widget _buildTopRightCloseButton() {
    final c = context.allora;
    return Align(
      alignment: Alignment.centerRight,
      child: GestureDetector(
        onTap: () {
          _activeSub?.cancel();
          Navigator.pop(context);
        },
        child: Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
              color: c.surfaceAlt, shape: BoxShape.circle),
          child: Icon(Icons.close_rounded, color: c.text, size: 16),
        ),
      ),
    );
  }

  Widget _buildConnectionIconsHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
              color: const Color(0xFF0052FF),
              borderRadius: BorderRadius.circular(16)),
          child:
              Image.asset('assets/images/app_icon.png', width: 56, height: 56),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16.0),
          child: Icon(Icons.sync_alt_rounded, color: Colors.grey, size: 32),
        ),
        Container(
          width: 64,
          height: 64,
          alignment: Alignment.center,
          decoration: BoxDecoration(
              color: kWaGreen.withOpacity(0.12),
              borderRadius: BorderRadius.circular(16)),
          child:
              Image.asset('assets/images/whatsapp.png', width: 44, height: 44),
        ),
      ],
    );
  }

  Widget _buildPillButton(String label, VoidCallback onTap) {
    final c = context.allora;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ElevatedButton(
      onPressed: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      style: ElevatedButton.styleFrom(
          backgroundColor: isDark ? c.accent : Colors.black87,
          foregroundColor: Colors.white,
          minimumSize: const Size(double.infinity, 54),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          elevation: 0),
      child: Text(label,
          style: GoogleFonts.inter(fontWeight: FontWeight.w600, fontSize: 16)),
    );
  }

  Widget _buildInstructionCard() {
    final c = context.allora;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
          color: c.surfaceAlt,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: c.outline)),
      child: RichText(
        textAlign: TextAlign.left,
        text: TextSpan(
          style: GoogleFonts.inter(
              color: c.text,
              fontSize: 14,
              fontWeight: FontWeight.w500,
              height: 1.8),
          children: [
            const TextSpan(text: '1. Open WhatsApp and tap '),
            WidgetSpan(
                child: Icon(Icons.more_vert_rounded,
                    size: 16, color: c.text),
                alignment: PlaceholderAlignment.middle),
            const TextSpan(text: ' in the top right\n'),
            const TextSpan(text: '2. Tap: '),
            const TextSpan(
                text: '"Linked devices"\n', style: TextStyle(color: kWaGreen)),
            const TextSpan(text: '3. Select: '),
            const TextSpan(
                text: '"Link a device"\n', style: TextStyle(color: kWaGreen)),
            const TextSpan(text: '4. Tap: '),
            const TextSpan(
                text: '"Link with phone number instead"\n',
                style: TextStyle(color: kWaGreen)),
            const TextSpan(text: '5. Paste the code below'),
          ],
        ),
      ),
    );
  }

  Future<Map<String, String>?> _showCountryPicker() {
    final c = context.allora;
    return showModalBottomSheet<Map<String, String>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: c.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) {
        String query = '';
        return StatefulBuilder(builder: (ctx, setModalState) {
          final filtered = _allCountries
              .where((item) =>
                  item['name']!.toLowerCase().contains(query.toLowerCase()) ||
                  item['code']!.contains(query))
              .toList();
          return SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.7,
            child: Column(
              children: [
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20.0),
                  child: TextField(
                    onChanged: (v) => setModalState(() => query = v),
                    style: GoogleFonts.inter(color: c.text),
                    decoration: InputDecoration(
                        hintText: 'Search country...',
                        hintStyle: GoogleFonts.inter(color: c.textTertiary),
                        prefixIcon:
                            Icon(Icons.search, color: c.textSecondary),
                        filled: true,
                        fillColor: c.surfaceAlt,
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: BorderSide.none)),
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView.builder(
                    itemCount: filtered.length,
                    itemBuilder: (ctx, i) => ListTile(
                      leading: Text(filtered[i]['flag']!,
                          style: const TextStyle(fontSize: 22)),
                      title: Text(filtered[i]['name']!,
                          style: GoogleFonts.inter(color: c.text)),
                      trailing: Text(filtered[i]['code']!,
                          style: GoogleFonts.inter(color: c.textSecondary)),
                      onTap: () => Navigator.pop(ctx, filtered[i]),
                    ),
                  ),
                )
              ],
            ),
          );
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.allora;
    return Container(
      margin: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      decoration: BoxDecoration(
          color: c.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(32))),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildTopDragHandle(),
            _buildTopRightCloseButton(),

            // Do not show connection header if we are on the success screen
            if (!_isConnected) ...[
              const SizedBox(height: 12),
              _buildConnectionIconsHeader(),
              const SizedBox(height: 32),
            ],

            // 🟢 SUCCESS STATE — enterprise connection sequence (no
            // checkmark bursts): staged status text + animated line, then
            // the sheet closes itself and HomeGate drops into the inbox.
            if (_isConnected) ...[
              Center(
                child: ConnectionSequence(
                  brandColor: kWaGreen,
                  artworkAsset: 'assets/images/whatsapp.png',
                  onDone: () {
                    if (mounted) Navigator.pop(context);
                  },
                ),
              ),
            ]

            // 🔴 ERROR STATE
            else if (_sheetError != null) ...[
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.red.shade200)),
                child: Row(
                  children: [
                    Icon(Icons.error_outline_rounded,
                        color: Colors.red.shade400),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(_sheetError!,
                          style: GoogleFonts.inter(
                              color: Colors.red.shade800,
                              fontSize: 14,
                              fontWeight: FontWeight.w500)),
                    ),
                  ],
                ),
              ),
              
              const SizedBox(height: 24),
              _buildPillButton(
                  "Try Again", () => setState(() => _sheetError = null)),
              const SizedBox(height: 12),
              Center(
                child: TextButton(
                  onPressed: () async {
                    setState(() {
                      _sheetError = null;
                      _sheetLoading = true;
                      _debugLogs.add('--- FORCING BRIDGE RESET ---');
                    });
                    
                    try {
                      for (final room in widget.client.rooms) {
                        if (WhatsAppDisconnectService.isManagementRoom(room)) {
                          setState(() => _debugLogs.add('Sending !wa logout to ${room.id}...'));
                          await room.sendTextEvent('!wa logout');
                          await Future.delayed(const Duration(milliseconds: 500));
                          
                          setState(() => _debugLogs.add('Leaving room ${room.id}...'));
                          await room.leave();
                        }
                      }
                      
                      setState(() {
                        _sheetLoading = false;
                        _sheetError = "Bridge reset commands sent. The bot is now clearing your old rooms in the background. Please close the app, wait 1 minute, and open it again.";
                      });
                    } catch (e) {
                      setState(() {
                        _sheetLoading = false;
                        _sheetError = "Failed to reset bridge: $e";
                      });
                    }
                  },
                  child: Text(
                    "Force Reset Bridge (Logout & Clear All)",
                    style: GoogleFonts.inter(
                      color: Colors.red.shade700,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                ),
              ),
            ]

            // ⏳ LOADING STATE (Now properly centered)
            else if (_sheetLoading) ...[
              const Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 32.0),
                  child: ServerRadarAnimation(),
                ),
              ),
              Center(
                child: Text('Requesting pairing code from server...',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.inter(
                        color: c.textSecondary, fontSize: 14)),
              ),
              
              const SizedBox(height: 24),
            ]

            // 🔑 PAIRING CODE GENERATED
            else if (_generatedPairingCode != null) ...[
              Text('Link Device',
                  style: GoogleFonts.inter(
                      color: c.text,
                      fontSize: 20,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text('Enter this code in WhatsApp to link your device.',
                  style: GoogleFonts.inter(
                      color: c.textSecondary, fontSize: 14)),
              const SizedBox(height: 24),
              _buildInstructionCard(),
              const SizedBox(height: 32),
              GestureDetector(
                onTap: () {
                  HapticFeedback.lightImpact();
                  Clipboard.setData(
                      ClipboardData(text: _generatedPairingCode!));
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Code copied!')));
                },
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  decoration: BoxDecoration(
                    color: kWaGreen.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: kWaGreen.withOpacity(0.3)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(_generatedPairingCode!,
                          style: GoogleFonts.inter(
                              fontSize: 32,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 4,
                              color: kWaGreen)),
                      const SizedBox(width: 12),
                      Icon(Icons.copy_rounded,
                          color: kWaGreen.withOpacity(0.8), size: 24),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Center(
                child: Text(
                  'Waiting for you to enter the code…',
                  style: GoogleFonts.inter(
                      color: c.textTertiary, fontSize: 13),
                ),
              ),
              const SizedBox(height: 32),
            ]

            // ⚪ INITIAL INPUT STATE
            else ...[
              Text('Connect WhatsApp',
                  style: GoogleFonts.inter(
                      color: c.text,
                      fontSize: 20,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text('Enter your phone number to receive a secure pairing code.',
                  style: GoogleFonts.inter(
                      color: c.textSecondary, fontSize: 14)),
              const SizedBox(height: 24),
              Text('Phone Number',
                  style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: c.textSecondary)),
              const SizedBox(height: 8),
              Container(
                decoration: BoxDecoration(
                    color: c.surfaceAlt,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: c.outline)),
                child: Row(
                  children: [
                    GestureDetector(
                      onTap: () async {
                        final res = await _showCountryPicker();
                        if (res != null) {
                          setState(() {
                            _selectedCountryCode = res['code']!;
                            _selectedCountryFlag = res['flag']!;
                          });
                        }
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 16),
                        decoration: BoxDecoration(
                            border: Border(
                                right:
                                    BorderSide(color: c.outline))),
                        child: Text(
                            '$_selectedCountryFlag $_selectedCountryCode ▾',
                            style: GoogleFonts.inter(
                                color: c.text,
                                fontWeight: FontWeight.w600)),
                      ),
                    ),
                    Expanded(
                      child: TextField(
                        controller: _phoneController,
                        keyboardType: TextInputType.phone,
                        autofocus: true,
                        style: GoogleFonts.inter(
                            color: c.text, fontSize: 16, fontWeight: FontWeight.w600),
                        decoration: InputDecoration(
                            hintText: 'Enter number',
                            hintStyle:
                                GoogleFonts.inter(color: c.textTertiary),
                            filled: false,
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            disabledBorder: InputBorder.none,
                            contentPadding:
                                const EdgeInsets.symmetric(horizontal: 16)),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),
              _buildPillButton("Continue", _executeUnifiedPipeline),
            ],
          ],
        ),
      ),
    );
  }
}

// ─── RADAR ANIMATION ─────────────────────────────────────────────────────────
class ServerRadarAnimation extends StatefulWidget {
  const ServerRadarAnimation({super.key});

  @override
  State<ServerRadarAnimation> createState() => _ServerRadarAnimationState();
}

class _ServerRadarAnimationState extends State<ServerRadarAnimation>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller =
        AnimationController(vsync: this, duration: const Duration(seconds: 2))
          ..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 120,
      width: 120,
      child: Stack(
        alignment: Alignment.center,
        children: [
          ...List.generate(3, (index) {
            return AnimatedBuilder(
              animation: _controller,
              builder: (context, child) {
                final double value = (_controller.value + (index / 3)) % 1.0;
                return Opacity(
                  opacity: (1.0 - value).clamp(0.0, 1.0),
                  child: Transform.scale(
                    scale: 1.0 + (value * 2.5),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                              color: const Color(0xFF25D366).withOpacity(0.5),
                              width: 2)),
                    ),
                  ),
                );
              },
            );
          }),
          Container(
            width: 50,
            height: 50,
            alignment: Alignment.center,
            child: Image.asset('assets/images/whatsapp.png',
                width: 44, height: 44),
          ),
        ],
      ),
    );
  }
}
