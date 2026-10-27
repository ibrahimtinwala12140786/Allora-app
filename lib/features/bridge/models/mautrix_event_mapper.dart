import 'bridge_connection_state.dart';

/// Mapper utility for converting Mautrix bridge status codes and event strings
/// into strongly typed [BridgeConnectionState] enum instances.
class MautrixEventMapper {
  MautrixEventMapper._();

  /// Maps a raw Mautrix status string or state event code into [BridgeConnectionState].
  static BridgeConnectionState mapState(String? rawStatus) {
    if (rawStatus == null || rawStatus.trim().isEmpty) {
      return BridgeConnectionState.bridgeUnreachable;
    }

    final status = rawStatus.trim().toUpperCase();

    switch (status) {
      case 'CONNECTED':
      case 'LOGGED_IN':
      case 'RUNNING':
        return BridgeConnectionState.connected;

      case 'STARTING':
      case 'CONNECTING':
      case 'TRANSIENT_DISCONNECT':
      case 'RESUMING':
      case 'RECONNECTING':
        return BridgeConnectionState.reconnecting;

      case 'BAD_CREDENTIALS':
      case 'LOGGED_OUT':
      case 'UNLINKED':
      case 'SESSION_EXPIRED':
      case 'UNAUTHORIZED':
        return BridgeConnectionState.needsLogin;

      case 'RATE_LIMIT':
      case 'RATE_LIMITED':
      case 'THROTTLED':
      case 'TOO_MANY_REQUESTS':
      case '429':
        return BridgeConnectionState.rateLimited;

      case 'BRIDGE_UNREACHABLE':
      case 'DAEMON_DOWN':
      case 'HOST_UNREACHABLE':
      case 'TIMEOUT':
      case '503':
      case '504':
      case 'UNKNOWN_ERROR':
      default:
        return BridgeConnectionState.bridgeUnreachable;
    }
  }

  /// Extracts reason string from bridge message payload or body text.
  static String? extractReason(String? body) {
    if (body == null || body.trim().isEmpty) return null;
    final lower = body.toLowerCase();
    if (lower.contains('rate limit') || lower.contains('throttled')) {
      return 'Rate limited by platform server';
    }
    if (lower.contains('logged out') || lower.contains('session expired')) {
      return 'Session expired or unlinked on primary device';
    }
    if (lower.contains('unreachable') || lower.contains('connection refused')) {
      return 'Bridge daemon unreachable';
    }
    return body.trim();
  }
}
