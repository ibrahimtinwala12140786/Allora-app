import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/allora_avatar.dart';
import '../../core/utils/matrix_media.dart';
import '../../providers/network_provider.dart';
import '../../data/services/contacts_service.dart';
import 'status_viewer_screen.dart';

class StatusScreen extends ConsumerStatefulWidget {
  const StatusScreen({super.key});

  @override
  ConsumerState<StatusScreen> createState() => _StatusScreenState();
}

class _StatusScreenState extends ConsumerState<StatusScreen> {
  Room? _statusRoom;
  Timeline? _timeline;
  List<Event> _events = [];
  bool _loading = true;
  StreamSubscription? _timelineSub;
  SharedPreferences? _prefs;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _init();
    });
  }

  @override
  void dispose() {
    _timelineSub?.cancel();
    _timeline?.cancelSubscriptions();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      final client = ref.read(matrixClientProvider);
      
      _statusRoom = client.rooms.where(
        (r) {
          final name = r.getLocalizedDisplayname().toLowerCase();
          return (name.contains('status broadcast') || name.contains('whatsapp status')) &&
              r.membership == Membership.join;
        },
      ).firstOrNull;
      
      if (_statusRoom != null) {
        _timeline = await _statusRoom!.getTimeline(onUpdate: _updateEvents);
        _updateEvents();
        if (_timeline!.canRequestHistory && _events.length < 50) {
          await _timeline!.requestHistory(historyCount: 100);
          _updateEvents();
        }
      }
    } catch (e) {
      debugPrint('StatusScreen error: $e');
    } finally {
      if (mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _loading = false);
        });
      }
    }
  }

  void _updateEvents() {
    if (!mounted || _timeline == null) return;
    
    final events = _timeline!.events.where((e) {
      if (e.redacted) return false;
      if (e.type != EventTypes.Message && e.type != EventTypes.Encrypted) return false;
      if (e.body.startsWith("Unknown message format of type") && MatrixMedia.mxcOf(e) == null) return false;
      return true;
    }).toList();
    
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        setState(() => _events = events);
      }
    });
  }

  void _markAsSeen(String senderId, int timestamp) {
    if (_prefs == null) return;
    final key = 'status_seen_$senderId';
    final current = _prefs!.getInt(key) ?? 0;
    if (timestamp > current) {
      _prefs!.setInt(key, timestamp);
      if (mounted) {
        setState(() {});
      }
    }
  }

  bool _hasUnseen(String senderId, List<Event> senderEvents) {
    if (_prefs == null || senderEvents.isEmpty) return true;
    final key = 'status_seen_$senderId';
    final lastSeen = _prefs!.getInt(key) ?? 0;
    final latestEventTs = senderEvents
        .map((e) => e.originServerTs.millisecondsSinceEpoch)
        .reduce((a, b) => a > b ? a : b);
    return latestEventTs > lastSeen;
  }

  bool _isUserStatus(String senderId, Client client) {
    if (senderId == client.userID) return true;
    final myLocal = client.userID?.split(':').first.replaceAll('@', '');
    if (myLocal != null && myLocal.isNotEmpty && (senderId.contains(myLocal) || myLocal.contains(senderId.split(':').first.replaceAll('@', '')))) {
      return true;
    }
    final supaId = Supabase.instance.client.auth.currentUser?.id.replaceAll('-', '');
    if (supaId != null && supaId.isNotEmpty && senderId.contains(supaId)) {
      return true;
    }
    return false;
  }

  String _resolveSenderName(String senderId, List<Event> events, Client client, ContactsNotifier contacts) {
    if (_isUserStatus(senderId, client)) {
      return 'My status';
    }

    // 1. Try Matrix member display name (Push Name from WhatsApp)
    String pushName = '';
    try {
      final member = _statusRoom?.unsafeGetUserFromMemoryOrFallback(senderId);
      final calcName = member?.calcDisplayname();
      if (calcName != null && calcName.isNotEmpty && !calcName.startsWith('@') && !calcName.startsWith('whatsapp_')) {
        pushName = calcName;
      }
    } catch (_) {}

    if (pushName.isEmpty && events.isNotEmpty) {
      try {
        final calc = events.last.senderFromMemoryOrFallback.calcDisplayname();
        if (calc.isNotEmpty && !calc.startsWith('@') && !calc.startsWith('whatsapp_')) {
          pushName = calc;
        }
      } catch (_) {}
    }

    // 2. Resolve with Phone & SIM Contacts
    final resolved = contacts.resolveName(senderId, pushName);
    if (resolved.isNotEmpty && !ContactsNotifier.isBotDisplayName(resolved) && !ContactsNotifier.isBotMxid(resolved)) {
      return resolved;
    }
    if (pushName.isNotEmpty && !ContactsNotifier.isBotDisplayName(pushName) && !ContactsNotifier.isBotMxid(pushName)) {
      return pushName;
    }

    // 3. Clean up phone number / bridge identifier
    final digits = senderId.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.length >= 7) {
      final fromDigits = contacts.resolveName(digits, '');
      if (fromDigits.isNotEmpty && !ContactsNotifier.isBotDisplayName(fromDigits)) return fromDigits;
      return ContactsNotifier.formatPhoneNumber(digits, digits);
    }

    final fallback = senderId.split(':').first.replaceFirst('@', '').replaceFirst(RegExp(r'^(whatsapp_|telegram_|signal_)'), '');
    return fallback.isNotEmpty ? fallback : 'Unknown';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.allora;
    // Watch contacts so that list automatically refreshes once phone/SIM contacts finish loading
    ref.watch(contactsProvider);
    final contacts = ref.read(contactsProvider.notifier);
    final client = ref.read(matrixClientProvider);

    // Group events by sender
    final grouped = <String, List<Event>>{};
    for (final e in _events) {
      grouped.putIfAbsent(e.senderId, () => []).add(e);
    }

    // Separate user's own status from other contacts
    List<Event>? myStatusEvents;
    String? myStatusSenderId;

    for (final senderId in grouped.keys) {
      if (_isUserStatus(senderId, client)) {
        myStatusEvents = grouped[senderId];
        myStatusSenderId = senderId;
        break;
      }
    }

    // Other contacts' senders
    final contactSenders = grouped.keys.where((s) => s != myStatusSenderId).toList();
    contactSenders.sort((a, b) {
      final aLatest = grouped[a]!.map((e) => e.originServerTs).reduce((e1, e2) => e1.isAfter(e2) ? e1 : e2);
      final bLatest = grouped[b]!.map((e) => e.originServerTs).reduce((e1, e2) => e1.isAfter(e2) ? e1 : e2);
      return bLatest.compareTo(aLatest);
    });

    if (myStatusEvents != null) {
      myStatusEvents.sort((a, b) => a.originServerTs.compareTo(b.originServerTs));
    }

    return Scaffold(
      backgroundColor: c.canvas,
      appBar: AppBar(
        title: Text(
          'Status',
          style: TextStyle(color: c.text, fontWeight: FontWeight.w700),
        ),
        backgroundColor: c.surface,
        elevation: 0,
        iconTheme: IconThemeData(color: c.text),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _statusRoom == null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.donut_large_rounded, size: 56, color: c.textTertiary),
                      const SizedBox(height: 16),
                      Text(
                        'No status updates yet',
                        style: TextStyle(
                          color: c.text,
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Status updates from bridged accounts will appear here.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: c.textSecondary, fontSize: 13),
                      ),
                    ],
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  children: [
                    // ── 1. My Status Tile (WhatsApp Style) ──
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                      leading: Stack(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(2),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: myStatusEvents != null && myStatusEvents.isNotEmpty
                                    ? c.accent
                                    : c.outline,
                                width: 2.5,
                              ),
                            ),
                            child: AlloraAvatar(
                              name: 'You',
                              size: 48,
                            ),
                          ),
                          if (myStatusEvents == null || myStatusEvents.isEmpty)
                            Positioned(
                              right: 0,
                              bottom: 0,
                              child: Container(
                                width: 20,
                                height: 20,
                                decoration: BoxDecoration(
                                  color: c.accent,
                                  shape: BoxShape.circle,
                                  border: Border.all(color: c.canvas, width: 2),
                                ),
                                child: const Icon(Icons.add, size: 12, color: Colors.white),
                              ),
                            ),
                        ],
                      ),
                      title: Text(
                        'My status',
                        style: TextStyle(
                          color: c.text,
                          fontWeight: FontWeight.w600,
                          fontSize: 16,
                        ),
                      ),
                      subtitle: Text(
                        myStatusEvents != null && myStatusEvents.isNotEmpty
                            ? 'Today at ${myStatusEvents.last.originServerTs.hour.toString().padLeft(2, '0')}:${myStatusEvents.last.originServerTs.minute.toString().padLeft(2, '0')}'
                            : 'Tap to add status update',
                        style: TextStyle(color: c.textSecondary, fontSize: 13),
                      ),
                      onTap: () {
                        if (myStatusEvents != null && myStatusEvents.isNotEmpty) {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => StatusViewerScreen(
                                events: myStatusEvents!,
                                senderName: 'My status',
                                authHeaders: {'Authorization': 'Bearer ${_statusRoom!.client.accessToken}'},
                                onSeen: () {},
                              ),
                            ),
                          );
                        }
                      },
                    ),

                    if (contactSenders.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        child: Text(
                          'RECENT UPDATES',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: c.textTertiary,
                            letterSpacing: 0.8,
                          ),
                        ),
                      ),
                      // ── 2. Recent Contact Statuses ──
                      ...contactSenders.map((senderId) {
                        final senderEvents = grouped[senderId]!;
                        senderEvents.sort((a, b) => a.originServerTs.compareTo(b.originServerTs));

                        final hasUnseen = _hasUnseen(senderId, senderEvents);
                        final name = _resolveSenderName(senderId, senderEvents, client, contacts);
                        final time = senderEvents.last.originServerTs;

                        return ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                          leading: Container(
                            padding: const EdgeInsets.all(2),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: hasUnseen ? c.accent : c.outline,
                                width: 2.5,
                              ),
                            ),
                            child: AlloraAvatar(
                              name: name,
                              size: 48,
                            ),
                          ),
                          title: Text(
                            name,
                            style: TextStyle(
                              color: c.text,
                              fontWeight: FontWeight.w600,
                              fontSize: 16,
                            ),
                          ),
                          subtitle: Text(
                            '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}',
                            style: TextStyle(color: c.textSecondary, fontSize: 13),
                          ),
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => StatusViewerScreen(
                                  events: senderEvents,
                                  senderName: name,
                                  authHeaders: {'Authorization': 'Bearer ${_statusRoom!.client.accessToken}'},
                                  onSeen: () {
                                    final latestTs = senderEvents.last.originServerTs.millisecondsSinceEpoch;
                                    _markAsSeen(senderId, latestTs);
                                  },
                                ),
                              ),
                            );
                          },
                        );
                      }),
                    ],
                  ],
                ),
    );
  }
}
