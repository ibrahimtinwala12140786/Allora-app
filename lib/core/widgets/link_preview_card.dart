import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/link_preview_service.dart';
import '../theme/app_theme.dart';

/// WhatsApp-style rich link preview card.
class LinkPreviewCard extends StatefulWidget {
  final String url;
  final bool isMe;

  const LinkPreviewCard({
    super.key,
    required this.url,
    required this.isMe,
  });

  @override
  State<LinkPreviewCard> createState() => _LinkPreviewCardState();
}

class _LinkPreviewCardState extends State<LinkPreviewCard> {
  LinkPreviewData? _preview;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  @override
  void didUpdateWidget(covariant LinkPreviewCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _fetch();
    }
  }

  void _fetch() {
    LinkPreviewService.instance.getPreview(widget.url).then((data) {
      if (mounted) {
        setState(() {
          _preview = data;
          _loaded = true;
        });
      }
    });
  }

  Future<void> _openLink() async {
    final uri = Uri.parse(widget.url);
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded || _preview == null || !_preview!.hasContent) {
      return const SizedBox.shrink();
    }

    final p = _preview!;
    final c = context.allora;
    final isMe = widget.isMe;

    final bgColor = isMe
        ? Colors.black.withValues(alpha: 0.15)
        : c.surfaceAlt;
    final borderColor = isMe
        ? Colors.white.withValues(alpha: 0.22)
        : c.outline;
    final domainColor = isMe
        ? Colors.white.withValues(alpha: 0.85)
        : c.accent;
    final titleColor = isMe ? Colors.white : c.text;
    final descColor = isMe
        ? Colors.white.withValues(alpha: 0.75)
        : c.textSecondary;

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _openLink,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 320),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: borderColor, width: 0.8),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (p.imageUrl != null && p.imageUrl!.isNotEmpty)
                  AspectRatio(
                    aspectRatio: 16 / 9,
                    child: Image.network(
                      p.imageUrl!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.link_rounded, size: 13, color: domainColor),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              p.domain.toUpperCase(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.4,
                                color: domainColor,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (p.title != null && p.title!.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          p.title!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            height: 1.25,
                            color: titleColor,
                          ),
                        ),
                      ],
                      if (p.description != null && p.description!.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          p.description!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11.5,
                            height: 1.25,
                            color: descColor,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
