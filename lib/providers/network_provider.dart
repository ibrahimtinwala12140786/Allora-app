import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matrix/matrix.dart';

import '../data/services/room_wipe_service.dart';
import '../screens/networks/network_connection_cache.dart';
import '../screens/networks/network_meta.dart';

/// Global Matrix client (overridden in main() with the real instance).
final matrixClientProvider =
    Provider<Client>((ref) => throw UnimplementedError());

/// Global VoIP instance for Matrix WebRTC calls.
final voipProvider = Provider<VoIP>((ref) => throw UnimplementedError());

enum NetworkStatus { connected, disconnected, available, comingSoon }

class NetworkAccount {
  final NetworkMeta meta;
  final NetworkStatus status;
  final String? accountLabel;
  final String? lastSynced;

  const NetworkAccount({
    required this.meta,
    required this.status,
    this.accountLabel,
    this.lastSynced,
  });
}

class NetworkHubState {
  final List<NetworkAccount> networks;
  final bool isGlobalLoading;
  final bool isWipePending;

  const NetworkHubState({
    required this.networks,
    this.isGlobalLoading = false,
    this.isWipePending = false,
  });

  NetworkHubState copyWith({
    List<NetworkAccount>? networks,
    bool? isGlobalLoading,
    bool? isWipePending,
  }) {
    return NetworkHubState(
      networks: networks ?? this.networks,
      isGlobalLoading: isGlobalLoading ?? this.isGlobalLoading,
      isWipePending: isWipePending ?? this.isWipePending,
    );
  }
}

class NetworkNotifier extends StateNotifier<NetworkHubState> {
  NetworkNotifier() : super(const NetworkHubState(networks: [])) {
    refreshCache();
    NetworkConnectionCache.notifier.addListener(refreshCache);
    RoomWipeService.pending.addListener(_syncWipeState);
    _syncWipeState();
  }

  @override
  void dispose() {
    NetworkConnectionCache.notifier.removeListener(refreshCache);
    RoomWipeService.pending.removeListener(_syncWipeState);
    super.dispose();
  }

  void _syncWipeState() {
    if (!mounted) return;
    state = state.copyWith(
        isWipePending: RoomWipeService.pending.value.isNotEmpty);
  }

  void refreshCache() {
    if (!mounted) return;
    final networks = kNetworks.map((meta) {
      if (!meta.available) {
        return NetworkAccount(meta: meta, status: NetworkStatus.comingSoon);
      }
      final cached = NetworkConnectionCache.get(meta.id);
      final NetworkStatus status;
      if (cached.connected) {
        status = NetworkStatus.connected;
      } else if (cached.accountLabel != null || (cached.hasData && !cached.manuallyDisconnected)) {
        status = NetworkStatus.disconnected;
      } else {
        status = NetworkStatus.available;
      }
      return NetworkAccount(
        meta: meta,
        status: status,
        accountLabel: cached.accountLabel,
        lastSynced: cached.lastSynced,
      );
    }).toList();
    state = state.copyWith(networks: networks);
  }


  void setGlobalLoading(bool loading) {
    state = state.copyWith(isGlobalLoading: loading);
  }
}

final networkHubProvider =
    StateNotifierProvider<NetworkNotifier, NetworkHubState>(
        (ref) => NetworkNotifier());
