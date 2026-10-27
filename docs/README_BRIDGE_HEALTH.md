# Enterprise Bridge Connection Health System

The Bridge Connection Health System provides enterprise-grade connection monitoring, silent exponential backoff retries, rate-limiting policies, local SQLite outbox queueing, and Supabase Realtime multi-device synchronization for Allora.

---

## Key Features

1. **State Machine (`BridgeConnectionState`)**:
   - `connected`: Operational bridge.
   - `reconnecting`: Silent exponential backoff retry engine (2s, 5s, 15s, 40s, 90s with ±20% jitter). Max 5 retries.
   - `needsLogin`: Session unlinked / credentials expired. Requires explicit QR/pair scan.
   - `rateLimited`: Throttled connection with enforced cooldown schedule (30m, 1h, 2h, 6h, 12h) and countdown display.
   - `bridgeUnreachable`: Daemon or Matrix server unreachable.

2. **SQLite Local Outbox**:
   - Queues outgoing messages when bridge is reconnecting or unreachable.
   - Auto-flushes sequentially over Matrix SDK upon state restoration.
   - Prevents duplicate sends and preserves message ordering.

3. **Supabase Realtime Sync & Audit Logs**:
   - Broadcasts state transitions across all signed-in devices using Supabase Realtime channels.
   - Writes structured audit logs into SQLite `bridge_audit_logs`.

4. **UI Components**:
   - `BridgeStatusDot`: Animated pulsing dot for avatars.
   - `BridgeStatusBanner`: Actionable top banner for `needsLogin`, `rateLimited`, and `bridgeUnreachable`.
   - `AccountHealthCard`: Detailed diagnostic telemetry for Account Settings.
   - `RemoveAccountDialog`: Modal dialog enforcing admin/owner permissions for shared accounts.

---

## Folder Architecture

```
lib/features/bridge/
├── database/
│   └── bridge_database_helper.dart
├── models/
│   ├── bridge_connection_state.dart
│   ├── bridge_health.dart
│   └── mautrix_event_mapper.dart
├── providers/
│   └── bridge_health_provider.dart
├── services/
│   ├── admin_bridge_support_model.dart
│   ├── bridge_notification_service.dart
│   ├── bridge_outbox_repository.dart
│   └── bridge_realtime_service.dart
└── widgets/
    ├── account_health_card.dart
    ├── bridge_message_composer_wrapper.dart
    ├── bridge_status_banner.dart
    ├── bridge_status_dot.dart
    └── remove_account_dialog.dart
```
