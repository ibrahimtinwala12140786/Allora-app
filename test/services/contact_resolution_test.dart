import 'package:allora/data/services/contacts_service.dart';
import 'package:allora/features/chat_list/chat_list_providers.dart';
import 'package:allora/services/contact_name_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Bot Identification', () {
    test('isBotDisplayName flags all bridge bot variations', () {
      expect(ContactsNotifier.isBotDisplayName('WhatsApp bridge bot'), isTrue);
      expect(ContactsNotifier.isBotDisplayName('WhatsApp Bridge Bot'), isTrue);
      expect(ContactsNotifier.isBotDisplayName('telegram bridge bot'), isTrue);
      expect(ContactsNotifier.isBotDisplayName('bridge bot'), isTrue);
      expect(ContactsNotifier.isBotDisplayName('bridgebot'), isTrue);
      expect(ContactsNotifier.isBotDisplayName('WhatsApp bridge'), isTrue);
      expect(ContactsNotifier.isBotDisplayName('whatsapp bot'), isTrue);
      expect(ContactsNotifier.isBotDisplayName('Telegram bot'), isTrue);
      expect(ContactsNotifier.isBotDisplayName('empty room'), isTrue);

      // Real user names must NOT be flagged
      expect(ContactsNotifier.isBotDisplayName('John Doe'), isFalse);
      expect(ContactsNotifier.isBotDisplayName('+1 (415) 555-0123'), isFalse);
      expect(ContactsNotifier.isBotDisplayName('Alice'), isFalse);
    });

    test('isBotMxid flags bot MXIDs', () {
      expect(ContactsNotifier.isBotMxid('@whatsappbot:matrix.allora.chat'), isTrue);
      expect(ContactsNotifier.isBotMxid('@telegrambot:matrix.allora.chat'), isTrue);
      expect(ContactsNotifier.isBotMxid('@bridge:matrix.allora.chat'), isTrue);
      expect(ContactsNotifier.isBotMxid('@allora:matrix.allora.chat'), isTrue);

      // Remote contact puppets must NOT be flagged
      expect(ContactsNotifier.isBotMxid('@whatsapp_14155550123:matrix.allora.chat'), isFalse);
      expect(ContactsNotifier.isBotMxid('@telegram_12345678:matrix.allora.chat'), isFalse);
      expect(ContactsNotifier.isBotMxid('@user:matrix.allora.chat'), isFalse);
    });
  });

  group('Phone Number Formatting', () {
    test('formats international numbers cleanly', () {
      expect(
        ContactsNotifier.formatPhoneNumber('919876543210', '919876543210'),
        '+91 98765 43210',
      );
      expect(
        ContactsNotifier.formatPhoneNumber('14155550123', '14155550123'),
        '+1 (415) 555-0123',
      );
      expect(
        ContactsNotifier.formatPhoneNumber('447911123456', '447911123456'),
        '+44 7911 123456',
      );
      expect(
        ContactsNotifier.formatPhoneNumber('923001234567', '923001234567'),
        '+92 300 1234567',
      );
    });
  });

  group('cleanRoomTitle', () {
    test('never returns bridge bot on fallback and extracts phone number', () {
      // Pure bridge bot names should return empty string (never "WhatsApp bridge bot")
      expect(cleanRoomTitle('WhatsApp bridge bot'), '');
      expect(cleanRoomTitle('telegram bridge bot'), '');
      expect(cleanRoomTitle('bridge bot'), '');

      // Bridge tag cleanup
      expect(cleanRoomTitle('John Doe (WA)'), 'John Doe');
      expect(cleanRoomTitle('Alice Smith [TG]'), 'Alice Smith');

      // Phone number extraction from MXID
      expect(
        cleanRoomTitle('@whatsapp_919876543210:allora.chat'),
        '+91 98765 43210',
      );
      expect(
        cleanRoomTitle('@whatsapp_14155550123:allora.chat'),
        '+1 (415) 555-0123',
      );
    });
  });

  group('ContactsNotifier.resolveName', () {
    test('resolves phone numbers when name is a bot or missing', () {
      final notifier = ContactsNotifier();

      // If fallback is "WhatsApp bridge bot", extract phone number from puppet MXID
      final resolved = notifier.resolveName(
        '@whatsapp_919876543210:allora.chat',
        'WhatsApp bridge bot',
      );
      expect(resolved, '+91 98765 43210');
      expect(resolved.contains('bridge bot'), isFalse);

      // Valid human name should be preserved
      final human = notifier.resolveName(
        '@whatsapp_919876543210:allora.chat',
        'Sarah Connor',
      );
      expect(human, 'Sarah Connor');
    });
  });

  group('ContactNameResolver', () {
    setUp(() {
      ContactNameResolver.instance.setContactsForTesting({
        '919876543210': 'Ibrahim Tinwala',
        '9876543210': 'Ibrahim Tinwala',
        '14155550123': 'Alice Developer',
        '4155550123': 'Alice Developer',
      });
    });

    test('resolves phonebook name from WhatsApp Matrix puppet ID', () {
      final name = ContactNameResolver.instance.resolveDisplayName(
        fallbackName: 'Push Name',
        matrixUserId: '@whatsapp_919876543210:matrix.allorachat.app',
      );
      expect(name, 'Ibrahim Tinwala');
    });

    test('resolves phonebook name from local 10 digit contact match', () {
      final name = ContactNameResolver.instance.resolveDisplayName(
        fallbackName: 'Push Name',
        matrixUserId: '@whatsapp_919876543210:matrix.allorachat.app',
      );
      expect(name, 'Ibrahim Tinwala');
    });

    test('resolves phonebook name from room member IDs', () {
      final name = ContactNameResolver.instance.resolveDisplayName(
        fallbackName: 'Some Push Name',
        roomMemberIds: [
          '@alice:matrix.allorachat.app',
          '@whatsapp_14155550123:matrix.allorachat.app',
        ],
      );
      expect(name, 'Alice Developer');
    });

    test('resolves phonebook name from phone number in fallback text', () {
      final name = ContactNameResolver.instance.resolveDisplayName(
        fallbackName: '+91 98765 43210',
      );
      expect(name, 'Ibrahim Tinwala');
    });

    test('falls back to fallbackName if number is not saved in address book', () {
      final name = ContactNameResolver.instance.resolveDisplayName(
        fallbackName: 'Unknown Person',
        matrixUserId: '@whatsapp_999999999999:matrix.allorachat.app',
      );
      expect(name, 'Unknown Person');
    });
  });
}
