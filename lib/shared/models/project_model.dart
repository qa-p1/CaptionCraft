import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
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
  final EditorTimeline timeline;
  SubtitleStyleModel globalStyle;
  final DateTime createdAt;
  DateTime lastModifiedAt;
  Uint8List? _thumbnailBytesCache;
  bool _thumbnailDecoded = false;
  bool? _videoAvailableCache;

  Project({
    required this.id,
    required this.name,
    required this.videoPath,
    this.thumbnailBase64,
    required this.durationMs,
    this.subtitles = const [],
    this.timeline = const EditorTimeline(),
    this.globalStyle = const SubtitleStyleModel(),
    DateTime? createdAt,
    DateTime? lastModifiedAt,
  }) : createdAt = createdAt ?? DateTime.now(),
       lastModifiedAt = lastModifiedAt ?? DateTime.now();

  /// Whether the source video file still exists on device.
  bool get isVideoAvailable {
    final cached = _videoAvailableCache;
    if (cached != null) return cached;

    final exists = File(videoPath).existsSync();
    _videoAvailableCache = exists;
    return exists;
  }

  Uint8List? get thumbnailBytes {
    if (_thumbnailDecoded) return _thumbnailBytesCache;

    _thumbnailDecoded = true;
    final encodedThumbnail = thumbnailBase64;
    if (encodedThumbnail == null || encodedThumbnail.isEmpty) {
      return null;
    }

    try {
      _thumbnailBytesCache = base64Decode(encodedThumbnail);
    } catch (_) {
      _thumbnailBytesCache = null;
    }

    return _thumbnailBytesCache;
  }

  void cacheVideoAvailability(bool isAvailable) {
    _videoAvailableCache = isAvailable;
  }

  Duration get duration => Duration(milliseconds: durationMs);

  Map<String, dynamic> toFirestore() {
    return {
      'id': id,
      'name': name,
      'videoPath': videoPath,
      'thumbnailBase64': thumbnailBase64,
      'durationMs': durationMs,
      'subtitles': subtitles.map((e) => e.toJson()).toList(),
      'timeline': timeline.toJson(),
      'globalStyle': globalStyle.toJson(),
      'createdAt': Timestamp.fromDate(createdAt),
      'lastModifiedAt': Timestamp.fromDate(lastModifiedAt),
    };
  }

  factory Project.fromFirestore(Map<String, dynamic> data) {
    final subtitles =
        (data['subtitles'] as List<dynamic>?)
            ?.map((e) => SubtitleEntry.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [];
    final globalStyle = data['globalStyle'] != null
        ? SubtitleStyleModel.fromJson(
            data['globalStyle'] as Map<String, dynamic>,
          )
        : const SubtitleStyleModel();
    final videoPath = data['videoPath'] as String? ?? '';
    final durationMs = (data['durationMs'] as num?)?.toInt() ?? 0;

    return Project(
      id: data['id'] as String,
      name: data['name'] as String? ?? 'Untitled',
      videoPath: videoPath,
      thumbnailBase64: data['thumbnailBase64'] as String?,
      durationMs: durationMs,
      subtitles: subtitles,
      timeline: _timelineFromData(
        data['timeline'],
        subtitles: subtitles,
        globalStyle: globalStyle,
        videoPath: videoPath,
        durationMs: durationMs,
      ),
      globalStyle: globalStyle,
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
      'timeline': timeline.toJson(),
      'globalStyle': globalStyle.toJson(),
      'createdAt': createdAt.toIso8601String(),
      'lastModifiedAt': lastModifiedAt.toIso8601String(),
    };
  }

  factory Project.fromJson(Map<String, dynamic> data) {
    final subtitles =
        (data['subtitles'] as List<dynamic>?)
            ?.map((e) => SubtitleEntry.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [];
    final globalStyle = data['globalStyle'] != null
        ? SubtitleStyleModel.fromJson(
            data['globalStyle'] as Map<String, dynamic>,
          )
        : const SubtitleStyleModel();
    final videoPath = data['videoPath'] as String? ?? '';
    final durationMs = (data['durationMs'] as num?)?.toInt() ?? 0;

    return Project(
      id: data['id'] as String,
      name: data['name'] as String? ?? 'Untitled',
      videoPath: videoPath,
      thumbnailBase64: data['thumbnailBase64'] as String?,
      durationMs: durationMs,
      subtitles: subtitles,
      timeline: _timelineFromData(
        data['timeline'],
        subtitles: subtitles,
        globalStyle: globalStyle,
        videoPath: videoPath,
        durationMs: durationMs,
      ),
      globalStyle: globalStyle,
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
    EditorTimeline? timeline,
    SubtitleStyleModel? globalStyle,
    DateTime? lastModifiedAt,
    String? thumbnailBase64,
  }) {
    return Project(
      id: id,
      name: name ?? this.name,
      videoPath: videoPath,
      thumbnailBase64: thumbnailBase64 ?? this.thumbnailBase64,
      durationMs: durationMs,
      subtitles: subtitles ?? this.subtitles,
      timeline: timeline ?? this.timeline,
      globalStyle: globalStyle ?? this.globalStyle,
      createdAt: createdAt,
      lastModifiedAt: lastModifiedAt ?? this.lastModifiedAt,
    );
  }

  static EditorTimeline _timelineFromData(
    Object? value, {
    required List<SubtitleEntry> subtitles,
    required SubtitleStyleModel globalStyle,
    required String videoPath,
    required int durationMs,
  }) {
    if (value is Map) {
      return EditorTimeline.fromJson(Map<String, dynamic>.from(value));
    }

    return const EditorTimeline().syncLegacySubtitles(
      subtitles: subtitles,
      globalStyle: globalStyle,
      videoPath: videoPath,
      durationMs: durationMs,
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
    await file.writeAsString(jsonEncode(project.toJson()), flush: true);
  }

  /// Load all projects from local JSON.
  static Future<List<Project>> loadProjects() async {
    final dir = await _projectsDir;
    final directory = Directory(dir);

    if (!await directory.exists()) return [];

    final entities = await directory.list().toList();
    final files = entities
        .whereType<File>()
        .where((file) => file.path.endsWith('.json'))
        .toList();

    final loadedProjects = await Future.wait(
      files.map((file) async {
        try {
          final content = await file.readAsString();
          final data = jsonDecode(content) as Map<String, dynamic>;
          return Project.fromJson(data);
        } catch (_) {
          // Skip corrupted files.
          return null;
        }
      }),
    );

    final projects = loadedProjects.whereType<Project>().toList();

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
