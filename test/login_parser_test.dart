import 'package:allora/data/services/connection_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseListLogins', () {
    test('recognises logged-out replies', () {
      expect(parseListLogins("You're not logged into WhatsApp")!.isLoggedIn,
          isFalse);
      expect(parseListLogins('No logins')!.isLoggedIn, isFalse);
    });

    test('recognises logged-in replies and extracts the phone', () {
      final r = parseListLogins('List of logins:\n* +14155550123 (Personal)');
      expect(r!.isLoggedIn, isTrue);
      expect(r.accountLabel, '+14155550123');
    });

    test('recognises handle-style accounts', () {
      final r = parseListLogins('Logged in as @some.user');
      expect(r!.isLoggedIn, isTrue);
      expect(r.accountLabel, '@some.user');
    });

    test('recognises Connected and User + phone replies', () {
      final r1 = parseListLogins('Connected as +14155550123');
      expect(r1!.isLoggedIn, isTrue);
      expect(r1.accountLabel, '+14155550123');

      final r2 = parseListLogins('User +14155550123 (Connected)');
      expect(r2!.isLoggedIn, isTrue);
      expect(r2.accountLabel, '+14155550123');

      final r3 = parseListLogins('1. +14155550123');
      expect(r3!.isLoggedIn, isTrue);
      expect(r3.accountLabel, '+14155550123');
    });

    test('returns null for unrelated bot chatter', () {
      expect(parseListLogins('Syncing chats, this may take a while'), isNull);
    });
  });
}
