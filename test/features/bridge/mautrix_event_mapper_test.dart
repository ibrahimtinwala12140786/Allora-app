import 'package:allora/features/bridge/models/bridge_connection_state.dart';
import 'package:allora/features/bridge/models/mautrix_event_mapper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MautrixEventMapper Unit Tests', () {
    test('Maps connected bridge status events correctly', () {
      expect(MautrixEventMapper.mapState('CONNECTED'), equals(BridgeConnectionState.connected));
      expect(MautrixEventMapper.mapState('LOGGED_IN'), equals(BridgeConnectionState.connected));
    });

    test('Maps reconnecting status events correctly', () {
      expect(MautrixEventMapper.mapState('STARTING'), equals(BridgeConnectionState.reconnecting));
      expect(MautrixEventMapper.mapState('CONNECTING'), equals(BridgeConnectionState.reconnecting));
      expect(MautrixEventMapper.mapState('TRANSIENT_DISCONNECT'), equals(BridgeConnectionState.reconnecting));
    });

    test('Maps needsLogin status events correctly', () {
      expect(MautrixEventMapper.mapState('BAD_CREDENTIALS'), equals(BridgeConnectionState.needsLogin));
      expect(MautrixEventMapper.mapState('LOGGED_OUT'), equals(BridgeConnectionState.needsLogin));
    });

    test('Maps rate limited status events correctly', () {
      expect(MautrixEventMapper.mapState('RATE_LIMIT'), equals(BridgeConnectionState.rateLimited));
      expect(MautrixEventMapper.mapState('THROTTLED'), equals(BridgeConnectionState.rateLimited));
      expect(MautrixEventMapper.mapState('429'), equals(BridgeConnectionState.rateLimited));
    });

    test('Maps bridge unreachable status events correctly', () {
      expect(MautrixEventMapper.mapState('BRIDGE_UNREACHABLE'), equals(BridgeConnectionState.bridgeUnreachable));
      expect(MautrixEventMapper.mapState('503'), equals(BridgeConnectionState.bridgeUnreachable));
      expect(MautrixEventMapper.mapState(null), equals(BridgeConnectionState.bridgeUnreachable));
    });
  });
}
