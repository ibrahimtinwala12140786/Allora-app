import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/chat_time.dart';
import '../../../core/utils/media_limits.dart';

/// Result from voice recording session.
class VoiceRecordResult {
  final Uint8List bytes;
  final String path;
  final Duration duration;
  final String filename;
  final List<int> waveform;

  const VoiceRecordResult({
    required this.bytes,
    required this.path,
    required this.duration,
    required this.filename,
    required this.waveform,
  });
}

/// A modern, interactive in-app voice note recorder with live waveform,
/// pause/resume, delete, and send actions.
class VoiceRecorderDialog extends StatefulWidget {
  const VoiceRecorderDialog({super.key});

  static Future<VoiceRecordResult?> show(BuildContext context) {
    return showDialog<VoiceRecordResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const VoiceRecorderDialog(),
    );
  }

  @override
  State<VoiceRecorderDialog> createState() => _VoiceRecorderDialogState();
}

class _VoiceRecorderDialogState extends State<VoiceRecorderDialog>
    with SingleTickerProviderStateMixin {
  late final AudioRecorder _recorder;
  Timer? _timer;
  Duration _duration = Duration.zero;
  bool _isRecording = false;
  bool _isPaused = false;
  String? _recordedPath;
  final List<double> _amplitudes = [];
  late final AnimationController _pulseCtrl;

  @override
  void initState() {
    super.initState();
    _recorder = AudioRecorder();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);
    _startRecording();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pulseCtrl.dispose();
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _startRecording() async {
    try {
      if (await _recorder.hasPermission()) {
        final tempDir = await getTemporaryDirectory();
        final now = DateTime.now().millisecondsSinceEpoch;
        final path = '${tempDir.path}/voice_note_$now.m4a';

        await _recorder.start(
          const RecordConfig(
            encoder: AudioEncoder.aacLc,
            bitRate: 128000,
            sampleRate: 44100,
          ),
          path: path,
        );

        setState(() {
          _isRecording = true;
          _isPaused = false;
          _recordedPath = path;
          _duration = Duration.zero;
          _amplitudes.clear();
        });

        _timer = Timer.periodic(const Duration(milliseconds: 100), (t) async {
          if (!_isPaused && mounted) {
            setState(() {
              _duration += const Duration(milliseconds: 100);
            });
            try {
              final amp = await _recorder.getAmplitude();
              if (mounted) {
                // Normalize dBFS (-60 to 0) to 0.0 - 1.0
                final norm = ((amp.current + 60) / 60).clamp(0.05, 1.0);
                setState(() {
                  _amplitudes.add(norm);
                  if (_amplitudes.length > 36) {
                    _amplitudes.removeAt(0);
                  }
                });
              }
            } catch (_) {}
          }
        });
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Microphone permission required.')),
          );
          Navigator.pop(context);
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Recording error: $e')),
        );
        Navigator.pop(context);
      }
    }
  }

  Future<void> _pauseOrResume() async {
    if (_isPaused) {
      await _recorder.resume();
      setState(() => _isPaused = false);
    } else {
      await _recorder.pause();
      setState(() => _isPaused = true);
    }
    HapticFeedback.selectionClick();
  }

  Future<void> _cancelRecording() async {
    _timer?.cancel();
    try {
      await _recorder.stop();
      if (_recordedPath != null) {
        final f = File(_recordedPath!);
        if (await f.exists()) await f.delete();
      }
    } catch (_) {}
    if (mounted) Navigator.pop(context);
  }

  Future<void> _finishAndSend() async {
    _timer?.cancel();
    try {
      final path = await _recorder.stop();
      final finalPath = path ?? _recordedPath;
      if (!mounted) return;
      if (finalPath == null) {
        Navigator.pop(context);
        return;
      }
      final file = File(finalPath);
      if (!await file.exists()) {
        if (mounted) Navigator.pop(context);
        return;
      }
      final bytes = await file.readAsBytes();
      if (!mounted) return;

      if (bytes.length > MediaLimits.maxAudioBytes) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                'Voice note exceeds 16 MB limit (${MediaLimits.formatBytes(bytes.length)}).'),
          ),
        );
        Navigator.pop(context);
        return;
      }

      // Generate integer waveform (0-1000) for Matrix msc1767 audio
      final waveform = _amplitudes.map((a) => (a * 1000).toInt()).toList();
      if (waveform.isEmpty) {
        final random = Random();
        for (var i = 0; i < 28; i++) {
          waveform.add(200 + random.nextInt(600));
        }
      }

      final filename =
          'Voice_Note_${DateTime.now().year}${DateTime.now().month.toString().padLeft(2, '0')}${DateTime.now().day.toString().padLeft(2, '0')}_${DateTime.now().hour.toString().padLeft(2, '0')}${DateTime.now().minute.toString().padLeft(2, '0')}.m4a';

      if (mounted) {
        Navigator.pop(
          context,
          VoiceRecordResult(
            bytes: bytes,
            path: finalPath,
            duration: _duration,
            filename: filename,
            waveform: waveform,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save voice note: $e')),
        );
        Navigator.pop(context);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.allora;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Dialog(
      backgroundColor: isDark ? const Color(0xFF1C1D22) : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                AnimatedBuilder(
                  animation: _pulseCtrl,
                  builder: (_, __) {
                    final scale = _isPaused ? 1.0 : 1.0 + _pulseCtrl.value * 0.2;
                    return Transform.scale(
                      scale: scale,
                      child: Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: _isPaused ? const Color(0xFFFF9500) : c.danger,
                          shape: BoxShape.circle,
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(width: 10),
                Text(
                  _isPaused ? 'Recording Paused' : 'Recording Audio…',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: c.text,
                  ),
                ),
                const Spacer(),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: c.surfaceAlt,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    ChatTime.duration(_duration),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      color: c.text,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            // Live Waveform Visualizer
            Container(
              height: 56,
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: c.surfaceAlt,
                borderRadius: BorderRadius.circular(16),
              ),
              alignment: Alignment.center,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(
                  32,
                  (index) {
                    final ampIndex = _amplitudes.length - 32 + index;
                    final amp = ampIndex >= 0 && ampIndex < _amplitudes.length
                        ? _amplitudes[ampIndex]
                        : 0.1;
                    return Container(
                      width: 4,
                      height: (amp * 44).clamp(6.0, 44.0),
                      margin: const EdgeInsets.symmetric(horizontal: 1.5),
                      decoration: BoxDecoration(
                        color: _isPaused
                            ? c.textTertiary
                            : (index > 26 ? c.danger : c.accent),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                // Cancel / Delete
                IconButton(
                  tooltip: 'Cancel',
                  style: IconButton.styleFrom(
                    backgroundColor: c.surfaceAlt,
                    foregroundColor: c.danger,
                    minimumSize: const Size(48, 48),
                  ),
                  onPressed: _cancelRecording,
                  icon: const Icon(Icons.delete_outline_rounded, size: 24),
                ),
                // Pause / Resume
                IconButton(
                  tooltip: _isPaused ? 'Resume' : 'Pause',
                  style: IconButton.styleFrom(
                    backgroundColor: c.surfaceAlt,
                    foregroundColor: c.text,
                    minimumSize: const Size(48, 48),
                  ),
                  onPressed: _pauseOrResume,
                  icon: Icon(
                    _isPaused
                        ? Icons.mic_rounded
                        : Icons.pause_rounded,
                    size: 24,
                  ),
                ),
                // Finish and Send
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: c.accent,
                    foregroundColor: Colors.white,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                  ),
                  onPressed: _duration.inMilliseconds > 500
                      ? _finishAndSend
                      : null,
                  icon: const Icon(Icons.send_rounded, size: 20),
                  label: const Text(
                    'Send',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
