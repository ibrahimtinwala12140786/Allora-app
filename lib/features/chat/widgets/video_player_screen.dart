// ignore_for_file: deprecated_member_use
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/chat_time.dart';

/// In-app player for audio (AAC, MP3, AMR, M4A, OGG, WAV) & video (MP4, MOV, MKV, AVI, 3GP, FLV).
///
/// Uses `media_kit` with `httpHeaders`, so it can stream authenticated
/// Matrix media as well as local cache files.
class VideoPlayerScreen extends StatefulWidget {
  final String url;
  final Map<String, String> headers;
  final String? title;
  final bool isAudio;

  const VideoPlayerScreen({
    super.key,
    required this.url,
    required this.headers,
    this.title,
    this.isAudio = false,
  });

  static Route route({
    required String url,
    required Map<String, String> headers,
    String? title,
    bool isAudio = false,
  }) {
    return PageRouteBuilder(
      opaque: false,
      barrierColor: Colors.black,
      transitionDuration: const Duration(milliseconds: 240),
      reverseTransitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (_, __, ___) => VideoPlayerScreen(
        url: url,
        headers: headers,
        title: title,
        isAudio: isAudio,
      ),
      transitionsBuilder: (_, anim, __, child) =>
          FadeTransition(opacity: anim, child: child),
    );
  }

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen>
    with SingleTickerProviderStateMixin {
  late final Player _player = Player();
  late final VideoController _controller = VideoController(_player);
  bool _initializing = true;
  String? _error;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  double _rate = 1.0;

  StreamSubscription? _posSub;
  StreamSubscription? _durSub;
  StreamSubscription? _playSub;
  late final AnimationController _spinCtrl;

  @override
  void initState() {
    super.initState();
    _spinCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 12),
    );
    _init();
  }

  Future<void> _init() async {
    try {
      _posSub = _player.stream.position.listen((pos) {
        if (mounted) setState(() => _position = pos);
      });
      _durSub = _player.stream.duration.listen((dur) {
        if (mounted) setState(() => _duration = dur);
      });
      _playSub = _player.stream.playing.listen((playing) {
        if (mounted) {
          setState(() => _playing = playing);
          if (playing) {
            _spinCtrl.repeat();
          } else {
            _spinCtrl.stop();
          }
        }
      });

      await _player.open(Media(widget.url, httpHeaders: widget.headers));
      await _player.play();
      if (mounted) {
        setState(() {
          _initializing = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _initializing = false;
          _error = 'Couldn\u2019t play this media.';
        });
      }
    }
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _durSub?.cancel();
    _playSub?.cancel();
    _spinCtrl.dispose();
    _player.dispose();
    super.dispose();
  }

  void _toggleSpeed() {
    HapticFeedback.selectionClick();
    if (_rate == 1.0) {
      _rate = 1.5;
    } else if (_rate == 1.5) {
      _rate = 2.0;
    } else {
      _rate = 1.0;
    }
    _player.setRate(_rate);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black.withValues(alpha: 0.95),
      body: Stack(
        children: [
          if (_initializing)
            const Center(child: CircularProgressIndicator(color: Colors.white70))
          else if (_error != null)
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline_rounded,
                      color: Colors.white54, size: 48),
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                  ),
                ],
              ),
            )
          else if (widget.isAudio)
            _buildAudioPlayer(context)
          else
            Center(
              child: Video(
                controller: _controller,
                controls: AdaptiveVideoControls,
              ),
            ),

          // Top App Bar
          SafeArea(
            child: Container(
              height: 56,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.close_rounded,
                        color: Colors.white, size: 28),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.title ?? (widget.isAudio ? 'Audio Player' : 'Video Player'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAudioPlayer(BuildContext context) {
    final c = context.allora;
    final total = _duration.inMilliseconds > 0
        ? _duration.inMilliseconds.toDouble()
        : 1.0;
    final current = _position.inMilliseconds.toDouble().clamp(0.0, total);

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Vinyl / Audio Artwork
            RotationTransition(
              turns: _spinCtrl,
              child: Container(
                width: 170,
                height: 170,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: [c.accent, c.bubbleMineDeep],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: c.accent.withValues(alpha: 0.4),
                      blurRadius: 30,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: Center(
                  child: Container(
                    width: 60,
                    height: 60,
                    decoration: const BoxDecoration(
                      color: Colors.black87,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.audiotrack_rounded,
                        color: Colors.white.withValues(alpha: 0.9), size: 30),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 36),
            Text(
              widget.title ?? 'Audio Track',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 19,
                fontWeight: FontWeight.w700,
              ),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 20),

            // Progress Slider
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: c.accent,
                inactiveTrackColor: Colors.white24,
                thumbColor: Colors.white,
                trackHeight: 4,
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 6),
              ),
              child: Slider(
                value: current,
                max: total,
                onChanged: (val) {
                  _player.seek(Duration(milliseconds: val.toInt()));
                },
              ),
            ),

            // Timestamps
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    ChatTime.duration(_position),
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  Text(
                    ChatTime.duration(_duration),
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // Control Buttons
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Speed Button
                TextButton(
                  onPressed: _toggleSpeed,
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white,
                    backgroundColor: Colors.white12,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: Text(
                    '${_rate}x',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(width: 20),

                // Replay 10s
                IconButton(
                  icon: const Icon(Icons.replay_10_rounded,
                      color: Colors.white, size: 30),
                  onPressed: () {
                    final target = _position - const Duration(seconds: 10);
                    _player.seek(target < Duration.zero ? Duration.zero : target);
                  },
                ),
                const SizedBox(width: 14),

                // Play / Pause
                GestureDetector(
                  onTap: () {
                    HapticFeedback.selectionClick();
                    _player.playOrPause();
                  },
                  child: Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: c.accent,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: c.accent.withValues(alpha: 0.4),
                          blurRadius: 16,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Icon(
                      _playing
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 38,
                    ),
                  ),
                ),
                const SizedBox(width: 14),

                // Forward 10s
                IconButton(
                  icon: const Icon(Icons.forward_10_rounded,
                      color: Colors.white, size: 30),
                  onPressed: () {
                    final target = _position + const Duration(seconds: 10);
                    _player.seek(target > _duration ? _duration : target);
                  },
                ),
                const SizedBox(width: 44),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
