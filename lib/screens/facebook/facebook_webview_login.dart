// ignore_for_file: deprecated_member_use, use_build_context_synchronously
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:matrix/matrix.dart';
import 'package:pinput/pinput.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../../core/theme/app_theme.dart';
import '../../data/services/connection_manager.dart';
import '../../data/services/hidden_rooms_store.dart';
import '../networks/network_connection_cache.dart';
import '../networks/network_meta.dart';
import 'facebook_cookie_extractor.dart';
import 'facebook_disconnect.dart';
import 'facebook_messenger_connection.dart';

const String kPrimaryMessengerLoginUrl = 'https://www.messenger.com/?no_redirect=true';
const String kFacebookMobileLoginUrl = 'https://m.facebook.com/login';

/// Clean Full-Screen Web Login Screen for Facebook Messenger (Beeper-Style).
/// Directly renders the login web view, automatically intercepts cookies upon login,
/// and transmits them into the Matrix bridge bot.
class FacebookMessengerWebLoginView extends StatefulWidget {
  final Client client;
  final VoidCallback? onConnected;
  final String? initialUrl;
  final String? initialEmail;
  final String? initialPassword;

  const FacebookMessengerWebLoginView({
    super.key,
    required this.client,
    this.onConnected,
    this.initialUrl,
    this.initialEmail,
    this.initialPassword,
  });

  /// Opens the full-screen Facebook Messenger web login screen directly.
  static Future<void> open(
    BuildContext context, {
    required Client client,
    VoidCallback? onConnected,
    String? initialUrl,
    String? initialEmail,
    String? initialPassword,
  }) async {
    HapticFeedback.lightImpact();
    await Navigator.push(
      context,
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => FacebookMessengerWebLoginView(
          client: client,
          onConnected: onConnected,
          initialUrl: initialUrl,
          initialEmail: initialEmail,
          initialPassword: initialPassword,
        ),
      ),
    );
  }

  @override
  State<FacebookMessengerWebLoginView> createState() =>
      _FacebookMessengerWebLoginViewState();
}

class _FacebookMessengerWebLoginViewState
    extends State<FacebookMessengerWebLoginView> {
  late final WebViewController _controller;
  final WebViewCookieManager _cookieManager = WebViewCookieManager();

  bool _isLoading = true;
  double _loadingProgress = 0.0;
  String _currentUrl = '';

  Map<String, String> _capturedCookies = {};
  bool _hasValidSession = false;
  bool _isTransmitting = false;
  bool _sendAsCurl = true;
  String? _capturedRealCurl;
  bool _hasSentCookiesForPrompt = false;
  String? _extractedFbDtsg;
  String? _extractedSpinR;
  String? _extractedJazoest;
  String? _extractedUserId;
  bool _isBotWaitingForCookies = false;
  bool _hasLoadedBotUrl = false;
  String? _pendingPayload;
  String _statusMessage = '';
  Timer? _transmitTimeoutTimer;
  StreamSubscription<Event>? _botSub;
  Room? _botRoom;
  final List<String> _debugLogs = [];

  static const Color kMessengerBlue = Color(0xFF0084FF);
  static const Color kMessengerPurple = Color(0xFFA033FF);
  static const Color kAlloraBlue = Color(0xFF0052FF);

  void _addLog(String msg) {
    debugPrint('[FacebookWebView] $msg');
    if (mounted) {
      setState(() {
        _debugLogs.add(msg);
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _currentUrl = widget.initialUrl ?? kPrimaryMessengerLoginUrl;
    _initWebViewController();
    _initBridgeHandshake();
  }

  @override
  void dispose() {
    _transmitTimeoutTimer?.cancel();
    _botSub?.cancel();
    super.dispose();
  }

  Future<void> _initBridgeHandshake() async {
    try {
      _addLog('Connecting to Facebook Messenger bridge...');
      _botRoom = await FacebookMessengerDisconnectService.findOrCreateManagementRoom(
        widget.client,
        createIfMissing: true,
      );

      if (_botRoom != null) {
        _addLog('Bridge room ready: ${_botRoom!.id}');
        _listenToBot(_botRoom!);

        // 1. Send !fb cancel to cancel all ongoing / stuck sessions
        _addLog('📤 Sent: !fb cancel');
        await _botRoom!.sendTextEvent('!fb cancel');

        await Future.delayed(const Duration(milliseconds: 400));

        // 2. Send !fb login to initiate fresh cookie flow
        _addLog('📤 Sent: !fb login');
        await _botRoom!.sendTextEvent('!fb login');
      }
    } catch (e) {
      _addLog('Bridge init error: $e');
    }
  }

  void _listenToBot(Room room) {
    _botSub?.cancel();
    _botSub = widget.client.onTimelineEvent.stream.listen((Event event) {
      if (event.roomId != room.id || event.senderId == widget.client.userID) {
        return;
      }

      final body = (event.content['body'] as String? ?? '').trim();
      if (body.isEmpty) return;

      final lower = body.toLowerCase();
      _addLog('📥 Bot: $body');

      // 1. Success State
      if (lower.contains('logged in') ||
          lower.contains('successfully logged in') ||
          lower.contains('login successful') ||
          lower.contains('successfully authenticated') ||
          lower.contains('- connected') ||
          lower.contains('logged in as')) {
        _transmitTimeoutTimer?.cancel();
        HapticFeedback.heavyImpact();

        String? extractedName;
        final connectedMatch =
            RegExp(r'(\d+)\s*\(([^)]+)\)\s*-\s*CONNECTED', caseSensitive: false)
                .firstMatch(body);
        if (connectedMatch != null) {
          final id = connectedMatch.group(1);
          final name = connectedMatch.group(2);
          extractedName = '$name ($id)';
        } else {
          final asIdx = lower.indexOf('logged in as');
          if (asIdx != -1) {
            final sub = body.substring(asIdx + 12).trim();
            final endLine = sub.indexOf('\n');
            extractedName =
                endLine != -1 ? sub.substring(0, endLine).trim() : sub;
            extractedName =
                extractedName.replaceAll(RegExp(r'[\(\)\.\!]'), '').trim();
          }
        }

        final label = extractedName?.isNotEmpty == true ? extractedName! : 'Facebook User';

        NetworkConnectionCache.markConnected(
          NetworkId.messenger,
          accountLabel: label,
          lastSynced: 'Just now',
          force: true,
        );
        ConnectionManager.instance?.noteJustConnected(
          NetworkId.messenger,
          syncFor: const Duration(seconds: 10),
        );
        HiddenRoomsStore.clear(NetworkId.messenger);

        // Ping double puppeting in background
        Future.delayed(const Duration(milliseconds: 600), () {
          try {
            room.sendTextEvent('ping-matrix');
            FacebookMessengerDisconnectService.forceSyncPortals(widget.client);
          } catch (_) {}
        });

        widget.onConnected?.call();

        if (mounted) {
          setState(() {
            _isTransmitting = false;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  const Icon(Icons.check_circle_rounded, color: Colors.white, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Messenger connected as $label!',
                      style: GoogleFonts.poppins(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
              backgroundColor: const Color(0xFF10B981),
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          );
          Navigator.of(context).pop();
        }
        return;
      }

      // 2. Bridge prompts for Cookie JSON / cURL command & provides brand Login URL
      if (lower.contains('enter a json object with your cookies') ||
          lower.contains('curl command') ||
          lower.contains('login url:')) {
        _isBotWaitingForCookies = true;

        // Dynamically load the brand Login URL if provided by the bot
        final extractedUrl = FacebookCookieExtractor.extractLoginUrl(body);
        if (extractedUrl != null &&
            extractedUrl.isNotEmpty &&
            !_hasLoadedBotUrl &&
            !_hasValidSession) {
          _hasLoadedBotUrl = true;
          _addLog('🌐 Loading brand Login URL from bridge: $extractedUrl');
          _controller.loadRequest(Uri.parse(extractedUrl));
        }

        // Flush any pending payload that was queued before the bot was ready
        if (_pendingPayload != null && _pendingPayload!.isNotEmpty && !_hasSentCookiesForPrompt) {
          _hasSentCookiesForPrompt = true;
          final payload = _pendingPayload!;
          _pendingPayload = null;
          _addLog('📤 Bot is ready! Flushing queued payload (Real Browser cURL):\n${payload.substring(0, payload.length > 120 ? 120 : payload.length)}...');
          setState(() {
            _isTransmitting = true;
            _statusMessage = 'Submitting session credentials to bridge...';
          });
          room.sendTextEvent(payload);
          return;
        }

        // If user already has valid session cookies ready, transmit them immediately
        if (!_hasSentCookiesForPrompt && _hasValidSession && _capturedCookies.isNotEmpty) {
          _hasSentCookiesForPrompt = true;

          String? dtsg = _extractedFbDtsg;
          String? jazoest = _extractedJazoest;
          String? spinR = _extractedSpinR;
          String? userId = _extractedUserId ?? FacebookCookieExtractor.getUserId(_capturedCookies);

          final payload = (_capturedRealCurl != null && _capturedRealCurl!.isNotEmpty)
              ? _capturedRealCurl!
              : (_sendAsCurl
                  ? FacebookCookieExtractor.formatDeepGraphQlCurl(
                      cookies: _capturedCookies,
                      fbDtsg: dtsg,
                      spinR: spinR,
                      jazoest: jazoest,
                      userId: userId,
                    )
                  : FacebookCookieExtractor.formatCleanSessionJson(_capturedCookies));
          _addLog('📤 Transmitting credentials payload (${_capturedRealCurl != null ? "Real Browser cURL" : (_sendAsCurl ? "cURL" : "JSON")}):\n$payload');
          setState(() {
            _isTransmitting = true;
            _statusMessage = 'Submitting session credentials to bridge...';
          });
          room.sendTextEvent(payload);
        }
        return;
      }

      // 3. Bridge asks to choose login flow
      if (lower.contains('choose a login flow') ||
          lower.contains('available login flows') ||
          lower.contains('select flow')) {
        _addLog('📤 Sent: !fb login cookies');
        setState(() {
          _statusMessage = 'Selecting cookies login flow...';
        });
        room.sendTextEvent('!fb login cookies');
        return;
      }

      // 4. Cancel confirmation response (normal handshake state)
      if (lower.contains('login cancelled')) {
        return;
      }

      // 5. Two-Factor Authentication / Checkpoint Code
      if (lower.contains('two-factor') ||
          lower.contains('2fa') ||
          lower.contains('verification code') ||
          lower.contains('security code') ||
          lower.contains('enter code') ||
          lower.contains('checkpoint code') ||
          lower.contains('sms code') ||
          lower.contains('authenticator')) {
        _transmitTimeoutTimer?.cancel();
        if (mounted) {
          setState(() {
            _isTransmitting = false;
          });
          _showTwoFactorDialog(room);
        }
        return;
      }

      // 6. Security Approval prompt
      if (lower.contains('approve') ||
          lower.contains('device confirmation') ||
          lower.contains('check your facebook app') ||
          lower.contains('notification sent') ||
          lower.contains('tap yes on your device')) {
        if (mounted) {
          setState(() {
            _statusMessage =
                'Please approve the login notification in your Facebook mobile app.';
          });
        }
        return;
      }

      // 7. Errors & Fallbacks
      if (lower.contains('unknown command') ||
          lower.contains('got logged out immediately') ||
          lower.contains('failed to load inbox') ||
          lower.contains('version id not found') ||
          lower.contains('invalid cookies') ||
          lower.contains('failed to log in') ||
          lower.contains('login failed') ||
          lower.contains('expired') ||
          lower.contains('invalid json') ||
          lower.contains('login error') ||
          lower.contains('internal error') ||
          lower.contains('challenge required') ||
          lower.contains('locked')) {
        _transmitTimeoutTimer?.cancel();
        if (mounted) {
          setState(() {
            _isTransmitting = false;
            _statusMessage = '';
          });

          final currentCurl = (_capturedRealCurl != null && _capturedRealCurl!.isNotEmpty)
              ? _capturedRealCurl!
              : FacebookCookieExtractor.formatDeepGraphQlCurl(
                  cookies: _capturedCookies,
                  fbDtsg: _extractedFbDtsg,
                  spinR: _extractedSpinR,
                  jazoest: _extractedJazoest,
                  userId: _extractedUserId,
                );

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              duration: const Duration(seconds: 10),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    body.length > 180 ? '${body.substring(0, 177)}...' : body,
                    style: GoogleFonts.poppins(fontSize: 12.5, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Tap "Copy cURL" below to copy the generated GraphQL command.',
                    style: GoogleFonts.poppins(fontSize: 11, color: Colors.white70),
                  ),
                ],
              ),
              backgroundColor: const Color(0xFFDC2626),
              behavior: SnackBarBehavior.floating,
              action: SnackBarAction(
                label: 'Copy cURL',
                textColor: Colors.amberAccent,
                onPressed: () {
                  HapticFeedback.lightImpact();
                  Clipboard.setData(ClipboardData(text: currentCurl));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Whole cURL (bash) copied to clipboard!'),
                      backgroundColor: Color(0xFF10B981),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                },
              ),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          );
        }
        return;
      }
    });
  }

  void _showTwoFactorDialog(Room room) {
    final textController = TextEditingController();
    final c = context.allora;

    final defaultPinTheme = PinTheme(
      width: 44,
      height: 52,
      textStyle: GoogleFonts.poppins(
        fontSize: 18,
        color: c.text,
        fontWeight: FontWeight.w700,
      ),
      decoration: BoxDecoration(
        border: Border.all(color: c.outline, width: 1.5),
        borderRadius: BorderRadius.circular(12),
        color: c.surfaceAlt,
      ),
    );

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: EdgeInsets.fromLTRB(
          24,
          20,
          24,
          MediaQuery.of(ctx).viewInsets.bottom + 28,
        ),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
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
            Text(
              'Security Verification',
              style: GoogleFonts.poppins(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: c.text,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Enter the 6-digit verification code from your Authenticator app or SMS to complete the connection.',
              style: GoogleFonts.poppins(
                fontSize: 13,
                color: c.textSecondary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 20),
            Center(
              child: Pinput(
                length: 6,
                controller: textController,
                defaultPinTheme: defaultPinTheme,
                autofocus: true,
                onCompleted: (code) async {
                  Navigator.pop(ctx);
                  setState(() {
                    _isTransmitting = true;
                    _statusMessage = 'Verifying security code...';
                  });
                  await room.sendTextEvent(code.trim());
                },
              ),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: () async {
                final code = textController.text.trim();
                if (code.isNotEmpty) {
                  Navigator.pop(ctx);
                  setState(() {
                    _isTransmitting = true;
                    _statusMessage = 'Verifying security code...';
                  });
                  await room.sendTextEvent(code);
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: kMessengerBlue,
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 48),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                elevation: 0,
              ),
              child: Text(
                'Submit Code',
                style: GoogleFonts.poppins(
                  fontWeight: FontWeight.w600,
                  fontSize: 15,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static const String _kNetworkInterceptorJs = r"""
    (function() {
      if (window.__messenger_sniffer_installed) return;
      window.__messenger_sniffer_installed = true;

      function reportCurl(url, method, headersObj, bodyStr) {
        try {
          if (!window.MessengerNetworkChannel) return;
          var fullUrl = url.startsWith('http') ? url : (window.location.origin + (url.startsWith('/') ? '' : '/') + url);
          if (!fullUrl.includes('graphql') && !fullUrl.includes('/ajax/')) return;

          var cookieStr = document.cookie || '';
          var headers = [];
          headers.push("-H 'accept: */*'");
          headers.push("-H 'content-type: application/x-www-form-urlencoded'");
          if (cookieStr) {
            headers.push("-b " + JSON.stringify(cookieStr));
          }
          headers.push("-H 'origin: https://www.messenger.com'");
          headers.push("-H 'referer: https://www.messenger.com/?no_redirect=true'");
          headers.push("-H 'user-agent: " + navigator.userAgent.replace(/'/g, "\\'") + "'");

          if (headersObj) {
            for (var k in headersObj) {
              var lk = k.toLowerCase();
              if (lk.startsWith('x-fb-') || lk.startsWith('x-asbd-') || lk.startsWith('sec-')) {
                headers.push("-H '" + k + ": " + headersObj[k].toString().replace(/'/g, "\\'") + "'");
              }
            }
          }

          var curl = "curl --url '" + fullUrl + "' \\\n  " + headers.join(" \\\n  ");
          if (bodyStr && bodyStr.length > 0) {
            curl += " \\\n  --data-raw " + JSON.stringify(bodyStr);
          }

          window.MessengerNetworkChannel.postMessage(JSON.stringify({
            url: fullUrl,
            method: method,
            curl: curl,
            body: bodyStr,
            cookie: cookieStr
          }));
        } catch(e) {}
      }

      var origFetch = window.fetch;
      if (origFetch) {
        window.fetch = async function() {
          try {
            var input = arguments[0];
            var init = arguments[1] || (typeof input === 'object' ? input : {});
            var url = typeof input === 'string' ? input : (input && input.url ? input.url : '');
            var method = (init && init.method) ? init.method : 'GET';
            var body = (init && init.body) ? init.body : '';
            var headers = {};
            if (init && init.headers) {
              if (init.headers instanceof Headers) {
                init.headers.forEach(function(v, k) { headers[k] = v; });
              } else if (typeof init.headers === 'object') {
                headers = init.headers;
              }
            }
            reportCurl(url, method, headers, typeof body === 'string' ? body : '');
          } catch(e) {}
          return origFetch.apply(this, arguments);
        };
      }

      var origOpen = XMLHttpRequest.prototype.open;
      var origSend = XMLHttpRequest.prototype.send;
      var origSetHeader = XMLHttpRequest.prototype.setRequestHeader;

      XMLHttpRequest.prototype.open = function(method, url) {
        this._reqUrl = url;
        this._reqMethod = method;
        this._reqHeaders = {};
        return origOpen.apply(this, arguments);
      };

      XMLHttpRequest.prototype.setRequestHeader = function(header, value) {
        if (!this._reqHeaders) this._reqHeaders = {};
        this._reqHeaders[header] = value;
        return origSetHeader.apply(this, arguments);
      };

      XMLHttpRequest.prototype.send = function(body) {
        try {
          if (this._reqUrl) {
            reportCurl(this._reqUrl, this._reqMethod || 'POST', this._reqHeaders || {}, typeof body === 'string' ? body : '');
          }
        } catch(e) {}
        return origSend.apply(this, arguments);
      };
    })();
  """;

  void _initWebViewController() {
    final controller = WebViewController();
    controller
      ..setUserAgent(
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36')
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..addJavaScriptChannel(
        'MessengerNetworkChannel',
        onMessageReceived: (JavaScriptMessage message) {
          try {
            final data = jsonDecode(message.message) as Map<String, dynamic>;
            final curl = data['curl'] as String?;
            final url = data['url'] as String? ?? '';
            if (curl != null && curl.isNotEmpty) {
              _capturedRealCurl = curl;
              _addLog('📡 Intercepted real browser GraphQL network request ($url)!');
            }
          } catch (_) {}
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (int progress) {
            if (mounted) {
              setState(() {
                _loadingProgress = progress / 100.0;
                _isLoading = progress < 100;
              });
            }
          },
          onPageStarted: (String url) {
            if (mounted) {
              setState(() {
                _currentUrl = url;
                _isLoading = true;
              });
            }
            try {
              controller.runJavaScript(_kNetworkInterceptorJs);
            } catch (_) {}
          },
          onPageFinished: (String url) async {
            if (mounted) {
              setState(() {
                _currentUrl = url;
                _isLoading = false;
              });
            }
            try {
              await controller.runJavaScript(_kNetworkInterceptorJs);
              // Inject desktop viewport so messenger.com renders desktop PC login form
              await controller.runJavaScript(r"""
                (function() {
                  var meta = document.querySelector('meta[name="viewport"]');
                  if (meta) {
                    meta.setAttribute('content', 'width=1024, initial-scale=0.8');
                  }
                  // Auto-accept cookie banner
                  try {
                    var cookieBtn = document.querySelector('[data-cookiebanner="accept_button"]') || 
                                    document.querySelector('button[data-testid="cookie-policy-manage-dialog-accept-button"]') ||
                                    document.querySelector('button[value="1"]');
                    if (cookieBtn) cookieBtn.click();
                  } catch(e) {}
                })();
              """);

              if (widget.initialEmail != null && widget.initialEmail!.isNotEmpty) {
                final emailJson = jsonEncode(widget.initialEmail);
                final passJson = jsonEncode(widget.initialPassword ?? '');
                await controller.runJavaScript("""
                  (function() {
                    var emailInput = document.querySelector('#email') || 
                                     document.querySelector('input[name="email"]') || 
                                     document.querySelector('input[type="email"]') ||
                                     document.querySelector('input[autocomplete="username"]') ||
                                     document.querySelector('#m_login_email') ||
                                     document.querySelector('input[name="username"]');

                    var passInput = document.querySelector('#pass') || 
                                    document.querySelector('input[name="pass"]') || 
                                    document.querySelector('input[type="password"]') ||
                                    document.querySelector('input[autocomplete="current-password"]') ||
                                    document.querySelector('#m_login_password');

                    if (emailInput) {
                      try {
                        var setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value").set;
                        setter.call(emailInput, $emailJson);
                        if (passInput && $passJson) {
                          setter.call(passInput, $passJson);
                        }
                      } catch (e) {
                        emailInput.value = $emailJson;
                        if (passInput && $passJson) {
                          passInput.value = $passJson;
                        }
                      }
                      emailInput.dispatchEvent(new Event('input', { bubbles: true }));
                      emailInput.dispatchEvent(new Event('change', { bubbles: true }));
                      if (passInput && $passJson) {
                        passInput.dispatchEvent(new Event('input', { bubbles: true }));
                        passInput.dispatchEvent(new Event('change', { bubbles: true }));
                      }
                    }
                  })();
                """);
              }
            } catch (_) {}
            await _inspectPageCookies();
          },
          onWebResourceError: (WebResourceError error) {
            debugPrint('[FacebookWebView] Resource Error: ${error.description}');
          },
          onNavigationRequest: (NavigationRequest request) {
            final lower = request.url.toLowerCase();
            // Prevent app store or native intent redirects so user stays in web login
            if (lower.startsWith('intent:') ||
                lower.startsWith('market:') ||
                lower.startsWith('fb://') ||
                lower.startsWith('fb-messenger://') ||
                lower.contains('play.google.com') ||
                lower.contains('apps.apple.com')) {
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      );

    if (controller.platform is AndroidWebViewController) {
      AndroidWebViewController.enableDebugging(false);
      (controller.platform as AndroidWebViewController)
          .setMediaPlaybackRequiresUserGesture(false);
    }

    _controller = controller;

    // Load initial target URL
    final urlToLoad = widget.initialUrl ?? kPrimaryMessengerLoginUrl;
    _controller.loadRequest(Uri.parse(urlToLoad));
  }

  /// Evaluates native WebViewCookieManager storage and document.cookie for session tokens
  Future<void> _inspectPageCookies() async {
    if (_isTransmitting) return;

    try {
      final Map<String, String> cookies = {};

      // 1. Native platform cookie manager query across domains (includes HttpOnly cookies like c_user, xs, datr, sb)
      final targetUris = [
        Uri.parse('https://m.facebook.com'),
        Uri.parse('https://facebook.com'),
        Uri.parse('https://www.facebook.com'),
        Uri.parse('https://mbasic.facebook.com'),
        Uri.parse('https://messenger.com'),
        Uri.parse('https://www.messenger.com'),
      ];

      for (final uri in targetUris) {
        try {
          final list = await _cookieManager.getCookies(domain: uri);
          for (final c in list) {
            if (c.name.isNotEmpty && c.value.isNotEmpty) {
              cookies[c.name] = c.value;
            }
          }
        } catch (e) {
          debugPrint('[FacebookWebView] getCookies error for $uri: $e');
        }
      }

      // 2. Merge with document.cookie as secondary fallback
      try {
        final cookieResult =
            await _controller.runJavaScriptReturningResult('document.cookie');
        String rawCookies = cookieResult.toString();

        if (rawCookies.startsWith('"') &&
            rawCookies.endsWith('"') &&
            rawCookies.length >= 2) {
          rawCookies = rawCookies.substring(1, rawCookies.length - 1);
        }
        rawCookies = rawCookies.replaceAll(r'\"', '"');

        final jsParsed = FacebookCookieExtractor.parseCookies(rawCookies);
        jsParsed.forEach((k, v) {
          if (!cookies.containsKey(k) && v.isNotEmpty) {
            cookies[k] = v;
          }
        });
      } catch (_) {}

      try {
        final domJsonStr = await _controller.runJavaScriptReturningResult(r"""
          (function() {
            var dtsg = '';
            var userId = '';
            var spinR = '';
            var jazoest = '';

            // 1. Try JS objects / modules
            try {
              if (window.DTSGInitialData && window.DTSGInitialData.token) dtsg = window.DTSGInitialData.token;
              else if (window.DTSGInitData && window.DTSGInitData.token) dtsg = window.DTSGInitData.token;
              else if (window.require) {
                try { dtsg = window.require('DTSGInitialData').token; } catch(e) {}
                if (!dtsg) { try { dtsg = window.require('DTSGInitData').token; } catch(e) {} }
              }
            } catch(e) {}

            // 2. Try HTML input elements
            if (!dtsg) {
              var el = document.querySelector('input[name="fb_dtsg"]') || document.querySelector('[name="fb_dtsg"]');
              if (el && el.value) dtsg = el.value;
            }

            // 3. Scan all script tags in the DOM for DTSG token patterns
            if (!dtsg) {
              var scripts = document.getElementsByTagName('script');
              for (var i = 0; i < scripts.length; i++) {
                var text = scripts[i].textContent || scripts[i].innerText || '';
                if (text.indexOf('DTSG') !== -1 || text.indexOf('fb_dtsg') !== -1 || text.indexOf('token') !== -1) {
                  var m = text.match(/"token":"(NAf[^"]+)"/) || 
                          text.match(/"token":"(NA[A-Za-z0-9_\-:]+)"/) ||
                          text.match(/\["DTSGInitialData",\s*\[\s*\],\s*\{\s*"token"\s*:\s*"([^"]+)"/) ||
                          text.match(/\["DTSGInitData",\s*\[\s*\],\s*\{\s*"token"\s*:\s*"([^"]+)"/) ||
                          text.match(/"dtsg":\{"token":"([^"]+)"/) ||
                          text.match(/"fb_dtsg":"([^"]+)"/) ||
                          text.match(/name="fb_dtsg" value="([^"]+)"/);
                  if (m && m[1]) {
                    dtsg = m[1];
                    break;
                  }
                }
              }
            }

            // 4. Scan whole document HTML if still not found
            if (!dtsg) {
              var html = document.documentElement ? document.documentElement.innerHTML : '';
              var m = html.match(/"token":"(NAf[^"]+)"/) ||
                      html.match(/"token":"(NA[A-Za-z0-9_\-:]+)"/) ||
                      html.match(/name="fb_dtsg" value="([^"]+)"/) ||
                      html.match(/"async_get_token":"([^"]+)"/);
              if (m && m[1]) {
                dtsg = m[1];
              }
            }

            // Extract User ID
            try {
              if (window.Env && window.Env.user) userId = String(window.Env.user);
              else if (window.CurrentUserInitialData && window.CurrentUserInitialData.USER_ID) userId = String(window.CurrentUserInitialData.USER_ID);
              else if (window.__initialData && window.__initialData.USER_ID) userId = String(window.__initialData.USER_ID);
              else if (document.cookie) {
                var cm = document.cookie.match(/(?:^|;\s*)c_user=([^;]+)/);
                if (cm) userId = cm[1];
              }
            } catch(e) {}

            // Extract spin_r
            try {
              if (window.__spin_r) spinR = String(window.__spin_r);
              else {
                var sm = document.documentElement.innerHTML.match(/"__spin_r":(\d+)/) || document.documentElement.innerHTML.match(/"server_revision":(\d+)/);
                if (sm) spinR = sm[1];
              }
            } catch(e) {}

            // Extract jazoest
            var jazoestEl = document.querySelector('input[name="jazoest"]');
            if (jazoestEl && jazoestEl.value) jazoest = jazoestEl.value;

            return JSON.stringify({
              dtsg: dtsg || '',
              userId: userId || '',
              spinR: spinR || '',
              jazoest: jazoest || ''
            });
          })();
        """);
        if (domJsonStr.toString().isNotEmpty) {
          String cleanDomJson = domJsonStr.toString();
          if (cleanDomJson.startsWith('"') && cleanDomJson.endsWith('"')) {
            cleanDomJson = jsonDecode(cleanDomJson);
          }
          final parsedDom = jsonDecode(cleanDomJson);
          if (parsedDom is Map) {
            if (parsedDom['dtsg']?.toString().isNotEmpty ?? false) {
              _extractedFbDtsg = parsedDom['dtsg'].toString();
            }
            if (parsedDom['spinR']?.toString().isNotEmpty ?? false) {
              _extractedSpinR = parsedDom['spinR'].toString();
            }
            if (parsedDom['jazoest']?.toString().isNotEmpty ?? false) {
              _extractedJazoest = parsedDom['jazoest'].toString();
            }
            if (parsedDom['userId']?.toString().isNotEmpty ?? false) {
              _extractedUserId = parsedDom['userId'].toString();
            }
          }
        }
      } catch (_) {}

      // Fallback: If fb_dtsg is still missing and we have valid session cookies, fetch live tokens
      if ((_extractedFbDtsg == null || _extractedFbDtsg!.isEmpty) &&
          FacebookCookieExtractor.hasValidSession(cookies)) {
        try {
          final liveParams = await FacebookCookieExtractor.fetchGraphQLParamsFromWeb(cookies);
          if (liveParams.fbDtsg != null && liveParams.fbDtsg!.isNotEmpty) {
            _extractedFbDtsg = liveParams.fbDtsg;
            _extractedJazoest = liveParams.jazoest ?? FacebookCookieExtractor.computeJazoest(liveParams.fbDtsg!);
            if (liveParams.spinR != null && liveParams.spinR!.isNotEmpty) {
              _extractedSpinR = liveParams.spinR;
            }
            if (liveParams.userId != null && liveParams.userId!.isNotEmpty) {
              _extractedUserId = liveParams.userId;
            }
            _addLog('🔑 Resolved live fb_dtsg token from Facebook (${_extractedFbDtsg!.substring(0, 10)}...)');
          }
        } catch (_) {}
      }

      // 3. Detect if the user is currently on the login form page
      bool isLoginPage = false;
      try {
        final jsHasPassword = await _controller.runJavaScriptReturningResult(
          "document.querySelector('input[type=\"password\"]') !== null || document.querySelector('input[name=\"pass\"]') !== null || document.querySelector('#pass') !== null"
        );
        isLoginPage = jsHasPassword.toString() == 'true';
      } catch (_) {}

      final url = _currentUrl.toLowerCase();
      if ((url.contains('login.php') || url.contains('/login/') || url.contains('checkpoint')) &&
          !FacebookCookieExtractor.hasValidSession(cookies)) {
        isLoginPage = true;
      }

      final hasSession = !isLoginPage && FacebookCookieExtractor.hasValidSession(cookies);

      if (mounted) {
        setState(() {
          _capturedCookies = cookies;
          _hasValidSession = hasSession;
        });
      }

      // Automatically transmit credentials once when user logs in and session is ready
      if (hasSession &&
          !isLoginPage &&
          !_hasSentCookiesForPrompt &&
          !_isTransmitting) {

        String? dtsg = _extractedFbDtsg;
        String? jazoest = _extractedJazoest;
        String? spinR = _extractedSpinR;
        String? userId = _extractedUserId ?? FacebookCookieExtractor.getUserId(cookies);

        if (dtsg == null || dtsg.isEmpty) {
          _addLog('⏳ Resolving live fb_dtsg token from Messenger...');
          final webParams = await FacebookCookieExtractor.fetchGraphQLParamsFromWeb(cookies);
          if (webParams.fbDtsg != null && webParams.fbDtsg!.isNotEmpty) {
            dtsg = webParams.fbDtsg;
            jazoest = webParams.jazoest ?? FacebookCookieExtractor.computeJazoest(dtsg!);
            spinR ??= webParams.spinR;
            userId ??= webParams.userId;
            _extractedFbDtsg = dtsg;
            _extractedJazoest = jazoest;
            _extractedSpinR = spinR;
            _extractedUserId = userId;
          }
        }

        final payload = (_capturedRealCurl != null && _capturedRealCurl!.isNotEmpty)
            ? _capturedRealCurl!
            : FacebookCookieExtractor.formatDeepGraphQlCurl(
                cookies: cookies,
                fbDtsg: dtsg,
                spinR: spinR,
                jazoest: jazoest,
                userId: userId,
              );

        // If the bot is already waiting for cookies, send immediately
        if (_isBotWaitingForCookies) {
          _hasSentCookiesForPrompt = true;
          _addLog('📤 User logged in! Transmitting ${_capturedRealCurl != null ? "Real Browser cURL" : "GraphQL cURL"} payload:\n${payload.substring(0, payload.length > 120 ? 120 : payload.length)}...');
          setState(() {
            _isTransmitting = true;
            _statusMessage = 'Submitting session credentials to bridge...';
          });

          _botRoom ??= await FacebookMessengerDisconnectService.findOrCreateManagementRoom(
            widget.client,
            createIfMissing: true,
          );
          if (_botRoom != null) {
            _listenToBot(_botRoom!);
            await _botRoom!.sendTextEvent(payload);
          }
        } else {
          // Bot hasn't asked for cookies yet — queue the payload
          _pendingPayload = payload;
          _addLog('⏳ Session ready but bot not ready yet. Queued payload for transmission...');
          setState(() {
            _statusMessage = 'Waiting for bridge bot to be ready...';
          });
        }
      }
    } catch (e) {
      debugPrint('[FacebookWebView] Error inspecting cookies: $e');
    }
  }

  Future<void> _transmitSessionToMatrix({bool asCurl = true}) async {
    if (_capturedCookies.isEmpty) {
      await _inspectPageCookies();
    }
    if (!_hasValidSession || _capturedCookies.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
              'Please enter your Email and Password above to sign into Messenger first.'),
          backgroundColor: Colors.orangeAccent,
          behavior: SnackBarBehavior.floating,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
      return;
    }

    setState(() {
      _isTransmitting = true;
      _statusMessage = 'Connecting Messenger to Allora...';
    });
    HapticFeedback.mediumImpact();

    // 30s timeout guard
    _transmitTimeoutTimer?.cancel();
    _transmitTimeoutTimer = Timer(const Duration(seconds: 30), () {
      if (mounted && _isTransmitting) {
        setState(() {
          _isTransmitting = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
                'Bridge bot response timed out. Please tap Connect to retry.'),
            backgroundColor: Colors.orangeAccent,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
    });

    try {
      _sendAsCurl = asCurl;
      _hasSentCookiesForPrompt = false;
      _botRoom ??=
          await FacebookMessengerDisconnectService.findOrCreateManagementRoom(
        widget.client,
        createIfMissing: true,
      );

      if (_botRoom != null) {
        _listenToBot(_botRoom!);
        _addLog('Requesting bridge authentication (${asCurl ? "cURL command" : "clean JSON"})...');

        if (_isBotWaitingForCookies) {
          _hasSentCookiesForPrompt = true;
          final payload = (_capturedRealCurl != null && _capturedRealCurl!.isNotEmpty)
              ? _capturedRealCurl!
              : (_sendAsCurl
                  ? FacebookCookieExtractor.formatDeepGraphQlCurl(
                      cookies: _capturedCookies,
                      fbDtsg: _extractedFbDtsg,
                      spinR: _extractedSpinR,
                      jazoest: _extractedJazoest,
                      userId: _extractedUserId,
                    )
                  : FacebookCookieExtractor.formatCleanSessionJson(_capturedCookies));
          _addLog('📤 Transmitting credentials payload (${_capturedRealCurl != null ? "Real Browser cURL" : (_sendAsCurl ? "cURL" : "JSON")}):\n$payload');
          setState(() {
            _statusMessage = 'Submitting session credentials to bridge...';
          });
          await _botRoom!.sendTextEvent(payload);
        } else {
          setState(() {
            _statusMessage = 'Resetting bridge state...';
          });
          _addLog('📤 Sent: cancel');
          await _botRoom!.sendTextEvent('cancel');
          await Future.delayed(const Duration(milliseconds: 300));
          setState(() {
            _statusMessage = 'Requesting bridge authentication...';
          });
          _addLog('📤 Sent: login');
          await _botRoom!.sendTextEvent('login');
        }
      } else {
        _transmitTimeoutTimer?.cancel();
        setState(() {
          _isTransmitting = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
                'Could not reach Messenger bridge. Please check connection and try again.'),
            backgroundColor: Colors.redAccent,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
    } catch (e) {
      _transmitTimeoutTimer?.cancel();
      _addLog('Transmit error: $e');
      if (mounted) {
        setState(() {
          _isTransmitting = false;
        });
      }
    }
  }

  void _showLogsModal() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        height: 380,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: const Color(0xFF0F172A),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border.all(color: Colors.blueGrey.withValues(alpha: 0.3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'BRIDGE DEBUG LOGS',
                  style: GoogleFonts.firaCode(
                    color: Colors.cyanAccent,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded, color: Colors.white70, size: 20),
                  onPressed: () => Navigator.pop(ctx),
                ),
              ],
            ),
            const Divider(color: Colors.white12, height: 12),
            Expanded(
              child: _debugLogs.isEmpty
                  ? Center(
                      child: Text(
                        'No logs yet. Activity will appear here.',
                        style: GoogleFonts.poppins(color: Colors.white38, fontSize: 12),
                      ),
                    )
                  : ListView.builder(
                      reverse: true,
                      itemCount: _debugLogs.length,
                      itemBuilder: (context, idx) {
                        final log = _debugLogs[_debugLogs.length - 1 - idx];
                        final isOut = log.startsWith('📤');
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Text(
                            log,
                            style: GoogleFonts.firaCode(
                              color: isOut
                                  ? const Color(0xFF60A5FA)
                                  : const Color(0xFF94A3B8),
                              fontSize: 11.5,
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  void _openManualCookieSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => FacebookMessengerConnectSheet(
        client: widget.client,
        onConnected: () {
          widget.onConnected?.call();
          if (mounted) {
            Navigator.pop(context);
          }
        },
      ),
    );
  }

  Widget _buildBottomStatusBar(AlloraColors c) {
    final userId = FacebookCookieExtractor.getUserId(_capturedCookies);

    return Positioned(
      left: 16,
      right: 16,
      bottom: 20,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: c.surface.withValues(alpha: 0.95),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: _hasValidSession
                ? kMessengerBlue.withValues(alpha: 0.4)
                : c.outline,
            width: 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.25),
              blurRadius: 18,
              offset: const Offset(0, 6),
            )
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: _hasValidSession
                    ? const Color(0xFF10B981).withValues(alpha: 0.15)
                    : kMessengerBlue.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(
                _hasValidSession
                    ? Icons.check_circle_rounded
                    : Icons.person_rounded,
                color: _hasValidSession
                    ? const Color(0xFF10B981)
                    : kMessengerBlue,
                size: 22,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _hasValidSession
                        ? 'Messenger Session Ready'
                        : 'Sign into Messenger',
                    style: GoogleFonts.poppins(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: c.text,
                    ),
                  ),
                  Text(
                    _hasValidSession
                        ? (userId != null
                            ? 'Logged in ($userId)'
                            : 'Ready to bridge messages')
                        : 'Enter credentials above & tap Log In',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.poppins(
                      fontSize: 11.5,
                      color: c.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              onPressed: () {
                _inspectPageCookies().then((_) => _transmitSessionToMatrix());
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: kMessengerBlue,
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                elevation: 0,
              ),
              child: Text(
                _hasValidSession ? 'Connect Now' : 'Connect',
                style: GoogleFonts.poppins(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            PopupMenuButton<String>(
              icon: Icon(Icons.more_vert_rounded, color: c.textSecondary, size: 18),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              color: c.surface,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              onSelected: (val) {
                if (val == 'curl') {
                  _inspectPageCookies().then((_) => _transmitSessionToMatrix(asCurl: true));
                } else if (val == 'messenger') {
                  _controller.loadRequest(Uri.parse('https://www.messenger.com/?no_redirect=true'));
                } else if (val == 'logs') {
                  _showLogsModal();
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'curl',
                  child: Row(
                    children: [
                      Icon(Icons.terminal_rounded, size: 18),
                      SizedBox(width: 10),
                      Text('Submit as cURL command', style: TextStyle(fontSize: 13)),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'messenger',
                  child: Row(
                    children: [
                      Icon(Icons.language_rounded, size: 18),
                      SizedBox(width: 10),
                      Text('Open Messenger.com', style: TextStyle(fontSize: 13)),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.allora;

    return Scaffold(
      backgroundColor: c.canvas,
      appBar: AppBar(
        backgroundColor: c.surface,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.close_rounded, color: c.text),
          onPressed: () => Navigator.of(context).pop(),
        ),
        centerTitle: true,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: const BoxDecoration(
                color: kAlloraBlue,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: const Icon(Icons.all_inclusive_rounded,
                  color: Colors.white, size: 16),
            ),
            const SizedBox(width: 8),
            Icon(Icons.swap_horiz_rounded, color: c.textSecondary, size: 18),
            const SizedBox(width: 8),
            Container(
              width: 28,
              height: 28,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [kMessengerBlue, kMessengerPurple],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Image.asset(
                'assets/images/messenger.png',
                width: 16,
                height: 16,
                errorBuilder: (_, __, ___) => const Icon(
                  Icons.chat_bubble_rounded,
                  color: Colors.white,
                  size: 14,
                ),
              ),
            ),
          ],
        ),
        actions: [
          if (_hasValidSession && !_isTransmitting)
            IconButton(
              icon: const Icon(Icons.link_rounded, color: kMessengerBlue, size: 22),
              tooltip: 'Connect to Allora',
              onPressed: () => _transmitSessionToMatrix(),
            ),
          IconButton(
            icon: Icon(Icons.refresh_rounded, color: c.textSecondary, size: 20),
            tooltip: 'Reload',
            onPressed: () => _controller.reload(),
          ),
          PopupMenuButton<String>(
            icon: Icon(Icons.more_vert_rounded, color: c.textSecondary, size: 20),
            color: c.surface,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            onSelected: (val) {
              if (val == 'logs') {
                _showLogsModal();
              } else if (val == 'manual') {
                _openManualCookieSheet();
              } else if (val == 'clear') {
                _cookieManager.clearCookies();
                _controller.clearCache();
                _controller.loadRequest(Uri.parse(kPrimaryMessengerLoginUrl));
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'logs',
                child: Row(
                  children: [
                    Icon(Icons.terminal_rounded, size: 18),
                    SizedBox(width: 10),
                    Text('Live Bridge Logs', style: TextStyle(fontSize: 13)),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'manual',
                child: Row(
                  children: [
                    Icon(Icons.code_rounded, size: 18),
                    SizedBox(width: 10),
                    Text('Paste Cookies / Advanced', style: TextStyle(fontSize: 13)),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'clear',
                child: Row(
                  children: [
                    Icon(Icons.delete_outline_rounded, size: 18, color: Colors.redAccent),
                    SizedBox(width: 10),
                    Text('Clear Cookies & Reset', style: TextStyle(fontSize: 13, color: Colors.redAccent)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Stack(
        children: [
          Column(
            children: [
              if (_isLoading)
                LinearProgressIndicator(
                  value: _loadingProgress > 0 ? _loadingProgress : null,
                  backgroundColor: Colors.transparent,
                  valueColor:
                      const AlwaysStoppedAnimation<Color>(kMessengerBlue),
                  minHeight: 2.5,
                ),
              Expanded(
                child: WebViewWidget(controller: _controller),
              ),
            ],
          ),

          // Full-Screen Transmitting / Connecting Overlay
          if (_isTransmitting)
            Container(
              color: Colors.black.withValues(alpha: 0.75),
              alignment: Alignment.center,
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 32),
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: c.surface,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: c.outline),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.3),
                      blurRadius: 24,
                    )
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 44,
                      height: 44,
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        valueColor: AlwaysStoppedAnimation(kMessengerBlue),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'Connecting to Messenger...',
                      style: GoogleFonts.poppins(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: c.text,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _statusMessage.isNotEmpty
                          ? _statusMessage
                          : 'Authenticating session credentials with bridge...',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.poppins(
                        fontSize: 12.5,
                        color: c.textSecondary,
                      ),
                    ),
                    if (_debugLogs.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0F172A),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color: Colors.blueGrey.withValues(alpha: 0.3)),
                        ),
                        child: Text(
                          _debugLogs.last,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: GoogleFonts.firaCode(
                            color: _debugLogs.last.startsWith('📤')
                                ? const Color(0xFF60A5FA)
                                : const Color(0xFF34D399),
                            fontSize: 10.5,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        TextButton.icon(
                          onPressed: _showLogsModal,
                          icon: const Icon(Icons.terminal_rounded, size: 16),
                          label: Text(
                            'View Live Logs',
                            style: GoogleFonts.poppins(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        TextButton(
                          onPressed: () {
                            _transmitTimeoutTimer?.cancel();
                            setState(() {
                              _isTransmitting = false;
                            });
                          },
                          child: Text(
                            'Dismiss',
                            style: GoogleFonts.poppins(
                              fontSize: 12.5,
                              color: c.textTertiary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

