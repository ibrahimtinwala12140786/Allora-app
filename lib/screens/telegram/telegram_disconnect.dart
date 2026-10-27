import 'package:matrix/matrix.dart';

import '../../data/services/account_lifecycle.dart';
import '../bridge/bridge_room_classifier.dart';
import '../networks/network_meta.dart';

/// Telegram disconnect and management room helper service.
class TelegramDisconnectService {
  TelegramDisconnectService._();

  /// Initiates disconnect for Telegram: sends `logout` to bridge bot,
  /// hides Telegram portal rooms, and updates network connection status.
  static Future<DisconnectResult> beginDisconnect(Client client) {
    return AccountLifecycleService.disconnectNetwork(client, NetworkId.telegram);
  }

  /// Checks whether a room is a Telegram portal room.
  static bool isTelegramRoom(Room room, {Client? client}) =>
      BridgeRoomClassifier.isRoomForNetwork(room, NetworkId.telegram,
          client: client);

  /// Strict management (bot control) room check for Telegram.
  static bool isManagementRoom(Room room) {
    if (AccountLifecycleService.findManagementRoom(
            room.client, NetworkId.telegram)?.id ==
        room.id) {
      return true;
    }
    final userDomain = room.client.userID?.split(':').last;
    if (userDomain == null) return false;
    final botMxid =
        metaFor(NetworkId.telegram).botMxid(userDomain).toLowerCase();
    final direct = (room.directChatMatrixID ?? '').toLowerCase();
    if (direct == botMxid || direct.startsWith('@telegrambot:')) {
      return true;
    }
    return false;
  }
}
