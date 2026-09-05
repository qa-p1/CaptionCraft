import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../shared/models/project_model.dart';

class EditorChangeLogService {
  EditorChangeLogService._();

  static const int _maxLogBytes = 512 * 1024;
  static final Map<String, DateTime> _lastLoggedAt = {};

  static Future<void> saveLocalSnapshot({
    required Project project,
    required String changeType,
  }) async {
    await ProjectLocalStorage.saveProject(project);
    try {
      await _appendChange(project: project, changeType: changeType);
    } catch (_) {
      // Diagnostics must never turn a successful project save into a failure.
    }
  }

  static Future<String> get _logDir async {
    final appDir = await ProjectLocalStorage.applicationDocumentsDirectory;
    final dir = Directory(p.join(appDir.path, 'caption_craft_change_logs'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir.path;
  }

  static Future<void> _appendChange({
    required Project project,
    required String changeType,
  }) async {
    final now = DateTime.now();
    final previous = _lastLoggedAt[project.id];
    if (previous != null &&
        now.difference(previous) < const Duration(milliseconds: 600)) {
      return;
    }
    _lastLoggedAt[project.id] = now;

    final dir = await _logDir;
    final safeProjectId = project.id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final file = File(
      p.join(dir, '${safeProjectId.isEmpty ? 'project' : safeProjectId}.jsonl'),
    );
    if (await file.exists() && await file.length() >= _maxLogBytes) {
      final previousFile = File('${file.path}.previous');
      if (await previousFile.exists()) await previousFile.delete();
      await file.rename(previousFile.path);
    }
    final event = {
      'projectId': project.id,
      'changeType': changeType,
      'savedAt': now.toUtc().toIso8601String(),
      'lastModifiedAt': project.lastModifiedAt.toUtc().toIso8601String(),
      'subtitleCount': project.subtitles.length,
      'trackCount': project.timeline.tracks.length,
      'assetCount': project.timeline.assets.length,
    };

    await file.writeAsString(
      '${jsonEncode(event)}\n',
      mode: FileMode.append,
      flush: true,
    );
  }
}
