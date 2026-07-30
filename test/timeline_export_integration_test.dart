import 'dart:convert';
import 'dart:io';

import 'package:caption_craft/core/utils/subtitle_export_service.dart';
import 'package:caption_craft/core/utils/timeline_export_service.dart';
import 'package:caption_craft/features/editor/models/export_settings.dart';
import 'package:caption_craft/features/editor/models/subtitle_entry.dart';
import 'package:caption_craft/features/editor/models/subtitle_style_model.dart';
import 'package:caption_craft/features/editor/models/timeline_models.dart';
import 'package:caption_craft/features/editor/models/word_timing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test(
    'planned command renders layered video, mixed audio, and ASS captions',
    () async {
      if (!await _commandExists('ffmpeg') || !await _commandExists('ffprobe')) {
        markTestSkipped('Desktop FFmpeg tools are not installed.');
        return;
      }

      final workingDirectory = await Directory.systemTemp.createTemp(
        'captioncraft_render_test_',
      );
      addTearDown(() async {
        if (await workingDirectory.exists()) {
          await workingDirectory.delete(recursive: true);
        }
      });

      final firstVideo = p.join(workingDirectory.path, 'first.mp4');
      final secondVideo = p.join(workingDirectory.path, 'second.mp4');
      final overlayImage = p.join(workingDirectory.path, 'overlay.bmp');
      final captions = p.join(workingDirectory.path, 'captions.ass');
      final output = p.join(workingDirectory.path, 'master.mp4');

      await _runFfmpeg([
        '-f',
        'lavfi',
        '-i',
        'testsrc2=size=640x360:rate=30:duration=1.6',
        '-f',
        'lavfi',
        '-i',
        'sine=frequency=440:sample_rate=48000:duration=1.6',
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
        firstVideo,
      ]);
      await _runFfmpeg([
        '-f',
        'lavfi',
        '-i',
        'color=c=0x174A5B:size=640x360:rate=30:duration=1.4',
        '-f',
        'lavfi',
        '-i',
        'sine=frequency=660:sample_rate=48000:duration=1.4',
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
        secondVideo,
      ]);
      await _runFfmpeg([
        '-f',
        'lavfi',
        '-i',
        'color=c=0xF6C453:size=180x100',
        '-frames:v',
        '1',
        overlayImage,
      ]);
      await File(captions).writeAsString(
        SubtitleExportService.buildAssDocument(
          [
            SubtitleEntry(
              startTime: const Duration(milliseconds: 550),
              endTime: const Duration(milliseconds: 2550),
              text: 'CaptionCraft render test',
              words: const [
                WordTiming(
                  word: 'CaptionCraft',
                  startTime: Duration(milliseconds: 550),
                  endTime: Duration(milliseconds: 1220),
                ),
                WordTiming(
                  word: 'render',
                  startTime: Duration(milliseconds: 1380),
                  endTime: Duration(milliseconds: 1810),
                ),
                WordTiming(
                  word: 'test',
                  startTime: Duration(milliseconds: 1980),
                  endTime: Duration(milliseconds: 2400),
                ),
              ],
              styleOverride: const SubtitleStyleModel(
                fontFamily: 'Arial',
                fontSize: 34,
                isBold: true,
                backgroundType: SubtitleBackground.fullBar,
                backgroundColor: Color(0xFF111412),
                backgroundOpacity: 0.82,
                animationPreset: SubtitleAnimationPreset.karaokeHighlight,
              ),
            ),
          ],
          const SubtitleStyleModel(fontFamily: 'Arial', fontSize: 34),
          playResX: 640,
          playResY: 360,
        ),
      );

      final overlayAsset = EditorAssetReference(
        id: 'overlay_asset',
        type: EditorAssetType.image,
        label: 'Overlay card',
        sourcePath: overlayImage,
        metadata: const {'durationMs': 2000, 'hasAudio': false},
      );
      final firstAsset = EditorAssetReference(
        id: 'first_asset',
        type: EditorAssetType.video,
        label: 'First source',
        sourcePath: firstVideo,
        metadata: const {
          'durationMs': 1600,
          'width': 640,
          'height': 360,
          'hasAudio': true,
          'frameRate': 30,
        },
      );
      final secondAsset = EditorAssetReference(
        id: 'second_asset',
        type: EditorAssetType.video,
        label: 'Second source',
        sourcePath: secondVideo,
        metadata: const {
          'durationMs': 1400,
          'width': 640,
          'height': 360,
          'hasAudio': true,
          'frameRate': 30,
        },
      );

      final overlayClip = TimelineClip(
        id: 'overlay_clip',
        trackId: 'overlay_track',
        type: TimelineTrackType.image,
        label: 'Overlay card',
        assetId: overlayAsset.id,
        startTime: const Duration(milliseconds: 450),
        endTime: const Duration(milliseconds: 2450),
        sourceDuration: const Duration(seconds: 2),
        fitMode: ClipFitMode.contain,
        crop: const ClipCropSettings(left: 0.06, right: 0.04),
        blur: const ClipBlurSettings(
          mode: ClipBlurMode.region,
          strength: 5,
          regionX: 0.2,
          regionY: 0.2,
          regionWidth: 0.5,
          regionHeight: 0.4,
        ),
        transform: const TimelineTransform(
          offsetX: 68,
          offsetY: -38,
          scale: 0.82,
          rotation: 0.04,
          opacity: 0.82,
        ),
        introTransition: const ClipTransition(
          type: TransitionType.zoom,
          durationMs: 220,
        ),
        outroTransition: const ClipTransition(
          type: TransitionType.fade,
          durationMs: 220,
        ),
      );
      final firstClip = TimelineClip(
        id: 'first_clip',
        trackId: 'base_track',
        type: TimelineTrackType.video,
        label: 'First source',
        assetId: firstAsset.id,
        startTime: Duration.zero,
        endTime: const Duration(milliseconds: 1600),
        sourceDuration: const Duration(milliseconds: 1600),
        isReversed: true,
        crop: const ClipCropSettings(top: 0.05, bottom: 0.05),
        blur: const ClipBlurSettings(mode: ClipBlurMode.full, strength: 2),
        colorAdjustments: const ClipColorAdjustments(
          contrast: 1.05,
          saturation: 1.08,
          vignette: 0.12,
        ),
        audioMix: const AudioMixSettings(
          volume: 0.72,
          fadeInMs: 100,
          fadeOutMs: 180,
          pan: -0.12,
        ),
        outroTransition: const ClipTransition(
          type: TransitionType.dissolve,
          durationMs: 200,
        ),
      );
      final secondClip = TimelineClip(
        id: 'second_clip',
        trackId: 'base_track',
        type: TimelineTrackType.video,
        label: 'Second source',
        assetId: secondAsset.id,
        startTime: const Duration(milliseconds: 1600),
        endTime: const Duration(milliseconds: 3000),
        sourceDuration: const Duration(milliseconds: 1400),
        audioMix: const AudioMixSettings(
          volume: 0.68,
          fadeInMs: 180,
          pan: 0.12,
        ),
        introTransition: const ClipTransition(
          type: TransitionType.fade,
          durationMs: 200,
        ),
      );

      final overlayTrack = TimelineTrack(
        id: 'overlay_track',
        name: 'Overlay 1',
        type: TimelineTrackType.image,
        section: TimelineTrackSection.overlay,
        clips: [overlayClip],
      );
      final baseTrack = TimelineTrack(
        id: 'base_track',
        name: 'Video 1',
        type: TimelineTrackType.video,
        section: TimelineTrackSection.baseVideo,
        clips: [firstClip, secondClip],
      );
      final timeline = EditorTimeline(
        canvasSettings: const CanvasSettings(
          aspectRatioPreset: CanvasAspectRatioPreset.ratio16x9,
          backgroundColor: Color(0xFF101210),
        ),
        assets: [overlayAsset, firstAsset, secondAsset],
        tracks: [overlayTrack, baseTrack],
      );
      final inputs = [
        TimelineRenderInput(
          index: 0,
          trackIndex: 0,
          track: overlayTrack,
          clip: overlayClip,
          asset: overlayAsset,
          sourcePath: overlayImage,
          hasAudio: false,
        ),
        TimelineRenderInput(
          index: 1,
          trackIndex: 1,
          track: baseTrack,
          clip: firstClip,
          asset: firstAsset,
          sourcePath: firstVideo,
          hasAudio: true,
        ),
        TimelineRenderInput(
          index: 2,
          trackIndex: 1,
          track: baseTrack,
          clip: secondClip,
          asset: secondAsset,
          sourcePath: secondVideo,
          hasAudio: true,
        ),
      ];

      final arguments = TimelineExportService.buildFfmpegArguments(
        timeline: timeline,
        inputs: inputs,
        settings: const ExportSettings(
          resolution: ExportResolution.p480,
          frameRate: ExportFrameRate.fps30,
          quality: ExportQuality.compact,
          saveToGallery: false,
        ),
        canvasSize: const ExportCanvasSize(
          width: 640,
          height: 360,
          framesPerSecond: 30,
        ),
        timelineDuration: const Duration(seconds: 3),
        assPath: captions,
        outputPath: output,
      );
      final filterGraph = arguments[arguments.indexOf('-filter_complex') + 1];
      expect(filterGraph, contains('reverse'));
      expect(filterGraph, contains('areverse'));
      expect(filterGraph, contains('gblur=sigma='));
      expect(filterGraph, contains('crop=w=trunc(iw*'));
      expect(filterGraph, contains('blurRegion'));

      final render = await Process.run('ffmpeg', arguments);
      expect(render.exitCode, 0, reason: '${render.stdout}\n${render.stderr}');

      final outputFile = File(output);
      expect(await outputFile.exists(), isTrue);
      expect(await outputFile.length(), greaterThan(20 * 1024));

      final probe = await Process.run('ffprobe', [
        '-v',
        'error',
        '-show_entries',
        'format=duration:stream=codec_type,width,height',
        '-of',
        'json',
        output,
      ]);
      expect(probe.exitCode, 0, reason: '${probe.stderr}');
      final metadata =
          jsonDecode(probe.stdout as String) as Map<String, dynamic>;
      final streams = metadata['streams'] as List<dynamic>;
      final video = streams.cast<Map<String, dynamic>>().firstWhere(
        (stream) => stream['codec_type'] == 'video',
      );
      expect(video['width'], 640);
      expect(video['height'], 360);
      expect(
        streams.any(
          (stream) => (stream as Map<String, dynamic>)['codec_type'] == 'audio',
        ),
        isTrue,
      );
      final format = metadata['format'] as Map<String, dynamic>;
      final duration = double.parse(format['duration'] as String);
      expect(duration, closeTo(3, 0.12));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

Future<bool> _commandExists(String executable) async {
  try {
    final result = await Process.run(executable, ['-version']);
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}

Future<void> _runFfmpeg(List<String> arguments) async {
  final result = await Process.run('ffmpeg', [
    '-hide_banner',
    '-loglevel',
    'error',
    '-y',
    ...arguments,
  ]);
  if (result.exitCode != 0) {
    throw StateError(
      'Synthetic media generation failed:\n'
      '${result.stdout}\n${result.stderr}',
    );
  }
}
