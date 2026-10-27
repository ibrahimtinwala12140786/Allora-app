import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_contacts/flutter_contacts.dart' hide Event, PermissionStatus;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matrix/matrix.dart';
import 'package:permission_handler/permission_handler.dart';

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
        const platformChannel = MethodChannel('app.allorachat.messenger/notifications');
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

  /// Resolves contact name strictly following the 3-step hierarchy:
  ///   Priority 1: Device Contact Name (matches phone number in device/SIM address book)
  ///   Priority 2: Social Contact Name (saved name from that social network, e.g. WhatsApp contact)
  ///   Priority 3: Social Platform Public Profile / Push Name (name they gave themselves)
  ///   Priority 4: Formatted phone number or cleaned handle
  String resolveContactHierarchy({
    required Room room,
    Event? event,
    String? senderId,
  }) {
    final sId = senderId ??
        event?.senderId ??
        (room.summary.mHeroes?.isNotEmpty == true ? room.summary.mHeroes!.first : '');
    final rawRoomName = _cleanFallback(room.getLocalizedDisplayname());

    if (state.isEmpty && !_isLoading) {
      loadContacts();
    }

    // Priority 1: Check device contacts by senderId, heroes, or room name digits
    if (state.isNotEmpty) {
      String? deviceName = _matchNumberInState(sId);
      if (deviceName == null && room.summary.mHeroes?.isNotEmpty == true) {
        for (final hero in room.summary.mHeroes!) {
          deviceName = _matchNumberInState(hero);
          if (deviceName != null) break;
        }
      }
      if (deviceName == null && room.directChatMatrixID != null) {
        deviceName = _matchNumberInState(room.directChatMatrixID!);
      }
      deviceName ??= _matchNumberInState(rawRoomName);
      deviceName ??= _matchNumberInState(room.id);
      if (deviceName != null && deviceName.trim().isNotEmpty) {
        return deviceName.trim();
      }
    }

    // Priority 2: Name saved in that social platform (room title if not a raw phone number or generic app name)
    final digitsInRoom = _extractDigits(rawRoomName);
    final roomIsPhone = digitsInRoom.length >= 7 &&
        rawRoomName.replaceAll(RegExp(r'[\d\s\+\-\(\)]'), '').trim().isEmpty;
    final isGenericAppName = rawRoomName.toLowerCase() == 'allora' ||
        rawRoomName.toLowerCase() == 'whatsapp' ||
        rawRoomName.toLowerCase() == 'telegram';
    if (!isGenericAppName && !roomIsPhone && rawRoomName.trim().isNotEmpty && !rawRoomName.startsWith('@')) {
      return rawRoomName.trim();
    }

    // Priority 3: Name they gave themselves on the social platform (profile / push name)
    if (event != null) {
      try {
        final profileName = event.senderFromMemoryOrFallback.calcDisplayname().trim();
        final digitsInProfile = _extractDigits(profileName);
        final profileIsPhone = digitsInProfile.length >= 7 &&
            profileName.replaceAll(RegExp(r'[\d\s\+\-\(\)]'), '').trim().isEmpty;
        if (!profileIsPhone && profileName.isNotEmpty && !profileName.startsWith('@')) {
          return _cleanFallback(profileName);
        }
      } catch (_) {}
    }

    if (sId.isNotEmpty) {
      try {
        final memberState = room.getState('m.room.member', sId);
        final mName = memberState?.content['displayname']?.toString().trim();
        if (mName != null && mName.isNotEmpty) {
          final digitsInM = _extractDigits(mName);
          final mIsPhone = digitsInM.length >= 7 &&
              mName.replaceAll(RegExp(r'[\d\s\+\-\(\)]'), '').trim().isEmpty;
          if (!mIsPhone && !mName.startsWith('@')) {
            return _cleanFallback(mName);
          }
        }
      } catch (_) {}
    }

    // Priority 4: Fallback (formatted phone number or cleaned handle)
    if (rawRoomName.isNotEmpty) return rawRoomName;
    return _cleanFallback(sId);
  }

  /// Resolves a contact name given a Matrix ID, phone number string, or room title.
  /// Falls back to [fallback] if no contact matches.
  String resolveName(String idOrTitle, String fallback) {
    if (state.isNotEmpty) {
      // Priority 1: Device Contact Name
      final matchedFromId = _matchNumberInState(idOrTitle);
      if (matchedFromId != null) return matchedFromId;

      final matchedFromFallback = _matchNumberInState(fallback);
      if (matchedFromFallback != null) return matchedFromFallback;
    }

    // Priority 2: Social Saved Name (fallback if not raw phone number)
    final cleaned = _cleanFallback(fallback);
    final digits = _extractDigits(cleaned);
    final isPhone = digits.length >= 7 &&
        cleaned.replaceAll(RegExp(r'[\d\s\+\-\(\)]'), '').trim().isEmpty;
    if (!isPhone && cleaned.isNotEmpty) {
      return cleaned;
    }

    // Priority 3: Profile name from idOrTitle if not phone number
    final fromIdCleaned = _cleanFallback(idOrTitle);
    final idDigits = _extractDigits(fromIdCleaned);
    final idIsPhone = idDigits.length >= 7 &&
        fromIdCleaned.replaceAll(RegExp(r'[\d\s\+\-\(\)]'), '').trim().isEmpty;
    if (!idIsPhone && fromIdCleaned.isNotEmpty) {
      return fromIdCleaned;
    }

    return cleaned.isNotEmpty ? cleaned : fromIdCleaned;
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
      if (digits.startsWith('91') && digits.length == 12) {
        return '+91 ${digits.substring(2, 7)} ${digits.substring(7)}';
      } else if (digits.startsWith('1') && digits.length == 11) {
        return '+1 (${digits.substring(1, 4)}) ${digits.substring(4, 7)}-${digits.substring(7)}';
      } else if (digits.startsWith('44') && digits.length >= 11 && digits.length <= 12) {
        return '+44 ${digits.substring(2, 6)} ${digits.substring(6)}';
      } else if (digits.startsWith('92') && digits.length == 12) {
        return '+92 ${digits.substring(2, 5)} ${digits.substring(5)}';
      } else if (digits.length == 10) {
        return '+${digits.substring(0, 5)} ${digits.substring(5)}';
      }
      return '+$digits';
    }

    return cleaned.isNotEmpty ? cleaned : fallback;
  }
}
