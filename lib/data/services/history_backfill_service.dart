import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

import '../../screens/bridge/bridge_room_classifier.dart';

/// Background service to paginate and prefetch complete message histories
/// for all contact and direct chats from the Matrix homeserver into local storage.
class HistoryBackfillService {
  HistoryBackfillService._();

  static Client? _client;
  static bool _running = false;
  static final Set<String> _completedRooms = {};

  /// Starts the backfill worker.
  static void start(Client client) {
    _client = client;
    // Trigger lightweight initial backfill in background after startup
    Future.delayed(const Duration(seconds: 4), () {
      backfillAllRooms();
    });
  }

  /// Backfill history gently for all joined direct and contact rooms without blocking UI.
  static Future<void> backfillAllRooms({int maxBatchesPerRoom = 3}) async {
    final client = _client;
    if (client == null || _running || !client.isLogged()) return;
    _running = true;

    try {
      final rooms = client.rooms
          .where((r) =>
              r.membership == Membership.join &&
              !r.isSpace &&
              !BridgeRoomClassifier.isManagementRoom(r, client: client))
          .toList();

      for (final room in rooms) {
        if (_completedRooms.contains(room.id)) continue;
        await backfillRoom(room, maxBatches: maxBatchesPerRoom);
        // Generous delay between rooms to keep UI thread 100% smooth
        await Future.delayed(const Duration(milliseconds: 300));
      }
    } catch (e) {
      debugPrint('HistoryBackfillService: backfill failed: $e');
    } finally {
      _running = false;
    }
  }

  /// Backfills history for a single room gently.
  static Future<void> backfillRoom(Room room, {int maxBatches = 3}) async {
    try {
      final timeline = await room.getTimeline();
      int batches = 0;
      while (timeline.canRequestHistory && batches < maxBatches) {
        final countBefore = timeline.events.length;
        await timeline.requestHistory(historyCount: 30);
        if (timeline.events.length == countBefore || !timeline.canRequestHistory) {
          _completedRooms.add(room.id);
          break;
        }
        batches++;
        await Future.delayed(const Duration(milliseconds: 100));
      }
      _completedRooms.add(room.id);
    } catch (e) {
      _completedRooms.add(room.id);
      debugPrint('HistoryBackfillService: error backfilling room ${room.id}: $e');
    }
  }
}
