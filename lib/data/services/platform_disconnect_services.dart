import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

import '../../screens/networks/network_connection_cache.dart';
import '../../screens/networks/network_meta.dart';
import 'account_lifecycle.dart';

/// Outcome of a platform disconnect, with per-step visibility for
/// diagnostics/logging.
class PlatformDisconnectReport {
  final NetworkId network;
  final bool sessionWasActive;
  final bool remoteLogoutSent;
  final int roomsRemoved;
  final Duration elapsed;
  final String? error;

  const PlatformDisconnectReport({
    required this.network,
    required this.sessionWasActive,
    required this.remoteLogoutSent,
    required this.roomsRemoved,
    required this.elapsed,
    this.error,
  });

  bool get success => error == null;

  @override
  String toString() =>
      'Disconnect(${network.name}) active=$sessionWasActive '
      'remoteLogout=$remoteLogoutSent rooms=$roomsRemoved '
      'in=${elapsed.inMilliseconds}ms error=$error';
}

/// Base disconnect service. Every platform gets a named service (so
/// platform-specific behaviour has an obvious home), while the battle-tested
/// core — bridge revocation, portal sweep, guaranteed hide, instant wipe,
/// UI refresh — stays in ONE place: [AccountLifecycleService].
///
/// Pipeline per platform:
///   validate session → revoke via bridge (meta.logoutCommands) → clear
///   local state (cache/classifier/prefs) → remove rooms → refresh UI →
///   log a structured report.
abstract class PlatformDisconnectService {
  NetworkId get network;

  /// True when Allora currently believes this platform is linked.
  bool validateSession() => NetworkConnectionCache.get(network).connected;

  /// Hook for bridge-specific extra cleanup (rarely needed).
  Future<void> platformSpecificCleanup(Client client) async {}

  Future<PlatformDisconnectReport> disconnect(Client client) async {
    final watch = Stopwatch()..start();
    final wasActive = validateSession();
    try {
      final result =
          await AccountLifecycleService.disconnectNetwork(client, network);
      await platformSpecificCleanup(client);
      final report = PlatformDisconnectReport(
        network: network,
        sessionWasActive: wasActive,
        remoteLogoutSent: result.remoteLogoutSent,
        roomsRemoved: result.roomsWiped,
        elapsed: watch.elapsed,
      );
      debugPrint('DisconnectService: $report');
      return report;
    } catch (e) {
      final report = PlatformDisconnectReport(
        network: network,
        sessionWasActive: wasActive,
        remoteLogoutSent: false,
        roomsRemoved: 0,
        elapsed: watch.elapsed,
        error: e.toString(),
      );
      debugPrint('DisconnectService: $report');
      return report;
    }
  }
}

class WhatsAppPlatformDisconnectService extends PlatformDisconnectService {
  @override
  NetworkId get network => NetworkId.whatsapp;
}

class TelegramDisconnectService extends PlatformDisconnectService {
  @override
  NetworkId get network => NetworkId.telegram;
}

class InstagramDisconnectService extends PlatformDisconnectService {
  @override
  NetworkId get network => NetworkId.instagram;
}

class MessengerDisconnectService extends PlatformDisconnectService {
  @override
  NetworkId get network => NetworkId.messenger;
}

class DiscordDisconnectService extends PlatformDisconnectService {
  @override
  NetworkId get network => NetworkId.discord;
}

class SlackDisconnectService extends PlatformDisconnectService {
  @override
  NetworkId get network => NetworkId.slack;
}

class TwitterDisconnectService extends PlatformDisconnectService {
  @override
  NetworkId get network => NetworkId.x;
}

class SignalDisconnectService extends PlatformDisconnectService {
  @override
  NetworkId get network => NetworkId.signal;
}

class EmailDisconnectService extends PlatformDisconnectService {
  @override
  NetworkId get network => NetworkId.email;
}

class LinkedInDisconnectService extends PlatformDisconnectService {
  @override
  NetworkId get network => NetworkId.linkedin;
}

class LineDisconnectService extends PlatformDisconnectService {
  @override
  NetworkId get network => NetworkId.line;
}

/// Registry: service for any network id.
PlatformDisconnectService disconnectServiceFor(NetworkId id) {
  switch (id) {
    case NetworkId.whatsapp:
      return WhatsAppPlatformDisconnectService();
    case NetworkId.telegram:
      return TelegramDisconnectService();
    case NetworkId.instagram:
      return InstagramDisconnectService();
    case NetworkId.messenger:
      return MessengerDisconnectService();
    case NetworkId.discord:
      return DiscordDisconnectService();
    case NetworkId.slack:
      return SlackDisconnectService();
    case NetworkId.x:
      return TwitterDisconnectService();
    case NetworkId.signal:
      return SignalDisconnectService();
    case NetworkId.email:
      return EmailDisconnectService();
    case NetworkId.linkedin:
      return LinkedInDisconnectService();
    case NetworkId.line:
      return LineDisconnectService();
  }
}
