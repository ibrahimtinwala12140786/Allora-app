import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import '../database/bridge_database_helper.dart';

class OutboxMessage {
  final String id;
  final String roomId;
  final String message;
  final DateTime createdAt;
  final String status;
  final int retryCount;
  final String accountId;

  const OutboxMessage({
    required this.id,
    required this.roomId,
    required this.message,
    required this.createdAt,
    required this.status,
    required this.retryCount,
    required this.accountId,
  });

  factory OutboxMessage.fromMap(Map<String, dynamic> map) {
    return OutboxMessage(
      id: map['id'] as String,
      roomId: map['roomId'] as String,
      message: map['message'] as String,
      createdAt: DateTime.parse(map['createdAt'] as String),
      status: map['status'] as String,
      retryCount: map['retryCount'] as int? ?? 0,
      accountId: map['accountId'] as String,
    );
  }
}

/// Outbox Repository managing queued messages for offline/reconnecting scenarios.
class BridgeOutboxRepository {
  final BridgeDatabaseHelper _db;

  BridgeOutboxRepository({BridgeDatabaseHelper? db})
      : _db = db ?? BridgeDatabaseHelper.instance;

  /// Enqueue a message to send when connection recovers.
  Future<void> enqueueMessage({
    required String id,
    required String roomId,
    required String message,
    required String accountId,
  }) async {
    await _db.enqueueOutboxMessage(
      id: id,
      roomId: roomId,
      message: message,
      accountId: accountId,
    );
    debugPrint('BridgeOutboxRepository: Enqueued message $id for room $roomId');
  }

  /// Get pending queued messages for an account in strict creation order.
  Future<List<OutboxMessage>> getPendingMessages(String accountId) async {
    final list = await _db.getPendingOutbox(accountId);
    return list.map((m) => OutboxMessage.fromMap(m)).toList();
  }

  /// Sequential outbox flush when bridge transitions to Connected.
  Future<int> flushOutbox({
    required String accountId,
    required Client client,
  }) async {
    final pending = await getPendingMessages(accountId);
    if (pending.isEmpty) return 0;

    int successCount = 0;
    debugPrint('BridgeOutboxRepository: Flushing ${pending.length} queued messages for $accountId');

    for (final item in pending) {
      try {
        await _db.updateOutboxStatus(item.id, 'sending');
        final room = client.getRoomById(item.roomId);
        if (room != null && room.membership == Membership.join) {
          // Only send if we are still a joined member.  After a bridge kick
          // ("User is not in remote chat") the room membership becomes leave/ban
          // and sending would throw a 403, keeping this loop retrying forever.
          await room.sendTextEvent(item.message);
          await _db.deleteOutboxMessage(item.id);
          successCount++;
          debugPrint('BridgeOutboxRepository: Successfully delivered queued message ${item.id}');
        } else {
          // Room not found, or we've been kicked — skip this message.
          await _db.updateOutboxStatus(item.id, 'failed', retryCount: item.retryCount + 1);
          debugPrint(
              'BridgeOutboxRepository: Skipped message ${item.id} — '
              'room not joined (membership: ${room?.membership})');
        }
      } catch (e) {
        debugPrint('BridgeOutboxRepository: Failed to flush message ${item.id}: $e');
        await _db.updateOutboxStatus(
          item.id,
          'failed',
          retryCount: item.retryCount + 1,
        );
      }
    }

    return successCount;
  }
}
