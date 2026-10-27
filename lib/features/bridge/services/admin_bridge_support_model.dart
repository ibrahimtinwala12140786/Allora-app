import '../models/bridge_connection_state.dart';
import '../models/bridge_health.dart';

/// Support diagnostic model for enterprise admin dashboards & monitoring.
class AdminBridgeSupportModel {
  final String accountId;
  final String networkName;
  final BridgeConnectionState currentState;
  final double uptimePercentage;
  final DateTime? lastDisconnectAt;
  final int retryCount;
  final String? lastError;
  final Duration connectionDuration;

  const AdminBridgeSupportModel({
    required this.accountId,
    required this.networkName,
    required this.currentState,
    required this.uptimePercentage,
    this.lastDisconnectAt,
    required this.retryCount,
    this.lastError,
    required this.connectionDuration,
  });

  factory AdminBridgeSupportModel.fromHealth({
    required String accountId,
    required String networkName,
    required BridgeHealth health,
    double uptimePercentage = 99.5,
    DateTime? lastDisconnectAt,
  }) {
    return AdminBridgeSupportModel(
      accountId: accountId,
      networkName: networkName,
      currentState: health.state,
      uptimePercentage: uptimePercentage,
      lastDisconnectAt: lastDisconnectAt ?? (health.state != BridgeConnectionState.connected ? health.since : null),
      retryCount: health.retryCount,
      lastError: health.lastError,
      connectionDuration: DateTime.now().difference(health.since),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'accountId': accountId,
      'networkName': networkName,
      'currentState': currentState.name,
      'uptimePercentage': uptimePercentage,
      'lastDisconnectAt': lastDisconnectAt?.toIso8601String(),
      'retryCount': retryCount,
      'lastError': lastError,
      'connectionDurationSeconds': connectionDuration.inSeconds,
    };
  }
}
