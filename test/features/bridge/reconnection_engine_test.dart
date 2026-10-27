import 'package:allora/features/bridge/models/bridge_connection_state.dart';
import 'package:allora/features/bridge/providers/bridge_health_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Reconnection Engine Tests', () {
    test('Reconnection schedule delays and jitter bounds', () {
      expect(kReconnectionSchedule.length, equals(5));
      expect(kReconnectionSchedule[0], equals(const Duration(seconds: 2)));
      expect(kReconnectionSchedule[1], equals(const Duration(seconds: 5)));
      expect(kReconnectionSchedule[2], equals(const Duration(seconds: 15)));
      expect(kReconnectionSchedule[3], equals(const Duration(seconds: 40)));
      expect(kReconnectionSchedule[4], equals(const Duration(seconds: 90)));
    });

    test('State transition to reconnecting suppresses error popups', () {
      final notifier = BridgeHealthNotifier(accountId: 'whatsapp_test');
      notifier.noteDisconnect(reason: 'Network loss');

      expect(notifier.state.state, equals(BridgeConnectionState.reconnecting));
      expect(notifier.state.retryCount, equals(1));
      expect(notifier.state.state.showBanner, isFalse); // Silent retry without banner

      notifier.dispose();
    });
  });
}
