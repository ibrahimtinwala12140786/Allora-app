import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'package:intl/intl.dart';

import 'message_bubble.dart';
import 'image_viewer.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/matrix_media.dart';

class MediaGridBubble extends StatelessWidget {
  final List<Event> events;
  final Timeline timeline;
  final Function(String) onJumpTo;

  const MediaGridBubble({
    super.key,
    required this.events,
    required this.timeline,
    required this.onJumpTo,
  });

  @override
  Widget build(BuildContext context) {
    if (events.isEmpty) return const SizedBox.shrink();
    // Sort oldest to newest for visual flow (top-left to bottom-right)
    final sorted = List<Event>.from(events)..sort((a, b) => a.originServerTs.compareTo(b.originServerTs));
    
    final isMe = sorted.first.senderId == timeline.room.client.userID;
    final c = context.allora;
    final maxWidth = MediaQuery.of(context).size.width * 0.78;

    return Padding(
      padding: const EdgeInsets.only(left: 10, right: 10, top: 4, bottom: 4),
      child: Row(
        mainAxisAlignment: isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          Container(
            width: maxWidth,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: isMe ? c.bubbleMineDeep : c.surface,
              borderRadius: BorderRadius.circular(16),
              border: !isMe ? Border.all(color: c.outline, width: 0.8) : null,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04),
                  blurRadius: 4,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
            padding: const EdgeInsets.all(3.5),
            child: _buildGrid(context, sorted),
          ),
        ],
      ),
    );
  }

  Widget _buildGrid(BuildContext context, List<Event> sorted) {
    final count = sorted.length;
    if (count == 2) {
      return Row(
        children: [
          Expanded(child: _buildItem(context, sorted[0], height: 180)),
          const SizedBox(width: 3),
          Expanded(child: _buildItem(context, sorted[1], height: 180)),
        ],
      );
    } else if (count == 3) {
      return Column(
        children: [
          _buildItem(context, sorted[0], height: 160, width: double.infinity),
          const SizedBox(height: 3),
          Row(
            children: [
              Expanded(child: _buildItem(context, sorted[1], height: 120)),
              const SizedBox(width: 3),
              Expanded(child: _buildItem(context, sorted[2], height: 120)),
            ],
          ),
        ],
      );
    } else {
      // 4 or more
      return Column(
        children: [
          Row(
            children: [
              Expanded(child: _buildItem(context, sorted[0], height: 140)),
              const SizedBox(width: 3),
              Expanded(child: _buildItem(context, sorted[1], height: 140)),
            ],
          ),
          const SizedBox(height: 3),
          Row(
            children: [
              Expanded(child: _buildItem(context, sorted[2], height: 140)),
              const SizedBox(width: 3),
              Expanded(
                child: SizedBox(
                  height: 140,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Positioned.fill(
                        child: _buildItem(context, sorted[3], height: 140),
                      ),
                      if (count > 4)
                        Positioned.fill(
                          child: Container(
                            color: Colors.black.withValues(alpha: 0.5),
                            alignment: Alignment.center,
                            child: Text(
                              '+${count - 4}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 24,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      );
    }
  }

  Widget _buildItem(BuildContext context, Event event, {double? width, double? height}) {
    final mxc = event.content['url'] as String?;
    if (mxc == null) return Container(color: Colors.grey, height: height, width: width);

    final thumb = MatrixMedia.thumbnail(event.room.client, mxc, width: 400, height: 400);
    final full = MatrixMedia.download(event.room.client, mxc);

    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        width: width,
        height: height,
        child: GestureDetector(
          onTap: () {
            if (full == null) return;
            Navigator.of(context).push(ImageViewerScreen.route(
              url: full.url,
              headers: full.headers,
              heroTag: 'img_${event.eventId}',
              title: 'Image',
            ));
          },
          child: Image.network(
            thumb?.url ?? '',
            headers: thumb?.headers,
            fit: BoxFit.cover,
            errorBuilder: (c, e, s) => Container(color: Colors.grey.withValues(alpha: 0.3)),
          ),
        ),
      ),
    );
  }
}
