import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/config/env_config.dart';
import '../../core/theme/app_theme.dart';
import '../../features/home_gate.dart';
import '../../features/privacy/app_lock.dart';
import 'email_screen.dart';
import 'signup_screen.dart';

class WelcomeScreen extends StatefulWidget {
  final Client client;
  const WelcomeScreen({super.key, required this.client});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  bool _isGoogleSignInInitialized = false;
  bool _googleLoading = false;
  bool _isSyncingMatrix = false;
  StreamSubscription<AuthState>? _authSubscription;

  @override
  void initState() {
    super.initState();
    _authSubscription =
        Supabase.instance.client.auth.onAuthStateChange.listen((data) async {
      if (data.event == AuthChangeEvent.signedIn && data.session != null) {
        if (!widget.client.isLogged() && !_isSyncingMatrix) {
          final ok = await _syncMatrixAccount(data.session!.user.id);
          if (mounted) {
            if (ok && widget.client.isLogged()) {
              Navigator.pushAndRemoveUntil(
                context,
                PageRouteBuilder(
                  pageBuilder: (_, __, ___) =>
                      const LockGate(child: HomeGate()),
                  transitionDuration: const Duration(milliseconds: 600),
                  transitionsBuilder: (_, animation, __, child) =>
                      FadeTransition(opacity: animation, child: child),
                ),
                (route) => false,
              );
            } else {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                    'Signed in, but unable to connect to Allora chat servers. Please check your connection.',
                  ),
                  backgroundColor: Colors.orange,
                ),
              );
            }
          }
        }
      }
    });
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    super.dispose();
  }

  Future<bool> _syncMatrixAccount(String supabaseUserId) async {
    if (_isSyncingMatrix) return false;
    if (widget.client.isLogged()) return true;
    _isSyncingMatrix = true;

    try {
      final matrixUsername = supabaseUserId.replaceAll('-', '').toLowerCase();
      final matrixPassword = 'Allora_${matrixUsername.substring(0, 15)}!';

      if (widget.client.homeserver == null) {
        await widget.client
            .checkHomeserver(Uri.parse(EnvConfig.matrixHomeserverUrl))
            .timeout(const Duration(seconds: 8));
      }

      // Step 1: Try to log in (account may already exist)
      try {
        await widget.client.login(
          LoginType.mLoginPassword,
          identifier: AuthenticationUserIdentifier(user: matrixUsername),
          password: matrixPassword,
        ).timeout(const Duration(seconds: 10));
        debugPrint('✅ Matrix login success (existing account)');
        return true;
      } catch (e) {
        debugPrint('Matrix login failed, provisioning new account: $e');
      }

      // Step 2: Provision via Supabase Edge Function (preferred)
      try {
        final res = await Supabase.instance.client.functions
            .invoke('allora-provision', body: {'password': matrixPassword})
            .timeout(const Duration(seconds: 12));
        final data = res.data;
        if (data is Map && data['ok'] == true) {
          await widget.client.login(
            LoginType.mLoginPassword,
            identifier: AuthenticationUserIdentifier(user: matrixUsername),
            password: matrixPassword,
          ).timeout(const Duration(seconds: 10));
          debugPrint('✅ Matrix provisioned and logged in via allora-provision');
          return true;
        }
      } catch (e) {
        debugPrint('allora-provision unavailable, trying legacy path: $e');
      }

      // Step 3: Legacy HMAC registration fallback
      try {
        const baseUrl = EnvConfig.matrixHomeserverUrl;
        const secret = EnvConfig.synapseAdminSecret;

        final nonceRes = await http
            .get(Uri.parse('$baseUrl/_synapse/admin/v1/register'))
            .timeout(const Duration(seconds: 8));
        if (nonceRes.statusCode != 200) throw Exception('Backend sync failed');

        final nonce = jsonDecode(nonceRes.body)['nonce'];
        final macStr =
            '$nonce\x00$matrixUsername\x00$matrixPassword\x00notadmin';
        final mac =
            Hmac(sha1, utf8.encode(secret)).convert(utf8.encode(macStr));

        final regRes = await http
            .post(
              Uri.parse('$baseUrl/_synapse/admin/v1/register'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'nonce': nonce,
                'username': matrixUsername,
                'password': matrixPassword,
                'mac': mac.toString(),
                'admin': false,
              }),
            )
            .timeout(const Duration(seconds: 10));

        if (regRes.statusCode >= 200 && regRes.statusCode < 300) {
          await widget.client.login(
            LoginType.mLoginPassword,
            identifier: AuthenticationUserIdentifier(user: matrixUsername),
            password: matrixPassword,
          ).timeout(const Duration(seconds: 10));
          debugPrint('✅ Matrix registered and logged in via legacy path');
          return true;
        } else {
          final body = jsonDecode(regRes.body);
          if (body['errcode'] == 'M_USER_IN_USE') {
            await widget.client.login(
              LoginType.mLoginPassword,
              identifier: AuthenticationUserIdentifier(user: matrixUsername),
              password: matrixPassword,
            ).timeout(const Duration(seconds: 10));
            debugPrint(
                '✅ Matrix user already existed, logged in via legacy path fallback');
            return true;
          } else {
            throw Exception(
                'Registration rejected: ${regRes.statusCode} - ${regRes.body}');
          }
        }
      } catch (e) {
        debugPrint('❌ Matrix provisioning failed entirely: $e');
        return false;
      }
    } catch (e) {
      debugPrint('❌ Matrix connection error: $e');
      return false;
    } finally {
      _isSyncingMatrix = false;
    }
  }

  Future<void> _signInWithGoogle() async {
    setState(() => _googleLoading = true);
    try {
      try {
        if (!_isGoogleSignInInitialized) {
          await GoogleSignIn.instance.initialize(
            serverClientId: EnvConfig.googleWebClientId,
            clientId: (!kIsWeb && Platform.isIOS) ? EnvConfig.googleWebClientId : null,
          );
          _isGoogleSignInInitialized = true;
        }

        final googleUser = await GoogleSignIn.instance.authenticate();
        final idToken = googleUser.authentication.idToken;

        if (idToken != null) {
          final response = await Supabase.instance.client.auth.signInWithIdToken(
            provider: OAuthProvider.google,
            idToken: idToken,
          );
          if (response.session != null && mounted) {
            final syncSuccess = await _syncMatrixAccount(response.session!.user.id);
            if (mounted) {
              setState(() => _googleLoading = false);
              if (syncSuccess && widget.client.isLogged()) {
                Navigator.pushAndRemoveUntil(
                  context,
                  PageRouteBuilder(
                    pageBuilder: (_, __, ___) => const LockGate(child: HomeGate()),
                    transitionDuration: const Duration(milliseconds: 600),
                    transitionsBuilder: (_, animation, __, child) =>
                        FadeTransition(opacity: animation, child: child),
                  ),
                  (route) => false,
                );
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Signed in with Google, but unable to reach Allora chat servers. Please check your connection or try again later.',
                    ),
                    backgroundColor: Colors.orange,
                  ),
                );
              }
            }
            return;
          }
        }
      } catch (e) {
        final errStr = e.toString().toLowerCase();
        if ((e is GoogleSignInException &&
                e.code == GoogleSignInExceptionCode.canceled) ||
            errStr.contains('cancel')) {
          debugPrint('Google sign-in was canceled by the user');
          return;
        }
        debugPrint('Native Google sign-in failed, trying OAuth fallback: $e');
      }

      // Fallback: Web OAuth flow via Supabase with proper redirect scheme
      await Supabase.instance.client.auth.signInWithOAuth(
        OAuthProvider.google,
        redirectTo: kIsWeb ? null : 'io.supabase.allorachat://login-callback',
        authScreenLaunchMode: LaunchMode.externalApplication,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Google sign-in failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _googleLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.allora;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? c.canvas : Colors.white,
      body: Column(
        children: [
          // ── Hero image ────────────────────────────────────────────────
          Expanded(
            flex: 55,
            child: Container(
              width: double.infinity,
              decoration: const BoxDecoration(
                image: DecorationImage(
                  image: AssetImage('assets/images/allora_hero.png'),
                  fit: BoxFit.cover,
                  alignment: Alignment.center,
                ),
              ),
            ),
          ),

          // ── Auth buttons ──────────────────────────────────────────────
          Expanded(
            flex: 45,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Continue with Google
                  ElevatedButton.icon(
                    onPressed: _googleLoading ? null : _signInWithGoogle,
                    icon: _googleLoading
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.blueAccent),
                          )
                        : const _GoogleLogo(size: 24),
                    label: Text(
                      _googleLoading ? 'Signing in...' : 'Continue with Google',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Colors.black87,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: Colors.grey.shade200,
                      minimumSize: const Size(double.infinity, 54),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: BorderSide(color: Colors.grey.shade300),
                      ),
                      elevation: 0,
                    ),
                  ),

                  const SizedBox(height: 16),

                  // Continue with Email
                  ElevatedButton.icon(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => EmailScreen(client: widget.client),
                      ),
                    ),
                    icon: const Icon(Icons.email_rounded, color: Colors.white),
                    label: const Text(
                      'Continue with Email',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blueAccent.shade700,
                      minimumSize: const Size(double.infinity, 54),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      elevation: 0,
                    ),
                  ),

                  const SizedBox(height: 24),

                  // Create account link
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        "Don't have an account? ",
                        style: TextStyle(color: c.textSecondary),
                      ),
                      GestureDetector(
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => SignupScreen(client: widget.client),
                          ),
                        ),
                        child: Text(
                          'Create Account',
                          style: TextStyle(
                            color: Colors.blueAccent.shade700,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 20),

                  // Legal
                  RichText(
                    textAlign: TextAlign.center,
                    text: TextSpan(
                      style: TextStyle(
                        color: c.textTertiary,
                        fontSize: 12,
                        height: 1.5,
                      ),
                      children: const [
                        TextSpan(text: 'By continuing, you agree to our '),
                        TextSpan(
                          text: 'Terms of Use',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        TextSpan(text: ' and '),
                        TextSpan(
                          text: 'Privacy Policy',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        TextSpan(text: '.'),
                      ],
                    ),
                  ),
                  const SafeArea(child: SizedBox.shrink()),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A simple custom-painted Google 'G' logo — no external package needed.
class _GoogleLogo extends StatelessWidget {
  final double size;
  const _GoogleLogo({this.size = 24});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(size, size),
      painter: _GoogleLogoPainter(),
    );
  }
}

class _GoogleLogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final double cx = size.width / 2;
    final double cy = size.height / 2;
    final double r = size.width / 2;
    final paint = Paint()..style = PaintingStyle.fill;

    // Draw colored circle sectors
    final colors = [
      const Color(0xFF4285F4), // Blue (top & right)
      const Color(0xFF34A853), // Green (bottom-right)
      const Color(0xFFFBBC05), // Yellow (bottom-left)
      const Color(0xFFEA4335), // Red (top-left)
    ];

    final angles = [-0.26, 1.31, 2.36, 4.19];
    final sweeps = [1.57, 1.05, 1.83, 1.57];

    for (int i = 0; i < 4; i++) {
      paint.color = colors[i];
      canvas.drawArc(
        Rect.fromCircle(center: Offset(cx, cy), radius: r),
        angles[i],
        sweeps[i],
        true,
        paint,
      );
    }

    // White center circle (creates the 'G' cutout illusion)
    paint.color = Colors.white;
    canvas.drawCircle(Offset(cx, cy), r * 0.60, paint);

    // Blue right bar for 'G' horizontal stroke
    paint.color = const Color(0xFF4285F4);
    canvas.drawRect(
      Rect.fromLTWH(cx, cy - r * 0.17, r * 0.95, r * 0.34),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
