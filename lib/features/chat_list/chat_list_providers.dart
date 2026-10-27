// ignore_for_file: deprecated_member_use
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matrix/matrix.dart';

import '../../core/utils/throttle.dart';
import '../../data/services/contacts_service.dart';
import '../../data/services/hidden_rooms_store.dart';
import '../../data/services/room_wipe_service.dart';
import '../../data/settings/app_settings.dart';
import '../../data/settings/labels.dart';
import '../../providers/network_provider.dart';
import '../../screens/bridge/bridge_room_classifier.dart';
import '../../screens/networks/network_meta.dart';
import '../../screens/networks/network_connection_cache.dart';

/// Category filters shown as chips above the list.
enum ChatFilter { all, unread, priority, archived, people, groups }

extension ChatFilterLabel on ChatFilter {
  String get label {
    switch (this) {
      case ChatFilter.all:
        return 'All';
      case ChatFilter.unread:
        return 'Unread';
      case ChatFilter.priority:
        return 'Priority';
      case ChatFilter.archived:
        return 'Archived';
      case ChatFilter.people:
        return 'People';
      case ChatFilter.groups:
        return 'Groups';
    }
  }
}

final chatFilterProvider = StateProvider<ChatFilter>((_) => ChatFilter.all);
final networkFilterProvider = StateProvider<NetworkId?>((_) => null);
final chatSearchQueryProvider = StateProvider<String>((_) => '');

/// Coalesced sync ticks: instant first update, then at most ~3/sec no
/// matter how hard the bridges hammer /sync. Every chat-list rebuild hangs
/// off this single stream — no per-tile listeners, no polling.
final syncTickProvider = StreamProvider<int>((ref) {
  final client = ref.watch(matrixClientProvider);
  var tick = 0;
  return throttleLatest(client.onSync.stream, const Duration(milliseconds: 350))
      .map((_) => ++tick);
});

/// Everything a tile needs, computed once per sync tick instead of inside
/// every row's build.
class ChatEntry {
  final Room room;
  final NetworkMeta? network;
  final String title;
  final bool pinned;
  final bool muted;
  final bool typing;
  final int unreadCount;
  final bool markedUnread;
  final bool isGroup;
  final Event? lastEvent;
  final DateTime lastActivity;
  final List<Label> labels;

  const ChatEntry({
    required this.room,
    required this.network,
    required this.title,
    required this.pinned,
    required this.muted,
    required this.typing,
    required this.unreadCount,
    required this.markedUnread,
    required this.isGroup,
    required this.lastEvent,
    required this.lastActivity,
    this.labels = const [],
  });

  bool get isUnread => unreadCount > 0 || markedUnread;
}

class ChatListData {
  final List<ChatEntry> pinned;
  final List<ChatEntry> chats;
  final int archivedCount;
  final int totalUnread;

  const ChatListData({
    required this.pinned,
    required this.chats,
    required this.archivedCount,
    required this.totalUnread,
  });

  bool get isEmpty => pinned.isEmpty && chats.isEmpty;
}

final _bridgeTagPattern = RegExp(
  r'\s*[\(\[]\s*(?:WA|IG|FB|TG|DC|SL|TW|X|Slack|Discord|Signal|WhatsApp|Telegram|Instagram|Messenger|Facebook|Twitter)\s*[\)\]]',
  caseSensitive: false,
);

final _bridgePrefixPattern = RegExp(
  r'^(?:(?:WhatsApp|Telegram|Instagram|Messenger|Facebook|Discord|Slack|Signal|X|Twitter)\s+)?(?:bridge\s*bot|bridgebot|bridge)\s*[:\-\s]*',
  caseSensitive: false,
);

final _bridgeInlinePattern = RegExp(
  r'(?:^|\s+)(?:bridge\s*bot|bridgebot)(?:\s+|$)',
  caseSensitive: false,
);

/// Formats raw digits into a clean, readable international phone number.
String formatPhoneNumber(String original, String digitsOnly) {
  if (original.contains(' ') || original.contains('-')) {
    return original.startsWith('+') ? original : '+$original';
  }

  if (digitsOnly.startsWith('91') && digitsOnly.length == 12) {
    return '+91 ${digitsOnly.substring(2, 7)} ${digitsOnly.substring(7)}';
  } else if (digitsOnly.startsWith('1') && digitsOnly.length == 11) {
    return '+1 (${digitsOnly.substring(1, 4)}) ${digitsOnly.substring(4, 7)}-${digitsOnly.substring(7)}';
  } else if (digitsOnly.startsWith('44') && digitsOnly.length >= 11 && digitsOnly.length <= 12) {
    return '+44 ${digitsOnly.substring(2, 6)} ${digitsOnly.substring(6)}';
  } else if (digitsOnly.startsWith('92') && digitsOnly.length == 12) {
    return '+92 ${digitsOnly.substring(2, 5)} ${digitsOnly.substring(5)}';
  } else if (digitsOnly.startsWith('971') && digitsOnly.length == 12) {
    return '+971 ${digitsOnly.substring(3, 5)} ${digitsOnly.substring(5, 8)} ${digitsOnly.substring(8)}';
  } else if (digitsOnly.length == 10) {
    return '+${digitsOnly.substring(0, 5)} ${digitsOnly.substring(5)}';
  }

  return '+$digitsOnly';
}

/// Cleans room title by removing all "Bridge Bot", "WhatsApp bridge bot", bridge tags,
/// and formats phone numbers cleanly.
String cleanRoomTitle(String raw) {
  if (raw.isEmpty) return raw;

  var cleaned = raw.trim();

  // 1. Remove Matrix MXID wrappers if present, e.g. @whatsapp_919876543210:server.com -> 919876543210
  if (cleaned.startsWith('@') && cleaned.contains(':')) {
    cleaned = cleaned.split(':').first.substring(1);
    cleaned = cleaned.replaceFirst(
      RegExp(r'^(?:whatsapp_|telegram_|instagram_|messenger_|facebook_|discord_|slack_|twitter_|x_|signal_)',
          caseSensitive: false),
      '',
    );
  }

  // 2. Remove trailing bridge tags like (WA), (TG), (FB), (IG), [WA], (WhatsApp), etc.
  cleaned = cleaned.replaceAll(_bridgeTagPattern, '').trim();

  // 3. Remove leading "WhatsApp bridge bot", "Bridge bot", "Bridge:", etc.
  cleaned = cleaned.replaceAll(_bridgePrefixPattern, '').trim();

  // 4. Remove any remaining isolated "bridge bot" or "bridgebot" tokens
  cleaned = cleaned.replaceAll(_bridgeInlinePattern, ' ').trim();

  // 5. Remove surrounding parenthesis/brackets around phone numbers/names, e.g. "(+919876543210)" -> "+919876543210"
  if (cleaned.startsWith('(') && cleaned.endsWith(')')) {
    cleaned = cleaned.substring(1, cleaned.length - 1).trim();
  } else if (cleaned.startsWith('[') && cleaned.endsWith(']')) {
    cleaned = cleaned.substring(1, cleaned.length - 1).trim();
  }

  // 6. Clean leading/trailing punctuation like colons, dashes
  cleaned = cleaned.replaceAll(RegExp(r'^[:\-\s]+|[:\-\s]+$'), '').trim();

  // 7. Format clean phone numbers if applicable
  final digitsOnly = cleaned.replaceAll(RegExp(r'[^\d]'), '');
  final isPhone = digitsOnly.length >= 7 &&
      (cleaned.startsWith('+') || RegExp(r'^\d+$').hasMatch(cleaned.replaceAll(RegExp(r'[\s\-\(\)]'), '')));

  if (isPhone && digitsOnly.length >= 7) {
    cleaned = formatPhoneNumber(cleaned, digitsOnly);
  }

  return cleaned.isNotEmpty ? cleaned : raw;
}

final smartFoldersProcessorProvider = Provider<void>((ref) {
  final settings = ref.watch(settingsProvider);
  if (!settings.smartFoldersEnabled || settings.smartFolderRules.isEmpty) return;

  final client = ref.watch(matrixClientProvider);
  final rules = settings.smartFolderRules;
  final labelsNotifier = ref.read(labelsProvider.notifier);

  ref.watch(syncTickProvider);

  Future.microtask(() {
    for (final room in client.rooms) {
      if (room.membership != Membership.join || room.isSpace) continue;
      final rawTitle = cleanRoomTitle(room.displayname).toLowerCase();
      
      for (final entry in rules.entries) {
        if (rawTitle.contains(entry.key.toLowerCase())) {
          labelsNotifier.assign(room.id, entry.value);
        }
      }
    }
  });
});

/// The single source of truth for what the chat list shows.
///
/// Subtracts, in order: bridge management rooms, rooms of disconnected
/// networks, rooms queued for wipe (so a disconnect empties the UI in the
/// same frame), hidden chats, archived chats; then applies category/network
/// filters and the search query; finally sorts pinned-first by activity.
final chatListProvider = Provider<ChatListData>((ref) {
  ref.watch(syncTickProvider); // rebuild on (throttled) sync
  ref.watch(smartFoldersProcessorProvider); // process rules in background
  final client = ref.watch(matrixClientProvider);
  final wiping = ref.watch(wipePendingProvider);
  final hidden = ref.watch(hiddenRoomsProvider);
  final settings = ref.watch(settingsProvider);
  final filter = ref.watch(chatFilterProvider);
  final networkFilter = ref.watch(networkFilterProvider);
  final labelFilter = ref.watch(labelFilterProvider);
  final labelsState = ref.watch(labelsProvider);
  ref.watch(contactsProvider);
  final contacts = ref.read(contactsProvider.notifier);
  final query = ref.watch(chatSearchQueryProvider).trim().toLowerCase();

  final pinned = <ChatEntry>[];
  final chats = <ChatEntry>[];
  var archivedCount = 0;
  var totalUnread = 0;

  for (final room in client.rooms) {
    if (room.membership != Membership.join) continue;
    if (room.isSpace) continue;
    if (wiping.contains(room.id)) continue;
    final isBridgeOrBot = BridgeRoomClassifier.isManagementRoom(room, client: client);
    final isStatusBroadcast = room.displayname == 'WhatsApp Status Broadcast';
    
    // Always hide bot management rooms and status broadcast from inbox
    if (isBridgeOrBot) continue;
    if (isStatusBroadcast) continue;
    if (hidden.contains(room.id)) continue;
    if (settings.hiddenChats.contains(room.id)) continue;
    if (BridgeRoomClassifier.isEmptyOrGhostRoom(room, client: client)) continue;

    final networkId = BridgeRoomClassifier.getNetworkForRoom(room, client: client);

    // Hide rooms belonging to manually disconnected networks
    if (networkId != null) {
      final cache = NetworkConnectionCache.get(networkId);
      if (cache.manuallyDisconnected) continue;
    }

    final unread = room.notificationCount;
    if (unread > 0) totalUnread += unread;

    final isArchived = settings.archivedChats.contains(room.id);
    if (isArchived) {
      archivedCount++;
      if (filter != ChatFilter.archived) continue;
    } else {
      if (filter == ChatFilter.archived) continue;
    }

    if (networkFilter != null && networkId != networkFilter) continue;

    final roomLabels = labelsState.labelsFor(room.id);
    if (labelFilter != null &&
        !roomLabels.any((l) => l.id == labelFilter)) {
      continue;
    }

    final isDirect = BridgeRoomClassifier.isDirectChat(room, client: client);
    final isGroup = !isDirect;
    final markedUnread = room.markedUnread;
    final isPinned = settings.pinnedChats.contains(room.id);

    if (filter == ChatFilter.unread && unread == 0 && !markedUnread) continue;
    if (filter == ChatFilter.priority && !isPinned && unread == 0) continue;
    if (filter == ChatFilter.people && isGroup) continue;
    if (filter == ChatFilter.groups && !isGroup) continue;
    final title = contacts.resolveContactHierarchy(room: room);

    if (query.isNotEmpty && !title.toLowerCase().contains(query)) continue;

    final lastEvent = room.lastEvent;
    final entry = ChatEntry(
      room: room,
      network: networkId != null ? metaFor(networkId) : null,
      title: title,
      pinned: settings.pinnedChats.contains(room.id),
      muted: room.pushRuleState == PushRuleState.dontNotify,
      typing: room.typingUsers
          .any((u) => u.id != client.userID && u.id.isNotEmpty),
      unreadCount: unread,
      markedUnread: markedUnread,
      isGroup: isGroup,
      lastEvent: lastEvent,
      lastActivity: lastEvent?.originServerTs ??
          DateTime.fromMillisecondsSinceEpoch(0),
      labels: roomLabels,
    );
    (entry.pinned ? pinned : chats).add(entry);
  }

  int byActivity(ChatEntry a, ChatEntry b) =>
      b.lastActivity.compareTo(a.lastActivity);
  pinned.sort(byActivity);
  chats.sort(byActivity);

  return ChatListData(
    pinned: pinned,
    chats: chats,
    archivedCount: archivedCount,
    totalUnread: totalUnread,
  );
});

/// Aggregated unread count per network for the platform switcher rail.
final unreadCountsPerNetworkProvider = Provider<Map<NetworkId, int>>((ref) {
  ref.watch(syncTickProvider);
  final client = ref.watch(matrixClientProvider);
  final settings = ref.watch(settingsProvider);
  final wiping = ref.watch(wipePendingProvider);
  final hidden = ref.watch(hiddenRoomsProvider);

  final counts = <NetworkId, int>{};
  for (final room in client.rooms) {
    if (room.membership != Membership.join) continue;
    if (wiping.contains(room.id) || hidden.contains(room.id)) continue;
    if (settings.archivedChats.contains(room.id)) continue;
    if (BridgeRoomClassifier.isEmptyOrGhostRoom(room, client: client)) continue;
    if (BridgeRoomClassifier.isManagementRoom(room, client: client)) continue;

    final networkId = BridgeRoomClassifier.getNetworkForRoom(room, client: client);
    if (networkId != null) {
      final unread = room.notificationCount;
      if (unread > 0) {
        counts[networkId] = (counts[networkId] ?? 0) + unread;
      }
    }
  }
  return counts;
});

/// Up to 5 favorite / recent contacts for the story avatar circles at the top.
final storyContactsProvider = Provider<List<ChatEntry>>((ref) {
  final data = ref.watch(chatListProvider);
  final out = <ChatEntry>[];
  out.addAll(data.pinned);
  for (final chat in data.chats) {
    if (!out.any((c) => c.room.id == chat.room.id)) {
      out.add(chat);
    }
    if (out.length >= 6) break;
  }
  return out;
});


/// Archived chats, for the dedicated screen.
final archivedChatsProvider = Provider<List<ChatEntry>>((ref) {
  ref.watch(contactsProvider);
  final client = ref.watch(matrixClientProvider);
  final settings = ref.watch(settingsProvider);
  final wiping = ref.watch(wipePendingProvider);
  final hidden = ref.watch(hiddenRoomsProvider);
  final contacts = ref.read(contactsProvider.notifier);

  final out = <ChatEntry>[];
  for (final id in settings.archivedChats) {
    if (wiping.contains(id) || hidden.contains(id)) continue;
    final room = client.getRoomById(id);
    if (room == null || room.membership != Membership.join) continue;
    if (BridgeRoomClassifier.isEmptyOrGhostRoom(room, client: client)) continue;

    final networkId = BridgeRoomClassifier.getNetworkForRoom(room, client: client);
    final lastEvent = room.lastEvent;

    final isDirect = BridgeRoomClassifier.isDirectChat(room, client: client);
    final title = contacts.resolveContactHierarchy(room: room);

    out.add(ChatEntry(
      room: room,
      network: networkId != null ? metaFor(networkId) : null,
      title: title,
      pinned: false,
      muted: room.pushRuleState == PushRuleState.dontNotify,
      typing: false,
      unreadCount: room.notificationCount,
      markedUnread: room.markedUnread,
      isGroup: !isDirect,
      lastEvent: lastEvent,
      lastActivity:
          lastEvent?.originServerTs ?? DateTime.fromMillisecondsSinceEpoch(0),
    ));
  }
  out.sort((a, b) => b.lastActivity.compareTo(a.lastActivity));
  return out;
});

/// Preview line + glyph for a room's latest event ("📷 Photo", "🎤 Voice
/// message", "You: on my way"...). Pure function → trivially testable.
class ChatPreview {
  final String text;
  final PreviewGlyph glyph;
  const ChatPreview(this.text, [this.glyph = PreviewGlyph.none]);
}

enum PreviewGlyph { none, photo, video, voice, file, location, sticker, deleted }

final _whitespaceRegex = RegExp(r'\s+');

ChatPreview previewFor(Event? event, {required bool isGroup, String? myUserId, String Function(String, String)? resolveName}) {
  if (event == null) return const ChatPreview('No messages yet');
  if (event.redacted) {
    return const ChatPreview('Message deleted', PreviewGlyph.deleted);
  }

  final isMe = event.senderId == myUserId;
  String prefix = '';
  if (isMe) {
    prefix = 'You: ';
  } else if (isGroup) {
    final fallback = event.senderFromMemoryOrFallback.calcDisplayname();
    final sender = resolveName != null ? resolveName(event.senderId, fallback) : fallback;
    final first = sender.split(' ').first;
    if (first.isNotEmpty) prefix = '$first: ';
  }

  final msgtype = event.content['msgtype'] as String? ?? '';
  final info = event.content['info'];
  String mimetype = '';
  if (info is Map && info['mimetype'] is String) {
    mimetype = (info['mimetype'] as String).toLowerCase();
  } else if (event.content['mimetype'] is String) {
    mimetype = (event.content['mimetype'] as String).toLowerCase();
  }

  var body = event.content['body']?.toString().trim() ?? '';
  if (body.isEmpty) {
    final mscText = event.content['org.matrix.msc1767.text'];
    if (mscText is String) body = mscText.trim();
  }
  if (body.toLowerCase().startsWith("unknown message format")) body = '';
  if (body.startsWith('m.room.')) body = '';

  // Stickers
  if (event.type == EventTypes.Sticker ||
      event.type == 'm.sticker' ||
      msgtype == 'm.sticker' ||
      mimetype == 'image/webp.sticker') {
    return ChatPreview('${prefix}Sticker', PreviewGlyph.sticker);
  }

  // Photos & Images
  if (msgtype == 'm.image' || mimetype.startsWith('image/')) {
    return ChatPreview('${prefix}Photo', PreviewGlyph.photo);
  }

  // Videos
  if (msgtype == 'm.video' || mimetype.startsWith('video/')) {
    return ChatPreview('${prefix}Video', PreviewGlyph.video);
  }

  // Audio & Voice Notes
  if (msgtype == 'm.audio' ||
      mimetype.startsWith('audio/') ||
      event.content['org.matrix.msc3245.voice'] != null ||
      event.content['org.matrix.msc1767.audio'] != null) {
    return ChatPreview('${prefix}Voice message', PreviewGlyph.voice);
  }

  // Locations
  if (msgtype == 'm.location' ||
      (event.content['geo_uri'] is String && (event.content['geo_uri'] as String).isNotEmpty)) {
    return ChatPreview('${prefix}Location', PreviewGlyph.location);
  }

  // Contacts
  if (msgtype == 'm.contact' || mimetype.contains('vcard') || body.startsWith('BEGIN:VCARD')) {
    return ChatPreview('${prefix}Contact', PreviewGlyph.file);
  }

  // Files & Documents
  if (msgtype == 'm.file' || event.content['url'] != null || event.content['file'] != null) {
    String filename = event.content['filename']?.toString().trim() ??
        (info is Map ? info['name']?.toString().trim() ?? '' : '');
    if (filename.isEmpty && body.isNotEmpty && !body.contains('\n') && body.length < 50) {
      filename = body;
    }
    if (filename.isEmpty) {
      filename = 'Document';
    }
    return ChatPreview('$prefix$filename', PreviewGlyph.file);
  }

  if (event.type == EventTypes.Encrypted) {
    return ChatPreview('${prefix}Encrypted message');
  }

  if (body.isEmpty) return ChatPreview('${prefix}Message');
  final flat = body.replaceAll(_whitespaceRegex, ' ');
  return ChatPreview('$prefix$flat');
}
