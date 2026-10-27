# Allora Messenger

One inbox for every conversation. WhatsApp, Telegram, Instagram, Messenger,
Discord, Slack and X — bridged over Matrix into a single, fast, private app.

## Architecture (v2)

```
lib/
├── main.dart                  # bootstrap: parallel init, auth, service startup
├── background_wiper.dart      # Workmanager fallback executor (wipe + scheduled sends)
├── core/                      # design system & shared building blocks
│   ├── theme/                 # AlloraColors tokens, light/dark ThemeData, accents
│   ├── utils/                 # time formatting, stream throttling (pure, tested)
│   └── widgets/               # avatar, skeletons, empty states, link text
├── data/
│   ├── settings/              # persisted AppSettings (Riverpod StateNotifier)
│   └── services/
│       ├── connection_manager.dart      # stream-driven Matrix + bridge states
│       ├── account_lifecycle.dart       # THE disconnect path for every network
│       ├── room_wipe_service.dart       # instant foreground wipe + resumable queue
│       ├── ai_service.dart              # server-backed Allora AI client
│       ├── scheduled_message_service.dart
│       └── disappearing_message_service.dart
├── features/
│   ├── chat_list/             # redesigned inbox (filters, swipes, sections)
│   ├── chat/                  # redesigned chat screen (bubbles, reactions, menu…)
│   ├── ai/                    # assistant sheet + Allora AI conversation
│   ├── settings/              # settings hub + sub-screens
│   ├── privacy/               # app lock (PIN/biometric), FLAG_SECURE bridge
│   └── search/                # global search (chats/messages/media/links)
├── providers/                 # matrixClientProvider, network hub state
└── screens/                   # auth + per-network connect flows (bridge commands)
```

State management is **Riverpod** end-to-end. Widgets contain no business
logic: list composition, connection states, disconnect flows and AI calls
all live in `data/` providers & services.

## Key behaviours

* **Disconnect really disconnects.** `AccountLifecycleService` sends the
  bridge `logout`, sticky-marks the network disconnected, and hands every
  portal room to `RoomWipeService`, which removes them **in the foreground,
  instantly** — the UI updates in the same frame. A Workmanager job only
  finishes what a process kill interrupted. If no bridge bot is reachable,
  the app says so honestly: *"Your Allora connection has been removed. You
  may still be logged into the official application."*
* **Live connection status.** `ConnectionManager` maps the Matrix SDK's
  sync stream to `connecting / connected / syncing / reconnecting /
  disconnected / expired / error` with zero polling.
* **AI without shipped keys.** All AI goes through the
  `supabase/functions/allora-ai` edge function (deploy it + set
  `ANTHROPIC_API_KEY`). Until then the app shows a clear "AI unreachable"
  message instead of fake responses.
* **Privacy & Incognito Mode.**
  * **Incognito mode ON:** Sets online presence to offline (sender sees single tick on official apps), hides read receipts, hides typing indicator, blocks screenshots, and pauses AI history.
  * **Delivery ticks:** Single tick when recipient is offline, double tick when recipient is online but has not opened the message, and purple double tick when opened.
  * **App lock & Hidden chats:** Secure chats behind PIN or biometrics, and set disappearing message timers per chat.

## Building

```bash
flutter pub get        # fetches the two new deps: image_picker, local_auth
flutter test
flutter build appbundle
```

See **PLAYSTORE.md** for the release checklist (signing, provisioning
hardening, store listing notes).
