import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../data/settings/app_settings.dart';
import '../privacy/app_lock.dart';

class SecuritySettingsScreen extends ConsumerWidget {
  const SecuritySettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.allora;
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);

    return Scaffold(
      backgroundColor: c.canvas,
      appBar: AppBar(title: const Text('Security')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: c.outline),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                SwitchListTile(
                  secondary: Icon(Icons.lock_rounded, color: c.accent),
                  title: const Text('App lock'),
                  subtitle: const Text('Require authentication to open Allora'),
                  value: settings.appLockEnabled,
                  onChanged: (v) async {
                    if (v) {
                      _pickLockType(context, ref);
                    } else {
                      notifier.disableAppLock();
                    }
                  },
                ),
                if (settings.appLockEnabled) ...[
                  Divider(color: c.outline, height: 1),
                  ListTile(
                    leading: Icon(Icons.security_rounded, color: c.textSecondary),
                    title: const Text('Lock Type'),
                    subtitle: Text(_lockTypeLabel(settings.appLockType)),
                    trailing:
                        Icon(Icons.chevron_right_rounded, color: c.textTertiary),
                    onTap: () => _pickLockType(context, ref),
                  ),
                  if (settings.appLockType != AppLockType.system) ...[
                    Divider(color: c.outline, height: 1),
                    SwitchListTile(
                      secondary:
                          Icon(Icons.fingerprint_rounded, color: c.textSecondary),
                      title: const Text('Unlock with biometrics'),
                      subtitle: const Text('Fingerprint or face unlock'),
                      value: settings.biometricEnabled,
                      onChanged: notifier.setBiometric,
                    ),
                    Divider(color: c.outline, height: 1),
                    ListTile(
                      leading: Icon(Icons.password_rounded, color: c.textSecondary),
                      title: const Text('Change Password'),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => AppLockSetupScreen(type: settings.appLockType),
                        ),
                      ),
                    ),
                  ],
                  Divider(color: c.outline, height: 1),
                  ListTile(
                    leading: Icon(Icons.timer_rounded, color: c.textSecondary),
                    title: const Text('Auto-lock'),
                    subtitle: Text(_autoLockLabel(settings.autoLockMinutes)),
                    trailing:
                        Icon(Icons.chevron_right_rounded, color: c.textTertiary),
                    onTap: () => _pickAutoLock(context, ref),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              'Your lock credentials are stored securely on this device. '
              'If you forget your custom password, you can uninstall and reinstall the app, but you may lose local data.',
              style: TextStyle(
                  fontSize: 12.5, color: c.textTertiary, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }

  static String _lockTypeLabel(AppLockType type) {
    switch (type) {
      case AppLockType.system:
        return 'System Security (Device PIN/Fingerprint)';
      case AppLockType.numeric:
        return 'Numeric PIN';
      case AppLockType.alphabet:
        return 'Alphabet Password';
      case AppLockType.pattern:
        return 'Pattern Lock';
    }
  }

  void _pickLockType(BuildContext context, WidgetRef ref) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16.0),
              child: Text('Choose Lock Type', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
            for (final type in AppLockType.values)
              ListTile(
                title: Text(_lockTypeLabel(type)),
                onTap: () async {
                  Navigator.pop(ctx);
                  if (type == AppLockType.system) {
                    ref.read(settingsProvider.notifier).setAppLockType(AppLockType.system);
                    ref.read(settingsProvider.notifier).setPin('system_lock_placeholder');
                  } else {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => AppLockSetupScreen(type: type)),
                    );
                  }
                },
              ),
          ],
        ),
      ),
    );
  }

  static String _autoLockLabel(int minutes) {
    if (minutes <= 0) return 'Immediately';
    if (minutes == 1) return 'After 1 minute';
    if (minutes < 60) return 'After $minutes minutes';
    return 'After 1 hour';
  }

  void _pickAutoLock(BuildContext context, WidgetRef ref) {
    final current = ref.read(settingsProvider).autoLockMinutes;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final m in [0, 1, 5, 15, 60])
              RadioListTile<int>(
                value: m,
                groupValue: current,
                title: Text(_autoLockLabel(m)),
                onChanged: (v) {
                  Navigator.pop(ctx);
                  if (v != null) {
                    ref.read(settingsProvider.notifier).setAutoLockMinutes(v);
                  }
                },
              ),
          ],
        ),
      ),
    );
  }
}
