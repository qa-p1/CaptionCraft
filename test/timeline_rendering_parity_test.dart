import 'dart:io';
import 'dart:math' as math;

import 'package:caption_craft/core/utils/timeline_export_service.dart';
import 'package:caption_craft/features/editor/models/export_settings.dart';
import 'package:caption_craft/features/editor/models/timeline_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _canvas = ExportCanvasSize(width: 192, height: 108, framesPerSecond: 15);
const _duration = Duration(milliseconds: 1200);
const _exportSettings = ExportSettings(
  resolution: ExportResolution.p480,
  frameRate: ExportFrameRate.fps30,
  quality: ExportQuality.compact,
  saveToGallery: false,
);

void main() {
  late bool hasDesktopFfmpeg;
  late Directory workingDirectory;
  late String sourcePath;
  late String baselinePath;
  late String longSourcePath;
  late String noisySourcePath;
  late String animatedGifPath;
  late String chromaSourcePath;
  late String geometrySourcePath;
  late EditorAssetReference sourceAsset;
  late EditorAssetReference longSourceAsset;
  late EditorAssetReference noisySourceAsset;
  late EditorAssetReference animatedGifAsset;
  late EditorAssetReference chromaSourceAsset;
  late EditorAssetReference geometrySourceAsset;

  setUpAll(() async {
    hasDesktopFfmpeg =
        await _commandExists('ffmpeg') && await _commandExists('ffprobe');
    if (!hasDesktopFfmpeg) return;

    workingDirectory = await Directory.systemTemp.createTemp(
      'captioncraft_effect_parity_',
    );
    sourcePath = p.join(workingDirectory.path, 'pattern.mp4');
    baselinePath = p.join(workingDirectory.path, 'baseline.mp4');
    longSourcePath = p.join(workingDirectory.path, 'long_pattern.mp4');
    noisySourcePath = p.join(workingDirectory.path, 'noisy_pattern.mp4');
    animatedGifPath = p.join(workingDirectory.path, 'pattern.gif');
    chromaSourcePath = p.join(workingDirectory.path, 'chroma_pattern.mp4');
    geometrySourcePath = p.join(workingDirectory.path, 'geometry_pattern.mp4');
    await _runFfmpeg([
      '-f',
      'lavfi',
      '-i',
      'testsrc2=size=${_canvas.width}x${_canvas.height}:'
          'rate=${_canvas.framesPerSecond}:duration=1.2',
      '-f',
      'lavfi',
      '-i',
      'sine=frequency=523:sample_rate=48000:duration=1.2',
      '-map',
      '0:v',
      '-map',
      '1:a',
      '-c:v',
      'libx264',
      '-preset',
      'ultrafast',
      '-pix_fmt',
      'yuv420p',
      '-c:a',
      'aac',
      '-shortest',
      sourcePath,
    ]);
    sourceAsset = EditorAssetReference(
      id: 'pattern_asset',
      type: EditorAssetType.video,
      label: 'Synthetic pattern',
      sourcePath: sourcePath,
      metadata: const {
        'durationMs': 1200,
        'width': 192,
        'height': 108,
        'frameRate': 15,
        'hasAudio': true,
      },
    );
    await _runFfmpeg([
      '-f',
      'lavfi',
      '-i',
      'testsrc2=size=${_canvas.width}x${_canvas.height}:'
          'rate=${_canvas.framesPerSecond}:duration=12',
      '-f',
      'lavfi',
      '-i',
      'aevalsrc=(0.04+0.015*t)*sin(2*PI*440*t):s=48000:d=12',
      '-map',
      '0:v',
      '-map',
      '1:a',
      '-c:v',
      'libx264',
      '-preset',
      'ultrafast',
      '-pix_fmt',
      'yuv420p',
      '-c:a',
      'aac',
      '-shortest',
      longSourcePath,
    ]);
    longSourceAsset = EditorAssetReference(
      id: 'long_pattern_asset',
      type: EditorAssetType.video,
      label: 'Long synthetic pattern',
      sourcePath: longSourcePath,
      metadata: const {
        'durationMs': 12000,
        'width': 192,
        'height': 108,
        'frameRate': 15,
        'hasAudio': true,
      },
    );
    await _runFfmpeg([
      '-f',
      'lavfi',
      '-i',
      'testsrc2=size=${_canvas.width}x${_canvas.height}:'
          'rate=${_canvas.framesPerSecond}:duration=1.2',
      '-f',
      'lavfi',
      '-i',
      'anoisesrc=color=white:amplitude=0.02:'
          'sample_rate=48000:duration=1.2',
      '-map',
      '0:v',
      '-map',
      '1:a',
      '-c:v',
      'libx264',
      '-preset',
      'ultrafast',
      '-pix_fmt',
      'yuv420p',
      '-c:a',
      'aac',
      '-shortest',
      noisySourcePath,
    ]);
    noisySourceAsset = EditorAssetReference(
      id: 'noisy_pattern_asset',
      type: EditorAssetType.video,
      label: 'Synthetic noisy pattern',
      sourcePath: noisySourcePath,
      metadata: const {
        'durationMs': 1200,
        'width': 192,
        'height': 108,
        'frameRate': 15,
        'hasAudio': true,
      },
    );
    final gifFramePaths = <String>[];
    for (final (index, color) in [
      '0xFF0000',
      '0x00FF00',
      '0x0000FF',
      '0xFFFF00',
    ].indexed) {
      final framePath = p.join(workingDirectory.path, 'gif_frame_$index.png');
      gifFramePaths.add(framePath);
      await _runFfmpeg([
        '-f',
        'lavfi',
        '-i',
        'color=c=$color:size=${_canvas.width}x${_canvas.height}',
        '-frames:v',
        '1',
        framePath,
      ]);
    }
    final gifConcatPath = p.join(workingDirectory.path, 'gif_frames.ffconcat');
    String concatPath(String value) => value.replaceAll(r'\', '/');
    await File(gifConcatPath).writeAsString(
      'ffconcat version 1.0\n'
      "file '${concatPath(gifFramePaths[0])}'\n"
      'duration 0.55\n'
      "file '${concatPath(gifFramePaths[1])}'\n"
      'duration 0.10\n'
      "file '${concatPath(gifFramePaths[2])}'\n"
      'duration 0.10\n'
      "file '${concatPath(gifFramePaths[3])}'\n"
      'duration 0.45\n'
      "file '${concatPath(gifFramePaths[3])}'\n",
    );
    await _runFfmpeg([
      '-f',
      'concat',
      '-safe',
      '0',
      '-i',
      gifConcatPath,
      '-fps_mode',
      'vfr',
      '-loop',
      '0',
      animatedGifPath,
    ]);
    animatedGifAsset = EditorAssetReference(
      id: 'pattern_gif_asset',
      type: EditorAssetType.gif,
      label: 'Synthetic animated GIF',
      sourcePath: animatedGifPath,
      metadata: const {
        'durationMs': 1200,
        'width': 192,
        'height': 108,
        'frameRate': 10,
        'hasAudio': false,
        'isAnimated': true,
      },
    );
    await _runFfmpeg([
      '-f',
      'lavfi',
      '-i',
      'color=c=0x00FF00:size=${_canvas.width}x${_canvas.height}:'
          'rate=${_canvas.framesPerSecond}:duration=1.2',
      '-vf',
      'drawbox=x=70:y=32:w=52:h=44:color=red:t=fill',
      '-an',
      '-c:v',
      'libx264',
      '-preset',
      'ultrafast',
      '-pix_fmt',
      'yuv420p',
      chromaSourcePath,
    ]);
    chromaSourceAsset = EditorAssetReference(
      id: 'chroma_pattern_asset',
      type: EditorAssetType.video,
      label: 'Synthetic chroma-key pattern',
      sourcePath: chromaSourcePath,
      metadata: const {
        'durationMs': 1200,
        'width': 192,
        'height': 108,
        'frameRate': 15,
        'hasAudio': false,
      },
    );
    await _runFfmpeg([
      '-f',
      'lavfi',
      '-i',
      'color=c=black:size=${_canvas.width}x${_canvas.height}:'
          'rate=${_canvas.framesPerSecond}:duration=1.2',
      '-vf',
      'drawbox=x=48:y=0:w=48:h=54:color=0x00FF00:t=fill,'
          'drawbox=x=96:y=0:w=48:h=54:color=0x0000FF:t=fill,'
          'drawbox=x=48:y=54:w=48:h=54:color=0xFFFF00:t=fill,'
          'drawbox=x=96:y=54:w=48:h=54:color=0xFF00FF:t=fill',
      '-an',
      '-c:v',
      'libx264',
      '-preset',
      'ultrafast',
      '-pix_fmt',
      'yuv420p',
      geometrySourcePath,
    ]);
    geometrySourceAsset = EditorAssetReference(
      id: 'geometry_pattern_asset',
      type: EditorAssetType.video,
      label: 'Synthetic crop and flip pattern',
      sourcePath: geometrySourcePath,
      metadata: const {
        'durationMs': 1200,
        'width': 192,
        'height': 108,
        'frameRate': 15,
        'hasAudio': false,
      },
    );
    await _render(_plan(sourceAsset: sourceAsset, outputPath: baselinePath));
  });

  tearDownAll(() async {
    if (hasDesktopFfmpeg && await workingDirectory.exists()) {
      await workingDirectory.delete(recursive: true);
    }
  });

  test(
    'full blur measurably reduces exported edge detail',
    () async {
      if (!hasDesktopFfmpeg) {
        markTestSkipped('Desktop FFmpeg tools are not installed.');
        return;
      }
      final output = p.join(workingDirectory.path, 'full_blur.mp4');
      final effect = TimelineClip.effect(
        id: 'full_blur',
        trackId: 'effects',
        effectKind: TimelineEffectKind.blur,
        label: 'Full blur',
        startTime: Duration.zero,
        endTime: _duration,
        blur: const ClipBlurSettings(mode: ClipBlurMode.full, strength: 12),
      );

      final plan = _plan(
        sourceAsset: sourceAsset,
        outputPath: output,
        effects: [effect],
      );
      await _render(plan);

      final baseline = await _extractRgbFrame(
        baselinePath,
        timestampSeconds: 0.6,
      );
      final blurred = await _extractRgbFrame(output, timestampSeconds: 0.6);
      final baselineEnergy = _edgeEnergy(
        baseline,
        _canvas.width,
        _canvas.height,
      );
      final blurredEnergy = _edgeEnergy(blurred, _canvas.width, _canvas.height);
      expect(
        blurredEnergy,
        lessThan(baselineEnergy * 0.72),
        reason: 'The exported frame retained too much high-frequency detail.',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'region blur changes its ROI while leaving a distant ROI stable',
    () async {
      if (!hasDesktopFfmpeg) {
        markTestSkipped('Desktop FFmpeg tools are not installed.');
        return;
      }
      final output = p.join(workingDirectory.path, 'region_blur.mp4');
      final effect = TimelineClip.effect(
        id: 'region_blur',
        trackId: 'effects',
        effectKind: TimelineEffectKind.blur,
        label: 'Region blur',
        startTime: Duration.zero,
        endTime: _duration,
        blur: const ClipBlurSettings(
          mode: ClipBlurMode.region,
          strength: 14,
          regionX: 0.1,
          regionY: 0.12,
          regionWidth: 0.44,
          regionHeight: 0.56,
        ),
      );

      await _render(
        _plan(sourceAsset: sourceAsset, outputPath: output, effects: [effect]),
      );
      const insideCrop = '52:44:24:18';
      const outsideCrop = '42:30:142:70';
      final baselineInside = await _extractRgbRoi(
        baselinePath,
        timestampSeconds: 0.6,
        crop: insideCrop,
      );
      final blurredInside = await _extractRgbRoi(
        output,
        timestampSeconds: 0.6,
        crop: insideCrop,
      );
      final baselineOutside = await _extractRgbRoi(
        baselinePath,
        timestampSeconds: 0.6,
        crop: outsideCrop,
      );
      final blurredOutside = await _extractRgbRoi(
        output,
        timestampSeconds: 0.6,
        crop: outsideCrop,
      );
      final insideDifference = _meanAbsoluteDifference(
        baselineInside,
        blurredInside,
      );
      final outsideDifference = _meanAbsoluteDifference(
        baselineOutside,
        blurredOutside,
      );

      expect(insideDifference, greaterThan(4));
      expect(
        _edgeEnergy(blurredInside, 52, 44),
        lessThan(_edgeEnergy(baselineInside, 52, 44) * 0.72),
        reason: 'Pixels in the selected region were changed but not blurred.',
      );
      expect(
        insideDifference,
        greaterThan(outsideDifference * 3 + 1),
        reason: 'Blur leaked outside its normalized region.',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'timed blur-strength keyframes change exported blur inside the effect',
    () async {
      if (!hasDesktopFfmpeg) {
        markTestSkipped('Desktop FFmpeg tools are not installed.');
        return;
      }
      const earlySeconds = 0.3;
      const lateSeconds = 0.9;
      final animatedOutput = p.join(
        workingDirectory.path,
        'blur_keyframes.mp4',
      );
      final animatedEffect =
          TimelineClip.effect(
            id: 'animated_blur',
            trackId: 'effects',
            effectKind: TimelineEffectKind.blur,
            label: 'Animated blur',
            startTime: const Duration(milliseconds: 200),
            endTime: const Duration(milliseconds: 1000),
            blur: const ClipBlurSettings(mode: ClipBlurMode.full, strength: 0),
          ).copyWith(
            keyframes: [
              _keyframe(TimelineKeyframeProperty.blurStrength, 0, 0),
              _keyframe(TimelineKeyframeProperty.blurStrength, 800, 24),
            ],
          );

      final animatedPlan = _plan(
        sourceAsset: sourceAsset,
        outputPath: animatedOutput,
        effects: [animatedEffect],
      );
      expect(animatedPlan.filterGraph, contains('sendcmd='));
      expect(animatedPlan.filterGraph, contains('gblur@effectFullBlur'));
      await _render(animatedPlan);

      final beforeEffect = await _extractRgbFrame(
        animatedOutput,
        timestampSeconds: 0.1,
      );
      final baselineBeforeEffect = await _extractRgbFrame(
        baselinePath,
        timestampSeconds: 0.1,
      );
      expect(
        _meanAbsoluteDifference(beforeEffect, baselineBeforeEffect),
        lessThan(3.25),
        reason: 'The timed blur changed frames before its effect interval.',
      );

      final animatedEarly = await _extractRgbFrame(
        animatedOutput,
        timestampSeconds: earlySeconds,
      );
      final animatedLate = await _extractRgbFrame(
        animatedOutput,
        timestampSeconds: lateSeconds,
      );
      final baselineEarly = await _extractRgbFrame(
        baselinePath,
        timestampSeconds: earlySeconds,
      );
      final baselineLate = await _extractRgbFrame(
        baselinePath,
        timestampSeconds: lateSeconds,
      );
      final earlyDetailRatio =
          _edgeEnergy(animatedEarly, _canvas.width, _canvas.height) /
          _edgeEnergy(baselineEarly, _canvas.width, _canvas.height);
      final lateDetailRatio =
          _edgeEnergy(animatedLate, _canvas.width, _canvas.height) /
          _edgeEnergy(baselineLate, _canvas.width, _canvas.height);
      expect(
        lateDetailRatio,
        lessThan(earlyDetailRatio * 0.72),
        reason: 'Increasing blur keyframes did not visibly soften the export.',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'timed effects exclude the first frame at their end boundary',
    () async {
      if (!hasDesktopFfmpeg) {
        markTestSkipped('Desktop FFmpeg tools are not installed.');
        return;
      }
      final output = p.join(workingDirectory.path, 'effect_boundary.mp4');
      final effect = TimelineClip.effect(
        id: 'bounded_filter',
        trackId: 'effects',
        effectKind: TimelineEffectKind.filter,
        label: 'Bounded monochrome',
        startTime: const Duration(milliseconds: 200),
        endTime: const Duration(milliseconds: 600),
        colorAdjustments: ClipColorAdjustments.forPreset(
          ClipFilterPreset.monochrome,
        ),
      );
      final plan = _plan(
        sourceAsset: sourceAsset,
        outputPath: output,
        effects: [effect],
      );
      expect(plan.filterGraph, contains('gte(t,0.200000)*lt(t,0.600000)'));
      await _render(plan);

      final inside = await _extractRgbFrame(output, timestampSeconds: 0.533);
      final baselineInside = await _extractRgbFrame(
        baselinePath,
        timestampSeconds: 0.533,
      );
      final atEnd = await _extractRgbFrame(output, timestampSeconds: 0.6);
      final baselineAtEnd = await _extractRgbFrame(
        baselinePath,
        timestampSeconds: 0.6,
      );
      final insideDifference = _meanAbsoluteDifference(inside, baselineInside);
      final endDifference = _meanAbsoluteDifference(atEnd, baselineAtEnd);
      expect(insideDifference, greaterThan(8));
      expect(
        endDifference,
        lessThan(math.min(5.0, insideDifference * 0.2)),
        reason: 'The effect remained active on its end-boundary frame.',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'timeline filter produces a visible exported pixel change',
    () async {
      if (!hasDesktopFfmpeg) {
        markTestSkipped('Desktop FFmpeg tools are not installed.');
        return;
      }
      final output = p.join(workingDirectory.path, 'filter.mp4');
      final effect = TimelineClip.effect(
        id: 'mono_filter',
        trackId: 'effects',
        effectKind: TimelineEffectKind.filter,
        label: 'Monochrome',
        startTime: Duration.zero,
        endTime: _duration,
        colorAdjustments: ClipColorAdjustments.forPreset(
          ClipFilterPreset.monochrome,
        ),
      );

      final plan = _plan(
        sourceAsset: sourceAsset,
        outputPath: output,
        effects: [effect],
      );
      await _render(plan);

      final baseline = await _extractRgbFrame(
        baselinePath,
        timestampSeconds: 0.6,
      );
      final filtered = await _extractRgbFrame(output, timestampSeconds: 0.6);
      expect(_meanAbsoluteDifference(baseline, filtered), greaterThan(8));
      expect(
        _meanChannelSpread(filtered),
        lessThan(_meanChannelSpread(baseline) * 0.12),
        reason: 'The monochrome preset changed pixels without removing color.',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'chroma key reveals the export canvas and preserves non-keyed pixels',
    () async {
      if (!hasDesktopFfmpeg) {
        markTestSkipped('Desktop FFmpeg tools are not installed.');
        return;
      }
      const blueCanvas = CanvasSettings(backgroundColor: Color(0xFF2030E0));
      final baselineOutput = p.join(
        workingDirectory.path,
        'chroma_baseline.mp4',
      );
      final keyedOutput = p.join(workingDirectory.path, 'chroma_keyed.mp4');
      final chromaClip = _baseClip().copyWith(assetId: chromaSourceAsset.id);
      await _render(
        _plan(
          sourceAsset: chromaSourceAsset,
          outputPath: baselineOutput,
          baseClip: chromaClip,
          hasAudio: false,
          canvasSettings: blueCanvas,
        ),
      );
      await _render(
        _plan(
          sourceAsset: chromaSourceAsset,
          outputPath: keyedOutput,
          baseClip: chromaClip.copyWith(
            chromaKeyEnabled: true,
            chromaKeyColor: const Color(0xFF00FF00),
            chromaKeySimilarity: 0.2,
          ),
          hasAudio: false,
          canvasSettings: blueCanvas,
        ),
      );

      final baselineBackground = await _extractRgbRoi(
        baselineOutput,
        timestampSeconds: 0.6,
        crop: '48:40:4:4',
      );
      final keyedBackground = await _extractRgbRoi(
        keyedOutput,
        timestampSeconds: 0.6,
        crop: '48:40:4:4',
      );
      final baselineForeground = await _extractRgbRoi(
        baselineOutput,
        timestampSeconds: 0.6,
        crop: '32:24:80:42',
      );
      final keyedForeground = await _extractRgbRoi(
        keyedOutput,
        timestampSeconds: 0.6,
        crop: '32:24:80:42',
      );
      final baselineBackgroundColor = _meanRgb(baselineBackground);
      final keyedBackgroundColor = _meanRgb(keyedBackground);

      expect(
        baselineBackgroundColor.$2,
        greaterThan(baselineBackgroundColor.$3 + 80),
        reason: 'The chroma fixture background was not green.',
      );
      expect(
        keyedBackgroundColor.$3,
        greaterThan(keyedBackgroundColor.$1 + 80),
      );
      expect(
        keyedBackgroundColor.$3,
        greaterThan(keyedBackgroundColor.$2 + 80),
      );
      expect(
        _meanAbsoluteDifference(baselineForeground, keyedForeground),
        lessThan(8),
        reason: 'Chroma key damaged pixels outside the selected key color.',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'keyframed opacity and volume visibly change over the exported timeline',
    () async {
      if (!hasDesktopFfmpeg) {
        markTestSkipped('Desktop FFmpeg tools are not installed.');
        return;
      }
      final output = p.join(workingDirectory.path, 'keyframes.mp4');
      final clip = _baseClip().copyWith(
        keyframes: [
          _keyframe(TimelineKeyframeProperty.opacity, 0, 0.24),
          _keyframe(TimelineKeyframeProperty.opacity, 1000, 1),
          _keyframe(TimelineKeyframeProperty.volume, 0, 0.18),
          _keyframe(TimelineKeyframeProperty.volume, 1000, 1),
        ],
      );
      final plan = _plan(
        sourceAsset: sourceAsset,
        outputPath: output,
        baseClip: clip,
      );
      await _render(plan);

      final earlyFrame = await _extractRgbFrame(output, timestampSeconds: 0.14);
      final lateFrame = await _extractRgbFrame(output, timestampSeconds: 0.92);
      expect(
        _meanLuma(lateFrame),
        greaterThan(_meanLuma(earlyFrame) * 1.45),
        reason: 'The opacity keyframe envelope was not visible in the render.',
      );

      final earlyRms = await _audioRms(
        output,
        startSeconds: 0.12,
        durationSeconds: 0.14,
      );
      final lateRms = await _audioRms(
        output,
        startSeconds: 0.88,
        durationSeconds: 0.14,
      );
      expect(
        lateRms,
        greaterThan(earlyRms * 2),
        reason: 'The volume keyframe envelope was flattened during export.',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'auto-duck lowers exported audio only during overlapping speech',
    () async {
      if (!hasDesktopFfmpeg) {
        markTestSkipped('Desktop FFmpeg tools are not installed.');
        return;
      }
      final output = p.join(workingDirectory.path, 'auto_duck.mp4');
      final speechTrack = TimelineTrack(
        id: 'speech_cues',
        name: 'Speech cues',
        type: TimelineTrackType.subtitle,
        section: TimelineTrackSection.textSubtitle,
        clips: [
          TimelineClip(
            id: 'speech',
            trackId: 'speech_cues',
            type: TimelineTrackType.subtitle,
            label: 'Speech',
            text: 'Speech',
            startTime: const Duration(milliseconds: 400),
            endTime: const Duration(milliseconds: 800),
          ),
        ],
      );
      final plan = _plan(
        sourceAsset: sourceAsset,
        outputPath: output,
        baseClip: _baseClip().copyWith(autoDuck: true, duckAmount: 0.75),
        additionalTracks: [speechTrack],
      );
      await _render(plan);

      final beforeSpeech = await _audioRms(
        output,
        startSeconds: 0.12,
        durationSeconds: 0.12,
      );
      final duringSpeech = await _audioRms(
        output,
        startSeconds: 0.52,
        durationSeconds: 0.12,
      );
      final afterSpeech = await _audioRms(
        output,
        startSeconds: 1.04,
        durationSeconds: 0.1,
      );

      expect(beforeSpeech, greaterThan(duringSpeech * 2.5));
      expect(afterSpeech, greaterThan(duringSpeech * 2.5));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'denoise filters are accepted and reduce exported noise energy',
    () async {
      if (!hasDesktopFfmpeg) {
        markTestSkipped('Desktop FFmpeg tools are not installed.');
        return;
      }
      final rawOutput = p.join(workingDirectory.path, 'raw_noise.mp4');
      final denoisedOutput = p.join(
        workingDirectory.path,
        'denoised_noise.mp4',
      );
      final noisyClip = _baseClip().copyWith(assetId: noisySourceAsset.id);
      await _render(
        _plan(
          sourceAsset: noisySourceAsset,
          outputPath: rawOutput,
          baseClip: noisyClip,
        ),
      );
      final denoisedPlan = _plan(
        sourceAsset: noisySourceAsset,
        outputPath: denoisedOutput,
        baseClip: noisyClip.copyWith(denoise: true),
      );
      expect(denoisedPlan.filterGraph, contains('hqdn3d='));
      expect(denoisedPlan.filterGraph, contains('afftdn='));
      await _render(denoisedPlan);

      final rawNoise = await _audioRms(
        rawOutput,
        startSeconds: 0.25,
        durationSeconds: 0.7,
      );
      final denoisedNoise = await _audioRms(
        denoisedOutput,
        startSeconds: 0.25,
        durationSeconds: 0.7,
      );
      expect(
        denoisedNoise,
        lessThan(rawNoise * 0.8),
        reason: 'Audio denoise rendered but did not reduce broadband noise.',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'stereo pan routes exported audio energy to the selected channel',
    () async {
      if (!hasDesktopFfmpeg) {
        markTestSkipped('Desktop FFmpeg tools are not installed.');
        return;
      }
      final leftOutput = p.join(workingDirectory.path, 'pan_left.mp4');
      final rightOutput = p.join(workingDirectory.path, 'pan_right.mp4');
      await _render(
        _plan(
          sourceAsset: sourceAsset,
          outputPath: leftOutput,
          baseClip: _baseClip().copyWith(
            audioMix: const AudioMixSettings(pan: -1),
          ),
        ),
      );
      await _render(
        _plan(
          sourceAsset: sourceAsset,
          outputPath: rightOutput,
          baseClip: _baseClip().copyWith(
            audioMix: const AudioMixSettings(pan: 1),
          ),
        ),
      );

      final leftPan = await _stereoAudioRms(
        leftOutput,
        startSeconds: 0.25,
        durationSeconds: 0.6,
      );
      final rightPan = await _stereoAudioRms(
        rightOutput,
        startSeconds: 0.25,
        durationSeconds: 0.6,
      );
      expect(leftPan.$1, greaterThan(leftPan.$2 * 8 + 100));
      expect(rightPan.$2, greaterThan(rightPan.$1 * 8 + 100));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'position keyframes match their expected exported positions over time',
    () async {
      if (!hasDesktopFfmpeg) {
        markTestSkipped('Desktop FFmpeg tools are not installed.');
        return;
      }
      const earlySeconds = 0.2;
      const lateSeconds = 0.8;
      const startX = -180.0;
      const endX = 180.0;
      final animatedOutput = p.join(
        workingDirectory.path,
        'position_keyframes.mp4',
      );
      final earlyReferenceOutput = p.join(
        workingDirectory.path,
        'position_early_reference.mp4',
      );
      final lateReferenceOutput = p.join(
        workingDirectory.path,
        'position_late_reference.mp4',
      );
      final animatedClip = _baseClip().copyWith(
        keyframes: [
          _keyframe(TimelineKeyframeProperty.positionX, 0, startX),
          _keyframe(TimelineKeyframeProperty.positionX, 1000, endX),
        ],
      );
      final earlyExpectedX = _lerp(startX, endX, earlySeconds);
      final lateExpectedX = _lerp(startX, endX, lateSeconds);

      await _render(
        _plan(
          sourceAsset: sourceAsset,
          outputPath: animatedOutput,
          baseClip: animatedClip,
        ),
      );
      await _render(
        _plan(
          sourceAsset: sourceAsset,
          outputPath: earlyReferenceOutput,
          baseClip: _baseClip().copyWith(
            transform: TimelineTransform(offsetX: earlyExpectedX),
          ),
        ),
      );
      await _render(
        _plan(
          sourceAsset: sourceAsset,
          outputPath: lateReferenceOutput,
          baseClip: _baseClip().copyWith(
            transform: TimelineTransform(offsetX: lateExpectedX),
          ),
        ),
      );

      final animatedEarly = await _extractRgbFrame(
        animatedOutput,
        timestampSeconds: earlySeconds,
      );
      final animatedLate = await _extractRgbFrame(
        animatedOutput,
        timestampSeconds: lateSeconds,
      );
      final expectedEarly = await _extractRgbFrame(
        earlyReferenceOutput,
        timestampSeconds: earlySeconds,
      );
      final wrongEarly = await _extractRgbFrame(
        lateReferenceOutput,
        timestampSeconds: earlySeconds,
      );
      final expectedLate = await _extractRgbFrame(
        lateReferenceOutput,
        timestampSeconds: lateSeconds,
      );
      final wrongLate = await _extractRgbFrame(
        earlyReferenceOutput,
        timestampSeconds: lateSeconds,
      );

      _expectCloserToExpected(
        actual: animatedEarly,
        expected: expectedEarly,
        wrongEndpoint: wrongEarly,
        feature: 'early position keyframe',
      );
      _expectCloserToExpected(
        actual: animatedLate,
        expected: expectedLate,
        wrongEndpoint: wrongLate,
        feature: 'late position keyframe',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'scale keyframes match their expected exported sizes over time',
    () async {
      if (!hasDesktopFfmpeg) {
        markTestSkipped('Desktop FFmpeg tools are not installed.');
        return;
      }
      const earlySeconds = 0.2;
      const lateSeconds = 0.8;
      const startScale = 0.5;
      const endScale = 1.0;
      final animatedOutput = p.join(
        workingDirectory.path,
        'scale_keyframes.mp4',
      );
      final earlyReferenceOutput = p.join(
        workingDirectory.path,
        'scale_early_reference.mp4',
      );
      final lateReferenceOutput = p.join(
        workingDirectory.path,
        'scale_late_reference.mp4',
      );
      final animatedClip = _baseClip().copyWith(
        keyframes: [
          _keyframe(TimelineKeyframeProperty.scale, 0, startScale),
          _keyframe(TimelineKeyframeProperty.scale, 1000, endScale),
        ],
      );
      final earlyExpectedScale = _lerp(startScale, endScale, earlySeconds);
      final lateExpectedScale = _lerp(startScale, endScale, lateSeconds);

      await _render(
        _plan(
          sourceAsset: sourceAsset,
          outputPath: animatedOutput,
          baseClip: animatedClip,
        ),
      );
      await _render(
        _plan(
          sourceAsset: sourceAsset,
          outputPath: earlyReferenceOutput,
          baseClip: _baseClip().copyWith(
            transform: TimelineTransform(scale: earlyExpectedScale),
          ),
        ),
      );
      await _render(
        _plan(
          sourceAsset: sourceAsset,
          outputPath: lateReferenceOutput,
          baseClip: _baseClip().copyWith(
            transform: TimelineTransform(scale: lateExpectedScale),
          ),
        ),
      );

      final animatedEarly = await _extractRgbFrame(
        animatedOutput,
        timestampSeconds: earlySeconds,
      );
      final animatedLate = await _extractRgbFrame(
        animatedOutput,
        timestampSeconds: lateSeconds,
      );
      final expectedEarly = await _extractRgbFrame(
        earlyReferenceOutput,
        timestampSeconds: earlySeconds,
      );
      final wrongEarly = await _extractRgbFrame(
        lateReferenceOutput,
        timestampSeconds: earlySeconds,
      );
      final expectedLate = await _extractRgbFrame(
        lateReferenceOutput,
        timestampSeconds: lateSeconds,
      );
      final wrongLate = await _extractRgbFrame(
        earlyReferenceOutput,
        timestampSeconds: lateSeconds,
      );

      _expectCloserToExpected(
        actual: animatedEarly,
        expected: expectedEarly,
        wrongEndpoint: wrongEarly,
        feature: 'early scale keyframe',
      );
      _expectCloserToExpected(
        actual: animatedLate,
        expected: expectedLate,
        wrongEndpoint: wrongLate,
        feature: 'late scale keyframe',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'rotation keyframes match their expected exported angles over time',
    () async {
      if (!hasDesktopFfmpeg) {
        markTestSkipped('Desktop FFmpeg tools are not installed.');
        return;
      }
      const earlySeconds = 0.2;
      const lateSeconds = 0.8;
      const startRotation = 0.0;
      const endRotation = math.pi / 2;
      final animatedOutput = p.join(
        workingDirectory.path,
        'rotation_keyframes.mp4',
      );
      final earlyReferenceOutput = p.join(
        workingDirectory.path,
        'rotation_early_reference.mp4',
      );
      final lateReferenceOutput = p.join(
        workingDirectory.path,
        'rotation_late_reference.mp4',
      );
      final sourceClip = _baseClip().copyWith(assetId: geometrySourceAsset.id);
      final animatedClip = sourceClip.copyWith(
        keyframes: [
          _keyframe(TimelineKeyframeProperty.rotation, 0, startRotation),
          _keyframe(TimelineKeyframeProperty.rotation, 1000, endRotation),
        ],
      );
      final earlyExpectedRotation = _lerp(
        startRotation,
        endRotation,
        earlySeconds,
      );
      final lateExpectedRotation = _lerp(
        startRotation,
        endRotation,
        lateSeconds,
      );

      await _render(
        _plan(
          sourceAsset: geometrySourceAsset,
          outputPath: animatedOutput,
          baseClip: animatedClip,
          hasAudio: false,
        ),
      );
      await _render(
        _plan(
          sourceAsset: geometrySourceAsset,
          outputPath: earlyReferenceOutput,
          baseClip: sourceClip.copyWith(
            transform: TimelineTransform(rotation: earlyExpectedRotation),
          ),
          hasAudio: false,
        ),
      );
      await _render(
        _plan(
          sourceAsset: geometrySourceAsset,
          outputPath: lateReferenceOutput,
          baseClip: sourceClip.copyWith(
            transform: TimelineTransform(rotation: lateExpectedRotation),
          ),
          hasAudio: false,
        ),
      );

      final animatedEarly = await _extractRgbFrame(
        animatedOutput,
        timestampSeconds: earlySeconds,
      );
      final animatedLate = await _extractRgbFrame(
        animatedOutput,
        timestampSeconds: lateSeconds,
      );
      final expectedEarly = await _extractRgbFrame(
        earlyReferenceOutput,
        timestampSeconds: earlySeconds,
      );
      final wrongEarly = await _extractRgbFrame(
        lateReferenceOutput,
        timestampSeconds: earlySeconds,
      );
      final expectedLate = await _extractRgbFrame(
        lateReferenceOutput,
        timestampSeconds: lateSeconds,
      );
      final wrongLate = await _extractRgbFrame(
        earlyReferenceOutput,
        timestampSeconds: lateSeconds,
      );

      _expectCloserToExpected(
        actual: animatedEarly,
        expected: expectedEarly,
        wrongEndpoint: wrongEarly,
        feature: 'early rotation keyframe',
      );
      _expectCloserToExpected(
        actual: animatedLate,
        expected: expectedLate,
        wrongEndpoint: wrongLate,
        feature: 'late rotation keyframe',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'source crop and both flips preserve the intended exported geometry',
    () async {
      if (!hasDesktopFfmpeg) {
        markTestSkipped('Desktop FFmpeg tools are not installed.');
        return;
      }
      final output = p.join(workingDirectory.path, 'crop_and_flip.mp4');
      final clip = _baseClip().copyWith(
        assetId: geometrySourceAsset.id,
        fitMode: ClipFitMode.stretch,
        crop: const ClipCropSettings(left: 0.25, right: 0.25),
        transform: const TimelineTransform(flipX: true, flipY: true),
      );
      final plan = _plan(
        sourceAsset: geometrySourceAsset,
        outputPath: output,
        baseClip: clip,
        hasAudio: false,
      );
      expect(plan.filterGraph, contains('crop=w='));
      expect(plan.filterGraph, contains('hflip'));
      expect(plan.filterGraph, contains('vflip'));
      await _render(plan);

      final topLeft = _meanRgb(
        await _extractRgbRoi(
          output,
          timestampSeconds: 0.6,
          crop: '16:16:24:16',
        ),
      );
      final topRight = _meanRgb(
        await _extractRgbRoi(
          output,
          timestampSeconds: 0.6,
          crop: '16:16:152:16',
        ),
      );
      final bottomLeft = _meanRgb(
        await _extractRgbRoi(
          output,
          timestampSeconds: 0.6,
          crop: '16:16:24:76',
        ),
      );
      final bottomRight = _meanRgb(
        await _extractRgbRoi(
          output,
          timestampSeconds: 0.6,
          crop: '16:16:152:76',
        ),
      );

      expect(topLeft.$1, greaterThan(topLeft.$2 + 80));
      expect(topLeft.$3, greaterThan(topLeft.$2 + 80));
      expect(topRight.$1, greaterThan(topRight.$3 + 80));
      expect(topRight.$2, greaterThan(topRight.$3 + 80));
      expect(bottomLeft.$3, greaterThan(bottomLeft.$1 + 80));
      expect(bottomLeft.$3, greaterThan(bottomLeft.$2 + 80));
      expect(bottomRight.$2, greaterThan(bottomRight.$1 + 80));
      expect(bottomRight.$2, greaterThan(bottomRight.$3 + 80));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'vignette darkens edges and sharpen restores exported edge detail',
    () async {
      if (!hasDesktopFfmpeg) {
        markTestSkipped('Desktop FFmpeg tools are not installed.');
        return;
      }
      final vignetteOutput = p.join(workingDirectory.path, 'vignette_only.mp4');
      final finishedOutput = p.join(
        workingDirectory.path,
        'vignette_and_sharpen.mp4',
      );
      const vignette = ClipColorAdjustments(vignette: 0.9);
      const finished = ClipColorAdjustments(vignette: 0.9, sharpen: 1);
      await _render(
        _plan(
          sourceAsset: sourceAsset,
          outputPath: vignetteOutput,
          baseClip: _baseClip().copyWith(colorAdjustments: vignette),
        ),
      );
      final finishedPlan = _plan(
        sourceAsset: sourceAsset,
        outputPath: finishedOutput,
        baseClip: _baseClip().copyWith(colorAdjustments: finished),
      );
      expect(finishedPlan.filterGraph, contains('vignette=angle='));
      expect(finishedPlan.filterGraph, contains('unsharp='));
      await _render(finishedPlan);

      const cornerCrop = '36:28:0:0';
      const centerCrop = '72:48:60:30';
      final baselineCorner = await _extractRgbRoi(
        baselinePath,
        timestampSeconds: 0.6,
        crop: cornerCrop,
      );
      final baselineCenter = await _extractRgbRoi(
        baselinePath,
        timestampSeconds: 0.6,
        crop: centerCrop,
      );
      final vignetteCorner = await _extractRgbRoi(
        vignetteOutput,
        timestampSeconds: 0.6,
        crop: cornerCrop,
      );
      final vignetteCenter = await _extractRgbRoi(
        vignetteOutput,
        timestampSeconds: 0.6,
        crop: centerCrop,
      );
      final finishedCenter = await _extractRgbRoi(
        finishedOutput,
        timestampSeconds: 0.6,
        crop: centerCrop,
      );
      final cornerLumaRatio =
          _meanLuma(vignetteCorner) / _meanLuma(baselineCorner);
      final centerLumaRatio =
          _meanLuma(vignetteCenter) / _meanLuma(baselineCenter);

      expect(
        cornerLumaRatio,
        lessThan(centerLumaRatio * 0.82),
        reason: 'Vignette did not darken exported corners relative to center.',
      );
      expect(
        _edgeEnergy(finishedCenter, 72, 48),
        greaterThan(_edgeEnergy(vignetteCenter, 72, 48) * 1.04),
        reason: 'Sharpen did not increase decoded edge detail.',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'freeze frame graph and output hold the selected source frame',
    () async {
      if (!hasDesktopFfmpeg) {
        markTestSkipped('Desktop FFmpeg tools are not installed.');
        return;
      }
      final output = p.join(workingDirectory.path, 'freeze.mp4');
      final clip = _baseClip().copyWith(
        freezeFrame: true,
        freezeFrameSourceTime: const Duration(milliseconds: 400),
      );
      final plan = _plan(
        sourceAsset: sourceAsset,
        outputPath: output,
        baseClip: clip,
      );

      expect(
        plan.filterGraph,
        anyOf(contains('tpad=stop_mode=clone'), contains('loop=')),
      );
      expect(plan.filterGraph, contains('trim='));
      await _render(plan);

      final frozenEarly = await _extractRgbFrame(
        output,
        timestampSeconds: 0.16,
      );
      final frozenLate = await _extractRgbFrame(output, timestampSeconds: 0.94);
      final baselineEarly = await _extractRgbFrame(
        baselinePath,
        timestampSeconds: 0.16,
      );
      final baselineLate = await _extractRgbFrame(
        baselinePath,
        timestampSeconds: 0.94,
      );
      final selectedSourceFrame = await _extractRgbFrame(
        baselinePath,
        timestampSeconds: 0.4,
      );
      final frozenDifference = _meanAbsoluteDifference(frozenEarly, frozenLate);
      final movingDifference = _meanAbsoluteDifference(
        baselineEarly,
        baselineLate,
      );
      final selectedFrameDifference = _meanAbsoluteDifference(
        frozenEarly,
        selectedSourceFrame,
      );
      final earlySourceDifference = _meanAbsoluteDifference(
        frozenEarly,
        baselineEarly,
      );
      final lateSourceDifference = _meanAbsoluteDifference(
        frozenEarly,
        baselineLate,
      );

      expect(movingDifference, greaterThan(3));
      expect(frozenDifference, lessThan(movingDifference * 0.15));
      expect(frozenDifference, lessThan(1.5));
      expect(
        selectedFrameDifference,
        lessThan(4.5),
        reason: 'Freeze held a frame other than the selected source frame.',
      );
      expect(
        selectedFrameDifference,
        lessThan(math.min(earlySourceDifference, lateSourceDifference) * 0.35),
        reason:
            'Freeze output was closer to a moving frame than its selection.',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'deep freeze selection uses bounded decoding and keeps original audio',
    () async {
      if (!hasDesktopFfmpeg) {
        markTestSkipped('Desktop FFmpeg tools are not installed.');
        return;
      }
      const timelineDuration = Duration(milliseconds: 2700);
      final movingOutput = p.join(workingDirectory.path, 'long_moving.mp4');
      final frozenOutput = p.join(workingDirectory.path, 'long_freeze.mp4');
      final movingClip = _baseClip().copyWith(
        assetId: longSourceAsset.id,
        endTime: timelineDuration,
        sourceDuration: const Duration(seconds: 12),
        playbackRate: 4,
      );
      final frozenClip = movingClip.copyWith(
        freezeFrame: true,
        freezeFrameSourceTime: const Duration(milliseconds: 10400),
      );
      await _render(
        _plan(
          sourceAsset: longSourceAsset,
          outputPath: movingOutput,
          baseClip: movingClip,
          timelineDuration: timelineDuration,
        ),
      );
      final frozenPlan = _plan(
        sourceAsset: longSourceAsset,
        outputPath: frozenOutput,
        baseClip: frozenClip,
        timelineDuration: timelineDuration,
      );
      expect(frozenPlan.filterGraph, contains('[1:v]'));
      expect(frozenPlan.filterGraph, contains('[0:a]'));
      expect(frozenPlan.filterGraph, contains('trim=end=1.000001,reverse'));
      expect(frozenPlan.filterGraph, isNot(contains('trim=end=10.400001')));
      expect(
        frozenPlan.arguments,
        containsAllInOrder(['-ss', '9.400000', '-t', '1.400000']),
      );
      await _render(frozenPlan);

      final frozenEarly = await _extractRgbFrame(
        frozenOutput,
        timestampSeconds: 0.2,
      );
      final frozenLate = await _extractRgbFrame(
        frozenOutput,
        timestampSeconds: 2.3,
      );
      final selected = await _extractRgbFrame(
        longSourcePath,
        timestampSeconds: 10.4,
      );
      expect(_meanAbsoluteDifference(frozenEarly, frozenLate), lessThan(1.5));
      expect(_meanAbsoluteDifference(frozenEarly, selected), lessThan(4.5));

      for (final start in [0.2, 1.9]) {
        final movingRms = await _audioRms(
          movingOutput,
          startSeconds: start,
          durationSeconds: 0.25,
        );
        final frozenRms = await _audioRms(
          frozenOutput,
          startSeconds: start,
          durationSeconds: 0.25,
        );
        expect(frozenRms, closeTo(movingRms, movingRms * 0.06));
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'animated GIF freeze export holds its selected source frame',
    () async {
      if (!hasDesktopFfmpeg) {
        markTestSkipped('Desktop FFmpeg tools are not installed.');
        return;
      }
      final gifFrameTimes = await _videoFrameTimes(animatedGifPath);
      expect(gifFrameTimes, hasLength(greaterThanOrEqualTo(4)));
      expect(
        gifFrameTimes[1],
        greaterThan(0.4),
        reason: 'The selected 0.4s instant must still be in the first frame.',
      );
      final gifFrameGaps = <double>[
        for (var index = 1; index < gifFrameTimes.length; index++)
          gifFrameTimes[index] - gifFrameTimes[index - 1],
      ].where((gap) => gap > 0.001).toList();
      expect(
        gifFrameGaps.reduce(math.max),
        greaterThan(gifFrameGaps.reduce(math.min) * 3),
        reason: 'The freeze fixture must retain variable frame delays.',
      );
      final movingOutput = p.join(workingDirectory.path, 'moving_gif.mp4');
      final frozenOutput = p.join(workingDirectory.path, 'frozen_gif.mp4');
      final gifClip = _baseClip().copyWith(
        type: TimelineTrackType.gif,
        assetId: animatedGifAsset.id,
      );
      await _render(
        _plan(
          sourceAsset: animatedGifAsset,
          outputPath: movingOutput,
          baseClip: gifClip,
          hasAudio: false,
        ),
      );
      await _render(
        _plan(
          sourceAsset: animatedGifAsset,
          outputPath: frozenOutput,
          baseClip: gifClip.copyWith(
            freezeFrame: true,
            freezeFrameSourceTime: const Duration(milliseconds: 400),
          ),
          hasAudio: false,
        ),
      );

      final frozenEarly = await _extractRgbFrame(
        frozenOutput,
        timestampSeconds: 0.16,
      );
      final frozenLate = await _extractRgbFrame(
        frozenOutput,
        timestampSeconds: 0.94,
      );
      final selectedFrame = await _extractRgbFrame(
        movingOutput,
        timestampSeconds: 0.4,
      );
      final movingMiddle = await _extractRgbFrame(
        movingOutput,
        timestampSeconds: 0.68,
      );
      final movingLate = await _extractRgbFrame(
        movingOutput,
        timestampSeconds: 0.94,
      );
      final frozenDifference = _meanAbsoluteDifference(frozenEarly, frozenLate);
      final selectedDifference = _meanAbsoluteDifference(
        frozenEarly,
        selectedFrame,
      );
      final wrongFrameDifference = math.min(
        _meanAbsoluteDifference(frozenEarly, movingMiddle),
        _meanAbsoluteDifference(frozenEarly, movingLate),
      );

      expect(frozenDifference, lessThan(1.5));
      expect(selectedDifference, lessThan(5));
      expect(
        selectedDifference,
        lessThan(wrongFrameDifference * 0.4),
        reason: 'Animated GIF freeze did not hold the selected frame.',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'zoom transition changes exported geometry beyond its alpha fade',
    () async {
      if (!hasDesktopFfmpeg) {
        markTestSkipped('Desktop FFmpeg tools are not installed.');
        return;
      }
      final output = p.join(workingDirectory.path, 'zoom.mp4');
      final fadeControlOutput = p.join(
        workingDirectory.path,
        'zoom_fade_control.mp4',
      );
      final clip = _baseClip().copyWith(
        introTransition: const ClipTransition(
          type: TransitionType.zoom,
          durationMs: 600,
        ),
      );
      final plan = _plan(
        sourceAsset: sourceAsset,
        outputPath: output,
        baseClip: clip,
      );
      final fadeControlPlan = _plan(
        sourceAsset: sourceAsset,
        outputPath: fadeControlOutput,
        baseClip: _baseClip().copyWith(
          introTransition: const ClipTransition(
            type: TransitionType.fade,
            durationMs: 600,
          ),
        ),
      );
      await _render(plan);
      await _render(fadeControlPlan);

      final zoomEarly = await _extractRgbFrame(output, timestampSeconds: 0.2);
      final fadeEarly = await _extractRgbFrame(
        fadeControlOutput,
        timestampSeconds: 0.2,
      );
      final zoomLate = await _extractRgbFrame(output, timestampSeconds: 0.9);
      final fadeLate = await _extractRgbFrame(
        fadeControlOutput,
        timestampSeconds: 0.9,
      );
      final earlyGeometryDifference = _meanAbsoluteDifference(
        zoomEarly,
        fadeEarly,
      );
      final lateDifference = _meanAbsoluteDifference(zoomLate, fadeLate);

      expect(
        earlyGeometryDifference,
        greaterThan(3),
        reason: 'Zoom rendered identically to a fade-only transition.',
      );
      expect(
        earlyGeometryDifference,
        greaterThan(lateDifference * 3 + 1),
        reason: 'Zoom did not converge to the unscaled frame after its intro.',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'dissolve exports a distinct eased alpha curve from linear fade',
    () async {
      if (!hasDesktopFfmpeg) {
        markTestSkipped('Desktop FFmpeg tools are not installed.');
        return;
      }
      final dissolveOutput = p.join(
        workingDirectory.path,
        'dissolve_transition.mp4',
      );
      final fadeOutput = p.join(
        workingDirectory.path,
        'linear_fade_transition.mp4',
      );
      await _render(
        _plan(
          sourceAsset: sourceAsset,
          outputPath: dissolveOutput,
          baseClip: _baseClip().copyWith(
            introTransition: const ClipTransition(
              type: TransitionType.dissolve,
              durationMs: 600,
            ),
          ),
        ),
      );
      await _render(
        _plan(
          sourceAsset: sourceAsset,
          outputPath: fadeOutput,
          baseClip: _baseClip().copyWith(
            introTransition: const ClipTransition(
              type: TransitionType.fade,
              durationMs: 600,
            ),
          ),
        ),
      );

      final dissolveEarly = await _extractRgbFrame(
        dissolveOutput,
        timestampSeconds: 0.2,
      );
      final fadeEarly = await _extractRgbFrame(
        fadeOutput,
        timestampSeconds: 0.2,
      );
      final dissolveLate = await _extractRgbFrame(
        dissolveOutput,
        timestampSeconds: 0.9,
      );
      final fadeLate = await _extractRgbFrame(
        fadeOutput,
        timestampSeconds: 0.9,
      );
      final curveDifference = _meanAbsoluteDifference(dissolveEarly, fadeEarly);
      final completedDifference = _meanAbsoluteDifference(
        dissolveLate,
        fadeLate,
      );

      expect(
        curveDifference,
        greaterThan(2),
        reason: 'Dissolve was rendered as the same linear curve as fade.',
      );
      expect(
        curveDifference,
        greaterThan(completedDifference * 2 + 0.5),
        reason: 'The transition curves did not converge after completion.',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

TimelineKeyframe _keyframe(
  TimelineKeyframeProperty property,
  int milliseconds,
  double value,
) {
  return TimelineKeyframe(
    time: Duration(milliseconds: milliseconds),
    property: property,
    value: value,
  );
}

double _lerp(double start, double end, double seconds) {
  return start + (end - start) * seconds;
}

void _expectCloserToExpected({
  required List<int> actual,
  required List<int> expected,
  required List<int> wrongEndpoint,
  required String feature,
}) {
  final expectedDifference = _meanAbsoluteDifference(actual, expected);
  final wrongEndpointDifference = _meanAbsoluteDifference(
    actual,
    wrongEndpoint,
  );
  expect(
    wrongEndpointDifference,
    greaterThan(3),
    reason: 'The test fixture does not distinguish the $feature endpoints.',
  );
  expect(
    expectedDifference,
    lessThan(wrongEndpointDifference * 0.35),
    reason: 'The exported $feature did not match its interpolated value.',
  );
}

TimelineClip _baseClip() {
  return TimelineClip(
    id: 'base_clip',
    trackId: 'base_track',
    type: TimelineTrackType.video,
    label: 'Synthetic source',
    assetId: 'pattern_asset',
    startTime: Duration.zero,
    endTime: _duration,
    sourceStartTime: Duration.zero,
    sourceDuration: _duration,
  );
}

_RenderPlan _plan({
  required EditorAssetReference sourceAsset,
  required String outputPath,
  TimelineClip? baseClip,
  List<TimelineClip> effects = const [],
  List<TimelineTrack> additionalTracks = const [],
  bool hasAudio = true,
  CanvasSettings canvasSettings = const CanvasSettings(),
  Duration timelineDuration = _duration,
}) {
  final clip = baseClip ?? _baseClip();
  final baseTrack = TimelineTrack(
    id: 'base_track',
    name: 'Video 1',
    type: clip.type,
    section: TimelineTrackSection.baseVideo,
    clips: [clip],
  );
  final tracks = <TimelineTrack>[...additionalTracks];
  if (effects.isNotEmpty) {
    tracks.add(
      TimelineTrack(
        id: 'effects',
        name: 'Effects',
        type: TimelineTrackType.effect,
        section: TimelineTrackSection.overlay,
        clips: effects,
      ),
    );
  }
  // Timeline rows are stored top-to-bottom. Overlay/effect lanes therefore
  // precede the main lane so paint order remains bottom-to-top without a
  // special source-video exception.
  tracks.add(baseTrack);
  final timeline = EditorTimeline(
    assets: [sourceAsset],
    tracks: tracks,
    canvasSettings: canvasSettings,
  );
  final arguments = TimelineExportService.buildFfmpegArguments(
    timeline: timeline,
    inputs: [
      TimelineRenderInput(
        index: 0,
        trackIndex: 0,
        track: baseTrack,
        clip: clip,
        asset: sourceAsset,
        sourcePath: sourceAsset.sourcePath!,
        hasAudio: hasAudio,
      ),
    ],
    settings: _exportSettings,
    canvasSize: _canvas,
    timelineDuration: timelineDuration,
    assPath: null,
    outputPath: outputPath,
  );
  return _RenderPlan(arguments);
}

class _RenderPlan {
  final List<String> arguments;

  const _RenderPlan(this.arguments);

  String get filterGraph => arguments[arguments.indexOf('-filter_complex') + 1];
}

Future<List<double>> _videoFrameTimes(String videoPath) async {
  final result = await Process.run('ffprobe', [
    '-v',
    'error',
    '-select_streams',
    'v:0',
    '-show_entries',
    'frame=best_effort_timestamp_time',
    '-of',
    'csv=p=0',
    videoPath,
  ]);
  if (result.exitCode != 0) {
    throw StateError('Frame timestamp probe failed:\n${result.stderr}');
  }
  return (result.stdout as String)
      .split(RegExp(r'\r?\n'))
      .map((line) => double.tryParse(line.trim()))
      .whereType<double>()
      .toList();
}

Future<bool> _commandExists(String executable) async {
  try {
    final result = await Process.run(executable, ['-version']);
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}

Future<void> _render(_RenderPlan plan) async {
  final result = await Process.run('ffmpeg', plan.arguments);
  if (result.exitCode != 0) {
    throw StateError(
      'Timeline render failed:\n${result.stdout}\n${result.stderr}\n'
      '${plan.filterGraph}',
    );
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

Future<List<int>> _extractRgbFrame(
  String videoPath, {
  required double timestampSeconds,
}) {
  return _extractRgbRoi(
    videoPath,
    timestampSeconds: timestampSeconds,
    crop: '${_canvas.width}:${_canvas.height}:0:0',
  );
}

Future<List<int>> _extractRgbRoi(
  String videoPath, {
  required double timestampSeconds,
  required String crop,
}) async {
  final result = await Process.run('ffmpeg', [
    '-hide_banner',
    '-loglevel',
    'error',
    '-ss',
    timestampSeconds.toStringAsFixed(3),
    '-i',
    videoPath,
    '-frames:v',
    '1',
    '-vf',
    'crop=$crop',
    '-pix_fmt',
    'rgb24',
    '-f',
    'rawvideo',
    'pipe:1',
  ], stdoutEncoding: null);
  if (result.exitCode != 0) {
    throw StateError('Frame extraction failed:\n${result.stderr}');
  }
  return result.stdout as List<int>;
}

Future<double> _audioRms(
  String videoPath, {
  required double startSeconds,
  required double durationSeconds,
}) async {
  final result = await Process.run('ffmpeg', [
    '-hide_banner',
    '-loglevel',
    'error',
    '-ss',
    startSeconds.toStringAsFixed(3),
    '-i',
    videoPath,
    '-t',
    durationSeconds.toStringAsFixed(3),
    '-vn',
    '-ac',
    '1',
    '-ar',
    '8000',
    '-f',
    's16le',
    'pipe:1',
  ], stdoutEncoding: null);
  if (result.exitCode != 0) {
    throw StateError('Audio extraction failed:\n${result.stderr}');
  }
  final bytes = result.stdout as List<int>;
  if (bytes.length < 2) return 0;
  var sumSquares = 0.0;
  var sampleCount = 0;
  for (var index = 0; index + 1 < bytes.length; index += 2) {
    var sample = bytes[index] | (bytes[index + 1] << 8);
    if (sample >= 0x8000) sample -= 0x10000;
    sumSquares += sample * sample;
    sampleCount++;
  }
  return math.sqrt(sumSquares / sampleCount);
}

Future<(double, double)> _stereoAudioRms(
  String videoPath, {
  required double startSeconds,
  required double durationSeconds,
}) async {
  final result = await Process.run('ffmpeg', [
    '-hide_banner',
    '-loglevel',
    'error',
    '-ss',
    startSeconds.toStringAsFixed(3),
    '-i',
    videoPath,
    '-t',
    durationSeconds.toStringAsFixed(3),
    '-vn',
    '-ac',
    '2',
    '-ar',
    '8000',
    '-f',
    's16le',
    'pipe:1',
  ], stdoutEncoding: null);
  if (result.exitCode != 0) {
    throw StateError('Stereo audio extraction failed:\n${result.stderr}');
  }
  final bytes = result.stdout as List<int>;
  if (bytes.length < 4) return (0.0, 0.0);
  var leftSquares = 0.0;
  var rightSquares = 0.0;
  var frameCount = 0;
  for (var index = 0; index + 3 < bytes.length; index += 4) {
    var left = bytes[index] | (bytes[index + 1] << 8);
    var right = bytes[index + 2] | (bytes[index + 3] << 8);
    if (left >= 0x8000) left -= 0x10000;
    if (right >= 0x8000) right -= 0x10000;
    leftSquares += left * left;
    rightSquares += right * right;
    frameCount++;
  }
  return (
    math.sqrt(leftSquares / frameCount),
    math.sqrt(rightSquares / frameCount),
  );
}

double _meanAbsoluteDifference(List<int> first, List<int> second) {
  expect(first, hasLength(second.length));
  var difference = 0.0;
  for (var index = 0; index < first.length; index++) {
    difference += (first[index] - second[index]).abs();
  }
  return difference / first.length;
}

double _meanLuma(List<int> rgb) {
  var sum = 0.0;
  var pixels = 0;
  for (var index = 0; index + 2 < rgb.length; index += 3) {
    sum += _luma(rgb, index);
    pixels++;
  }
  return pixels == 0 ? 0 : sum / pixels;
}

double _meanChannelSpread(List<int> rgb) {
  var sum = 0.0;
  var pixels = 0;
  for (var index = 0; index + 2 < rgb.length; index += 3) {
    final red = rgb[index];
    final green = rgb[index + 1];
    final blue = rgb[index + 2];
    sum +=
        math.max(red, math.max(green, blue)) -
        math.min(red, math.min(green, blue));
    pixels++;
  }
  return pixels == 0 ? 0 : sum / pixels;
}

(double, double, double) _meanRgb(List<int> rgb) {
  var red = 0.0;
  var green = 0.0;
  var blue = 0.0;
  var pixels = 0;
  for (var index = 0; index + 2 < rgb.length; index += 3) {
    red += rgb[index];
    green += rgb[index + 1];
    blue += rgb[index + 2];
    pixels++;
  }
  if (pixels == 0) return (0.0, 0.0, 0.0);
  return (red / pixels, green / pixels, blue / pixels);
}

double _edgeEnergy(List<int> rgb, int width, int height) {
  expect(rgb, hasLength(width * height * 3));
  var energy = 0.0;
  var comparisons = 0;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final index = (y * width + x) * 3;
      final value = _luma(rgb, index);
      if (x + 1 < width) {
        energy += (value - _luma(rgb, index + 3)).abs();
        comparisons++;
      }
      if (y + 1 < height) {
        energy += (value - _luma(rgb, index + width * 3)).abs();
        comparisons++;
      }
    }
  }
  return energy / comparisons;
}

double _luma(List<int> rgb, int index) {
  return rgb[index] * 0.299 + rgb[index + 1] * 0.587 + rgb[index + 2] * 0.114;
}
