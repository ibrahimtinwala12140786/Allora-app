import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/bridge_database_helper.dart';
import '../models/bridge_connection_state.dart';
import '../models/bridge_health.dart';
import '../models/mautrix_event_mapper.dart';
import '../services/bridge_outbox_repository.dart';
import '../services/bridge_realtime_service.dart';

/// Reconnection retry schedule: 2s, 5s, 15s, 40s, 90s
const List<Duration> kReconnectionSchedule = [
  Duration(seconds: 2),
  Duration(seconds: 5),
  Duration(seconds: 15),
  Duration(seconds: 40),
  Duration(seconds: 90),
];

/// Rate limit backoff schedule: 30m, 1h, 2h, 6h, 12h
const List<Duration> kRateLimitSchedule = [
  Duration(minutes: 30),
  Duration(hours: 1),
  Duration(hours: 2),
  Duration(hours: 6),
  Duration(hours: 12),
];

/// StateNotifier responsible for managing BridgeHealth state transitions,
/// silent exponential backoff retries with random jitter, rate-limiting policy,
/// cold launch cache hydration, and multi-device realtime broadcasting.
class BridgeHealthNotifier extends StateNotifier<BridgeHealth> {
  final String accountId;
  final BridgeDatabaseHelper _db;
  final BridgeOutboxRepository _outboxRepo;
  final BridgeRealtimeService _realtimeService;

  Timer? _retryTimer;
  Timer? _cooldownTimer;
  final Random _random = Random();
  int _rateLimitLevel = 0;
  bool _isHydrated = false;

  BridgeHealthNotifier({
    required this.accountId,
    BridgeDatabaseHelper? db,
    BridgeOutboxRepository? outboxRepo,
    BridgeRealtimeService? realtimeService,
  })  : _db = db ?? BridgeDatabaseHelper.instance,
        _outboxRepo = outboxRepo ?? BridgeOutboxRepository(),
        _realtimeService = realtimeService ?? BridgeRealtimeService(),
        super(BridgeHealth.connected()) {
    _initAndHydrate();
  }

  /// Hydrate cold state from SQLite DB to eliminate flashing disconnected.
  Future<void> _initAndHydrate() async {
    final cached = await _db.getBridgeHealth(accountId);
    if (cached != null && mounted) {
      state = cached;
      _isHydrated = true;
    }

    _realtimeService.subscribeToRealtimeUpdates(
      accountId: accountId,
      onRemoteUpdate: (remoteHealth) {
        if (mounted && remoteHealth != state) {
          state = remoteHealth;
          _db.saveBridgeHealth(accountId, state);
        }
      },
    );
  }

  /// Signal that the bridge has disconnected silently.
  void noteDisconnect({String? reason}) {
    if (state.state == BridgeConnectionState.rateLimited && state.isThrottled) {
      debugPrint('BridgeHealthNotifier($accountId): Retries blocked by rate limit cooldown');
      return;
    }

    // Immediately enter reconnecting without showing an error
    final prevState = state.state;
    state = state.copyWith(
      state: BridgeConnectionState.reconnecting,
      since: DateTime.now(),
      retryCount: 1,
      lastError: reason,
    );

    _persistAndBroadcast(fromState: prevState, reason: reason);
    _scheduleSilentRetry();
  }

  /// Manually trigger or handle a retry attempt.
  void _scheduleSilentRetry() {
    _retryTimer?.cancel();

    if (state.retryCount > kReconnectionSchedule.length) {
      _exhaustRetries();
      return;
    }

    final baseDelay = kReconnectionSchedule[(state.retryCount - 1).clamp(0, kReconnectionSchedule.length - 1)];

    // Add ±20% random jitter to delay
    final jitterFactor = 0.8 + (_random.nextDouble() * 0.4); // 0.80..1.20
    final jitteredMs = (baseDelay.inMilliseconds * jitterFactor).round();
    final nextDelay = Duration(milliseconds: jitteredMs);

    final nextRetryTime = DateTime.now().add(nextDelay);
    state = state.copyWith(nextRetryAt: nextRetryTime);

    debugPrint('BridgeHealthNotifier($accountId): Silent retry #${state.retryCount} scheduled in ${nextDelay.inSeconds}s (jittered)');

    _retryTimer = Timer(nextDelay, () => performRetryAttempt());
  }

  /// Performs a retry attempt. Can be called automatically by timer or manually by UI.
  Future<void> performRetryAttempt({Future<bool> Function()? pingProbe}) async {
    _retryTimer?.cancel();

    if (state.state == BridgeConnectionState.rateLimited && state.isThrottled) {
      debugPrint('BridgeHealthNotifier($accountId): Manual retry rejected due to active cooldown');
      return;
    }

    debugPrint('BridgeHealthNotifier($accountId): Executing retry attempt #${state.retryCount}...');

    bool success = false;
    if (pingProbe != null) {
      try {
        success = await pingProbe();
      } catch (e) {
        success = false;
      }
    }

    if (success) {
      markConnected();
    } else {
      final nextCount = state.retryCount + 1;
      if (nextCount > 5) {
        _exhaustRetries();
      } else {
        state = state.copyWith(retryCount: nextCount);
        _scheduleSilentRetry();
      }
    }
  }

  /// Retries exhausted after 5 attempts -> transition state based on reason.
  void _exhaustRetries() {
    final prevState = state.state;
    final lastReason = state.lastError;
    final targetState = MautrixEventMapper.mapState(lastReason);

    final finalState = targetState == BridgeConnectionState.connected
        ? BridgeConnectionState.bridgeUnreachable
        : targetState;

    state = state.copyWith(
      state: finalState,
      clearNextRetryAt: true,
    );

    _persistAndBroadcast(fromState: prevState, reason: 'Retries exhausted: $lastReason');
  }

  /// Handle Throttled / Rate Limited state report from bridge server.
  void noteRateLimited({String? reason}) {
    _retryTimer?.cancel();

    final cooldownDuration = kRateLimitSchedule[_rateLimitLevel.clamp(0, kRateLimitSchedule.length - 1)];
    _rateLimitLevel = (_rateLimitLevel + 1).clamp(0, kRateLimitSchedule.length - 1);

    final cooldownUntil = DateTime.now().add(cooldownDuration);
    final prevState = state.state;

    state = state.copyWith(
      state: BridgeConnectionState.rateLimited,
      cooldownUntil: cooldownUntil,
      lastError: reason ?? 'Throttled by platform server',
      clearNextRetryAt: true,
    );

    _persistAndBroadcast(fromState: prevState, reason: reason);

    _cooldownTimer?.cancel();
    _cooldownTimer = Timer(cooldownDuration, () {
      if (mounted) {
        state = state.copyWith(clearCooldownUntil: true);
        noteDisconnect(reason: 'Cooldown expired — attempting reconnect');
      }
    });
  }

  /// Mark connection restored to Connected.
  void markConnected() {
    _retryTimer?.cancel();
    _cooldownTimer?.cancel();
    _rateLimitLevel = 0;

    final prevState = state.state;

    state = BridgeHealth(
      state: BridgeConnectionState.connected,
      since: DateTime.now(),
      retryCount: 0,
      lastError: null,
    );

    _persistAndBroadcast(fromState: prevState);
  }

  /// Directly set a bridge state based on incoming event string.
  void updateFromEvent(String rawEvent, {String? body}) {
    final mapped = MautrixEventMapper.mapState(rawEvent);
    final reason = MautrixEventMapper.extractReason(body);

    if (mapped == BridgeConnectionState.connected) {
      markConnected();
    } else if (mapped == BridgeConnectionState.rateLimited) {
      noteRateLimited(reason: reason);
    } else if (mapped == BridgeConnectionState.reconnecting) {
      noteDisconnect(reason: reason);
    } else {
      final prevState = state.state;
      state = state.copyWith(
        state: mapped,
        lastError: reason,
        clearNextRetryAt: true,
      );
      _persistAndBroadcast(fromState: prevState, reason: reason);
    }
  }

  void _persistAndBroadcast({required BridgeConnectionState fromState, String? reason}) {
    _db.saveBridgeHealth(accountId, state);
    _realtimeService.broadcastStateChange(
      accountId: accountId,
      fromState: fromState,
      toHealth: state,
      reason: reason,
      deviceId: 'device_${accountId_hashCode(accountId)}',
    );
  }

  int accountId_hashCode(String s) => s.hashCode.abs();

  @override
  void dispose() {
    _retryTimer?.cancel();
    _cooldownTimer?.cancel();
    _realtimeService.dispose();
    super.dispose();
  }
}

/// Family Provider mapping account ID (e.g. 'whatsapp', 'telegram') to its BridgeHealth state machine.
final bridgeHealthProvider =
    StateNotifierProvider.family<BridgeHealthNotifier, BridgeHealth, String>(
  (ref, accountId) => BridgeHealthNotifier(accountId: accountId),
);
