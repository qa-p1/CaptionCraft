import 'dart:io';

import 'package:caption_craft/core/utils/timeline_export_service.dart';
import 'package:caption_craft/features/editor/models/editor_effect_models.dart';
import 'package:caption_craft/features/editor/models/timeline_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
  test(
    'every exposed effect produces a filter accepted by FFmpeg',
    () async {
      if (!await _commandExists('ffmpeg')) {
        markTestSkipped('Desktop FFmpeg is not installed.');
        return;
      }
      final directory = await Directory.systemTemp.createTemp(
        'captioncraft_filter_compatibility_',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final lutPath = path.join(directory.path, 'identity.cube');
      await File(lutPath).writeAsString(_identityLut);
      final failures = <String>[];

      for (final type in EditorEffectType.values) {
        final effect = EditorEffect(
          type: type,
          parameters: {
            if (type == EditorEffectType.lut) 'path': lutPath,
            if (type == EditorEffectType.pitch) 'semitones': 3,
            if (type == EditorEffectType.timeStretch) 'rate': 1.1,
          },
        );
        final filters = type.domain == EditorEffectDomain.visual
            ? TimelineExportService.buildEditorEffectFiltersForTesting(
                effect,
                enableExpression: 'between(t,0.05,0.35)',
              )
            : TimelineExportService.buildAudioEffectFiltersForTesting(
                EditorEffectStack(effects: [effect]),
              );
        if (filters.isEmpty) {
          failures.add('${type.name}: generated no filter');
          continue;
        }
        final arguments = type.domain == EditorEffectDomain.visual
            ? [
                '-f',
                'lavfi',
                '-i',
                'testsrc2=size=160x120:rate=12:duration=0.4',
                '-vf',
                filters.join(','),
                '-frames:v',
                '4',
                '-f',
                'null',
                '-',
              ]
            : [
                '-f',
                'lavfi',
                '-i',
                'sine=frequency=1000:sample_rate=48000:duration=0.4',
                '-af',
                filters.join(','),
                '-f',
                'null',
                '-',
              ];
        final result = await Process.run('ffmpeg', [
          '-hide_banner',
          '-loglevel',
          'error',
          ...arguments,
        ]);
        if (result.exitCode != 0) {
          failures.add('${type.name}: ${result.stderr}');
        }
      }

      expect(failures, isEmpty, reason: failures.join('\n'));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('every exposed numeric parameter changes its render filter', () {
    final ignored = <String>[];
    for (final type in EditorEffectType.values) {
      final baseParameters = <String, dynamic>{
        ...type.defaultParameters,
        if (type == EditorEffectType.lut) 'path': r'C:\looks\identity.cube',
      };
      final baseline = _filtersFor(
        EditorEffect(type: type, parameters: baseParameters),
      );
      for (final entry in type.defaultParameters.entries) {
        if (entry.key == 'intensity') continue;
        final value = entry.value;
        final changedValue = switch (entry.key) {
          'angle' => 67.0,
          'amount' => value < 0.7 ? 0.9 : 0.2,
          'threshold' => value.isNegative ? value + 9 : 0.2,
          'softness' => 0.2,
          'size' => value + 7,
          'levels' => value + 5,
          'frequency' => value > 100 ? value * 0.5 : value + 5,
          'blur' => value + 8,
          'width' => value + 5,
          'offset' => 0.7,
          'offsetX' || 'offsetY' => value + 13,
          'position' || 'positionX' || 'positionY' => 0.1,
          _ =>
            value.abs() < 0.0001
                ? 0.37
                : value * 0.63 + (value.isNegative ? -0.17 : 0.17),
        };
        final changed = _filtersFor(
          EditorEffect(
            type: type,
            parameters: {...baseParameters, entry.key: changedValue},
          ),
        );
        if (changed.toString() == baseline.toString()) {
          ignored.add('${type.name}.${entry.key}');
        }
      }
    }

    expect(ignored, isEmpty, reason: 'Dead controls: ${ignored.join(', ')}');
  });

  test('every standard color control changes the export filter graph', () {
    final controls = <String, ClipColorAdjustments>{
      'exposure': const ClipColorAdjustments(exposure: 1),
      'brightness': const ClipColorAdjustments(brightness: 0.2),
      'contrast': const ClipColorAdjustments(contrast: 1.4),
      'highlights': const ClipColorAdjustments(highlights: 0.2),
      'shadows': const ClipColorAdjustments(shadows: 0.2),
      'whites': const ClipColorAdjustments(whites: 0.2),
      'blacks': const ClipColorAdjustments(blacks: -0.2),
      'saturation': const ClipColorAdjustments(saturation: 1.4),
      'vibrance': const ClipColorAdjustments(vibrance: 0.3),
      'temperature': const ClipColorAdjustments(temperature: 0.3),
      'tint': const ClipColorAdjustments(tint: 0.3),
      'gamma': const ClipColorAdjustments(gamma: 1.4),
      'hue': const ClipColorAdjustments(hue: 24),
      'redGain': const ClipColorAdjustments(redGain: 1.2),
      'greenGain': const ClipColorAdjustments(greenGain: 1.2),
      'blueGain': const ClipColorAdjustments(blueGain: 1.2),
      'fade': const ClipColorAdjustments(fade: 0.3),
      'vignette': const ClipColorAdjustments(vignette: 0.3),
      'sharpen': const ClipColorAdjustments(sharpen: 0.3),
      'rgbCurve': const ClipColorAdjustments(
        rgbCurve: EditorColorCurve(
          points: [
            EditorColorCurvePoint(0, 0),
            EditorColorCurvePoint(0.5, 0.65),
            EditorColorCurvePoint(1, 1),
          ],
        ),
      ),
      'colorWheels': const ClipColorAdjustments(
        wheels: EditorColorWheels(
          shadowsRed: 0.1,
          midtonesGreen: 0.1,
          highlightsBlue: 0.1,
          globalRed: 0.1,
        ),
      ),
    };
    final neutral = TimelineExportService.buildColorFiltersForTesting(
      const ClipColorAdjustments(),
    );
    final dead = <String>[];
    for (final entry in controls.entries) {
      final filters = TimelineExportService.buildColorFiltersForTesting(
        entry.value,
      );
      if (filters.toString() == neutral.toString()) dead.add(entry.key);
    }
    expect(dead, isEmpty, reason: 'Dead color controls: ${dead.join(', ')}');
  });

  test(
    'unsupported color pipelines stop instead of silently exporting SDR',
    () {
      EditorTimeline timelineWith(ClipColorAdjustments adjustments) {
        return EditorTimeline(
          tracks: [
            TimelineTrack(
              id: 'track',
              name: 'Video',
              type: TimelineTrackType.video,
              section: TimelineTrackSection.baseVideo,
              clips: [
                TimelineClip(
                  id: 'clip',
                  trackId: 'track',
                  type: TimelineTrackType.video,
                  label: 'Camera clip',
                  startTime: Duration.zero,
                  endTime: const Duration(seconds: 1),
                  colorAdjustments: adjustments,
                ),
              ],
            ),
          ],
        );
      }

      expect(
        () => TimelineExportService.validateColorPipelineForTesting(
          timelineWith(
            const ClipColorAdjustments(inputColorSpace: EditorColorSpace.log),
          ),
        ),
        throwsUnsupportedError,
      );
      expect(
        () => TimelineExportService.validateColorPipelineForTesting(
          timelineWith(
            const ClipColorAdjustments(
              hueVsHueCurve: EditorColorCurve(
                points: [
                  EditorColorCurvePoint(0, 0),
                  EditorColorCurvePoint(0.5, 0.6),
                  EditorColorCurvePoint(1, 1),
                ],
              ),
            ),
          ),
        ),
        throwsUnsupportedError,
      );
    },
  );
}

List<String> _filtersFor(EditorEffect effect) {
  return effect.domain == EditorEffectDomain.visual
      ? TimelineExportService.buildEditorEffectFiltersForTesting(effect)
      : TimelineExportService.buildAudioEffectFiltersForTesting(
          EditorEffectStack(effects: [effect]),
        );
}

Future<bool> _commandExists(String command) async {
  final result = await Process.run(command, const ['-version']);
  return result.exitCode == 0;
}

const _identityLut = '''
TITLE "Identity"
LUT_3D_SIZE 2
DOMAIN_MIN 0.0 0.0 0.0
DOMAIN_MAX 1.0 1.0 1.0
0.0 0.0 0.0
1.0 0.0 0.0
0.0 1.0 0.0
1.0 1.0 0.0
0.0 0.0 1.0
1.0 0.0 1.0
0.0 1.0 1.0
1.0 1.0 1.0
''';
