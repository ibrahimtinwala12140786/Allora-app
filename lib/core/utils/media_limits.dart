import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

/// Centralized file formats and size limit configurations for Allora.
///
/// Limits supported:
/// - Documents: All formats (PDF, DOCX, XLSX, PPTX, TXT, ZIP, RAR, APK, etc.) -> 2 GB
/// - Video: MP4, MOV, MKV, AVI, 3GP, FLV -> 16 MB (Media) / 2 GB (Document)
/// - Images: JPEG, PNG, WebP, HEIC/HEIF -> 16 MB
/// - Audio: AAC, MP3, AMR, M4A, OGG (Opus for Voice Notes), WAV -> 16 MB
/// - Stickers: WebP (Static & Animated) -> 100 KB (Static) / 500 KB (Animated)
class MediaLimits {
  MediaLimits._();

  // ── Size & Character Limits ────────────────────────────────────────────────
  static const int maxMessageCharacterLimit = 65536; // Up to ~65,536 characters
  static const int maxDocumentBytes = 2 * 1024 * 1024 * 1024; // 2 GB
  static const int maxMediaVideoBytes = 16 * 1024 * 1024; // 16 MB
  static const int maxDocumentVideoBytes = 2 * 1024 * 1024 * 1024; // 2 GB
  static const int maxImageBytes = 16 * 1024 * 1024; // 16 MB
  static const int maxAudioBytes = 16 * 1024 * 1024; // 16 MB
  static const int maxStaticStickerBytes = 100 * 1024; // 100 KB
  static const int maxAnimatedStickerBytes = 500 * 1024; // 500 KB

  // ── Supported Extensions ──────────────────────────────────────────────────
  static const Set<String> videoExtensions = {
    'mp4', 'mov', 'mkv', 'avi', '3gp', 'flv', 'webm', 'm4v', 'wmv'
  };

  static const Set<String> imageExtensions = {
    'jpg', 'jpeg', 'png', 'webp', 'heic', 'heif', 'gif', 'bmp', 'svg', 'tiff'
  };

  static const Set<String> audioExtensions = {
    'aac', 'mp3', 'amr', 'm4a', 'ogg', 'opus', 'wav', 'flac', 'wma'
  };

  static const Set<String> stickerExtensions = {
    'webp'
  };

  // ── Format Helper Methods ─────────────────────────────────────────────────
  
  static String formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  static String getExtension(String pathOrName) {
    if (pathOrName.toLowerCase().startsWith('unknown message format')) return '';
    final raw = p.extension(pathOrName).replaceAll('.', '').replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();
    if (raw == 'message' || raw.length > 8) return '';
    return raw;
  }

  /// Derives file extension from standard MIME types.
  static String resolveExtensionFromMime(String mimeType) {
    final lower = mimeType.toLowerCase().split(';').first.trim();
    switch (lower) {
      case 'image/jpeg':
      case 'image/jpg':
        return 'jpg';
      case 'image/png':
        return 'png';
      case 'image/webp':
      case 'image/webp.sticker':
        return 'webp';
      case 'image/gif':
        return 'gif';
      case 'image/heic':
        return 'heic';
      case 'image/heif':
        return 'heif';
      case 'image/svg+xml':
        return 'svg';
      case 'video/mp4':
        return 'mp4';
      case 'video/quicktime':
        return 'mov';
      case 'video/x-matroska':
        return 'mkv';
      case 'video/x-msvideo':
      case 'video/avi':
        return 'avi';
      case 'video/3gpp':
      case 'video/3gp':
        return '3gp';
      case 'video/x-flv':
      case 'video/flv':
        return 'flv';
      case 'video/webm':
        return 'webm';
      case 'audio/ogg':
      case 'audio/opus':
        return 'ogg';
      case 'audio/mp4':
      case 'audio/m4a':
      case 'audio/x-m4a':
        return 'm4a';
      case 'audio/mpeg':
      case 'audio/mp3':
        return 'mp3';
      case 'audio/amr':
      case 'audio/amr-wb':
        return 'amr';
      case 'audio/aac':
        return 'aac';
      case 'audio/wav':
      case 'audio/x-wav':
        return 'wav';
      case 'application/pdf':
        return 'pdf';
      case 'application/msword':
        return 'doc';
      case 'application/vnd.openxmlformats-officedocument.wordprocessingml.document':
        return 'docx';
      case 'application/vnd.ms-excel':
        return 'xls';
      case 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet':
        return 'xlsx';
      case 'application/vnd.ms-powerpoint':
        return 'ppt';
      case 'application/vnd.openxmlformats-officedocument.presentationml.presentation':
        return 'pptx';
      case 'application/zip':
        return 'zip';
      case 'application/x-rar-compressed':
      case 'application/vnd.rar':
        return 'rar';
      case 'application/x-7z-compressed':
        return '7z';
      case 'application/vnd.android.package-archive':
        return 'apk';
      case 'text/vcard':
      case 'text/x-vcard':
        return 'vcf';
      case 'text/plain':
        return 'txt';
      default:
        return '';
    }
  }

  static bool isVideo(String pathOrName) {
    final ext = getExtension(pathOrName);
    return videoExtensions.contains(ext);
  }

  static bool isImage(String pathOrName) {
    final ext = getExtension(pathOrName);
    return imageExtensions.contains(ext);
  }

  static bool isAudio(String pathOrName) {
    final ext = getExtension(pathOrName);
    return audioExtensions.contains(ext);
  }

  static bool isSticker(String pathOrName) {
    final ext = getExtension(pathOrName);
    return stickerExtensions.contains(ext);
  }

  /// Resolves MIME type for accurate Matrix upload headers.
  static String resolveMimeType(String pathOrName, {String defaultMime = 'application/octet-stream'}) {
    final ext = getExtension(pathOrName);
    switch (ext) {
      // Images
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'webp':
        return 'image/webp';
      case 'heic':
        return 'image/heic';
      case 'heif':
        return 'image/heif';
      case 'gif':
        return 'image/gif';
      case 'bmp':
        return 'image/bmp';
      case 'svg':
        return 'image/svg+xml';

      // Video
      case 'mp4':
        return 'video/mp4';
      case 'mov':
        return 'video/quicktime';
      case 'mkv':
        return 'video/x-matroska';
      case 'avi':
        return 'video/x-msvideo';
      case '3gp':
        return 'video/3gpp';
      case 'flv':
        return 'video/x-flv';
      case 'webm':
        return 'video/webm';
      case 'm4v':
        return 'video/x-m4v';

      // Audio
      case 'aac':
        return 'audio/aac';
      case 'mp3':
        return 'audio/mpeg';
      case 'amr':
        return 'audio/amr';
      case 'm4a':
        return 'audio/mp4';
      case 'ogg':
      case 'opus':
        return 'audio/ogg';
      case 'wav':
        return 'audio/wav';
      case 'flac':
        return 'audio/flac';

      // Documents & Archives
      case 'pdf':
        return 'application/pdf';
      case 'doc':
        return 'application/msword';
      case 'docx':
        return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      case 'xls':
        return 'application/vnd.ms-excel';
      case 'xlsx':
        return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
      case 'ppt':
        return 'application/vnd.ms-powerpoint';
      case 'pptx':
        return 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
      case 'txt':
        return 'text/plain';
      case 'zip':
        return 'application/zip';
      case 'rar':
        return 'application/vnd.rar';
      case '7z':
        return 'application/x-7z-compressed';
      case 'tar':
        return 'application/x-tar';
      case 'gz':
        return 'application/gzip';
      case 'apk':
        return 'application/vnd.android.package-archive';
      case 'csv':
        return 'text/csv';
      case 'json':
        return 'application/json';
      case 'xml':
        return 'application/xml';
      default:
        return defaultMime;
    }
  }

  /// Returns tailored icon, badge color, and title for any file extension.
  static ({IconData icon, Color color, String badge}) documentMeta(String pathOrName) {
    final ext = getExtension(pathOrName);
    switch (ext) {
      case 'pdf':
        return (icon: Icons.picture_as_pdf_rounded, color: const Color(0xFFE53935), badge: 'PDF');
      case 'doc':
      case 'docx':
        return (icon: Icons.description_rounded, color: const Color(0xFF1E88E5), badge: 'DOC');
      case 'xls':
      case 'xlsx':
      case 'csv':
        return (icon: Icons.table_chart_rounded, color: const Color(0xFF43A047), badge: 'SHEET');
      case 'ppt':
      case 'pptx':
        return (icon: Icons.slideshow_rounded, color: const Color(0xFFFB8C00), badge: 'SLIDES');
      case 'zip':
      case 'rar':
      case '7z':
      case 'tar':
      case 'gz':
        return (icon: Icons.folder_zip_rounded, color: const Color(0xFF8E24AA), badge: 'ZIP');
      case 'apk':
        return (icon: Icons.android_rounded, color: const Color(0xFF2E7D32), badge: 'APK');
      case 'txt':
      case 'md':
      case 'rtf':
        return (icon: Icons.text_snippet_rounded, color: const Color(0xFF546E7A), badge: 'TXT');
      case 'mp4':
      case 'mov':
      case 'mkv':
      case 'avi':
      case '3gp':
      case 'flv':
        return (icon: Icons.videocam_rounded, color: const Color(0xFF00ACC1), badge: 'VIDEO');
      case 'mp3':
      case 'aac':
      case 'm4a':
      case 'wav':
      case 'ogg':
      case 'opus':
        return (icon: Icons.audiotrack_rounded, color: const Color(0xFFE91E63), badge: 'AUDIO');
      default:
        return (
          icon: Icons.insert_drive_file_rounded,
          color: const Color(0xFF3949AB),
          badge: ext.isNotEmpty ? ext.toUpperCase() : 'FILE'
        );
    }
  }

  /// Validates file against policy and returns an error message if invalid, or null if valid.
  static String? validateFile({
    required String filename,
    required int sizeBytes,
    required String category, // 'document', 'image', 'video', 'audio', 'sticker'
    bool isAnimatedSticker = false,
  }) {
    switch (category) {
      case 'document':
        if (sizeBytes > maxDocumentBytes) {
          return 'Document exceeds 2 GB limit (${formatBytes(sizeBytes)}).';
        }
        return null;

      case 'image':
        if (sizeBytes > maxImageBytes) {
          return 'Image exceeds 16 MB limit (${formatBytes(sizeBytes)}).';
        }
        return null;

      case 'video':
        if (sizeBytes > maxDocumentVideoBytes) {
          return 'Video exceeds 2 GB limit (${formatBytes(sizeBytes)}).';
        }
        return null;

      case 'audio':
        if (sizeBytes > maxAudioBytes) {
          return 'Audio file exceeds 16 MB limit (${formatBytes(sizeBytes)}).';
        }
        return null;

      case 'sticker':
        final limit = isAnimatedSticker ? maxAnimatedStickerBytes : maxStaticStickerBytes;
        final label = isAnimatedSticker ? '500 KB (Animated)' : '100 KB (Static)';
        if (sizeBytes > limit) {
          return 'Sticker exceeds $label limit (${formatBytes(sizeBytes)}).';
        }
        return null;

      default:
        return null;
    }
  }
}
