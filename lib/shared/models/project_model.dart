import 'dart:convert';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../../features/editor/models/subtitle_entry.dart';
import '../../features/editor/models/subtitle_style_model.dart';
import '../../features/editor/models/timeline_models.dart';

/// Project data model — represents a subtitling project.
class Project {
  final String id;
  final String name;
  final String videoPath;
  final String? thumbnailBase64;
  final int durationMs;
  final List<SubtitleEntry> subtitles;
  SubtitleStyleModel globalStyle;
  final EditorTimeline timeline;
  final DateTime createdAt;
  DateTime lastModifiedAt;

  Project({
    required this.id,
    required this.name,
    required this.videoPath,
    this.thumbnailBase64,
    required this.durationMs,
    this.subtitles = const [],
    this.globalStyle = const SubtitleStyleModel(),
    EditorTimeline? timeline,
    DateTime? createdAt,
    DateTime? lastModifiedAt,
  }) : timeline =
           timeline ??
           EditorTimeline.fromLegacy(
             subtitles: subtitles,
             globalStyle: globalStyle,
             videoPath: videoPath,
             durationMs: durationMs,
           ),
       createdAt = createdAt ?? DateTime.now(),
       lastModifiedAt = lastModifiedAt ?? DateTime.now();

  /// Whether the source video file still exists on device.
  bool get isVideoAvailable => File(videoPath).existsSync();

  Duration get duration => Duration(milliseconds: durationMs);

  Map<String, dynamic> toFirestore() {
    return {
      'id': id,
      'name': name,
      'videoPath': videoPath,
      'thumbnailBase64': thumbnailBase64,
      'durationMs': durationMs,
      'subtitles': subtitles.map((e) => e.toJson()).toList(),
      'globalStyle': globalStyle.toJson(),
      'timeline': timeline.toJson(),
      'createdAt': Timestamp.fromDate(createdAt),
      'lastModifiedAt': Timestamp.fromDate(lastModifiedAt),
    };
  }

  factory Project.fromFirestore(Map<String, dynamic> data) {
    final legacySubtitles =
        (data['subtitles'] as List<dynamic>?)
            ?.map((e) => SubtitleEntry.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [];
    final legacyStyle = data['globalStyle'] != null
        ? SubtitleStyleModel.fromJson(
            data['globalStyle'] as Map<String, dynamic>,
          )
        : const SubtitleStyleModel();
    final videoPath = data['videoPath'] as String? ?? '';
    final durationMs = (data['durationMs'] as num?)?.toInt() ?? 0;
    final timeline = data['timeline'] is Map<String, dynamic>
        ? EditorTimeline.fromJson(data['timeline'] as Map<String, dynamic>)
        : EditorTimeline.fromLegacy(
            subtitles: legacySubtitles,
            globalStyle: legacyStyle,
            videoPath: videoPath,
            durationMs: durationMs,
          );
    final normalizedTimeline =
        timeline.primarySubtitleTrack != null || legacySubtitles.isEmpty
        ? timeline
        : timeline.syncLegacySubtitles(
            subtitles: legacySubtitles,
            globalStyle: legacyStyle,
            videoPath: videoPath,
            durationMs: durationMs,
          );

    return Project(
      id: data['id'] as String,
      name: data['name'] as String? ?? 'Untitled',
      videoPath: videoPath,
      thumbnailBase64: data['thumbnailBase64'] as String?,
      durationMs: durationMs,
      subtitles: normalizedTimeline.subtitleEntries,
      globalStyle: normalizedTimeline.subtitleStyle,
      timeline: normalizedTimeline,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      lastModifiedAt:
          (data['lastModifiedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'videoPath': videoPath,
      'thumbnailBase64': thumbnailBase64,
      'durationMs': durationMs,
      'subtitles': subtitles.map((e) => e.toJson()).toList(),
      'globalStyle': globalStyle.toJson(),
      'timeline': timeline.toJson(),
      'createdAt': createdAt.toIso8601String(),
      'lastModifiedAt': lastModifiedAt.toIso8601String(),
    };
  }

  factory Project.fromJson(Map<String, dynamic> data) {
    final legacySubtitles =
        (data['subtitles'] as List<dynamic>?)
            ?.map((e) => SubtitleEntry.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [];
    final legacyStyle = data['globalStyle'] != null
        ? SubtitleStyleModel.fromJson(
            data['globalStyle'] as Map<String, dynamic>,
          )
        : const SubtitleStyleModel();
    final videoPath = data['videoPath'] as String? ?? '';
    final durationMs = (data['durationMs'] as num?)?.toInt() ?? 0;
    final timeline = data['timeline'] is Map<String, dynamic>
        ? EditorTimeline.fromJson(data['timeline'] as Map<String, dynamic>)
        : EditorTimeline.fromLegacy(
            subtitles: legacySubtitles,
            globalStyle: legacyStyle,
            videoPath: videoPath,
            durationMs: durationMs,
          );
    final normalizedTimeline =
        timeline.primarySubtitleTrack != null || legacySubtitles.isEmpty
        ? timeline
        : timeline.syncLegacySubtitles(
            subtitles: legacySubtitles,
            globalStyle: legacyStyle,
            videoPath: videoPath,
            durationMs: durationMs,
          );

    return Project(
      id: data['id'] as String,
      name: data['name'] as String? ?? 'Untitled',
      videoPath: videoPath,
      thumbnailBase64: data['thumbnailBase64'] as String?,
      durationMs: durationMs,
      subtitles: normalizedTimeline.subtitleEntries,
      globalStyle: normalizedTimeline.subtitleStyle,
      timeline: normalizedTimeline,
      createdAt:
          DateTime.tryParse(data['createdAt'] as String? ?? '') ??
          DateTime.now(),
      lastModifiedAt:
          DateTime.tryParse(data['lastModifiedAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }

  Project copyWith({
    String? name,
    List<SubtitleEntry>? subtitles,
    SubtitleStyleModel? globalStyle,
    EditorTimeline? timeline,
    DateTime? lastModifiedAt,
    String? thumbnailBase64,
  }) {
    final nextSubtitles = subtitles ?? this.subtitles;
    final nextStyle = globalStyle ?? this.globalStyle;
    final nextTimeline =
        timeline ??
        this.timeline.mergeSubtitleEntries(
          subtitles: nextSubtitles,
          globalStyle: nextStyle,
        );

    return Project(
      id: id,
      name: name ?? this.name,
      videoPath: videoPath,
      thumbnailBase64: thumbnailBase64 ?? this.thumbnailBase64,
      durationMs: durationMs,
      subtitles: nextSubtitles,
      globalStyle: nextStyle,
      timeline: nextTimeline,
      createdAt: createdAt,
      lastModifiedAt: lastModifiedAt ?? this.lastModifiedAt,
    );
  }
}

/// Service for local JSON project persistence (offline fallback).
class ProjectLocalStorage {
  ProjectLocalStorage._();

  static Future<String> get _projectsDir async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(appDir.path, 'caption_craft_projects'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir.path;
  }

  /// Save a project as a local JSON file.
  static Future<void> saveProject(Project project) async {
    final dir = await _projectsDir;
    final file = File(p.join(dir, '${project.id}.json'));
    await file.writeAsString(jsonEncode(project.toJson()));
  }

  /// Load all projects from local JSON.
  static Future<List<Project>> loadProjects() async {
    final dir = await _projectsDir;
    final directory = Directory(dir);

    if (!await directory.exists()) return [];

    final projects = <Project>[];
    await for (final entity in directory.list()) {
      if (entity is File && entity.path.endsWith('.json')) {
        try {
          final content = await entity.readAsString();
          final data = jsonDecode(content) as Map<String, dynamic>;
          projects.add(Project.fromJson(data));
        } catch (e) {
          // Skip corrupted files
          continue;
        }
      }
    }

    projects.sort((a, b) => b.lastModifiedAt.compareTo(a.lastModifiedAt));
    return projects;
  }

  /// Delete a project's local JSON file.
  static Future<void> deleteProject(String projectId) async {
    final dir = await _projectsDir;
    final file = File(p.join(dir, '$projectId.json'));
    if (await file.exists()) {
      await file.delete();
    }
  }
}
