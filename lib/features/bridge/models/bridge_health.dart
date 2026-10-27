import 'package:flutter/foundation.dart';
import 'bridge_connection_state.dart';

/// Immutable BridgeHealth model containing current connection state telemetry,
/// timestamps, retry counters, and rate-limit cooldown windows.
@immutable
class BridgeHealth {
  final BridgeConnectionState state;
  final DateTime since;
  final String? lastError;
  final int retryCount;
  final DateTime? nextRetryAt;
  final DateTime? cooldownUntil;

  const BridgeHealth({
    required this.state,
    required this.since,
    this.lastError,
    this.retryCount = 0,
    this.nextRetryAt,
    this.cooldownUntil,
  });

  /// Factory helper for creating an initial connected state.
  factory BridgeHealth.connected({DateTime? since}) {
    return BridgeHealth(
      state: BridgeConnectionState.connected,
      since: since ?? DateTime.now(),
      retryCount: 0,
    );
  }

  /// Factory helper for creating an initial reconnecting state.
  factory BridgeHealth.reconnecting({
    DateTime? since,
    int retryCount = 1,
    DateTime? nextRetryAt,
    String? lastError,
  }) {
    return BridgeHealth(
      state: BridgeConnectionState.reconnecting,
      since: since ?? DateTime.now(),
      retryCount: retryCount,
      nextRetryAt: nextRetryAt,
      lastError: lastError,
    );
  }

  /// Create a copy with modified attributes.
  BridgeHealth copyWith({
    BridgeConnectionState? state,
    DateTime? since,
    String? lastError,
    int? retryCount,
    DateTime? nextRetryAt,
    DateTime? cooldownUntil,
    bool clearLastError = false,
    bool clearNextRetryAt = false,
    bool clearCooldownUntil = false,
  }) {
    return BridgeHealth(
      state: state ?? this.state,
      since: since ?? this.since,
      lastError: clearLastError ? null : (lastError ?? this.lastError),
      retryCount: retryCount ?? this.retryCount,
      nextRetryAt: clearNextRetryAt ? null : (nextRetryAt ?? this.nextRetryAt),
      cooldownUntil:
          clearCooldownUntil ? null : (cooldownUntil ?? this.cooldownUntil),
    );
  }

  /// Serialize model to JSON Map.
  Map<String, dynamic> toJson() {
    return {
      'state': state.name,
      'since': since.toIso8601String(),
      'lastError': lastError,
      'retryCount': retryCount,
      'nextRetryAt': nextRetryAt?.toIso8601String(),
      'cooldownUntil': cooldownUntil?.toIso8601String(),
    };
  }

  /// Deserialize model from JSON Map.
  factory BridgeHealth.fromJson(Map<String, dynamic> json) {
    final stateStr = json['state'] as String? ?? 'connected';
    final stateEnum = BridgeConnectionState.values.firstWhere(
      (e) => e.name == stateStr,
      orElse: () => BridgeConnectionState.connected,
    );

    return BridgeHealth(
      state: stateEnum,
      since: json['since'] != null
          ? DateTime.parse(json['since'] as String)
          : DateTime.now(),
      lastError: json['lastError'] as String?,
      retryCount: json['retryCount'] as int? ?? 0,
      nextRetryAt: json['nextRetryAt'] != null
          ? DateTime.parse(json['nextRetryAt'] as String)
          : null,
      cooldownUntil: json['cooldownUntil'] != null
          ? DateTime.parse(json['cooldownUntil'] as String)
          : null,
    );
  }

  /// Returns remaining rate-limit cooldown duration, or Duration.zero if expired/null.
  Duration get remainingCooldown {
    if (cooldownUntil == null) return Duration.zero;
    final diff = cooldownUntil!.difference(DateTime.now());
    return diff.isNegative ? Duration.zero : diff;
  }

  /// Helper flag checking if the connection is currently in cooldown.
  bool get isThrottled => remainingCooldown > Duration.zero;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is BridgeHealth &&
        other.state == state &&
        other.since == since &&
        other.lastError == lastError &&
        other.retryCount == retryCount &&
        other.nextRetryAt == nextRetryAt &&
        other.cooldownUntil == cooldownUntil;
  }

  @override
  int get hashCode {
    return Object.hash(
      state,
      since,
      lastError,
      retryCount,
      nextRetryAt,
      cooldownUntil,
    );
  }

  @override
  String toString() {
    return 'BridgeHealth(state: ${state.name}, since: $since, retryCount: $retryCount, lastError: $lastError, nextRetryAt: $nextRetryAt, cooldownUntil: $cooldownUntil)';
  }
}
