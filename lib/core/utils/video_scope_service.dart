import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../../features/editor/models/timeline_models.dart';
import 'timeline_export_service.dart';

enum EditorVideoScopeType { waveform, rgbParade, vectorscope, histogram }

extension EditorVideoScopeTypeLabel on EditorVideoScopeType {
  String get label => switch (this) {
    EditorVideoScopeType.waveform => 'Waveform',
    EditorVideoScopeType.rgbParade => 'RGB Parade',
    EditorVideoScopeType.vectorscope => 'Vectorscope',
    EditorVideoScopeType.histogram => 'Histogram',
  };
}

class VideoScopeService {
  VideoScopeService._();

  static final Map<String, String> _cache = <String, String>{};
  static final List<String> _cacheOrder = <String>[];
  static const int _maximumCacheEntries = 36;

  static Future<String> render({
    required String sourcePath,
    required Duration sourcePosition,
    required ClipColorAdjustments adjustments,
    required EditorVideoScopeType type,
  }) async {
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw Exception('The source media is unavailable.');
    }
    final stat = await source.stat();
    final roundedPositionMs = (sourcePosition.inMilliseconds ~/ 125) * 125;
    final fingerprint = sha1
        .convert(
          utf8.encode(
            '$sourcePath|${stat.size}|${stat.modified.millisecondsSinceEpoch}|'
            '$roundedPositionMs|${type.name}|${jsonEncode(adjustments.toJson())}',
          ),
        )
        .toString();
    final cached = _cache[fingerprint];
    if (cached != null && await File(cached).exists()) return cached;

    final temporaryDirectory = await getTemporaryDirectory();
    final outputPath = path.join(
      temporaryDirectory.path,
      'cc_scope_$fingerprint.png',
    );
    final filterGraph = buildFilterGraphForTesting(
      adjustments: adjustments,
      type: type,
    );
    final session = await FFmpegKit.executeWithArguments([
      '-hide_banner',
      '-y',
      '-ss',
      _seconds(Duration(milliseconds: roundedPositionMs)),
      '-i',
      sourcePath,
      '-filter_complex',
      filterGraph,
      '-map',
      '[scopeout]',
      '-frames:v',
      '1',
      outputPath,
    ]);
    final returnCode = await session.getReturnCode();
    if (!ReturnCode.isSuccess(returnCode) ||
        !await File(outputPath).exists() ||
        await File(outputPath).length() == 0) {
      final logs = await session.getAllLogsAsString();
      throw Exception('Could not update ${type.label.toLowerCase()}: $logs');
    }
    await _remember(fingerprint, outputPath);
    return outputPath;
  }

  static String buildFilterGraphForTesting({
    required ClipColorAdjustments adjustments,
    required EditorVideoScopeType type,
  }) {
    final colorPlan = TimelineExportService.buildColorAdjustmentGraphPlan(
      adjustments,
      sourceLabel: '0:v',
    );
    final scopeFilter = switch (type) {
      EditorVideoScopeType.waveform =>
        'waveform=mode=column:display=overlay:components=1:'
            'graticule=green:scale=ire:fitmode=size:intensity=0.08,'
            'scale=640:260:flags=fast_bilinear',
      EditorVideoScopeType.rgbParade =>
        'waveform=mode=column:display=parade:components=7:'
            'graticule=green:scale=ire:fitmode=size:intensity=0.08,'
            'scale=640:260:flags=fast_bilinear',
      EditorVideoScopeType.vectorscope =>
        'vectorscope=mode=color4:graticule=color:flags=white+black+name:'
            'intensity=0.012:bgopacity=0.3:colorspace=709,'
            'scale=420:420:flags=fast_bilinear',
      EditorVideoScopeType.histogram =>
        'histogram=display_mode=overlay:levels_mode=logarithmic:'
            'components=7:colors_mode=coloronblack:level_height=220,'
            'scale=640:260:flags=fast_bilinear',
    };
    return <String>[
      if (colorPlan.filterGraph.isNotEmpty) colorPlan.filterGraph,
      '[${colorPlan.outputLabel}]$scopeFilter,format=rgba[scopeout]',
    ].join(';');
  }

  static Future<void> _remember(String key, String filePath) async {
    _cache[key] = filePath;
    _cacheOrder
      ..remove(key)
      ..add(key);
    while (_cacheOrder.length > _maximumCacheEntries) {
      final oldest = _cacheOrder.removeAt(0);
      final obsoletePath = _cache.remove(oldest);
      if (obsoletePath == null || _cache.containsValue(obsoletePath)) continue;
      try {
        final obsolete = File(obsoletePath);
        if (await obsolete.exists()) await obsolete.delete();
      } catch (_) {
        // Scope images are a bounded best-effort cache.
      }
    }
  }

  static String _seconds(Duration duration) {
    final value = duration.inMicroseconds / Duration.microsecondsPerSecond;
    final text = value.toStringAsFixed(6).replaceFirst(RegExp(r'\.?0+$'), '');
    return text.isEmpty ? '0' : text;
  }
}
