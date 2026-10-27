# Migration Guide: Bridge Connection Health System

This guide outlines how to migrate existing network status handlers in Allora from the legacy boolean `connected` flag to the enterprise **Bridge Connection Health System**.

---

## 1. Data Model Upgrades

### Before (Boolean connected cache):
```dart
final snap = NetworkConnectionCache.get(NetworkId.whatsapp);
final bool isConnected = snap.connected;
```

### After (`BridgeHealth` state machine):
```dart
final health = ref.watch(bridgeHealthProvider('whatsapp'));
final BridgeConnectionState state = health.state;

if (state == BridgeConnectionState.connected) {
  // Directly operational
} else if (state == BridgeConnectionState.reconnecting) {
  // Silent background exponential backoff
}
```

---

## 2. Avatar & UI Badge Indicators

Replace standard status dots with `BridgeStatusDot`:
```dart
BridgeStatusDot(
  state: ref.watch(bridgeHealthProvider('whatsapp')).state,
  size: 14.0,
)
```

---

## 3. Chat Banners

Add `BridgeStatusBanner` to chat screen headers:
```dart
BridgeStatusBanner(
  networkName: 'WhatsApp',
  health: ref.watch(bridgeHealthProvider('whatsapp')),
  onTapReconnect: () => openQrPairingFlow(context),
)
```

---

## 4. Message Composition & Offline Outbox

Wrap message composer inputs with `BridgeMessageComposerWrapper`:
```dart
BridgeMessageComposerWrapper(
  accountId: 'whatsapp',
  roomId: room.id,
  composerBuilder: (context, onSendMessage) => CustomComposerWidget(
    onSend: (text) async {
      final success = await onSendMessage(text);
      if (success) clearInput();
    },
  ),
)
```
