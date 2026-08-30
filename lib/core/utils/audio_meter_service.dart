import 'dart:convert';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';

import '../../features/editor/models/editor_effect_models.dart';
import '../../features/editor/models/timeline_models.dart';
import 'timeline_export_service.dart';

class AudioMeterService {
  AudioMeterService._();

  static Future<AudioLoudnessAnalysis> analyzeClip({
    required EditorTimeline timeline,
    required TimelineTrack track,
    required TimelineClip clip,
    required EditorAssetReference? asset,
    required String sourcePath,
  }) async {
    if (clip.duration <= Duration.zero) {
      throw ArgumentError('The selected audio range is empty.');
    }
    final fingerprint = fingerprintForClip(
      timeline: timeline,
      track: track,
      clip: clip,
      asset: asset,
      sourcePath: sourcePath,
    );
    final analysisMix = clip.audioMix.copyWith(
      muted: false,
      normalize: false,
      clearLoudnessAnalysis: true,
    );
    final analysisClip = clip.copyWith(
      startTime: Duration.zero,
      endTime: clip.duration,
      audioMix: analysisMix,
    );
    final analysisTrack = track.copyWith(
      isMuted: false,
      isSolo: false,
      clips: [analysisClip],
    );
    final analysisTimeline = timeline.copyWith(tracks: [analysisTrack]);
    final input = _input(
      timeline: analysisTimeline,
      track: analysisTrack,
      clip: analysisClip,
      asset: asset,
      sourcePath: sourcePath,
    );
    final arguments = TimelineExportService.buildAudioAnalysisArguments(
      timeline: analysisTimeline,
      inputs: [input],
      timelineDuration: analysisClip.duration,
      targetLufs: clip.audioMix.targetLufs,
      peakLimitDb: clip.audioMix.peakLimitDb,
    );
    final session = await FFmpegKit.executeWithArguments(arguments);
    final returnCode = await session.getReturnCode();
    final logs = await session.getAllLogsAsString() ?? '';
    if (!ReturnCode.isSuccess(returnCode)) {
      throw Exception(
        'Audio analysis failed${logs.trim().isEmpty ? '.' : ': ${_tail(logs)}'}',
      );
    }
    return parseLogs(logs, sourceFingerprint: fingerprint);
  }

  static String fingerprintForClip({
    required EditorTimeline timeline,
    required TimelineTrack track,
    required TimelineClip clip,
    required EditorAssetReference? asset,
    required String sourcePath,
  }) {
    return TimelineExportService.audioAnalysisFingerprint(
      timeline: timeline,
      input: _input(
        timeline: timeline,
        track: track,
        clip: clip,
        asset: asset,
        sourcePath: sourcePath,
      ),
    );
  }

  static TimelineRenderInput _input({
    required EditorTimeline timeline,
    required TimelineTrack track,
    required TimelineClip clip,
    required EditorAssetReference? asset,
    required String sourcePath,
  }) {
    final metadata = asset?.metadata ?? const <String, dynamic>{};
    return TimelineRenderInput(
      index: 0,
      trackIndex: timeline.tracks.indexWhere(
        (candidate) => candidate.id == track.id,
      ),
      track: track,
      clip: clip,
      asset: asset,
      sourcePath: sourcePath,
      hasAudio: true,
      frameRate: (metadata['frameRate'] as num?)?.toDouble(),
      colorPrimaries: metadata['colorPrimaries'] as String?,
      colorTransfer: metadata['colorTransfer'] as String?,
      colorSpace: metadata['colorSpace'] as String?,
      colorRange: metadata['colorRange'] as String?,
      bitDepth: metadata['bitDepth'] as int?,
      audioStreamCount: metadata['audioStreamCount'] as int?,
      audioChannels: metadata['audioChannels'] as int?,
      audioChannelsByStream: audioChannelsByStreamFromMetadata(
        metadata['audioStreams'],
      ),
    );
  }

  static AudioLoudnessAnalysis parseLogs(
    String logs, {
    required String sourceFingerprint,
  }) {
    Map<String, dynamic>? loudnorm;
    for (final match in RegExp(
      r'\{[^{}]*"input_i"[^{}]*\}',
      multiLine: true,
    ).allMatches(logs)) {
      try {
        final decoded = jsonDecode(match.group(0)!);
        if (decoded is Map<String, dynamic>) loudnorm = decoded;
      } catch (_) {
        // Continue to the final complete loudnorm summary.
      }
    }
    if (loudnorm == null) {
      throw const FormatException('FFmpeg did not return loudness statistics.');
    }
    double number(String key, [double fallback = 0]) {
      final raw = loudnorm![key];
      final parsed = raw is num ? raw.toDouble() : double.tryParse('$raw');
      return parsed?.isFinite == true ? parsed! : fallback;
    }

    double lastMetric(String label, double fallback) {
      final matches = RegExp(
        '${RegExp.escape(label)}\\s*:\\s*(-?(?:\\d+(?:\\.\\d+)?|inf))',
        caseSensitive: false,
      ).allMatches(logs);
      if (matches.isEmpty) return fallback;
      final raw = matches.last.group(1)?.toLowerCase();
      if (raw == '-inf') return -120;
      return double.tryParse(raw ?? '') ?? fallback;
    }

    final truePeak = number('input_tp', -1);
    return AudioLoudnessAnalysis(
      integratedLufs: number('input_i', -24),
      truePeakDb: truePeak,
      samplePeakDb: lastMetric('Peak level dB', truePeak),
      rmsDb: lastMetric('RMS level dB', number('input_i', -24)),
      loudnessRange: number('input_lra'),
      thresholdLufs: number('input_thresh', -34),
      targetOffset: number('target_offset'),
      sourceFingerprint: sourceFingerprint,
    );
  }

  static String _tail(String logs) {
    final compact = logs.trim().replaceAll(RegExp(r'\s+'), ' ');
    return compact.length <= 420
        ? compact
        : compact.substring(compact.length - 420);
  }
}
