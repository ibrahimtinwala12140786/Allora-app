import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

import '../settings/app_settings.dart';

/// Disappearing messages, honestly implemented for Matrix:
///
///  * When a chat has a timer, we set the room's `m.room.retention` state
///    (best effort) so retention-aware servers purge history for everyone.
///  * Independently, a local sweeper redacts **your own** messages once they
///    exceed the timer. On Matrix you can only delete other people's
///    messages if you have moderation power in that room, so — exactly like
///    every bridge-based messenger — the guarantee applies to what you send.
///    The settings UI states this plainly instead of pretending otherwise.
///
/// Redaction removes the content from the server and (via sync) from every
/// local cache, notification and backup that follows the room state.
class DisappearingMessageService {
  DisappearingMessageService._();

  static Client? _client;
  static SettingsController? _settings;
  static Timer? _timer;
  static bool _sweeping = false;

  static const presets = <int, String>{
    0: 'Off',
    86400: '24 hours',
    604800: '7 days',
    2592000: '30 days',
    7776000: '90 days',
  };

  static String labelFor(int seconds) {
    if (seconds <= 0) return 'Off';
    final preset = presets[seconds];
    if (preset != null) return preset;
    if (seconds % 86400 == 0) return '${seconds ~/ 86400} days';
    if (seconds % 3600 == 0) return '${seconds ~/ 3600} hours';
    return '${(seconds / 60).ceil()} min';
  }

  static final Map<String, int> _cache = {};

  static void forget(String roomId) => _cache.remove(roomId);

  /// Scans timeline events for bridge system messages (like WhatsApp) that
  /// turn on/off disappearing messages, returning the active ttl in seconds (or -1 if none).
  static int detectBridgeTimerFromEvents(Iterable<Event> events) {
    for (final e in events.toList().reversed) {
      final text = e.body.toLowerCase();
      if (text.contains('disappearing message') ||
          text.contains('disappear from this chat') ||
          text.contains('disappearing messages') ||
          text.contains('message timer') ||
          text.contains('disappearing')) {
        if (text.contains('turned off') ||
            text.contains('disappearing messages off') ||
            text.contains('are off') ||
            text.contains('is off') ||
            text.contains('disabled') ||
            text.contains('removed') ||
            text.contains('turned off disappearing') ||
            text.contains('off')) {
          return 0;
        } else if (text.contains('24 hours') || text.contains('1 day')) {
          return 86400;
        } else if (text.contains('7 days') || text.contains('1 week')) {
          return 604800;
        } else if (text.contains('30 days') || text.contains('1 month')) {
          return 2592000;
        } else if (text.contains('90 days')) {
          return 7776000;
        }
      }
    }
    return -1;
  }

  /// Returns the effective disappearing timer in seconds for a room by checking:
  /// 1. Allora local setting (explicit choice, including Off = 0)
  /// 2. Recent bridge system messages in the timeline
  /// 3. Cached fallback value
  /// 4. Matrix retention state (m.room.retention)
  static int effectiveSeconds(Room room, {SettingsController? settings, Iterable<Event>? events}) {
    final cached = _cache[room.id];
    if (cached != null) return cached;

    final s = settings ?? _settings;
    try {
      if (s != null && s.mounted && s.state.disappearingSeconds.containsKey(room.id)) {
        final res = s.state.disappearingSeconds[room.id]!;
        _cache[room.id] = res;
        return res;
      }
    } catch (_) {}

    if (events != null) {
      final bridgeTtl = detectBridgeTimerFromEvents(events);
      if (bridgeTtl >= 0) {
        _cache[room.id] = bridgeTtl;
        return bridgeTtl;
      }
    } else {
      try {
        final last = room.lastEvent != null ? [room.lastEvent!] : <Event>[];
        final bridgeTtl = detectBridgeTimerFromEvents(last);
        if (bridgeTtl >= 0) {
          _cache[room.id] = bridgeTtl;
          return bridgeTtl;
        }
      } catch (_) {}
    }

    try {
      final ret = room.getState('m.room.retention');
      if (ret != null && ret.content['max_lifetime'] != null) {
        final maxLifetimeMs = (ret.content['max_lifetime'] as num).toInt();
        if (maxLifetimeMs >= 0) {
          final res = maxLifetimeMs ~/ 1000;
          _cache[room.id] = res;
          return res;
        }
      }
    } catch (_) {}

    _cache[room.id] = 0;
    return 0;
  }

  static void start(Client client, SettingsController settings) {
    _client = client;
    _settings = settings;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(minutes: 5), (_) => sweep());
    // First pass shortly after startup, once sync has caught up a bit.
    Timer(const Duration(seconds: 20), sweep);
  }

  static void shutdown() {
    _timer?.cancel();
    _timer = null;
    _cache.clear();
  }

  /// Apply a timer to a room: persist locally + best-effort server retention.
  static Future<void> setTimer(Room room, int seconds) async {
    final effective = seconds <= 0 ? 0 : seconds;
    _cache[room.id] = effective;
    _settings?.setDisappearing(room.id, effective);
    try {
      await room.client.setRoomStateWithKey(
        room.id,
        'm.room.retention',
        '',
        effective > 0
            ? {'max_lifetime': effective * 1000}
            : <String, Object?>{},
      );
    } catch (e) {
      // Bridged portals often deny state changes — the local sweeper still
      // enforces the timer for our own messages.
      debugPrint('Disappearing: retention state rejected for ${room.id}: $e');
    }
  }

  /// Redact own expired messages across all rooms with timers.
  static Future<void> sweep() async {
    if (_sweeping) return;
    final client = _client;
    final settings = _settings;
    if (client == null || settings == null || !client.isLogged()) return;

    _sweeping = true;
    try {
      for (final room in client.rooms) {
        final ttl = effectiveSeconds(room, settings: settings);
        if (ttl <= 0) continue;
        final cutoff =
            DateTime.now().subtract(Duration(seconds: ttl));

        Timeline? timeline;
        try {
          timeline = await room.getTimeline();
          // Only sweep what's loaded plus one history page — a bounded,
          // cheap pass that runs often instead of an expensive full crawl.
          if (timeline.canRequestHistory) {
            await timeline.requestHistory(historyCount: 50);
          }
          for (final event in List<Event>.from(timeline.events)) {
            if (event.senderId != client.userID) continue;
            if (event.type != EventTypes.Message) continue;
            if (event.redacted) continue;
            if (event.eventId.isEmpty || event.status.isSending) continue;
            if (event.originServerTs.isAfter(cutoff)) continue;
            try {
              await room.redactEvent(event.eventId);
              await Future.delayed(const Duration(milliseconds: 150));
            } on MatrixException catch (e) {
              if (e.errcode == 'M_LIMIT_EXCEEDED') {
                await Future.delayed(const Duration(seconds: 5));
              } else if (e.errcode == 'M_FORBIDDEN') {
                // Non-admin or room power levels forbid redaction — skip
                break;
              }
            } catch (_) {}
          }

        } catch (e) {
          debugPrint('Disappearing: sweep failed for ${room.id}: $e');
        }
      }
    } finally {
      _sweeping = false;
    }
  }
}
