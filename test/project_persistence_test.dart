import 'dart:convert';
import 'dart:io';

import 'package:caption_craft/features/editor/models/subtitle_entry.dart';
import 'package:caption_craft/features/editor/models/subtitle_style_model.dart';
import 'package:caption_craft/features/editor/models/timeline_models.dart';
import 'package:caption_craft/shared/models/project_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('project persistence', () {
    late Directory documentsDirectory;

    setUp(() async {
      documentsDirectory = await Directory.systemTemp.createTemp(
        'captioncraft_project_persistence_',
      );
      ProjectLocalStorage.setDocumentsDirectoryForTesting(documentsDirectory);
    });

    tearDown(() async {
      ProjectLocalStorage.setDocumentsDirectoryForTesting(null);
      if (await documentsDirectory.exists()) {
        await documentsDirectory.delete(recursive: true);
      }
    });

    test(
      'saves and retrieves the latest timeline and captions locally',
      () async {
        final createdAt = DateTime.utc(2026, 7, 29, 8);
        final initial = _project(
          captionText: 'Initial caption',
          lastModifiedAt: createdAt,
          captionsModifiedAt: createdAt,
        );
        await ProjectLocalStorage.saveProject(initial);

        final updatedAt = createdAt.add(const Duration(minutes: 3));
        final updated = _project(
          captionText: 'Locally persisted caption',
          lastModifiedAt: updatedAt,
          captionsModifiedAt: updatedAt,
          showGrid: true,
        );
        await ProjectLocalStorage.saveProject(updated);

        final restored = await ProjectLocalStorage.loadProject(initial.id);
        final library = await ProjectLocalStorage.loadProjects();

        expect(restored, isNotNull);
        expect(restored!.subtitles.single.text, 'Locally persisted caption');
        expect(restored.timeline.canvasSettings.showGrid, isTrue);
        expect(
          restored.timeline.subtitleEntries.single.text,
          restored.subtitles.single.text,
        );
        expect(restored.lastModifiedAt, updatedAt);
        expect(restored.captionsModifiedAt, updatedAt);
        expect(library.map((project) => project.id), contains(initial.id));
        expect(
          library.single.subtitles.single.text,
          'Locally persisted caption',
        );
      },
    );

    test(
      'does not let a stale asynchronous save replace newer progress',
      () async {
        final newerAt = DateTime.utc(2026, 7, 29, 10);
        final newer = _project(
          captionText: 'Newest caption',
          lastModifiedAt: newerAt,
          captionsModifiedAt: newerAt,
          showGrid: true,
        );
        final stale = _project(
          captionText: 'Stale caption',
          lastModifiedAt: newerAt.subtract(const Duration(minutes: 5)),
          captionsModifiedAt: newerAt.subtract(const Duration(minutes: 5)),
        );

        await ProjectLocalStorage.saveProject(newer);
        await ProjectLocalStorage.saveProject(stale);

        final restored = await ProjectLocalStorage.loadProject(newer.id);
        expect(restored!.subtitles.single.text, 'Newest caption');
        expect(restored.timeline.canvasSettings.showGrid, isTrue);
        expect(restored.lastModifiedAt, newerAt);
      },
    );

    test('recovers the newest valid atomic-save candidate', () async {
      final initialAt = DateTime.utc(2026, 7, 29, 11);
      final initial = _project(
        captionText: 'Committed caption',
        lastModifiedAt: initialAt,
        captionsModifiedAt: initialAt,
      );
      await ProjectLocalStorage.saveProject(initial);

      final recoveredAt = initialAt.add(const Duration(minutes: 1));
      final recovered = _project(
        captionText: 'Recovered caption',
        lastModifiedAt: recoveredAt,
        captionsModifiedAt: recoveredAt,
      );
      final temporaryFile = File(
        p.join(
          documentsDirectory.path,
          'caption_craft_projects',
          '${initial.id}.json.tmp',
        ),
      );
      await temporaryFile.writeAsString(
        jsonEncode(recovered.toJson()),
        flush: true,
      );

      final restored = await ProjectLocalStorage.loadProject(initial.id);
      final library = await ProjectLocalStorage.loadProjects();

      expect(restored!.subtitles.single.text, 'Recovered caption');
      expect(restored.lastModifiedAt, recoveredAt);
      expect(library.single.subtitles.single.text, 'Recovered caption');
    });
  });

  group('local and database reconciliation', () {
    test('Firestore payload round-trips captions and caption metadata', () {
      final modifiedAt = DateTime.utc(2026, 7, 29, 12);
      final project = _project(
        captionText: 'Database caption',
        lastModifiedAt: modifiedAt,
        captionsModifiedAt: modifiedAt,
      );

      final payload = project.toFirestore();
      final restored = Project.fromFirestore(payload);

      expect(payload['captionCount'], 1);
      expect(payload['subtitles'], isA<List<dynamic>>());
      expect(restored.subtitles.single.text, 'Database caption');
      expect(restored.timeline.subtitleEntries.single.text, 'Database caption');
      expect(restored.captionsModifiedAt.isAtSameMomentAs(modifiedAt), isTrue);
    });

    test('keeps local progress while accepting newer database captions', () {
      final baseAt = DateTime.utc(2026, 7, 29, 13);
      final local = _project(
        captionText: 'Older local caption',
        lastModifiedAt: baseAt.add(const Duration(minutes: 4)),
        captionsModifiedAt: baseAt,
        showGrid: true,
      );
      final remote = _project(
        captionText: 'Newer database caption',
        lastModifiedAt: baseAt.add(const Duration(minutes: 2)),
        captionsModifiedAt: baseAt.add(const Duration(minutes: 3)),
      );

      final merged = Project.mergePersistedCopies(local: local, remote: remote);

      expect(merged.timeline.canvasSettings.showGrid, isTrue);
      expect(merged.subtitles.single.text, 'Newer database caption');
      expect(
        merged.timeline.subtitleEntries.single.text,
        'Newer database caption',
      );
      expect(merged.lastModifiedAt, local.lastModifiedAt);
      expect(merged.captionsModifiedAt, remote.captionsModifiedAt);
    });
  });
}

Project _project({
  required String captionText,
  required DateTime lastModifiedAt,
  required DateTime captionsModifiedAt,
  bool showGrid = false,
}) {
  final caption = SubtitleEntry(
    id: 'caption_1',
    startTime: const Duration(milliseconds: 250),
    endTime: const Duration(milliseconds: 2250),
    text: captionText,
  );
  const style = SubtitleStyleModel(fontSize: 12, textColor: Color(0xFFFFFFFF));
  final timeline =
      EditorTimeline(
        canvasSettings: CanvasSettings(showGrid: showGrid),
      ).syncLegacySubtitles(
        subtitles: [caption],
        globalStyle: style,
        videoPath: '/media/source.mp4',
        durationMs: 5000,
      );

  return Project(
    id: 'project_1',
    name: 'Persistence test',
    videoPath: '/media/source.mp4',
    durationMs: 5000,
    subtitles: [caption],
    timeline: timeline,
    globalStyle: style,
    createdAt: DateTime.utc(2026, 7, 29, 7),
    lastModifiedAt: lastModifiedAt,
    captionsModifiedAt: captionsModifiedAt,
  );
}
