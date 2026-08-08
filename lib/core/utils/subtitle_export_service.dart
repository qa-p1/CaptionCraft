import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../theme/app_theme.dart';
import '../../features/editor/models/subtitle_entry.dart';
import '../../features/editor/models/subtitle_style_model.dart';
import '../../features/editor/models/timeline_models.dart';
import 'caption_font_service.dart';

class AssSubtitlePreflight {
  final String path;
  final int fileSize;
  final int dialogueCount;

  const AssSubtitlePreflight({
    required this.path,
    required this.fileSize,
    required this.dialogueCount,
  });
}

/// Service for generating subtitle files in SRT, VTT, and ASS formats.
class SubtitleExportService {
  SubtitleExportService._();

  /// Keeps imported cues inside the playable composition. Subtitle files can
  /// legally contain hours-long timestamps; accepting those unchanged would
  /// extend an otherwise short project and export a long blank tail.
  static List<SubtitleEntry> clampEntriesToDuration(
    Iterable<SubtitleEntry> entries,
    Duration duration,
  ) {
    if (duration <= Duration.zero) return const [];
    final bounded = <SubtitleEntry>[];
    for (final entry in entries) {
      if (entry.endTime <= Duration.zero || entry.startTime >= duration) {
        continue;
      }
      final start = entry.startTime < Duration.zero
          ? Duration.zero
          : entry.startTime;
      final end = entry.endTime > duration ? duration : entry.endTime;
      if (end <= start) continue;
      bounded.add(
        start == entry.startTime && end == entry.endTime
            ? entry
            : entry.copyWith(startTime: start, endTime: end),
      );
    }
    bounded.sort((a, b) => a.startTime.compareTo(b.startTime));
    return bounded;
  }

  /// Resolves the caption list that both preview and export should render.
  ///
  /// Timeline clips control visibility/enabled state while the richer provider
  /// entries retain word timing and per-cue styling. Legacy projects without a
  /// subtitle track continue to render their valid provider entries.
  static List<SubtitleEntry> effectiveTimelineCaptions({
    required EditorTimeline timeline,
    required List<SubtitleEntry> entries,
  }) {
    bool isValid(SubtitleEntry entry) {
      return entry.endTime > entry.startTime && entry.text.trim().isNotEmpty;
    }

    final validEntries = entries.where(isValid).toList(growable: false);
    final subtitleTracks = timeline.tracks
        .where((track) => track.type == TimelineTrackType.subtitle)
        .toList(growable: false);
    if (subtitleTracks.isEmpty) {
      return _sortedUniqueEntries(validEntries);
    }

    final visibleTracks = subtitleTracks
        .where((track) => !track.isHidden)
        .toList(growable: false);
    if (visibleTracks.isEmpty) return const [];

    final entriesById = {for (final entry in validEntries) entry.id: entry};
    final representedIds = subtitleTracks
        .expand((track) => track.clips)
        .map((clip) => clip.id)
        .toSet();
    final enabledClips = visibleTracks
        .expand((track) => track.clips)
        .where(
          (clip) =>
              clip.enabled &&
              clip.endTime > clip.startTime &&
              (clip.text ?? clip.label).trim().isNotEmpty,
        )
        .toList(growable: false);

    final resolved = <SubtitleEntry>[];
    for (final clip in enabledClips) {
      final providerEntry = entriesById[clip.id];
      if (providerEntry != null) {
        resolved.add(providerEntry);
        continue;
      }
      final fallbackEntry = clip.toSubtitleEntry();
      if (fallbackEntry != null && isValid(fallbackEntry)) {
        resolved.add(fallbackEntry);
      }
    }

    // An entry not represented by any timeline clip can occur while importing
    // or migrating an older project. Keep it visible instead of silently
    // dropping a valid caption. Explicitly disabled/hidden clips stay omitted.
    resolved.addAll(
      validEntries.where((entry) => !representedIds.contains(entry.id)),
    );
    return _sortedUniqueEntries(resolved);
  }

  static List<SubtitleEntry> _sortedUniqueEntries(
    Iterable<SubtitleEntry> entries,
  ) {
    final byId = <String, SubtitleEntry>{};
    for (final entry in entries) {
      byId.putIfAbsent(entry.id, () => entry);
    }
    final sorted = byId.values.toList()
      ..sort((a, b) {
        final timeComparison = a.startTime.compareTo(b.startTime);
        return timeComparison != 0 ? timeComparison : a.id.compareTo(b.id);
      });
    return sorted;
  }

  /// Verifies that an ASS file is present and contains renderable dialogue.
  static Future<AssSubtitlePreflight> preflightAssFile(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw StateError(
        'Caption export could not start because the subtitle file is missing.',
      );
    }
    final fileSize = await file.length();
    if (fileSize <= 0) {
      throw StateError(
        'Caption export could not start because the subtitle file is empty.',
      );
    }

    String contents;
    try {
      contents = await file.readAsString();
    } on FileSystemException catch (error) {
      throw StateError(
        'Caption export could not read the generated subtitle file: '
        '${error.message}',
      );
    }
    final dialogueCount = RegExp(
      r'^Dialogue\s*:',
      multiLine: true,
      caseSensitive: false,
    ).allMatches(contents).length;
    if (dialogueCount == 0) {
      throw StateError(
        'Caption export found no renderable dialogue in the subtitle file.',
      );
    }
    return AssSubtitlePreflight(
      path: file.path,
      fileSize: fileSize,
      dialogueCount: dialogueCount,
    );
  }

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
    final filePath = p.join(
      tempDir.path,
      'captions_${DateTime.now().microsecondsSinceEpoch}.srt',
    );
    await File(filePath).writeAsString(buffer.toString(), flush: true);
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
    final filePath = p.join(
      tempDir.path,
      'captions_${DateTime.now().microsecondsSinceEpoch}.vtt',
    );
    await File(filePath).writeAsString(buffer.toString(), flush: true);
    return filePath;
  }

  /// Generate an ASS (Advanced SubStation Alpha) file for FFmpeg subtitle burning.
  static Future<String> generateAss(
    List<SubtitleEntry> entries,
    SubtitleStyleModel globalStyle, {
    String? fileName,
    int playResX = 1920,
    int playResY = 1080,
  }) async {
    final document = buildAssDocument(
      entries,
      globalStyle,
      playResX: playResX,
      playResY: playResY,
    );
    final tempDir = await getTemporaryDirectory();
    final resolvedFileName =
        (fileName?.trim().isNotEmpty == true
                ? fileName!.trim()
                : 'captions.ass')
            .replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
    final filePath = p.join(tempDir.path, resolvedFileName);
    await File(filePath).writeAsString(document, flush: true);
    return filePath;
  }

  /// Builds an ASS document without touching the filesystem.
  ///
  /// Export planning and tests use this to verify that preview animation,
  /// positioning, colors, and background behavior survive delivery.
  static String buildAssDocument(
    List<SubtitleEntry> entries,
    SubtitleStyleModel globalStyle, {
    int playResX = 1920,
    int playResY = 1080,
  }) {
    final buffer = StringBuffer();
    final sorted = List<SubtitleEntry>.from(entries)
      ..sort((a, b) => a.startTime.compareTo(b.startTime));
    final validEntries = sorted
        .where(
          (entry) =>
              entry.endTime > entry.startTime && entry.text.trim().isNotEmpty,
        )
        .toList();
    if (validEntries.isEmpty) {
      throw Exception('No valid subtitle lines available for ASS export.');
    }

    // Script Info
    buffer.writeln('[Script Info]');
    buffer.writeln('Title: CaptionCraft Export');
    buffer.writeln('ScriptType: v4.00+');
    buffer.writeln('WrapStyle: 0');
    buffer.writeln('ScaledBorderAndShadow: yes');
    buffer.writeln('PlayResX: $playResX');
    buffer.writeln('PlayResY: $playResY');
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
    final defaultStyle = _buildAssStyle(
      'Default',
      globalStyle,
      playResX: playResX,
      playResY: playResY,
    );
    buffer.writeln(defaultStyle);
    for (var index = 0; index < validEntries.length; index++) {
      final override = validEntries[index].styleOverride;
      if (override == null) continue;
      buffer.writeln(
        _buildAssStyle(
          'Cue$index',
          override,
          playResX: playResX,
          playResY: playResY,
        ),
      );
    }
    buffer.writeln();

    // Events
    buffer.writeln('[Events]');
    buffer.writeln(
      'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text',
    );

    for (var index = 0; index < validEntries.length; index++) {
      final entry = validEntries[index];
      final start = _formatAssTime(entry.startTime);
      final end = _formatAssTime(entry.endTime);
      final style = entry.styleOverride ?? globalStyle;
      final content = style.isAllCaps ? entry.text.toUpperCase() : entry.text;
      final text = _buildAssCueText(
        entry.copyWith(text: content),
        style,
        playResX: playResX,
        playResY: playResY,
      );
      final styleName = entry.styleOverride == null ? 'Default' : 'Cue$index';

      if (style.backgroundType == SubtitleBackground.fullBar) {
        buffer.writeln(
          'Dialogue: 0,$start,$end,$styleName,,0,0,0,,'
          '${_buildFullBarDrawing(style, playResX: playResX, playResY: playResY)}',
        );
      }
      buffer.writeln('Dialogue: 1,$start,$end,$styleName,,0,0,0,,$text');
    }

    return buffer.toString();
  }

  /// Escape ASS control characters so user text is rendered literally.
  static String _escapeAssText(String text) => _escapeAssFragment(text).trim();

  static String _escapeAssFragment(String text) {
    return text
        .replaceAll('\\', r'\\')
        .replaceAll('{', r'\{')
        .replaceAll('}', r'\}')
        .replaceAll('\n', r'\N');
  }

  static String _buildAssCueText(
    SubtitleEntry entry,
    SubtitleStyleModel style, {
    required int playResX,
    required int playResY,
  }) {
    final horizontalAlignment = _assHorizontalAlignment(style.textAlignment);
    final boxCenterX =
        playResX / 2 + style.offsetX * (playResX / kTimelineDesignWidth);
    final boxHalfWidth = playResX * style.maxWidthFactor.clamp(0.25, 1.0) / 2;
    final anchorX = switch (horizontalAlignment) {
      1 => boxCenterX - boxHalfWidth,
      3 => boxCenterX + boxHalfWidth,
      _ => boxCenterX,
    };
    final x = anchorX.clamp(0, playResX).round();
    final baseY = switch (style.position) {
      SubtitlePosition.top => playResY * 0.1,
      SubtitlePosition.center => playResY * 0.5,
      SubtitlePosition.bottom => playResY * 0.9,
    };
    final y =
        (baseY +
                (style.verticalOffset + style.offsetY) *
                    (playResY / kTimelineDesignHeight))
            .clamp(0, playResY)
            .round();
    final escaped = _escapeAssText(entry.text);
    if (style.animationPreset == SubtitleAnimationPreset.wordPop) {
      final fragments = _resolveWordAnimationFragments(entry);
      if (fragments.isNotEmpty) {
        final primaryAlpha = _assAlpha(style.textColor.a);
        final secondaryAlpha = primaryAlpha;
        final outlineAlpha = '00';
        final backgroundAlpha = _assAlpha(
          style.backgroundColor.a * style.backgroundOpacity,
        );
        final pop = StringBuffer('{\\pos($x,$y)}');
        for (final fragment in fragments) {
          final startMs = fragment.startOffset.inMilliseconds;
          final endMs = (startMs + _wordPopDuration.inMilliseconds).clamp(
            startMs,
            entry.duration.inMilliseconds,
          );
          pop
            ..write(
              '{\\alpha&HFF&\\fscx60\\fscy60'
              '\\t($startMs,$endMs,'
              '\\1a&H$primaryAlpha&\\2a&H$secondaryAlpha&'
              '\\3a&H$outlineAlpha&\\4a&H$backgroundAlpha&'
              '\\fscx100\\fscy100)}',
            )
            ..write(_escapeAssFragment(fragment.text));
        }
        return pop.toString();
      }
    }
    if (style.animationPreset == SubtitleAnimationPreset.karaokeHighlight) {
      final fragments = _resolveKaraokeAnimationFragments(entry);
      if (fragments.isEmpty) {
        final durationCentiseconds = (entry.duration.inMilliseconds / 10)
            .round()
            .clamp(1, 9999);
        return '{\\pos($x,$y)\\kf$durationCentiseconds}$escaped';
      }
      final karaoke = StringBuffer('{\\pos($x,$y)}');
      var cursor = Duration.zero;
      for (final fragment in fragments) {
        final gapCentiseconds =
            ((fragment.startOffset - cursor).inMilliseconds / 10).round().clamp(
              0,
              9999,
            );
        if (gapCentiseconds > 0) {
          karaoke.write('{\\alpha&HFF&\\k$gapCentiseconds}\\h{\\alpha&H00&}');
        }
        final durationCentiseconds =
            ((fragment.endOffset - fragment.startOffset).inMilliseconds / 10)
                .round()
                .clamp(1, 9999);
        karaoke
          ..write('{\\k$durationCentiseconds}')
          ..write(_escapeAssFragment(fragment.text));
        cursor = fragment.endOffset > cursor ? fragment.endOffset : cursor;
      }
      return karaoke.toString();
    }

    if (style.animationPreset == SubtitleAnimationPreset.typewriter) {
      final characters = entry.text.runes
          .map(String.fromCharCode)
          .toList(growable: false);
      if (characters.isNotEmpty) {
        final durationCentiseconds = (entry.duration.inMilliseconds / 10)
            .round()
            .clamp(1, 9999);
        final characterDuration = (durationCentiseconds / characters.length)
            .round()
            .clamp(1, 9999);
        final typewriter = StringBuffer('{\\pos($x,$y)}');
        for (final character in characters) {
          typewriter
            ..write('{\\k$characterDuration}')
            ..write(_escapeAssFragment(character));
        }
        return typewriter.toString();
      }
    }

    final animationOverride = switch (style.animationPreset) {
      SubtitleAnimationPreset.lineFade => r'\fad(200,0)',
      _ => '',
    };
    if (style.animationPreset == SubtitleAnimationPreset.wordSlideUp) {
      final travel = (12 * (playResY / kTimelineDesignHeight)).round();
      return '{\\move($x,${y + travel},$x,$y,0,180)\\fad(180,0)}$escaped';
    }
    return '{\\pos($x,$y)$animationOverride}$escaped';
  }

  static const _wordPopDuration = Duration(milliseconds: 120);
  static const _fallbackWordStagger = Duration(milliseconds: 160);

  /// Resolves the visible caption into text-preserving word fragments.
  ///
  /// Provider word timestamps are used when every visible word has a valid
  /// timing. Edited/imported captions commonly have no word data (or stale
  /// data), so those cues use a deterministic stagger that is shared with the
  /// editor preview. Keeping all fragments inside one ASS event preserves the
  /// cue's wrapping, alignment, background, and style without duplicate text.
  static List<_AssWordAnimationFragment> _resolveWordAnimationFragments(
    SubtitleEntry entry,
  ) {
    final matches = RegExp(
      r'\S+',
    ).allMatches(entry.text).toList(growable: false);
    if (matches.isEmpty) return const [];

    final validWords = entry.words
        ?.where(
          (word) =>
              word.word.trim().isNotEmpty && word.endTime > word.startTime,
        )
        .toList(growable: false);
    final useProviderTiming = validWords?.length == matches.length;
    final durationMs = entry.duration.inMilliseconds;
    final fallbackAvailableMs = (durationMs - _wordPopDuration.inMilliseconds)
        .clamp(0, durationMs);
    final fallbackStaggerMs = matches.length <= 1
        ? 0
        : (fallbackAvailableMs ~/ (matches.length - 1)).clamp(
            0,
            _fallbackWordStagger.inMilliseconds,
          );

    return List.generate(matches.length, (index) {
      final start = index == 0 ? 0 : matches[index].start;
      final end = index + 1 < matches.length
          ? matches[index + 1].start
          : entry.text.length;
      final rawStartMs = useProviderTiming
          ? validWords![index].startTime.inMilliseconds -
                entry.startTime.inMilliseconds
          : index * fallbackStaggerMs;
      return _AssWordAnimationFragment(
        text: entry.text.substring(start, end),
        startOffset: Duration(milliseconds: rawStartMs.clamp(0, durationMs)),
      );
    }, growable: false);
  }

  static List<_AssKaraokeAnimationFragment> _resolveKaraokeAnimationFragments(
    SubtitleEntry entry,
  ) {
    final matches = RegExp(
      r'\S+',
    ).allMatches(entry.text).toList(growable: false);
    final validWords = entry.words
        ?.where(
          (word) =>
              word.word.trim().isNotEmpty && word.endTime > word.startTime,
        )
        .toList(growable: false);
    if (matches.isEmpty || validWords?.length != matches.length) {
      return const [];
    }
    final durationMs = entry.duration.inMilliseconds;
    return List.generate(matches.length, (index) {
      final start = index == 0 ? 0 : matches[index].start;
      final end = index + 1 < matches.length
          ? matches[index + 1].start
          : entry.text.length;
      final startOffsetMs =
          (validWords![index].startTime - entry.startTime).inMilliseconds;
      final endOffsetMs =
          (validWords[index].endTime - entry.startTime).inMilliseconds;
      final safeStartMs = startOffsetMs.clamp(0, durationMs).toInt();
      final safeEndMs = endOffsetMs
          .clamp(safeStartMs + 1, math.max(safeStartMs + 1, durationMs))
          .toInt();
      return _AssKaraokeAnimationFragment(
        text: entry.text.substring(start, end),
        startOffset: Duration(milliseconds: safeStartMs),
        endOffset: Duration(milliseconds: safeEndMs),
      );
    }, growable: false);
  }

  static String _buildAssStyle(
    String name,
    SubtitleStyleModel style, {
    required int playResX,
    required int playResY,
  }) {
    final fontName = CaptionFontService.resolveFamily(style.fontFamily);
    final fontSize = (style.fontSize * (playResY / kTimelineDesignHeight))
        .clamp(8, playResY * 0.24)
        .round();
    final isKaraoke =
        style.animationPreset == SubtitleAnimationPreset.karaokeHighlight;
    final isTypewriter =
        style.animationPreset == SubtitleAnimationPreset.typewriter;
    final primaryColor = _colorToAss(isKaraoke ? kAccent : style.textColor);
    final secondaryColor = _colorToAss(
      isKaraoke
          ? style.textColor.withValues(alpha: 0.4)
          : isTypewriter
          ? style.textColor.withValues(alpha: 0)
          : style.textColor,
    );
    final outlineColor = '&H00000000'; // Black outline
    final backgroundAlpha = (style.backgroundColor.a * style.backgroundOpacity)
        .clamp(0.0, 1.0);
    final backColor = _colorToAss(
      style.backgroundColor.withValues(alpha: backgroundAlpha),
    );
    final bold = style.isBold ? -1 : 0;
    final italic = style.isItalic ? -1 : 0;
    final borderStyle =
        style.backgroundType == SubtitleBackground.semiTransparentBox ? 3 : 1;
    final outline = switch (style.backgroundType) {
      SubtitleBackground.outlineShadow => 3,
      SubtitleBackground.semiTransparentBox => 6,
      _ => 0,
    };
    final shadow = style.backgroundType == SubtitleBackground.outlineShadow
        ? 2
        : 0;

    // ASS uses numpad alignment: 1/2/3 bottom, 4/5/6 middle,
    // and 7/8/9 top. The matching horizontal anchor is positioned at the
    // left edge, center, or right edge of the same centered max-width box that
    // the editor preview lays out.
    final horizontalAlignment = _assHorizontalAlignment(style.textAlignment);
    final alignment = switch (style.position) {
      SubtitlePosition.top => horizontalAlignment + 6,
      SubtitlePosition.center => horizontalAlignment + 3,
      SubtitlePosition.bottom => horizontalAlignment,
    };

    final horizontalMargin =
        ((1 - style.maxWidthFactor.clamp(0.25, 1.0)) * playResX / 2)
            .round()
            .clamp(10, playResX ~/ 2);
    final verticalMargin = (playResY * 0.05).round().clamp(10, playResY ~/ 3);

    return 'Style: $name,$fontName,$fontSize,$primaryColor,$secondaryColor,'
        '$outlineColor,$backColor,$bold,$italic,0,0,100,100,0,0,'
        '$borderStyle,$outline,$shadow,$alignment,$horizontalMargin,'
        '$horizontalMargin,$verticalMargin,1';
  }

  static int _assHorizontalAlignment(TextAlign textAlignment) {
    switch (textAlignment) {
      case TextAlign.left:
      case TextAlign.start:
        return 1;
      case TextAlign.right:
      case TextAlign.end:
        return 3;
      case TextAlign.center:
      case TextAlign.justify:
        return 2;
    }
  }

  static String _buildFullBarDrawing(
    SubtitleStyleModel style, {
    required int playResX,
    required int playResY,
  }) {
    final baseY = switch (style.position) {
      SubtitlePosition.top => playResY * 0.1,
      SubtitlePosition.center => playResY * 0.5,
      SubtitlePosition.bottom => playResY * 0.9,
    };
    final y =
        (baseY +
                (style.verticalOffset + style.offsetY) *
                    (playResY / kTimelineDesignHeight))
            .clamp(0, playResY)
            .round();
    final scaledFontSize = style.fontSize * (playResY / kTimelineDesignHeight);
    final barHeight = (scaledFontSize + 16 * (playResY / kTimelineDesignHeight))
        .round()
        .clamp(18, playResY);
    final top = (y - barHeight / 2).round().clamp(0, playResY);
    final bottom = (top + barHeight).clamp(0, playResY);
    final effectiveAlpha = (style.backgroundColor.a * style.backgroundOpacity)
        .clamp(0.0, 1.0);
    final alphaHex = (255 - (effectiveAlpha * 255).round())
        .clamp(0, 255)
        .toRadixString(16)
        .padLeft(2, '0')
        .toUpperCase();
    final colorHex = _colorToAss(
      style.backgroundColor.withValues(alpha: 1),
    ).substring(4);

    return '{\\an7\\pos(0,0)\\p1\\bord0\\shad0'
        '\\1c&H$colorHex&\\1a&H$alphaHex&}'
        'm 0 $top l $playResX $top l $playResX $bottom l 0 $bottom';
  }

  /// Convert a Flutter Color to ASS color format (&HAABBGGRR).
  static String _colorToAss(Color color) {
    final alpha = (color.a * 255.0).round().clamp(0, 255);
    final blue = (color.b * 255.0).round().clamp(0, 255);
    final green = (color.g * 255.0).round().clamp(0, 255);
    final red = (color.r * 255.0).round().clamp(0, 255);
    final a = (255 - alpha).toRadixString(16).padLeft(2, '0').toUpperCase();
    final b = blue.toRadixString(16).padLeft(2, '0').toUpperCase();
    final g = green.toRadixString(16).padLeft(2, '0').toUpperCase();
    final r = red.toRadixString(16).padLeft(2, '0').toUpperCase();
    return '&H$a$b$g$r';
  }

  static String _assAlpha(double opacity) {
    return (255 - (opacity.clamp(0.0, 1.0) * 255).round())
        .clamp(0, 255)
        .toRadixString(16)
        .padLeft(2, '0')
        .toUpperCase();
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
    final normalized = content
        .replaceFirst('\uFEFF', '')
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');
    final blocks = normalized.trim().split(RegExp(r'\n\s*\n'));
    final entries = <SubtitleEntry>[];

    for (final block in blocks) {
      final lines = block.trim().split('\n');
      final timestampLineIndex = lines.indexWhere(
        (line) => line.contains('-->'),
      );
      if (timestampLineIndex < 0) continue;
      final timeParts = lines[timestampLineIndex].split(RegExp(r'\s*-->\s*'));
      if (timeParts.length != 2) continue;

      final startTime = _parseSrtTime(timeParts[0].trim());
      final endTime = _parseSrtTime(timeParts[1].trim());
      if (startTime == null || endTime == null) continue;

      final text = lines.skip(timestampLineIndex + 1).join('\n').trim();
      if (text.isEmpty || endTime <= startTime) continue;

      entries.add(
        SubtitleEntry(startTime: startTime, endTime: endTime, text: text),
      );
    }

    return entries;
  }

  /// Import subtitles from a VTT file.
  static Future<List<SubtitleEntry>> importVtt(String filePath) async {
    final content = await File(filePath).readAsString();
    final normalized = content
        .replaceFirst('\uFEFF', '')
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');
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
      if (lines.first.trim().startsWith('NOTE') ||
          lines.first.trim() == 'STYLE' ||
          lines.first.trim() == 'REGION') {
        continue;
      }

      var timestampLineIndex = 0;
      if (!lines.first.contains('-->')) {
        if (lines.length < 2) continue;
        timestampLineIndex = 1;
      }

      final timeParts = lines[timestampLineIndex].split(RegExp(r'\s*-->\s*'));
      if (timeParts.length != 2) continue;

      final startTime = _parseVttTime(timeParts[0].trim());
      final endToken = timeParts[1].trim().split(RegExp(r'\s+')).first;
      final endTime = _parseVttTime(endToken);
      if (startTime == null || endTime == null) continue;

      final textLines = lines.skip(timestampLineIndex + 1).toList();
      if (textLines.isEmpty || endTime <= startTime) continue;

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
      r'(\d{1,2}):(\d{2}):(\d{2})[,.](\d{1,3})',
    ).firstMatch(timeStr);
    if (match == null) return null;
    final fraction = match.group(4)!.padRight(3, '0').substring(0, 3);

    return Duration(
      hours: int.parse(match.group(1)!),
      minutes: int.parse(match.group(2)!),
      seconds: int.parse(match.group(3)!),
      milliseconds: int.parse(fraction),
    );
  }

  static Duration? _parseVttTime(String timeStr) {
    // Formats: HH:MM:SS.mmm or MM:SS.mmm
    final parts = timeStr.replaceAll(',', '.').split(':');
    if (parts.length != 2 && parts.length != 3) return null;
    final secondParts = parts.last.split('.');
    if (secondParts.length != 2) return null;
    final fraction = secondParts[1].padRight(3, '0').substring(0, 3);
    final seconds = int.tryParse(secondParts[0]);
    final minutes = int.tryParse(parts[parts.length - 2]);
    final hours = parts.length == 3 ? int.tryParse(parts[0]) : 0;
    if (seconds == null || minutes == null || hours == null) return null;
    return Duration(
      hours: hours,
      minutes: minutes,
      seconds: seconds,
      milliseconds: int.tryParse(fraction) ?? 0,
    );
  }
}

class _AssWordAnimationFragment {
  final String text;
  final Duration startOffset;

  const _AssWordAnimationFragment({
    required this.text,
    required this.startOffset,
  });
}

class _AssKaraokeAnimationFragment {
  final String text;
  final Duration startOffset;
  final Duration endOffset;

  const _AssKaraokeAnimationFragment({
    required this.text,
    required this.startOffset,
    required this.endOffset,
  });
}
