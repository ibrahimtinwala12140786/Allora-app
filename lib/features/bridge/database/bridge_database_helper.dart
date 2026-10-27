import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import '../models/bridge_connection_state.dart';
import '../models/bridge_health.dart';

/// SQLite Database Helper for local bridge persistence: Outbox queue, Audit logs,
/// and Health state cache for instantaneous cold launch rendering.
class BridgeDatabaseHelper {
  static final BridgeDatabaseHelper instance = BridgeDatabaseHelper._internal();
  static Database? _database;

  BridgeDatabaseHelper._internal();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final dir = await getApplicationSupportDirectory();
    final dbPath = join(dir.path, 'allora_bridge_health.db');

    return await openDatabase(
      dbPath,
      version: 1,
      onCreate: (db, version) async {
        // Table 1: Outbox Queue
        await db.execute('''
          CREATE TABLE bridge_outbox (
            id TEXT PRIMARY KEY,
            roomId TEXT NOT NULL,
            message TEXT NOT NULL,
            createdAt TEXT NOT NULL,
            status TEXT NOT NULL,
            retryCount INTEGER NOT NULL DEFAULT 0,
            accountId TEXT NOT NULL
          )
        ''');

        // Table 2: Audit Logs
        await db.execute('''
          CREATE TABLE bridge_audit_logs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            account_id TEXT NOT NULL,
            from_state TEXT NOT NULL,
            to_state TEXT NOT NULL,
            reason TEXT,
            occurred_at TEXT NOT NULL,
            device_id TEXT NOT NULL
          )
        ''');

        // Table 3: Bridge Health Local Cache
        await db.execute('''
          CREATE TABLE bridge_health_cache (
            account_id TEXT PRIMARY KEY,
            state TEXT NOT NULL,
            since TEXT NOT NULL,
            last_error TEXT,
            retry_count INTEGER NOT NULL DEFAULT 0,
            next_retry_at TEXT,
            cooldown_until TEXT,
            updated_at TEXT NOT NULL
          )
        ''');
      },
    );
  }

  // ── Health Cache ──────────────────────────────────────────────────────────

  /// Persists the latest [BridgeHealth] state for an account.
  Future<void> saveBridgeHealth(String accountId, BridgeHealth health) async {
    try {
      final db = await database;
      await db.insert(
        'bridge_health_cache',
        {
          'account_id': accountId,
          'state': health.state.name,
          'since': health.since.toIso8601String(),
          'last_error': health.lastError,
          'retry_count': health.retryCount,
          'next_retry_at': health.nextRetryAt?.toIso8601String(),
          'cooldown_until': health.cooldownUntil?.toIso8601String(),
          'updated_at': DateTime.now().toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (e) {
      debugPrint('BridgeDatabaseHelper: saveBridgeHealth failed: $e');
    }
  }

  /// Retrieves the cached [BridgeHealth] state for instant cold app launches.
  Future<BridgeHealth?> getBridgeHealth(String accountId) async {
    try {
      final db = await database;
      final rows = await db.query(
        'bridge_health_cache',
        where: 'account_id = ?',
        whereArgs: [accountId],
      );

      if (rows.isEmpty) return null;
      final row = rows.first;

      final stateEnum = BridgeConnectionState.values.firstWhere(
        (e) => e.name == row['state'],
        orElse: () => BridgeConnectionState.connected,
      );

      return BridgeHealth(
        state: stateEnum,
        since: DateTime.parse(row['since'] as String),
        lastError: row['last_error'] as String?,
        retryCount: row['retry_count'] as int? ?? 0,
        nextRetryAt: row['next_retry_at'] != null
            ? DateTime.parse(row['next_retry_at'] as String)
            : null,
        cooldownUntil: row['cooldown_until'] != null
            ? DateTime.parse(row['cooldown_until'] as String)
            : null,
      );
    } catch (e) {
      debugPrint('BridgeDatabaseHelper: getBridgeHealth failed: $e');
      return null;
    }
  }

  // ── Audit Logs ─────────────────────────────────────────────────────────────

  /// Logs a state transition to `bridge_audit_logs`.
  Future<void> insertAuditLog({
    required String accountId,
    required BridgeConnectionState fromState,
    required BridgeConnectionState toState,
    String? reason,
    required String deviceId,
  }) async {
    try {
      final db = await database;
      await db.insert('bridge_audit_logs', {
        'account_id': accountId,
        'from_state': fromState.name,
        'to_state': toState.name,
        'reason': reason,
        'occurred_at': DateTime.now().toIso8601String(),
        'device_id': deviceId,
      });
    } catch (e) {
      debugPrint('BridgeDatabaseHelper: insertAuditLog failed: $e');
    }
  }

  /// Fetches recent audit logs for an account.
  Future<List<Map<String, dynamic>>> getAuditLogs(String accountId, {int limit = 50}) async {
    try {
      final db = await database;
      return await db.query(
        'bridge_audit_logs',
        where: 'account_id = ?',
        whereArgs: [accountId],
        orderBy: 'id DESC',
        limit: limit,
      );
    } catch (e) {
      debugPrint('BridgeDatabaseHelper: getAuditLogs failed: $e');
      return [];
    }
  }

  // ── Outbox ─────────────────────────────────────────────────────────────────

  /// Inserts a message into the SQLite outbox queue.
  Future<void> enqueueOutboxMessage({
    required String id,
    required String roomId,
    required String message,
    required String accountId,
  }) async {
    try {
      final db = await database;
      await db.insert(
        'bridge_outbox',
        {
          'id': id,
          'roomId': roomId,
          'message': message,
          'createdAt': DateTime.now().toIso8601String(),
          'status': 'queued',
          'retryCount': 0,
          'accountId': accountId,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    } catch (e) {
      debugPrint('BridgeDatabaseHelper: enqueueOutboxMessage failed: $e');
    }
  }

  /// Retrieves pending queued messages for an account ordered by creation time.
  Future<List<Map<String, dynamic>>> getPendingOutbox(String accountId) async {
    try {
      final db = await database;
      return await db.query(
        'bridge_outbox',
        where: 'accountId = ? AND (status = ? OR status = ?)',
        whereArgs: [accountId, 'queued', 'failed'],
        orderBy: 'createdAt ASC',
      );
    } catch (e) {
      debugPrint('BridgeDatabaseHelper: getPendingOutbox failed: $e');
      return [];
    }
  }

  /// Updates outbox message status and retry count.
  Future<void> updateOutboxStatus(String id, String status, {int? retryCount}) async {
    try {
      final db = await database;
      final values = <String, dynamic>{'status': status};
      if (retryCount != null) values['retryCount'] = retryCount;
      await db.update(
        'bridge_outbox',
        values,
        where: 'id = ?',
        whereArgs: [id],
      );
    } catch (e) {
      debugPrint('BridgeDatabaseHelper: updateOutboxStatus failed: $e');
    }
  }

  /// Deletes a successfully sent message from the outbox.
  Future<void> deleteOutboxMessage(String id) async {
    try {
      final db = await database;
      await db.delete(
        'bridge_outbox',
        where: 'id = ?',
        whereArgs: [id],
      );
    } catch (e) {
      debugPrint('BridgeDatabaseHelper: deleteOutboxMessage failed: $e');
    }
  }
}
