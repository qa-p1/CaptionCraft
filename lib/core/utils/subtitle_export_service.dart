import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../../features/editor/models/subtitle_entry.dart';
import '../../features/editor/models/subtitle_style_model.dart';

/// Service for generating subtitle files in SRT, VTT, and ASS formats.
class SubtitleExportService {
  SubtitleExportService._();

  /// Generate an SRT file.
  static Future<String> generateSrt(List<SubtitleEntry> entries) async {
    final buffer = StringBuffer();
    final sorted = List<SubtitleEntry>.from(entries)
      ..sort((a, b) => a.startTime.compareTo(b.startTime));
    var cueIndex = 1;

    for (final entry in sorted) {
      if (entry.endTime <= entry.startTime) continue;
      final text = entry.text.trim();
      if (text.isEmpty) continue;
      buffer.writeln(cueIndex++);
      buffer.writeln(
        '${SubtitleEntry.formatSrtTime(entry.startTime)} --> '
        '${SubtitleEntry.formatSrtTime(entry.endTime)}',
      );
      buffer.writeln(text);
      buffer.writeln();
    }

    if (cueIndex == 1) {
      throw Exception('No valid subtitle lines available for SRT export.');
    }

    final tempDir = await getTemporaryDirectory();
    final filePath = p.join(tempDir.path, 'captions.srt');
    await File(filePath).writeAsString(buffer.toString());
    return filePath;
  }

  /// Generate a VTT file.
  static Future<String> generateVtt(List<SubtitleEntry> entries) async {
    final buffer = StringBuffer();
    buffer.writeln('WEBVTT');
    buffer.writeln();

    final sorted = List<SubtitleEntry>.from(entries)
      ..sort((a, b) => a.startTime.compareTo(b.startTime));
    var cueIndex = 1;

    for (final entry in sorted) {
      if (entry.endTime <= entry.startTime) continue;
      final text = entry.text.trim();
      if (text.isEmpty) continue;
      buffer.writeln(cueIndex++);
      buffer.writeln(
        '${SubtitleEntry.formatVttTime(entry.startTime)} --> '
        '${SubtitleEntry.formatVttTime(entry.endTime)}',
      );
      buffer.writeln(text);
      buffer.writeln();
    }

    if (cueIndex == 1) {
      throw Exception('No valid subtitle lines available for VTT export.');
    }

    final tempDir = await getTemporaryDirectory();
    final filePath = p.join(tempDir.path, 'captions.vtt');
    await File(filePath).writeAsString(buffer.toString());
    return filePath;
  }

  /// Generate an ASS (Advanced SubStation Alpha) file for FFmpeg subtitle burning.
  static Future<String> generateAss(
    List<SubtitleEntry> entries,
    SubtitleStyleModel globalStyle,
    {String? fileName}
  ) async {
    final buffer = StringBuffer();

    // Script Info
    buffer.writeln('[Script Info]');
    buffer.writeln('Title: CaptionCraft Export');
    buffer.writeln('ScriptType: v4.00+');
    buffer.writeln('PlayResX: 1920');
    buffer.writeln('PlayResY: 1080');
    buffer.writeln();

    // Styles
    buffer.writeln('[V4+ Styles]');
    buffer.writeln(
      'Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, '
      'OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, '
      'ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, '
      'Alignment, MarginL, MarginR, MarginV, Encoding',
    );

    // Default style
    final defaultStyle = _buildAssStyle('Default', globalStyle);
    buffer.writeln(defaultStyle);
    buffer.writeln();

    // Events
    buffer.writeln('[Events]');
    buffer.writeln(
      'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text',
    );

    final sorted = List<SubtitleEntry>.from(entries)
      ..sort((a, b) => a.startTime.compareTo(b.startTime));

    for (final entry in sorted) {
      if (entry.endTime <= entry.startTime) continue;
      final start = _formatAssTime(entry.startTime);
      final end = _formatAssTime(entry.endTime);
      final text = _escapeAssText(entry.text);
      if (text.isEmpty) continue;
      final styleName = 'Default';

      buffer.writeln('Dialogue: 0,$start,$end,$styleName,,0,0,0,,$text');
    }

    final tempDir = await getTemporaryDirectory();
    final resolvedFileName =
        (fileName?.trim().isNotEmpty == true ? fileName!.trim() : 'captions.ass')
            .replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
    final filePath = p.join(tempDir.path, resolvedFileName);
    await File(filePath).writeAsString(buffer.toString());
    return filePath;
  }

  /// Escape ASS control characters so user text is rendered literally.
  static String _escapeAssText(String text) {
    return text
        .replaceAll('\\', r'\\')
        .replaceAll('{', r'\{')
        .replaceAll('}', r'\}')
        .replaceAll('\n', r'\N')
        .trim();
  }

  static String _buildAssStyle(String name, SubtitleStyleModel style) {
    final fontName = style.fontFamily;
    final fontSize = style.fontSize.round();
    final primaryColor = _colorToAss(style.textColor);
    final outlineColor = '&H00000000'; // Black outline
    final backColor = _colorToAss(style.backgroundColor);
    final bold = style.isBold ? -1 : 0;
    final italic = style.isItalic ? -1 : 0;
    final borderStyle =
        style.backgroundType == SubtitleBackground.fullBar ||
            style.backgroundType == SubtitleBackground.semiTransparentBox
        ? 3
        : 1;
    final outline = style.backgroundType == SubtitleBackground.outlineShadow
        ? 3
        : 2;
    final shadow = style.backgroundType == SubtitleBackground.outlineShadow
        ? 2
        : 0;

    // ASS alignment: 2 = bottom center (default)
    int alignment;
    switch (style.position) {
      case SubtitlePosition.top:
        alignment = 8; // top center
        break;
      case SubtitlePosition.center:
        alignment = 5; // middle center
        break;
      case SubtitlePosition.bottom:
        alignment = 2; // bottom center
        break;
    }

    return 'Style: $name,$fontName,$fontSize,$primaryColor,&H000000FF,'
        '$outlineColor,$backColor,$bold,$italic,0,0,100,100,0,0,'
        '$borderStyle,$outline,$shadow,$alignment,10,10,10,1';
  }

  /// Convert a Flutter Color to ASS color format (&HAABBGGRR).
  static String _colorToAss(Color color) {
    final alpha = ((color.a * 255.0).round().clamp(0, 255)) as int;
    final blue = ((color.b * 255.0).round().clamp(0, 255)) as int;
    final green = ((color.g * 255.0).round().clamp(0, 255)) as int;
    final red = ((color.r * 255.0).round().clamp(0, 255)) as int;
    final a = (255 - alpha).toRadixString(16).padLeft(2, '0').toUpperCase();
    final b = blue.toRadixString(16).padLeft(2, '0').toUpperCase();
    final g = green.toRadixString(16).padLeft(2, '0').toUpperCase();
    final r = red.toRadixString(16).padLeft(2, '0').toUpperCase();
    return '&H$a$b$g$r';
  }

  /// Format Duration as ASS time (H:MM:SS.cc — centiseconds).
  static String _formatAssTime(Duration d) {
    final hours = d.inHours;
    final minutes = (d.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    final centiseconds = ((d.inMilliseconds % 1000) ~/ 10).toString().padLeft(
      2,
      '0',
    );
    return '$hours:$minutes:$seconds.$centiseconds';
  }

  /// Import subtitles from an SRT file.
  static Future<List<SubtitleEntry>> importSrt(String filePath) async {
    final content = await File(filePath).readAsString();
    final normalized = content.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final blocks = normalized.trim().split(RegExp(r'\n\s*\n'));
    final entries = <SubtitleEntry>[];

    for (final block in blocks) {
      final lines = block.trim().split('\n');
      if (lines.length < 3) continue;

      // Line 0: index (ignore)
      // Line 1: timestamps
      final timeParts = lines[1].split(' --> ');
      if (timeParts.length != 2) continue;

      final startTime = _parseSrtTime(timeParts[0].trim());
      final endTime = _parseSrtTime(timeParts[1].trim());
      if (startTime == null || endTime == null) continue;

      // Lines 2+: text
      final text = lines.sublist(2).join('\n').trim();

      entries.add(
        SubtitleEntry(startTime: startTime, endTime: endTime, text: text),
      );
    }

    return entries;
  }

  /// Import subtitles from a VTT file.
  static Future<List<SubtitleEntry>> importVtt(String filePath) async {
    final content = await File(filePath).readAsString();
    final normalized = content.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final blocks = normalized.trim().split(RegExp(r'\n\s*\n'));
    final entries = <SubtitleEntry>[];

    for (final block in blocks) {
      final lines = block
          .trim()
          .split('\n')
          .where((line) => line.trim().isNotEmpty)
          .toList();
      if (lines.isEmpty) continue;
      if (lines.first.trim().toUpperCase() == 'WEBVTT') continue;

      var timestampLineIndex = 0;
      if (!lines.first.contains('-->')) {
        if (lines.length < 2) continue;
        timestampLineIndex = 1;
      }

      final timeParts = lines[timestampLineIndex].split(' --> ');
      if (timeParts.length != 2) continue;

      final startTime = _parseVttTime(timeParts[0].trim());
      final endTime = _parseVttTime(timeParts[1].trim());
      if (startTime == null || endTime == null) continue;

      final textLines = lines.skip(timestampLineIndex + 1).toList();
      if (textLines.isEmpty) continue;

      entries.add(
        SubtitleEntry(
          startTime: startTime,
          endTime: endTime,
          text: textLines.join('\n').trim(),
        ),
      );
    }

    return entries;
  }

  static Duration? _parseSrtTime(String timeStr) {
    // Format: HH:MM:SS,mmm
    final match = RegExp(
      r'(\d{2}):(\d{2}):(\d{2})[,.](\d{3})',
    ).firstMatch(timeStr);
    if (match == null) return null;

    return Duration(
      hours: int.parse(match.group(1)!),
      minutes: int.parse(match.group(2)!),
      seconds: int.parse(match.group(3)!),
      milliseconds: int.parse(match.group(4)!),
    );
  }

  static Duration? _parseVttTime(String timeStr) {
    // Format: HH:MM:SS.mmm
    final match = RegExp(
      r'(\d{2}):(\d{2}):(\d{2})[,.](\d{3})',
    ).firstMatch(timeStr);
    if (match == null) return null;

    return Duration(
      hours: int.parse(match.group(1)!),
      minutes: int.parse(match.group(2)!),
      seconds: int.parse(match.group(3)!),
      milliseconds: int.parse(match.group(4)!),
    );
  }
}
