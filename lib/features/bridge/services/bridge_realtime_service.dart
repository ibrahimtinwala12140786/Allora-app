import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:realtime_client/src/types.dart' show RealtimeListenTypes;
import '../database/bridge_database_helper.dart';
import '../models/bridge_connection_state.dart';
import '../models/bridge_health.dart';

/// Handles multi-device instant synchronization using Supabase Realtime channels
/// and records structured audit log entries into SQLite.
class BridgeRealtimeService {
  final BridgeDatabaseHelper _db;
  final SupabaseClient? _supabase;
  RealtimeChannel? _channel;
  StreamSubscription? _sub;

  BridgeRealtimeService({
    BridgeDatabaseHelper? db,
    SupabaseClient? supabase,
  })  : _db = db ?? BridgeDatabaseHelper.instance,
        _supabase = supabase ?? _safeGetSupabase();

  static SupabaseClient? _safeGetSupabase() {
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  /// Broadcasts a state change across all signed-in devices using Supabase Realtime,
  /// and writes an audit log entry locally.
  Future<void> broadcastStateChange({
    required String accountId,
    required BridgeConnectionState fromState,
    required BridgeHealth toHealth,
    String? reason,
    required String deviceId,
  }) async {
    // 1. Write local audit log
    await _db.insertAuditLog(
      accountId: accountId,
      fromState: fromState,
      toState: toHealth.state,
      reason: reason ?? toHealth.lastError,
      deviceId: deviceId,
    );

    // 2. Broadcast via Supabase Realtime
    if (_supabase != null) {
      try {
        final channelName = 'bridge_health:$accountId';
        final channel = _supabase!.channel(channelName);
        await channel.subscribe();
        await channel.send(
          type: RealtimeListenTypes.broadcast,
          event: 'state_changed',
          payload: {
            'accountId': accountId,
            'fromState': fromState.name,
            'health': toHealth.toJson(),
            'reason': reason,
            'deviceId': deviceId,
            'timestamp': DateTime.now().toIso8601String(),
          },
        );
      } catch (e) {
        debugPrint('BridgeRealtimeService: Supabase Realtime broadcast suppressed: $e');
      }
    }
  }

  /// Subscribes to state updates broadcast by other devices.
  void subscribeToRealtimeUpdates({
    required String accountId,
    required void Function(BridgeHealth health) onRemoteUpdate,
  }) {
    final client = _supabase;
    if (client == null) return;

    try {
      final channelName = 'bridge_health:$accountId';
      final channel = client.channel(channelName);
      _channel = channel;

      channel.onBroadcast(
        event: 'state_changed',
        callback: (payload) {
          try {
            final healthJson = payload['health'] as Map<String, dynamic>?;
            if (healthJson != null) {
              final health = BridgeHealth.fromJson(healthJson);
              onRemoteUpdate(health);
            }
          } catch (e) {
            debugPrint('BridgeRealtimeService: error parsing remote health payload: $e');
          }
        },
      );

      channel.subscribe();
    } catch (e) {
      debugPrint('BridgeRealtimeService: Realtime subscription failed: $e');
    }
  }

  /// Disposes active Realtime channel subscriptions.
  Future<void> dispose() async {
    await _sub?.cancel();
    final channel = _channel;
    final client = _supabase;
    if (channel != null && client != null) {
      try {
        await client.removeChannel(channel);
      } catch (_) {}
    }
  }
}
