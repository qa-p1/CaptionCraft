import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

class AppPanel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;
  final Color? borderColor;
  final double radius;
  final bool elevated;
  final bool selected;

  const AppPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.color,
    this.borderColor,
    this.radius = kRadiusLarge,
    this.elevated = false,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final resolvedBorder = selected
        ? kAccent.withValues(alpha: 0.62)
        : borderColor ?? kBorder;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color ?? (elevated ? kSurfaceElevated : kSurface),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: resolvedBorder),
        boxShadow: elevated
            ? const [
                BoxShadow(
                  color: Color(0x24000000),
                  blurRadius: 18,
                  offset: Offset(0, 8),
                ),
              ]
            : null,
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}

class AppSheetSurface extends StatelessWidget {
  final Widget child;
  final double radius;

  const AppSheetSurface({
    super.key,
    required this.child,
    this.radius = kRadiusSheet,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF15191D), kSurface],
            stops: [0, 0.18],
          ),
          borderRadius: BorderRadius.vertical(top: Radius.circular(radius)),
          border: const Border(top: BorderSide(color: kBorderStrong)),
          boxShadow: const [
            BoxShadow(
              color: Color(0x73000000),
              blurRadius: 28,
              offset: Offset(0, -8),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.vertical(top: Radius.circular(radius)),
          child: child,
        ),
      ),
    );
  }
}

class AppSheetHandle extends StatelessWidget {
  final double height;

  const AppSheetHandle({super.key, this.height = 26});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: Center(
        child: Container(
          width: 38,
          height: 4,
          decoration: BoxDecoration(
            color: kBorderStrong,
            borderRadius: BorderRadius.circular(99),
          ),
        ),
      ),
    );
  }
}

class AppSheetHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final IconData? icon;
  final Widget? trailing;
  final VoidCallback? onClose;
  final Widget? handle;
  final bool showHandle;
  final EdgeInsetsGeometry padding;

  const AppSheetHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.trailing,
    this.onClose,
    this.handle,
    this.showHandle = true,
    this.padding = const EdgeInsets.fromLTRB(18, 0, 10, 13),
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showHandle) handle ?? const AppSheetHandle(),
        Padding(
          padding: padding,
          child: Row(
            children: [
              if (icon != null) ...[
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: kAccent.withValues(alpha: 0.11),
                    borderRadius: BorderRadius.circular(11),
                    border: Border.all(color: kAccent.withValues(alpha: 0.22)),
                  ),
                  child: Icon(icon, color: kAccent, size: 19),
                ),
                const SizedBox(width: 11),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: kTextPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.35,
                      ),
                    ),
                    if (subtitle?.trim().isNotEmpty == true) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: kTextSecondary,
                          fontSize: 11,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 8), trailing!],
              if (onClose != null) ...[
                const SizedBox(width: 6),
                IconButton(
                  tooltip: 'Close',
                  onPressed: onClose,
                  style: IconButton.styleFrom(
                    backgroundColor: kSurfaceElevated,
                    side: const BorderSide(color: kBorder),
                    minimumSize: const Size.square(36),
                    maximumSize: const Size.square(36),
                  ),
                  icon: const Icon(Icons.close_rounded, size: 19),
                ),
              ],
            ],
          ),
        ),
        const Divider(height: 1),
      ],
    );
  }
}

class AppSectionHeader extends StatelessWidget {
  final String title;
  final String? description;
  final IconData? icon;
  final Widget? trailing;

  const AppSectionHeader({
    super.key,
    required this.title,
    this.description,
    this.icon,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (icon != null) ...[
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: kSurfaceElevated,
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: kBorder),
            ),
            child: Icon(icon, size: 15, color: kAccent),
          ),
          const SizedBox(width: 10),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: kTextPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.1,
                ),
              ),
              if (description?.trim().isNotEmpty == true) ...[
                const SizedBox(height: 2),
                Text(
                  description!,
                  style: const TextStyle(
                    color: kTextSecondary,
                    fontSize: 10.5,
                    height: 1.3,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 10), trailing!],
      ],
    );
  }
}

class AppStatusPill extends StatelessWidget {
  final String label;
  final Color color;
  final IconData? icon;

  const AppStatusPill({
    super.key,
    required this.label,
    this.color = kAccent,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: color.withValues(alpha: 0.24)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, color: color, size: 12),
              const SizedBox(width: 5),
            ],
            Text(
              label.toUpperCase(),
              style: TextStyle(
                color: color,
                fontSize: 8.5,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.75,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AppEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  const AppEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 54,
                height: 54,
                decoration: BoxDecoration(
                  color: kSurfaceElevated,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: kBorder),
                ),
                child: Icon(icon, color: kAccent, size: 25),
              ),
              const SizedBox(height: 15),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: kTextPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.25,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: kTextSecondary,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
              if (action != null) ...[const SizedBox(height: 17), action!],
            ],
          ),
        ),
      ),
    );
  }
}
