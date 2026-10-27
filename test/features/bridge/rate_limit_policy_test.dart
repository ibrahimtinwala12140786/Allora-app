import 'package:allora/features/bridge/models/bridge_connection_state.dart';
import 'package:allora/features/bridge/providers/bridge_health_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Rate Limit Policy Tests', () {
    test('Rate limit backoff schedule intervals', () {
      expect(kRateLimitSchedule.length, equals(5));
      expect(kRateLimitSchedule[0], equals(const Duration(minutes: 30)));
      expect(kRateLimitSchedule[1], equals(const Duration(hours: 1)));
      expect(kRateLimitSchedule[2], equals(const Duration(hours: 2)));
      expect(kRateLimitSchedule[3], equals(const Duration(hours: 6)));
      expect(kRateLimitSchedule[4], equals(const Duration(hours: 12)));
    });

    test('noteRateLimited sets cooldownUntil timestamp and rateLimited state', () {
      final notifier = BridgeHealthNotifier(accountId: 'whatsapp_throttled');
      notifier.noteRateLimited(reason: '429 Too Many Requests');

      expect(notifier.state.state, equals(BridgeConnectionState.rateLimited));
      expect(notifier.state.cooldownUntil, isNotNull);
      expect(notifier.state.isThrottled, isTrue);
      expect(notifier.state.state.showBanner, isTrue);

      notifier.dispose();
    });
  });
}
