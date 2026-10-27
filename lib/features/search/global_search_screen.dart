// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matrix/matrix.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/chat_time.dart';
import '../../core/utils/matrix_media.dart';
import '../../core/utils/throttle.dart';
import '../../core/widgets/allora_avatar.dart';
import '../../data/services/contacts_service.dart';
import '../../data/settings/app_settings.dart';
import '../../providers/network_provider.dart';
import '../../screens/bridge/bridge_room_classifier.dart';
import '../../screens/networks/network_meta.dart';
import '../chat/chat_screen.dart';
import '../chat/widgets/image_viewer.dart';
import '../chat_list/chat_list_providers.dart';

enum _SearchTab { chats, messages, media, links }

class _MessageHit {
  final Room room;
  final Event event;
  const _MessageHit(this.room, this.event);
}

/// Global search: chat names instantly; message text, shared media and
/// links via a bounded scan of the most recent conversations (newest 24
/// rooms × last ~100 events — cancellable, so typing stays fluid).
class GlobalSearchScreen extends ConsumerStatefulWidget {
  const GlobalSearchScreen({super.key});

  @override
  ConsumerState<GlobalSearchScreen> createState() => _GlobalSearchScreenState();
}

class _GlobalSearchScreenState extends ConsumerState<GlobalSearchScreen> {
  final _controller = TextEditingController();
  final _debouncer = Debouncer(const Duration(milliseconds: 350));
  _SearchTab _tab = _SearchTab.chats;
  String _query = '';
  bool _scanning = false;
  int _generation = 0;

  List<Room> _chatHits = const [];
  List<MapEntry<String, String>> _contactHits = const [];
  List<_MessageHit> _messageHits = const [];
  List<_MessageHit> _mediaHits = const [];
  List<_MessageHit> _linkHits = const [];

  static final _urlPattern =
      RegExp(r'https?://[^\s<>"]+', caseSensitive: false);

  @override
  void dispose() {
    _generation++;
    _debouncer.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    _query = value;
    _searchChats(); // instant
    _debouncer(() => _scanTimelines());
  }

  List<Room> _candidateRooms() {
    final client = ref.read(matrixClientProvider);
    final hidden = ref.read(settingsProvider).hiddenChats;
    final rooms = client.rooms
        .where((r) {
          if (r.membership != Membership.join || r.isSpace || hidden.contains(r.id)) {
            return false;
          }
          if (BridgeRoomClassifier.isManagementRoom(r, client: client) ||
              BridgeRoomClassifier.isEmptyOrGhostRoom(r, client: client)) {
            return false;
          }
          final loc = r.getLocalizedDisplayname().toLowerCase().trim();
          final rName = r.displayname.toLowerCase().trim();
          if (loc.contains('bridge bot') ||
              loc.contains('bridgebot') ||
              rName.contains('bridge bot') ||
              rName.contains('bridgebot')) {
            final hasPuppet = r.getParticipants().any((p) => ContactsNotifier.isRemotePuppetMxid(p.id));
            if (!hasPuppet) return false;
          }
          return true;
        })
        .toList()
      ..sort((a, b) {
        final at = a.lastEvent?.originServerTs ??
            DateTime.fromMillisecondsSinceEpoch(0);
        final bt = b.lastEvent?.originServerTs ??
            DateTime.fromMillisecondsSinceEpoch(0);
        return bt.compareTo(at);
      });
    return rooms;
  }

  void _searchChats() {
    final q = _query.trim().toLowerCase();
    final rooms = _candidateRooms();
    final contacts = ref.read(contactsProvider);
    final contactsNotifier = ref.read(contactsProvider.notifier);
    setState(() {
      _chatHits = q.isEmpty
          ? rooms.take(12).toList()
          : rooms
              .where((r) {
                final title = contactsNotifier.resolveContactHierarchy(room: r).toLowerCase();
                return title.contains(q);
              })
              .take(30)
              .toList();
      _contactHits = q.isEmpty
          ? const []
          : contacts.entries
              .where((e) =>
                  e.value.toLowerCase().contains(q) || e.key.contains(q))
              .take(15)
              .toList();
    });
  }

  Future<void> _startContactChat(String contactName, String phoneOrHandle) async {
    final client = ref.read(matrixClientProvider);
    final contacts = ref.read(contactsProvider.notifier);

    final targetDigits = phoneOrHandle.replaceAll(RegExp(r'[^0-9]'), '');
    final targetNameLower = contactName.toLowerCase().trim();
    final targetLast10 = targetDigits.length >= 10
        ? targetDigits.substring(targetDigits.length - 10)
        : (targetDigits.length >= 7 ? targetDigits.substring(targetDigits.length - 7) : targetDigits);

    // 1. Search for an existing direct/bridged chat for this contact
    for (final r in client.rooms) {
      if (r.membership != Membership.join || r.isSpace) continue;
      if (BridgeRoomClassifier.isManagementRoom(r, client: client)) continue;

      final rawTitle = cleanRoomTitle(r.displayname).toLowerCase().trim();
      final resolved = contacts.resolveName(r.displayname, rawTitle).toLowerCase().trim();
      final roomDigits = r.displayname.replaceAll(RegExp(r'[^0-9]'), '');
      final directId = (r.directChatMatrixID ?? '').toLowerCase();
      final directDigits = directId.replaceAll(RegExp(r'[^0-9]'), '');

      // Check title or resolved contact name
      if (rawTitle == targetNameLower || resolved == targetNameLower) {
        _openRoom(r);
        return;
      }

      // Check phone number match in displayname or direct matrix ID
      if (targetLast10.isNotEmpty && targetLast10.length >= 7) {
        if (roomDigits.contains(targetLast10) ||
            directDigits.contains(targetLast10) ||
            directId.contains(targetDigits)) {
          _openRoom(r);
          return;
        }
      }

      // Check hero participants
      if (r.summary.mHeroes != null) {
        for (final hero in r.summary.mHeroes!) {
          final heroResolved = contacts.resolveName(hero, '').toLowerCase().trim();
          final heroDigits = hero.replaceAll(RegExp(r'[^0-9]'), '');
          if (heroResolved == targetNameLower ||
              (targetLast10.isNotEmpty && targetLast10.length >= 7 && heroDigits.contains(targetLast10))) {
            _openRoom(r);
            return;
          }
        }
      }
    }

    // 2. If no room exists, create a new direct chat and wait for it to be ready
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    try {
      final roomId = await client.createRoom(
        name: contactName,
        preset: CreateRoomPreset.trustedPrivateChat,
        isDirect: true,
      );

      Room? room = client.getRoomById(roomId);
      int retries = 0;
      while (room == null && retries < 25) {
        await Future.delayed(const Duration(milliseconds: 200));
        room = client.getRoomById(roomId);
        retries++;
      }

      if (mounted) Navigator.pop(context);
      if (room != null && mounted) {
        _openRoom(room);
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Chat created. Syncing with homeserver...')),
        );
      }
    } catch (e) {
      if (mounted) Navigator.pop(context);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not start chat: $e')),
        );
      }
    }
  }

  Future<void> _scanTimelines() async {
    final gen = ++_generation;
    final q = _query.trim().toLowerCase();
    setState(() {
      _scanning = true;
      _messageHits = const [];
      _mediaHits = const [];
      _linkHits = const [];
    });

    final messages = <_MessageHit>[];
    final media = <_MessageHit>[];
    final links = <_MessageHit>[];

    for (final room in _candidateRooms().take(24)) {
      if (gen != _generation || !mounted) return;
      Timeline? timeline;
      try {
        timeline = await room.getTimeline();
        for (final event in timeline.events.take(120)) {
          if (event.type != EventTypes.Message || event.redacted) continue;
          final msgtype = event.content['msgtype'] as String? ?? 'm.text';
          final body = event.body;

          if (msgtype == 'm.image' && event.content['url'] is String) {
            media.add(_MessageHit(room, event));
          }
          final url = _urlPattern.firstMatch(body)?.group(0);
          if (url != null &&
              (q.isEmpty || url.toLowerCase().contains(q))) {
            links.add(_MessageHit(room, event));
          }
          if (q.isNotEmpty &&
              msgtype != 'm.image' &&
              body.toLowerCase().contains(q)) {
            messages.add(_MessageHit(room, event));
          }
        }
      } catch (_) {
        // Room without loadable timeline — skip.
      }

      // Push partial results so the list fills in as the scan proceeds.
      if (gen == _generation && mounted) {
        setState(() {
          _messageHits = List.of(messages);
          _mediaHits = List.of(media);
          _linkHits = List.of(links);
        });
      }
    }

    if (gen == _generation && mounted) {
      setState(() => _scanning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.allora;
    return Scaffold(
      backgroundColor: c.canvas,
      appBar: AppBar(
        titleSpacing: 0,
        title: Padding(
          padding: const EdgeInsets.only(right: 12),
          child: TextField(
            controller: _controller,
            autofocus: true,
            onChanged: _onQueryChanged,
            textInputAction: TextInputAction.search,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w500,
              color: c.text,
            ),
            decoration: InputDecoration(
              hintText: 'Search everything…',
              hintStyle: TextStyle(color: c.textTertiary, fontSize: 15),
              prefixIcon: Icon(Icons.search_rounded, size: 20, color: c.textSecondary),
              suffixIcon: _query.isNotEmpty
                  ? IconButton(
                      icon: Icon(Icons.close_rounded, size: 18, color: c.textSecondary),
                      onPressed: () {
                        _controller.clear();
                        _onQueryChanged('');
                      },
                    )
                  : null,
              isDense: true,
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              disabledBorder: InputBorder.none,
              errorBorder: InputBorder.none,
              focusedErrorBorder: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(vertical: 10),
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              children: [
                _tabChip(_SearchTab.chats, 'Chats', Icons.forum_rounded),
                _tabChip(
                    _SearchTab.messages, 'Messages', Icons.notes_rounded),
                _tabChip(_SearchTab.media, 'Media', Icons.photo_rounded),
                _tabChip(_SearchTab.links, 'Links', Icons.link_rounded),
              ],
            ),
          ),
          if (_scanning) LinearProgressIndicator(
            minHeight: 2,
            backgroundColor: c.surfaceAlt,
          ),
          Expanded(child: _results()),
        ],
      ),
    );
  }

  Widget _tabChip(_SearchTab tab, String label, IconData icon) {
    final c = context.allora;
    final selected = _tab == tab;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: () {
          setState(() => _tab = tab);
          if (tab != _SearchTab.chats &&
              _messageHits.isEmpty &&
              _mediaHits.isEmpty &&
              _linkHits.isEmpty &&
              !_scanning) {
            _scanTimelines();
          }
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 13),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? c.accent : c.surfaceAlt,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(
            children: [
              Icon(icon,
                  size: 14, color: selected ? c.onAccent : c.textSecondary),
              const SizedBox(width: 6),
              Text(label,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: selected ? c.onAccent : c.textSecondary)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _results() {
    final c = context.allora;
    switch (_tab) {
      case _SearchTab.chats:
        if (_chatHits.isEmpty && _contactHits.isEmpty) {
          if (_query.trim().isNotEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('No chats found', style: TextStyle(color: c.textSecondary)),
                    const SizedBox(height: 12),
                    ElevatedButton.icon(
                      onPressed: () => _startContactChat(_query.trim(), _query.trim()),
                      icon: const Icon(Icons.chat_bubble_outline),
                      label: Text("Start new chat with '$_query'"),
                    ),
                  ],
                ),
              ),
            );
          }
          return _empty('No chats found');
        }
        return ListView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          children: [
            if (_chatHits.isNotEmpty) ...[
              for (final room in _chatHits) ...[
                Builder(
                  builder: (context) {
                    final networkId = BridgeRoomClassifier.getNetworkForRoom(room,
                        client: room.client);
                    final title = ref.read(contactsProvider.notifier).resolveContactHierarchy(room: room);
                    final isDirect = BridgeRoomClassifier.isDirectChat(room, client: room.client);
                    return ListTile(
                      leading: AlloraAvatar(
                        name: title,
                        mxcUri: room.avatar,
                        client: room.client,
                        size: 46,
                        network: networkId != null ? metaFor(networkId) : null,
                      ),
                      title:
                          Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        isDirect ? 'Direct message' : 'Group',
                        style: TextStyle(fontSize: 12, color: c.textTertiary),
                      ),
                      onTap: () => _openRoom(room),
                    );
                  },
                ),
              ],
            ],
            if (_contactHits.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text('Contacts',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: c.textSecondary)),
              ),
              for (final contact in _contactHits)
                ListTile(
                  leading: CircleAvatar(
                    backgroundColor: c.accent.withOpacity(0.15),
                    child: Icon(Icons.person_outline, color: c.accent),
                  ),
                  title: Text(contact.value,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    '${contact.key} • Tap to start conversation',
                    style: TextStyle(fontSize: 12, color: c.textTertiary),
                  ),
                  onTap: () => _startContactChat(contact.value, contact.key),
                ),
            ],
          ],
        );

      case _SearchTab.messages:
        if (_query.trim().isEmpty) {
          return _empty('Type to search message text');
        }
        if (_messageHits.isEmpty && !_scanning) {
          return _empty('No messages found in recent chats');
        }
        return ListView.builder(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          itemCount: _messageHits.length,
          itemBuilder: (context, i) => _messageTile(_messageHits[i]),
        );

      case _SearchTab.media:
        if (_mediaHits.isEmpty && !_scanning) {
          return _empty('No recent photos found');
        }
        return GridView.builder(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.all(10),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            crossAxisSpacing: 6,
            mainAxisSpacing: 6,
          ),
          itemCount: _mediaHits.length,
          itemBuilder: (context, i) {
            final hit = _mediaHits[i];
            final mxc = MatrixMedia.mxcOf(hit.event);
            final thumb = MatrixMedia.thumbnail(hit.room.client, mxc,
                width: 300, height: 300);
            final full = MatrixMedia.download(hit.room.client, mxc);
            if (thumb == null || full == null) return const SizedBox.shrink();
            return GestureDetector(
              onTap: () => Navigator.of(context).push(ImageViewerScreen.route(
                  url: full.url,
                  headers: full.headers,
                  heroTag: 'search_${hit.event.eventId}')),
              child: Hero(
                tag: 'search_${hit.event.eventId}',
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.network(thumb.url,
                      headers: thumb.headers,
                      fit: BoxFit.cover, cacheWidth: 300),
                ),
              ),
            );
          },
        );

      case _SearchTab.links:
        if (_linkHits.isEmpty && !_scanning) {
          return _empty('No links found in recent chats');
        }
        return ListView.builder(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          itemCount: _linkHits.length,
          itemBuilder: (context, i) => _messageTile(_linkHits[i], isLink: true),
        );
    }
  }

  Widget _messageTile(_MessageHit hit, {bool isLink = false}) {
    final c = context.allora;
    final title = ref.read(contactsProvider.notifier).resolveContactHierarchy(room: hit.room);
    return ListTile(
      leading: AlloraAvatar(
        name: title,
        mxcUri: hit.room.avatar,
        client: hit.room.client,
        size: 44,
        showNetworkBadge: false,
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w600)),
          ),
          Text(ChatTime.listStamp(hit.event.originServerTs),
              style: TextStyle(fontSize: 11.5, color: c.textTertiary)),
        ],
      ),
      subtitle: Text(
        hit.event.body.replaceAll('\n', ' '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 13,
          color: isLink ? c.accent : c.textSecondary,
        ),
      ),
      onTap: () => _openRoom(hit.room),
    );
  }

  Widget _empty(String message) {
    final c = context.allora;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14, color: c.textTertiary),
        ),
      ),
    );
  }

  void _openRoom(Room room) {
    Navigator.push(
        context, MaterialPageRoute(builder: (_) => ChatScreen(room: room)));
  }
}
