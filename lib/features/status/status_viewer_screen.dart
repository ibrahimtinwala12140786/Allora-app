import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/utils/matrix_media.dart';

class StatusViewerScreen extends StatefulWidget {
  final List<Event> events;
  final String senderName;
  final Map<String, String> authHeaders;
  final VoidCallback onSeen;

  const StatusViewerScreen({
    super.key,
    required this.events,
    required this.senderName,
    required this.authHeaders,
    required this.onSeen,
  });

  @override
  State<StatusViewerScreen> createState() => _StatusViewerScreenState();
}

class _StatusViewerScreenState extends State<StatusViewerScreen> {
  late PageController _pageController;
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    widget.onSeen(); // Mark as seen immediately when opened.
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _next() {
    if (_currentIndex < widget.events.length - 1) {
      _pageController.nextPage(duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
    } else {
      Navigator.pop(context);
    }
  }

  void _previous() {
    if (_currentIndex > 0) {
      _pageController.previousPage(duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            PageView.builder(
              controller: _pageController,
              itemCount: widget.events.length,
              onPageChanged: (index) {
                setState(() => _currentIndex = index);
              },
              itemBuilder: (context, index) {
                final event = widget.events[index];
                return GestureDetector(
                  onTapUp: (details) {
                    final width = MediaQuery.of(context).size.width;
                    if (details.globalPosition.dx < width / 3) {
                      _previous();
                    } else {
                      _next();
                    }
                  },
                  child: _StatusMediaItem(
                    event: event,
                    authHeaders: widget.authHeaders,
                    onFinished: _next,
                  ),
                );
              },
            ),
            
            // Progress indicators
            Positioned(
              top: 10,
              left: 10,
              right: 10,
              child: Row(
                children: List.generate(widget.events.length, (index) {
                  return Expanded(
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 2),
                      height: 3,
                      decoration: BoxDecoration(
                        color: index <= _currentIndex ? Colors.white : Colors.white.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(1.5),
                      ),
                    ),
                  );
                }),
              ),
            ),
            
            // Header
            Positioned(
              top: 24,
              left: 8,
              right: 8,
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                    onPressed: () => Navigator.pop(context),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.senderName,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        shadows: [Shadow(color: Colors.black54, blurRadius: 4)],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusMediaItem extends StatefulWidget {
  final Event event;
  final Map<String, String> authHeaders;
  final VoidCallback onFinished;

  const _StatusMediaItem({
    required this.event,
    required this.authHeaders,
    required this.onFinished,
  });

  @override
  State<_StatusMediaItem> createState() => _StatusMediaItemState();
}

class _StatusMediaItemState extends State<_StatusMediaItem> {
  Player? _player;
  VideoController? _controller;
  
  @override
  void initState() {
    super.initState();
    _initMedia();
  }

  void _initMedia() {
    final type = widget.event.content['msgtype'];
    if (type == 'm.video') {
      final src = MatrixMedia.download(widget.event.room.client, MatrixMedia.mxcOf(widget.event));
      if (src != null) {
        _player = Player();
        _controller = VideoController(_player!);
        _player!.open(Media(src.url, httpHeaders: src.headers));
        _player!.play();
        _player!.stream.completed.listen((completed) {
          if (completed && mounted) widget.onFinished();
        });
      }
    }
  }

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final type = widget.event.content['msgtype'];
    final body = widget.event.content['body']?.toString() ?? '';

    if (type == 'm.image') {
      final src = MatrixMedia.download(widget.event.room.client, MatrixMedia.mxcOf(widget.event));
      if (src != null) {
        return Image.network(
          src.url,
          headers: src.headers,
          fit: BoxFit.contain,
          errorBuilder: (c, e, s) => const Center(child: Icon(Icons.broken_image, color: Colors.white54, size: 64)),
        );
      }
    } else if (type == 'm.video' && _controller != null) {
      return Center(
        child: Video(
          controller: _controller!,
          controls: NoVideoControls,
        ),
      );
    }
    
    // Fallback for text/other
    return Container(
      color: Colors.blueGrey.shade800,
      padding: const EdgeInsets.all(24),
      alignment: Alignment.center,
      child: Text(
        body,
        style: const TextStyle(color: Colors.white, fontSize: 24),
        textAlign: TextAlign.center,
      ),
    );
  }
}
