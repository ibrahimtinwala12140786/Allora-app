import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';
import 'package:pattern_lock/pattern_lock.dart';

import '../../core/theme/app_theme.dart';
import '../../data/services/floating_chat_service.dart';
import '../../data/settings/app_settings.dart';
import '../../providers/network_provider.dart';

/// Android FLAG_SECURE bridge: blocks screenshots and hides the app's
/// content in the recent-apps switcher. No-ops silently on platforms
/// without the channel.
class SecureScreenService {
  SecureScreenService._();

  static const _channel = MethodChannel('app.allorachat.messenger/secure');

  static Future<void> setSecure(bool secure) async {
    try {
      await _channel.invokeMethod('setSecure', {'secure': secure});
    } catch (_) {
      // Channel missing (iOS/desktop/web) — nothing to do.
    }
  }
}

/// Wraps the authenticated app. Shows the PIN screen at startup when app
/// lock is enabled, re-locks after the configured background timeout, and
/// keeps FLAG_SECURE in sync with settings.
class LockGate extends ConsumerStatefulWidget {
  static bool isAuthenticating = false;

  final Widget child;
  const LockGate({super.key, required this.child});

  @override
  ConsumerState<LockGate> createState() => _LockGateState();
}

class _LockGateState extends ConsumerState<LockGate>
    with WidgetsBindingObserver {
  DateTime? _backgroundedAt;
  bool _secureApplied = false;
  bool _localAuthTriggered = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _applySecure(ref.read(settingsProvider).effectiveBlockScreenshots);
      _checkSystemLock();
    });
  }

  void _checkSystemLock() {
    final settings = ref.read(settingsProvider);
    final isLocked = ref.read(appLockedProvider);
    
    // If it's a system lock and the app is locked, trigger authentication.
    if (isLocked && settings.appLockType == AppLockType.system && !_localAuthTriggered) {
      _localAuthTriggered = true;
      _triggerSystemBiometric();
    }
  }

  Future<void> _triggerSystemBiometric() async {
    try {
      LockGate.isAuthenticating = true;
      final ok = await LocalAuthentication().authenticate(
        localizedReason: 'Unlock Allora',
        persistAcrossBackgrounding: true,
      );
      if (ok && mounted) {
        ref.read(appLockedProvider.notifier).state = false;
      }
    } catch (_) {
    } finally {
      LockGate.isAuthenticating = false;
      _localAuthTriggered = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _applySecure(bool secure) {
    if (secure == _secureApplied) return;
    _secureApplied = secure;
    SecureScreenService.setSecure(secure);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final settings = ref.read(settingsProvider);

    // Floating chat bubble
    if (settings.floatingChatEnabled) {
      if (state == AppLifecycleState.paused) {
        FloatingChatService.show(unread: _totalUnread());
      } else if (state == AppLifecycleState.resumed) {
        FloatingChatService.hide();
      }
    }

    if (!settings.appLockEnabled || LockGate.isAuthenticating) return;

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _backgroundedAt ??= DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final away = _backgroundedAt;
      _backgroundedAt = null;
      if (away == null) return;
      final elapsed = DateTime.now().difference(away);
      if (elapsed.inSeconds >= settings.autoLockMinutes * 60) {
        ref.read(appLockedProvider.notifier).state = true;
        _checkSystemLock();
      }
    }
  }

  int _totalUnread() {
    try {
      final client = ref.read(matrixClientProvider);
      var total = 0;
      for (final room in client.rooms) {
        total += room.notificationCount;
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final locked = ref.watch(appLockedProvider);
    final settings = ref.watch(settingsProvider);
    _applySecure(settings.effectiveBlockScreenshots);

    return Stack(
      children: [
        widget.child,
        if (locked && settings.appLockEnabled && settings.appLockType != AppLockType.system && settings.pinHash != null)
          AppLockScreen(
            title: 'Allora is locked',
            type: settings.appLockType,
            biometricAllowed: settings.biometricEnabled,
            onVerify: (pin) =>
                ref.read(settingsProvider.notifier).verifyPin(pin),
            onUnlocked: () =>
                ref.read(appLockedProvider.notifier).state = false,
          ),
        if (locked && settings.appLockEnabled && settings.appLockType == AppLockType.system)
          _SystemLockScreen(
            onRetry: _triggerSystemBiometric,
          ),
      ],
    );
  }
}

class _SystemLockScreen extends StatelessWidget {
  final VoidCallback onRetry;
  const _SystemLockScreen({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final c = context.allora;
    return Material(
      color: c.canvas,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.lock_rounded, size: 64, color: c.accent),
            const SizedBox(height: 16),
            Text('App Locked', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: c.text)),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.fingerprint_rounded),
              label: const Text('Unlock with System'),
            )
          ],
        ),
      ),
    );
  }
}


/// Full-screen App Lock, supporting Numeric, Alphabet, and Pattern, with optional biometric shortcut.
class AppLockScreen extends StatefulWidget {
  final String title;
  final AppLockType type;
  final bool biometricAllowed;
  final bool Function(String pin) onVerify;
  final VoidCallback onUnlocked;

  const AppLockScreen({
    super.key,
    required this.title,
    required this.type,
    required this.onVerify,
    required this.onUnlocked,
    this.biometricAllowed = false,
  });

  @override
  State<AppLockScreen> createState() => _AppLockScreenState();
}

class _AppLockScreenState extends State<AppLockScreen> {
  String _entry = '';
  bool _wrong = false;
  bool _biometricAvailable = false;
  final _alphabetController = TextEditingController();

  @override
  void initState() {
    super.initState();
    if (widget.biometricAllowed) _initBiometric();
  }

  @override
  void dispose() {
    _alphabetController.dispose();
    super.dispose();
  }

  Future<void> _initBiometric() async {
    try {
      final auth = LocalAuthentication();
      final supported = await auth.isDeviceSupported();
      final can = await auth.canCheckBiometrics;
      if (!mounted) return;
      setState(() => _biometricAvailable = supported && can);
      if (_biometricAvailable) unawaited(_tryBiometric());
    } catch (_) {}
  }

  Future<void> _tryBiometric() async {
    try {
      LockGate.isAuthenticating = true;
      final ok = await LocalAuthentication().authenticate(
        localizedReason: 'Verify identity to continue',
        persistAcrossBackgrounding: true,
      );
      if (ok && mounted) widget.onUnlocked();
    } catch (_) {
    } finally {
      LockGate.isAuthenticating = false;
    }
  }

  void _verify(String attempt) {
    if (widget.onVerify(attempt)) {
      HapticFeedback.lightImpact();
      widget.onUnlocked();
    } else {
      HapticFeedback.heavyImpact();
      setState(() {
        _wrong = true;
        _entry = '';
        _alphabetController.clear();
      });
    }
  }

  void _tapDigit(String digit) {
    if (_entry.length >= 6) return;
    HapticFeedback.selectionClick();
    setState(() {
      _entry += digit;
      _wrong = false;
    });
    if (_entry.length >= 4) {
      if (widget.onVerify(_entry)) {
        HapticFeedback.lightImpact();
        widget.onUnlocked();
      } else if (_entry.length == 6) {
        HapticFeedback.heavyImpact();
        setState(() {
          _wrong = true;
          _entry = '';
        });
      }
    }
  }

  void _backspaceDigit() {
    if (_entry.isEmpty) return;
    setState(() => _entry = _entry.substring(0, _entry.length - 1));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.allora;
    return Material(
      color: c.canvas,
      child: SafeArea(
        child: Column(
          children: [
            const Spacer(),
            Container(
              width: 68,
              height: 68,
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: [c.accent, c.bubbleMineDeep]),
                shape: BoxShape.circle,
              ),
              child:
                  const Icon(Icons.lock_rounded, color: Colors.white, size: 30),
            ),
            const SizedBox(height: 20),
            Text(widget.title,
                style: TextStyle(
                    fontSize: 19, fontWeight: FontWeight.w800, color: c.text)),
            const SizedBox(height: 6),
            Text(
              _wrong ? 'Wrong password — try again' : 'Enter your password',
              style: TextStyle(
                  fontSize: 13.5,
                  color: _wrong ? c.danger : c.textSecondary),
            ),
            const SizedBox(height: 22),
            if (widget.type == AppLockType.numeric) ...[
              _dots(),
              const Spacer(),
              _pad(),
            ] else if (widget.type == AppLockType.pattern) ...[
              const Spacer(),
              _patternPad(),
            ] else if (widget.type == AppLockType.alphabet) ...[
              _alphabetPad(),
              const Spacer(),
            ],
            if (widget.biometricAllowed && widget.type != AppLockType.numeric && _biometricAvailable)
              Padding(
                padding: const EdgeInsets.all(24.0),
                child: IconButton(
                  icon: Icon(Icons.fingerprint_rounded, size: 42, color: c.accent),
                  onPressed: _tryBiometric,
                ),
              ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _patternPad() {
    return SizedBox(
      height: 320,
      width: 320,
      child: PatternLock(
        selectedColor: context.allora.accent,
        pointRadius: 8,
        showInput: false,
        dimension: 3,
        relativePadding: 0.7,
        selectThreshold: 25,
        fillPoints: true,
        onInputComplete: (List<int> input) {
          _verify(input.join(','));
        },
      ),
    );
  }

  Widget _alphabetPad() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32.0, vertical: 24),
      child: Column(
        children: [
          TextField(
            controller: _alphabetController,
            obscureText: true,
            decoration: InputDecoration(
              hintText: 'Password',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onSubmitted: _verify,
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: () => _verify(_alphabetController.text),
            child: const Text('Unlock'),
          )
        ],
      ),
    );
  }

  Widget _dots() {
    final c = context.allora;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(6, (i) {
        final filled = i < _entry.length;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: filled ? 14 : 11,
          height: filled ? 14 : 11,
          margin: const EdgeInsets.symmetric(horizontal: 7),
          decoration: BoxDecoration(
            color: filled ? c.accent : c.surfaceAlt,
            shape: BoxShape.circle,
            border: Border.all(color: filled ? c.accent : c.outline),
          ),
        );
      }),
    );
  }

  Widget _pad() {
    final keys = [
      '1', '2', '3',
      '4', '5', '6',
      '7', '8', '9',
      _biometricAvailable ? 'bio' : '', '0', 'back',
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 44),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: 14,
          crossAxisSpacing: 26,
          childAspectRatio: 1.35,
        ),
        itemCount: keys.length,
        itemBuilder: (context, i) => _key(keys[i]),
      ),
    );
  }

  Widget _key(String value) {
    final c = context.allora;
    if (value.isEmpty) return const SizedBox.shrink();
    final isBio = value == 'bio';
    final isBack = value == 'back';
    return InkWell(
      customBorder: const CircleBorder(),
      onTap: () {
        if (isBio) {
          _tryBiometric();
        } else if (isBack) {
          _backspaceDigit();
        } else {
          _tapDigit(value);
        }
      },
      child: Container(
        decoration: BoxDecoration(
          color: isBio || isBack ? Colors.transparent : c.surface,
          shape: BoxShape.circle,
          border: isBio || isBack ? null : Border.all(color: c.outline),
        ),
        alignment: Alignment.center,
        child: isBio
            ? Icon(Icons.fingerprint_rounded, size: 26, color: c.accent)
            : isBack
                ? Icon(Icons.backspace_outlined,
                    size: 22, color: c.textSecondary)
                : Text(value,
                    style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w600,
                        color: c.text)),
      ),
    );
  }
}

/// Setup screen for Numeric, Pattern, and Alphabet.
class AppLockSetupScreen extends ConsumerStatefulWidget {
  final AppLockType type;
  const AppLockSetupScreen({super.key, required this.type});

  @override
  ConsumerState<AppLockSetupScreen> createState() => _AppLockSetupScreenState();
}

class _AppLockSetupScreenState extends ConsumerState<AppLockSetupScreen> {
  String _first = '';
  String _entry = '';
  bool _confirming = false;
  bool _mismatch = false;
  final _alphabetController = TextEditingController();

  @override
  void dispose() {
    _alphabetController.dispose();
    super.dispose();
  }

  void _tapDigit(String d) {
    if (_entry.length >= 6) return;
    HapticFeedback.selectionClick();
    setState(() {
      _entry += d;
      _mismatch = false;
    });
    if (_entry.length == 6) _advance();
  }

  void _advance([String? input]) {
    final currentInput = input ?? _entry;
    
    if (!_confirming) {
      if (currentInput.isEmpty) return;
      setState(() {
        _first = currentInput;
        _entry = '';
        _alphabetController.clear();
        _confirming = true;
      });
    } else if (currentInput == _first) {
      ref.read(settingsProvider.notifier).setAppLockType(widget.type);
      ref.read(settingsProvider.notifier).setPin(currentInput);
      HapticFeedback.lightImpact();
      Navigator.pop(context, true);
    } else {
      HapticFeedback.heavyImpact();
      setState(() {
        _mismatch = true;
        _entry = '';
        _first = '';
        _alphabetController.clear();
        _confirming = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.allora;
    return Scaffold(
      backgroundColor: c.canvas,
      appBar: AppBar(title: const Text('Set Password')),
      body: SafeArea(
        child: Column(
          children: [
            const Spacer(),
            Icon(Icons.pin_rounded, size: 44, color: c.accent),
            const SizedBox(height: 18),
            Text(
              _confirming ? 'Confirm your password' : 'Choose a password',
              style: TextStyle(
                  fontSize: 18, fontWeight: FontWeight.w700, color: c.text),
            ),
            const SizedBox(height: 6),
            Text(
              _mismatch
                  ? 'Passwords didn\u2019t match — start over'
                  : 'You\u2019ll use this to unlock Allora',
              style: TextStyle(
                  fontSize: 13,
                  color: _mismatch ? c.danger : c.textSecondary),
            ),
            const SizedBox(height: 22),
            
            if (widget.type == AppLockType.numeric) ...[
              _dots(),
              const Spacer(),
              _pad(),
            ] else if (widget.type == AppLockType.pattern) ...[
              const Spacer(),
              _patternPad(),
            ] else if (widget.type == AppLockType.alphabet) ...[
              _alphabetPad(),
              const Spacer(),
            ],
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _patternPad() {
    return SizedBox(
      height: 320,
      width: 320,
      child: PatternLock(
        selectedColor: context.allora.accent,
        pointRadius: 8,
        showInput: false,
        dimension: 3,
        relativePadding: 0.7,
        selectThreshold: 25,
        fillPoints: true,
        onInputComplete: (List<int> input) {
          _advance(input.join(','));
        },
      ),
    );
  }

  Widget _alphabetPad() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32.0, vertical: 24),
      child: Column(
        children: [
          TextField(
            controller: _alphabetController,
            obscureText: true,
            decoration: InputDecoration(
              hintText: 'Password',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onSubmitted: _advance,
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: () => _advance(_alphabetController.text),
            child: const Text('Next'),
          )
        ],
      ),
    );
  }

  Widget _dots() {
    final c = context.allora;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(6, (i) {
        final filled = i < _entry.length;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: filled ? 14 : 11,
          height: filled ? 14 : 11,
          margin: const EdgeInsets.symmetric(horizontal: 7),
          decoration: BoxDecoration(
            color: filled ? c.accent : c.surfaceAlt,
            shape: BoxShape.circle,
            border: Border.all(color: filled ? c.accent : c.outline),
          ),
        );
      }),
    );
  }

  Widget _pad() {
    final c = context.allora;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 44),
      child: GridView.count(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        crossAxisCount: 3,
        mainAxisSpacing: 14,
        crossAxisSpacing: 26,
        childAspectRatio: 1.35,
        children: [
          for (final k in [
            '1', '2', '3', '4', '5', '6', '7', '8', '9', '', '0', 'back',
          ])
            k.isEmpty
                ? const SizedBox.shrink()
                : InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () {
                      if (k == 'back') {
                        if (_entry.isNotEmpty) {
                          setState(() => _entry = _entry.substring(
                              0, _entry.length - 1));
                        }
                      } else {
                        _tapDigit(k);
                      }
                    },
                    child: Container(
                      decoration: BoxDecoration(
                        color: k == 'back'
                            ? Colors.transparent
                            : c.surface,
                        shape: BoxShape.circle,
                        border: k == 'back'
                            ? null
                            : Border.all(color: c.outline),
                      ),
                      alignment: Alignment.center,
                      child: k == 'back'
                          ? Icon(Icons.backspace_outlined,
                              size: 22, color: c.textSecondary)
                          : Text(k,
                              style: TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.w600,
                                  color: c.text)),
                    ),
                  ),
        ],
      ),
    );
  }
}
