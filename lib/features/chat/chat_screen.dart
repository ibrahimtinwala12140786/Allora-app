// ignore_for_file: deprecated_member_use
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:matrix/matrix.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/chat_time.dart';
import '../../core/utils/throttle.dart';
import '../../core/widgets/allora_avatar.dart';
import '../../data/services/account_lifecycle.dart';
import '../../data/services/ai_service.dart';
import '../../data/services/disappearing_message_service.dart';
import '../../data/settings/app_settings.dart';
import '../../screens/bridge/bridge_room_classifier.dart';
import '../../screens/connection_screen/connect_networks_screen.dart';
import '../../screens/networks/network_meta.dart';


import '../bridge/models/bridge_connection_state.dart';
import '../bridge/providers/bridge_health_provider.dart';
import '../bridge/widgets/bridge_status_banner.dart';
import '../../data/services/contacts_service.dart';

import '../ai/ai_assistant_sheet.dart';
import '../chat_list/chat_list_providers.dart';
import '../../providers/network_provider.dart';
import 'chat_details_screen.dart';
import '../../screens/voip_call_screen.dart';
import 'widgets/chat_input_bar.dart';
import 'widgets/disappearing_sheet.dart';
import 'widgets/emoji_picker_sheet.dart';
import 'widgets/forward_sheet.dart';
import 'widgets/message_bubble.dart';
import 'widgets/media_grid_bubble.dart';
import 'widgets/message_context_menu.dart';
import 'widgets/message_info_sheet.dart';
import 'widgets/typing_indicator_row.dart';
import '../../core/utils/chat_sound_service.dart';
import '../../core/services/notification_service.dart';

class ChatScreen extends ConsumerStatefulWidget {
  final Room room;
  const ChatScreen({super.key, required this.room});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  Timeline? _timeline;
  List<Event>? _cachedVisibleEvents;
  bool _loadFailed = false;
  final _scroll = ScrollController();
  final _inputKey = GlobalKey<ChatInputBarState>();

  Event? _replyTo;
  Event? _editing;
  final Set<String> _selected = {};
  final Set<String> _deletedEventIds = {};
  String? _highlightedId;
  Timer? _highlightTimer;

  int _unreadAtOpen = 0;
  bool _requestingHistory = false;
  bool _showJumpButton = false;

  // In-chat search
  bool _searchOpen = false;
  final _searchController = TextEditingController();
  List<Event> _matches = const [];
  int _matchIndex = 0;

  // Smart replies
  List<String> _smartReplies = const [];
  String? _smartRepliesForEvent;
  Timer? _smartReplyDebounce;
  static final Map<String, List<String>> _smartReplyCache = {};

  Room get room => widget.room;
  bool get _selectionMode => _selected.isNotEmpty;

  StreamSubscription? _syncSub;
  StreamSubscription? _roomSub;
  Timer? _disappearingTimer;

  @override
  void initState() {
    super.initState();
    NotificationService.instance.setActiveRoom(room.id);
    _unreadAtOpen = room.notificationCount;
    _scroll.addListener(_onScroll);
    _loadMessages();
    _syncSub = throttleLatest(room.client.onSync.stream, const Duration(milliseconds: 250)).listen((_) {
      if (mounted) setState(() {});
    });
    _roomSub = throttleLatest(room.onUpdate.stream, const Duration(milliseconds: 250)).listen((_) {
      if (mounted) setState(() {});
    });
    _disappearingTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!mounted) {
        _disappearingTimer?.cancel();
        return;
      }
      if (DisappearingMessageService.effectiveSeconds(room,
              settings: ref.read(settingsProvider.notifier),
              events: _timeline?.events) >
          0) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    NotificationService.instance.setActiveRoom(null);
    _syncSub?.cancel();
    _roomSub?.cancel();
    _disappearingTimer?.cancel();
    _highlightTimer?.cancel();
    _smartReplyDebounce?.cancel();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _searchController.dispose();
    _timeline?.cancelSubscriptions();
    super.dispose();
  }

  Future<void> _loadMessages() async {
    try {
      final timeline = await room.getTimeline(onUpdate: _onTimelineUpdate);
      if (!mounted) {
        timeline.cancelSubscriptions();
        return;
      }
      _cachedVisibleEvents = null;
      for (final ev in timeline.events) {
        if (ev.status == EventStatus.error) {
          _deletedEventIds.add(ev.eventId);
          ev.cancelSend().catchError((_) {});
        }
      }
      setState(() => _timeline = timeline);
      
      _markRead();
      _scheduleSmartReplies();

      _requestInitialHistory(timeline);
    } catch (e) {
      debugPrint('ChatScreen: timeline init failed: $e');
      if (mounted) setState(() => _loadFailed = true);
    }
  }

  Future<void> _requestInitialHistory(Timeline timeline) async {
    if (_requestingHistory) return;
    setState(() => _requestingHistory = true);
    try {
      int attempts = 0;
      while (timeline.events.length < 30 &&
          (timeline.canRequestHistory || attempts == 0) &&
          attempts < 5 &&
          mounted) {
        final countBefore = timeline.events.length;
        await timeline.requestHistory(historyCount: 50);
        _cachedVisibleEvents = null;
        if (mounted) setState(() {});
        if (timeline.events.length == countBefore && !timeline.canRequestHistory) {
          break;
        }
        attempts++;
        if (timeline.events.length >= 30) break;
      }
    } catch (e) {
      debugPrint('ChatScreen: initial requestHistory error: $e');
    } finally {
      if (mounted) {
        _cachedVisibleEvents = null;
        setState(() => _requestingHistory = false);
      }
    }
  }

  void _onTimelineUpdate() {
    if (!mounted) return;
    for (final ev in _timeline?.events ?? const <Event>[]) {
      if (ev.status == EventStatus.error && !_deletedEventIds.contains(ev.eventId)) {
        _deletedEventIds.add(ev.eventId);
        ev.cancelSend().catchError((_) {});
        ChatSoundService.playFailSound();
      }
    }
    _cachedVisibleEvents = null;
    setState(() {});
    // At (or near) the bottom: keep the room read as new messages arrive.
    if (_scroll.hasClients && _scroll.offset < 80) {
      _markRead();
    }
    _scheduleSmartReplies();
  }

  void _onScroll() {
    final show = _scroll.hasClients && _scroll.offset > 600;
    if (show != _showJumpButton) setState(() => _showJumpButton = show);

    final timeline = _timeline;
    if (timeline == null || _requestingHistory) return;
    if (_scroll.hasClients &&
        _scroll.position.maxScrollExtent - _scroll.offset < 900 &&
        timeline.canRequestHistory) {
      _requestHistory(timeline);
    }
  }

  Future<void> _requestHistory(Timeline timeline) async {
    if (_requestingHistory || !timeline.canRequestHistory) return;
    setState(() => _requestingHistory = true);
    try {
      await timeline.requestHistory(historyCount: 100);
      _cachedVisibleEvents = null;
    } catch (e) {
      debugPrint('ChatScreen: requestHistory failed: $e');
    } finally {
      if (mounted) setState(() => _requestingHistory = false);
    }
  }

  void _markRead() {
    if (ref.read(settingsProvider).effectiveHideReadReceipts) {
      debugPrint('Incognito: read receipt suppressed');
      return;
    }
    Event? target = room.lastEvent;
    if (target != null && target.eventId.startsWith('AlloraClient-')) {
      final valid = _visibleEvents()
          .where((e) => !e.eventId.startsWith('AlloraClient-'));
      target = valid.isNotEmpty ? valid.last : null;
    }
    if (target == null || room.notificationCount == 0) return;
    room.setReadMarker(target.eventId, mRead: target.eventId).catchError((e) {
      debugPrint('setReadMarker failed: $e');
    });
  }

  // ── Events shown in the list ─────────────────────────────────────────────

  bool _isVisible(Event e) {
    // Edit events are folded into their target via getDisplayEvent.
    if (e.relationshipType == RelationshipTypes.edit) return false;

    // Never show deleted messages
    if (_deletedEventIds.contains(e.eventId)) return false;

    // Never show failed messages with error red marks - auto delete them
    if (e.status == EventStatus.error) return false;

    if (e.type == EventTypes.Message ||
        e.type == EventTypes.Encrypted ||
        e.type == EventTypes.Sticker ||
        e.type.startsWith('m.room.message')) {
      return true;
    }
    
    // Explicitly allow all m.notice messages (bots use this)
    if (e.type == 'm.room.message' && e.content['msgtype'] == 'm.notice') {
      return true;
    }
    
    if (e.type == EventTypes.CallInvite || e.type == EventTypes.CallHangup) {
      return true;
    }

    if (e.type.startsWith('m.room.message') || e.type.startsWith('m.call.')) {
      return true;
    }

    return false;
  }

  String _resolveSenderNameForEvent(Event event) {
    final myId = widget.room.client.userID;
    final isMe = event.senderId == myId ||
        (widget.room.isDirectChat &&
            event.senderId != widget.room.directChatMatrixID &&
            !event.senderId.split(':').first.toLowerCase().endsWith('bot') &&
            !event.senderId.split(':').first.toLowerCase().contains('bridge'));
    if (isMe) return 'You';
    return ref.read(contactsProvider.notifier).resolveContactHierarchy(
      room: widget.room,
      event: event,
      senderId: event.senderId,
    );
  }

  List<Event> _visibleEvents() {
    final cached = _cachedVisibleEvents;
    if (cached != null) return cached;
    final timeline = _timeline;
    if (timeline == null) return const [];

    final res = timeline.events.where((e) => _isVisible(e)).toList();
    _cachedVisibleEvents = res;
    return res;
  }

  // ── Sending ───────────────────────────────────────────────────────────────

  Future<void> _send(String text) async {
    _cachedVisibleEvents = null;
    // Guard: never send to a room we've been kicked from or have left.
    // After a bridge kick ("User is not in remote chat") the room membership
    // drops to Membership.leave / Membership.ban before the reconnect banner
    // appears.  Sending into that state causes a 403 from the homeserver and
    // keeps the outgoing queue retrying indefinitely.
    if (room.membership != Membership.join) {
      ChatSoundService.playFailSound();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Not connected — reconnect to send messages.')));
      }
      return;
    }
    try {
      if (_editing != null) {
        await room.sendTextEvent(text, editEventId: _editing!.eventId);
        setState(() => _editing = null);
      } else {
        final reply = _replyTo;
        setState(() => _replyTo = null);
        await room.sendTextEvent(text, inReplyTo: reply);
        if (mounted) setState(() {});
      }
      // Play sent sound on successful dispatch
      ChatSoundService.playSentSound();
      if (_scroll.hasClients) {
        _scroll.animateTo(0,
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic);
      }
    } catch (e) {
      debugPrint('send failed: $e');
      // Matrix server is offline or send error: auto-delete failed event so it doesn't stay stuck with red mark
      try {
        final pending = _timeline?.events.where((ev) =>
            ev.senderId == room.client.userID &&
            (ev.status == EventStatus.error ||
             ev.status == EventStatus.sending ||
             ev.eventId.startsWith('AlloraClient-'))).toList();
        if (pending != null && pending.isNotEmpty) {
          for (final failedEv in pending) {
            _deletedEventIds.add(failedEv.eventId);
            await failedEv.cancelSend();
          }
        }
      } catch (cancelErr) {
        debugPrint('cancelSend error: $cancelErr');
      }

      // Play fail sound
      ChatSoundService.playFailSound();

      if (mounted) {
        setState(() {
          _cachedVisibleEvents = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Row(
            children: [
              Icon(Icons.cloud_off_rounded, color: Colors.white, size: 20),
              SizedBox(width: 10),
              Expanded(
                child: Text('Server offline — message could not be sent and was removed.'),
              ),
            ],
          ),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 3),
        ));
      }
    }
  }

  Future<void> _toggleReaction(Event event, String key) async {
    final timeline = _timeline;
    if (timeline == null) return;
    try {
      final myId = room.client.userID;
      Event? mine;
      for (final r
          in event.aggregatedEvents(timeline, RelationshipTypes.reaction)) {
        if (r.redacted || r.senderId != myId) continue;
        final relates = r.content['m.relates_to'];
        if (relates is Map && relates['key'] == key) {
          mine = r;
          break;
        }
      }
      if (mine != null) {
        await room.redactEvent(mine.eventId);
      } else {
        await room.sendReaction(event.eventId, key);
      }
    } catch (e) {
      debugPrint('reaction failed: $e');
    }
  }

  // ── Navigation within the timeline ───────────────────────────────────────

  final Map<String, GlobalKey> _itemKeys = {};

  GlobalKey _keyFor(String eventId) =>
      _itemKeys.putIfAbsent(eventId, () => GlobalKey());

  Future<void> _jumpTo(String eventId) async {
    final key = _itemKeys[eventId];
    final ctx = key?.currentContext;
    if (ctx != null) {
      await Scrollable.ensureVisible(ctx,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
          alignment: 0.4);
      _flash(eventId);
      return;
    }
    // Not built yet: walk towards it (bounded) while history loads.
    final events = _visibleEvents();
    final idx = events.indexWhere((e) => e.eventId == eventId);
    if (idx == -1) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Message is further back in history.')));
      return;
    }
    _scroll.animateTo(
      (idx * 72.0).clamp(0.0, _scroll.position.maxScrollExtent),
      duration: const Duration(milliseconds: 380),
      curve: Curves.easeOutCubic,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx2 = _itemKeys[eventId]?.currentContext;
      if (ctx2 != null) {
        Scrollable.ensureVisible(ctx2,
            duration: const Duration(milliseconds: 240), alignment: 0.4);
      }
      _flash(eventId);
    });
  }

  void _flash(String eventId) {
    _highlightTimer?.cancel();
    setState(() => _highlightedId = eventId);
    _highlightTimer = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _highlightedId = null);
    });
  }

  // ── Smart replies ─────────────────────────────────────────────────────────

  void _scheduleSmartReplies() {
    final settings = ref.read(settingsProvider);
    if (!settings.aiEnabled || !settings.aiSmartReplies) return;
    _smartReplyDebounce?.cancel();
    _smartReplyDebounce =
        Timer(const Duration(milliseconds: 900), _loadSmartReplies);
  }

  Future<void> _loadSmartReplies() async {
    final events = _visibleEvents();
    if (events.isEmpty) return;
    final last = events.first;
    // Only suggest when the other side spoke last.
    if (last.senderId == room.client.userID || last.redacted) {
      if (_smartReplies.isNotEmpty && mounted) {
        setState(() => _smartReplies = const []);
      }
      return;
    }
    if (_smartRepliesForEvent == last.eventId) return;

    final cached = _smartReplyCache[last.eventId];
    if (cached != null) {
      setState(() {
        _smartReplies = cached;
        _smartRepliesForEvent = last.eventId;
      });
      return;
    }

    _smartRepliesForEvent = last.eventId;
    final context8 =
        AiService.contextFromTimeline(room, events.take(8).toList());
    final res = await AiService.smartReplies(context8);
    if (!mounted || _smartRepliesForEvent != last.eventId) return;
    if (res.ok && res.suggestions.isNotEmpty) {
      _smartReplyCache[last.eventId] = res.suggestions.take(3).toList();
      if (_smartReplyCache.length > 30) {
        _smartReplyCache.remove(_smartReplyCache.keys.first);
      }
      setState(() => _smartReplies = _smartReplyCache[last.eventId]!);
    } else {
      setState(() => _smartReplies = const []);
    }
  }

  // ── Context menu ─────────────────────────────────────────────────────────

  void _openContextMenu(Event displayEvent, Rect rect) {
    final isMe = displayEvent.senderId == room.client.userID;
    final isText = !displayEvent.redacted &&
        (displayEvent.content['msgtype'] == 'm.text' ||
            displayEvent.content['msgtype'] == null ||
            displayEvent.content['msgtype'] == 'm.notice' ||
            displayEvent.content['msgtype'] == 'm.emote');
    final settings = ref.read(settingsProvider);
    final starred =
        ref.read(settingsProvider.notifier).isStarred(displayEvent.eventId);
    final pinnedIds = _safePinnedIds();
    final isPinned = pinnedIds.contains(displayEvent.eventId);
    final body = stripReplyFallback(displayEvent.body);

    showMessageContextMenu(
      context: context,
      event: displayEvent,
      bubbleRect: rect,
      isMe: isMe,
      onReact: (emoji) => _toggleReaction(displayEvent, emoji),
      onMoreReactions: () async {
        final emoji = await showEmojiPicker(context);
        if (emoji != null) await _toggleReaction(displayEvent, emoji);
      },
      actions: [
        MessageMenuAction(
          icon: Icons.reply_rounded,
          label: 'Reply',
          onTap: () => setState(() {
            _editing = null;
            _replyTo = displayEvent;
          }),
        ),
        if (isText)
          MessageMenuAction(
            icon: Icons.copy_rounded,
            label: 'Copy',
            onTap: () {
              Clipboard.setData(ClipboardData(text: body));
              ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Copied')));
            },
          ),
        MessageMenuAction(
          icon: Icons.forward_rounded,
          label: 'Forward',
          onTap: () => showForwardSheet(context, ref, event: displayEvent),
        ),
        MessageMenuAction(
          icon: starred ? Icons.star_rounded : Icons.star_outline_rounded,
          label: starred ? 'Unstar' : 'Star',
          onTap: () => ref.read(settingsProvider.notifier).toggleStarred(
                StarredMessage(
                  roomId: room.id,
                  eventId: displayEvent.eventId,
                  roomName: cleanRoomTitle(room.displayname),
                  senderName: _resolveSenderNameForEvent(displayEvent),
                  preview: body.isEmpty
                      ? (displayEvent.content['msgtype']?.toString() ??
                          'Message')
                      : body,
                  tsMs: displayEvent.originServerTs.millisecondsSinceEpoch,
                ),
              ),
        ),
        MessageMenuAction(
          icon: isPinned
              ? Icons.push_pin_outlined
              : Icons.push_pin_rounded,
          label: isPinned ? 'Unpin' : 'Pin',
          onTap: () => _togglePin(displayEvent, pinnedIds),
        ),
        if (isText && settings.aiEnabled) ...[
          MessageMenuAction(
            icon: Icons.translate_rounded,
            label: 'Translate',
            onTap: () => showAiResultSheet(
              context,
              title: 'Translation',
              icon: Icons.translate_rounded,
              future:
                  AiService.translate(body, settings.aiTranslateLanguage),
            ),
          ),
          MessageMenuAction(
            icon: Icons.psychology_alt_rounded,
            label: 'Explain',
            onTap: () => showAiResultSheet(
              context,
              title: 'Explanation',
              icon: Icons.psychology_alt_rounded,
              future: AiService.explain(body),
            ),
          ),
        ],
        if (isMe && isText && !displayEvent.redacted)
          MessageMenuAction(
            icon: Icons.edit_rounded,
            label: 'Edit',
            onTap: () => setState(() {
              _replyTo = null;
              _editing = displayEvent;
            }),
          ),
        MessageMenuAction(
          icon: Icons.check_circle_outline_rounded,
          label: 'Select',
          onTap: () => setState(() => _selected.add(displayEvent.eventId)),
        ),
        MessageMenuAction(
          icon: Icons.info_outline_rounded,
          label: 'Message info',
          onTap: () => showMessageInfoSheet(context, displayEvent),
        ),
        if (isMe || displayEvent.status == EventStatus.error || displayEvent.eventId.startsWith('AlloraClient-'))
          MessageMenuAction(
            icon: Icons.delete_outline_rounded,
            label: 'Delete',
            destructive: true,
            onTap: () => _confirmRedact([displayEvent.eventId]),
          ),
      ],
    );
  }

  List<String> _safePinnedIds() {
    try {
      return room.pinnedEventIds;
    } catch (_) {
      return const [];
    }
  }

  Future<void> _togglePin(Event event, List<String> current) async {
    try {
      final next = List<String>.from(current);
      next.contains(event.eventId)
          ? next.remove(event.eventId)
          : next.add(event.eventId);
      await room.setPinnedEvents(next);
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Pinning isn\u2019t allowed in this chat.')));
      }
    }
  }

  void _confirmRedact(List<String> eventIds) {
    final c = context.allora;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
            eventIds.length == 1 ? 'Delete message?' : 'Delete ${eventIds.length} messages?'),
        content: Text(
          'This message will be removed from this chat.',
          style: TextStyle(color: c.textSecondary),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              for (final id in eventIds) {
                _deletedEventIds.add(id);
                final Event? ev = _timeline?.events.where((e) => e.eventId == id).firstOrNull;
                if (ev != null) {
                  try {
                    await ev.cancelSend();
                  } catch (_) {}
                }
                try {
                  await room.redactEvent(id);
                } catch (e) {
                  debugPrint('redact failed: $e');
                }
              }
              ChatSoundService.playDeleteSound();
              _cachedVisibleEvents = null;
              setState(() => _selected.clear());
            },
            child: Text('Delete', style: TextStyle(color: c.danger)),
          ),
        ],
      ),
    );
  }

  // ── Search in chat ────────────────────────────────────────────────────────

  void _runSearch(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) {
      setState(() {
        _matches = const [];
        _matchIndex = 0;
      });
      return;
    }
    final matches = _visibleEvents()
        .where((e) => !e.redacted && e.body.toLowerCase().contains(q))
        .toList();
    setState(() {
      _matches = matches;
      _matchIndex = 0;
    });
    if (matches.isNotEmpty) _jumpTo(matches.first.eventId);
  }

  void _stepMatch(int delta) {
    if (_matches.isEmpty) return;
    setState(() =>
        _matchIndex = (_matchIndex + delta + _matches.length) % _matches.length);
    _jumpTo(_matches[_matchIndex].eventId);
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final c = context.allora;
    final events = _visibleEvents();
    final eventById = {for (final e in events) e.eventId: e};

    return Scaffold(
      backgroundColor: c.canvas,
      appBar: _selectionMode
          ? _selectionAppBar(events)
          : _chatAppBar(),
      body: Column(
        children: [
          if (_searchOpen) _searchBar(),
          if (BridgeRoomClassifier.getNetworkForRoom(room, client: room.client) != null)
            Consumer(
              builder: (context, ref, _) {
                final netId = BridgeRoomClassifier.getNetworkForRoom(room, client: room.client)!;
                final health = ref.watch(bridgeHealthProvider(netId.name));
                return BridgeStatusBanner(
                  networkName: metaFor(netId).displayName,
                  health: health,
                  onTapReconnect: () {
                    AccountLifecycleService.reconnectNetwork(room.client, netId);
                    openNetworkConnectFlow(
                      context,
                      room.client,
                      netId,
                    );
                  },
                );
              },
            ),
          _pinnedBanner(eventById),
          Expanded(
            child: Stack(
              children: [
                _timeline == null
                    ? (_loadFailed
                        ? _errorState()
                        : const Center(
                            child:
                                CircularProgressIndicator(strokeWidth: 2.5)))
                    : _messageList(events, eventById),
                Positioned(
                  right: 14,
                  bottom: 14,
                  child: AnimatedScale(
                    scale: _showJumpButton ? 1 : 0,
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOutBack,
                    child: FloatingActionButton.small(
                      heroTag: 'jump_bottom',
                      backgroundColor: c.surface,
                      foregroundColor: c.accent,
                      elevation: 2,
                      onPressed: () {
                        _scroll.animateTo(0,
                            duration: const Duration(milliseconds: 320),
                            curve: Curves.easeOutCubic);
                        _markRead();
                      },
                      child: const Icon(Icons.keyboard_arrow_down_rounded),
                    ),
                  ),
                ),
              ],
            ),
          ),
          TypingIndicatorRow(room: room),
          if (_smartReplies.isNotEmpty && !_selectionMode && room.canSendEvent(EventTypes.Message))
            _smartReplyChips(),
          if (!_selectionMode)
            Consumer(
              builder: (context, ref, _) {
                final netId = BridgeRoomClassifier.getNetworkForRoom(room, client: room.client);
                final health = netId != null ? ref.watch(bridgeHealthProvider(netId.name)) : null;
                final isDisconnected = health?.state == BridgeConnectionState.needsLogin;
                return ChatInputBar(
                  key: _inputKey,
                  room: room,
                  replyTo: _replyTo,
                  editing: _editing,
                  disabled: isDisconnected,
                  onCancelReply: () => setState(() => _replyTo = null),
                  onCancelEdit: () => setState(() => _editing = null),
                  onSend: _send,
                  aiContextBuilder: () => AiService.contextFromTimeline(
                      room, _visibleEvents().take(20).toList()),
                );
              },
            ),

        ],
      ),
    );
  }

  PreferredSizeWidget _chatAppBar() {
    final c = context.allora;
    final isDirect = BridgeRoomClassifier.isDirectChat(room, client: room.client);
    final contacts = ref.watch(contactsProvider.notifier);
    final title = contacts.resolveContactHierarchy(room: room);

    final networkId =
        BridgeRoomClassifier.getNetworkForRoom(room, client: room.client);
    final network = networkId != null ? metaFor(networkId) : null;
    final typing = room.typingUsers
        .where((u) => u.id != room.client.userID)
        .toList();
    final settings = ref.watch(settingsProvider);
    final ttl = DisappearingMessageService.effectiveSeconds(room,
        settings: ref.read(settingsProvider.notifier), events: _timeline?.events);


    final String subtitle;
    if (typing.isNotEmpty) {
      subtitle = isDirect
          ? 'typing…'
          : '${typing.first.calcDisplayname().split(' ').first} is typing…';
    } else if (!isDirect) {
      int count = room.summary.mJoinedMemberCount ?? 0;
      if (networkId != null && count > 0) count -= 1;
      subtitle = count > 0 ? '$count members' : 'Group';
    } else {
      subtitle = 'Allora Secured';
    }

    return AppBar(
      titleSpacing: 0,
      leadingWidth: 42,
      title: InkWell(
        onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => ChatDetailsScreen(room: room))),
        child: Row(
          children: [
            Hero(
              tag: 'avatar_${room.id}',
              child: AlloraAvatar(
                name: title,
                mxcUri: AlloraAvatar.resolveUri(room),
                client: room.client,
                size: 38,
                network: network,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.2,
                              color: c.text),
                        ),
                      ),
                      if (ttl > 0)
                        Padding(
                          padding: const EdgeInsets.only(left: 5),
                          child: Icon(Icons.timer_outlined,
                              size: 13, color: c.textSecondary),
                        ),
                    ],
                  ),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: Text(
                      subtitle,
                      key: ValueKey(subtitle),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: typing.isNotEmpty
                            ? FontWeight.w600
                            : FontWeight.w400,
                        color: typing.isNotEmpty ? c.accent : c.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (settings.floatingChatEnabled)
          IconButton(
            tooltip: 'Pop out (Bubble)',
            onPressed: () async {
              if (await FlutterOverlayWindow.isPermissionGranted()) {
                await FlutterOverlayWindow.showOverlay(
                  height: 600,
                  alignment: OverlayAlignment.center,
                );
              } else {
                await FlutterOverlayWindow.requestPermission();
              }
            },
            icon: const Icon(Icons.bubble_chart_outlined),
          ),
        if (BridgeRoomClassifier.isDirectChat(room, client: room.client)) ...[
          IconButton(
            tooltip: 'Audio call',
            onPressed: () => _startCall(CallType.kVoice),
            icon: const Icon(Icons.call_outlined),
          ),
          IconButton(
            tooltip: 'Video call',
            onPressed: () => _startCall(CallType.kVideo),
            icon: const Icon(Icons.videocam_outlined),
          ),
        ],
        IconButton(
          tooltip: 'Search in chat',
          onPressed: () => setState(() {
            _searchOpen = !_searchOpen;
            if (!_searchOpen) {
              _searchController.clear();
              _matches = const [];
            }
          }),
          icon: Icon(_searchOpen ? Icons.close_rounded : Icons.search_rounded),
        ),
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert_rounded),
          onSelected: _onMenuAction,
          itemBuilder: (ctx) {
            final settings = ref.read(settingsProvider);
            final muted = room.pushRuleState == PushRuleState.dontNotify;
            return [
              const PopupMenuItem(
                  value: 'details', child: Text('Chat details')),
              if (settings.aiEnabled) ...[
                const PopupMenuItem(
                    value: 'summarize', child: Text('Summarize chat')),
                const PopupMenuItem(
                    value: 'tasks', child: Text('Extract tasks & dates')),
              ],
              PopupMenuItem(
                  value: 'mute', child: Text(muted ? 'Unmute' : 'Mute')),
              const PopupMenuItem(
                  value: 'disappearing',
                  child: Text('Disappearing messages')),
              const PopupMenuItem(
                  value: 'select', child: Text('Select messages')),
            ];
          },
        ),
      ],
    );
  }

  void _onMenuAction(String action) {
    switch (action) {
      case 'details':
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => ChatDetailsScreen(room: room)));
        break;
      case 'summarize':
        showAiResultSheet(
          context,
          title: 'Chat summary',
          icon: Icons.summarize_rounded,
          future: AiService.summarize(AiService.contextFromTimeline(
              room, _visibleEvents().take(60).toList(), limit: 60)),
        );
        break;
      case 'tasks':
        showAiResultSheet(
          context,
          title: 'Tasks & dates',
          icon: Icons.checklist_rounded,
          future: AiService.extractActions(AiService.contextFromTimeline(
              room, _visibleEvents().take(60).toList(), limit: 60)),
        );
        break;
      case 'mute':
        final muted = room.pushRuleState == PushRuleState.dontNotify;
        room
            .setPushRuleState(
                muted ? PushRuleState.notify : PushRuleState.dontNotify)
            .then((_) {
          if (mounted) setState(() {});
        }).catchError((_) {});
        break;
      case 'disappearing':
        showDisappearingSheet(context, ref, room);
        break;
      case 'select':
        final events = _visibleEvents();
        if (events.isNotEmpty) {
          setState(() => _selected.add(events.first.eventId));
        }
        break;
    }
  }

  Future<void> _startCall(CallType type) async {
    final voip = ref.read(voipProvider);
    try {
      final session = await voip.inviteToCall(room, type);
      if (mounted) {
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => VoipCallScreen(session: session),
        ));
      }
    } catch (e) {
      debugPrint('Call failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to start call.')),
        );
      }
    }
  }

  PreferredSizeWidget _selectionAppBar(List<Event> events) {
    final c = context.allora;
    final selectedEvents =
        events.where((e) => _selected.contains(e.eventId)).toList();
    final allMine = selectedEvents
        .every((e) => e.senderId == room.client.userID && !e.redacted);

    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.close_rounded),
        onPressed: () => setState(() => _selected.clear()),
      ),
      title: Text('${_selected.length} selected'),
      actions: [
        IconButton(
          tooltip: 'Copy',
          icon: const Icon(Icons.copy_rounded),
          onPressed: () {
            final text = selectedEvents.reversed
                .map((e) => stripReplyFallback(e.body))
                .where((t) => t.isNotEmpty)
                .join('\n');
            Clipboard.setData(ClipboardData(text: text));
            setState(() => _selected.clear());
            ScaffoldMessenger.of(context)
                .showSnackBar(const SnackBar(content: Text('Copied')));
          },
        ),
        if (selectedEvents.length == 1)
          IconButton(
            tooltip: 'Forward',
            icon: const Icon(Icons.forward_rounded),
            onPressed: () {
              final e = selectedEvents.first;
              setState(() => _selected.clear());
              showForwardSheet(context, ref, event: e);
            },
          ),
        IconButton(
          tooltip: 'Star',
          icon: const Icon(Icons.star_outline_rounded),
          onPressed: () {
            final notifier = ref.read(settingsProvider.notifier);
            for (final e in selectedEvents) {
              if (!notifier.isStarred(e.eventId)) {
                notifier.toggleStarred(StarredMessage(
                  roomId: room.id,
                  eventId: e.eventId,
                  roomName: cleanRoomTitle(room.displayname),
                  senderName: _resolveSenderNameForEvent(e),
                  preview: stripReplyFallback(e.body),
                  tsMs: e.originServerTs.millisecondsSinceEpoch,
                ));
              }
            }
            setState(() => _selected.clear());
            ScaffoldMessenger.of(context)
                .showSnackBar(const SnackBar(content: Text('Starred')));
          },
        ),
        if (allMine)
          IconButton(
            tooltip: 'Delete',
            icon: Icon(Icons.delete_outline_rounded, color: c.danger),
            onPressed: () => _confirmRedact(_selected.toList()),
          ),
      ],
    );
  }

  Widget _searchBar() {
    final c = context.allora;
    return Container(
      color: c.surface,
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchController,
              autofocus: true,
              onSubmitted: _runSearch,
              onChanged: (v) {
                if (v.isEmpty) _runSearch('');
              },
              textInputAction: TextInputAction.search,
              decoration: const InputDecoration(
                hintText: 'Search in chat…',
                prefixIcon: Icon(Icons.search_rounded, size: 20),
                isDense: true,
              ),
            ),
          ),
          if (_matches.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text('${_matchIndex + 1}/${_matches.length}',
                  style: TextStyle(fontSize: 12.5, color: c.textSecondary)),
            ),
          IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: () => _stepMatch(1),
            icon: Icon(Icons.keyboard_arrow_up_rounded, color: c.textSecondary),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: () => _stepMatch(-1),
            icon: Icon(Icons.keyboard_arrow_down_rounded,
                color: c.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _pinnedBanner(Map<String, Event> eventById) {
    final c = context.allora;
    final pinnedIds = _safePinnedIds();
    if (pinnedIds.isEmpty) return const SizedBox.shrink();
    final id = pinnedIds.last;
    final event = eventById[id];
    final timeline = _timeline;
    final preview = event == null || timeline == null
        ? 'Pinned message'
        : stripReplyFallback(event.getDisplayEvent(timeline).body)
            .replaceAll('\n', ' ');


    return Material(
      color: c.surface,
      child: InkWell(
        onTap: () => _jumpTo(id),
        onLongPress: event == null
            ? null
            : () => _togglePin(event, pinnedIds),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: c.outline)),
          ),
          child: Row(
            children: [
              Icon(Icons.push_pin_rounded, size: 15, color: c.accent),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Pinned message',
                        style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            color: c.accent)),
                    Text(
                      preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12.5, color: c.textSecondary),
                    ),
                  ],
                ),
              ),
              if (pinnedIds.length > 1)
                Text('${pinnedIds.length}',
                    style: TextStyle(fontSize: 12, color: c.textTertiary)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _messageList(List<Event> events, Map<String, Event> eventById) {
    final settings = ref.watch(settingsProvider);
    final timeline = _timeline;
    if (timeline == null) return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    
    // Cluster consecutive media messages
    final items = <_TimelineItem>[];
    for (int i = 0; i < events.length; i++) {
      final e = events[i];
      if (_isMediaGridCandidate(e)) {
        final cluster = [e];
        int j = i + 1;
        while (j < events.length && _isMediaGridCandidate(events[j])) {
          final prev = events[j];
          final curr = events[j - 1];
          if (prev.senderId == e.senderId && 
              curr.originServerTs.difference(prev.originServerTs).inMinutes < 5) {
            cluster.add(prev);
            j++;
          } else {
            break;
          }
        }
        if (cluster.length > 1) {
          items.add(_MediaClusterItem(cluster));
          i = j - 1; // skip clustered items
          continue;
        }
      }
      items.add(_SingleEventItem(e));
    }

    if (items.isEmpty) {
      if (_requestingHistory) {
        return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
      }
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.chat_bubble_outline_rounded,
                  size: 44, color: context.allora.textSecondary.withOpacity(0.5)),
              const SizedBox(height: 12),
              Text('No messages yet',
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: context.allora.textSecondary)),
              const SizedBox(height: 4),
              Text('Send a message to start the conversation.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 13,
                      color: context.allora.textSecondary.withOpacity(0.7))),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      controller: _scroll,
      reverse: true,
      physics:
          const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
      padding: const EdgeInsets.only(top: 12, bottom: 8),
      itemCount: items.length + (_requestingHistory ? 1 : 0),
      cacheExtent: 600,
      addRepaintBoundaries: true,
      addAutomaticKeepAlives: true,
      itemBuilder: (context, idx) {
        if (idx >= items.length) {
          return const Padding(
            padding: EdgeInsets.all(14),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }

        final item = items[idx];
        final olderItem = idx + 1 < items.length ? items[idx + 1] : null;
        final newerItem = idx > 0 ? items[idx - 1] : null;
        
        final Event event = item is _SingleEventItem ? item.event : (item as _MediaClusterItem).events.last;
        final Event? older = olderItem is _SingleEventItem ? olderItem.event : (olderItem as _MediaClusterItem?)?.events.first;
        final Event? newer = newerItem is _SingleEventItem ? newerItem.event : (newerItem as _MediaClusterItem?)?.events.last;

        final children = <Widget>[];

        // Day separator (visually above this message).
        if (older == null ||
            !ChatTime.sameDay(
                older.originServerTs, event.originServerTs)) {
          children.add(_DayChip(date: event.originServerTs));
        }

        // Unread divider logic
        if (_unreadAtOpen > 0) {
          bool showDivider = false;
          if (item is _SingleEventItem) {
             final origIdx = events.indexOf(item.event);
             if (origIdx == _unreadAtOpen - 1 && _unreadAtOpen <= events.length) showDivider = true;
          } else if (item is _MediaClusterItem) {
             for (final e in item.events) {
               final origIdx = events.indexOf(e);
               if (origIdx == _unreadAtOpen - 1 && _unreadAtOpen <= events.length) {
                 showDivider = true;
                 break;
               }
             }
          }
          if (showDivider) children.add(const _UnreadDivider());
        }

        if (item is _SingleEventItem) {
          final displayEvent = item.event.getDisplayEvent(timeline);
          children.add(MessageBubble(
            key: ValueKey(displayEvent.eventId),
            event: displayEvent,
            timeline: timeline,
            older: older,
            newer: newer,
            selectionMode: _selectionMode,
            selected: _selected.contains(displayEvent.eventId),
            highlighted: _highlightedId == displayEvent.eventId,
            fontScale: settings.fontScale,
            resolveEvent: (id) => eventById[id],
            onLongPress: _openContextMenu,
            onSwipeReply: (e) => setState(() {
              _editing = null;
              _replyTo = e;
            }),
            onTap: () => setState(() {
              _selected.contains(displayEvent.eventId)
                  ? _selected.remove(displayEvent.eventId)
                  : _selected.add(displayEvent.eventId);
            }),
            onJumpTo: _jumpTo,
            onToggleReaction: _toggleReaction,
          ));
        } else if (item is _MediaClusterItem) {
          children.add(MediaGridBubble(
             key: ValueKey(item.events.first.eventId),
             events: item.events,
             timeline: timeline,
             onJumpTo: _jumpTo,
          ));
        }

        final itemKey = item is _SingleEventItem 
            ? item.event.eventId 
            : (item as _MediaClusterItem).events.first.eventId;
        return Column(
          key: ValueKey('item_$itemKey'),
          children: children,
        );
      },
    );
  }


  bool _isMediaGridCandidate(Event e) {
    return !e.redacted && 
           e.type == EventTypes.Message &&
           e.content['msgtype'] == 'm.image' &&
           e.content['url'] is String &&
           (e.content['m.relates_to'] as Map?)?['m.in_reply_to'] == null;
  }

  Widget _smartReplyChips() {
    final c = context.allora;
    return Container(
      height: 44,
      alignment: Alignment.centerLeft,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 6, top: 8),
            child:
                Icon(Icons.auto_awesome_rounded, size: 15, color: c.accent),
          ),
          for (final reply in _smartReplies)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ActionChip(
                backgroundColor: c.surface,
                side: BorderSide(color: c.outline),
                label: Text(reply,
                    style: TextStyle(fontSize: 13, color: c.text)),
                onPressed: () {
                  HapticFeedback.lightImpact();
                  setState(() => _smartReplies = const []);
                  _send(reply);
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _emptyChat() {
    final c = context.allora;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.waving_hand_rounded, size: 44, color: c.accent),
          const SizedBox(height: 12),
          Text('Say hello',
              style: TextStyle(
                  fontSize: 17, fontWeight: FontWeight.w700, color: c.text)),
          const SizedBox(height: 4),
          Text('Messages you send appear here.',
              style: TextStyle(fontSize: 13.5, color: c.textSecondary)),
        ],
      ),
    );
  }

  Widget _errorState() {
    final c = context.allora;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off_rounded, size: 44, color: c.textTertiary),
          const SizedBox(height: 12),
          Text('Couldn\u2019t load this chat',
              style: TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w700, color: c.text)),
          const SizedBox(height: 14),
          OutlinedButton(
            onPressed: () {
              setState(() => _loadFailed = false);
              _loadMessages();
            },
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}

class _DayChip extends StatelessWidget {
  final DateTime date;
  const _DayChip({required this.date});

  @override
  Widget build(BuildContext context) {
    final c = context.allora;
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 10),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: c.surfaceAlt.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          ChatTime.dayHeader(date),
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: c.textSecondary,
          ),
        ),
      ),
    );
  }
}

class _UnreadDivider extends StatelessWidget {
  const _UnreadDivider();

  @override
  Widget build(BuildContext context) {
    final c = context.allora;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 20),
      child: Row(
        children: [
          Expanded(child: Divider(color: c.accent.withValues(alpha: 0.4))),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(
              'UNREAD MESSAGES',
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: c.accent,
              ),
            ),
          ),
          Expanded(child: Divider(color: c.accent.withValues(alpha: 0.4))),
        ],
      ),
    );
  }
}

abstract class _TimelineItem {}
class _SingleEventItem extends _TimelineItem {
  final Event event;
  _SingleEventItem(this.event);
}
class _MediaClusterItem extends _TimelineItem {
  final List<Event> events;
  _MediaClusterItem(this.events);
}
