import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import 'subtitle_entry.dart';
import 'subtitle_style_model.dart';

enum TimelineTrackType { video, audio, subtitle, text, image, sticker, gif }

enum TimelineTrackSection { overlay, baseVideo, textSubtitle, audio }

enum EditorAssetType { video, audio, image, gif, sticker, unknown }

enum ClipFitMode { cover, contain, stretch }

enum CanvasAspectRatioPreset {
  original,
  ratio16x9,
  ratio9x16,
  ratio1x1,
  ratio4x5,
}

enum TransitionType { none, cut, fade, dissolve, slideLeft, slideRight, zoom }

class TimelineTransform {
  final double offsetX;
  final double offsetY;
  final double scale;
  final double rotation;
  final double opacity;
  final bool flipX;
  final bool flipY;

  const TimelineTransform({
    this.offsetX = 0,
    this.offsetY = 0,
    this.scale = 1,
    this.rotation = 0,
    this.opacity = 1,
    this.flipX = false,
    this.flipY = false,
  });

  TimelineTransform copyWith({
    double? offsetX,
    double? offsetY,
    double? scale,
    double? rotation,
    double? opacity,
    bool? flipX,
    bool? flipY,
  }) {
    return TimelineTransform(
      offsetX: offsetX ?? this.offsetX,
      offsetY: offsetY ?? this.offsetY,
      scale: scale ?? this.scale,
      rotation: rotation ?? this.rotation,
      opacity: opacity ?? this.opacity,
      flipX: flipX ?? this.flipX,
      flipY: flipY ?? this.flipY,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'offsetX': offsetX,
      'offsetY': offsetY,
      'scale': scale,
      'rotation': rotation,
      'opacity': opacity,
      'flipX': flipX,
      'flipY': flipY,
    };
  }

  factory TimelineTransform.fromJson(Map<String, dynamic> json) {
    return TimelineTransform(
      offsetX: (json['offsetX'] as num?)?.toDouble() ?? 0,
      offsetY: (json['offsetY'] as num?)?.toDouble() ?? 0,
      scale: (json['scale'] as num?)?.toDouble() ?? 1,
      rotation: (json['rotation'] as num?)?.toDouble() ?? 0,
      opacity: (json['opacity'] as num?)?.toDouble() ?? 1,
      flipX: json['flipX'] as bool? ?? false,
      flipY: json['flipY'] as bool? ?? false,
    );
  }
}

class AudioMixSettings {
  final double volume;
  final bool muted;
  final int fadeInMs;
  final int fadeOutMs;

  const AudioMixSettings({
    this.volume = 1,
    this.muted = false,
    this.fadeInMs = 0,
    this.fadeOutMs = 0,
  });

  AudioMixSettings copyWith({
    double? volume,
    bool? muted,
    int? fadeInMs,
    int? fadeOutMs,
  }) {
    return AudioMixSettings(
      volume: volume ?? this.volume,
      muted: muted ?? this.muted,
      fadeInMs: fadeInMs ?? this.fadeInMs,
      fadeOutMs: fadeOutMs ?? this.fadeOutMs,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'volume': volume,
      'muted': muted,
      'fadeInMs': fadeInMs,
      'fadeOutMs': fadeOutMs,
    };
  }

  factory AudioMixSettings.fromJson(Map<String, dynamic> json) {
    return AudioMixSettings(
      volume: (json['volume'] as num?)?.toDouble() ?? 1,
      muted: json['muted'] as bool? ?? false,
      fadeInMs: (json['fadeInMs'] as num?)?.toInt() ?? 0,
      fadeOutMs: (json['fadeOutMs'] as num?)?.toInt() ?? 0,
    );
  }
}

class ClipTransition {
  final TransitionType type;
  final int durationMs;

  const ClipTransition({this.type = TransitionType.none, this.durationMs = 0});

  ClipTransition copyWith({TransitionType? type, int? durationMs}) {
    return ClipTransition(
      type: type ?? this.type,
      durationMs: durationMs ?? this.durationMs,
    );
  }

  Map<String, dynamic> toJson() {
    return {'type': type.name, 'durationMs': durationMs};
  }

  factory ClipTransition.fromJson(Map<String, dynamic> json) {
    return ClipTransition(
      type: TransitionType.values.firstWhere(
        (value) => value.name == json['type'],
        orElse: () => TransitionType.none,
      ),
      durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
    );
  }
}

class EditorAssetReference {
  final String id;
  final EditorAssetType type;
  final String label;
  final String? sourcePath;
  final String? remoteUrl;
  final bool isNetworkBacked;
  final Map<String, dynamic> metadata;

  EditorAssetReference({
    String? id,
    required this.type,
    required this.label,
    this.sourcePath,
    this.remoteUrl,
    this.isNetworkBacked = false,
    Map<String, dynamic>? metadata,
  }) : id = id ?? const Uuid().v4(),
       metadata = metadata ?? const {};

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'type': type.name,
      'label': label,
      'sourcePath': sourcePath,
      'remoteUrl': remoteUrl,
      'isNetworkBacked': isNetworkBacked,
      'metadata': metadata,
    };
  }

  factory EditorAssetReference.fromJson(Map<String, dynamic> json) {
    return EditorAssetReference(
      id: json['id'] as String?,
      type: EditorAssetType.values.firstWhere(
        (value) => value.name == json['type'],
        orElse: () => EditorAssetType.unknown,
      ),
      label: json['label'] as String? ?? 'Untitled asset',
      sourcePath: json['sourcePath'] as String?,
      remoteUrl: json['remoteUrl'] as String?,
      isNetworkBacked: json['isNetworkBacked'] as bool? ?? false,
      metadata: (json['metadata'] as Map<String, dynamic>?) ?? const {},
    );
  }
}

class TimelineClip {
  final String id;
  final String trackId;
  final TimelineTrackType type;
  final String label;
  final String? assetId;
  final String? linkedClipId;
  final Duration startTime;
  final Duration endTime;
  final Duration sourceStartTime;
  final Duration sourceDuration;
  final int layer;
  final bool enabled;
  final TimelineTransform transform;
  final AudioMixSettings audioMix;
  final ClipFitMode fitMode;
  final String? text;
  final SubtitleStyleModel? subtitleStyle;
  final ClipTransition introTransition;
  final ClipTransition outroTransition;

  TimelineClip({
    String? id,
    required this.trackId,
    required this.type,
    required this.label,
    required this.startTime,
    required this.endTime,
    this.assetId,
    this.linkedClipId,
    Duration? sourceStartTime,
    Duration? sourceDuration,
    this.layer = 0,
    this.enabled = true,
    this.transform = const TimelineTransform(),
    this.audioMix = const AudioMixSettings(),
    this.fitMode = ClipFitMode.cover,
    this.text,
    this.subtitleStyle,
    this.introTransition = const ClipTransition(),
    this.outroTransition = const ClipTransition(),
  }) : id = id ?? const Uuid().v4(),
       sourceStartTime = sourceStartTime ?? Duration.zero,
       sourceDuration = sourceDuration ?? (endTime - startTime);

  Duration get duration => endTime - startTime;

  TimelineClip copyWith({
    String? id,
    String? trackId,
    TimelineTrackType? type,
    String? label,
    String? assetId,
    String? linkedClipId,
    Duration? startTime,
    Duration? endTime,
    Duration? sourceStartTime,
    Duration? sourceDuration,
    int? layer,
    bool? enabled,
    TimelineTransform? transform,
    AudioMixSettings? audioMix,
    ClipFitMode? fitMode,
    String? text,
    SubtitleStyleModel? subtitleStyle,
    bool clearSubtitleStyle = false,
    ClipTransition? introTransition,
    ClipTransition? outroTransition,
  }) {
    return TimelineClip(
      id: id ?? this.id,
      trackId: trackId ?? this.trackId,
      type: type ?? this.type,
      label: label ?? this.label,
      assetId: assetId ?? this.assetId,
      linkedClipId: linkedClipId ?? this.linkedClipId,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      sourceStartTime: sourceStartTime ?? this.sourceStartTime,
      sourceDuration: sourceDuration ?? this.sourceDuration,
      layer: layer ?? this.layer,
      enabled: enabled ?? this.enabled,
      transform: transform ?? this.transform,
      audioMix: audioMix ?? this.audioMix,
      fitMode: fitMode ?? this.fitMode,
      text: text ?? this.text,
      subtitleStyle: clearSubtitleStyle
          ? null
          : (subtitleStyle ?? this.subtitleStyle),
      introTransition: introTransition ?? this.introTransition,
      outroTransition: outroTransition ?? this.outroTransition,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'trackId': trackId,
      'type': type.name,
      'label': label,
      'assetId': assetId,
      'linkedClipId': linkedClipId,
      'startTimeMs': startTime.inMilliseconds,
      'endTimeMs': endTime.inMilliseconds,
      'sourceStartTimeMs': sourceStartTime.inMilliseconds,
      'sourceDurationMs': sourceDuration.inMilliseconds,
      'layer': layer,
      'enabled': enabled,
      'transform': transform.toJson(),
      'audioMix': audioMix.toJson(),
      'fitMode': fitMode.name,
      'text': text,
      'subtitleStyle': subtitleStyle?.toJson(),
      'introTransition': introTransition.toJson(),
      'outroTransition': outroTransition.toJson(),
    };
  }

  factory TimelineClip.fromJson(Map<String, dynamic> json) {
    return TimelineClip(
      id: json['id'] as String?,
      trackId: json['trackId'] as String? ?? '',
      type: TimelineTrackType.values.firstWhere(
        (value) => value.name == json['type'],
        orElse: () => TimelineTrackType.subtitle,
      ),
      label: json['label'] as String? ?? 'Untitled clip',
      assetId: json['assetId'] as String?,
      linkedClipId: json['linkedClipId'] as String?,
      startTime: Duration(
        milliseconds: (json['startTimeMs'] as num?)?.toInt() ?? 0,
      ),
      endTime: Duration(
        milliseconds: (json['endTimeMs'] as num?)?.toInt() ?? 0,
      ),
      sourceStartTime: Duration(
        milliseconds: (json['sourceStartTimeMs'] as num?)?.toInt() ?? 0,
      ),
      sourceDuration: Duration(
        milliseconds: (json['sourceDurationMs'] as num?)?.toInt() ?? 0,
      ),
      layer: (json['layer'] as num?)?.toInt() ?? 0,
      enabled: json['enabled'] as bool? ?? true,
      transform: json['transform'] is Map<String, dynamic>
          ? TimelineTransform.fromJson(
              json['transform'] as Map<String, dynamic>,
            )
          : const TimelineTransform(),
      audioMix: json['audioMix'] is Map<String, dynamic>
          ? AudioMixSettings.fromJson(json['audioMix'] as Map<String, dynamic>)
          : const AudioMixSettings(),
      fitMode: ClipFitMode.values.firstWhere(
        (value) => value.name == json['fitMode'],
        orElse: () => ClipFitMode.cover,
      ),
      text: json['text'] as String?,
      subtitleStyle: json['subtitleStyle'] is Map<String, dynamic>
          ? SubtitleStyleModel.fromJson(
              json['subtitleStyle'] as Map<String, dynamic>,
            )
          : null,
      introTransition: json['introTransition'] is Map<String, dynamic>
          ? ClipTransition.fromJson(
              json['introTransition'] as Map<String, dynamic>,
            )
          : const ClipTransition(),
      outroTransition: json['outroTransition'] is Map<String, dynamic>
          ? ClipTransition.fromJson(
              json['outroTransition'] as Map<String, dynamic>,
            )
          : const ClipTransition(),
    );
  }

  factory TimelineClip.fromSubtitleEntry(
    SubtitleEntry entry, {
    required String trackId,
    String? linkedClipId,
  }) {
    return TimelineClip(
      id: entry.id,
      trackId: trackId,
      type: TimelineTrackType.subtitle,
      label: entry.text,
      linkedClipId: linkedClipId,
      startTime: entry.startTime,
      endTime: entry.endTime,
      text: entry.text,
      subtitleStyle: entry.styleOverride,
    );
  }

  SubtitleEntry? toSubtitleEntry() {
    if (type != TimelineTrackType.subtitle) return null;
    return SubtitleEntry(
      id: id,
      startTime: startTime,
      endTime: endTime,
      text: text ?? label,
      styleOverride: subtitleStyle,
    );
  }
}

class TimelineTrack {
  final String id;
  final String name;
  final TimelineTrackType type;
  final TimelineTrackSection section;
  final bool isCollapsed;
  final bool isLocked;
  final bool isMuted;
  final bool isHidden;
  final List<TimelineClip> clips;

  TimelineTrack({
    String? id,
    required this.name,
    required this.type,
    TimelineTrackSection? section,
    this.isCollapsed = false,
    this.isLocked = false,
    this.isMuted = false,
    this.isHidden = false,
    List<TimelineClip>? clips,
  }) : id = id ?? const Uuid().v4(),
       section = section ?? _defaultSectionForType(type),
       clips = clips ?? const [];

  TimelineTrack copyWith({
    String? id,
    String? name,
    TimelineTrackType? type,
    TimelineTrackSection? section,
    bool? isCollapsed,
    bool? isLocked,
    bool? isMuted,
    bool? isHidden,
    List<TimelineClip>? clips,
  }) {
    return TimelineTrack(
      id: id ?? this.id,
      name: name ?? this.name,
      type: type ?? this.type,
      section: section ?? this.section,
      isCollapsed: isCollapsed ?? this.isCollapsed,
      isLocked: isLocked ?? this.isLocked,
      isMuted: isMuted ?? this.isMuted,
      isHidden: isHidden ?? this.isHidden,
      clips: clips ?? this.clips,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'type': type.name,
      'section': section.name,
      'isCollapsed': isCollapsed,
      'isLocked': isLocked,
      'isMuted': isMuted,
      'isHidden': isHidden,
      'clips': clips.map((clip) => clip.toJson()).toList(),
    };
  }

  factory TimelineTrack.fromJson(Map<String, dynamic> json) {
    return TimelineTrack(
      id: json['id'] as String?,
      name: json['name'] as String? ?? 'Untitled track',
      type: _trackTypeFromJson(json['type']),
      section: TimelineTrackSection.values.firstWhere(
        (value) => value.name == json['section'],
        orElse: () => _defaultSectionForType(_trackTypeFromJson(json['type'])),
      ),
      isCollapsed: json['isCollapsed'] as bool? ?? false,
      isLocked: json['isLocked'] as bool? ?? false,
      isMuted: json['isMuted'] as bool? ?? false,
      isHidden: json['isHidden'] as bool? ?? false,
      clips:
          (json['clips'] as List<dynamic>?)
              ?.map(
                (clip) => TimelineClip.fromJson(clip as Map<String, dynamic>),
              )
              .toList() ??
          const [],
    );
  }
}

class CanvasSettings {
  final CanvasAspectRatioPreset aspectRatioPreset;
  final int? customWidth;
  final int? customHeight;
  final Color backgroundColor;
  final bool showSafeAreas;
  final bool snapToGuides;

  const CanvasSettings({
    this.aspectRatioPreset = CanvasAspectRatioPreset.original,
    this.customWidth,
    this.customHeight,
    this.backgroundColor = Colors.black,
    this.showSafeAreas = true,
    this.snapToGuides = true,
  });

  CanvasSettings copyWith({
    CanvasAspectRatioPreset? aspectRatioPreset,
    int? customWidth,
    int? customHeight,
    Color? backgroundColor,
    bool? showSafeAreas,
    bool? snapToGuides,
  }) {
    return CanvasSettings(
      aspectRatioPreset: aspectRatioPreset ?? this.aspectRatioPreset,
      customWidth: customWidth ?? this.customWidth,
      customHeight: customHeight ?? this.customHeight,
      backgroundColor: backgroundColor ?? this.backgroundColor,
      showSafeAreas: showSafeAreas ?? this.showSafeAreas,
      snapToGuides: snapToGuides ?? this.snapToGuides,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'aspectRatioPreset': aspectRatioPreset.name,
      'customWidth': customWidth,
      'customHeight': customHeight,
      'backgroundColor': _colorToInt(backgroundColor),
      'showSafeAreas': showSafeAreas,
      'snapToGuides': snapToGuides,
    };
  }

  factory CanvasSettings.fromJson(Map<String, dynamic> json) {
    return CanvasSettings(
      aspectRatioPreset: CanvasAspectRatioPreset.values.firstWhere(
        (value) => value.name == json['aspectRatioPreset'],
        orElse: () => CanvasAspectRatioPreset.original,
      ),
      customWidth: (json['customWidth'] as num?)?.toInt(),
      customHeight: (json['customHeight'] as num?)?.toInt(),
      backgroundColor: Color(json['backgroundColor'] as int? ?? 0xFF000000),
      showSafeAreas: json['showSafeAreas'] as bool? ?? true,
      snapToGuides: json['snapToGuides'] as bool? ?? true,
    );
  }
}

class EditorTimeline {
  final int schemaVersion;
  final CanvasSettings canvasSettings;
  final SubtitleStyleModel subtitleStyle;
  final List<EditorAssetReference> assets;
  final List<TimelineTrack> tracks;

  const EditorTimeline({
    this.schemaVersion = 2,
    this.canvasSettings = const CanvasSettings(),
    this.subtitleStyle = const SubtitleStyleModel(),
    this.assets = const [],
    this.tracks = const [],
  });

  TimelineTrack? get primarySubtitleTrack {
    for (final track in tracks) {
      if (track.type == TimelineTrackType.subtitle) {
        return track;
      }
    }
    return null;
  }

  List<TimelineTrack> tracksForSection(TimelineTrackSection section) {
    return tracks.where((track) => track.section == section).toList();
  }

  String nextTrackNameForSection(TimelineTrackSection section) {
    final sectionTracks = tracksForSection(section);
    switch (section) {
      case TimelineTrackSection.overlay:
        return 'Overlay ${sectionTracks.length + 1}';
      case TimelineTrackSection.baseVideo:
        return 'Video ${sectionTracks.length + 1}';
      case TimelineTrackSection.textSubtitle:
        final textTracks = sectionTracks
            .where((track) => track.type == TimelineTrackType.text)
            .length;
        return 'Text ${textTracks + 1}';
      case TimelineTrackSection.audio:
        return 'Audio ${sectionTracks.length + 1}';
    }
  }

  List<SubtitleEntry> get subtitleEntries {
    final track = primarySubtitleTrack;
    if (track == null) return const [];
    return track.clips
        .map((clip) => clip.toSubtitleEntry())
        .whereType<SubtitleEntry>()
        .toList()
      ..sort((a, b) => a.startTime.compareTo(b.startTime));
  }

  List<TimelineClip> get videoClips {
    return tracks
        .where((track) => track.type == TimelineTrackType.video)
        .expand((track) => track.clips)
        .toList()
      ..sort((a, b) => a.startTime.compareTo(b.startTime));
  }

  List<TimelineClip> subtitleClipsForLinkedClip(String clipId) {
    return tracks
        .where((track) => track.type == TimelineTrackType.subtitle)
        .expand((track) => track.clips)
        .where((clip) => clip.linkedClipId == clipId)
        .toList()
      ..sort((a, b) => a.startTime.compareTo(b.startTime));
  }

  EditorTimeline copyWith({
    int? schemaVersion,
    CanvasSettings? canvasSettings,
    SubtitleStyleModel? subtitleStyle,
    List<EditorAssetReference>? assets,
    List<TimelineTrack>? tracks,
  }) {
    return EditorTimeline(
      schemaVersion: schemaVersion ?? this.schemaVersion,
      canvasSettings: canvasSettings ?? this.canvasSettings,
      subtitleStyle: subtitleStyle ?? this.subtitleStyle,
      assets: assets ?? this.assets,
      tracks: tracks ?? this.tracks,
    );
  }

  EditorTimeline syncLegacySubtitles({
    required List<SubtitleEntry> subtitles,
    required SubtitleStyleModel globalStyle,
    required String videoPath,
    required int durationMs,
  }) {
    final subtitleTrackId = primarySubtitleTrack?.id ?? 'track_subtitles';
    final subtitleTrack = TimelineTrack(
      id: subtitleTrackId,
      name: 'Subtitles',
      type: TimelineTrackType.subtitle,
      section: TimelineTrackSection.textSubtitle,
      clips: subtitles
          .map(
            (entry) =>
                TimelineClip.fromSubtitleEntry(entry, trackId: subtitleTrackId),
          )
          .toList(),
    );

    final nextTracks = <TimelineTrack>[
      ...tracks.where((track) => track.type != TimelineTrackType.subtitle),
      subtitleTrack,
    ];

    final hasSourceVideoAsset = assets.any(
      (asset) =>
          asset.type == EditorAssetType.video && asset.sourcePath == videoPath,
    );
    final nextAssets = hasSourceVideoAsset
        ? assets
        : [
            EditorAssetReference(
              type: EditorAssetType.video,
              label: 'Source video',
              sourcePath: videoPath,
              metadata: {'durationMs': durationMs},
            ),
            ...assets,
          ];

    final hasVideoTrack = nextTracks.any(
      (track) => track.type == TimelineTrackType.video,
    );
    final completeTracks = hasVideoTrack
        ? nextTracks
        : [
            TimelineTrack(
              id: 'track_overlay_primary',
              name: 'Overlay 1',
              type: TimelineTrackType.video,
              section: TimelineTrackSection.overlay,
              clips: const [],
            ),
            TimelineTrack(
              id: 'track_video_primary',
              name: 'Video 1',
              type: TimelineTrackType.video,
              section: TimelineTrackSection.baseVideo,
              clips: [
                TimelineClip(
                  trackId: 'track_video_primary',
                  type: TimelineTrackType.video,
                  label: 'Source video',
                  startTime: Duration.zero,
                  endTime: Duration(milliseconds: durationMs),
                ),
              ],
            ),
            TimelineTrack(
              id: 'track_text_primary',
              name: 'Text 1',
              type: TimelineTrackType.text,
              section: TimelineTrackSection.textSubtitle,
              clips: const [],
            ),
            ...nextTracks,
            TimelineTrack(
              id: 'track_audio_primary',
              name: 'Audio 1',
              type: TimelineTrackType.audio,
              section: TimelineTrackSection.audio,
              clips: const [],
            ),
          ];

    return copyWith(
      subtitleStyle: globalStyle,
      assets: nextAssets,
      tracks: completeTracks,
    );
  }

  EditorTimeline mergeSubtitleEntries({
    required List<SubtitleEntry> subtitles,
    required SubtitleStyleModel globalStyle,
  }) {
    final subtitleTrackId = primarySubtitleTrack?.id ?? 'track_subtitles';
    final existingSubtitleClips = tracks
        .where((track) => track.type == TimelineTrackType.subtitle)
        .expand((track) => track.clips)
        .fold<Map<String, TimelineClip>>({}, (map, clip) {
          map[clip.id] = clip;
          return map;
        });

    final mergedTrack = TimelineTrack(
      id: subtitleTrackId,
      name: primarySubtitleTrack?.name ?? 'Subtitles',
      type: TimelineTrackType.subtitle,
      section: TimelineTrackSection.textSubtitle,
      clips: subtitles.map((entry) {
        final existing = existingSubtitleClips[entry.id];
        if (existing == null) {
          return TimelineClip.fromSubtitleEntry(
            entry,
            trackId: subtitleTrackId,
          );
        }
        return existing.copyWith(
          label: entry.text,
          startTime: entry.startTime,
          endTime: entry.endTime,
          text: entry.text,
          subtitleStyle: entry.styleOverride,
        );
      }).toList(),
    );

    return copyWith(
      subtitleStyle: globalStyle,
      tracks: [
        ...tracks.where((track) => track.type != TimelineTrackType.subtitle),
        mergedTrack,
      ],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'schemaVersion': schemaVersion,
      'canvasSettings': canvasSettings.toJson(),
      'subtitleStyle': subtitleStyle.toJson(),
      'assets': assets.map((asset) => asset.toJson()).toList(),
      'tracks': tracks.map((track) => track.toJson()).toList(),
    };
  }

  factory EditorTimeline.fromJson(Map<String, dynamic> json) {
    return EditorTimeline(
      schemaVersion: (json['schemaVersion'] as num?)?.toInt() ?? 2,
      canvasSettings: json['canvasSettings'] is Map<String, dynamic>
          ? CanvasSettings.fromJson(
              json['canvasSettings'] as Map<String, dynamic>,
            )
          : const CanvasSettings(),
      subtitleStyle: json['subtitleStyle'] is Map<String, dynamic>
          ? SubtitleStyleModel.fromJson(
              json['subtitleStyle'] as Map<String, dynamic>,
            )
          : const SubtitleStyleModel(),
      assets:
          (json['assets'] as List<dynamic>?)
              ?.map(
                (asset) => EditorAssetReference.fromJson(
                  asset as Map<String, dynamic>,
                ),
              )
              .toList() ??
          const [],
      tracks:
          (json['tracks'] as List<dynamic>?)
              ?.map(
                (track) =>
                    TimelineTrack.fromJson(track as Map<String, dynamic>),
              )
              .toList() ??
          const [],
    );
  }

  factory EditorTimeline.fromLegacy({
    required List<SubtitleEntry> subtitles,
    required SubtitleStyleModel globalStyle,
    required String videoPath,
    required int durationMs,
  }) {
    return const EditorTimeline().syncLegacySubtitles(
      subtitles: subtitles,
      globalStyle: globalStyle,
      videoPath: videoPath,
      durationMs: durationMs,
    );
  }
}

TimelineTrackType _trackTypeFromJson(dynamic value) {
  return TimelineTrackType.values.firstWhere(
    (candidate) => candidate.name == value,
    orElse: () => TimelineTrackType.subtitle,
  );
}

TimelineTrackSection _defaultSectionForType(TimelineTrackType type) {
  switch (type) {
    case TimelineTrackType.audio:
      return TimelineTrackSection.audio;
    case TimelineTrackType.subtitle:
    case TimelineTrackType.text:
      return TimelineTrackSection.textSubtitle;
    case TimelineTrackType.video:
      return TimelineTrackSection.baseVideo;
    case TimelineTrackType.image:
    case TimelineTrackType.sticker:
    case TimelineTrackType.gif:
      return TimelineTrackSection.overlay;
  }
}

int _colorToInt(Color color) {
  final a = (color.a * 255.0).round().clamp(0, 255);
  final r = (color.r * 255.0).round().clamp(0, 255);
  final g = (color.g * 255.0).round().clamp(0, 255);
  final b = (color.b * 255.0).round().clamp(0, 255);
  return (a << 24) | (r << 16) | (g << 8) | b;
}
