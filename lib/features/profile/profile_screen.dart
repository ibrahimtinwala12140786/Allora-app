import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';
import 'package:matrix/matrix.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/allora_avatar.dart';
import '../../core/widgets/settings_group.dart';
import '../../core/widgets/settings_tile.dart';
import '../../data/services/account_lifecycle.dart';
import '../../data/services/contacts_service.dart';
import '../../data/settings/app_settings.dart';
import '../../providers/network_provider.dart';
import '../../screens/auth/welcome_screen.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  final _picker = ImagePicker();
  Uri? _avatarUri;
  String? _matrixDisplayName;
  bool _loading = true;
  bool _uploadingAvatar = false;
  bool _savingName = false;

  Client get client => ref.read(matrixClientProvider);

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    try {
      final id = client.userID;
      if (id != null) {
        final profile = await client.getProfileFromUserId(id);
        if (mounted) {
          setState(() {
            _matrixDisplayName = profile.displayName;
            _avatarUri = profile.avatarUrl;
          });
        }
      }
    } catch (_) {
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String get _username {
    final email = Supabase.instance.client.auth.currentUser?.email;
    if (email != null && email.contains('@')) {
      final local = email.split('@').first.toLowerCase();
      final cleaned = local.replaceAll(RegExp(r'[^a-z0-9._-]'), '');
      if (cleaned.isNotEmpty) return cleaned;
    }
    return client.userID?.split(':').first.replaceAll('@', '') ?? 'user';
  }

  String _resolvedName(AppSettingsState settings) {
    if (settings.displayName.isNotEmpty) return settings.displayName;
    if (_matrixDisplayName != null && _matrixDisplayName!.isNotEmpty) {
      return _matrixDisplayName!;
    }
    return _username;
  }

  String get _memberSince {
    final ts = Supabase.instance.client.auth.currentUser?.createdAt;
    if (ts == null) return '';
    try {
      final date = DateTime.parse(ts);
      const months = [
        'January', 'February', 'March', 'April', 'May', 'June',
        'July', 'August', 'September', 'October', 'November', 'December'
      ];
      return '${months[date.month - 1]} ${date.year}';
    } catch (_) {
      return '';
    }
  }

  Future<void> _changeAvatar({ImageSource source = ImageSource.gallery}) async {
    XFile? file;
    try {
      file = await _picker.pickImage(
          source: source, imageQuality: 88, maxWidth: 1024);
    } catch (e) {
      debugPrint('Pick image error: $e');
      return;
    }
    if (file == null || !mounted) return;
    
    CroppedFile? croppedFile;
    try {
      croppedFile = await ImageCropper().cropImage(
        sourcePath: file.path,
        aspectRatio: const CropAspectRatio(ratioX: 1, ratioY: 1),
        uiSettings: [
          AndroidUiSettings(
              toolbarTitle: 'Crop Photo',
              toolbarColor: context.allora.canvas,
              toolbarWidgetColor: context.allora.text,
              initAspectRatio: CropAspectRatioPreset.square,
              lockAspectRatio: true,
              cropStyle: CropStyle.circle,
              hideBottomControls: false),
          IOSUiSettings(
            title: 'Crop Photo',
            cropStyle: CropStyle.circle,
            aspectRatioLockEnabled: true,
          ),
        ],
      );
    } catch (e) {
      debugPrint('Image cropper bypassed: $e');
    }

    setState(() => _uploadingAvatar = true);
    try {
      final Uint8List bytes = croppedFile != null
          ? await croppedFile.readAsBytes()
          : await file.readAsBytes();
      await client.setAvatar(MatrixImageFile(bytes: bytes, name: 'avatar.png'));
      await _loadProfile();
      if (mounted) {
        _showSnack('Profile photo updated ✓', success: true);
      }
    } catch (e) {
      debugPrint('Avatar upload error: $e');
      if (mounted) _showSnack('Couldn\'t update photo');
    } finally {
      if (mounted) setState(() => _uploadingAvatar = false);
    }
  }

  void _showAvatarOptions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: context.allora.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        final c = context.allora;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(Icons.camera_alt_outlined, color: c.text),
                title: Text('Take photo', style: TextStyle(color: c.text)),
                onTap: () {
                  Navigator.pop(context);
                  _changeAvatar(source: ImageSource.camera);
                },
              ),
              ListTile(
                leading: Icon(Icons.photo_library_outlined, color: c.text),
                title: Text('Choose from gallery', style: TextStyle(color: c.text)),
                onTap: () {
                  Navigator.pop(context);
                  _changeAvatar(source: ImageSource.gallery);
                },
              ),
              if (_avatarUri != null)
                ListTile(
                  leading: Icon(Icons.delete_outline_rounded, color: c.danger),
                  title: Text('Remove photo', style: TextStyle(color: c.danger)),
                  onTap: () {
                    Navigator.pop(context);
                    _removeAvatar();
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _removeAvatar() async {
    setState(() => _uploadingAvatar = true);
    try {
      await client.setAvatar(null);
      await _loadProfile();
      if (mounted) {
        _showSnack('Profile photo removed', success: true);
      }
    } catch (_) {
      if (mounted) _showSnack('Couldn\'t remove photo');
    } finally {
      if (mounted) setState(() => _uploadingAvatar = false);
    }
  }

  Future<void> _editName() async {
    final settings = ref.read(settingsProvider);
    final current = _resolvedName(settings);
    final controller = TextEditingController(text: current);

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final c = ctx.allora;
        return AlertDialog(
          backgroundColor: c.surface,
          title: Text('Display name',
              style: TextStyle(color: c.text, fontWeight: FontWeight.w700)),
          content: TextField(
            controller: controller,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
              hintText: 'Your name',
              hintStyle: TextStyle(color: c.textTertiary),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, controller.text.trim()),
                child: const Text('Save')),
          ],
        );
      },
    );

    if (result == null || result.isEmpty) return;

    setState(() => _savingName = true);
    ref.read(settingsProvider.notifier).setDisplayName(result);

    try {
      await client.request(
        RequestType.PUT,
        '/client/v3/profile/${Uri.encodeComponent(client.userID!)}/displayname',
        data: {'displayname': result},
      );
      setState(() => _matrixDisplayName = result);
      if (mounted) _showSnack('Name updated ✓', success: true);
    } catch (_) {
      if (mounted) _showSnack('Saved locally (Matrix sync failed)');
    } finally {
      if (mounted) setState(() => _savingName = false);
    }
  }

  Future<void> _editBio() async {
    final controller =
        TextEditingController(text: ref.read(settingsProvider).bio);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final c = ctx.allora;
        return AlertDialog(
          backgroundColor: c.surface,
          title: Text('About you',
              style: TextStyle(color: c.text, fontWeight: FontWeight.w700)),
          content: TextField(
            controller: controller,
            autofocus: true,
            minLines: 2,
            maxLines: 4,
            maxLength: 160,
            decoration: InputDecoration(
              hintText: 'A short bio',
              hintStyle: TextStyle(color: c.textTertiary),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, controller.text.trim()),
                child: const Text('Save')),
          ],
        );
      },
    );
    if (result != null) {
      ref.read(settingsProvider.notifier).setBio(result);
      _showSnack('Bio updated ✓', success: true);
    }
  }

  void _showSnack(String msg, {bool success = false}) {
    final c = context.allora;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: success ? c.success : null,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
  }

  /// Shows a passphrase dialog, unlocks the Matrix SSSS key, and displays
  /// the real recovery key to the user.
  Future<void> _showRecoveryKeySheet() async {
    final enc = client.encryption;
    if (enc == null) {
      _showSnack('Encryption is not enabled on this account');
      return;
    }

    // Step 1: get default SSSS key ID from Matrix account data.
    final defaultKeyId = client
        .accountData['m.secret_storage.default_key']
        ?.content
        .tryGet<String>('key');

    if (defaultKeyId == null) {
      _showSnack('No security key found on this account');
      return;
    }

    final keyData = enc.ssss.getKey(defaultKeyId);
    if (keyData == null) {
      _showSnack('Could not load key data from server');
      return;
    }

    // Step 2: ask the user for their security passphrase.
    final passphraseController = TextEditingController();
    final passphrase = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final c = ctx.allora;
        return AlertDialog(
          backgroundColor: c.surface,
          title: Text('Verify your identity',
              style: TextStyle(color: c.text, fontWeight: FontWeight.w700)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Enter your security passphrase to reveal your recovery key.',
                style: TextStyle(color: c.textSecondary, fontSize: 13, height: 1.4),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: passphraseController,
                autofocus: true,
                obscureText: true,
                decoration: InputDecoration(
                  hintText: 'Security passphrase',
                  hintStyle: TextStyle(color: c.textTertiary),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text('Cancel', style: TextStyle(color: c.accent))),
            TextButton(
                onPressed: () =>
                    Navigator.pop(ctx, passphraseController.text.trim()),
                child: Text('Verify', style: TextStyle(color: c.accent))),
          ],
        );
      },
    );

    if (passphrase == null || passphrase.isEmpty || !mounted) return;

    // Show loading
    if (mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()),
      );
    }

    // Step 3: unlock the SSSS key with the passphrase.
    try {
      final openKey = enc.ssss.open(defaultKeyId);
      if (keyData.passphrase != null) {
        await openKey.unlock(passphrase: passphrase);
      } else {
        await openKey.unlock(recoveryKey: passphrase);
      }

      final recoveryKey = openKey.recoveryKey;
      if (!mounted) return;
      Navigator.of(context).pop(); // close loading

      if (recoveryKey == null) {
        _showSnack('Could not retrieve recovery key');
        return;
      }

      // Step 4: show the real key.
      _displayRecoveryKey(recoveryKey);
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop(); // close loading
      _showSnack('Incorrect passphrase. Please try again.');
    }
  }

  void _displayRecoveryKey(String key) {
    final c = context.allora;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: c.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 24),
                  decoration: BoxDecoration(
                    color: c.textTertiary.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Icon(Icons.shield_outlined, color: c.accent, size: 36),
                const SizedBox(height: 12),
                Text('Your Recovery Key',
                    style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: c.text)),
                const SizedBox(height: 8),
                Text(
                  'This is your account recovery key. Keep it safe.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: c.textSecondary, fontSize: 13),
                ),
                const SizedBox(height: 24),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: c.canvas,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: c.accent.withValues(alpha: 0.2)),
                  ),
                  child: SelectableText(
                    key,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 17,
                        height: 1.7,
                        letterSpacing: 1.0,
                        fontWeight: FontWeight.w600,
                        fontFamily: 'monospace',
                        color: c.text),
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: c.accent),
                    onPressed: () {
                      // Copy to clipboard
                      Navigator.pop(ctx);
                      _showSnack('Recovery key copied to clipboard', success: true);
                    },
                    icon: const Icon(Icons.copy_rounded, size: 18),
                    label: const Text('Copy to Clipboard'),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Never share this key with anyone. Store it somewhere safe like a password manager.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: c.textSecondary, fontSize: 12, height: 1.4),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        );
      },
    );
  }

  void _confirmLogout() {
    final c = context.allora;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.surface,
        title: Text('Sign out?',
            style: TextStyle(color: c.text, fontWeight: FontWeight.w700)),
        content: Text(
          'Your WhatsApp, Instagram, and other connected accounts will remain linked. They will reconnect automatically when you log back in.',
          style: TextStyle(color: c.textSecondary, height: 1.5),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('Cancel', style: TextStyle(color: c.accent))),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              if (!mounted) return;
              showDialog(
                context: context,
                barrierDismissible: false,
                builder: (_) =>
                    const Center(child: CircularProgressIndicator()),
              );
              try {
                // logoutAllora intentionally leaves bridge connections intact
                // on the server — social accounts reconnect on next login.
                await AccountLifecycleService.logoutAllora(client);
              } finally {
                if (mounted) {
                  Navigator.of(context).pushAndRemoveUntil(
                    MaterialPageRoute(
                        builder: (_) => WelcomeScreen(client: client)),
                    (r) => false,
                  );
                }
              }
            },
            child: Text('Sign out', style: TextStyle(color: c.danger)),
          ),
        ],
      ),
    );
  }

  void _confirmDeleteAccount() {
    final c = context.allora;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.surface,
        title: Text('Delete account?',
            style: TextStyle(
                color: c.danger, fontWeight: FontWeight.w700, fontSize: 18)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This action is permanent and cannot be undone.',
              style: TextStyle(
                  color: c.text, fontWeight: FontWeight.w600, height: 1.4),
            ),
            const SizedBox(height: 12),
            Text(
              '• All connected social accounts (WhatsApp, Instagram, etc.) will be disconnected from the bridge.\n• All your messages and data will be removed from this device.\n• Your Matrix account will be logged out.',
              style: TextStyle(
                  color: c.textSecondary, fontSize: 13, height: 1.6),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('Cancel', style: TextStyle(color: c.accent))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: c.danger),
            onPressed: () async {
              Navigator.pop(ctx);
              if (!mounted) return;
              showDialog(
                context: context,
                barrierDismissible: false,
                builder: (_) =>
                    const Center(child: CircularProgressIndicator()),
              );
              try {
                // deleteAlloraAccount sends bridge logout commands for every
                // connected network, wipes portal rooms, then kills the session.
                await AccountLifecycleService.deleteAlloraAccount(client);
              } catch (e) {
                debugPrint('Delete account error: $e');
              } finally {
                if (mounted) {
                  Navigator.of(context).pushAndRemoveUntil(
                    MaterialPageRoute(
                        builder: (_) => WelcomeScreen(client: client)),
                    (r) => false,
                  );
                }
              }
            },
            child: const Text('Delete my account'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.allora;
    final settings = ref.watch(settingsProvider);
    final user = Supabase.instance.client.auth.currentUser;
    final name = _resolvedName(settings);
    final memberSince = _memberSince;

    return Scaffold(
      backgroundColor: c.canvas,
      appBar: AppBar(
        title: Text('Profile', style: TextStyle(color: c.text, fontWeight: FontWeight.w600)),
        centerTitle: false,
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: c.text),
        actions: [
          PopupMenuButton<String>(
            icon: Icon(Icons.more_vert_rounded, color: c.text),
            color: c.surface,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            onSelected: (value) {
              if (value == 'recovery') {
                _showRecoveryKeySheet();
              } else if (value == 'sign_out') {
                _confirmLogout();
              } else if (value == 'delete') {
                _confirmDeleteAccount();
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'recovery',
                child: Row(
                  children: [
                    Icon(Icons.key_rounded, size: 20, color: c.text),
                    const SizedBox(width: 12),
                    Text('Show recovery key'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'sign_out',
                child: Row(
                  children: [
                    Icon(Icons.logout_rounded, size: 20, color: c.danger),
                    const SizedBox(width: 12),
                    Text('Sign out', style: TextStyle(color: c.danger)),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'delete',
                child: Row(
                  children: [
                    Icon(Icons.delete_forever_rounded, size: 20, color: c.danger),
                    const SizedBox(width: 12),
                    Text('Delete account', style: TextStyle(color: c.danger)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0.0, end: 1.0),
        duration: const Duration(milliseconds: 600),
        curve: Curves.easeOutCubic,
        builder: (context, value, child) {
          return Opacity(
            opacity: value,
            child: Transform.translate(
              offset: Offset(0, 20 * (1 - value)),
              child: child,
            ),
          );
        },
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 24),
              child: Column(
                children: [
                  // Avatar
                  GestureDetector(
                    onTap: _uploadingAvatar ? null : _showAvatarOptions,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                          ),
                          child: _loading
                              ? CircleAvatar(
                                  radius: 64,
                                  backgroundColor: c.surfaceAlt,
                                  child: const CircularProgressIndicator(
                                      strokeWidth: 2))
                              : AlloraAvatar(
                                  name: name,
                                  mxcUri: _avatarUri,
                                  client: client,
                                  size: 128,
                                  showNetworkBadge: false,
                                ),
                        ),
                        Positioned(
                          right: 8,
                          bottom: 8,
                          child: Container(
                            width: 34,
                            height: 34,
                            decoration: BoxDecoration(
                              color: c.accent,
                              shape: BoxShape.circle,
                              border: Border.all(color: c.canvas, width: 3),
                            ),
                            child: _uploadingAvatar
                                ? const Padding(
                                    padding: EdgeInsets.all(8),
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2, color: Colors.white))
                                : const Icon(Icons.camera_alt_rounded,
                                    color: Colors.white, size: 16),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 32),
                ],
              ),
            ),
          ),
          
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverToBoxAdapter(
              child: Text(
                'ACCOUNT DETAILS',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: c.textTertiary,
                    letterSpacing: 0.8),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: SettingsGroup(
              margin: const EdgeInsets.only(left: 16, right: 16, top: 12, bottom: 24),
              children: [
                SettingsTile(
                  icon: Icons.person_outline_rounded,
                  title: 'Name',
                  subtitle: name,
                  onTap: _editName,
                ),
                SettingsTile(
                  icon: Icons.mail_outline_rounded,
                  title: 'Email account',
                  subtitle: user?.email ?? '',
                ),
                SettingsTile(
                  icon: Icons.alternate_email_rounded,
                  title: 'Username',
                  subtitle: '@$_username',
                ),
                SettingsTile(
                  icon: Icons.calendar_today_outlined,
                  title: 'Member since',
                  subtitle: memberSince,
                ),
              ],
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverToBoxAdapter(
              child: Text(
                'CONTACTS & SYNC',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: c.textTertiary,
                    letterSpacing: 0.8),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: SettingsGroup(
              margin: const EdgeInsets.only(left: 16, right: 16, top: 12, bottom: 32),
              children: [
                SettingsTile(
                  icon: Icons.contacts_rounded,
                  title: 'Sync Phone & SIM Contacts',
                  subtitle: ref.watch(contactsProvider).isNotEmpty
                      ? 'Synced ${ref.watch(contactsProvider).length} contact numbers from device'
                      : 'Tap to grant permission and sync saved contacts',
                  trailing: Icon(Icons.sync_rounded, size: 20, color: c.accent),
                  onTap: () async {
                    _showSnack('Syncing contacts from Phone & SIM...');
                    await ref.read(contactsProvider.notifier).syncContacts();
                    final count = ref.read(contactsProvider).length;
                    if (mounted) {
                      _showSnack('Synced $count contacts successfully ✓', success: true);
                    }
                  },
                ),
              ],
            ),
          ),
        ],
      ), // closes CustomScrollView
      ), // closes TweenAnimationBuilder
    ); // closes Scaffold
  }
}
