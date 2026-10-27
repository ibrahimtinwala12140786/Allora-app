// ignore_for_file: deprecated_member_use, use_build_context_synchronously

import 'dart:async';
import 'package:flutter/material.dart' hide Visibility;
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:matrix/matrix.dart';
import 'package:pinput/pinput.dart';

import '../../core/theme/app_theme.dart';
import '../../data/services/account_lifecycle.dart';
import '../../data/services/connection_manager.dart';
import '../../data/services/hidden_rooms_store.dart';
import '../bridge/bridge_room_classifier.dart';
import '../networks/network_connection_cache.dart';
import '../networks/network_meta.dart';

// ─── BRAND COLORS ────────────────────────────────────────────────────────────
const Color kTelegramBlue = Color(0xFF29A9EA);

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
  {"name": "Spain", "code": "+34", "flag": "🇪🇸"},
  {"name": "United Arab Emirates", "code": "+971", "flag": "🇦🇪"},
  {"name": "United Kingdom", "code": "+44", "flag": "🇬🇧"},
  {"name": "United States", "code": "+1", "flag": "🇺🇸"},
];

enum TelegramStep { phone, loading, code, password, success }

void showTelegramConnectSheet({
  required BuildContext context,
  required Client client,
  VoidCallback? onConnected,
}) {
  HapticFeedback.lightImpact();
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => TelegramConnectSheet(
      client: client,
      onConnected: onConnected,
    ),
  );
}

class TelegramConnectSheet extends StatefulWidget {
  final Client client;
  final VoidCallback? onConnected;

  const TelegramConnectSheet({
    super.key,
    required this.client,
    this.onConnected,
  });

  @override
  State<TelegramConnectSheet> createState() => _TelegramConnectSheetState();
}

class _TelegramConnectSheetState extends State<TelegramConnectSheet> {
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  StreamSubscription<Event>? _activeSub;
  Room? _botRoom;

  TelegramStep _currentStep = TelegramStep.phone;
  String? _sheetError;
  String _loadingMessage = 'Connecting to Telegram bridge...';
  String _selectedCountryCode = "+91";
  String _selectedCountryFlag = "🇮🇳";
  bool _obscurePassword = true;
  String? _accountIdentifier;
  bool _showLogs = true;
  final List<String> _debugLogs = ['Ready to connect to Telegram bridge.'];

  void _addLog(String msg) {
    debugPrint('[TelegramBridge] $msg');
    if (mounted) {
      setState(() {
        _debugLogs.add(msg);
      });
    }
  }

  @override
  void initState() {
    super.initState();
    final cached = NetworkConnectionCache.get(NetworkId.telegram);
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
    _passwordController.dispose();
    _activeSub?.cancel();
    super.dispose();
  }

  Future<Room?> _resolveBotRoom() async {
    if (_botRoom != null) return _botRoom;

    final userDomain = widget.client.userID!.split(':').last;
    final botMxidFull = '@telegrambot:$userDomain';
    final botMxidAlt = '@telegram:$userDomain';

    _addLog('Finding Telegram bridge bot room...');

    // 1. Try finding existing management room via AccountLifecycleService
    _botRoom = AccountLifecycleService.findManagementRoom(
        widget.client, NetworkId.telegram);

    // 2. Check directChatMatrixID, room name, or bot participants (EXCLUDE puppet rooms)
    if (_botRoom == null) {
      for (final r in widget.client.rooms) {
        if (r.encrypted) continue;
        final hasPuppet = r.getParticipants().any((p) {
          final id = p.id.toLowerCase();
          return id.contains('_telegram_') || id.contains('@telegram_') || id.contains('@tg_');
        });
        if (hasPuppet) continue; // Never select a bridged portal room!

        final dm = (r.directChatMatrixID ?? '').toLowerCase();
        final name = r.displayname.toLowerCase().trim();
        if (dm == botMxidFull.toLowerCase() ||
            name == 'telegram bridge' ||
            name == 'telegram bridge bot') {
          _botRoom = r;
          break;
        }
        for (final m in r.getParticipants()) {
          final pid = m.id.toLowerCase();
          if (pid == botMxidFull.toLowerCase() || pid.startsWith('@telegrambot:')) {
            _botRoom = r;
            break;
          }
        }
        if (_botRoom != null) break;
      }
    }

    // 3. Create DM room if not present
    if (_botRoom == null) {
      _addLog('Creating Telegram bridge DM room...');
      try {
        final roomId = await widget.client.createRoom(
          name: 'Telegram Bridge',
          isDirect: false,
          preset: CreateRoomPreset.privateChat,
          invite: [botMxidFull],
        );

        int retries = 0;
        while (_botRoom == null && retries < 15) {
          _botRoom = widget.client.getRoomById(roomId);
          if (_botRoom != null) break;
          try {
            await widget.client.sync();
          } catch (_) {}
          await Future.delayed(const Duration(milliseconds: 300));
          retries++;
        }
      } catch (e) {
        _addLog('Create room error: $e');
      }
    } else {
      _addLog('Found bot room: ${_botRoom!.id}');
    }

    return _botRoom;
  }

  void _listenToBot() {
    _activeSub?.cancel();
    _activeSub = widget.client.onTimelineEvent.stream.listen((Event event) {
      if (_botRoom == null ||
          event.roomId != _botRoom!.id ||
          event.senderId == widget.client.userID) {
        return;
      }

      final body =
          (event.content['body'] as String? ?? '').trim();
      if (body.isEmpty) return;

      final lower = body.toLowerCase();
      _addLog('📥 Bot: $body');

      // 1. SUCCESS CHECK
      if (lower.contains('logged in') ||
          lower.contains('successfully') ||
          lower.contains('login successful') ||
          lower.contains('connected to telegram') ||
          lower.contains('authenticated')) {
        HapticFeedback.heavyImpact();
        
        final userMatch = RegExp(r'logged in as ([^\n\r\(\)]+)', caseSensitive: false).firstMatch(body);
        if (userMatch != null) {
          _accountIdentifier = userMatch.group(1)?.trim();
        }
        _handleSuccessfulConnection();
        return;
      }

      // 2. CODE PROMPT CHECK
      if (lower.contains('enter the code') ||
          lower.contains('verification code') ||
          lower.contains('login code') ||
          lower.contains('enter code') ||
          (lower.contains('code') && (lower.contains('telegram') || lower.contains('sms')))) {
        HapticFeedback.mediumImpact();
        setState(() {
          _currentStep = TelegramStep.code;
          _sheetError = null;
        });
        return;
      }

      // 3. 2FA PASSWORD CHECK
      if (lower.contains('two-step') ||
          lower.contains('2fa') ||
          lower.contains('cloud password') ||
          lower.contains('enter your password') ||
          lower.contains('enter password')) {
        HapticFeedback.mediumImpact();
        setState(() {
          _currentStep = TelegramStep.password;
          _sheetError = null;
        });
        return;
      }

      // 4. PHONE PROMPT CHECK
      if (lower.contains('phone number') ||
          lower.contains('enter phone') ||
          lower.contains('reply with your phone')) {
        if (_accountIdentifier != null && _accountIdentifier!.isNotEmpty) {
          _addLog('📤 Bot requested phone number, sending: !tg $_accountIdentifier');
          _botRoom?.sendTextEvent('!tg $_accountIdentifier');
        } else if (_currentStep == TelegramStep.loading) {
          setState(() {
            _currentStep = TelegramStep.phone;
          });
        }
        return;
      }

      // 5. ERROR CHECK
      if (lower.contains('invalid') ||
          lower.contains('error') ||
          lower.contains('failed') ||
          lower.contains('incorrect') ||
          lower.contains('flood_wait') ||
          lower.contains('expired')) {
        HapticFeedback.heavyImpact();
        setState(() {
          _sheetError = body;
          if (_currentStep == TelegramStep.loading) {
            _currentStep = TelegramStep.phone;
          }
        });
      }
    });
  }

  Future<void> _submitPhone() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final rawNumber = _phoneController.text.trim();
    if (rawNumber.isEmpty || rawNumber.length < 5) {
      setState(() {
        _sheetError = 'Please enter a valid phone number.';
      });
      return;
    }

    setState(() {
      _sheetError = null;
      _currentStep = TelegramStep.loading;
      _loadingMessage = 'Connecting to Telegram bridge...';
    });

    try {
      final room = await _resolveBotRoom();
      if (room == null) {
        setState(() {
          _currentStep = TelegramStep.phone;
          _sheetError = "Could not reach Telegram Bridge. Ensure bridge is running.";
        });
        return;
      }

      _listenToBot();

      String cleanInput = rawNumber.replaceAll(RegExp(r'[^\d]'), '');
      String codeOnly = _selectedCountryCode.replaceAll(RegExp(r'[^\d]'), '');
      if (cleanInput.startsWith(codeOnly) && cleanInput.length > 10) {
        cleanInput = cleanInput.substring(codeOnly.length);
      }
      final sanitizedNumber = '+$codeOnly$cleanInput';
      _accountIdentifier = sanitizedNumber;

      // Start fresh with cancel then login phone
      try {
        _addLog('📤 Sent: !tg cancel');
        await room.sendTextEvent('!tg cancel');
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 400));

      setState(() => _loadingMessage = 'Requesting Telegram login code...');
      _addLog('📤 Sent: !tg login phone');
      await room.sendTextEvent('!tg login phone');

      // Send the phone number to the bot
      await Future.delayed(const Duration(seconds: 1));
      _addLog('📤 Sent: !tg $sanitizedNumber');
      await room.sendTextEvent('!tg $sanitizedNumber');
    } catch (e) {
      _addLog('Error: $e');
      setState(() {
        _currentStep = TelegramStep.phone;
        _sheetError = "Failed to communicate with bridge: $e";
      });
    }
  }

  Future<void> _submitCode(String code) async {
    final cleanCode = code.trim();
    if (cleanCode.isEmpty) return;

    setState(() {
      _sheetError = null;
      _currentStep = TelegramStep.loading;
      _loadingMessage = 'Verifying login code...';
    });

    try {
      _addLog('📤 Sent verification code: !tg $cleanCode');
      await _botRoom?.sendTextEvent('!tg $cleanCode');
    } catch (e) {
      _addLog('Code error: $e');
      setState(() {
        _currentStep = TelegramStep.code;
        _sheetError = 'Failed to send verification code: $e';
      });
    }
  }

  Future<void> _submitPassword() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final pw = _passwordController.text;
    if (pw.isEmpty) return;

    setState(() {
      _sheetError = null;
      _currentStep = TelegramStep.loading;
      _loadingMessage = 'Verifying 2FA password...';
    });

    try {
      _addLog('📤 Sent: !tg [2FA Password]');
      await _botRoom?.sendTextEvent('!tg $pw');
    } catch (e) {
      _addLog('Password error: $e');
      setState(() {
        _currentStep = TelegramStep.password;
        _sheetError = 'Failed to send password: $e';
      });
    }
  }

  Future<void> _handleSuccessfulConnection() async {
    _activeSub?.cancel();
    _addLog('✅ Telegram connected successfully');
    setState(() {
      _currentStep = TelegramStep.success;
      _sheetError = null;
    });

    final label = _accountIdentifier ?? _phoneController.text.trim();
    await NetworkConnectionCache.markConnected(
      NetworkId.telegram,
      force: true,
      accountLabel: label.isNotEmpty ? label : 'Connected',
      lastSynced: 'Just now',
    );
    await HiddenRoomsStore.clear(NetworkId.telegram);
    ConnectionManager.instance?.noteJustConnected(
      NetworkId.telegram,
      syncFor: const Duration(seconds: 15),
    );
    BridgeRoomClassifier.clearCacheForNetwork(NetworkId.telegram);

    // Send Telegram sync-chats to bridge bot to immediately pull all chats
    try {
      if (_botRoom != null) {
        _addLog('📤 Sent: !tg sync-chats');
        unawaited(_botRoom!.sendTextEvent('!tg sync-chats'));
      }
    } catch (_) {}

    unawaited(widget.client.sync());
    unawaited(Future.delayed(const Duration(seconds: 2), () => widget.client.sync()));
    unawaited(Future.delayed(const Duration(seconds: 5), () => widget.client.sync()));
    unawaited(Future.delayed(const Duration(seconds: 10), () => widget.client.sync()));

    widget.onConnected?.call();

    await Future.delayed(const Duration(milliseconds: 1600));
    if (mounted && Navigator.canPop(context)) {
      Navigator.pop(context);
    }
  }

  Future<void> _cancelFlow() async {
    _activeSub?.cancel();
    try {
      if (_botRoom != null) {
        _addLog('📤 Sent: !tg cancel');
        await _botRoom!.sendTextEvent('!tg cancel');
      }
    } catch (_) {}
    if (mounted && Navigator.canPop(context)) {
      Navigator.pop(context);
    }
  }

  Future<Map<String, String>?> _showCountryPicker() {
    return showModalBottomSheet<Map<String, String>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.allora.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) {
        String query = '';
        return StatefulBuilder(builder: (ctx, setModalState) {
          final filtered = _allCountries
              .where((c) =>
                  c['name']!.toLowerCase().contains(query.toLowerCase()) ||
                  c['code']!.contains(query))
              .toList();
          return SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.7,
            child: Column(
              children: [
                const SizedBox(height: 16),
                Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: context.allora.outline,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20.0),
                  child: TextField(
                    onChanged: (v) => setModalState(() => query = v),
                    style: GoogleFonts.inter(color: context.allora.text),
                    decoration: InputDecoration(
                        hintText: 'Search country...',
                        hintStyle: GoogleFonts.inter(
                            color: context.allora.textSecondary),
                        prefixIcon: Icon(Icons.search,
                            color: context.allora.textSecondary),
                        filled: true,
                        fillColor: context.allora.surfaceAlt,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 12),
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
                          style: GoogleFonts.inter(
                              color: context.allora.text,
                              fontWeight: FontWeight.w500)),
                      trailing: Text(filtered[i]['code']!,
                          style: GoogleFonts.inter(
                              color: context.allora.textSecondary,
                              fontWeight: FontWeight.w600)),
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

  Widget _buildTopDragHandle() => Center(
        child: Container(
          width: 38,
          height: 4,
          margin: const EdgeInsets.only(bottom: 20),
          decoration: BoxDecoration(
              color: context.allora.outline,
              borderRadius: BorderRadius.circular(2)),
        ),
      );

  Widget _buildPrimaryButton(String label, VoidCallback onTap) {
    return ElevatedButton(
      onPressed: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      style: ElevatedButton.styleFrom(
          backgroundColor: kTelegramBlue,
          foregroundColor: Colors.white,
          minimumSize: const Size(double.infinity, 52),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          elevation: 0),
      child: Text(label,
          style: GoogleFonts.inter(
              fontWeight: FontWeight.w600, fontSize: 16, letterSpacing: 0.2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.allora;
    final defaultPinTheme = PinTheme(
      width: 52,
      height: 60,
      textStyle: GoogleFonts.inter(
          fontSize: 22, color: c.text, fontWeight: FontWeight.w700),
      decoration: BoxDecoration(
          border: Border.all(color: c.outline, width: 1.5),
          borderRadius: BorderRadius.circular(14),
          color: c.surface),
    );

    final focusedPinTheme = PinTheme(
      width: 52,
      height: 60,
      textStyle: GoogleFonts.inter(
          fontSize: 22, color: c.text, fontWeight: FontWeight.w700),
      decoration: BoxDecoration(
          border: Border.all(color: kTelegramBlue, width: 2),
          borderRadius: BorderRadius.circular(14),
          color: c.surface),
    );

    return Container(
      margin: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      decoration: BoxDecoration(
          color: c.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28))),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildTopDragHandle(),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: kTelegramBlue.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  alignment: Alignment.center,
                  child: const Icon(Icons.send_rounded,
                      color: kTelegramBlue, size: 22),
                ),
                Row(
                  children: [
                    IconButton(
                      icon: Icon(
                        _showLogs ? Icons.terminal_rounded : Icons.info_outline_rounded,
                        color: _showLogs ? kTelegramBlue : c.textSecondary,
                        size: 20,
                      ),
                      tooltip: 'Bridge Command Logs',
                      onPressed: () => setState(() => _showLogs = !_showLogs),
                    ),
                    const SizedBox(width: 4),
                    GestureDetector(
                      onTap: _cancelFlow,
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                            color: c.surfaceAlt, shape: BoxShape.circle),
                        child: Icon(Icons.close_rounded,
                            color: c.textSecondary, size: 18),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 18),

            if (_sheetError != null) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                    color: c.danger.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: c.danger.withValues(alpha: 0.25))),
                child: Row(
                  children: [
                    Icon(Icons.error_outline_rounded,
                        color: c.danger, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                        child: Text(_sheetError!,
                            style: GoogleFonts.inter(
                                color: c.danger,
                                fontSize: 13.5,
                                fontWeight: FontWeight.w500,
                                height: 1.35))),
                  ],
                ),
              ),
              const SizedBox(height: 18),
            ],

            if (_currentStep == TelegramStep.success) ...[
              Center(
                child: Column(
                  children: [
                    const SizedBox(height: 24),
                    Container(
                      width: 76,
                      height: 76,
                      decoration: BoxDecoration(
                          color: c.success.withValues(alpha: 0.12),
                          shape: BoxShape.circle,
                          border: Border.all(
                              color: c.success.withValues(alpha: 0.3), width: 2)),
                      child: Center(
                          child: Icon(Icons.check_circle_rounded,
                              color: c.success, size: 44)),
                    ),
                    const SizedBox(height: 20),
                    Text('Telegram Connected',
                        style: GoogleFonts.inter(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            color: c.text)),
                    const SizedBox(height: 6),
                    Text('Your conversations and channels are now syncing.',
                        style: GoogleFonts.inter(
                            fontSize: 14, color: c.textSecondary)),
                    const SizedBox(height: 32),
                    _buildPrimaryButton("Done", () => Navigator.pop(context)),
                  ],
                ),
              ),
            ] else if (_currentStep == TelegramStep.loading) ...[
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 36.0),
                  child: Column(
                    children: [
                      const SizedBox(
                        width: 36,
                        height: 36,
                        child: CircularProgressIndicator(
                          strokeWidth: 3,
                          valueColor:
                              AlwaysStoppedAnimation<Color>(kTelegramBlue),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(_loadingMessage,
                          textAlign: TextAlign.center,
                          style: GoogleFonts.inter(
                              color: c.textSecondary,
                              fontSize: 14.5,
                              fontWeight: FontWeight.w500)),
                    ],
                  ),
                ),
              ),
            ] else if (_currentStep == TelegramStep.code) ...[
              Text('Enter Telegram Code',
                  style: GoogleFonts.inter(
                      color: c.text,
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.3)),
              const SizedBox(height: 6),
              Text('Enter the login code sent to your Telegram app.',
                  style: GoogleFonts.inter(
                      color: c.textSecondary, fontSize: 14)),
              const SizedBox(height: 28),
              Center(
                child: Pinput(
                  length: 5,
                  autofocus: true,
                  defaultPinTheme: defaultPinTheme,
                  focusedPinTheme: focusedPinTheme,
                  onCompleted: _submitCode,
                ),
              ),
              const SizedBox(height: 28),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  TextButton(
                    onPressed: () {
                      setState(() {
                        _currentStep = TelegramStep.phone;
                        _sheetError = null;
                      });
                    },
                    child: Text('Change phone number',
                        style: GoogleFonts.inter(
                            color: kTelegramBlue,
                            fontWeight: FontWeight.w600,
                            fontSize: 14)),
                  ),
                ],
              ),
            ] else if (_currentStep == TelegramStep.password) ...[
              Text('Two-Step Verification',
                  style: GoogleFonts.inter(
                      color: c.text,
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.3)),
              const SizedBox(height: 6),
              Text('Your Telegram account is protected by 2FA. Enter your password.',
                  style: GoogleFonts.inter(
                      color: c.textSecondary, fontSize: 14)),
              const SizedBox(height: 22),
              TextField(
                controller: _passwordController,
                obscureText: _obscurePassword,
                autofocus: true,
                style: GoogleFonts.inter(color: c.text, fontSize: 15),
                decoration: InputDecoration(
                  hintText: 'Telegram 2FA Password',
                  hintStyle: GoogleFonts.inter(color: c.textTertiary),
                  filled: true,
                  fillColor: c.surfaceAlt,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide.none),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscurePassword
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      color: c.textSecondary,
                    ),
                    onPressed: () =>
                        setState(() => _obscurePassword = !_obscurePassword),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              _buildPrimaryButton("Submit Password", _submitPassword),
            ] else ...[
              Text('Connect Telegram',
                  style: GoogleFonts.inter(
                      color: c.text,
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.3)),
              const SizedBox(height: 6),
              Text('Enter your phone number to sign in via the Telegram bridge.',
                  style: GoogleFonts.inter(
                      color: c.textSecondary, fontSize: 14, height: 1.4)),
              const SizedBox(height: 22),
              Text('PHONE NUMBER',
                  style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                      color: c.textSecondary)),
              const SizedBox(height: 8),
              Container(
                decoration: BoxDecoration(
                    color: c.surfaceAlt,
                    borderRadius: BorderRadius.circular(16)),
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
                            horizontal: 14, vertical: 16),
                        child: Row(
                          children: [
                            Text(_selectedCountryFlag,
                                style: const TextStyle(fontSize: 18)),
                            const SizedBox(width: 6),
                            Text(_selectedCountryCode,
                                style: GoogleFonts.inter(
                                    color: c.text,
                                    fontWeight: FontWeight.w600,
                                    fontSize: 14.5)),
                            const SizedBox(width: 4),
                            Icon(Icons.keyboard_arrow_down_rounded,
                                color: c.textSecondary, size: 18),
                          ],
                        ),
                      ),
                    ),
                    Container(
                      width: 1,
                      height: 28,
                      color: c.outline.withValues(alpha: 0.5),
                    ),
                    Expanded(
                      child: TextField(
                        controller: _phoneController,
                        keyboardType: TextInputType.phone,
                        autofocus: true,
                        style: GoogleFonts.inter(
                            color: c.text,
                            fontSize: 15.5,
                            fontWeight: FontWeight.w500),
                        decoration: InputDecoration(
                            hintText: 'Enter phone number',
                            hintStyle: GoogleFonts.inter(color: c.textTertiary),
                            filled: false,
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            disabledBorder: InputBorder.none,
                            contentPadding:
                                const EdgeInsets.symmetric(horizontal: 14)),
                        onSubmitted: (_) => _submitPhone(),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              _buildPrimaryButton("Continue", _submitPhone),
            ],

            if (_showLogs) ...[
              const SizedBox(height: 20),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E2E),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Bridge Activity Log',
                            style: GoogleFonts.firaCode(
                                color: const Color(0xFF89B4FA),
                                fontSize: 11,
                                fontWeight: FontWeight.w700)),
                        Text('${_debugLogs.length} events',
                            style: GoogleFonts.firaCode(
                                color: Colors.white54, fontSize: 10)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 140),
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: _debugLogs.map(
                                (log) => Padding(
                                  padding: const EdgeInsets.only(bottom: 4),
                                  child: Text(
                                    log,
                                    style: GoogleFonts.firaCode(
                                      color: log.startsWith('📤')
                                          ? const Color(0xFFA6E3A1)
                                          : log.startsWith('📥')
                                              ? const Color(0xFF89DCEB)
                                              : log.contains('Error') || log.contains('error')
                                                  ? const Color(0xFFF38BA8)
                                                  : Colors.white70,
                                      fontSize: 10.5,
                                    ),
                                  ),
                                ),
                              ).toList(),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
