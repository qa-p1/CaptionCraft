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

  test(
    'lens and depth effects execute source-preserving composite graphs',
    () async {
      if (!await _commandExists('ffmpeg')) {
        markTestSkipped('Desktop FFmpeg is not installed.');
        return;
      }
      const source =
          'color=c=black@0.0:size=160x120:rate=12:duration=0.4,'
          'format=rgba,'
          'drawbox=x=35:y=25:w=90:h=70:color=red@1:t=fill';
      final baseline = await Process.run('ffmpeg', [
        '-hide_banner',
        '-loglevel',
        'error',
        '-f',
        'lavfi',
        '-i',
        source,
        '-frames:v',
        '4',
        '-pix_fmt',
        'rgba',
        '-f',
        'framemd5',
        '-',
      ]);
      expect(baseline.exitCode, 0, reason: '${baseline.stderr}');
      final failures = <String>[];
      const types = <EditorEffectType>[
        EditorEffectType.glow,
        EditorEffectType.bloom,
        EditorEffectType.cinematicGlow,
        EditorEffectType.glare,
        EditorEffectType.bokeh,
        EditorEffectType.flare,
        EditorEffectType.lightLeak,
        EditorEffectType.prism,
        EditorEffectType.dropShadow,
        EditorEffectType.outline,
        EditorEffectType.stroke,
        EditorEffectType.reflection,
      ];
      for (final type in types) {
        final plan = TimelineExportService.buildEditorEffectGraphPlanForTesting(
          EditorEffect(
            type: type,
            intensity: 0.74,
            mask: const EditorEffectMask(
              shape: EditorEffectMaskShape.ellipse,
              x: 0.08,
              y: 0.08,
              width: 0.84,
              height: 0.84,
              feather: 0.12,
            ),
          ),
          sourceLabel: '0:v',
        );
        if (!plan.filterGraph.contains('maskedmerge=') ||
            !plan.filterGraph.contains('split=')) {
          failures.add('${type.name}: graph was not composited and masked');
          continue;
        }
        final graph =
            '${plan.filterGraph};'
            '[${plan.outputLabel}]format=rgba[out]';
        final result = await Process.run('ffmpeg', [
          '-hide_banner',
          '-loglevel',
          'error',
          '-f',
          'lavfi',
          '-i',
          source,
          '-filter_complex',
          graph,
          '-map',
          '[out]',
          '-frames:v',
          '4',
          '-pix_fmt',
          'rgba',
          '-f',
          'framemd5',
          '-',
        ]);
        if (result.exitCode != 0) {
          failures.add('${type.name}: ${result.stderr}');
        } else if (result.stdout == baseline.stdout) {
          failures.add('${type.name}: rendered pixels were unchanged');
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
      'hueVsHue': const ClipColorAdjustments(
        hueVsHueCurve: EditorColorCurve(
          points: [
            EditorColorCurvePoint(0, 0),
            EditorColorCurvePoint(0.5, 0.62),
            EditorColorCurvePoint(1, 1),
          ],
        ),
      ),
      'hueVsSaturation': const ClipColorAdjustments(
        hueVsSaturationCurve: EditorColorCurve(
          points: [
            EditorColorCurvePoint(0, 0),
            EditorColorCurvePoint(0.5, 0.35),
            EditorColorCurvePoint(1, 1),
          ],
        ),
      ),
      'hueVsLuminance': const ClipColorAdjustments(
        hueVsLuminanceCurve: EditorColorCurve(
          points: [
            EditorColorCurvePoint(0, 0),
            EditorColorCurvePoint(0.5, 0.58),
            EditorColorCurvePoint(1, 1),
          ],
        ),
      ),
      'luminanceVsSaturation': const ClipColorAdjustments(
        luminanceVsSaturationCurve: EditorColorCurve(
          points: [
            EditorColorCurvePoint(0, 0),
            EditorColorCurvePoint(0.5, 0.7),
            EditorColorCurvePoint(1, 1),
          ],
        ),
      ),
      'saturationVsSaturation': const ClipColorAdjustments(
        saturationVsSaturationCurve: EditorColorCurve(
          points: [
            EditorColorCurvePoint(0, 0),
            EditorColorCurvePoint(0.5, 0.3),
            EditorColorCurvePoint(1, 1),
          ],
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
    'exposure plus both directions of black and white controls change pixels',
    () async {
      if (!await _commandExists('ffmpeg')) {
        markTestSkipped('Desktop FFmpeg is not installed.');
        return;
      }
      Future<String> render(ClipColorAdjustments adjustments) async {
        final plan = TimelineExportService.buildColorAdjustmentGraphPlan(
          adjustments,
          sourceLabel: '0:v',
        );
        final graph = plan.filterGraph.isEmpty
            ? '[0:v]format=yuv420p[out]'
            : '${plan.filterGraph};'
                  '[${plan.outputLabel}]format=yuv420p[out]';
        final result = await Process.run('ffmpeg', [
          '-hide_banner',
          '-loglevel',
          'error',
          '-f',
          'lavfi',
          '-i',
          'testsrc2=size=160x120:rate=12:duration=0.4',
          '-filter_complex',
          graph,
          '-map',
          '[out]',
          '-frames:v',
          '4',
          '-f',
          'framemd5',
          '-',
        ]);
        expect(result.exitCode, 0, reason: '${result.stderr}');
        return result.stdout as String;
      }

      final neutral = await render(const ClipColorAdjustments());
      final controls = <String, ClipColorAdjustments>{
        'positive exposure': const ClipColorAdjustments(exposure: 1),
        'negative exposure': const ClipColorAdjustments(exposure: -1),
        'lift blacks': const ClipColorAdjustments(blacks: 0.5),
        'crush blacks': const ClipColorAdjustments(blacks: -0.5),
        'raise whites': const ClipColorAdjustments(whites: 0.5),
        'lower whites': const ClipColorAdjustments(whites: -0.5),
      };
      final unchanged = <String>[];
      for (final entry in controls.entries) {
        if (await render(entry.value) == neutral) unchanged.add(entry.key);
      }
      expect(unchanged, isEmpty, reason: 'No pixel change: $unchanged');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('camera input transforms and HDR pipelines validate', () {
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
      returnsNormally,
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
      returnsNormally,
    );
    expect(
      () => TimelineExportService.validateColorPipelineForTesting(
        EditorTimeline(
          colorManagement: const EditorColorManagementSettings(
            workingSpace: EditorColorSpace.hlg,
            outputSpace: EditorColorSpace.pq,
            preserveHdr: true,
          ),
        ),
      ),
      returnsNormally,
    );
    expect(
      () => TimelineExportService.validateColorPipelineForTesting(
        EditorTimeline(
          colorManagement: const EditorColorManagementSettings(
            outputSpace: EditorColorSpace.automatic,
          ),
        ),
      ),
      throwsArgumentError,
    );
  });

  test(
    'secondary curves and a masked qualifier are accepted by FFmpeg',
    () async {
      if (!await _commandExists('ffmpeg')) {
        markTestSkipped('Desktop FFmpeg is not installed.');
        return;
      }
      final adjustments = ClipColorAdjustments(
        hueVsHueCurve: const EditorColorCurve(
          points: [
            EditorColorCurvePoint(0, 0),
            EditorColorCurvePoint(0.33, 0.46),
            EditorColorCurvePoint(1, 1),
          ],
        ),
        luminanceVsSaturationCurve: const EditorColorCurve(
          points: [
            EditorColorCurvePoint(0, 0),
            EditorColorCurvePoint(0.5, 0.7),
            EditorColorCurvePoint(1, 1),
          ],
        ),
        saturationVsSaturationCurve: const EditorColorCurve(
          points: [
            EditorColorCurvePoint(0, 0),
            EditorColorCurvePoint(0.5, 0.35),
            EditorColorCurvePoint(1, 1),
          ],
        ),
        qualifier: EditorColorQualifier(
          enabled: true,
          color: 0xFFFF0000,
          hueShift: 18,
          saturationShift: 0.2,
          spatialMask: const EditorEffectMask(
            shape: EditorEffectMaskShape.freeform,
            points: [
              EditorMaskPoint(0.1, 0.1),
              EditorMaskPoint(0.9, 0.2),
              EditorMaskPoint(0.75, 0.9),
              EditorMaskPoint(0.2, 0.8),
            ],
            feather: 0.15,
          ),
        ),
      );
      final plan = TimelineExportService.buildColorAdjustmentGraphPlan(
        adjustments,
        sourceLabel: '0:v',
      );
      expect(plan.filterGraph, contains('huesaturation='));
      expect(plan.filterGraph, contains('format=gbrp,geq='));
      expect(plan.filterGraph, contains('maskedmerge='));
      expect(plan.filterGraph, contains('mod('));
      expect(plan.filterGraph, contains('min(abs('));
      final graph =
          '${plan.filterGraph};'
          '[${plan.outputLabel}]format=yuv420p[out]';
      final result = await Process.run('ffmpeg', [
        '-hide_banner',
        '-loglevel',
        'error',
        '-f',
        'lavfi',
        '-i',
        'testsrc2=size=160x120:rate=12:duration=0.4',
        '-filter_complex',
        graph,
        '-map',
        '[out]',
        '-frames:v',
        '4',
        '-f',
        'null',
        '-',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
    timeout: const Timeout(Duration(minutes: 2)),
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
