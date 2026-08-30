import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/theme/app_theme.dart';

const String kCaptionCraftLogoAsset = 'captioncraft_logo.svg';

class CaptionCraftMark extends StatelessWidget {
  final double size;
  final double radius;

  const CaptionCraftMark({super.key, this.size = 42, this.radius = 11});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      image: true,
      label: 'CaptionCraft',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: SvgPicture.asset(
          kCaptionCraftLogoAsset,
          width: size,
          height: size,
          fit: BoxFit.cover,
        ),
      ),
    );
  }
}

class CaptionCraftLockup extends StatelessWidget {
  final double markSize;
  final bool compact;
  final String subtitle;

  const CaptionCraftLockup({
    super.key,
    this.markSize = 42,
    this.compact = false,
    this.subtitle = 'EDITING STUDIO',
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        CaptionCraftMark(size: markSize, radius: markSize * 0.24),
        if (!compact) ...[
          const SizedBox(width: 11),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'CAPTIONCRAFT',
                style: TextStyle(
                  color: kTextPrimary,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.15,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: const TextStyle(
                  fontFamily: 'Space Mono',
                  color: kAccent,
                  fontSize: 8,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.35,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
