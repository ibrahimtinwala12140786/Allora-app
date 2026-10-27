import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/settings/app_settings.dart';
import '../providers/network_provider.dart';
import '../screens/connection_screen/connect_networks_screen.dart';
import 'chat_list/chat_list_screen.dart';

/// The post-login home. Reactively shows:
///
///   • the Connect-networks screen while no platform is connected, and
///   • the chat list once at least one account links.
///
/// This lives *inside* LockGate and only swaps its own child, so the app
/// lock/FLAG_SECURE wrapper is preserved across the transition. The swap is
/// safe even while a connect sheet is open — the sheet is a separate route,
/// so it simply reveals the chat list when it closes.
import 'dart:async';
import 'package:matrix/matrix.dart';
import '../data/services/voip_delegate.dart';
import '../screens/bridge/bridge_room_classifier.dart';
import '../screens/voip_call_screen.dart';

class HomeGate extends ConsumerStatefulWidget {
  const HomeGate({super.key});

  @override
  ConsumerState<HomeGate> createState() => _HomeGateState();
}

class _HomeGateState extends ConsumerState<HomeGate> {
  StreamSubscription? _callSub;

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      final voip = ref.read(voipProvider);
      if (voip.delegate is AlloraWebRTCDelegate) {
        final delegate = voip.delegate as AlloraWebRTCDelegate;
        _callSub = delegate.onNewCall.listen((session) {
          if (!mounted) return;
          Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => VoipCallScreen(session: session),
          ));
        });
      }
    });
  }

  @override
  void dispose() {
    _callSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final client = ref.watch(matrixClientProvider);
    final hasConnectedOrDisconnected = ref.watch(
      networkHubProvider.select(
        (s) => s.networks.any((n) =>
            n.status == NetworkStatus.connected ||
            n.status == NetworkStatus.disconnected),
      ),
    );
    final hasValidRooms = client.rooms.any((r) =>
        r.membership == Membership.join &&
        !r.isSpace &&
        !BridgeRoomClassifier.isManagementRoom(r, client: client) &&
        !BridgeRoomClassifier.isEmptyOrGhostRoom(r, client: client));
    final showChatList = hasConnectedOrDisconnected || hasValidRooms;

    final reduceMotion = ref.watch(reduceMotionProvider);
    return AnimatedSwitcher(
      duration: Duration(milliseconds: reduceMotion ? 0 : 400),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeIn,
      child: showChatList
          ? const ChatListScreen(key: ValueKey('chats'))
          : ConnectNetworksScreen(
              key: const ValueKey('connect'),
              client: client,
            ),
    );
  }
}

