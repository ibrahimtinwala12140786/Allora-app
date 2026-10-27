import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/media_limits.dart';

class CustomStickerData {
  final Uint8List bytes;
  final String filename;
  final bool isAnimated;

  const CustomStickerData({
    required this.bytes,
    required this.filename,
    this.isAnimated = false,
  });
}

/// Sticker picker supporting built-in animated & static stickers, plus custom WebP sticker upload
/// with strict validation: 100 KB (Static) / 500 KB (Animated).
class StickerPickerSheet extends StatefulWidget {
  const StickerPickerSheet({super.key});

  static Future<CustomStickerData?> show(BuildContext context) {
    return showModalBottomSheet<CustomStickerData>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const StickerPickerSheet(),
    );
  }

  @override
  State<StickerPickerSheet> createState() => _StickerPickerSheetState();
}

class _StickerPickerSheetState extends State<StickerPickerSheet> {
  // Built-in sticker packs (using high quality WebP stickers / assets)
  static final List<({String name, IconData icon, List<String> urls})> _stickerPacks = [
    (
      name: 'Allora Fun',
      icon: Icons.auto_awesome_rounded,
      urls: [
        'https://matrix.org/logos/matrix-logo.png',
        'https://raw.githubusercontent.com/telegramdesktop/tdesktop/dev/Telegram/Resources/art/stickers/tg_star.png',
      ],
    ),
  ];

  int _selectedPack = 0;

  Future<void> _pickCustomWebpSticker() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['webp'],
        withData: true,
      );

      if (result == null || result.files.isEmpty) return;
      final file = result.files.first;
      final bytes = file.bytes;
      if (bytes == null || !mounted) return;

      // Detect if WebP is animated (contains 'ANIM' or 'ANMF' chunk in RIFF header)
      final isAnimated = _isAnimatedWebp(bytes);
      final size = bytes.length;

      final error = MediaLimits.validateFile(
        filename: file.name,
        sizeBytes: size,
        category: 'sticker',
        isAnimatedSticker: isAnimated,
      );

      if (error != null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(error),
              backgroundColor: Colors.redAccent,
            ),
          );
        }
        return;
      }

      if (mounted) {
        Navigator.pop(
          context,
          CustomStickerData(
            bytes: bytes,
            filename: file.name,
            isAnimated: isAnimated,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not load sticker file.')),
        );
      }
    }
  }

  /// Checks if WebP bytes contain the ANIM or ANMF tag in headers
  bool _isAnimatedWebp(Uint8List bytes) {
    if (bytes.length < 32) return false;
    final headerStr = String.fromCharCodes(bytes.sublist(0, bytes.length.clamp(0, 100)));
    return headerStr.contains('ANIM') || headerStr.contains('ANMF');
  }

  @override
  Widget build(BuildContext context) {
    final c = context.allora;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      height: MediaQuery.of(context).size.height * 0.48,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF191A1F) : Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          Container(
            margin: const EdgeInsets.only(top: 10, bottom: 8),
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: c.textTertiary.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                Text(
                  'Stickers',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: c.text,
                  ),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: _pickCustomWebpSticker,
                  icon: const Icon(Icons.add_photo_alternate_rounded, size: 18),
                  label: const Text('Add WebP', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                  style: TextButton.styleFrom(
                    foregroundColor: c.accent,
                    backgroundColor: c.accent.withValues(alpha: 0.1),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ],
            ),
          ),
          Divider(color: c.outline, height: 1),
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        color: c.accent.withValues(alpha: 0.12),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(Icons.emoji_emotions_rounded, color: c.accent, size: 34),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'WebP Stickers Supported',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: c.text,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Send Static (≤100 KB) & Animated (≤500 KB) WebP stickers to any chat.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        color: c.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: c.accent,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                      ),
                      onPressed: _pickCustomWebpSticker,
                      icon: const Icon(Icons.upload_file_rounded, size: 18),
                      label: const Text('Choose WebP Sticker File'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
