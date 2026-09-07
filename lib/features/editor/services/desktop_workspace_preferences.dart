import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// Layout-only preferences for the Windows editor workspace.
///
/// These values intentionally live outside [Project] and the editor undo
/// history. A user can try a different panel arrangement without making the
/// project dirty, and opening another project keeps the same comfortable
/// working layout.
class DesktopWorkspacePreferences {
  static const int currentSchemaVersion = 1;

  static const double defaultLeftPanelWidth = 258;
  static const double defaultRightPanelWidth = 316;
  static const double defaultTimelineHeight = 288;

  final int schemaVersion;
  final double leftPanelWidth;
  final double rightPanelWidth;
  final double timelineHeight;
  final bool mediaCollapsed;
  final bool inspectorCollapsed;

  const DesktopWorkspacePreferences({
    this.schemaVersion = currentSchemaVersion,
    this.leftPanelWidth = defaultLeftPanelWidth,
    this.rightPanelWidth = defaultRightPanelWidth,
    this.timelineHeight = defaultTimelineHeight,
    this.mediaCollapsed = false,
    this.inspectorCollapsed = false,
  });

  DesktopWorkspacePreferences copyWith({
    int? schemaVersion,
    double? leftPanelWidth,
    double? rightPanelWidth,
    double? timelineHeight,
    bool? mediaCollapsed,
    bool? inspectorCollapsed,
  }) {
    return DesktopWorkspacePreferences(
      schemaVersion: schemaVersion ?? this.schemaVersion,
      leftPanelWidth: leftPanelWidth ?? this.leftPanelWidth,
      rightPanelWidth: rightPanelWidth ?? this.rightPanelWidth,
      timelineHeight: timelineHeight ?? this.timelineHeight,
      mediaCollapsed: mediaCollapsed ?? this.mediaCollapsed,
      inspectorCollapsed: inspectorCollapsed ?? this.inspectorCollapsed,
    );
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': currentSchemaVersion,
    'leftPanelWidth': leftPanelWidth,
    'rightPanelWidth': rightPanelWidth,
    'timelineHeight': timelineHeight,
    'mediaCollapsed': mediaCollapsed,
    'inspectorCollapsed': inspectorCollapsed,
  };

  factory DesktopWorkspacePreferences.fromJson(Map<String, dynamic> json) {
    double number(String key, double fallback) {
      final value = json[key];
      if (value is num && value.isFinite) return value.toDouble();
      if (value is String) {
        final parsed = double.tryParse(value.trim());
        return parsed != null && parsed.isFinite ? parsed : fallback;
      }
      return fallback;
    }

    return DesktopWorkspacePreferences(
      schemaVersion: (json['schemaVersion'] as num?)?.toInt() ?? 1,
      leftPanelWidth: number('leftPanelWidth', defaultLeftPanelWidth),
      rightPanelWidth: number('rightPanelWidth', defaultRightPanelWidth),
      timelineHeight: number('timelineHeight', defaultTimelineHeight),
      mediaCollapsed: json['mediaCollapsed'] as bool? ?? false,
      inspectorCollapsed: json['inspectorCollapsed'] as bool? ?? false,
    );
  }

  /// Constrains persisted values to sane bounds before a layout consumes them.
  /// The width/height values are later constrained again against the current
  /// window, because a preference can outlive a monitor or DPI change.
  DesktopWorkspacePreferences normalized() {
    return copyWith(
      schemaVersion: currentSchemaVersion,
      leftPanelWidth: leftPanelWidth.clamp(180.0, 440.0).toDouble(),
      rightPanelWidth: rightPanelWidth.clamp(220.0, 480.0).toDouble(),
      timelineHeight: timelineHeight.clamp(170.0, 720.0).toDouble(),
    );
  }
}

/// Small JSON-backed store for workspace chrome preferences.
///
/// The directory provider is injectable so widget and service tests can use a
/// temporary directory without relying on a platform plugin implementation.
class DesktopWorkspacePreferencesStore {
  final Future<Directory> Function() _directoryProvider;
  final String fileName;
  Future<void> _saveQueue = Future<void>.value();

  DesktopWorkspacePreferencesStore({
    Future<Directory> Function()? directoryProvider,
    this.fileName = 'desktop_workspace_preferences.json',
  }) : _directoryProvider = directoryProvider ?? getApplicationSupportDirectory;

  Future<File> _file() async {
    final directory = await _directoryProvider();
    await directory.create(recursive: true);
    return File(path.join(directory.path, fileName));
  }

  Future<DesktopWorkspacePreferences> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return const DesktopWorkspacePreferences();
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return const DesktopWorkspacePreferences();
      return DesktopWorkspacePreferences.fromJson(
        Map<String, dynamic>.from(decoded),
      ).normalized();
    } catch (_) {
      // Layout preferences are optional. A damaged preference file should
      // never prevent a project from opening.
      return const DesktopWorkspacePreferences();
    }
  }

  Future<void> save(DesktopWorkspacePreferences preferences) async {
    final queued = _saveQueue.then((_) => _saveNow(preferences));
    // Keep the queue usable after a read-only directory or transient Windows
    // file-lock failure. The caller still receives the original error so the
    // service can be tested directly; the workspace boundary intentionally
    // treats this optional chrome state as best effort.
    _saveQueue = queued.catchError((_) {});
    return queued;
  }

  Future<void> _saveNow(DesktopWorkspacePreferences preferences) async {
    final file = await _file();
    final temporary = File(
      '${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    await temporary.writeAsString(
      jsonEncode(preferences.normalized().toJson()),
      flush: true,
    );
    if (await file.exists()) {
      try {
        await file.delete();
      } catch (_) {
        // Windows can briefly hold a handle after a read. The temporary file
        // remains available for diagnostics; the next save retries normally.
      }
    }
    await temporary.rename(file.path);
  }
}
