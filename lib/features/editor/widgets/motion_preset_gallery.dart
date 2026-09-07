import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../models/clip_motion_presets.dart';
import '../models/timeline_models.dart';

class MotionPresetGallery extends StatefulWidget {
  const MotionPresetGallery({super.key, required this.onSelected});
  final ValueChanged<ClipMotionPreset> onSelected;

  @override
  State<MotionPresetGallery> createState() => _MotionPresetGalleryState();
}

class _MotionPresetGalleryState extends State<MotionPresetGallery>
    with SingleTickerProviderStateMixin {
  late final AnimationController _clock = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );
  late final _samples = {
    for (final preset in ClipMotionPreset.values)
      preset: preset.apply(
        TimelineClip(
          trackId: 'sample',
          type: TimelineTrackType.image,
          label: 'Motion',
          startTime: Duration.zero,
          endTime: const Duration(seconds: 1),
        ),
      ),
  };

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _clock.stop();
    } else if (!_clock.isAnimating) {
      _clock.repeat();
    }
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final preset in ClipMotionPreset.values)
        Semantics(
          button: true,
          label: 'Apply ${preset.label} motion',
          child: InkWell(
            key: ValueKey('motion_preset_${preset.name}'),
            onTap: () => widget.onSelected(preset),
            borderRadius: BorderRadius.circular(12),
            child: Container(
              width: 100,
              height: 90,
              decoration: BoxDecoration(
                color: kSurfaceElevated,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: kBorder),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    height: 45,
                    child: Center(
                      child: AnimatedBuilder(
                        animation: _clock,
                        builder: (_, child) {
                          final progress =
                              MediaQuery.disableAnimationsOf(context)
                              ? 0.5
                              : _clock.value;
                          final transform = _samples[preset]!.transformAt(
                            Duration(
                              microseconds: (progress * 1000000).round(),
                            ),
                          );
                          return Transform.translate(
                            offset: Offset(
                              transform.offsetX / 6,
                              transform.offsetY / 3,
                            ),
                            child: Transform.rotate(
                              angle: transform.rotation,
                              child: Transform.scale(
                                scale: transform.scale,
                                child: child,
                              ),
                            ),
                          );
                        },
                        child: Container(
                          width: 28,
                          height: 22,
                          decoration: BoxDecoration(
                            color: kAccent,
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: const Icon(
                            Icons.play_arrow_rounded,
                            color: kOnAccent,
                            size: 16,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Text(
                    preset.label,
                    style: const TextStyle(fontSize: 11, color: kTextPrimary),
                  ),
                ],
              ),
            ),
          ),
        ),
    ],
  );
}
