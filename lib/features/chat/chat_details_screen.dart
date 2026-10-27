// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matrix/matrix.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/matrix_media.dart';
import '../../core/widgets/allora_avatar.dart';
import '../../data/services/contacts_service.dart';
import '../../data/services/disappearing_message_service.dart';
import '../../data/services/room_wipe_service.dart';
import '../../data/settings/app_settings.dart';
import '../../data/settings/labels.dart';
import '../../screens/bridge/bridge_room_classifier.dart';
import '../../screens/networks/network_meta.dart';
import 'widgets/disappearing_sheet.dart';
import 'widgets/image_viewer.dart';
import 'chat_screen.dart';

/// Chat profile: hero avatar, quick toggles (mute / pin / archive / hide),
/// disappearing timer, shared media grid, members (for groups) and
/// leave/delete.
class ChatDetailsScreen extends ConsumerStatefulWidget {
  final Room room;
  const ChatDetailsScreen({super.key, required this.room});

  @override
  ConsumerState<ChatDetailsScreen> createState() => _ChatDetailsScreenState();
}

class _ChatDetailsScreenState extends ConsumerState<ChatDetailsScreen> {
  List<Event> _media = const [];
  bool _loadingMedia = true;
  bool _showAllMembers = false;
  bool _loadingMembers = true;

  Room get room => widget.room;

  @override
  void initState() {
    super.initState();
    _loadMedia();
    _loadMembers();
  }

  Future<void> _loadMembers() async {
    try {
      await room.requestParticipants();
      if (mounted) {
        setState(() {
          _loadingMembers = false;
        });
      }
    } catch (e) {
      debugPrint('Failed to request participants: $e');
      if (mounted) {
        setState(() {
          _loadingMembers = false;
        });
      }
    }
  }

  Future<void> _loadMedia() async {
    try {
      final timeline = await room.getTimeline();
      if (timeline.canRequestHistory) {
        await timeline.requestHistory(historyCount: 120);
      }
      final media = timeline.events
          .where((e) =>
              !e.redacted &&
              e.content['msgtype'] == 'm.image' &&
              e.content['url'] is String)
          .take(30)
          .toList();
      if (mounted) {
        setState(() {
          _media = media;
          _loadingMedia = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingMedia = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.allora;
    final settings = ref.watch(settingsProvider);
    final title = ref.read(contactsProvider.notifier).resolveContactHierarchy(room: room);
    final networkId = BridgeRoomClassifier.getNetworkForRoom(room,
        client: room.client);
    final network = networkId != null ? metaFor(networkId) : null;
    final muted = room.pushRuleState == PushRuleState.dontNotify;
    final pinned = settings.pinnedChats.contains(room.id);
    final archived = settings.archivedChats.contains(room.id);
    final ttl = DisappearingMessageService.effectiveSeconds(room,
        settings: ref.read(settingsProvider.notifier));
    final members = room.getParticipants()
      .where((m) {
        final localpart = m.id.split(':').first.toLowerCase();
        return !localpart.endsWith('bot') && !localpart.contains('bridge') && localpart != '@allora';
      })
      .toList()
      ..sort((a, b) => a.calcDisplayname().compareTo(b.calcDisplayname()));

    return Scaffold(
      backgroundColor: c.canvas,
      appBar: AppBar(),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          Center(
            child: Column(
              children: [
                GestureDetector(
                  onTap: () {
                    final uri = AlloraAvatar.resolveUri(room);
                    if (uri == null) return;
                    final src = MatrixMedia.download(room.client, uri.toString());
                    if (src == null) return;
                    Navigator.of(context).push(ImageViewerScreen.route(
                      url: src.url,
                      headers: src.headers,
                      heroTag: 'avatar_${room.id}',
                      title: title,
                    ));
                  },
                  child: Hero(
                    tag: 'avatar_${room.id}',
                    child: AlloraAvatar(
                      name: title,
                      mxcUri: AlloraAvatar.resolveUri(room),
                      client: room.client,
                      size: 96,
                      network: network,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Text(
                    title,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.4,
                        color: c.text),
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.shield_rounded,
                      size: 14,
                      color: const Color(0xFF10B981),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      'Allora Secured',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: const Color(0xFF10B981),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                _quickAction(
                  icon: muted
                      ? Icons.notifications_off_rounded
                      : Icons.notifications_active_rounded,
                  label: muted ? 'Muted' : 'Mute',
                  active: muted,
                  onTap: () async {
                    try {
                      await room.setPushRuleState(muted
                          ? PushRuleState.notify
                          : PushRuleState.dontNotify);
                      setState(() {});
                    } catch (_) {}
                  },
                ),
                _quickAction(
                  icon: Icons.push_pin_rounded,
                  label: pinned ? 'Pinned' : 'Pin',
                  active: pinned,
                  onTap: () {
                    final ok = ref
                        .read(settingsProvider.notifier)
                        .togglePinned(room.id);
                    if (!ok && context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: const Text(
                              'You can only pin up to 4 chats. Please unpin a chat first.'),
                          behavior: SnackBarBehavior.floating,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                      );
                    }
                  },
                ),
                _quickAction(
                  icon: Icons.archive_rounded,
                  label: archived ? 'Archived' : 'Archive',
                  active: archived,
                  onTap: () => ref
                      .read(settingsProvider.notifier)
                      .setArchived(room.id, !archived),
                ),
                _quickAction(
                  icon: Icons.visibility_off_rounded,
                  label: 'Hide',
                  active: false,
                  onTap: () {
                    ref.read(settingsProvider.notifier).setHidden(room.id, true);
                    Navigator.popUntil(context, (r) => r.isFirst);
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          _card(children: [
            ListTile(
              leading: Icon(Icons.timer_outlined, color: c.textSecondary),
              title: const Text('Disappearing messages'),
              subtitle: Text(DisappearingMessageService.labelFor(ttl)),
              trailing: Icon(Icons.chevron_right_rounded, color: c.textTertiary),
              onTap: () => showDisappearingSheet(context, ref, room),
            ),
          ]),
          if (_loadingMedia || _media.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 18, 24, 8),
              child: Text('SHARED MEDIA',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                      color: c.textTertiary)),
            ),
            SizedBox(
              height: 92,
              child: _loadingMedia
                  ? const Center(
                      child: SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2)))
                  : ListView.builder(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: _media.length,
                      itemBuilder: (context, i) {
                        final event = _media[i];
                        final mxc = MatrixMedia.mxcOf(event);
                        final thumb = MatrixMedia.thumbnail(room.client, mxc,
                            width: 300, height: 300);
                        final full = MatrixMedia.download(room.client, mxc);
                        if (thumb == null || full == null) {
                          return const SizedBox.shrink();
                        }
                        return Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: GestureDetector(
                            onTap: () => Navigator.of(context).push(
                                ImageViewerScreen.route(
                                    url: full.url,
                                    headers: full.headers,
                                    heroTag: 'media_${event.eventId}')),
                            child: Hero(
                              tag: 'media_${event.eventId}',
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: Image.network(thumb.url,
                                    headers: thumb.headers,
                                    width: 92,
                                    height: 92,
                                    cacheWidth: 300,
                                    fit: BoxFit.cover),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
          if (members.length > 2 || !BridgeRoomClassifier.isDirectChat(room, client: room.client)) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 18, 24, 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('MEMBERS · ${members.length}',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.8,
                          color: c.textTertiary)),
                  if (_loadingMembers)
                    SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.8,
                        valueColor: AlwaysStoppedAnimation<Color>(c.textTertiary),
                      ),
                    ),
                ],
              ),
            ),
            _card(children: [
              for (final m in (_showAllMembers ? members : members.take(10)))
                () {
                  final rawName = m.calcDisplayname().replaceAll(RegExp(r'\s*\((?:WA|TG|IG|FB|DC|SL)\)'), '');
                  final memberName = m.id == room.client.userID ? rawName : ref.read(contactsProvider.notifier).resolveName(m.id, rawName);
                  return ListTile(
                    leading: AlloraAvatar(
                      name: memberName,
                      mxcUri: m.avatarUrl,
                      client: room.client,
                      size: 38,
                      showNetworkBadge: false,
                    ),
                    title: Text(
                      memberName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: m.id == room.client.userID ? FontWeight.w700 : FontWeight.w500,
                        color: c.text,
                      ),
                    ),
                    subtitle: m.id == room.client.userID
                        ? Text('You', style: TextStyle(fontSize: 12, color: c.textSecondary))
                        : null,
                    onTap: () {
                      if (m.id != room.client.userID) {
                        showModalBottomSheet(
                          context: context,
                          isScrollControlled: true,
                          backgroundColor: Colors.transparent,
                          builder: (ctx) => MemberActionSheet(member: m, room: room),
                        );
                      }
                    },
                  );
                }(),
              if (members.length > 10)
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () {
                      HapticFeedback.selectionClick();
                      setState(() => _showAllMembers = !_showAllMembers);
                    },
                    borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16)),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            _showAllMembers
                                ? 'Show less'
                                : 'Show all ${members.length} members (+${members.length - 10} more)',
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              color: c.accent,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Icon(
                            _showAllMembers
                                ? Icons.keyboard_arrow_up_rounded
                                : Icons.keyboard_arrow_down_rounded,
                            size: 18,
                            color: c.accent,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ]),
          ],
          const SizedBox(height: 18),
          _card(children: [
            ListTile(
              leading: Icon(Icons.delete_outline_rounded, color: c.danger),
              title: Text('Delete chat',
                  style: TextStyle(color: c.danger)),
              onTap: _confirmDelete,
            ),
          ]),
        ],
      ),
    );
  }

  Widget _quickAction({
    required IconData icon,
    required String label,
    required bool active,
    required VoidCallback onTap,
  }) {
    final c = context.allora;
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              color: active ? c.accent.withValues(alpha: 0.12) : c.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: active ? c.accent : c.outline),
            ),
            child: Column(
              children: [
                Icon(icon, size: 20, color: active ? c.accent : c.textSecondary),
                const SizedBox(height: 5),
                Text(label,
                    style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: active ? c.accent : c.textSecondary)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _card({required List<Widget> children}) {
    final c = context.allora;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.outline),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: c.surface,
        child: Column(children: children),
      ),
    );
  }

  void _confirmDelete() {
    final c = context.allora;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete chat?'),
        content: Text(
          'This removes the conversation from Allora. Bridged conversations '
          'remain on the original network.',
          style: TextStyle(color: c.textSecondary, height: 1.4),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await RoomWipeService.enqueue(room.client, [room.id]);
              ref.read(settingsProvider.notifier).forgetRooms([room.id]);
              ref.read(labelsProvider.notifier).forgetRooms([room.id]);
              if (mounted) Navigator.popUntil(context, (r) => r.isFirst);
            },
            child: Text('Delete', style: TextStyle(color: c.danger)),
          ),
        ],
      ),
    );
  }
}

class MemberActionSheet extends StatefulWidget {
  final User member;
  final Room room;

  const MemberActionSheet({super.key, required this.member, required this.room});

  @override
  State<MemberActionSheet> createState() => _MemberActionSheetState();
}

class _MemberActionSheetState extends State<MemberActionSheet> {
  bool _working = false;

  void _makeAdmin() async {
    setState(() => _working = true);
    try {
      final powerLevels = widget.room.getState(EventTypes.RoomPowerLevels);
      if (powerLevels != null) {
        final content = Map<String, dynamic>.from(powerLevels.content);
        final users = Map<String, dynamic>.from(content['users'] as Map? ?? {});
        users[widget.member.id] = 50;
        content['users'] = users;
        await widget.room.client.setRoomStateWithKey(widget.room.id, EventTypes.RoomPowerLevels, '', content);
      }
      if (mounted) Navigator.pop(context);
    } catch (e) {
      debugPrint('Error making admin: $e');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  void _removeMember() async {
    setState(() => _working = true);
    try {
      await widget.room.kick(widget.member.id);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      debugPrint('Error removing member: $e');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.allora;
    final name = widget.member.calcDisplayname().replaceAll(' (WA)', '');
    final powerLevelsContent = widget.room.getState(EventTypes.RoomPowerLevels)?.content;
    final Map<String, dynamic> users = {};
    final dynamic rawUsers = powerLevelsContent?['users'];
    if (rawUsers is Map) {
      users.addAll(Map<String, dynamic>.from(rawUsers));
    }
    final int defaultPower = powerLevelsContent?['users_default'] as int? ?? 0;
    
    final myPowerLevel = users[widget.room.client.userID] as int? ?? defaultPower;
    final theirPowerLevel = users[widget.member.id] as int? ?? defaultPower;

    final bool amIAdmin = myPowerLevel >= 50;
    final bool canPromote = amIAdmin && theirPowerLevel < 50;
    final bool canKick = amIAdmin && theirPowerLevel < myPowerLevel;

    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: const EdgeInsets.only(top: 24, bottom: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Center(
            child: GestureDetector(
              onTap: () {
                if (widget.member.avatarUrl != null) {
                  final source = MatrixMedia.download(widget.room.client, widget.member.avatarUrl?.toString());
                  if (source != null) {
                    Navigator.of(context).push(ImageViewerScreen.route(url: source.url, headers: source.headers, heroTag: 'avatar_${widget.member.id}'));
                  }
                }
              },
              child: Hero(
                tag: 'avatar_${widget.member.id}',
                child: AlloraAvatar(
                  name: name,
                  mxcUri: widget.member.avatarUrl,
                  client: widget.room.client,
                  size: 80,
                  showNetworkBadge: false,
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            name,
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: c.text),
          ),
          const SizedBox(height: 4),
          Text(
            widget.member.id.startsWith('@whatsapp_') ? '+${widget.member.id.split('_')[1].split(':')[0].replaceAll('lid', '')}' : widget.member.id,
            style: TextStyle(fontSize: 14, color: c.textSecondary),
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _actionButton(Icons.message_rounded, 'Message', c, onTap: () {
                final dmRoom = widget.room.client.rooms.where((r) => r.isDirectChat && r.getParticipants().any((p) => p.id == widget.member.id)).firstOrNull;
                if (dmRoom != null) {
                  Navigator.pop(context);
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(room: dmRoom)));
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No direct chat found')));
                }
              }),
              _actionButton(Icons.call_rounded, 'Audio', c),
              _actionButton(Icons.videocam_rounded, 'Video', c),
              _actionButton(Icons.currency_rupee_rounded, 'Pay', c),
            ],
          ),
          const SizedBox(height: 16),
          const Divider(height: 1),
          ListTile(
            leading: Icon(Icons.info_outline_rounded, color: c.textSecondary),
            title: Text('Info', style: TextStyle(color: c.text)),
            onTap: () {},
          ),
          ListTile(
            leading: Icon(Icons.security_rounded, color: c.textSecondary),
            title: Text('Verify security code', style: TextStyle(color: c.text)),
            onTap: () {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Verification sent')));
            },
          ),
          if (canPromote)
            ListTile(
              leading: Icon(Icons.admin_panel_settings_rounded, color: c.textSecondary),
              title: Text('Make group admin', style: TextStyle(color: c.text)),
              onTap: _working ? null : _makeAdmin,
            ),
          if (canKick)
            ListTile(
              leading: Icon(Icons.remove_circle_outline_rounded, color: c.danger),
              title: Text('Remove from group', style: TextStyle(color: c.danger)),
              onTap: _working ? null : _removeMember,
            ),
        ],
      ),
    );
  }

  Widget _actionButton(IconData icon, String label, dynamic c, {VoidCallback? onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            width: 50,
            height: 50,
            decoration: BoxDecoration(
              color: c.surfaceAlt,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: c.text),
          ),
          const SizedBox(height: 8),
          Text(label, style: TextStyle(fontSize: 12, color: c.textSecondary)),
        ],
      ),
    );
  }
}
