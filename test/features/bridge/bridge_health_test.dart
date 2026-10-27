import 'package:allora/features/bridge/models/bridge_connection_state.dart';
import 'package:allora/features/bridge/models/bridge_health.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BridgeHealth Unit Tests', () {
    test('Initial connected factory creates correct state', () {
      final health = BridgeHealth.connected();
      expect(health.state, equals(BridgeConnectionState.connected));
      expect(health.retryCount, equals(0));
      expect(health.lastError, isNull);
      expect(health.state.canSendDirectly, isTrue);
    });

    test('BridgeHealth copyWith preserves untouched fields', () {
      final original = BridgeHealth(
        state: BridgeConnectionState.reconnecting,
        since: DateTime(2026, 1, 1),
        retryCount: 2,
        lastError: 'Timeout',
      );

      final updated = original.copyWith(retryCount: 3);

      expect(updated.state, equals(BridgeConnectionState.reconnecting));
      expect(updated.since, equals(DateTime(2026, 1, 1)));
      expect(updated.retryCount, equals(3));
      expect(updated.lastError, equals('Timeout'));
    });

    test('Serialization and Deserialization round-trip', () {
      final original = BridgeHealth(
        state: BridgeConnectionState.rateLimited,
        since: DateTime.parse('2026-07-25T01:00:00.000Z'),
        retryCount: 4,
        lastError: '429 Throttled',
        cooldownUntil: DateTime.parse('2026-07-25T01:30:00.000Z'),
      );

      final json = original.toJson();
      final restored = BridgeHealth.fromJson(json);

      expect(restored.state, equals(original.state));
      expect(restored.retryCount, equals(original.retryCount));
      expect(restored.lastError, equals(original.lastError));
      expect(restored.cooldownUntil, equals(original.cooldownUntil));
    });
  });
}
