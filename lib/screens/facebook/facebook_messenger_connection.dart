// ignore_for_file: unnecessary_non_null_assertion, unused_element, curly_braces_in_flow_control_structures, unused_import, unnecessary_string_interpolations, use_build_context_synchronously, deprecated_member_use

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart' hide Visibility;
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:matrix/matrix.dart';
import 'package:pinput/pinput.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/theme/app_theme.dart';
import '../../data/services/connection_manager.dart';
import '../../data/services/hidden_rooms_store.dart';
import '../networks/network_connection_cache.dart';
import '../networks/network_meta.dart';
import 'facebook_cookie_extractor.dart';
import 'facebook_disconnect.dart';
import 'facebook_messenger_commands_sheet.dart';
import 'facebook_webview_login.dart';

// ─── BRAND CONSTANTS ──────────────────────────────────────────────────────────

const Color kMessengerBlue = Color(0xFF0084FF);
const Color kMessengerGradientBlue = Color(0xFF006FFF);
const Color kMessengerPurple = Color(0xFFA033FF);
const Color kAlloraBlue = Color(0xFF0052FF);

// ─── CONNECTION STEPS ─────────────────────────────────────────────────────────

enum FacebookConnectStep {
  chooseMethod,
  manualCookies,
  flowSelection,
  twoFactor,
  appApproval,
  loading,
  success,
}

// ─── PUBLIC ENTRY POINTS ──────────────────────────────────────────────────────

/// Opens the Facebook Messenger "Connect Account" bottom sheet.
///
/// [onConnected] fires once the bridge bot confirms a successful login.
void showMessengerConnectSheet({
  required BuildContext context,
  required Client client,
  VoidCallback? onConnected,
}) {
  HapticFeedback.lightImpact();
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => FacebookMessengerConnectSheet(
      client: client,
      onConnected: onConnected,
    ),
  );
}

/// Opens the Facebook Messenger account management and disconnect sheet.
void showFacebookMessengerAccountSheet({
  required BuildContext context,
  required Client client,
  String? accountLabel,
  VoidCallback? onDisconnected,
}) {
  HapticFeedback.lightImpact();
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => FacebookMessengerAccountManagementSheet(
      client: client,
      accountLabel: accountLabel,
      onDisconnected: onDisconnected,
    ),
  );
}

// ─── THE CONNECT SHEET ────────────────────────────────────────────────────────

class FacebookMessengerConnectSheet extends StatefulWidget {
  final Client client;
  final VoidCallback? onConnected;

  const FacebookMessengerConnectSheet({
    super.key,
    required this.client,
    this.onConnected,
  });

  @override
  State<FacebookMessengerConnectSheet> createState() =>
      _FacebookMessengerConnectSheetState();
}

class _FacebookMessengerConnectSheetState
    extends State<FacebookMessengerConnectSheet> {
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _cookiesInputController = TextEditingController();
  final TextEditingController _twoFactorController = TextEditingController();

  bool _obscurePassword = true;
  final WebViewCookieManager _cookieManager = WebViewCookieManager();
  final Map<String, String> _capturedCookies = {};
  String? _capturedRealCurl;
  bool _hasSentCookiesToBot = false;
  final bool _hasPrimedMessenger = false;
  String? _extractedFbDtsg;
  String? _extractedSpinR;
  String? _extractedJazoest;
  String? _extractedUserId;
  Timer? _cookiePollTimer;

  StreamSubscription<Event>? _activeSub;
  Room? _botRoom;

  FacebookConnectStep _currentStep = FacebookConnectStep.chooseMethod;
  String? _sheetError;
  String _loadingMessage = 'Authenticating with Facebook Messenger bridge...';
  String? _accountIdentifier;
  String? _bridgeLoginUrl;
  bool _isBridgeReady = false;
  bool _showLogs = false;
  final List<String> _debugLogs = ['Ready to connect to Facebook bridge.'];
  final List<String> _availableFlows = [];
  Timer? _timeoutTimer;

  String? _pendingCookiePayload;
  String? _lastPassedCurl;
  Completer<String>? _loginUrlCompleter;

  void _addLog(String msg) {
    debugPrint('[FacebookBridge] $msg');
    if (mounted) {
      setState(() {
        _debugLogs.add(msg);
      });
    }
  }

  @override
  void initState() {
    super.initState();
    final cached = NetworkConnectionCache.get(NetworkId.messenger);
    if (cached.accountLabel != null && cached.accountLabel!.isNotEmpty) {
      _accountIdentifier = cached.accountLabel;
    }
    _initBridgeHandshake();
  }

  Future<void> _initBridgeHandshake() async {
    try {
      final room = await _resolveBotRoom();
      if (room != null) {
        _listenToBot(room);
        _loginUrlCompleter = Completer<String>();
        _addLog('📤 Sent: cancel');
        await room.sendTextEvent('cancel');
        await Future.delayed(const Duration(milliseconds: 250));
        _addLog('📤 Sent: login');
        await room.sendTextEvent('login');
      }
    } catch (e) {
      _addLog('Bridge init error: $e');
    }
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _cookiesInputController.dispose();
    _twoFactorController.dispose();
    _activeSub?.cancel();
    _timeoutTimer?.cancel();
    _cookiePollTimer?.cancel();
    super.dispose();
  }

  // ─── RESOLVE OR CREATE MANAGEMENT BOT ROOM ──────────────────────────────

  Future<Room?> _resolveBotRoom() async {
    if (_botRoom != null) return _botRoom;

    _addLog('Finding Facebook Messenger bridge management room...');
    _botRoom = await FacebookMessengerDisconnectService.findOrCreateManagementRoom(
      widget.client,
      createIfMissing: true,
    );

    if (_botRoom != null) {
      _addLog('Management room active: ${_botRoom!.id}');
    } else {
      _addLog('Failed to resolve management room.');
    }
    return _botRoom;
  }

  // ─── LISTEN TO BRIDGE BOT RESPONSES ──────────────────────────────────────

  void _listenToBot(Room room) {
    _activeSub?.cancel();

    _activeSub = widget.client.onTimelineEvent.stream.listen((Event event) {
      if (event.roomId != room.id || event.senderId == widget.client.userID) {
        return;
      }

      final body = (event.content['body'] as String? ?? '').trim();
      if (body.isEmpty) return;

      _addLog('📥 Bot: $body');
      final lower = body.toLowerCase();

      // 1. Success state
      if (lower.contains('logged in') ||
          lower.contains('successfully logged in') ||
          lower.contains('login successful') ||
          lower.contains('successfully authenticated') ||
          lower.contains('- connected') ||
          lower.contains('logged in as')) {
        _timeoutTimer?.cancel();
        HapticFeedback.mediumImpact();

        // Extract account name or numeric ID if present
        String? extractedName;
        final connectedMatch =
            RegExp(r'(\d+)\s*\(([^)]+)\)\s*-\s*CONNECTED', caseSensitive: false)
                .firstMatch(body);
        if (connectedMatch != null) {
          final id = connectedMatch.group(1);
          final name = connectedMatch.group(2);
          extractedName = '$name ($id)';
          _accountIdentifier = id;
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
          final numericMatch = RegExp(r'\d{6,}').firstMatch(body);
          if (numericMatch != null) {
            _accountIdentifier = numericMatch.group(0);
          }
        }

        final label = extractedName?.isNotEmpty == true
            ? extractedName!
            : (_accountIdentifier?.isNotEmpty == true
                ? _accountIdentifier!
                : 'Facebook User');

        setState(() {
          _sheetError = null;
          _currentStep = FacebookConnectStep.success;
        });

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
        Future.delayed(const Duration(milliseconds: 800), () {
          try {
            _addLog('📤 Sent: ${FacebookBridgeCommands.pingMatrix()}');
            room.sendTextEvent(FacebookBridgeCommands.pingMatrix());
            FacebookMessengerDisconnectService.forceSyncPortals(widget.client);
          } catch (_) {}
        });

        widget.onConnected?.call();
        return;
      }

      // 2. Bridge asks for Cookie JSON / cURL command & provides Login URL
      if (lower.contains('enter a json object with your cookies') ||
          lower.contains('curl command') ||
          lower.contains('login url:') ||
          lower.contains('messenger.com/?no_redirect=true') ||
          lower.contains('messenger.com')) {
        _timeoutTimer?.cancel();

        final extractedUrl = FacebookCookieExtractor.extractLoginUrl(body);
        if (extractedUrl != null && extractedUrl.isNotEmpty) {
          setState(() {
            _bridgeLoginUrl = extractedUrl;
            _isBridgeReady = true;
          });
          _addLog('🔗 Bridge Login URL: $extractedUrl');
          if (_loginUrlCompleter != null && !_loginUrlCompleter!.isCompleted) {
            _loginUrlCompleter!.complete(extractedUrl);
          }
        } else {
          setState(() {
            _isBridgeReady = true;
          });
          if (_loginUrlCompleter != null && !_loginUrlCompleter!.isCompleted) {
            _loginUrlCompleter!.complete('https://www.messenger.com/?no_redirect=true');
          }
        }

        if (!_hasSentCookiesToBot &&
            _capturedCookies.isNotEmpty &&
            FacebookCookieExtractor.hasValidSession(_capturedCookies)) {
          _hasSentCookiesToBot = true;
          final payload = (_capturedRealCurl != null && _capturedRealCurl!.isNotEmpty)
              ? _capturedRealCurl!
              : FacebookCookieExtractor.formatDeepGraphQlCurl(
                  cookies: _capturedCookies,
                  fbDtsg: _extractedFbDtsg,
                  spinR: _extractedSpinR,
                  jazoest: _extractedJazoest,
                  userId: _extractedUserId,
                );
          _addLog('📤 Transmitting credentials payload (${_capturedRealCurl != null ? "Real Browser cURL" : "GraphQL cURL"}) to bridge:\n$payload');
          setState(() {
            _loadingMessage = 'Authenticating session with bridge bot...';
          });
          room.sendTextEvent(payload);
        } else if (_pendingCookiePayload != null && _pendingCookiePayload!.isNotEmpty) {
          final payload = _pendingCookiePayload!;
          _pendingCookiePayload = null;
          _addLog('📤 Transmitting cookie payload to bridge...');
          setState(() {
            _loadingMessage = 'Authenticating session with bridge bot...';
          });
          room.sendTextEvent(payload);
        }
        return;
      }

      // 3. Two-Factor Authentication / Checkpoint Code
      if (lower.contains('two-factor') ||
          lower.contains('2fa') ||
          lower.contains('verification code') ||
          lower.contains('security code') ||
          lower.contains('enter code') ||
          lower.contains('checkpoint code') ||
          lower.contains('sms code') ||
          lower.contains('authenticator')) {
        _timeoutTimer?.cancel();
        HapticFeedback.lightImpact();
        setState(() {
          _sheetError = null;
          _currentStep = FacebookConnectStep.twoFactor;
        });
        return;
      }

      // 4. Security Approval / In-App Notification prompt
      if (lower.contains('approve') ||
          lower.contains('device confirmation') ||
          lower.contains('check your facebook app') ||
          lower.contains('notification sent') ||
          lower.contains('tap yes on your device') ||
          lower.contains('browser checkpoint')) {
        _timeoutTimer?.cancel();
        HapticFeedback.lightImpact();
        setState(() {
          _sheetError = null;
          _currentStep = FacebookConnectStep.appApproval;
        });
        return;
      }

      // 5. Flow selection prompt
      if (lower.contains('choose a login flow') ||
          lower.contains('available login flows') ||
          lower.contains('select flow')) {
        _timeoutTimer?.cancel();
        _availableFlows.clear();
        final lines = body.split('\n');
        for (final line in lines) {
          final t = line.trim();
          if (t.startsWith('-') || t.startsWith('*') || RegExp(r'^\d+\.').hasMatch(t)) {
            _availableFlows.add(t.replaceAll(RegExp(r'^[-\*\d\.\s]+'), '').trim());
          }
        }
        if (_availableFlows.isNotEmpty) {
          setState(() {
            _sheetError = null;
            _currentStep = FacebookConnectStep.flowSelection;
          });
          return;
        }
      }

      // 6. Errors and Rejections
      if (lower.contains('invalid cookies') ||
          lower.contains('failed to log in') ||
          lower.contains('failed to load inbox') ||
          lower.contains('version id not found') ||
          lower.contains('got logged out immediately') ||
          lower.contains('expired') ||
          lower.contains('invalid json') ||
          lower.contains('login error') ||
          lower.contains('internal error') ||
          lower.contains('challenge required') ||
          lower.contains('locked')) {
        _timeoutTimer?.cancel();
        HapticFeedback.heavyImpact();
        setState(() {
          _sheetError = body.length > 250 ? '${body.substring(0, 247)}...' : body;
          if (_currentStep == FacebookConnectStep.loading) {
            _currentStep = FacebookConnectStep.chooseMethod;
          }
        });
      }
    });

    // Fallback 60s timeout
    _timeoutTimer?.cancel();
    _timeoutTimer = Timer(const Duration(seconds: 60), () {
      if (mounted && _currentStep == FacebookConnectStep.loading) {
        setState(() {
          _sheetError =
              "Timed out waiting for Facebook bridge bot to reply. Please check connection and try again.";
          _currentStep = FacebookConnectStep.chooseMethod;
        });
      }
    });
  }

  // ─── HEADLESS BACKGROUND CREDENTIAL LOGIN ─────────────────────────────────

  Future<Map<String, String>> _extractAllCookies() async {
    final Map<String, String> cookies = {};
    final domains = [
      Uri.parse('https://facebook.com'),
      Uri.parse('https://www.facebook.com'),
      Uri.parse('https://m.facebook.com'),
      Uri.parse('https://messenger.com'),
      Uri.parse('https://www.messenger.com'),
    ];

    for (final domain in domains) {
      try {
        final list = await _cookieManager.getCookies(domain: domain);
        for (final c in list) {
          if (c.name.isNotEmpty && c.value.isNotEmpty) {
            cookies[c.name] = c.value;
          }
        }
      } catch (_) {}
    }

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
          _addLog('🔑 Successfully resolved live fb_dtsg token from Facebook (${_extractedFbDtsg!.substring(0, 10)}...)');
        }
      } catch (_) {}
    }

    return cookies;
  }

  // JavaScript that hooks into fetch/XHR to capture genuine GraphQL network requests
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

  WebViewController? _headlessController;

  Future<void> _performNativeCredentialLogin() async {
    final email = _usernameController.text.trim();
    final password = _passwordController.text;

    if (email.isEmpty || password.isEmpty) {
      setState(() {
        _sheetError = 'Please enter your Facebook username/email and password.';
      });
      return;
    }

    FocusManager.instance.primaryFocus?.unfocus();
    HapticFeedback.lightImpact();

    // Clear stale cookies first so old expired sessions don't cause false positives
    try {
      await _cookieManager.clearCookies();
    } catch (_) {}

    setState(() {
      _currentStep = FacebookConnectStep.loading;
      _loadingMessage = 'Authenticating with Facebook Messenger...';
      _sheetError = null;
      _hasSentCookiesToBot = false;
      _capturedRealCurl = null;
    });

    // 1. Start bridge handshake
    final room = await _resolveBotRoom();
    if (room != null) {
      _listenToBot(room);

      _addLog('📤 Sent: cancel');
      await room.sendTextEvent('cancel');
      await Future.delayed(const Duration(milliseconds: 400));
      _addLog('📤 Sent: login');
      await room.sendTextEvent('login');
    }

    // 2. Create invisible headless WebView with network interceptor
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
          onPageStarted: (url) {
            _addLog('🌐 Navigating: $url');
            try {
              controller.runJavaScript(_kNetworkInterceptorJs);
            } catch (_) {}
          },
          onPageFinished: (url) async {
            _addLog('🌐 Page loaded: $url');
            try {
              await controller.runJavaScript(_kNetworkInterceptorJs);
            } catch (_) {}
            await _handleHeadlessLoginStep(controller, url, email, password);
          },
          onNavigationRequest: (NavigationRequest request) {
            final lower = request.url.toLowerCase();
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

    setState(() {
      _headlessController = controller;
    });
    controller.loadRequest(Uri.parse('https://www.messenger.com/?no_redirect=true'));

    // 3. Start background cookie polling timer
    _cookiePollTimer?.cancel();
    int elapsedSeconds = 0;
    _cookiePollTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      elapsedSeconds += 2;
      if (!mounted || _currentStep != FacebookConnectStep.loading) {
        timer.cancel();
        return;
      }

      final cookies = await _extractAllCookies();
      if (FacebookCookieExtractor.hasValidSession(cookies) && !_hasSentCookiesToBot) {
        _hasSentCookiesToBot = true;
        timer.cancel();
        _addLog('✅ Captured session cookies (c_user, xs, datr, sb)!');
        _capturedCookies.clear();
        _capturedCookies.addAll(cookies);
        setState(() {
          _loadingMessage = 'Resolving Facebook security tokens...';
        });

        // Resolve fb_dtsg if not captured from DOM
        String? dtsg = _extractedFbDtsg;
        String? jazoest = _extractedJazoest;
        String? spinR = _extractedSpinR;
        String? userId = _extractedUserId ?? FacebookCookieExtractor.getUserId(cookies);

        if (dtsg == null || dtsg.isEmpty) {
          _addLog('⏳ Resolving live fb_dtsg token from Facebook...');
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
            _addLog('🔑 Resolved fb_dtsg: ${dtsg!.substring(0, dtsg.length > 10 ? 10 : dtsg.length)}...');
          }
        }

        // Build the payload — prefer real browser cURL
        final payload = (_capturedRealCurl != null && _capturedRealCurl!.isNotEmpty)
            ? _capturedRealCurl!
            : FacebookCookieExtractor.formatDeepGraphQlCurl(
                cookies: cookies,
                fbDtsg: dtsg,
                spinR: spinR,
                jazoest: jazoest,
                userId: userId,
              );
        _lastPassedCurl = payload;

        // If the bridge is already waiting, send now. Otherwise queue it.
        if (_isBridgeReady) {
          _addLog('📤 Transmitting ${_capturedRealCurl != null ? "Real Browser cURL" : "GraphQL cURL"} to bridge...');
          setState(() {
            _loadingMessage = 'Submitting session to bridge bot...';
          });
          await _pushPayloadToBridge(payload);
        } else {
          _pendingCookiePayload = payload;
          _addLog('⏳ Session ready, waiting for bridge bot to be ready...');
          setState(() {
            _loadingMessage = 'Waiting for bridge bot...';
          });
        }
      } else if (elapsedSeconds >= 30) {
        timer.cancel();
        if (!_hasSentCookiesToBot) {
          String currentUrl = '';
          try {
            currentUrl = await controller.currentUrl() ?? '';
          } catch (_) {}
          final lower = currentUrl.toLowerCase();
          if (lower.contains('checkpoint') || lower.contains('two-factor') || lower.contains('approvals_code')) {
            setState(() {
              _currentStep = FacebookConnectStep.twoFactor;
            });
          } else {
            // Check if login failed (still on login page)
            setState(() {
              _currentStep = FacebookConnectStep.chooseMethod;
              _sheetError = 'Could not authenticate. Please check your credentials or use "Log in via In-App Browser".';
            });
          }
        }
      }
    });
  }

  Future<void> _handleHeadlessLoginStep(
      WebViewController controller, String url, String email, String password) async {
    final lower = url.toLowerCase();

    // Auto-fill and submit login form
    if (lower.contains('login') ||
        lower == 'https://www.messenger.com/' ||
        lower == 'https://www.messenger.com/?no_redirect=true' ||
        lower.contains('messenger.com') ||
        lower.contains('facebook.com')) {
      final jsCode = """
        (function() {
          // Auto-accept cookie consent dialog if present
          try {
            var cookieBtn = document.querySelector('[data-cookiebanner="accept_button"]') || 
                            document.querySelector('button[data-testid="cookie-policy-manage-dialog-accept-button"]') ||
                            document.querySelector('button[value="1"]');
            if (cookieBtn) cookieBtn.click();
          } catch(e) {}

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

          var btn = document.querySelector('#loginbutton') || 
                    document.querySelector('button[name="login"]') || 
                    document.querySelector('button[type="submit"]') || 
                    document.querySelector('input[type="submit"]') ||
                    document.querySelector('div[role="button"][tabindex="0"]');

          if (emailInput && passInput) {
            try {
              var setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value").set;
              setter.call(emailInput, ${jsonEncode(email)});
              setter.call(passInput, ${jsonEncode(password)});
            } catch (e) {
              emailInput.value = ${jsonEncode(email)};
              passInput.value = ${jsonEncode(password)};
            }
            emailInput.dispatchEvent(new Event('input', { bubbles: true }));
            emailInput.dispatchEvent(new Event('change', { bubbles: true }));
            passInput.dispatchEvent(new Event('input', { bubbles: true }));
            passInput.dispatchEvent(new Event('change', { bubbles: true }));

            setTimeout(function() {
              if (btn) {
                btn.click();
              } else {
                var form = emailInput.closest('form');
                if (form) form.submit();
              }
            }, 150);
            return 'submitted';
          }
          return 'no_form';
        })();
      """;
      try {
        final result = await controller.runJavaScriptReturningResult(jsCode);
        _addLog('🤖 Form submit status: $result');
      } catch (_) {}
    }

    // Check for 2FA / checkpoint
    if (lower.contains('checkpoint') ||
        lower.contains('two-factor') ||
        lower.contains('approvals_code')) {
      _addLog('🔐 Facebook 2FA verification required.');
      setState(() {
        _currentStep = FacebookConnectStep.twoFactor;
      });
      return;
    }
  }

  // ─── TRANSMIT PAYLOAD TO BRIDGE BOT ────────────────────────────────────────

  Future<void> _pushPayloadToBridge(String payload) async {
    try {
      final room = _botRoom ?? await _resolveBotRoom();
      if (room != null) {
        _addLog('📤 Sending payload to bridge bot...');
        await room.sendTextEvent(payload);
      } else {
        _addLog('❌ Could not reach bridge service.');
        setState(() {
          _sheetError = 'Could not reach Facebook service. Please retry.';
          _currentStep = FacebookConnectStep.chooseMethod;
        });
      }
    } catch (e) {
      _addLog('❌ Error transmitting to bridge: $e');
      setState(() {
        _sheetError = 'Error sending credentials to Facebook service: $e';
        _currentStep = FacebookConnectStep.chooseMethod;
      });
    }
  }

  // ─── START IN-APP MOBILE WEB LOGIN ────────────────────────────────────────

  Future<void> _startMobileWebLogin({String? targetUrlOverride}) async {
    HapticFeedback.lightImpact();

    // 1. Resolve bot room
    final room = await _resolveBotRoom();
    if (room == null) {
      setState(() {
        _sheetError = "Could not reach Facebook service. Ensure connection is active.";
      });
      return;
    }

    _listenToBot(room);
    _loginUrlCompleter = Completer<String>();

    // 2. Send cancel command first to clear any stale state
    _addLog('📤 Sent: cancel');
    await room.sendTextEvent('cancel');
    await Future.delayed(const Duration(milliseconds: 250));

    // 3. Send login command to trigger the bot to reply with the login URL
    _addLog('📤 Sent: login');
    await room.sendTextEvent('login');

    // 4. Wait for the bridge bot to reply with the login URL
    String targetUrl = targetUrlOverride ?? _bridgeLoginUrl ?? '';
    if (targetUrl.isEmpty) {
      try {
        targetUrl = await _loginUrlCompleter!.future.timeout(
          const Duration(seconds: 3),
          onTimeout: () => _bridgeLoginUrl ?? 'https://www.messenger.com/?no_redirect=true',
        );
      } catch (_) {
        targetUrl = _bridgeLoginUrl ?? 'https://www.messenger.com/?no_redirect=true';
      }
    }

    if (targetUrl.isEmpty) {
      targetUrl = 'https://www.messenger.com/?no_redirect=true';
    }

    _addLog('🌐 Opening mobile login at: $targetUrl');

    // 5. Open in-app browser view
    await FacebookMessengerWebLoginView.open(
      context,
      client: widget.client,
      onConnected: widget.onConnected,
      initialUrl: targetUrl,
    );
  }

  // ─── SUBMIT MANUAL COOKIES OR CURL ────────────────────────────────────────

  Future<void> _submitManualCookies() async {
    FocusManager.instance.primaryFocus?.unfocus();

    final input = _cookiesInputController.text.trim();
    if (input.isEmpty) {
      setState(() {
        _sheetError = 'Please paste your cURL (bash) command or Facebook session cookies.';
      });
      return;
    }

    final parsed = FacebookCookieExtractor.parseCookies(input);
    final params = FacebookCookieExtractor.extractGraphQLParams(input);

    if (!FacebookCookieExtractor.hasValidSession(parsed)) {
      setState(() {
        _sheetError =
            'Could not find valid session tokens (c_user & xs). Ensure you copied the complete cURL (bash) from Chrome DevTools.';
      });
      return;
    }

    final userId = params.userId ?? FacebookCookieExtractor.getUserId(parsed);
    if (userId != null) {
      _accountIdentifier = 'ID: $userId';
    }

    String payload;
    if (FacebookCookieExtractor.isCurlCommand(input)) {
      payload = FacebookCookieExtractor.normalizeToBashCurl(input);
      _addLog('📤 Transmitting authentic cURL (bash) command to bridge for user $userId');
    } else {
      String? dtsg = params.fbDtsg ?? _extractedFbDtsg;
      String? jazoest = params.jazoest ?? _extractedJazoest;
      String? spinR = params.spinR ?? _extractedSpinR;

      if (dtsg == null || dtsg.isEmpty) {
        _addLog('⏳ Resolving live fb_dtsg token from Facebook...');
        final webParams = await FacebookCookieExtractor.fetchGraphQLParamsFromWeb(parsed);
        if (webParams.fbDtsg != null && webParams.fbDtsg!.isNotEmpty) {
          dtsg = webParams.fbDtsg;
          jazoest = webParams.jazoest ?? FacebookCookieExtractor.computeJazoest(dtsg!);
          spinR ??= webParams.spinR;
          _extractedFbDtsg = dtsg;
          _extractedJazoest = jazoest;
          _extractedSpinR = spinR;
          _addLog('🔑 Successfully resolved live fb_dtsg: ${dtsg!.substring(0, dtsg.length > 10 ? 10 : dtsg.length)}...');
        }
      }

      payload = FacebookCookieExtractor.formatDeepGraphQlCurl(
        cookies: parsed,
        fbDtsg: dtsg,
        spinR: spinR,
        jazoest: jazoest,
        userId: userId ?? _extractedUserId,
      );
      _addLog('📤 Formatted deep GraphQL cURL credentials with ${parsed.length} cookies for user $userId');
    }

    await _transmitCookiesToBridge(payload);
  }

  // ─── TRANSMIT COOKIES TO BRIDGE BOT ───────────────────────────────────────

  Future<void> _transmitCookiesToBridge(String cookiePayload) async {
    _lastPassedCurl = cookiePayload;
    setState(() {
      _sheetError = null;
      _currentStep = FacebookConnectStep.loading;
      _loadingMessage = 'Connecting to Facebook Messenger bridge...';
      _pendingCookiePayload = cookiePayload;
    });

    try {
      final room = await _resolveBotRoom();
      if (room == null) {
        setState(() {
          _currentStep = FacebookConnectStep.chooseMethod;
          _sheetError =
              "Could not reach Facebook Bridge bot. Ensure the bridge service is running.";
        });
        return;
      }

      _listenToBot(room);

      setState(() => _loadingMessage = 'Authenticating session with bridge bot...');
      _addLog('📤 Initiating handshake with bridge bot...');
      await room.sendTextEvent('cancel');
      await Future.delayed(const Duration(milliseconds: 300));
      await room.sendTextEvent('login');

      // Fallback: if bot doesn't send prompt within 1.5s, send payload directly
      Future.delayed(const Duration(milliseconds: 1500), () async {
        if (mounted && _pendingCookiePayload != null && !_hasSentCookiesToBot) {
          _hasSentCookiesToBot = true;
          final payload = _pendingCookiePayload!;
          _pendingCookiePayload = null;
          _addLog('📤 Transmitting credentials payload to bridge:\n$payload');
          await room.sendTextEvent(payload);
        }
      });
    } catch (e) {
      _addLog('Error: $e');
      setState(() {
        _currentStep = FacebookConnectStep.chooseMethod;
        _sheetError = "Failed to communicate with bridge bot: $e";
      });
    }
  }

  // ─── SUBMIT 2FA CODE ──────────────────────────────────────────────────────

  Future<void> _submitTwoFactorCode(String code) async {
    final cleanCode = code.trim();
    if (cleanCode.isEmpty) return;

    setState(() {
      _sheetError = null;
      _currentStep = FacebookConnectStep.loading;
      _loadingMessage = 'Verifying security code...';
    });

    try {
      final room = await _resolveBotRoom();
      if (room == null) {
        setState(() {
          _currentStep = FacebookConnectStep.twoFactor;
          _sheetError = "Connection to bridge lost. Please retry.";
        });
        return;
      }

      _listenToBot(room);

      _addLog('📤 Sent: $cleanCode');
      await room.sendTextEvent(cleanCode);
    } catch (e) {
      _addLog('Error: $e');
      setState(() {
        _currentStep = FacebookConnectStep.twoFactor;
        _sheetError = "Failed to submit verification code: $e";
      });
    }
  }

  // ─── SELECT LOGIN FLOW ────────────────────────────────────────────────────

  Future<void> _selectFlow(String flow) async {
    setState(() {
      _sheetError = null;
      _currentStep = FacebookConnectStep.loading;
      _loadingMessage = 'Selecting $flow flow...';
    });

    try {
      final room = await _resolveBotRoom();
      if (room == null) return;

      _listenToBot(room);

      final cmd = FacebookBridgeCommands.login(flow);
      _addLog('📤 Sent: $cmd');
      await room.sendTextEvent(cmd);
    } catch (e) {
      _addLog('Error: $e');
      setState(() {
        _currentStep = FacebookConnectStep.flowSelection;
        _sheetError = 'Failed to select flow: $e';
      });
    }
  }

  // ─── RECHECK IN-APP APPROVAL ──────────────────────────────────────────────

  Future<void> _checkAppApproval() async {
    setState(() {
      _sheetError = null;
      _currentStep = FacebookConnectStep.loading;
      _loadingMessage = 'Checking Facebook approval status...';
    });

    try {
      final room = await _resolveBotRoom();
      if (room == null) return;

      _listenToBot(room);

      _addLog('📤 Sent: ${FacebookBridgeCommands.pingMatrix()}');
      await room.sendTextEvent(FacebookBridgeCommands.pingMatrix());
    } catch (e) {
      _addLog('Error: $e');
      setState(() {
        _currentStep = FacebookConnectStep.appApproval;
        _sheetError = 'Failed to verify approval: $e';
      });
    }
  }

  // ─── UI BUILDERS ──────────────────────────────────────────────────────────

  Widget _buildTopDragHandle() {
    final c = context.allora;
    return Center(
      child: Container(
        width: 36,
        height: 4,
        margin: const EdgeInsets.only(bottom: 16),
        decoration: BoxDecoration(
          color: c.outline,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final c = context.allora;
    return Row(
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [kMessengerBlue, kMessengerPurple],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                color: kMessengerBlue.withValues(alpha: 0.3),
                blurRadius: 10,
                offset: const Offset(0, 4),
              )
            ],
          ),
          alignment: Alignment.center,
          child: Image.asset(
            'assets/images/messenger.png',
            width: 24,
            height: 24,
            errorBuilder: (_, __, ___) => const Icon(
              Icons.chat_bubble_rounded,
              color: Colors.white,
              size: 20,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Messenger',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.poppins(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: c.text,
                  letterSpacing: -0.2,
                ),
              ),
              Text(
                'Facebook Conversations Bridge',
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
        IconButton(
          constraints: const BoxConstraints(),
          padding: const EdgeInsets.all(8),
          icon: Icon(
            _showLogs ? Icons.terminal_rounded : Icons.info_outline_rounded,
            color: _showLogs ? kMessengerBlue : c.textSecondary,
            size: 20,
          ),
          tooltip: 'Bridge Logs',
          onPressed: () => setState(() => _showLogs = !_showLogs),
        ),
        IconButton(
          constraints: const BoxConstraints(),
          padding: const EdgeInsets.all(8),
          icon: Icon(Icons.close_rounded, color: c.textSecondary, size: 20),
          onPressed: () {
            _activeSub?.cancel();
            _timeoutTimer?.cancel();
            Navigator.pop(context);
          },
        ),
      ],
    );
  }

  Widget _buildLogsDrawer() {
    if (!_showLogs) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.only(top: 14, bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.blueGrey.withValues(alpha: 0.2)),
      ),
      constraints: const BoxConstraints(maxHeight: 140),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'LIVE BRIDGE COMMANDS',
                style: GoogleFonts.firaCode(
                  color: Colors.cyanAccent,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_capturedCookies.isNotEmpty) ...[
                    GestureDetector(
                      onTap: () {
                        final payload =
                            FacebookCookieExtractor.formatDeepGraphQlCurl(
                          cookies: _capturedCookies,
                          fbDtsg: _extractedFbDtsg,
                          spinR: _extractedSpinR,
                          jazoest: _extractedJazoest,
                          userId: _extractedUserId,
                        );
                        Clipboard.setData(ClipboardData(text: payload));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Deep GraphQL cURL copied to clipboard!'),
                            backgroundColor: Color(0xFF10B981),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      },
                      child: Text(
                        'COPY COOKIES',
                        style: GoogleFonts.firaCode(
                          color: const Color(0xFF60A5FA),
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                  ],
                  GestureDetector(
                    onTap: () => setState(() => _debugLogs.clear()),
                    child: Text(
                      'CLEAR',
                      style: GoogleFonts.firaCode(
                        color: Colors.grey,
                        fontSize: 10,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const Divider(color: Colors.white12, height: 8),
          Expanded(
            child: ListView.builder(
              reverse: true,
              itemCount: _debugLogs.length,
              itemBuilder: (context, idx) {
                final log = _debugLogs[_debugLogs.length - 1 - idx];
                final isOut = log.startsWith('📤');
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    log,
                    style: GoogleFonts.firaCode(
                      color: isOut
                          ? const Color(0xFF60A5FA)
                          : const Color(0xFF94A3B8),
                      fontSize: 11,
                    ),
                  ),
                );
              },
            ),
          )
        ],
      ),
    );
  }

  Widget _buildErrorBanner() {
    if (_sheetError == null) return const SizedBox.shrink();
    final c = context.allora;

    return Container(
      margin: const EdgeInsets.only(top: 14, bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.redAccent.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.redAccent.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.error_outline_rounded,
                  color: Colors.redAccent, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _sheetError!,
                  style: GoogleFonts.poppins(
                    color: Colors.redAccent,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
          if (_lastPassedCurl != null && _lastPassedCurl!.isNotEmpty) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      HapticFeedback.lightImpact();
                      Clipboard.setData(ClipboardData(text: _lastPassedCurl!));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Whole cURL (bash) copied to clipboard!'),
                          backgroundColor: Color(0xFF10B981),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    },
                    icon: const Icon(Icons.copy_rounded, size: 15),
                    label: Text(
                      'Copy cURL (bash)',
                      style: GoogleFonts.poppins(fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.redAccent,
                      side: const BorderSide(color: Colors.redAccent, width: 1.2),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: () => _showCurlPreviewDialog(_lastPassedCurl!),
                  icon: const Icon(Icons.code_rounded, size: 18),
                  tooltip: 'View cURL payload',
                  style: IconButton.styleFrom(
                    foregroundColor: c.textSecondary,
                    backgroundColor: c.surfaceAlt,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  void _showCurlPreviewDialog(String curl) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        height: MediaQuery.of(ctx).size.height * 0.7,
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
                  'GENERATED CURL (BASH)',
                  style: GoogleFonts.firaCode(
                    color: Colors.cyanAccent,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.copy_rounded, color: Colors.cyanAccent, size: 18),
                      tooltip: 'Copy all',
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: curl));
                        Navigator.pop(ctx);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Whole cURL (bash) copied to clipboard!'),
                            backgroundColor: Color(0xFF10B981),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded, color: Colors.white70, size: 20),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
              ],
            ),
            const Divider(color: Colors.white12, height: 12),
            Expanded(
              child: SingleChildScrollView(
                child: SelectableText(
                  curl,
                  style: GoogleFonts.firaCode(
                    color: const Color(0xFF94A3B8),
                    fontSize: 11.5,
                    height: 1.5,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPillButton(String label, VoidCallback? onTap,
      {bool isPrimary = true, IconData? icon}) {
    return ElevatedButton(
      onPressed: onTap,
      style: ElevatedButton.styleFrom(
        backgroundColor: isPrimary ? kMessengerBlue : Colors.transparent,
        foregroundColor: isPrimary ? Colors.white : kMessengerBlue,
        minimumSize: const Size(double.infinity, 52),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: isPrimary
              ? BorderSide.none
              : const BorderSide(color: kMessengerBlue, width: 1.5),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 19),
            const SizedBox(width: 8),
          ],
          Text(
            label,
            style: GoogleFonts.poppins(
              fontWeight: FontWeight.w600,
              fontSize: 15.5,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }

  // ─── STEP BODIES ──────────────────────────────────────────────────────────

  Widget _buildChooseMethodStep() {
    final c = context.allora;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),

        // Brand Connection Header Icons (Allora <-> Messenger)
        Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: kAlloraBlue,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: kAlloraBlue.withValues(alpha: 0.25),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                alignment: Alignment.center,
                child: const Icon(Icons.all_inclusive_rounded, color: Colors.white, size: 28),
              ),
              const SizedBox(width: 14),
              Icon(Icons.swap_horiz_rounded, color: c.textSecondary, size: 24),
              const SizedBox(width: 14),
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [kMessengerBlue, kMessengerPurple],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: kMessengerBlue.withValues(alpha: 0.25),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                alignment: Alignment.center,
                child: Image.asset(
                  'assets/images/messenger.png',
                  width: 26,
                  height: 26,
                  errorBuilder: (_, __, ___) => const Icon(
                    Icons.chat_bubble_rounded,
                    color: Colors.white,
                    size: 24,
                  ),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 18),

        // Subtitle Instructions matching Beeper
        Text(
          'Enter your Facebook credentials. The Messenger network will only work with Facebook accounts.',
          textAlign: TextAlign.center,
          style: GoogleFonts.poppins(
            fontSize: 13.5,
            color: c.textSecondary,
            height: 1.45,
          ),
        ),

        const SizedBox(height: 22),

        // Username / Email input field
        Container(
          decoration: BoxDecoration(
            color: c.surfaceAlt,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: c.outline),
          ),
          child: TextField(
            controller: _usernameController,
            textInputAction: TextInputAction.next,
            keyboardType: TextInputType.emailAddress,
            style: GoogleFonts.poppins(color: c.text, fontSize: 14),
            decoration: InputDecoration(
              hintText: 'Username or email address',
              hintStyle: GoogleFonts.poppins(color: c.textTertiary, fontSize: 13.5),
              contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
              border: InputBorder.none,
            ),
          ),
        ),

        const SizedBox(height: 12),

        // Password input field
        Container(
          decoration: BoxDecoration(
            color: c.surfaceAlt,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: c.outline),
          ),
          child: TextField(
            controller: _passwordController,
            obscureText: _obscurePassword,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _performNativeCredentialLogin(),
            style: GoogleFonts.poppins(color: c.text, fontSize: 14),
            decoration: InputDecoration(
              hintText: 'Password',
              hintStyle: GoogleFonts.poppins(color: c.textTertiary, fontSize: 13.5),
              contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
              border: InputBorder.none,
              suffixIcon: IconButton(
                icon: Icon(
                  _obscurePassword ? Icons.visibility_off_rounded : Icons.visibility_rounded,
                  color: c.textSecondary,
                  size: 20,
                ),
                onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
              ),
            ),
          ),
        ),

        const SizedBox(height: 22),

        // Continue Button
        ElevatedButton(
          onPressed: _performNativeCredentialLogin,
          style: ElevatedButton.styleFrom(
            backgroundColor: kMessengerBlue,
            foregroundColor: Colors.white,
            minimumSize: const Size(double.infinity, 52),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            elevation: 0,
          ),
          child: Text(
            'Continue',
            style: GoogleFonts.poppins(
              fontSize: 15.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),

        const SizedBox(height: 12),

        // Direct In-App Web Login Button
        OutlinedButton.icon(
          onPressed: () => _startMobileWebLogin(),
          icon: const Icon(Icons.open_in_browser_rounded, size: 18),
          label: Text(
            'Log in via In-App Browser',
            style: GoogleFonts.poppins(
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          style: OutlinedButton.styleFrom(
            foregroundColor: kMessengerBlue,
            side: const BorderSide(color: kMessengerBlue, width: 1.2),
            minimumSize: const Size(double.infinity, 50),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildManualCookiesStep() {
    final c = context.allora;
    final currentText = _cookiesInputController.text;
    final parsed = FacebookCookieExtractor.parseCookies(currentText);
    final params = FacebookCookieExtractor.extractGraphQLParams(currentText);
    final hasValidSession = FacebookCookieExtractor.hasValidSession(parsed);
    final userId = params.userId ?? FacebookCookieExtractor.getUserId(parsed);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: kMessengerBlue.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.terminal_rounded, color: kMessengerBlue, size: 20),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Paste GraphQL cURL',
                    style: GoogleFonts.poppins(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: c.text,
                    ),
                  ),
                  Text(
                    'Paste cURL (bash) from Chrome DevTools to connect',
                    style: GoogleFonts.poppins(
                      fontSize: 11.5,
                      color: c.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),

        const SizedBox(height: 14),

        // Paste & Copy Buttons Row
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () async {
                  HapticFeedback.lightImpact();
                  final data = await Clipboard.getData(Clipboard.kTextPlain);
                  if (data?.text != null && data!.text!.isNotEmpty) {
                    setState(() {
                      _cookiesInputController.text = data.text!;
                    });
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Clipboard is empty. Copy cURL (bash) from browser first.'),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  }
                },
                icon: const Icon(Icons.paste_rounded, size: 16),
                label: Text(
                  'Paste from Clipboard',
                  style: GoogleFonts.poppins(fontSize: 12, fontWeight: FontWeight.w600),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: kMessengerBlue,
                  side: const BorderSide(color: kMessengerBlue, width: 1.2),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                ),
              ),
            ),
            if (currentText.isNotEmpty) ...[
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () {
                  HapticFeedback.lightImpact();
                  final curlToCopy = FacebookCookieExtractor.isCurlCommand(currentText)
                      ? FacebookCookieExtractor.normalizeToBashCurl(currentText)
                      : (hasValidSession
                          ? FacebookCookieExtractor.formatDeepGraphQlCurl(
                              cookies: parsed,
                              fbDtsg: params.fbDtsg ?? _extractedFbDtsg,
                              spinR: params.spinR ?? _extractedSpinR,
                              jazoest: params.jazoest ?? _extractedJazoest,
                              userId: userId ?? _extractedUserId,
                            )
                          : currentText);
                  Clipboard.setData(ClipboardData(text: curlToCopy));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Whole cURL (bash) copied to clipboard!'),
                      backgroundColor: Color(0xFF10B981),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                },
                icon: const Icon(Icons.copy_rounded, size: 15),
                label: Text(
                  'Copy cURL (bash)',
                  style: GoogleFonts.poppins(fontSize: 12, fontWeight: FontWeight.w600),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF10B981),
                  side: const BorderSide(color: Color(0xFF10B981), width: 1.2),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 10),
                ),
              ),
              const SizedBox(width: 6),
              IconButton(
                onPressed: () {
                  setState(() {
                    _cookiesInputController.clear();
                  });
                },
                icon: const Icon(Icons.clear_rounded, size: 18),
                tooltip: 'Clear input',
                style: IconButton.styleFrom(
                  foregroundColor: c.textSecondary,
                  backgroundColor: c.surfaceAlt,
                ),
              ),
            ],
          ],
        ),

        const SizedBox(height: 10),

        // Text area
        Container(
          decoration: BoxDecoration(
            color: c.surfaceAlt,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: hasValidSession
                  ? const Color(0xFF10B981)
                  : (currentText.isNotEmpty ? Colors.orangeAccent : c.outline),
              width: hasValidSession ? 1.5 : 1,
            ),
          ),
          child: TextField(
            controller: _cookiesInputController,
            maxLines: 4,
            onChanged: (_) => setState(() {}),
            style: GoogleFonts.firaCode(color: c.text, fontSize: 12),
            decoration: InputDecoration(
              hintText: "curl 'https://www.messenger.com/api/graphql/' \\\n  -H 'cookie: ...' \\\n  --data-raw '...'",
              hintStyle: GoogleFonts.firaCode(color: c.textTertiary, fontSize: 11),
              filled: false,
              border: InputBorder.none,
              contentPadding: const EdgeInsets.all(14),
            ),
          ),
        ),

        // Validation badge if detected
        if (hasValidSession) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF10B981).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFF10B981).withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                const Icon(Icons.check_circle_rounded, color: Color(0xFF10B981), size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Valid session detected!${userId != null ? ' (User: $userId)' : ''}',
                        style: GoogleFonts.poppins(
                          color: const Color(0xFF10B981),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        'Tokens: ${FacebookCookieExtractor.summarizeKeys(parsed)}',
                        style: GoogleFonts.poppins(
                          color: c.textSecondary,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                TextButton.icon(
                  onPressed: () {
                    HapticFeedback.lightImpact();
                    final curlToCopy = FacebookCookieExtractor.isCurlCommand(currentText)
                        ? FacebookCookieExtractor.normalizeToBashCurl(currentText)
                        : FacebookCookieExtractor.formatDeepGraphQlCurl(
                            cookies: parsed,
                            fbDtsg: params.fbDtsg ?? _extractedFbDtsg,
                            spinR: params.spinR ?? _extractedSpinR,
                            jazoest: params.jazoest ?? _extractedJazoest,
                            userId: userId ?? _extractedUserId,
                          );
                    Clipboard.setData(ClipboardData(text: curlToCopy));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Whole cURL (bash) copied to clipboard!'),
                        backgroundColor: Color(0xFF10B981),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  },
                  icon: const Icon(Icons.copy_rounded, size: 14, color: Color(0xFF10B981)),
                  label: Text(
                    'Copy cURL',
                    style: GoogleFonts.poppins(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: const Color(0xFF10B981),
                    ),
                  ),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    minimumSize: Size.zero,
                  ),
                ),
              ],
            ),
          ),
        ],

        const SizedBox(height: 16),
        _buildPillButton(
          'Connect Messenger',
          _submitManualCookies,
          icon: Icons.link_rounded,
        ),
        const SizedBox(height: 8),
        _buildPillButton(
          'Back to Credentials',
          () => setState(() => _currentStep = FacebookConnectStep.chooseMethod),
          isPrimary: false,
        ),
      ],
    );
  }

  Widget _buildTwoFactorStep() {
    final c = context.allora;
    final defaultPinTheme = PinTheme(
      width: 48,
      height: 56,
      textStyle: GoogleFonts.poppins(
        fontSize: 20,
        color: c.text,
        fontWeight: FontWeight.w700,
      ),
      decoration: BoxDecoration(
        border: Border.all(color: c.outline, width: 1.5),
        borderRadius: BorderRadius.circular(14),
        color: c.surfaceAlt,
      ),
    );

    final focusedPinTheme = PinTheme(
      width: 48,
      height: 56,
      textStyle: GoogleFonts.poppins(
        fontSize: 20,
        color: c.text,
        fontWeight: FontWeight.w700,
      ),
      decoration: BoxDecoration(
        border: Border.all(color: kMessengerBlue, width: 2),
        borderRadius: BorderRadius.circular(14),
        color: c.surface,
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        Text(
          'Two-Factor Authentication',
          style: GoogleFonts.poppins(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: c.text,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Enter the 6-digit security code from your Authenticator app or received via SMS on your phone.',
          style: GoogleFonts.poppins(
            fontSize: 13,
            color: c.textSecondary,
            height: 1.45,
          ),
        ),
        const SizedBox(height: 24),
        Center(
          child: Pinput(
            length: 6,
            controller: _twoFactorController,
            defaultPinTheme: defaultPinTheme,
            focusedPinTheme: focusedPinTheme,
            autofocus: true,
            onCompleted: _submitTwoFactorCode,
          ),
        ),
        const SizedBox(height: 28),
        _buildPillButton(
          'Verify & Continue',
          () => _submitTwoFactorCode(_twoFactorController.text),
        ),
        const SizedBox(height: 12),
        _buildPillButton(
          'Cancel',
          () => setState(() => _currentStep = FacebookConnectStep.chooseMethod),
          isPrimary: false,
        ),
      ],
    );
  }

  Widget _buildAppApprovalStep() {
    final c = context.allora;
    return Column(
      children: [
        const SizedBox(height: 16),
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            color: const Color(0xFFFEF3C7),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFF59E0B).withValues(alpha: 0.25),
                blurRadius: 14,
              )
            ],
          ),
          child: const Icon(
            Icons.phonelink_lock_rounded,
            color: Color(0xFFD97706),
            size: 36,
          ),
        ),
        const SizedBox(height: 20),
        Text(
          'Approve from Facebook App',
          textAlign: TextAlign.center,
          style: GoogleFonts.poppins(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: c.text,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Facebook detected a new login. Please open the Facebook app on your phone or check your notifications and tap "Yes, it was me".',
          textAlign: TextAlign.center,
          style: GoogleFonts.poppins(
            fontSize: 13.5,
            color: c.textSecondary,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 28),
        _buildPillButton("I've Approved on Facebook", _checkAppApproval),
        const SizedBox(height: 12),
        _buildPillButton(
          'Cancel',
          () {
            FacebookMessengerDisconnectService.cancelPendingAction(widget.client);
            setState(() => _currentStep = FacebookConnectStep.chooseMethod);
          },
          isPrimary: false,
        ),
      ],
    );
  }

  Widget _buildFlowSelectionStep() {
    final c = context.allora;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        Text(
          'Choose Authentication Flow',
          style: GoogleFonts.poppins(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: c.text,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Select the authentication method requested by your bridge.',
          style: GoogleFonts.poppins(
            fontSize: 13,
            color: c.textSecondary,
          ),
        ),
        const SizedBox(height: 20),
        ..._availableFlows.map((flow) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: InkWell(
              onTap: () => _selectFlow(flow),
              borderRadius: BorderRadius.circular(16),
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: c.surfaceAlt,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: c.outline),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: kMessengerBlue.withValues(alpha: 0.12),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.login_rounded,
                        color: kMessengerBlue,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        flow.toUpperCase(),
                        style: GoogleFonts.poppins(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: c.text,
                        ),
                      ),
                    ),
                    Icon(
                      Icons.chevron_right_rounded,
                      color: c.textTertiary,
                    )
                  ],
                ),
              ),
            ),
          );
        }),
      ],
    );
  }

  Widget _buildLoadingStep() {
    final c = context.allora;
    return Column(
      children: [
        const SizedBox(height: 16),
        const MessengerRadarAnimation(),
        const SizedBox(height: 16),
        Text(
          'Connecting to Messenger',
          style: GoogleFonts.poppins(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: c.text,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          _loadingMessage,
          textAlign: TextAlign.center,
          style: GoogleFonts.poppins(
            fontSize: 13,
            color: c.textSecondary,
          ),
        ),
        const SizedBox(height: 16),

        // Live Log Output Box right inside the loading step
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFF0F172A),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.blueGrey.withValues(alpha: 0.2)),
          ),
          constraints: const BoxConstraints(maxHeight: 140),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'LIVE CONNECTION LOGS',
                    style: GoogleFonts.firaCode(
                      color: Colors.cyanAccent,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_capturedCookies.isNotEmpty) ...[
                        GestureDetector(
                          onTap: () {
                            final payload =
                                FacebookCookieExtractor.formatDeepGraphQlCurl(
                              cookies: _capturedCookies,
                              fbDtsg: _extractedFbDtsg,
                              spinR: _extractedSpinR,
                              jazoest: _extractedJazoest,
                              userId: _extractedUserId,
                            );
                            Clipboard.setData(ClipboardData(text: payload));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Deep GraphQL cURL copied to clipboard!'),
                                backgroundColor: Color(0xFF10B981),
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          },
                          child: Text(
                            'COPY COOKIES',
                            style: GoogleFonts.firaCode(
                              color: const Color(0xFF60A5FA),
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                      ],
                      GestureDetector(
                        onTap: () => setState(() => _debugLogs.clear()),
                        child: Text(
                          'CLEAR',
                          style: GoogleFonts.firaCode(
                            color: Colors.grey,
                            fontSize: 10,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const Divider(color: Colors.white12, height: 8),
              Expanded(
                child: ListView.builder(
                  reverse: true,
                  itemCount: _debugLogs.length,
                  itemBuilder: (context, idx) {
                    final log = _debugLogs[_debugLogs.length - 1 - idx];
                    final isOut = log.startsWith('📤');
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        log,
                        style: GoogleFonts.firaCode(
                          color: isOut
                              ? const Color(0xFF60A5FA)
                              : const Color(0xFF94A3B8),
                          fontSize: 11,
                        ),
                      ),
                    );
                  },
                ),
              )
            ],
          ),
        ),

        const SizedBox(height: 20),
        SizedBox(
          width: 180,
          child: OutlinedButton(
            onPressed: () {
              _cookiePollTimer?.cancel();
              FacebookMessengerDisconnectService.cancelPendingAction(
                  widget.client);
              setState(() => _currentStep = FacebookConnectStep.chooseMethod);
            },
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: c.outline),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            child: Text(
              'Cancel',
              style: GoogleFonts.poppins(
                fontSize: 13,
                color: c.textSecondary,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSuccessStep() {
    final c = context.allora;
    return Column(
      children: [
        const SizedBox(height: 20),
        Container(
          width: 76,
          height: 76,
          decoration: BoxDecoration(
            color: const Color(0xFF10B981).withValues(alpha: 0.14),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.check_circle_rounded,
            color: Color(0xFF10B981),
            size: 48,
          ),
        ),
        const SizedBox(height: 20),
        Text(
          'Messenger Connected!',
          style: GoogleFonts.poppins(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: c.text,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Your Facebook Messenger chats, direct messages, and groups will now sync directly to your Allora inbox.',
          textAlign: TextAlign.center,
          style: GoogleFonts.poppins(
            fontSize: 13.5,
            color: c.textSecondary,
            height: 1.45,
          ),
        ),
        const SizedBox(height: 32),
        _buildPillButton('Done', () => Navigator.pop(context)),
      ],
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
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 32,
            offset: const Offset(0, -8),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildTopDragHandle(),
              _buildHeader(),
              _buildLogsDrawer(),
              _buildErrorBanner(),
              if (_currentStep == FacebookConnectStep.chooseMethod)
                _buildChooseMethodStep()
              else if (_currentStep == FacebookConnectStep.manualCookies)
                _buildManualCookiesStep()
              else if (_currentStep == FacebookConnectStep.twoFactor)
                _buildTwoFactorStep()
              else if (_currentStep == FacebookConnectStep.appApproval)
                _buildAppApprovalStep()
              else if (_currentStep == FacebookConnectStep.flowSelection)
                _buildFlowSelectionStep()
              else if (_currentStep == FacebookConnectStep.loading)
                _buildLoadingStep()
              else if (_currentStep == FacebookConnectStep.success)
                _buildSuccessStep(),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── RADAR PULSE ANIMATION WIDGET ───────────────────────────────────────────

class MessengerRadarAnimation extends StatefulWidget {
  const MessengerRadarAnimation({super.key});

  @override
  State<MessengerRadarAnimation> createState() =>
      _MessengerRadarAnimationState();
}

class _MessengerRadarAnimationState extends State<MessengerRadarAnimation>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat();
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
                    scale: 1.0 + (value * 2.2),
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: kMessengerBlue.withValues(alpha: 0.6),
                          width: 2,
                        ),
                      ),
                    ),
                  ),
                );
              },
            );
          }),
          Container(
            width: 58,
            height: 58,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [kMessengerBlue, kMessengerPurple],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: kMessengerBlue.withValues(alpha: 0.4),
                  blurRadius: 16,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: Image.asset(
              'assets/images/messenger.png',
              width: 32,
              height: 32,
              errorBuilder: (_, __, ___) => const Icon(
                Icons.chat_bubble_rounded,
                color: Colors.white,
                size: 26,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── ACCOUNT MANAGEMENT & DISCONNECT SHEET ───────────────────────────────────

class FacebookMessengerAccountManagementSheet extends StatefulWidget {
  final Client client;
  final String? accountLabel;
  final VoidCallback? onDisconnected;

  const FacebookMessengerAccountManagementSheet({
    super.key,
    required this.client,
    this.accountLabel,
    this.onDisconnected,
  });

  @override
  State<FacebookMessengerAccountManagementSheet> createState() =>
      _FacebookMessengerAccountManagementSheetState();
}

class _FacebookMessengerAccountManagementSheetState
    extends State<FacebookMessengerAccountManagementSheet> {
  bool _isDisconnecting = false;
  bool _confirming = false;
  bool _notificationsEnabled = true;

  Future<void> _handleDisconnect() async {
    setState(() => _isDisconnecting = true);
    HapticFeedback.heavyImpact();

    try {
      await FacebookMessengerDisconnectService.beginDisconnect(widget.client);
      widget.onDisconnected?.call();
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Facebook Messenger disconnected successfully.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isDisconnecting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Disconnect failed: $e'),
            backgroundColor: Colors.redAccent,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _handleSync() async {
    HapticFeedback.mediumImpact();
    await FacebookMessengerDisconnectService.forceSyncPortals(widget.client);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Syncing Messenger chats with bridge...'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.allora;
    final isConnected =
        NetworkConnectionCache.get(NetworkId.messenger).connected;
    final accountText = widget.accountLabel?.isNotEmpty == true
        ? widget.accountLabel!
        : 'Facebook User';

    return Container(
      decoration: BoxDecoration(
        color: c.canvas,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
      ),
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).padding.bottom + 16,
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
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
                'Messenger ($accountText)',
                textAlign: TextAlign.center,
                style: GoogleFonts.poppins(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: c.text,
                ),
              ),
              const SizedBox(height: 16),

              // Status Card
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: c.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: c.outline),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: isConnected
                            ? const Color(0xFF10B981)
                            : Colors.orangeAccent,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      isConnected ? 'Connected and syncing' : 'Disconnected',
                      style: GoogleFonts.poppins(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: c.text,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // Profile Card
              Container(
                decoration: BoxDecoration(
                  color: c.surface,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: c.outline),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                child: Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
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
                        width: 26,
                        height: 26,
                        errorBuilder: (_, __, ___) => const Icon(
                          Icons.chat_bubble_rounded,
                          color: Colors.white,
                          size: 22,
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Facebook Account',
                            style: GoogleFonts.poppins(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: c.textTertiary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            accountText,
                            style: GoogleFonts.poppins(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: c.text,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 18),

              // Settings & Bridge Commands Options
              Container(
                decoration: BoxDecoration(
                  color: c.surface,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: c.outline),
                ),
                child: Column(
                  children: [
                    SwitchListTile(
                      title: Text(
                        'Allow Notifications',
                        style: GoogleFonts.poppins(fontSize: 14.5, color: c.text),
                      ),
                      subtitle: Text(
                        'Notify when new Messenger chats arrive',
                        style: GoogleFonts.poppins(
                            fontSize: 12.5, color: c.textSecondary),
                      ),
                      value: _notificationsEnabled,
                      activeColor: kMessengerBlue,
                      onChanged: (v) =>
                          setState(() => _notificationsEnabled = v),
                    ),
                    Divider(height: 1, color: c.outline, indent: 16),
                    ListTile(
                      title: Text(
                        'Sync chats & portals',
                        style: GoogleFonts.poppins(fontSize: 14.5, color: c.text),
                      ),
                      subtitle: Text(
                        'Sends sync-portal to discover missing chats',
                        style: GoogleFonts.poppins(
                            fontSize: 12.5, color: c.textSecondary),
                      ),
                      trailing: const Icon(Icons.sync_rounded,
                          color: kMessengerBlue, size: 20),
                      onTap: _handleSync,
                    ),
                    Divider(height: 1, color: c.outline, indent: 16),
                    ListTile(
                      title: Text(
                        'Bridge Management Console',
                        style: GoogleFonts.poppins(fontSize: 14.5, color: c.text),
                      ),
                      subtitle: Text(
                        'Run commands (list-logins, ping, search, mute, etc.)',
                        style: GoogleFonts.poppins(
                            fontSize: 12.5, color: c.textSecondary),
                      ),
                      trailing: const Icon(Icons.terminal_rounded,
                          color: kMessengerBlue, size: 20),
                      onTap: () {
                        Navigator.pop(context);
                        showFacebookMessengerCommandsSheet(
                          context: context,
                          client: widget.client,
                        );
                      },
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 24),

              // Danger Zone: Disconnect
              if (_confirming)
                Column(
                  children: [
                    Text(
                      'Disconnect Facebook Messenger?',
                      style: GoogleFonts.poppins(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: c.danger,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'This will send logout to the bridge and clear your synced conversations from this device.',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.poppins(
                        fontSize: 12.5,
                        color: c.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () =>
                                setState(() => _confirming = false),
                            style: OutlinedButton.styleFrom(
                              side: BorderSide(color: c.outline),
                              minimumSize: const Size(0, 46),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                            child: Text(
                              'Cancel',
                              style: GoogleFonts.poppins(
                                  color: c.text, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton(
                            onPressed: _isDisconnecting ? null : _handleDisconnect,
                            style: FilledButton.styleFrom(
                              backgroundColor: c.danger,
                              minimumSize: const Size(0, 46),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                            child: _isDisconnecting
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      valueColor:
                                          AlwaysStoppedAnimation(Colors.white),
                                    ),
                                  )
                                : Text(
                                    'Disconnect',
                                    style: GoogleFonts.poppins(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ],
                )
              else
                SizedBox(
                  height: 48,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFDC2626),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    onPressed: () => setState(() => _confirming = true),
                    child: Text(
                      'Remove Account',
                      style: GoogleFonts.poppins(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
