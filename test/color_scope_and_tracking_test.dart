import 'dart:io';

import 'package:caption_craft/core/utils/mask_tracking_service.dart';
import 'package:caption_craft/core/utils/video_scope_service.dart';
import 'package:caption_craft/features/editor/models/editor_effect_models.dart';
import 'package:caption_craft/features/editor/models/timeline_models.dart';
import 'package:caption_craft/features/editor/widgets/advanced_color_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
  testWidgets('qualifier exposes frame eyedropper and freeform mask editor', (
    tester,
  ) async {
    var sampled = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AdvancedColorControls(
              adjustments: const ClipColorAdjustments(
                qualifier: EditorColorQualifier(
                  enabled: true,
                  spatialMask: EditorEffectMask(
                    shape: EditorEffectMaskShape.freeform,
                    points: [
                      EditorMaskPoint(0.2, 0.2),
                      EditorMaskPoint(0.8, 0.2),
                      EditorMaskPoint(0.7, 0.8),
                    ],
                  ),
                ),
              ),
              onChanged: (_, {required recordHistory}) {},
              onGestureStart: () {},
              onGestureEnd: () {},
              onPickNeutralReference: () async {},
              onPickQualifierReference: () async => sampled = true,
            ),
          ),
        ),
      ),
    );
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('qualifier_eyedropper')),
      300,
    );
    await tester.tap(find.byKey(const ValueKey('qualifier_eyedropper')));
    await tester.pump();
    expect(sampled, isTrue);
    await tester.scrollUntilVisible(find.text('Freeform polygon'), 300);
    expect(find.text('Freeform polygon'), findsOneWidget);
    expect(find.textContaining('Drag polygon points'), findsOneWidget);
  });

  test('tracking metadata parser preserves timing, bounds, and confidence', () {
    final samples = MaskTrackingService.parseMetadataForTesting('''
frame:0    pts:0       pts_time:0
lavfi.rect.w=40
lavfi.rect.h=30
lavfi.rect.x=12
lavfi.rect.y=18
lavfi.rect.score=0.000000
frame:1    pts:1024    pts_time:0.125
lavfi.rect.w=40
lavfi.rect.h=30
lavfi.rect.x=24
lavfi.rect.y=21
lavfi.rect.score=0.045000
''');
    expect(samples, hasLength(2));
    expect(samples.first.time, Duration.zero);
    expect(samples.last.time, const Duration(milliseconds: 125));
    expect(samples.last.x, 24);
    expect(samples.last.y, 21);
    expect(samples.last.width, 40);
    expect(samples.last.height, 30);
    expect(samples.first.confidence, 1);
    expect(samples.last.confidence, closeTo(0.75, 0.001));
  });

  test('tracked freeform masks interpolate and survive persistence', () {
    final mask = EditorEffectMask(
      shape: EditorEffectMaskShape.freeform,
      trackingEnabled: true,
      points: const [
        EditorMaskPoint(0.1, 0.1),
        EditorMaskPoint(0.3, 0.1),
        EditorMaskPoint(0.2, 0.3),
      ],
      trackingKeyframes: [
        EditorMaskTrackingKeyframe(
          time: Duration.zero,
          x: 0.1,
          y: 0.1,
          width: 0.2,
          height: 0.2,
          points: const [
            EditorMaskPoint(0.1, 0.1),
            EditorMaskPoint(0.3, 0.1),
            EditorMaskPoint(0.2, 0.3),
          ],
        ),
        EditorMaskTrackingKeyframe(
          time: const Duration(seconds: 1),
          x: 0.5,
          y: 0.3,
          width: 0.2,
          height: 0.2,
          points: const [
            EditorMaskPoint(0.5, 0.3),
            EditorMaskPoint(0.7, 0.3),
            EditorMaskPoint(0.6, 0.5),
          ],
        ),
      ],
    );
    final restored = EditorEffectMask.fromJson(mask.toJson());
    final halfway = restored.resolvedAt(const Duration(milliseconds: 500));
    expect(restored.hasTrackedMotion, isTrue);
    expect(halfway.x, closeTo(0.3, 0.0001));
    expect(halfway.y, closeTo(0.2, 0.0001));
    expect(halfway.points.first.x, closeTo(0.3, 0.0001));
    expect(halfway.points.first.y, closeTo(0.2, 0.0001));
  });

  test(
    'tracking filter follows a moving target and emits real samples',
    () async {
      if (!await _commandExists('ffmpeg')) {
        markTestSkipped('Desktop FFmpeg is not installed.');
        return;
      }
      final directory = await Directory.systemTemp.createTemp(
        'captioncraft_tracking_',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final sourcePath = path.join(directory.path, 'moving.mp4');
      final objectPath = path.join(directory.path, 'object.png');
      final metadataPath = path.join(directory.path, 'tracking.txt');
      final source = await Process.run('ffmpeg', [
        '-hide_banner',
        '-loglevel',
        'error',
        '-y',
        '-f',
        'lavfi',
        '-i',
        'color=black:size=160x120:rate=12:duration=1.2',
        '-f',
        'lavfi',
        '-i',
        'color=white:size=28x24:rate=12:duration=1.2,'
            'drawbox=x=4:y=4:w=7:h=7:color=black:t=fill,'
            'drawbox=x=16:y=12:w=8:h=8:color=gray:t=fill',
        '-filter_complex',
        "[0:v][1:v]overlay=x='20+36*t':y=38:shortest=1",
        '-c:v',
        'libx264',
        '-pix_fmt',
        'yuv420p',
        sourcePath,
      ]);
      expect(source.exitCode, 0, reason: '${source.stderr}');
      final template = await Process.run('ffmpeg', [
        '-hide_banner',
        '-loglevel',
        'error',
        '-y',
        '-i',
        sourcePath,
        '-vf',
        'crop=28:24:20:38,format=gray',
        '-frames:v',
        '1',
        objectPath,
      ]);
      expect(template.exitCode, 0, reason: '${template.stderr}');
      final filter = MaskTrackingService.buildTrackingFilterForTesting(
        sourceStartTime: Duration.zero,
        sourceDuration: const Duration(seconds: 1),
        playbackRate: 1,
        reversed: false,
        sampleRate: 8,
        objectPath: objectPath,
        metadataPath: metadataPath,
      );
      final tracking = await Process.run('ffmpeg', [
        '-hide_banner',
        '-loglevel',
        'error',
        '-y',
        '-i',
        sourcePath,
        '-vf',
        filter,
        '-an',
        '-f',
        'null',
        '-',
      ]);
      expect(tracking.exitCode, 0, reason: '${tracking.stderr}');
      final samples = MaskTrackingService.parseMetadataForTesting(
        await File(metadataPath).readAsString(),
      );
      expect(samples.length, greaterThanOrEqualTo(5));
      expect(samples.last.x, greaterThan(samples.first.x + 15));
      expect(samples.every((sample) => sample.width > 0), isTrue);
      expect(samples.every((sample) => sample.height > 0), isTrue);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'waveform, parade, vectorscope, and histogram graphs execute',
    () async {
      if (!await _commandExists('ffmpeg')) {
        markTestSkipped('Desktop FFmpeg is not installed.');
        return;
      }
      const adjustments = ClipColorAdjustments(exposure: 0.2, saturation: 1.1);
      final failures = <String>[];
      for (final type in EditorVideoScopeType.values) {
        final graph = VideoScopeService.buildFilterGraphForTesting(
          adjustments: adjustments,
          type: type,
        );
        final result = await Process.run('ffmpeg', [
          '-hide_banner',
          '-loglevel',
          'error',
          '-f',
          'lavfi',
          '-i',
          'testsrc2=size=320x180:rate=12:duration=0.2',
          '-filter_complex',
          graph,
          '-map',
          '[scopeout]',
          '-frames:v',
          '1',
          '-f',
          'null',
          '-',
        ]);
        if (result.exitCode != 0) {
          failures.add('${type.name}: ${result.stderr}');
        }
      }
      expect(failures, isEmpty, reason: failures.join('\n'));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

Future<bool> _commandExists(String command) async {
  try {
    final result = await Process.run(command, const ['-version']);
    return result.exitCode == 0;
  } on ProcessException {
    return false;
  }
}
