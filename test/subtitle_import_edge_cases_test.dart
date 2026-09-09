import 'dart:io';
import 'package:caption_craft/core/utils/subtitle_export_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'SRT rejects malformed timestamps without truncating long hours',
    () async {
      final root = await Directory.systemTemp.createTemp('srt-edge-');
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}/captions.srt');
      await file.writeAsString('''1
100:00:00,100 --> 100:00:02,200
Long recording

2
-00:00:01,000 --> 00:00:02,000
Negative time

3
00:99:00,000 --> 01:40:00,000
Invalid minute

4
00:00:01,000garbage --> 00:00:02,000
Trailing garbage
''');
      final cues = await SubtitleExportService.importSrt(file.path);
      expect(cues, hasLength(1));
      expect(
        cues.single.startTime,
        const Duration(hours: 100, milliseconds: 100),
      );
    },
  );

  test(
    'VTT rejects invalid fractions and fields but keeps valid cues',
    () async {
      final root = await Directory.systemTemp.createTemp('vtt-edge-');
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}/captions.vtt');
      await file.writeAsString('''WEBVTT

00:01.abc --> 00:02.000
Bad fraction

00:61.000 --> 01:03.000
Bad seconds

-1:00.000 --> 00:02.000
Negative minute

00:01.2 --> 00:02.350 align:center
Valid compatible fraction
''');
      final cues = await SubtitleExportService.importVtt(file.path);
      expect(cues, hasLength(1));
      expect(cues.single.startTime, const Duration(milliseconds: 1200));
      expect(cues.single.endTime, const Duration(milliseconds: 2350));
    },
  );
}
