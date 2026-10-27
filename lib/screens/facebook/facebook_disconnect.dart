// ignore_for_file: deprecated_member_use
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

import '../../data/services/account_lifecycle.dart';
import '../bridge/bridge_room_classifier.dart';
import '../networks/network_connection_cache.dart';
import '../networks/network_meta.dart';

/// ─────────────────────────────────────────────────────────────────────────────
/// FACEBOOK MESSENGER BRIDGE COMMAND DEFINITIONS
/// In the management room, prefixing with `!fb` is not required, but both
/// prefixless and `!fb` prefixed commands are supported.
/// ─────────────────────────────────────────────────────────────────────────────
class FacebookBridgeCommands {
  FacebookBridgeCommands._();

  static const String prefix = '!fb';

  static String _cmd(String command, {bool withPrefix = false}) =>
      withPrefix ? '!fb $command' : command;

  // General Commands
  static String cancel({bool withPrefix = false}) => _cmd('cancel', withPrefix: withPrefix);
  static String help({bool withPrefix = false}) => _cmd('help', withPrefix: withPrefix);
  static String setManagementRoom({bool withPrefix = false}) =>
      _cmd('set-management-room', withPrefix: withPrefix);
  static String version({bool withPrefix = false}) => _cmd('version', withPrefix: withPrefix);

  // Authentication Commands
  static String listLogins({bool withPrefix = false}) =>
      _cmd('list-logins', withPrefix: withPrefix);

  static String login([String? flowId, bool withPrefix = false]) =>
      flowId != null && flowId.trim().isNotEmpty
          ? _cmd('login $flowId', withPrefix: withPrefix)
          : _cmd('login', withPrefix: withPrefix);

  static String loginCookies(String jsonOrCookies, {bool withPrefix = false}) =>
      _cmd('login $jsonOrCookies', withPrefix: withPrefix);

  static String loginMatrix(String accessToken, {bool withPrefix = false}) =>
      _cmd('login-matrix $accessToken', withPrefix: withPrefix);

  static String logout([String? loginId, bool withPrefix = false]) =>
      loginId != null && loginId.trim().isNotEmpty
          ? _cmd('logout $loginId', withPrefix: withPrefix)
          : _cmd('logout', withPrefix: withPrefix);

  static String logoutMatrix({bool withPrefix = false}) =>
      _cmd('logout-matrix', withPrefix: withPrefix);

  static String pingMatrix({bool withPrefix = false}) =>
      _cmd('ping-matrix', withPrefix: withPrefix);

  static String relogin(String loginId, [String? flowId, bool withPrefix = false]) =>
      flowId != null && flowId.trim().isNotEmpty
          ? _cmd('relogin $loginId $flowId', withPrefix: withPrefix)
          : _cmd('relogin $loginId', withPrefix: withPrefix);

  static String setPreferredLogin(String loginId, {bool withPrefix = false}) =>
      _cmd('set-preferred-login $loginId', withPrefix: withPrefix);

  static String setRelay(String loginId, {bool withPrefix = false}) =>
      _cmd('set-relay $loginId', withPrefix: withPrefix);

  static String unsetRelay({bool withPrefix = false}) =>
      _cmd('unset-relay', withPrefix: withPrefix);

  // Starting and Managing Chats
  static String bridge(String chatId, [String? loginId, bool withPrefix = false]) =>
      loginId != null && loginId.trim().isNotEmpty
          ? _cmd('bridge $loginId $chatId', withPrefix: withPrefix)
          : _cmd('bridge $chatId', withPrefix: withPrefix);

  static String createGroup([String? groupType, bool withPrefix = false]) =>
      groupType != null && groupType.trim().isNotEmpty
          ? _cmd('create-group $groupType', withPrefix: withPrefix)
          : _cmd('create-group', withPrefix: withPrefix);

  static String createPortal(String chatId, [String? loginId, bool withPrefix = false]) =>
      loginId != null && loginId.trim().isNotEmpty
          ? _cmd('create-portal $loginId $chatId', withPrefix: withPrefix)
          : _cmd('create-portal $chatId', withPrefix: withPrefix);

  static String deleteChat({bool forEveryone = false, bool withPrefix = false}) =>
      forEveryone
          ? _cmd('delete-chat --for-everyone', withPrefix: withPrefix)
          : _cmd('delete-chat', withPrefix: withPrefix);

  static String id({bool withPrefix = false}) => _cmd('id', withPrefix: withPrefix);

  static String mute([String? duration, bool withPrefix = false]) =>
      duration != null && duration.trim().isNotEmpty
          ? _cmd('mute $duration', withPrefix: withPrefix)
          : _cmd('mute', withPrefix: withPrefix);

  static String resolveIdentifier(String identifier, [String? loginId, bool withPrefix = false]) =>
      loginId != null && loginId.trim().isNotEmpty
          ? _cmd('resolve-identifier $loginId $identifier', withPrefix: withPrefix)
          : _cmd('resolve-identifier $identifier', withPrefix: withPrefix);

  static String search(String query, {bool withPrefix = false}) =>
      _cmd('search $query', withPrefix: withPrefix);

  static String startChat(String identifier, [String? loginId, bool withPrefix = false]) =>
      loginId != null && loginId.trim().isNotEmpty
          ? _cmd('start-chat $loginId $identifier', withPrefix: withPrefix)
          : _cmd('start-chat $identifier', withPrefix: withPrefix);

  static String syncPortal({bool withPrefix = false}) =>
      _cmd('sync-portal', withPrefix: withPrefix);

  static String toggleEncryption({bool withPrefix = false}) =>
      _cmd('toggle-encryption', withPrefix: withPrefix);

  static String unbridge({bool withPrefix = false}) =>
      _cmd('unbridge', withPrefix: withPrefix);

  // Miscellaneous
  static String importImagePack(String url, {bool withPrefix = false}) =>
      _cmd('import-image-pack $url', withPrefix: withPrefix);

  // Administration
  static String doIn(String roomId, String command, [List<String>? args, bool withPrefix = false]) {
    final argStr = args != null && args.isNotEmpty ? ' ${args.join(' ')}' : '';
    return _cmd('doin $roomId $command$argStr', withPrefix: withPrefix);
  }
}

/// ─────────────────────────────────────────────────────────────────────────────
/// FACEBOOK MESSENGER DISCONNECT & MANAGEMENT SERVICE
/// Handles disconnection, session revocation, room wiping, and portal syncing.
/// ─────────────────────────────────────────────────────────────────────────────
class FacebookMessengerDisconnectService {
  FacebookMessengerDisconnectService._();

  /// Initiates a full disconnect for Facebook Messenger:
  /// 1. Sends `logout` (and `logout-matrix`) to the management room.
  /// 2. Invokes unified [AccountLifecycleService.disconnectNetwork] to mark cache,
  ///    hide portal rooms immediately, and schedule permanent Matrix room wiping.
  static Future<DisconnectResult> beginDisconnect(
    Client client, {
    String? loginId,
    void Function(Iterable<String> roomIds)? onRoomsForgotten,
  }) async {
    debugPrint('🔌 [FacebookBridge] Initiating Messenger account disconnect...');

    // Try finding management room and sending logout directly before wiping
    final botRoom = await findOrCreateManagementRoom(client, createIfMissing: false);
    if (botRoom != null) {
      try {
        String? targetLoginId = loginId;
        if (targetLoginId == null || targetLoginId.isEmpty) {
          final cached = NetworkConnectionCache.get(NetworkId.messenger);
          if (cached.accountLabel != null && cached.accountLabel!.isNotEmpty) {
            final match = RegExp(r'\d{6,}').firstMatch(cached.accountLabel!);
            if (match != null) {
              targetLoginId = match.group(0);
            }
          }
        }

        if (targetLoginId != null && targetLoginId.isNotEmpty) {
          final logoutCmd = '!fb logout $targetLoginId';
          debugPrint('📤 [FacebookBridge] Sending "$logoutCmd" to ${botRoom.id}');
          await botRoom.sendTextEvent(logoutCmd);
        } else {
          final logoutCmd = FacebookBridgeCommands.logout();
          debugPrint('📤 [FacebookBridge] Sending "$logoutCmd" to ${botRoom.id}');
          await botRoom.sendTextEvent(logoutCmd);
        }
        await Future.delayed(const Duration(milliseconds: 300));
        await botRoom.sendTextEvent(FacebookBridgeCommands.logoutMatrix());
      } catch (e) {
        debugPrint('⚠️ [FacebookBridge] Error sending logout command: $e');
      }
    }

    // Unified lifecycle disconnect handles sticky cache, room wipe, and hidden rooms
    return AccountLifecycleService.disconnectNetwork(
      client,
      NetworkId.messenger,
      onRoomsForgotten: onRoomsForgotten,
    );
  }

  /// Finds or creates the dedicated Facebook Messenger management bot room.
  static Future<Room?> findOrCreateManagementRoom(
    Client client, {
    bool createIfMissing = true,
  }) async {
    final userDomain = client.userID?.split(':').last;
    if (userDomain == null) return null;

    final discoveredBot =
        BridgeRoomClassifier.findBridgeBotMxid(client, NetworkId.messenger);

    final botMxids = [
      if (discoveredBot != null && discoveredBot.isNotEmpty)
        discoveredBot.toLowerCase(),
      '@messengerbot:$userDomain',
      '@messenger:$userDomain',
      '@facebookbot:$userDomain',
      '@facebook:$userDomain',
      '@fb_bot:$userDomain',
      '@fb:$userDomain',
      '@meta_bot:$userDomain',
      '@metabot:$userDomain',
      '@facebookgo_bot:$userDomain',
    ];

    // 1. Try finding existing unencrypted room via AccountLifecycleService
    Room? botRoom =
        AccountLifecycleService.findManagementRoom(client, NetworkId.messenger);
    if (botRoom != null && !botRoom.encrypted) return botRoom;

    // 2. Scan client rooms for unencrypted directChatMatrixID or bot participant or management name
    for (final room in client.rooms) {
      if (room.isSpace) continue;
      if (room.encrypted) continue; // Bridge management requires unencrypted room

      final direct = (room.directChatMatrixID ?? '').toLowerCase();
      if (botMxids.any((id) => direct == id.toLowerCase())) {
        return room;
      }
      final participants = room.getParticipants();
      final hasPuppet = participants.any((p) {
        final pid = p.id.toLowerCase();
        return pid.contains('_facebook_') ||
            pid.contains('_messenger_') ||
            pid.contains('@facebook_') ||
            pid.contains('@fb_');
      });
      if (hasPuppet) continue;

      final hasBot = participants.any((p) {
        final id = p.id.toLowerCase();
        return botMxids.any((b) => b.toLowerCase() == id) ||
            id.startsWith('@messengerbot:') ||
            id.startsWith('@facebookbot:') ||
            id.startsWith('@meta_bot:') ||
            id.startsWith('@metabot:');
      });
      if (hasBot) {
        return room;
      }

      final name = room.displayname.toLowerCase().trim();
      if (name == 'facebook messenger bridge' ||
          name == 'messenger bridge' ||
          name == 'facebook bridge' ||
          name == 'messenger bridge bot') {
        return room;
      }
    }

    if (!createIfMissing) return null;

    // 3. Create unencrypted management room and invite the bot
    try {
      final primaryBotMxid = discoveredBot ?? '@messengerbot:$userDomain';
      debugPrint('🔨 [FacebookBridge] Creating clean unencrypted Facebook management room with $primaryBotMxid');

      final roomId = await client.createRoom(
        name: 'Facebook Messenger Bridge',
        isDirect: false,
        preset: CreateRoomPreset.privateChat,
        invite: [primaryBotMxid],
      );

      int retries = 0;
      botRoom = null;
      while (botRoom == null && retries < 15) {
        await Future.delayed(const Duration(milliseconds: 300));
        botRoom = client.getRoomById(roomId);
        if (botRoom != null) break;
        try {
          await client.sync();
        } catch (_) {}
        retries++;
      }

      if (botRoom != null) {
        // Invite candidate bots if different from primary
        for (final alt in botMxids) {
          if (alt != primaryBotMxid.toLowerCase()) {
            try {
              await botRoom.invite(alt);
            } catch (_) {}
          }
        }

        // Send set-management-room to ensure bridge registers this room
        await Future.delayed(const Duration(milliseconds: 500));
        try {
          await botRoom.sendTextEvent(FacebookBridgeCommands.setManagementRoom());
        } catch (_) {}
      }

      return botRoom;
    } catch (e) {
      debugPrint('⚠️ [FacebookBridge] Failed to create management room: $e');
      return null;
    }
  }

  /// Sends sync commands to the bridge bot to refresh portals.
  static Future<void> forceSyncPortals(Client client) async {
    try {
      final botRoom =
          await findOrCreateManagementRoom(client, createIfMissing: true);
      if (botRoom != null) {
        debugPrint('📤 [FacebookBridge] Sending sync-portal & list-logins');
        await botRoom.sendTextEvent(FacebookBridgeCommands.syncPortal());
        await Future.delayed(const Duration(milliseconds: 500));
        await botRoom.sendTextEvent(FacebookBridgeCommands.listLogins());
      }
    } catch (e) {
      debugPrint('⚠️ [FacebookBridge] Error sending force sync: $e');
    }
  }

  /// Requests active logins list from the bridge bot.
  static Future<void> listLogins(Client client) async {
    try {
      final botRoom =
          await findOrCreateManagementRoom(client, createIfMissing: true);
      if (botRoom != null) {
        await botRoom.sendTextEvent(FacebookBridgeCommands.listLogins());
      }
    } catch (e) {
      debugPrint('⚠️ [FacebookBridge] Error querying logins: $e');
    }
  }

  /// Pings Matrix double puppeting to ensure message sync is working.
  static Future<void> pingMatrix(Client client) async {
    try {
      final botRoom =
          await findOrCreateManagementRoom(client, createIfMissing: true);
      if (botRoom != null) {
        await botRoom.sendTextEvent(FacebookBridgeCommands.pingMatrix());
      }
    } catch (e) {
      debugPrint('⚠️ [FacebookBridge] Error pinging matrix double puppet: $e');
    }
  }

  /// Cancels any pending login or ongoing bridge action.
  static Future<void> cancelPendingAction(Client client) async {
    try {
      final botRoom =
          await findOrCreateManagementRoom(client, createIfMissing: false);
      if (botRoom != null) {
        await botRoom.sendTextEvent(FacebookBridgeCommands.cancel());
      }
    } catch (e) {
      debugPrint('⚠️ [FacebookBridge] Error sending cancel: $e');
    }
  }

  /// Checks whether a room is a Facebook Messenger portal room.
  static bool isMessengerRoom(Room room, {Client? client}) =>
      BridgeRoomClassifier.isRoomForNetwork(room, NetworkId.messenger,
          client: client);

  /// Strict management (bot control) room check for Facebook Messenger.
  static bool isManagementRoom(Room room) {
    if (AccountLifecycleService.findManagementRoom(
            room.client, NetworkId.messenger)?.id ==
        room.id) {
      return true;
    }
    final userDomain = room.client.userID?.split(':').last;
    if (userDomain == null) return false;
    final botMxid =
        metaFor(NetworkId.messenger).botMxid(userDomain).toLowerCase();
    final direct = (room.directChatMatrixID ?? '').toLowerCase();
    if (direct == botMxid ||
        direct.startsWith('@messengerbot:') ||
        direct.startsWith('@facebookbot:')) {
      return true;
    }
    return false;
  }
}
