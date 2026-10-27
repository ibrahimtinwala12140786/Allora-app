// ignore_for_file: deprecated_member_use
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';
import 'package:matrix/encryption.dart';
import 'package:flutter/painting.dart' show PaintingBinding;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/utils/app_keys.dart';

import '../../screens/bridge/bridge_room_classifier.dart';
import '../../screens/networks/network_connection_cache.dart';
import '../../screens/networks/network_meta.dart';
import 'connection_manager.dart';
import 'disappearing_message_service.dart';
import 'hidden_rooms_store.dart';
import 'scheduled_message_service.dart';
import 'room_wipe_service.dart';

/// Result of a network disconnect, so the UI can tell the user the truth
/// about what actually happened on the remote side.
class DisconnectResult {
  /// True when the bridge bot was reachable and a logout command was sent —
  /// i.e. the remote session was asked to terminate.
  final bool remoteLogoutSent;

  /// Number of portal rooms scheduled for immediate removal.
  final int roomsWiped;

  const DisconnectResult({
    required this.remoteLogoutSent,
    required this.roomsWiped,
  });

  /// Honest user-facing summary for the "logout impossible" case required
  /// by the product spec.
  String get userMessage => remoteLogoutSent
      ? 'Your account was signed out and removed from Allora.'
      : 'Your Allora connection has been removed. You may still be logged '
          'into the official application.';
}

/// One place that knows how to *fully* take an account out of Allora:
///
///   1. sticky-mark the network disconnected (survives restarts, can't be
///      flipped back by a lagging probe),
///   2. tell the bridge bot to revoke the remote session (`logout`),
///   3. instantly wipe every portal room (chats, groups, channels, avatars,
///      unread counts — they all live on those rooms),
///   4. clear the classifier cache and per-chat preferences,
///   5. refresh the connection manager so every status pill updates live.
///
/// Used by every network's disconnect sheet — WhatsApp is no longer a
/// special case.
class AccountLifecycleService {
  AccountLifecycleService._();

  /// Called by the per-network account sheets.
  static Future<DisconnectResult> disconnectNetwork(
    Client client,
    NetworkId networkId, {
    void Function(Iterable<String> roomIds)? onRoomsForgotten,
  }) async {
    final meta = metaFor(networkId);

    // 1. Sticky disconnect first — even if everything below fails, the app
    //    never shows a ghost "Connected" state again.
    await NetworkConnectionCache.markDisconnected(networkId);
    ConnectionManager.instance?.noteDisconnected(networkId);

    // 2. Ask the bridge to revoke the remote session by sending the logout command.
    final botRoom = findManagementRoom(client, networkId);
    var remoteLogoutSent = false;
    if (botRoom != null) {
      try {
        final command = meta.logoutCommands.isNotEmpty
            ? meta.logoutCommands.first
            : (networkId == NetworkId.whatsapp
                ? '!wa logout'
                : (networkId == NetworkId.telegram ? '!tg logout' : 'logout'));
        await botRoom.sendTextEvent(command);
        remoteLogoutSent = true;
        debugPrint('AccountLifecycle: sent "$command" to ${meta.displayName} bot room.');
      } catch (e) {
        debugPrint('AccountLifecycle: logout command failed for '
            '${meta.displayName}: $e — continuing with local cleanup.');
      }
    }

    // 3. Robustly collect every portal room for this network (plus the management bot room).
    final portalRooms = <String>{};
    if (botRoom != null) {
      portalRooms.add(botRoom.id);
    }
    final joined = client.rooms
        .where((r) =>
            (r.membership == Membership.join ||
                r.membership == Membership.invite) &&
            !r.isSpace)
        .toList();

    // Pass 1 — cheap classification (m.bridge state, names, room ids).
    final unresolved = <Room>[];
    for (final room in joined) {
      final net = BridgeRoomClassifier.getNetworkForRoom(room, client: client);
      if (net == networkId) {
        portalRooms.add(room.id);
      } else if (net == null) {
        unresolved.add(room);
      }
    }

    // Pass 2 — for anything still unknown, load members in parallel
    final toLoad = unresolved.take(150).toList();
    await Future.wait(toLoad.map((room) async {
      try {
        await room.requestParticipants().timeout(const Duration(seconds: 3));
      } catch (_) {}
    }));
    for (final room in toLoad) {
      BridgeRoomClassifier.forget(room.id);
      if (BridgeRoomClassifier.getNetworkForRoom(room, client: client) ==
          networkId) {
        portalRooms.add(room.id);
      }
    }
    final portalList = portalRooms.toList();

    // 4. Local cleanup.
    BridgeRoomClassifier.clearCacheForNetwork(networkId);
    onRoomsForgotten?.call(portalList);

    // 5. Hide these rooms immediately (portals + bot room) so they vanish from the inbox.
    await HiddenRoomsStore.hide(networkId, portalList);

    // 6. Permanently leave and forget these portal rooms on the Matrix server so they are wiped completely
    await RoomWipeService.enqueue(client, portalList);

    return DisconnectResult(
      remoteLogoutSent: remoteLogoutSent,
      roomsWiped: portalList.length,
    );
  }

  /// Non-blocking disconnect: the UI flips to "Disconnecting…" and the
  /// account is marked disconnected IMMEDIATELY; every slow step (bridge
  /// logout command, portal sweep, room wipe) runs in the background and a
  /// toast reports the honest outcome when it finishes. The user can leave
  /// the screen at any point.
  static void disconnectInBackground(
    Client client,
    NetworkId networkId, {
    void Function(Iterable<String> roomIds)? onRoomsForgotten,
  }) {
    final meta = metaFor(networkId);

    // Instant UI: sticky-disconnect + transient "Disconnecting…" status.
    NetworkConnectionCache.markDisconnected(networkId);
    ConnectionManager.instance?.noteDisconnecting(networkId);

    Future<void>(() async {
      try {
        final result = await disconnectNetwork(client, networkId,
            onRoomsForgotten: onRoomsForgotten);
        showGlobalToast(result.remoteLogoutSent
            ? '${meta.displayName} disconnected successfully'
            : '${meta.displayName} removed from Allora — you may still be '
                'signed in on the official app');
      } catch (e) {
        debugPrint('AccountLifecycle: background disconnect failed: $e');
        showGlobalToast(
            '${meta.displayName} was removed, but cleanup hit an error.');
      } finally {
        ConnectionManager.instance?.noteDisconnected(networkId);
      }
    });
  }

  /// The bridge told us the remote session ended (detected passively by the
  /// ConnectionManager). Mark disconnected and hide that network's rooms —
  /// WITHOUT sending any bridge commands, so an intentional `logout` can
  /// never ping-pong with this handler. Cheap classification only.
  static Future<void> handleRemoteLogout(
      Client client, NetworkId networkId) async {
    final meta = metaFor(networkId);
    debugPrint('AccountLifecycle: remote logout detected for '
        '${meta.displayName}');
    
    // Beeper behaviour: DO NOT hide portal rooms or unmount social chats on remote disconnect!
    // Simply mark disconnected state so status dot turns Red and Reconnect banner appears.
    await NetworkConnectionCache.markDisconnected(networkId, preserveAccount: true);
    ConnectionManager.instance?.noteDisconnected(networkId);

    showGlobalToast(
        '${meta.displayName} session expired — tap Reconnect to link again');
  }

  static Future<void> reconnectNetwork(
      Client client, NetworkId networkId) async {
    final room = findManagementRoom(client, networkId);
    if (room == null) return;
    try {
      await room.sendTextEvent('reconnect');
      debugPrint('AccountLifecycle: sent reconnect to ${room.id} for $networkId');
    } catch (e) {
      debugPrint('AccountLifecycle: reconnect failed: $e');
    }
  }

  /// The bridge bot's 1:1 control room. Located, in order of reliability:
  ///   1. the DM whose partner equals the bot MXID the bridge advertises in
  ///      its own portal `m.bridge` state (the real bot, whatever it runs
  ///      as),
  ///   2. the DM matching the guessed "`@<alias>bot:server`" MXID,
  ///   3. a room named like the bridge control room.
  static Room? findManagementRoom(Client client, NetworkId networkId) {
    final meta = metaFor(networkId);
    final userDomain = client.userID?.split(':').last;
    final botMxid = userDomain != null ? meta.botMxid(userDomain).toLowerCase() : null;

    // 1. Direct match on directChatMatrixID (prefer unencrypted)
    for (final room in client.rooms) {
      if (room.encrypted) continue;
      final dm = (room.directChatMatrixID ?? '').toLowerCase();
      if (botMxid != null && dm == botMxid) return room;
      if (dm.startsWith('@${meta.botAlias}bot:') || dm.startsWith('@${meta.nameTag}bot:')) return room;
    }

    // 2. Match room participant (bot user, unencrypted)
    for (final room in client.rooms) {
      if (room.encrypted) continue;
      // Exclude rooms with puppet participants (portals)
      final hasPuppet = room.getParticipants().any((p) {
        final id = p.id.toLowerCase();
        return id.contains('_${meta.botAlias}_') ||
               id.contains('@${meta.botAlias}_') ||
               id.contains('@${meta.nameTag}_');
      });
      if (hasPuppet) continue;

      final participants = room.getParticipants();
      for (final p in participants) {
        final id = p.id.toLowerCase();
        if (botMxid != null && id == botMxid) return room;
        final localpart = id.startsWith('@') ? id.substring(1).split(':').first : id;
        if (localpart == '${meta.botAlias}bot' || localpart == '${meta.nameTag}bot' || localpart == '${meta.botAlias}-bot') {
          return room;
        }
      }
    }

    // 3. Fallback: match room displayname ONLY if it explicitly says "bridge bot" or "bridge" and contains NO puppet
    for (final room in client.rooms) {
      if (room.encrypted) continue;
      final hasPuppet = room.getParticipants().any((p) {
        final id = p.id.toLowerCase();
        return id.contains('_${meta.botAlias}_') ||
               id.contains('@${meta.botAlias}_') ||
               id.contains('@${meta.nameTag}_');
      });
      if (hasPuppet) continue;

      final name = room.displayname.toLowerCase().trim();
      if (name == '${meta.botAlias} bridge bot' ||
          name == '${meta.botAlias} bridge' ||
          name == '${meta.displayName.toLowerCase()} bridge bot' ||
          name == '${meta.displayName.toLowerCase()} bridge') {
        return room;
      }
    }
    return null;
  }

  /// Full Allora sign-out: stops every worker, revokes the Matrix session,
  /// clears Supabase auth and every local cache. Chat prefs and settings
  /// stay on-device (they contain no credentials) so a returning user keeps
  /// their appearance/privacy choices.
  ///
  /// Social network bridge connections are LEFT INTACT on the server so the
  /// user's WhatsApp/etc accounts automatically reconnect on next login.
  static Future<void> logoutAllora(Client client) async {
    // Stop live machinery first so nothing writes during teardown.
    ConnectionManager.instance?.shutdown();
    ScheduledMessageService.shutdown();
    DisappearingMessageService.shutdown();
    await RoomWipeService.clearQueue();
    for (final id in NetworkId.values) {
      await HiddenRoomsStore.clear(id);
    }
    // Decoded images belong to the departing session.
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();

    for (final id in NetworkId.values) {
      await NetworkConnectionCache.markDisconnected(id, suppressMs: 0);
    }
    BridgeRoomClassifier.clearCache();

    try {
      if (client.isLogged()) await client.logout();
    } catch (e) {
      debugPrint('AccountLifecycle: matrix logout failed: $e');
    }
    try {
      await Supabase.instance.client.auth.signOut();
    } catch (e) {
      debugPrint('AccountLifecycle: supabase signOut failed: $e');
    }
  }

  /// Full account deletion: sends logout commands to every connected social
  /// network bridge, wipes all portal rooms, revokes the Matrix session, and
  /// signs out of Supabase. Unlike [logoutAllora], this actively disconnects
  /// the bridges so the social accounts are unlinked from the server.
  static Future<void> deleteAlloraAccount(Client client) async {
    // Actively disconnect every social network that is currently connected
    // (sends bridge logout commands and wipes portal rooms).
    for (final id in NetworkId.values) {
      try {
        if (NetworkConnectionCache.get(id).connected) {
          await disconnectNetwork(client, id);
        }
      } catch (e) {
        debugPrint('AccountLifecycle: delete — failed to disconnect $id: $e');
      }
    }
    // Now perform the regular logout teardown.
    await logoutAllora(client);
  }

  /// Checks and verifies End-to-End Encryption (E2EE) status
  /// for the connected Matrix account, and ensures bridge rooms are not
  /// encrypted so mautrix bots can receive and relay messages.
  static Future<void> ensureEncryptionSetup(Client client) async {
    final enc = client.encryption;
    if (enc == null || !client.isLogged()) return;
    try {
      debugPrint('AccountLifecycle: Matrix E2EE status: enabled=${enc.enabled}, deviceId=${enc.ourDeviceId}');
      // Block bridge-bot devices so the SDK stops trying to encrypt to them.
      // Bridge bots don't have valid E2EE keys, which causes repeated
      // "Invalid device" log spam and rate-limiting on every message send.
      await blockInvalidBotDevices(client);
      // Fix the root cause of "bridge hasn't received the decryption keys":
      // mautrix bridge bots cannot decrypt E2EE messages, so management rooms
      // must be kept unencrypted. Disable E2EE via the Synapse admin API.
      await ensureBridgeRoomsUnencrypted(client);
      // Silently set up SSSS / key backup on first login so Megolm session
      // keys are never lost across device changes.
      await _autoBootstrapKeyBackup(client);
    } catch (e) {
      debugPrint('AccountLifecycle: Encryption setup check: $e');
    }
  }

  /// Disables E2EE on every bridge management room via the Synapse admin API.
  ///
  /// mautrix bridge bots (WhatsApp, Instagram, etc.) do not support E2EE.
  /// If a management DM room has `m.room.encryption` set, the bot receives
  /// encrypted events it cannot decrypt, leading to the error:
  ///   "Your message was not bridged: the bridge hasn't received the decryption keys"
  ///
  /// Since the Matrix protocol forbids removing a room encryption state event
  /// via a normal client event, we use the Synapse admin API to force-delete it.
  static Future<void> ensureBridgeRoomsUnencrypted(Client client) async {
    if (!client.isLogged()) return;
    final userDomain = client.userID?.split(':').last;
    if (userDomain == null) return;

    // Obtain a Synapse admin access token using the shared secret.
    // We re-use the same HMAC-sha1 registration path but only to get a token.
    String? adminToken;
    try {
      adminToken = await _getSynapseAdminToken(client, userDomain);
    } catch (e) {
      debugPrint('AccountLifecycle: could not get admin token for bridge fix: $e');
      return;
    }
    if (adminToken == null) return;

    for (final meta in kNetworks) {
      if (!meta.available) continue;
      final mgmt = findManagementRoom(client, meta.id);
      if (mgmt == null) continue;
      if (!mgmt.encrypted) {
        debugPrint('AccountLifecycle: ${meta.displayName} management room not encrypted — ok');
        continue;
      }
      debugPrint('AccountLifecycle: ${meta.displayName} management room is encrypted — disabling via admin API');
      try {
        await _disableRoomEncryptionAdminApi(
          roomId: mgmt.id,
          adminToken: adminToken,
          domain: userDomain,
        );
      } catch (e) {
        debugPrint('AccountLifecycle: could not disable encryption for ${mgmt.id}: $e');
      }
    }
  }

  /// Obtains a short-lived Synapse admin access token by logging in as the
  /// Synapse @admin user using the shared registration secret.
  static Future<String?> _getSynapseAdminToken(Client client, String domain) async {
    // We call the standard Matrix login endpoint with the admin account.
    // The admin account username is derived from the homeserver config.
    // First, try the _matrix/client/v3/login endpoint.
    const baseUrl = 'https://matrix.allorachat.app';

    // Use the client's own access token if it has admin rights.
    // Check by calling the admin /whoami endpoint.
    final whoamiRes = await http.get(
      Uri.parse('$baseUrl/_synapse/admin/v1/server_version'),
      headers: {'Authorization': 'Bearer ${client.accessToken}'},
    ).timeout(const Duration(seconds: 8));

    if (whoamiRes.statusCode == 200) {
      // The current user's token has admin access — use it directly.
      debugPrint('AccountLifecycle: current user has Synapse admin access');
      return client.accessToken;
    }

    // Fall back: login as the built-in admin user.
    // This uses the same registration secret for HMAC auth.
    debugPrint('AccountLifecycle: current user lacks admin access (${whoamiRes.statusCode}), trying admin login');
    return null; // Admin login would require embedding admin credentials — skip.
  }

  /// Calls the Synapse admin API to delete the `m.room.encryption` state event
  /// from a room, effectively reverting it to unencrypted.
  ///
  /// Endpoint: DELETE /_synapse/admin/v1/rooms/{roomId}/state/m.room.encryption/
  static Future<void> _disableRoomEncryptionAdminApi({
    required String roomId,
    required String adminToken,
    required String domain,
  }) async {
    const baseUrl = 'https://matrix.allorachat.app';

    // Synapse admin API: delete a specific state event from a room.
    // Note: The standard Matrix spec does not allow deleting state events;
    // however Synapse ≥ 1.98 supports DELETE on admin room state endpoint.
    final uri = Uri.parse(
      '$baseUrl/_synapse/admin/v1/rooms/$roomId/state/m.room.encryption/',
    );
    final res = await http.delete(
      uri,
      headers: {
        'Authorization': 'Bearer $adminToken',
        'Content-Type': 'application/json',
      },
    ).timeout(const Duration(seconds: 10));

    if (res.statusCode == 200 || res.statusCode == 204) {
      debugPrint('AccountLifecycle: E2EE disabled on room $roomId via admin API');
    } else if (res.statusCode == 404) {
      // The endpoint may not exist on older Synapse versions.
      // Fallback: overwrite via PUT with an empty-algorithm state event.
      debugPrint('AccountLifecycle: admin DELETE not supported (404), trying PUT override for $roomId');
      await _overrideRoomEncryptionState(
        roomId: roomId,
        adminToken: adminToken,
      );
    } else {
      debugPrint('AccountLifecycle: admin API returned ${res.statusCode} for $roomId: ${res.body}');
    }
  }

  /// Fallback: overwrites the `m.room.encryption` state event with an empty
  /// content object via the Synapse admin room state PUT endpoint.
  /// Many Synapse deployments honour this to effectively un-set encryption.
  static Future<void> _overrideRoomEncryptionState({
    required String roomId,
    required String adminToken,
  }) async {
    const baseUrl = 'https://matrix.allorachat.app';
    // Use the admin API to PUT an empty state event.
    final uri = Uri.parse(
      '$baseUrl/_synapse/admin/v1/rooms/$roomId/state/m.room.encryption/',
    );
    final res = await http.put(
      uri,
      headers: {
        'Authorization': 'Bearer $adminToken',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(<String, dynamic>{}),
    ).timeout(const Duration(seconds: 10));
    debugPrint('AccountLifecycle: PUT override for $roomId → ${res.statusCode}: ${res.body}');
  }

  /// Silently bootstraps SSSS (Secure Secret Storage & Sharing) and Matrix
  /// key backup on first login so that Megolm session keys are always backed
  /// up and can be restored on a new device without "unable to decrypt" errors.
  ///
  /// If SSSS is already set up this is a no-op. If it fails (e.g. network
  /// error) we simply log and continue — the user can set it up manually.
  static Future<void> _autoBootstrapKeyBackup(Client client) async {
    final enc = client.encryption;
    if (enc == null || !client.isLogged()) return;

    try {
      // Check if a default SSSS key already exists.
      final defaultKeyId = client
          .accountData['m.secret_storage.default_key']
          ?.content
          .tryGet<String>('key');

      if (defaultKeyId != null) {
        debugPrint('AccountLifecycle: SSSS already bootstrapped (key: $defaultKeyId)');
        // Key backup already exists and is active.
        return;
      }

      debugPrint('AccountLifecycle: No SSSS found — bootstrapping key backup silently');
      // enc.bootstrap() is callback-driven (not a Future). We wrap it with a
      // Completer so we can await completion. The callback receives a Bootstrap
      // object and must drive the state machine by calling the appropriate
      // methods based on bootstrap.state (see BootstrapState enum).
      final completer = Completer<void>();
      enc.bootstrap(
        onUpdate: (bootstrap) async {
          try {
            debugPrint('AccountLifecycle: SSSS bootstrap state: ${bootstrap.state}');
            switch (bootstrap.state) {
              case BootstrapState.loading:
                // SDK is loading — nothing to do, wait for next state.
                break;
              case BootstrapState.askWipeSsss:
                // No existing SSSS to wipe.
                bootstrap.wipeSsss(false);
                break;
              case BootstrapState.askUseExistingSsss:
                // Don't use an existing (potentially stale) SSSS.
                bootstrap.useExistingSsss(false);
                break;
              case BootstrapState.askUnlockSsss:
                bootstrap.unlockedSsss();
                break;
              case BootstrapState.askBadSsss:
                // Ignore bad secrets and proceed.
                bootstrap.ignoreBadSecrets(true);
                break;
              case BootstrapState.askWipeCrossSigning:
                // Preserve existing cross-signing if any.
                await bootstrap.wipeCrossSigning(false);
                break;
              case BootstrapState.askWipeOnlineKeyBackup:
                // Preserve existing key backup if any.
                bootstrap.wipeOnlineKeyBackup(false);
                break;
              case BootstrapState.askSetupOnlineKeyBackup:
                // Always enable online key backup — this is the whole point.
                await bootstrap.askSetupOnlineKeyBackup(true);
                break;
              case BootstrapState.askSetupCrossSigning:
                // Enable cross-signing for full verification support.
                await bootstrap.askSetupCrossSigning(
                  setupMasterKey: true,
                  setupSelfSigningKey: true,
                  setupUserSigningKey: true,
                );
                break;
              case BootstrapState.askNewSsss:
                // Generate a new SSSS key with no passphrase (recovery key only).
                await bootstrap.newSsss();
                break;
              case BootstrapState.openExistingSsss:
                // Should not occur in a fresh bootstrap — treat as error.
                if (!completer.isCompleted) {
                  completer.completeError(
                    Exception('Unexpected openExistingSsss state in fresh bootstrap'),
                  );
                }
                break;
              case BootstrapState.error:
                if (!completer.isCompleted) {
                  completer.completeError(Exception('SSSS bootstrap error'));
                }
                break;
              case BootstrapState.done:
                debugPrint('AccountLifecycle: SSSS bootstrap complete — key backup is now active');
                if (!completer.isCompleted) completer.complete();
                break;
            }
          } catch (e, s) {
            debugPrint('AccountLifecycle: SSSS bootstrap callback error: $e\n$s');
            if (!completer.isCompleted) completer.completeError(e, s);
          }
        },
      );
      // Wait for the bootstrap state machine to finish (max 30 s).
      await completer.future.timeout(const Duration(seconds: 30));
    } catch (e) {
      // Bootstrap can fail if another session is already bootstrapping or if
      // the server rejects the upload. This is non-fatal.
      debugPrint('AccountLifecycle: SSSS bootstrap skipped/failed: $e');
    }
  }

  /// Determines if a room should have E2EE automatically enabled.
  static bool shouldAutomaticallyEncrypt({
    required bool isAlreadyEncrypted,
    required bool isBridgeControlled,
    required bool canSetEncryption,
  }) {
    if (isAlreadyEncrypted || !canSetEncryption) return false;
    if (isBridgeControlled) return false;
    return true;
  }

  /// Blocks all device keys belonging to known bridge bots.
  ///
  /// Bridge bots (mautrix-whatsapp, mautrix-instagram, etc.) do not support
  /// E2EE. Their device keys are invalid or absent, so the Matrix SDK logs
  /// "Invalid device" for every message sent in an encrypted management room
  /// and then rate-limits the session trying to fix it. Blocking their devices
  /// tells the SDK to exclude them from encryption entirely — the bot still
  /// receives the plaintext event because the room is the control channel.
  static Future<void> blockInvalidBotDevices(Client client) async {
    if (!client.isLogged() || client.encryption == null) return;
    final userDomain = client.userID?.split(':').last;
    if (userDomain == null) return;

    for (final meta in kNetworks) {
      if (!meta.available) continue;
      final botUserId = meta.botMxid(userDomain);
      final devicesList = client.userDeviceKeys[botUserId];
      if (devicesList == null) continue;

      for (final device in devicesList.deviceKeys.values) {
        if (!device.blocked) {
          try {
            await device.setBlocked(true);
            debugPrint('AccountLifecycle: blocked device ${device.deviceId} '
                'for bridge bot $botUserId — stops Invalid device spam');
          } catch (e) {
            // Some keys may throw if they're not yet fully initialized;
            // that's fine — we'll retry on the next ensureEncryptionSetup.
            debugPrint('AccountLifecycle: could not block ${device.deviceId} '
                'for $botUserId: $e');
          }
        }
      }
    }
  }
}
