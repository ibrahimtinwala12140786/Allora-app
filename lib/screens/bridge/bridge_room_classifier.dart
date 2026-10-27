// ignore_for_file: deprecated_member_use
import 'package:matrix/matrix.dart';
import '../networks/network_meta.dart';

class BridgeRoomClassifier {
  BridgeRoomClassifier._();

  /// Returns the NetworkId this room belongs to, or null if it's a native Matrix room.
  static NetworkId? getNetworkForRoom(Room room, {Client? client}) {
    for (final network in NetworkId.values) {
      if (isRoomForNetwork(room, network, client: client)) {
        return network;
      }
    }
    return null;
  }

  /// Per-room classification cache.
  static final Map<String, NetworkId?> _cache = {};
  static final Map<String, bool> _managementCache = {};
  static final Map<String, bool> _directChatCache = {};

  static void forget(String roomId) {
    _cache.remove(roomId);
    _managementCache.remove(roomId);
    _directChatCache.remove(roomId);
  }

  static void clearCache() {
    _cache.clear();
    _managementCache.clear();
    _directChatCache.clear();
  }

  static void clearCacheForNetwork(NetworkId networkId) {
    _cache.removeWhere((_, classifiedId) => classifiedId == networkId);
    _managementCache.clear();
    _directChatCache.clear();
  }

  static NetworkId? classify(Room room, {Client? client}) {
    if (room.membership != Membership.join) return null;

    final cached = _cache[room.id];
    if (cached != null) return cached;

    final result = _classifyUncached(room, client: client);
    if (result != null) _cache[room.id] = result;
    return result;
  }

  static NetworkId? _classifyUncached(Room room, {Client? client}) {
    // ── 0. Canonical bridge state (most reliable) ───────────────────────────
    final protocolNet = _networkFromBridgeState(room);
    if (protocolNet != null) return protocolNet;

    final name = room.displayname.toLowerCase().trim();
    final directId = (room.directChatMatrixID ?? '').toLowerCase();
    final roomId = room.id.toLowerCase();
    final canonicalAlias = (room.canonicalAlias).toLowerCase();
    final topic = room.topic.toLowerCase();
    final userDomain = client?.userID?.split(':').last.toLowerCase();

    for (final net in kNetworks) {
      if (!net.available) continue;
      final alias = net.botAlias; // e.g. "whatsapp", "telegram"
      final nameTag = net.nameTag; // e.g. "wa", "tg"

      // Canonical management-room exclusion
      if (userDomain != null && directId == net.botMxid(userDomain)) {
        continue;
      }

      // Heuristic management-room exclusion
      if (name == alias || name == '$alias bridge bot' || name == '${alias}bot') {
        continue;
      }

      // 1. Tag in name, e.g. "(WA)", "(TG)", "(ig)", "[WA]", "[TG]"
      if (name.contains('($nameTag)') || name.contains('[$nameTag]')) {
        return net.id;
      }

      // 2. Network-specific extra name signals
      for (final signal in net.extraNameSignals) {
        if (name.contains(signal)) return net.id;
      }

      // 3. Topic signals
      if (topic.contains(alias) || (nameTag.length >= 2 && topic.contains(nameTag))) {
        if (net.id == NetworkId.telegram && (topic.contains('telegram') || topic.contains('t.me'))) {
          return net.id;
        }
      }

      // 4. Room ID / canonical alias contains network identifiers
      if (roomId.contains('_${alias}_') ||
          roomId.contains('_$alias') ||
          roomId.contains('${alias}_') ||
          (nameTag == 'tg' && roomId.contains('_tg_'))) {
        return net.id;
      }
      if (canonicalAlias.contains('${alias}_') ||
          canonicalAlias.contains('_$alias') ||
          canonicalAlias.contains('_${nameTag}_')) {
        return net.id;
      }

      // 5. Direct chat partner is bridge bot / puppet
      if (directId.contains('${alias}bot') ||
          directId.contains('$alias-bot') ||
          directId.contains('${alias}_') ||
          directId.contains(':$alias')) {
        return net.id;
      }
      if (nameTag == 'tg' && (directId.contains('tg_') || directId.contains('telegram'))) {
        return net.id;
      }

      // 6. Check heroes
      if (room.summary.mHeroes != null) {
        for (final hero in room.summary.mHeroes!) {
          if (_isMxidForNetwork(hero.toLowerCase(), net)) {
            return net.id;
          }
        }
      }

      // 7. Participant MXID check (puppets)
      if (_hasNetworkPuppet(room, net)) {
        return net.id;
      }
    }

    return null;
  }

  static NetworkId? _networkFromBridgeState(Room room) {
    try {
      for (final type in const ['m.bridge', 'uk.half-shot.bridge', 'm.room.bridged']) {
        final dynamic byStateKey = room.states[type];
        if (byStateKey == null) continue;
        final Iterable events =
            byStateKey is Map ? byStateKey.values : const [];
        for (final dynamic event in events) {
          final dynamic content = event.content;
          if (content is! Map) continue;
          for (final key in const ['protocol', 'network']) {
            final dynamic sub = content[key];
            if (sub is Map) {
              final id = sub['id']?.toString();
              if (id != null && id.isNotEmpty) {
                final net = networkForBridgeProtocol(id);
                if (net != null) return net;
              }
            } else if (sub is String && sub.isNotEmpty) {
              final net = networkForBridgeProtocol(sub);
              if (net != null) return net;
            }
          }
        }
      }
    } catch (_) {}
    return null;
  }

  static bool _hasNetworkPuppet(Room room, NetworkMeta net) {
    for (final m in room.getParticipants()) {
      if (_isMxidForNetwork(m.id.toLowerCase(), net)) {
        return true;
      }
    }
    return false;
  }

  static bool _isMxidForNetwork(String mxid, NetworkMeta net) {
    final alias = net.botAlias;
    final localpart =
        mxid.startsWith('@') ? mxid.substring(1).split(':').first : mxid;

    if (localpart == alias ||
        localpart.startsWith('${alias}bot') ||
        localpart.startsWith('$alias-') ||
        localpart.startsWith('${alias}_') ||
        localpart.contains('_$alias')) {
      return true;
    }

    switch (net.id) {
      case NetworkId.telegram:
        return localpart.startsWith('tg_') ||
            localpart.startsWith('telegram_') ||
            localpart.contains('telegram');
      case NetworkId.whatsapp:
        return localpart.startsWith('wa_') ||
            localpart.startsWith('whatsapp_') ||
            localpart.contains('whatsapp');
      case NetworkId.instagram:
        return localpart.startsWith('ig_') ||
            localpart.startsWith('instagram_') ||
            localpart.contains('instagram');
      case NetworkId.messenger:
        return localpart.startsWith('fb_') ||
            localpart.startsWith('facebook_') ||
            localpart.startsWith('messenger_') ||
            localpart.contains('messenger');
      case NetworkId.discord:
        return localpart.startsWith('discord_') || localpart.contains('discord');
      case NetworkId.slack:
        return localpart.startsWith('slack_') || localpart.contains('slack');
      case NetworkId.x:
        return localpart.startsWith('twitter_') || localpart.startsWith('x_');
      case NetworkId.signal:
        return localpart.startsWith('signal_') || localpart.contains('signal');
      default:
        return false;
    }
  }

  static bool isManagementRoom(Room room, {Client? client}) {
    final cached = _managementCache[room.id];
    if (cached != null) return cached;
    final result = _isManagementRoomUncached(room, client: client);
    _managementCache[room.id] = result;
    return result;
  }

  static bool _isRemotePuppetMxid(String mxid) {
    final lower = mxid.toLowerCase();
    return lower.contains('_whatsapp_') || lower.contains('@whatsapp_') ||
           lower.contains('_telegram_') || lower.contains('@telegram_') ||
           lower.contains('_facebook_') || lower.contains('@facebook_') ||
           lower.contains('_messenger_') || lower.contains('@messenger_') ||
           lower.contains('_instagram_') || lower.contains('@instagram_') ||
           lower.contains('_discord_') || lower.contains('@discord_') ||
           lower.contains('_slack_') || lower.contains('@slack_') ||
           lower.contains('_twitter_') || lower.contains('@twitter_') ||
           lower.contains('_signal_') || lower.contains('@signal_') ||
           lower.contains('@tg_') || lower.contains('_tg_') ||
           lower.contains('@wa_') || lower.contains('_wa_') ||
           lower.contains('@fb_') || lower.contains('_fb_') ||
           lower.contains('@ig_') || lower.contains('_ig_');
  }

  static bool _isBotMxid(String mxid, {Client? client}) {
    if (mxid.isEmpty) return false;
    final lower = mxid.toLowerCase();
    final userDomain = client?.userID?.split(':').last.toLowerCase();
    final localpart = lower.startsWith('@') ? lower.substring(1).split(':').first : lower;

    for (final n in kNetworks) {
      if (userDomain != null && lower == n.botMxid(userDomain).toLowerCase()) return true;
      if (localpart == '${n.botAlias}bot' ||
          localpart == '${n.nameTag}bot' ||
          localpart == '${n.botAlias}-bot' ||
          localpart == 'facebookbot' ||
          localpart == 'messengerbot' ||
          localpart == 'whatsappbot' ||
          localpart == 'telegrambot' ||
          localpart == 'instagrambot' ||
          localpart == 'discordbot' ||
          localpart == 'slackbot' ||
          localpart == 'twitterbot' ||
          localpart == 'xbot' ||
          localpart == 'signalbot' ||
          localpart == 'bridgebot' ||
          localpart == 'wabot' ||
          localpart == 'tgbot' ||
          localpart == 'fbbot' ||
          localpart == 'igbot') {
        return true;
      }
    }
    return false;
  }

  static bool _isStandaloneBotRoomName(String name) {
    final lower = name.toLowerCase().trim();
    return lower == 'whatsapp bridge bot' ||
        lower == 'whatsapp bridge' ||
        lower == 'telegram bridge bot' ||
        lower == 'telegram bridge' ||
        lower == 'facebook messenger bridge' ||
        lower == 'messenger bridge bot' ||
        lower == 'messenger bridge' ||
        lower == 'facebook bridge bot' ||
        lower == 'facebook bridge' ||
        lower == 'instagram bridge bot' ||
        lower == 'instagram bridge' ||
        lower == 'discord bridge bot' ||
        lower == 'discord bridge' ||
        lower == 'slack bridge bot' ||
        lower == 'slack bridge' ||
        lower == 'signal bridge bot' ||
        lower == 'signal bridge' ||
        lower == 'twitter bridge bot' ||
        lower == 'x bridge' ||
        lower == 'bridge bot' ||
        lower == 'bridgebot' ||
        lower.contains('bridge bot') ||
        lower.contains('bridgebot');
  }

  static bool isManagementCommandOrGreeting(String body) {
    if (body.isEmpty) return false;
    final lower = body.toLowerCase().trim();
    return lower.contains('marked as your management room') ||
        lower.contains('marked as a management room') ||
        lower.contains('i\'m a whatsapp bridge bot') ||
        lower.contains('i\'m a telegram bridge bot') ||
        lower.contains('i\'m a messenger bridge bot') ||
        lower.contains('i\'m a facebook bridge bot') ||
        lower.contains('i\'m an instagram bridge bot') ||
        lower.contains('i\'m a discord bridge bot') ||
        lower.contains('i\'m a slack bridge bot') ||
        lower.contains('i\'m a signal bridge bot') ||
        lower.contains('use \'help\' for help or \'login\' to log in') ||
        lower.contains('use help for help or login to log in') ||
        lower.contains('use `help` for help or `login` to log in') ||
        lower.contains('no ongoing command') ||
        lower.contains('successfully logged in as') ||
        lower.contains('input the pairing code in the') ||
        lower.startsWith('!wa ') ||
        lower.startsWith('!tg ') ||
        lower.startsWith('!fb ') ||
        lower.startsWith('!x ') ||
        lower.startsWith('!discord ') ||
        lower.startsWith('!slack ') ||
        lower.startsWith('!signal ') ||
        lower.startsWith('!ig ') ||
        lower.startsWith('!twitter ') ||
        lower == '!wa cancel' ||
        lower == '!fb cancel' ||
        lower == '!tg cancel' ||
        lower == 'cancel' ||
        lower == 'set-management-room' ||
        lower.startsWith('login phone ') ||
        lower.startsWith('login password ');
  }

  static bool _isManagementRoomUncached(Room room, {Client? client}) {
    final currentUserId = client?.userID?.toLowerCase() ?? '';
    final participants = room.getParticipants();
    final memberCount = room.summary.mJoinedMemberCount ?? participants.length;

    // Fast check: canonical and localized display names for standalone bot room
    final name = room.displayname.toLowerCase().trim();
    final locName = room.getLocalizedDisplayname().toLowerCase().trim();
    if (_isStandaloneBotRoomName(name) || _isStandaloneBotRoomName(locName)) {
      final hasPuppet = participants.any((p) => _isRemotePuppetMxid(p.id.toLowerCase()));
      if (!hasPuppet) {
        return true;
      }
    }

    // 1. Group chats with human puppets are NEVER management rooms!
    if (memberCount > 2) {
      final hasPuppet = participants.any((p) => _isRemotePuppetMxid(p.id.toLowerCase()));
      if (hasPuppet) return false;
    }

    // 2. Check if any participant is a remote puppet / contact
    for (final p in participants) {
      final id = p.id.toLowerCase();
      if (id == currentUserId) continue;

      // If there is any remote puppet or non-bot user, this is a user conversation!
      if (_isRemotePuppetMxid(id)) {
        return false;
      }
      if (!_isBotMxid(id, client: client)) {
        return false;
      }
    }

    // 3. Check heroes for remote puppet / non-bot users
    if (room.summary.mHeroes != null && room.summary.mHeroes!.isNotEmpty) {
      for (final hero in room.summary.mHeroes!) {
        final heroId = hero.toLowerCase();
        if (heroId == currentUserId) continue;
        if (_isRemotePuppetMxid(heroId)) {
          return false;
        }
        if (!_isBotMxid(heroId, client: client)) {
          return false;
        }
      }
    }

    // 4. Room only has user and potential bot. Verify bot identity:
    final directId = (room.directChatMatrixID ?? '').toLowerCase();
    if (directId.isNotEmpty && _isBotMxid(directId, client: client)) {
      return true;
    }

    final otherParticipants = participants.where((p) => p.id.toLowerCase() != currentUserId).toList();
    if (otherParticipants.length == 1 && _isBotMxid(otherParticipants.first.id, client: client)) {
      return true;
    }

    if (room.summary.mHeroes != null && room.summary.mHeroes!.length == 1) {
      if (_isBotMxid(room.summary.mHeroes!.first, client: client)) {
        return true;
      }
    }

    // 5. Check lastEvent: ONLY if it's from a verified bot AND contains management commands/greetings
    if (room.lastEvent != null) {
      final lastSender = room.lastEvent!.senderId.toLowerCase();
      if (lastSender != currentUserId && _isBotMxid(lastSender, client: client)) {
        if (isManagementCommandOrGreeting(room.lastEvent!.body)) {
          return true;
        }
      }
    }

    // 6. Check canonical display name for pure standalone bot room
    if (_isStandaloneBotRoomName(name) || _isStandaloneBotRoomName(locName)) {
      return true;
    }

    return false;
  }

  static bool isDirectChat(Room room, {Client? client}) {
    if (room.isDirectChat) return true;
    final cached = _directChatCache[room.id];
    if (cached != null) return cached;

    if (isManagementRoom(room, client: client)) {
      _directChatCache[room.id] = false;
      return false;
    }

    final count = room.summary.mJoinedMemberCount ?? room.getParticipants().length;
    if (count <= 2) {
      _directChatCache[room.id] = true;
      return true;
    }
    if (count == 3) {
      for (final p in room.getParticipants()) {
        final id = p.id.toLowerCase();
        final localpart = id.startsWith('@') ? id.substring(1).split(':').first : id;
        if (localpart.endsWith('bot') ||
            localpart.contains('bridge') ||
            localpart == 'allora' ||
            localpart.startsWith('whatsappbot') ||
            localpart.startsWith('telegrambot') ||
            localpart.startsWith('instagrambot') ||
            localpart.startsWith('messengerbot') ||
            localpart.startsWith('discordbot') ||
            localpart.startsWith('slackbot') ||
            localpart.startsWith('xbot') ||
            localpart.startsWith('signalbot')) {
          _directChatCache[room.id] = true;
          return true;
        }
      }
    }
    _directChatCache[room.id] = false;
    return false;
  }

  static bool isRoomForNetwork(Room room, NetworkId networkId,
          {Client? client}) =>
      classify(room, client: client) == networkId;

  static List<Room> roomsForNetwork(List<Room> rooms, NetworkId networkId,
          {Client? client}) =>
      rooms
          .where((r) => isRoomForNetwork(r, networkId, client: client))
          .toList();

  static String? findBridgeBotMxid(Client client, NetworkId networkId) {
    try {
      for (final room in client.rooms) {
        if (room.membership != Membership.join) continue;
        for (final type in const ['m.bridge', 'uk.half-shot.bridge', 'm.room.bridged']) {
          final dynamic byStateKey = room.states[type];
          if (byStateKey == null) continue;
          final Iterable events =
              byStateKey is Map ? byStateKey.values : const [];
          for (final dynamic event in events) {
            final dynamic content = event.content;
            if (content is! Map) continue;
            final dynamic protocol = content['protocol'];
            if (protocol is! Map) continue;
            final id = protocol['id']?.toString();
            if (id == null || networkForBridgeProtocol(id) != networkId) {
              continue;
            }
            final bot = content['bridgebot']?.toString();
            if (bot != null && bot.startsWith('@')) return bot;
          }
        }
      }
    } catch (_) {}
    return null;
  }

  static bool isEmptyOrGhostRoom(Room room, {Client? client}) {
    if (room.isSpace) return true;

    final nameLower = room.displayname.toLowerCase().trim();
    if (nameLower == 'empty room' ||
        nameLower.startsWith('empty room') ||
        nameLower == 'empty chat' ||
        nameLower.startsWith('empty chat')) {
      final memberCount =
          room.summary.mJoinedMemberCount ?? room.getParticipants().length;
      if (memberCount <= 1) return true;
    }

    // Never discard bridge portal rooms that belong to any social network
    final net = getNetworkForRoom(room, client: client);
    if (net != null) return false;

    final memberCount =
        room.summary.mJoinedMemberCount ?? room.getParticipants().length;
    final heroes = room.summary.mHeroes;
    if (memberCount <= 1 && (heroes == null || heroes.isEmpty) && room.lastEvent == null) {
      return true;
    }

    return false;
  }
}
