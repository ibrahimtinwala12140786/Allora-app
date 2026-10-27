import 'package:flutter/material.dart';

/// Comprehensive connection state machine enum for social media bridge connections.
enum BridgeConnectionState {
  /// Active and fully operational bridge connection.
  connected,

  /// Bridge lost connection; engine is silently performing exponential backoff retries.
  reconnecting,

  /// Credentials expired or unlinked; user input/login required (e.g. QR code scan).
  needsLogin,

  /// Bridge server throttled connection; backoff schedule enforced.
  rateLimited,

  /// Bridge daemon or Matrix server unreachable.
  bridgeUnreachable,
}

extension BridgeConnectionStateX on BridgeConnectionState {
  /// Human readable status description.
  String get label {
    switch (this) {
      case BridgeConnectionState.connected:
        return 'Connected';
      case BridgeConnectionState.reconnecting:
        return 'Reconnecting…';
      case BridgeConnectionState.needsLogin:
        return 'Needs Login';
      case BridgeConnectionState.rateLimited:
        return 'Rate Limited';
      case BridgeConnectionState.bridgeUnreachable:
        return 'Bridge Unreachable';
    }
  }

  /// UI Color representation for badges, status dots, and banners.
  Color get statusColor {
    switch (this) {
      case BridgeConnectionState.connected:
        return const Color(0xFF10B981); // Emerald Green
      case BridgeConnectionState.reconnecting:
        return const Color(0xFFF59E0B); // Amber / Orange
      case BridgeConnectionState.needsLogin:
      case BridgeConnectionState.rateLimited:
      case BridgeConnectionState.bridgeUnreachable:
        return const Color(0xFFEF4444); // Crimson Red
    }
  }

  /// Whether the connection state requires an actionable warning banner.
  bool get showBanner {
    switch (this) {
      case BridgeConnectionState.needsLogin:
      case BridgeConnectionState.rateLimited:
      case BridgeConnectionState.bridgeUnreachable:
        return true;
      case BridgeConnectionState.connected:
      case BridgeConnectionState.reconnecting:
        return false;
    }
  }

  /// Whether direct sending over Matrix SDK is available immediately.
  bool get canSendDirectly => this == BridgeConnectionState.connected;

  /// Whether messages should be queued locally in SQLite Outbox.
  bool get shouldQueueOutbox =>
      this == BridgeConnectionState.reconnecting ||
      this == BridgeConnectionState.bridgeUnreachable;

  /// Whether draft message saving should be enforced due to auth or rate-limit blocks.
  bool get shouldSaveDraft =>
      this == BridgeConnectionState.needsLogin ||
      this == BridgeConnectionState.rateLimited;
}
