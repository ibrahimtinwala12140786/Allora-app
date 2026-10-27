import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class SettingsTile extends StatelessWidget {
  final IconData? icon;
  final Widget? leading;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Color? iconColor;
  final Color? titleColor;

  const SettingsTile({
    super.key,
    this.icon,
    this.leading,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.iconColor,
    this.titleColor,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.allora;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              if (leading != null)
                Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: leading!,
                )
              else if (icon != null)
                Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: Icon(
                    icon,
                    size: 24,
                    color: iconColor ?? c.textSecondary,
                  ),
                ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        letterSpacing: -0.2,
                        color: titleColor ?? c.text,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w400,
                          color: c.textTertiary,
                        ),
                      ),
                    ]
                  ],
                ),
              ),
              if (trailing != null) trailing!,
              if (trailing == null && onTap != null)
                Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: c.textTertiary,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
