import 'dart:convert';
import 'dart:io';

import 'package:caption_craft/core/utils/timeline_export_service.dart';
import 'package:caption_craft/features/editor/models/editor_effect_models.dart';
import 'package:caption_craft/features/editor/models/export_settings.dart';
import 'package:caption_craft/features/editor/models/timeline_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
  test(
    'masked keyframed stacks, adjustment layers, and buses render together',
    () async {
      if (!await _commandExists('ffmpeg') || !await _commandExists('ffprobe')) {
        markTestSkipped('Desktop FFmpeg tools are not installed.');
        return;
      }

      final directory = await Directory.systemTemp.createTemp(
        'captioncraft_effect_stack_',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final sourcePath = path.join(directory.path, 'source.mp4');
      final outputPath = path.join(directory.path, 'output.mp4');
      final lutPath = path.join(directory.path, 'identity.cube');
      await File(lutPath).writeAsString('''
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
''');
      await _runFfmpeg([
        '-f',
        'lavfi',
        '-i',
        'testsrc2=size=320x240:rate=24:duration=1.5',
        '-f',
        'lavfi',
        '-i',
        'sine=frequency=440:sample_rate=48000:duration=1.5',
        '-map',
        '0:v',
        '-map',
        '1:a',
        '-c:v',
        'libx264',
        '-pix_fmt',
        'yuv420p',
        '-c:a',
        'aac',
        '-shortest',
        sourcePath,
      ]);

      final asset = EditorAssetReference(
        id: 'asset',
        type: EditorAssetType.video,
        label: 'Source',
        sourcePath: sourcePath,
        metadata: const {
          'durationMs': 1500,
          'width': 320,
          'height': 240,
          'frameRate': 24,
          'hasAudio': true,
        },
      );
      final clip = TimelineClip(
        id: 'clip',
        trackId: 'base',
        type: TimelineTrackType.video,
        label: 'Source',
        assetId: asset.id,
        startTime: Duration.zero,
        endTime: const Duration(milliseconds: 1500),
        sourceDuration: const Duration(milliseconds: 1500),
        colorAdjustments: ClipColorAdjustments(
          lutPath: lutPath,
          lutIntensity: 0.4,
        ),
        effectStack: EditorEffectStack(
          effects: [
            EditorEffect(
              type: EditorEffectType.gaussianBlur,
              intensity: 0.65,
              mask: const EditorEffectMask(
                shape: EditorEffectMaskShape.ellipse,
                x: 0.2,
                y: 0.2,
                width: 0.6,
                height: 0.6,
                feather: 0.25,
              ),
              keyframes: [
                EditorEffectParameterKeyframe(
                  parameter: 'radius',
                  time: Duration.zero,
                  value: 1,
                ),
                EditorEffectParameterKeyframe(
                  parameter: 'radius',
                  time: const Duration(milliseconds: 1200),
                  value: 18,
                  interpolation: EditorEffectInterpolation.easeInOut,
                ),
              ],
            ),
          ],
        ),
      );
      final bus = TimelineAudioBus(
        id: 'dialogue',
        name: 'Dialogue',
        gain: 0.9,
        pan: -0.15,
        effectStack: EditorEffectStack(
          effects: [EditorEffect(type: EditorEffectType.compressor)],
        ),
      );
      final baseTrack = TimelineTrack(
        id: 'base',
        name: 'Base',
        type: TimelineTrackType.video,
        section: TimelineTrackSection.baseVideo,
        audioBusId: bus.id,
        clips: [clip],
      );
      final adjustment = TimelineClip.effect(
        id: 'adjustment',
        trackId: 'adjustments',
        label: 'Adjustment',
        startTime: const Duration(milliseconds: 300),
        endTime: const Duration(milliseconds: 1200),
        isAdjustmentLayer: true,
        effectStack: EditorEffectStack(
          effects: [
            EditorEffect(type: EditorEffectType.scanLines, intensity: 0.3),
          ],
        ),
      );
      final adjustmentTrack = TimelineTrack(
        id: 'adjustments',
        name: 'Adjustments',
        type: TimelineTrackType.video,
        section: TimelineTrackSection.overlay,
        clips: [adjustment],
      );
      final timeline = EditorTimeline(
        assets: [asset],
        tracks: [adjustmentTrack, baseTrack],
        audioBuses: [bus],
      );
      final input = TimelineRenderInput(
        index: 0,
        trackIndex: 1,
        track: baseTrack,
        clip: clip,
        asset: asset,
        sourcePath: sourcePath,
        hasAudio: true,
      );
      final arguments = TimelineExportService.buildFfmpegArguments(
        timeline: timeline,
        inputs: [input],
        settings: const ExportSettings(
          resolution: ExportResolution.p480,
          frameRate: ExportFrameRate.fps24,
          quality: ExportQuality.compact,
          burnSubtitles: false,
          saveToGallery: false,
        ),
        canvasSize: const ExportCanvasSize(
          width: 320,
          height: 240,
          framesPerSecond: 24,
        ),
        timelineDuration: const Duration(milliseconds: 1500),
        assPath: null,
        outputPath: outputPath,
      );
      final filterGraph = arguments[arguments.indexOf('-filter_complex') + 1];
      expect(filterGraph, contains('maskedmerge=planes=15'));
      expect(filterGraph, contains('geq=lum='));
      expect(filterGraph, contains('lut3d=file='));
      expect(filterGraph, contains('clipLut'));
      expect(filterGraph, contains('adjustmentStack'));
      expect(filterGraph, contains('busProcessed'));
      expect(filterGraph, contains('acompressor='));

      final render = await Process.run('ffmpeg', arguments);
      expect(render.exitCode, 0, reason: '${render.stdout}\n${render.stderr}');
      expect(await File(outputPath).length(), greaterThan(1000));

      final probe = await Process.run('ffprobe', [
        '-v',
        'error',
        '-show_entries',
        'format=duration:stream=codec_type,width,height',
        '-of',
        'json',
        outputPath,
      ]);
      expect(probe.exitCode, 0, reason: '${probe.stderr}');
      final metadata =
          jsonDecode(probe.stdout as String) as Map<String, dynamic>;
      final streams = (metadata['streams'] as List)
          .cast<Map<String, dynamic>>();
      expect(streams.any((stream) => stream['codec_type'] == 'video'), isTrue);
      expect(streams.any((stream) => stream['codec_type'] == 'audio'), isTrue);
      final duration = double.parse(
        (metadata['format'] as Map<String, dynamic>)['duration'] as String,
      );
      expect(duration, closeTo(1.5, 0.12));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

Future<bool> _commandExists(String command) async {
  final result = await Process.run(command, const ['-version']);
  return result.exitCode == 0;
}

Future<void> _runFfmpeg(List<String> arguments) async {
  final result = await Process.run('ffmpeg', [
    '-hide_banner',
    '-loglevel',
    'error',
    '-y',
    ...arguments,
  ]);
  expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
}
