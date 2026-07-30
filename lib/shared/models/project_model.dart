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
  final bool isFavorite;
  final String? lastExportPath;
  final DateTime createdAt;
  DateTime lastModifiedAt;
  final DateTime captionsModifiedAt;
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
    this.isFavorite = false,
    this.lastExportPath,
    DateTime? createdAt,
    DateTime? lastModifiedAt,
    DateTime? captionsModifiedAt,
  }) : createdAt = createdAt ?? DateTime.now(),
       lastModifiedAt = lastModifiedAt ?? DateTime.now(),
       captionsModifiedAt =
           captionsModifiedAt ?? lastModifiedAt ?? DateTime.now();

  /// Whether the source video file still exists on device.
  bool get isVideoAvailable {
    final cached = _videoAvailableCache;
    if (cached != null) return cached;

    final exists = mediaPaths.any((mediaPath) => File(mediaPath).existsSync());
    _videoAvailableCache = exists;
    return exists;
  }

  /// Local video candidates that can make this project editable.
  Iterable<String> get mediaPaths sync* {
    final seen = <String>{};
    if (videoPath.isNotEmpty && seen.add(videoPath)) {
      yield videoPath;
    }
    for (final asset in timeline.assets) {
      final sourcePath = asset.sourcePath;
      if (asset.type == EditorAssetType.video &&
          sourcePath != null &&
          sourcePath.isNotEmpty &&
          seen.add(sourcePath)) {
        yield sourcePath;
      }
    }
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
      'isFavorite': isFavorite,
      'lastExportPath': lastExportPath,
      'createdAt': Timestamp.fromDate(createdAt),
      'lastModifiedAt': Timestamp.fromDate(lastModifiedAt),
      'captionsModifiedAt': Timestamp.fromDate(captionsModifiedAt),
      'captionCount': subtitles.length,
      'projectSchemaVersion': 2,
    };
  }

  factory Project.fromFirestore(Map<String, dynamic> data) {
    final subtitles = _subtitlesFromData(data);
    final globalStyle = _styleFromData(data['globalStyle']);
    final videoPath = data['videoPath'] as String? ?? '';
    final durationMs = (data['durationMs'] as num?)?.toInt() ?? 0;
    final lastModifiedAt = _firestoreDate(data['lastModifiedAt']);

    return Project(
      id: data['id'] as String? ?? '',
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
      isFavorite: data['isFavorite'] as bool? ?? false,
      lastExportPath: data['lastExportPath'] as String?,
      createdAt: _firestoreDate(data['createdAt']),
      lastModifiedAt: lastModifiedAt,
      captionsModifiedAt: _firestoreDate(
        data['captionsModifiedAt'],
        fallback: lastModifiedAt,
      ),
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
      'isFavorite': isFavorite,
      'lastExportPath': lastExportPath,
      'createdAt': createdAt.toIso8601String(),
      'lastModifiedAt': lastModifiedAt.toIso8601String(),
      'captionsModifiedAt': captionsModifiedAt.toIso8601String(),
      'projectSchemaVersion': 2,
    };
  }

  factory Project.fromJson(Map<String, dynamic> data) {
    final subtitles = _subtitlesFromData(data);
    final globalStyle = _styleFromData(data['globalStyle']);
    final videoPath = data['videoPath'] as String? ?? '';
    final durationMs = (data['durationMs'] as num?)?.toInt() ?? 0;
    final lastModifiedAt =
        DateTime.tryParse(data['lastModifiedAt'] as String? ?? '') ??
        DateTime.now();

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
      isFavorite: data['isFavorite'] as bool? ?? false,
      lastExportPath: data['lastExportPath'] as String?,
      createdAt:
          DateTime.tryParse(data['createdAt'] as String? ?? '') ??
          DateTime.now(),
      lastModifiedAt: lastModifiedAt,
      captionsModifiedAt:
          DateTime.tryParse(data['captionsModifiedAt'] as String? ?? '') ??
          lastModifiedAt,
    );
  }

  Project copyWith({
    String? name,
    String? videoPath,
    int? durationMs,
    List<SubtitleEntry>? subtitles,
    EditorTimeline? timeline,
    SubtitleStyleModel? globalStyle,
    bool? isFavorite,
    String? lastExportPath,
    bool clearLastExportPath = false,
    DateTime? lastModifiedAt,
    DateTime? captionsModifiedAt,
    String? thumbnailBase64,
  }) {
    return Project(
      id: id,
      name: name ?? this.name,
      videoPath: videoPath ?? this.videoPath,
      thumbnailBase64: thumbnailBase64 ?? this.thumbnailBase64,
      durationMs: durationMs ?? this.durationMs,
      subtitles: subtitles ?? this.subtitles,
      timeline: timeline ?? this.timeline,
      globalStyle: globalStyle ?? this.globalStyle,
      isFavorite: isFavorite ?? this.isFavorite,
      lastExportPath: clearLastExportPath
          ? null
          : (lastExportPath ?? this.lastExportPath),
      createdAt: createdAt,
      lastModifiedAt: lastModifiedAt ?? this.lastModifiedAt,
      captionsModifiedAt: captionsModifiedAt ?? this.captionsModifiedAt,
    );
  }

  /// Reconciles two persisted copies without letting newer caption edits be
  /// replaced by unrelated project metadata from the other copy.
  static Project mergePersistedCopies({
    required Project local,
    required Project remote,
  }) {
    final base = remote.lastModifiedAt.isAfter(local.lastModifiedAt)
        ? remote
        : local;
    final captionSource =
        remote.captionsModifiedAt.isAfter(local.captionsModifiedAt)
        ? remote
        : local;

    if (identical(base, captionSource)) return base;

    return base.copyWith(
      subtitles: List<SubtitleEntry>.from(captionSource.subtitles),
      globalStyle: captionSource.globalStyle,
      timeline: base.timeline.mergeSubtitleEntries(
        subtitles: captionSource.subtitles,
        globalStyle: captionSource.globalStyle,
      ),
      captionsModifiedAt: captionSource.captionsModifiedAt,
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
      try {
        return EditorTimeline.fromJson(
          Map<String, dynamic>.from(value),
        ).syncLegacySubtitles(
          subtitles: subtitles,
          globalStyle: globalStyle,
          videoPath: videoPath,
          durationMs: durationMs,
        );
      } catch (_) {
        // Fall through to a safe single-source timeline. Keeping a project
        // editable is preferable to dropping it because one nested item is
        // from an older or partially-written schema.
      }
    }

    return const EditorTimeline().syncLegacySubtitles(
      subtitles: subtitles,
      globalStyle: globalStyle,
      videoPath: videoPath,
      durationMs: durationMs,
    );
  }

  static List<SubtitleEntry> _subtitlesFromData(Map<String, dynamic> data) {
    Object? value = data['subtitles'];
    if (value == null) {
      final captions = data['captions'];
      value = captions is Map ? captions['entries'] : captions;
    }
    if (value is! List) return const [];

    final subtitles = <SubtitleEntry>[];
    for (final entry in value.whereType<Map>()) {
      try {
        subtitles.add(SubtitleEntry.fromJson(Map<String, dynamic>.from(entry)));
      } catch (_) {
        // Preserve the rest of the caption track if one cue is damaged.
      }
    }
    return subtitles;
  }

  static SubtitleStyleModel _styleFromData(Object? value) {
    if (value is Map) {
      try {
        return SubtitleStyleModel.fromJson(Map<String, dynamic>.from(value));
      } catch (_) {
        // Legacy or malformed style data should fall back to editor defaults.
      }
    }
    return const SubtitleStyleModel();
  }

  static DateTime _firestoreDate(Object? value, {DateTime? fallback}) {
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    if (value is String) {
      return DateTime.tryParse(value) ?? fallback ?? DateTime.now();
    }
    if (value is num) {
      return DateTime.fromMillisecondsSinceEpoch(value.toInt());
    }
    return fallback ?? DateTime.now();
  }
}

/// Service for local JSON project persistence (offline fallback).
class ProjectLocalStorage {
  ProjectLocalStorage._();

  static final Map<String, Future<void>> _saveQueues = {};
  static Directory? _documentsDirectoryOverride;

  /// Overrides the app documents directory for isolated persistence tests.
  static void setDocumentsDirectoryForTesting(Directory? directory) {
    if (_saveQueues.isNotEmpty) {
      throw StateError('Cannot change the storage directory during a save.');
    }
    _documentsDirectoryOverride = directory;
  }

  static Future<String> get _projectsDir async {
    final appDir =
        _documentsDirectoryOverride ?? await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(appDir.path, 'caption_craft_projects'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir.path;
  }

  /// Save a project as a local JSON file.
  static Future<void> saveProject(Project project) async {
    final projectId = _safeFileId(project.id);
    final previousSave = _saveQueues[projectId] ?? Future<void>.value();
    final nextSave = () async {
      try {
        await previousSave;
      } catch (_) {
        // A later valid snapshot should still be allowed to repair the file.
      }
      await _writeProject(project, projectId);
    }();
    _saveQueues[projectId] = nextSave;

    try {
      await nextSave;
    } finally {
      if (identical(_saveQueues[projectId], nextSave)) {
        _saveQueues.remove(projectId);
      }
    }
  }

  static Future<void> _writeProject(Project project, String projectId) async {
    final dir = await _projectsDir;
    final file = File(p.join(dir, '$projectId.json'));
    final temporaryFile = File('${file.path}.tmp');
    final backupFile = File('${file.path}.bak');
    final persistedProject = await _readLatestProject(file.path);
    var projectToWrite = project;
    if (persistedProject != null) {
      projectToWrite = Project.mergePersistedCopies(
        local: persistedProject,
        remote: project,
      );
      if (identical(projectToWrite, persistedProject)) return;
    }

    await temporaryFile.writeAsString(
      jsonEncode(projectToWrite.toJson()),
      flush: true,
    );

    if (await file.exists()) {
      if (await backupFile.exists()) await backupFile.delete();
      await file.copy(backupFile.path);
      await file.delete();
    }

    try {
      await temporaryFile.rename(file.path);
    } catch (_) {
      if (await backupFile.exists() && !await file.exists()) {
        await backupFile.copy(file.path);
      }
      rethrow;
    }
  }

  /// Load all projects from local JSON.
  static Future<List<Project>> loadProjects() async {
    final dir = await _projectsDir;
    final directory = Directory(dir);

    if (!await directory.exists()) return [];

    final entities = await directory.list().toList();
    final projectPaths = <String>{};
    for (final file in entities.whereType<File>()) {
      final basePath = _baseProjectPath(file.path);
      if (basePath != null) projectPaths.add(basePath);
    }

    final loadedProjects = await Future.wait(
      projectPaths.map(_readLatestProject),
    );

    final projects = loadedProjects.whereType<Project>().toList();

    projects.sort((a, b) => b.lastModifiedAt.compareTo(a.lastModifiedAt));
    return projects;
  }

  static Future<Project?> loadProject(String projectId) async {
    final dir = await _projectsDir;
    final basePath = p.join(dir, '${_safeFileId(projectId)}.json');
    return _readLatestProject(basePath);
  }

  /// Delete a project's local JSON file.
  static Future<void> deleteProject(
    String projectId, {
    String? ownerUid,
  }) async {
    final safeProjectId = _safeFileId(projectId);
    final previousSave = _saveQueues[safeProjectId] ?? Future<void>.value();
    final deletion = () async {
      try {
        await previousSave;
      } catch (_) {
        // Deletion still needs to remove any partial save artifacts.
      }
      final dir = await _projectsDir;
      final basePath = p.join(dir, '$safeProjectId.json');
      for (final candidate in [
        File(basePath),
        File('$basePath.tmp'),
        File('$basePath.bak'),
      ]) {
        if (await candidate.exists()) await candidate.delete();
      }
      final tombstone = File(p.join(dir, '$safeProjectId.deleted'));
      await tombstone.writeAsString(
        jsonEncode({
          'projectId': projectId,
          'ownerUid': ownerUid,
          'deletedAt': DateTime.now().toUtc().toIso8601String(),
        }),
        flush: true,
      );
    }();
    _saveQueues[safeProjectId] = deletion;
    try {
      await deletion;
    } finally {
      if (identical(_saveQueues[safeProjectId], deletion)) {
        _saveQueues.remove(safeProjectId);
      }
    }
  }

  static Future<Set<String>> loadDeletedProjectIds(String ownerUid) async {
    final dir = await _projectsDir;
    final markers = await Directory(dir)
        .list()
        .where((entity) => entity is File && entity.path.endsWith('.deleted'))
        .cast<File>()
        .toList();
    final ids = <String>{};
    for (final marker in markers) {
      try {
        final data =
            jsonDecode(await marker.readAsString()) as Map<String, dynamic>;
        final projectId = data['projectId'] as String?;
        final markerOwner = data['ownerUid'] as String?;
        if (markerOwner == ownerUid &&
            projectId != null &&
            projectId.isNotEmpty) {
          ids.add(projectId);
        }
      } catch (_) {
        // A malformed marker cannot identify a safe remote deletion target.
      }
    }
    return ids;
  }

  static Future<void> clearProjectDeletion(String projectId) async {
    final dir = await _projectsDir;
    final tombstone = File(p.join(dir, '${_safeFileId(projectId)}.deleted'));
    if (await tombstone.exists()) await tombstone.delete();
  }

  static Future<Project> _readProjectFile(File file) async {
    final content = await file.readAsString();
    final data = jsonDecode(content) as Map<String, dynamic>;
    return Project.fromJson(data);
  }

  static Future<Project?> _readLatestProject(String basePath) async {
    Project? latest;
    for (final candidate in [
      File(basePath),
      File('$basePath.tmp'),
      File('$basePath.bak'),
    ]) {
      if (!await candidate.exists()) continue;
      try {
        final project = await _readProjectFile(candidate);
        final current = latest;
        if (current == null ||
            project.lastModifiedAt.isAfter(current.lastModifiedAt) ||
            (project.lastModifiedAt.isAtSameMomentAs(current.lastModifiedAt) &&
                project.captionsModifiedAt.isAfter(
                  current.captionsModifiedAt,
                ))) {
          latest = project;
        }
      } catch (_) {
        // A valid temporary or backup snapshot can still recover the project.
      }
    }
    return latest;
  }

  static String? _baseProjectPath(String candidatePath) {
    if (candidatePath.endsWith('.json')) return candidatePath;
    if (candidatePath.endsWith('.json.tmp') ||
        candidatePath.endsWith('.json.bak')) {
      return candidatePath.substring(0, candidatePath.length - 4);
    }
    return null;
  }

  static String _safeFileId(String projectId) {
    final safe = projectId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return safe.isEmpty ? 'project' : safe;
  }
}
