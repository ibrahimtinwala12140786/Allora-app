import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class ContactNameResolver extends ChangeNotifier {
  ContactNameResolver._();
  static final ContactNameResolver instance = ContactNameResolver._();

  static const MethodChannel _channel =
      MethodChannel('app.allorachat.messenger/contacts');

  // Maps normalized digits (full & last 10 digits) -> Saved Phone Contact Name
  final Map<String, String> _phoneToName = {};
  bool _isLoaded = false;

  /// Read-only access to cached phone to name map
  Map<String, String> get phoneToName => Map.unmodifiable(_phoneToName);
  bool get isLoaded => _isLoaded;

  @visibleForTesting
  void setContactsForTesting(Map<String, String> contacts) {
    _phoneToName
      ..clear()
      ..addAll(contacts);
    _isLoaded = true;
    notifyListeners();
  }

  // Matches Mautrix ghost IDs like @whatsapp_919876543210:allorachat.app
  static final RegExp _matrixGhostRegex = RegExp(
    r'@(?:\w*whatsapp\w*|wa|signal|telegram|gmessages)_(\d{7,15}):',
    caseSensitive: false,
  );

  // Matches phone numbers inside room display names like "+91 98765 43210" or "Rahul (+919876543210)"
  static final RegExp _phoneInTextRegex = RegExp(r'\+?\d[\d\s\-\(\)]{6,16}\d');

  /// Call this once during app startup (e.g., in main.dart or HomeScreen.initState)
  Future<void> syncContacts({bool forceRefresh = false}) async {
    if (_isLoaded && !forceRefresh) return;
    try {
      final result =
          await _channel.invokeMapMethod<String, String>('getDeviceContacts');
      if (result != null) {
        _phoneToName
          ..clear()
          ..addAll(result);
        _isLoaded = true;
        notifyListeners();
      }
    } catch (e) {
      debugPrint('ContactNameResolver error: $e');
    }
  }

  /// Returns the name saved in the user's phone if found; otherwise falls back to [fallbackName].
  String resolveDisplayName({
    required String fallbackName,
    String? matrixUserId,
    List<String>? roomMemberIds,
    String? rawPhoneNumber,
  }) {
    if (_phoneToName.isEmpty) return fallbackName;

    // 1. Check explicit phone number if provided
    if (rawPhoneNumber != null && rawPhoneNumber.isNotEmpty) {
      final matched = _lookupByDigits(rawPhoneNumber);
      if (matched != null) return matched;
    }

    // 2. Check the sender's Matrix User ID (e.g., @whatsapp_919876543210:...)
    if (matrixUserId != null) {
      final matched = _matchFromMatrixId(matrixUserId);
      if (matched != null) return matched;
    }

    // 3. Check 1-on-1 DM room member IDs
    if (roomMemberIds != null) {
      for (final memberId in roomMemberIds) {
        final matched = _matchFromMatrixId(memberId);
        if (matched != null) return matched;
      }
    }

    // 4. Check if the fallback room/user name itself contains a phone number
    final phoneMatch = _phoneInTextRegex.firstMatch(fallbackName);
    if (phoneMatch != null) {
      final matched = _lookupByDigits(phoneMatch.group(0)!);
      if (matched != null) return matched;
    }

    return fallbackName;
  }

  String? _matchFromMatrixId(String mxid) {
    final match = _matrixGhostRegex.firstMatch(mxid);
    if (match != null) {
      return _lookupByDigits(match.group(1)!);
    }
    return null;
  }

  String? _lookupByDigits(String input) {
    final digits = input.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length < 7) return null;

    // Try exact digits first (e.g., 919876543210)
    final exact = _phoneToName[digits];
    if (exact != null) return exact;

    // Try last 10 digits (matches local contacts saved without +91 / country code)
    if (digits.length > 10) {
      final last10 = digits.substring(digits.length - 10);
      final matched10 = _phoneToName[last10];
      if (matched10 != null) return matched10;
    } else if (digits.length == 10) {
      // If contact was saved with a leading 0 (e.g., 09876543210)
      final withZero = _phoneToName['0$digits'];
      if (withZero != null) return withZero;
    }

    return null;
  }
}
