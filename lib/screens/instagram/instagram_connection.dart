// ignore_for_file: unnecessary_non_null_assertion, unused_element, curly_braces_in_flow_control_structures, unused_import, unnecessary_string_interpolations, use_build_context_synchronously, deprecated_member_use

import 'dart:async';
import 'package:flutter/material.dart' hide Visibility;
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:matrix/matrix.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/theme/app_theme.dart';
import '../../data/services/instagram_service.dart';
import '../networks/network_connection_cache.dart';
import '../networks/network_meta.dart';

// ─── BRAND COLORS ────────────────────────────────────────────────────────────

const Color kAlloraBlue = Color(0xFF0052FF);
const Color kInstagramPink = Color(0xFFE1306C);
const Color kInstagramPurple = Color(0xFF833AB4);
const Color kInstagramOrange = Color(0xFFF77737);

// ─── PUBLIC ENTRY POINT ───────────────────────────────────────────────────────

/// Opens the direct Instagram "connect account" bottom sheet.
void showInstagramConnectSheet({
  required BuildContext context,
  required Client client,
  VoidCallback? onConnected,
}) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => InstagramConnectSheet(
      client: client,
      onConnected: onConnected,
    ),
  );
}

// ─── THE CONNECT SHEET ────────────────────────────────────────────────────────

class InstagramConnectSheet extends StatefulWidget {
  final Client client;
  final VoidCallback? onConnected;

  const InstagramConnectSheet({
    super.key,
    required this.client,
    this.onConnected,
  });

  @override
  State<InstagramConnectSheet> createState() => _InstagramConnectSheetState();
}

class _InstagramConnectSheetState extends State<InstagramConnectSheet> {
  final TextEditingController _tokenController = TextEditingController();
  final TextEditingController _usernameController = TextEditingController();

  bool _sheetLoading = false;
  String? _sheetError;
  bool _connected = false;
  String? _connectedUsername;

  bool _isTestingWebhook = false;
  bool? _webhookTestSuccess;

  int _selectedTab = 0; // 0 = Token Connect, 1 = Webhook Info

  @override
  void initState() {
    super.initState();
    _checkExistingConnection();
  }

  Future<void> _checkExistingConnection() async {
    final status = NetworkConnectionCache.get(NetworkId.instagram);
    if (status.connected) {
      final saved = await InstagramService.instance.getSavedAccount();
      if (mounted) {
        setState(() {
          _connected = true;
          _connectedUsername = saved['username'] ?? status.accountLabel?.replaceAll('@', '') ?? 'Connected';
        });
      }
    }
  }

  @override
  void dispose() {
    _tokenController.dispose();
    _usernameController.dispose();
    super.dispose();
  }

  Future<void> _testWebhook() async {
    setState(() {
      _isTestingWebhook = true;
      _webhookTestSuccess = null;
    });

    final success = await InstagramService.instance.testWebhookVerification();

    if (mounted) {
      setState(() {
        _isTestingWebhook = false;
        _webhookTestSuccess = success;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            success
                ? 'Webhook endpoint is active and responding with HTTP 200!'
                : 'Webhook ping failed. Please check network connection.',
          ),
          backgroundColor: success ? const Color(0xFF10B981) : Colors.redAccent,
        ),
      );
    }
  }

  Future<void> _connectWithToken() async {
    FocusManager.instance.primaryFocus?.unfocus();

    final token = _tokenController.text.trim();
    final username = _usernameController.text.trim();

    if (token.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter or paste your Instagram Access Token.'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    setState(() {
      _sheetError = null;
      _sheetLoading = true;
    });

    final res = await InstagramService.instance.connectWithAccessToken(
      accessToken: token,
      fallbackUsername: username.isNotEmpty ? username : null,
    );

    if (!mounted) return;

    if (res['success'] == true) {
      setState(() {
        _sheetLoading = false;
        _connected = true;
        _connectedUsername = res['username'] ?? 'Connected';
      });
      widget.onConnected?.call();
    } else {
      setState(() {
        _sheetLoading = false;
        _sheetError = res['error'] ?? 'Connection failed. Please check your token.';
      });
    }
  }

  void _copyToClipboard(String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    HapticFeedback.lightImpact();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$label copied to clipboard!'),
        duration: const Duration(seconds: 2),
        backgroundColor: kAlloraBlue,
      ),
    );
  }

  // ─── UI BUILDERS ─────────────────────────────────────────────────────────

  Widget _buildTopRightCloseButton() {
    final c = context.allora;
    return Align(
      alignment: Alignment.centerRight,
      child: GestureDetector(
        onTap: () => Navigator.pop(context),
        child: Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: c.surfaceAlt,
            shape: BoxShape.circle,
          ),
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
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: kAlloraBlue,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Image.asset('assets/images/app_icon.png', width: 48, height: 48),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16.0),
          child: Icon(Icons.sync_alt_rounded, color: Colors.grey, size: 28),
        ),
        Container(
          width: 56,
          height: 56,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [kInstagramPurple, kInstagramPink, kInstagramOrange],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(16),
          ),
          child: const Icon(Icons.camera_alt_rounded, color: Colors.white, size: 30),
        ),
      ],
    );
  }

  Widget _buildPillButton(String label, VoidCallback onTap, {Color? bg}) {
    return ElevatedButton(
      onPressed: onTap,
      style: ElevatedButton.styleFrom(
        backgroundColor: bg ?? kAlloraBlue,
        foregroundColor: Colors.white,
        minimumSize: const Size(double.infinity, 52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
        elevation: 0,
      ),
      child: Text(
        label,
        style: GoogleFonts.poppins(fontWeight: FontWeight.bold, fontSize: 16),
      ),
    );
  }

  Widget _buildCopyRow({
    required String label,
    required String value,
    required VoidCallback onCopy,
  }) {
    final c = context.allora;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.outline.withOpacity(0.5)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: GoogleFonts.poppins(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: c.textSecondary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.firaCode(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: c.text,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.copy_rounded, size: 18),
            color: kAlloraBlue,
            onPressed: onCopy,
            tooltip: 'Copy $label',
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.allora;
    return Container(
      margin: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildTopRightCloseButton(),
            const SizedBox(height: 8),
            _buildConnectionIconsHeader(),
            const SizedBox(height: 16),

            Text(
              'Instagram Messaging API',
              textAlign: TextAlign.center,
              style: GoogleFonts.poppins(
                color: c.text,
                fontWeight: FontWeight.bold,
                fontSize: 18,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Direct Meta Webhook & Graph API connection',
              textAlign: TextAlign.center,
              style: GoogleFonts.poppins(color: c.textTertiary, fontSize: 13),
            ),

            const SizedBox(height: 20),

            // 🟢 STATE: SUCCESS
            if (_connected) ...[
              const Icon(Icons.check_circle_rounded, color: Color(0xFF10B981), size: 56),
              const SizedBox(height: 12),
              Text(
                'Instagram Connected',
                style: GoogleFonts.poppins(
                  color: c.text,
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Account: @${_connectedUsername ?? "Connected"}\nWebhook events are automatically ingested.',
                textAlign: TextAlign.center,
                style: GoogleFonts.poppins(color: c.textSecondary, fontSize: 13),
              ),
              const SizedBox(height: 24),
              _buildPillButton("Done", () => Navigator.pop(context)),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () async {
                  await InstagramService.instance.disconnect();
                  setState(() {
                    _connected = false;
                    _connectedUsername = null;
                  });
                },
                child: Text(
                  'Disconnect Account',
                  style: GoogleFonts.poppins(color: Colors.redAccent, fontSize: 14),
                ),
              ),
            ]

            // 🟢 STATE: LOADING
            else if (_sheetLoading) ...[
              const SizedBox(height: 24),
              const CircularProgressIndicator(color: kInstagramPink),
              const SizedBox(height: 20),
              Text(
                'Validating & saving Instagram credentials...',
                style: GoogleFonts.poppins(color: c.textSecondary, fontSize: 14),
              ),
              const SizedBox(height: 24),
            ]

            // 🟢 STATE: SETUP & CONNECT
            else ...[
              if (_sheetError != null) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: Colors.redAccent.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.redAccent.withOpacity(0.3)),
                  ),
                  child: Text(
                    _sheetError!,
                    textAlign: TextAlign.center,
                    style: GoogleFonts.poppins(
                      color: Colors.redAccent,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],

              // Navigation tab pills
              Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () => setState(() => _selectedTab = 0),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(
                          color: _selectedTab == 0 ? kAlloraBlue : c.surfaceAlt,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          '1. Connect Token',
                          style: GoogleFonts.poppins(
                            color: _selectedTab == 0 ? Colors.white : c.textSecondary,
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: GestureDetector(
                      onTap: () => setState(() => _selectedTab = 1),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(
                          color: _selectedTab == 1 ? kAlloraBlue : c.surfaceAlt,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          '2. Webhook Setup',
                          style: GoogleFonts.poppins(
                            color: _selectedTab == 1 ? Colors.white : c.textSecondary,
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 18),

              if (_selectedTab == 0) ...[
                // OAuth Button
                Container(
                  width: double.infinity,
                  height: 52,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [kInstagramPurple, kInstagramPink, kInstagramOrange],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(26),
                  ),
                  child: ElevatedButton.icon(
                    onPressed: () async {
                      final url = InstagramService.getOAuthLoginUrl();
                      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
                    },
                    icon: const Icon(Icons.camera_alt_rounded, color: Colors.white, size: 20),
                    label: Text(
                      'Log In with Instagram',
                      style: GoogleFonts.poppins(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                        color: Colors.white,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.transparent,
                      shadowColor: Colors.transparent,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(child: Divider(color: c.outline)),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Text(
                        'OR ENTER ACCESS TOKEN',
                        style: GoogleFonts.poppins(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: c.textTertiary,
                        ),
                      ),
                    ),
                    Expanded(child: Divider(color: c.outline)),
                  ],
                ),
                const SizedBox(height: 14),
                Text(
                  'Paste your Access Token generated in Step 1 of Meta Developer Console ("Generate access tokens")',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.poppins(color: c.textTertiary, fontSize: 12),
                ),
                const SizedBox(height: 14),
                Container(
                  decoration: BoxDecoration(
                    color: c.surfaceAlt,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: c.outline),
                  ),
                  child: TextField(
                    controller: _tokenController,
                    maxLines: 2,
                    style: GoogleFonts.poppins(color: c.text, fontSize: 13),
                    decoration: InputDecoration(
                      hintText: 'EAAG...',
                      hintStyle: GoogleFonts.poppins(color: c.textTertiary, fontSize: 13),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.all(14),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.paste_rounded, size: 20),
                        onPressed: () async {
                          final data = await Clipboard.getData('text/plain');
                          if (data?.text != null) {
                            _tokenController.text = data!.text!.trim();
                          }
                        },
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Container(
                  decoration: BoxDecoration(
                    color: c.surfaceAlt,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: c.outline),
                  ),
                  child: TextField(
                    controller: _usernameController,
                    style: GoogleFonts.poppins(color: c.text, fontSize: 14),
                    decoration: InputDecoration(
                      hintText: 'Username (optional)',
                      hintStyle: GoogleFonts.poppins(color: c.textTertiary, fontSize: 14),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                _buildPillButton("Connect Instagram Account", _connectWithToken),
              ] else ...[
                // Webhook Info View
                Text(
                  'Copy these into Meta for Developers -> "Configure webhooks":',
                  style: GoogleFonts.poppins(
                    color: c.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 12),
                _buildCopyRow(
                  label: 'CALLBACK URL (WEBHOOK)',
                  value: InstagramService.webhookUrl,
                  onCopy: () => _copyToClipboard(InstagramService.webhookUrl, 'Callback URL'),
                ),
                _buildCopyRow(
                  label: 'VERIFY TOKEN',
                  value: InstagramService.defaultVerifyToken,
                  onCopy: () => _copyToClipboard(InstagramService.defaultVerifyToken, 'Verify Token'),
                ),
                _buildCopyRow(
                  label: 'REDIRECT URL (BUSINESS LOGIN)',
                  value: InstagramService.oauthRedirectUrl,
                  onCopy: () => _copyToClipboard(InstagramService.oauthRedirectUrl, 'Redirect URL'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _isTestingWebhook ? null : _testWebhook,
                  icon: _isTestingWebhook
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          _webhookTestSuccess == true
                              ? Icons.check_circle_rounded
                              : Icons.health_and_safety_rounded,
                          color: _webhookTestSuccess == true
                              ? const Color(0xFF10B981)
                              : kAlloraBlue,
                          size: 18,
                        ),
                  label: Text(
                    _isTestingWebhook
                        ? 'Testing...'
                        : (_webhookTestSuccess == true
                            ? 'Webhook Verified (HTTP 200)'
                            : 'Test Webhook Verification'),
                    style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 44),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}
