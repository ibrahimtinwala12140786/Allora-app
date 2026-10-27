import 'package:allora/data/services/disappearing_message_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

class _MockEvent extends Fake implements Event {
  @override
  final String body;
  _MockEvent(this.body);
}

void main() {
  group('DisappearingMessageService Bridge Timer Detection', () {
    test('detects 24 hours from WhatsApp system message', () {
      final events = [
        _MockEvent('You turned on disappearing messages. New messages will disappear from this chat 24 hours after they\'re sent, except when kept. Change timer'),
      ];
      expect(DisappearingMessageService.detectBridgeTimerFromEvents(events), equals(86400));
    });

    test('detects 7 days from WhatsApp system message', () {
      final events = [
        _MockEvent('You turned on disappearing messages. New messages will disappear from this chat 7 days after they\'re sent, except when kept. Change timer'),
      ];
      expect(DisappearingMessageService.detectBridgeTimerFromEvents(events), equals(604800));
    });

    test('detects 90 days from WhatsApp system message', () {
      final events = [
        _MockEvent('You turned on disappearing messages. New messages will disappear from this chat 90 days after they\'re sent, except when kept. Change timer'),
      ];
      expect(DisappearingMessageService.detectBridgeTimerFromEvents(events), equals(7776000));
    });

    test('detects turning off disappearing messages', () {
      final events = [
        _MockEvent('You turned off disappearing messages. Change timer'),
      ];
      expect(DisappearingMessageService.detectBridgeTimerFromEvents(events), equals(0));
    });

    test('latest system message takes precedence', () {
      final events = [
        _MockEvent('You turned on disappearing messages. New messages will disappear from this chat 24 hours after they\'re sent, except when kept. Change timer'),
        _MockEvent('You turned off disappearing messages. Change timer'),
      ];
      expect(DisappearingMessageService.detectBridgeTimerFromEvents(events), equals(0));
    });
  });
}
