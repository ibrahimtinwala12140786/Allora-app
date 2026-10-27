import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_contacts/flutter_contacts.dart' hide Event, PermissionStatus;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matrix/matrix.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../services/contact_name_resolver.dart';

final contactsProvider =
    StateNotifierProvider<ContactsNotifier, Map<String, String>>((ref) {
  return (ContactsNotifier.instance)..loadContacts();
});

class ContactsNotifier extends StateNotifier<Map<String, String>> {
  static ContactsNotifier? _globalInstance;
  static ContactsNotifier get instance => _globalInstance ??= ContactsNotifier();

  ContactsNotifier() : super({}) {
    _globalInstance = this;
  }

  bool _isLoading = false;
  bool get isLoading => _isLoading;
  int _contactCount = 0;
  int get contactCount => _contactCount;

  /// Loads all contacts from Phone memory, SIM card(s), and synced accounts.
  Future<void> loadContacts({bool force = false}) async {
    if (_isLoading) return;
    _isLoading = true;

    final map = <String, String>{};

    try {
      // 1. Instant native Android contacts query via Android ContactsContract
      try {
        await ContactNameResolver.instance.syncContacts(forceRefresh: force);
        if (ContactNameResolver.instance.phoneToName.isNotEmpty) {
          map.addAll(ContactNameResolver.instance.phoneToName);
          state = Map<String, String>.from(map);
          _contactCount = map.length;
        }

        const platformChannel = MethodChannel('app.allorachat.messenger/contacts');
        final nativeMap = await platformChannel.invokeMapMethod<String, String>('getDeviceContacts');
        if (nativeMap != null && nativeMap.isNotEmpty) {
          map.addAll(nativeMap);
          state = Map<String, String>.from(map);
          _contactCount = map.length;
          debugPrint('ContactsNotifier: Loaded ${nativeMap.length} contacts from native Android');
        }
      } catch (e) {
        debugPrint('Native contacts query error: $e');
      }

      // 2. Permission check & FlutterContacts sync
      bool hasPermission = await Permission.contacts.isGranted;
      if (!hasPermission) {
        final res = await Permission.contacts.request();
        hasPermission = res.isGranted;
      }
      if (!hasPermission) {
        hasPermission = await FlutterContacts.permissions.has(PermissionType.read);
      }
      if (!hasPermission) {
        final status = await FlutterContacts.permissions.request(PermissionType.read);
        hasPermission = status.name == 'granted' || status.name == 'limited';
      }

      if (hasPermission) {
        final contacts = await FlutterContacts.getAll(
          properties: {ContactProperty.phone, ContactProperty.name},
        );

        _contactCount = contacts.length;

        for (final c in contacts) {
          final displayName = (c.displayName ?? '').trim();
          if (displayName.isEmpty) continue;

          for (final phone in c.phones) {
            final digits = _extractDigits(phone.number);
            if (digits.length < 6) continue;

            map[digits] = displayName;
            if (digits.length >= 10) {
              map[digits.substring(digits.length - 10)] = displayName;
            }
            if (digits.length >= 7) {
              map.putIfAbsent(digits.substring(digits.length - 7), () => displayName);
            }
            if (digits.startsWith('0') && digits.length > 7) {
              map[digits.substring(1)] = displayName;
            }
          }
        }
      }

      state = map;
      debugPrint('ContactsNotifier: Total ${map.length} contact keys synced');
    } catch (e) {
      debugPrint('ContactsNotifier error loading contacts: $e');
    } finally {
      _isLoading = false;
    }
  }

  /// Manually force a re-sync from device / SIM contacts
  Future<void> syncContacts() async {
    await loadContacts(force: true);
  }

  static bool isBotMxid(String mxid) {
    if (mxid.isEmpty) return false;
    final lower = mxid.toLowerCase().trim();
    final localpart = lower.startsWith('@') ? lower.substring(1).split(':').first : lower;
    return localpart.endsWith('bot') ||
        localpart.contains('bridge') ||
        localpart == 'whatsappbot' ||
        localpart == 'telegrambot' ||
        localpart == 'instagrambot' ||
        localpart == 'messengerbot' ||
        localpart == 'facebookbot' ||
        localpart == 'discordbot' ||
        localpart == 'slackbot' ||
        localpart == 'twitterbot' ||
        localpart == 'xbot' ||
        localpart == 'signalbot' ||
        localpart == 'allora' ||
        localpart == 'allorabot';
  }

  static bool isBotDisplayName(String name) {
    if (name.isEmpty) return false;
    final lower = name.toLowerCase().trim();
    return lower == 'whatsapp bridge bot' ||
        lower == 'whatsapp bridge' ||
        lower == 'telegram bridge bot' ||
        lower == 'telegram bridge' ||
        lower == 'facebook messenger bridge' ||
        lower == 'messenger bridge bot' ||
        lower == 'messenger bridge' ||
        lower == 'facebook bridge bot' ||
        lower == 'facebook bridge' ||
        lower == 'instagram bridge bot' ||
        lower == 'instagram bridge' ||
        lower == 'discord bridge bot' ||
        lower == 'discord bridge' ||
        lower == 'slack bridge bot' ||
        lower == 'slack bridge' ||
        lower == 'signal bridge bot' ||
        lower == 'signal bridge' ||
        lower == 'twitter bridge bot' ||
        lower == 'x bridge' ||
        lower == 'bridge bot' ||
        lower == 'bridgebot' ||
        lower.contains('bridge bot') ||
        lower.contains('bridgebot') ||
        lower.contains('whatsapp bot') ||
        lower.contains('telegram bot') ||
        lower.contains('messenger bot') ||
        lower.contains('facebook bot') ||
        lower.contains('instagram bot') ||
        lower == 'whatsapp' ||
        lower == 'telegram' ||
        lower == 'allora' ||
        lower == 'empty room' ||
        lower == 'empty chat';
  }

  static bool isRemotePuppetMxid(String mxid) {
    final lower = mxid.toLowerCase();
    return lower.contains('_whatsapp_') || lower.contains('@whatsapp_') ||
           lower.contains('_telegram_') || lower.contains('@telegram_') ||
           lower.contains('_facebook_') || lower.contains('@facebook_') ||
           lower.contains('_messenger_') || lower.contains('@messenger_') ||
           lower.contains('_instagram_') || lower.contains('@instagram_') ||
           lower.contains('_discord_') || lower.contains('@discord_') ||
           lower.contains('_slack_') || lower.contains('@slack_') ||
           lower.contains('_twitter_') || lower.contains('@twitter_') ||
           lower.contains('_signal_') || lower.contains('@signal_') ||
           lower.contains('@tg_') || lower.contains('_tg_') ||
           lower.contains('@wa_') || lower.contains('_wa_') ||
           lower.contains('@fb_') || lower.contains('_fb_') ||
           lower.contains('@ig_') || lower.contains('_ig_');
  }

  /// Formats raw digits into a clean, readable international phone number.
  static String formatPhoneNumber(String original, String digitsOnly) {
    if (original.contains(' ') || original.contains('-')) {
      return original.startsWith('+') ? original : '+$original';
    }

    if (digitsOnly.startsWith('91') && digitsOnly.length == 12) {
      return '+91 ${digitsOnly.substring(2, 7)} ${digitsOnly.substring(7)}';
    } else if (digitsOnly.startsWith('1') && digitsOnly.length == 11) {
      return '+1 (${digitsOnly.substring(1, 4)}) ${digitsOnly.substring(4, 7)}-${digitsOnly.substring(7)}';
    } else if (digitsOnly.startsWith('44') && digitsOnly.length >= 11 && digitsOnly.length <= 12) {
      return '+44 ${digitsOnly.substring(2, 6)} ${digitsOnly.substring(6)}';
    } else if (digitsOnly.startsWith('92') && digitsOnly.length == 12) {
      return '+92 ${digitsOnly.substring(2, 5)} ${digitsOnly.substring(5)}';
    } else if (digitsOnly.startsWith('971') && digitsOnly.length >= 11 && digitsOnly.length <= 12) {
      return '+971 ${digitsOnly.substring(3, 5)} ${digitsOnly.substring(5, 8)} ${digitsOnly.substring(8)}';
    } else if (digitsOnly.length == 10) {
      return '+${digitsOnly.substring(0, 5)} ${digitsOnly.substring(5)}';
    }

    return '+$digitsOnly';
  }

  /// Resolves contact name strictly following the hierarchy:
  ///   Priority 1: Device Contact Name (matches phone number in device/SIM address book)
  ///   Priority 2: Social Contact Profile Name (saved name or push name, if not a bridge bot or generic name)
  ///   Priority 3: Formatted International Phone Number (e.g. +91 98765 43210 for WhatsApp, Signal, etc.)
  ///   Priority 4: Clean Platform Handle / Username (e.g. for Telegram, Instagram, Messenger, Discord)
  ///   Priority 5: Clean Platform Fallback (e.g. "WhatsApp Contact", never "WhatsApp bridge bot")
  String resolveContactHierarchy({
    required Room room,
    Event? event,
    String? senderId,
  }) {
    if (state.isEmpty && !_isLoading) {
      loadContacts();
    }

    final myId = room.client.userID?.toLowerCase() ?? '';

    // 1. Identify the remote contact's Matrix ID (puppet or non-bot participant)
    String? remoteMxid;
    if (senderId != null && senderId.isNotEmpty && senderId.toLowerCase() != myId && !isBotMxid(senderId)) {
      remoteMxid = senderId;
    }
    if (remoteMxid == null && event?.senderId != null) {
      final eSender = event!.senderId;
      if (eSender.toLowerCase() != myId && !isBotMxid(eSender)) {
        remoteMxid = eSender;
      }
    }
    if (remoteMxid == null) {
      final directId = room.directChatMatrixID;
      if (directId != null && directId.toLowerCase() != myId && !isBotMxid(directId)) {
        remoteMxid = directId;
      }
    }
    if (remoteMxid == null) {
      for (final p in room.getParticipants()) {
        final pId = p.id;
        final pLower = pId.toLowerCase();
        if (pLower == myId || isBotMxid(pLower)) continue;
        if (isRemotePuppetMxid(pLower)) {
          remoteMxid = pId;
          break;
        }
      }
    }
    if (remoteMxid == null && room.summary.mHeroes != null) {
      for (final h in room.summary.mHeroes!) {
        final hLower = h.toLowerCase();
        if (hLower == myId || isBotMxid(hLower)) continue;
        remoteMxid = h;
        break;
      }
    }
    if (remoteMxid == null) {
      for (final p in room.getParticipants()) {
        final pId = p.id;
        final pLower = pId.toLowerCase();
        if (pLower == myId || isBotMxid(pLower)) continue;
        remoteMxid = pId;
        break;
      }
    }

    // 2. Extract best phone number digits
    final phoneDigits = _extractBestPhoneDigits(room, remoteMxid: remoteMxid);

    // Priority 1: Check device contacts (in-memory resolver + state)
    final inMemoryMatch = ContactNameResolver.instance.resolveDisplayName(
      fallbackName: '',
      matrixUserId: remoteMxid,
      roomMemberIds: room.getParticipants().map((p) => p.id).toList(),
      rawPhoneNumber: phoneDigits.isNotEmpty ? phoneDigits : null,
    );
    if (inMemoryMatch.isNotEmpty) {
      return inMemoryMatch;
    }

    if (state.isNotEmpty) {
      if (phoneDigits.isNotEmpty) {
        final match = _matchNumberInState(phoneDigits);
        if (match != null && match.trim().isNotEmpty) return match.trim();
      }
      if (remoteMxid != null) {
        final match = _matchNumberInState(remoteMxid);
        if (match != null && match.trim().isNotEmpty) return match.trim();
      }
      final rawName = room.getLocalizedDisplayname();
      if (!isBotDisplayName(rawName)) {
        final match = _matchNumberInState(rawName);
        if (match != null && match.trim().isNotEmpty) return match.trim();
      }
    }

    // Priority 2: Check social profile / push name (must NOT be a bridge bot name)
    // A. Check member display name in room state
    if (remoteMxid != null && remoteMxid.isNotEmpty) {
      try {
        final memberState = room.getState('m.room.member', remoteMxid);
        final mName = memberState?.content['displayname']?.toString().trim() ?? '';
        if (mName.isNotEmpty && !isBotDisplayName(mName) && !isBotMxid(mName)) {
          final cleaned = _cleanFallback(mName);
          if (cleaned.isNotEmpty && !isBotDisplayName(cleaned)) {
            return cleaned;
          }
        }
      } catch (_) {}
    }

    // B. Check event sender display name
    if (event != null && event.senderId.toLowerCase() != myId && !isBotMxid(event.senderId)) {
      try {
        final pName = event.senderFromMemoryOrFallback.calcDisplayname().trim();
        if (pName.isNotEmpty && !isBotDisplayName(pName) && !isBotMxid(pName)) {
          final cleaned = _cleanFallback(pName);
          if (cleaned.isNotEmpty && !isBotDisplayName(cleaned)) {
            return cleaned;
          }
        }
      } catch (_) {}
    }

    // C. Check room display name (if human/group name and not a bridge bot)
    final locRoomName = room.getLocalizedDisplayname().trim();
    if (locRoomName.isNotEmpty && !isBotDisplayName(locRoomName) && !isBotMxid(locRoomName)) {
      final cleaned = _cleanFallback(locRoomName);
      if (cleaned.isNotEmpty && !isBotDisplayName(cleaned)) {
        return cleaned;
      }
    }

    // Priority 3: Phone number format (for WhatsApp / Signal / any platform with digits)
    if (phoneDigits.length >= 7) {
      return formatPhoneNumber(phoneDigits, phoneDigits);
    }

    // Priority 4: Clean username / handle from remote puppet MXID
    if (remoteMxid != null && remoteMxid.isNotEmpty) {
      final cleanedHandle = _cleanFallback(remoteMxid);
      if (cleanedHandle.isNotEmpty && !isBotDisplayName(cleanedHandle) && !isBotMxid(cleanedHandle)) {
        return cleanedHandle;
      }
    }

    // Priority 5: Fallback to platform-friendly name (NEVER "WhatsApp bridge bot")
    final rLower = room.id.toLowerCase();
    final rNameLower = locRoomName.toLowerCase();
    if (rLower.contains('whatsapp') || rNameLower.contains('whatsapp')) {
      return 'WhatsApp Contact';
    } else if (rLower.contains('telegram') || rNameLower.contains('telegram')) {
      return 'Telegram Contact';
    } else if (rLower.contains('messenger') || rLower.contains('facebook')) {
      return 'Messenger Contact';
    } else if (rLower.contains('instagram')) {
      return 'Instagram Contact';
    }

    return 'Chat';
  }

  String _extractBestPhoneDigits(Room room, {String? remoteMxid}) {
    // 1. Remote puppet MXID: e.g. @whatsapp_919876543210:server.com
    if (remoteMxid != null && remoteMxid.isNotEmpty) {
      final local = remoteMxid.split(':').first;
      final d = _extractDigits(local);
      if (d.length >= 7) return d;
    }

    // 2. Direct chat Matrix ID
    final directId = room.directChatMatrixID;
    if (directId != null && directId.isNotEmpty && !isBotMxid(directId)) {
      final d = _extractDigits(directId.split(':').first);
      if (d.length >= 7) return d;
    }

    // 3. Remote puppet participants
    for (final p in room.getParticipants()) {
      final pId = p.id;
      if (isBotMxid(pId)) continue;
      if (isRemotePuppetMxid(pId)) {
        final d = _extractDigits(pId.split(':').first);
        if (d.length >= 7) return d;
      }
    }

    // 4. Room heroes
    if (room.summary.mHeroes != null) {
      for (final h in room.summary.mHeroes!) {
        if (isBotMxid(h)) continue;
        final d = _extractDigits(h.split(':').first);
        if (d.length >= 7) return d;
      }
    }

    // 5. Room ID (e.g. !whatsapp_919876543210_...:server.com)
    final rId = room.id.split(':').first;
    if (rId.contains('whatsapp') || rId.contains('wa_')) {
      final d = _extractDigits(rId);
      if (d.length >= 7) return d;
    }

    // 6. Canonical Alias
    final alias = room.canonicalAlias.split(':').first;
    if (alias.contains('whatsapp') || alias.contains('wa_')) {
      final d = _extractDigits(alias);
      if (d.length >= 7) return d;
    }

    return '';
  }

  /// Resolves a contact name given a Matrix ID, phone number string, or room title.
  /// Falls back to [fallback] if no contact matches.
  String resolveName(String idOrTitle, String fallback) {
    // Priority 1: Device Contact Name
    if (state.isNotEmpty) {
      final matchedFromId = _matchNumberInState(idOrTitle);
      if (matchedFromId != null) return matchedFromId;

      if (!isBotDisplayName(fallback)) {
        final matchedFromFallback = _matchNumberInState(fallback);
        if (matchedFromFallback != null) return matchedFromFallback;
      }
    }

    // Priority 2: Social Saved / Push Name (if not bot and not empty)
    if (!isBotDisplayName(fallback) && !isBotMxid(fallback)) {
      final cleaned = _cleanFallback(fallback);
      if (cleaned.isNotEmpty && !isBotDisplayName(cleaned)) {
        return cleaned;
      }
    }

    // Priority 3: Phone number from digits in idOrTitle or fallback
    final idDigits = _extractDigits(idOrTitle.split(':').first);
    if (idDigits.length >= 7) {
      return formatPhoneNumber(idDigits, idDigits);
    }
    final fbDigits = _extractDigits(fallback);
    if (fbDigits.length >= 7) {
      return formatPhoneNumber(fbDigits, fbDigits);
    }

    // Priority 4: Clean username/handle
    final fromIdCleaned = _cleanFallback(idOrTitle);
    if (fromIdCleaned.isNotEmpty && !isBotDisplayName(fromIdCleaned) && !isBotMxid(fromIdCleaned)) {
      return fromIdCleaned;
    }

    // Priority 5: Fallback without ever showing bot name
    if (isBotDisplayName(fallback) || isBotMxid(fallback) || isBotMxid(idOrTitle)) {
      return '';
    }

    return fallback;
  }

  String? _matchNumberInState(String input) {
    if (input.isEmpty) return null;

    final digits = _extractDigits(input);
    if (digits.length < 6) return null;

    // A. Direct full digits match
    if (state.containsKey(digits)) {
      return state[digits];
    }

    // B. Match last 10 digits
    if (digits.length >= 10) {
      final last10 = digits.substring(digits.length - 10);
      if (state.containsKey(last10)) {
        return state[last10];
      }
    }

    // C. Strip leading zero if present
    if (digits.startsWith('0') && digits.length > 7) {
      final noZero = digits.substring(1);
      if (state.containsKey(noZero)) {
        return state[noZero];
      }
    }

    // D. Suffix match against all stored contact numbers (>= 7 digits)
    for (final entry in state.entries) {
      if (entry.key.length >= 7 && digits.length >= 7) {
        if (digits.endsWith(entry.key) || entry.key.endsWith(digits)) {
          return entry.value;
        }
      }
    }

    return null;
  }

  static String _extractDigits(String text) {
    return text.replaceAll(RegExp(r'[^\d]'), '');
  }

  static String _cleanFallback(String fallback) {
    if (fallback.isEmpty) return fallback;

    var cleaned = fallback.trim();

    // 1. Clean Matrix MXID
    if (cleaned.startsWith('@') && cleaned.contains(':')) {
      cleaned = cleaned.split(':').first.substring(1);
      cleaned = cleaned.replaceFirst(
        RegExp(r'^(?:whatsapp_|telegram_|instagram_|messenger_|facebook_|discord_|slack_|twitter_|x_|signal_)',
            caseSensitive: false),
        '',
      );
    }

    // 2. Clean bridge tags (WA), (TG), (FB), (WhatsApp), etc.
    cleaned = cleaned.replaceAll(
      RegExp(
        r'\s*[\(\[]\s*(?:WA|IG|FB|TG|DC|SL|TW|X|Slack|Discord|Signal|WhatsApp|Telegram|Instagram|Messenger|Facebook|Twitter)\s*[\)\]]',
        caseSensitive: false,
      ),
      '',
    ).trim();

    // 3. Clean bridge bot prefixes: "WhatsApp bridge bot", "Bridge bot", "Bridge:", etc.
    cleaned = cleaned.replaceAll(
      RegExp(
        r'^(?:(?:WhatsApp|Telegram|Instagram|Messenger|Facebook|Discord|Slack|Signal|X|Twitter)\s+)?(?:bridge\s*bot|bridgebot|bridge)\s*[:\-\s]*',
        caseSensitive: false,
      ),
      '',
    ).trim();

    // 4. Remove isolated "bridge bot" / "bridgebot"
    cleaned = cleaned.replaceAll(
      RegExp(r'(?:^|\s+)(?:bridge\s*bot|bridgebot)(?:\s+|$)', caseSensitive: false),
      ' ',
    ).trim();

    // 5. Clean surrounding brackets/parenthesis
    if (cleaned.startsWith('(') && cleaned.endsWith(')')) {
      cleaned = cleaned.substring(1, cleaned.length - 1).trim();
    } else if (cleaned.startsWith('[') && cleaned.endsWith(']')) {
      cleaned = cleaned.substring(1, cleaned.length - 1).trim();
    }

    // 6. Clean leading/trailing punctuation
    cleaned = cleaned.replaceAll(RegExp(r'^[:\-\s]+|[:\-\s]+$'), '').trim();

    // 7. Format phone numbers cleanly if it's a number
    final digits = _extractDigits(cleaned);
    if (digits.length >= 7 && (cleaned.startsWith('+') || RegExp(r'^\d+$').hasMatch(cleaned))) {
      return formatPhoneNumber(cleaned, digits);
    }

    // CRITICAL: If cleaned became empty or is still a bot string, never return bot fallback!
    if (cleaned.isEmpty || isBotDisplayName(cleaned)) {
      final fallbackDigits = _extractDigits(fallback);
      if (fallbackDigits.length >= 7) {
        return formatPhoneNumber(fallbackDigits, fallbackDigits);
      }
      return '';
    }

    return cleaned;
  }
}
