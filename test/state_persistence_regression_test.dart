import 'dart:io';

import 'package:caption_craft/features/editor/models/subtitle_entry.dart';
import 'package:caption_craft/features/editor/models/subtitle_style_model.dart';
import 'package:caption_craft/features/editor/models/timeline_models.dart';
import 'package:caption_craft/features/editor/models/word_timing.dart';
import 'package:caption_craft/features/editor/providers/subtitle_provider.dart';
import 'package:caption_craft/features/quota/providers/quota_provider.dart';
import 'package:caption_craft/shared/models/project_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('project account ownership', () {
    late Directory documentsDirectory;

    setUp(() async {
      documentsDirectory = await Directory.systemTemp.createTemp(
        'captioncraft_account_projects_',
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
      'filters projects by owner and claims legacy files only once',
      () async {
        await ProjectLocalStorage.saveProject(_project('owned-a', 'account-a'));
        await ProjectLocalStorage.saveProject(_project('owned-b', 'account-b'));
        await ProjectLocalStorage.saveProject(_project('legacy', null));

        final accountA = await ProjectLocalStorage.loadProjects(
          ownerUid: 'account-a',
        );
        expect(accountA.map((project) => project.id), ['owned-a']);

        final accountB = await ProjectLocalStorage.loadProjects(
          ownerUid: 'account-b',
          claimUnowned: true,
        );
        expect(accountB.map((project) => project.id).toSet(), {
          'owned-b',
          'legacy',
        });

        final accountAAfterClaim = await ProjectLocalStorage.loadProjects(
          ownerUid: 'account-a',
        );
        expect(accountAAfterClaim.map((project) => project.id), ['owned-a']);
        expect(
          (await ProjectLocalStorage.loadProject('legacy'))!.ownerUid,
          'account-b',
        );
      },
    );

    test('round-trips owner and schema without changing a current style', () {
      const style = SubtitleStyleModel(fontSize: 24, maxWidthFactor: 0.85);
      final project = Project(
        id: 'current-style',
        ownerUid: 'account-a',
        name: 'Current style',
        videoPath: '/video.mp4',
        durationMs: 1000,
        globalStyle: style,
      );

      final restored = Project.fromJson(project.toJson());
      expect(restored.ownerUid, 'account-a');
      expect(restored.projectSchemaVersion, Project.currentSchemaVersion);
      expect(restored.globalStyle.fontSize, 24);
      expect(restored.globalStyle.maxWidthFactor, 0.85);
      expect(restored.editorGlobalStyle.fontSize, 24);
      expect(restored.editorGlobalStyle.maxWidthFactor, 0.85);

      final legacy = Project.fromJson({
        ...project.toJson(),
        'projectSchemaVersion': Project.currentSchemaVersion - 1,
      });
      expect(legacy.editorGlobalStyle.fontSize, 10);
      expect(legacy.editorGlobalStyle.maxWidthFactor, 1);
    });

    test('refuses to merge copies owned by different accounts', () {
      expect(
        () => Project.mergePersistedCopies(
          local: _project('shared-id', 'account-a'),
          remote: _project('shared-id', 'account-b'),
        ),
        throwsStateError,
      );
    });
  });

  test('timeline restores valid siblings and derives source duration', () {
    final timeline = EditorTimeline.fromJson({
      'schemaVersion': 4,
      'tracks': [
        {
          'id': 'video-track',
          'name': 'Video',
          'type': 'video',
          'section': 'baseVideo',
          'clips': [
            {
              'id': 'valid',
              'trackId': 'video-track',
              'type': 'video',
              'label': 'Valid',
              'startTimeMs': 100,
              'endTimeMs': 2100,
              'playbackRate': 2,
              'keyframes': [
                {'timeMs': 0, 'property': 'opacity', 'value': 0.5},
                {'timeMs': 1, 'property': 'opacity', 'value': 'damaged'},
              ],
            },
            {
              'id': 'damaged',
              'trackId': 'video-track',
              'type': 'video',
              'label': 'Damaged',
              'startTimeMs': 500,
              'endTimeMs': 500,
            },
          ],
        },
      ],
      'assets': [
        {'id': 'bad-asset', 'metadata': 'damaged'},
      ],
      'markers': [
        {'id': 'marker', 'positionMs': '750', 'color': 'not-a-color'},
      ],
    });

    final clip = timeline.videoClips.single;
    expect(clip.id, 'valid');
    expect(clip.sourceDuration, const Duration(seconds: 4));
    expect(clip.keyframes, hasLength(1));
    expect(timeline.assets.single.metadata, isEmpty);
    expect(timeline.markers.single.position, const Duration(milliseconds: 750));
  });

  test('project availability requires every referenced local video', () {
    final project = _mediaProject();

    final partial = project.evaluateVideoAvailability(
      pathExists: (path) => path == '/primary.mp4',
    );
    expect(partial.primarySourceAvailable, isTrue);
    expect(partial.anySourceAvailable, isTrue);
    expect(partial.allRequiredSourcesAvailable, isFalse);
    expect(partial.isPartiallyAvailable, isTrue);

    final missingPrimary = project.evaluateVideoAvailability(
      pathExists: (path) => path == '/secondary.mp4',
    );
    expect(missingPrimary.primarySourceAvailable, isFalse);
    expect(missingPrimary.anySourceAvailable, isTrue);
    expect(missingPrimary.allRequiredSourcesAvailable, isFalse);

    final networkOverlay = _mediaProject(
      networkSecondary: true,
    ).evaluateVideoAvailability(pathExists: (path) => path == '/primary.mp4');
    expect(networkOverlay.allRequiredSourcesAvailable, isTrue);
  });

  test('overlay-only image projects stay valid with an empty main lane', () {
    final imageAsset = EditorAssetReference(
      id: 'image-asset',
      type: EditorAssetType.image,
      label: 'Poster',
      sourcePath: '/poster.png',
    );
    final project = Project(
      id: 'image-project',
      ownerUid: 'account-a',
      name: 'Image project',
      videoPath: '/obsolete-first-video.mp4',
      durationMs: 4000,
      timeline: EditorTimeline(
        assets: [imageAsset],
        tracks: [
          TimelineTrack(
            id: 'main',
            name: 'Main video',
            type: TimelineTrackType.video,
            section: TimelineTrackSection.baseVideo,
          ),
          TimelineTrack(
            id: 'overlay',
            name: 'Overlay',
            type: TimelineTrackType.video,
            section: TimelineTrackSection.overlay,
            clips: [
              TimelineClip(
                id: 'poster',
                trackId: 'overlay',
                type: TimelineTrackType.image,
                label: 'Poster',
                assetId: imageAsset.id,
                startTime: Duration.zero,
                endTime: const Duration(seconds: 4),
              ),
            ],
          ),
        ],
      ),
    );

    final restored = Project.fromJson(project.toJson());
    expect(
      restored.timeline.tracks
          .singleWhere(
            (track) => track.section == TimelineTrackSection.baseVideo,
          )
          .clips,
      isEmpty,
    );
    final availability = restored.evaluateVideoAvailability(
      pathExists: (path) => path == '/poster.png',
    );
    expect(availability.primarySourceAvailable, isTrue);
    expect(availability.allRequiredSourcesAvailable, isTrue);
  });

  test('most recent project ignores favorite and display ordering', () {
    final olderFavorite = _project(
      'older',
      'account-a',
    ).copyWith(isFavorite: true, lastModifiedAt: DateTime.utc(2026, 8, 8, 10));
    final latest = _project(
      'latest',
      'account-a',
    ).copyWith(lastModifiedAt: DateTime.utc(2026, 8, 8, 12));

    expect(Project.mostRecentlyModified([olderFavorite, latest]), same(latest));
    expect(Project.mostRecentlyModified(const []), isNull);
  });

  test('word timings follow timing edits, duplicates, shifts, and trims', () {
    final notifier = SubtitleNotifier();
    addTearDown(notifier.dispose);
    final first = SubtitleEntry(
      id: 'first',
      startTime: const Duration(seconds: 1),
      endTime: const Duration(seconds: 5),
      text: 'one two',
      words: const [
        WordTiming(
          word: 'one',
          startTime: Duration(seconds: 1),
          endTime: Duration(seconds: 2),
        ),
        WordTiming(
          word: 'two',
          startTime: Duration(seconds: 4),
          endTime: Duration(seconds: 5),
        ),
      ],
    );
    notifier.initializeFromProject(
      entries: [first],
      globalStyle: const SubtitleStyleModel(),
    );

    notifier.updateTiming(
      'first',
      const Duration(seconds: 2),
      const Duration(seconds: 6),
    );
    var edited = notifier.state.entries.single;
    expect(edited.words!.first.startTime, const Duration(seconds: 2));
    expect(edited.words!.last.endTime, const Duration(seconds: 6));

    notifier.duplicateEntry('first');
    final duplicate = notifier.state.selectedEntry!;
    expect(duplicate.words!.first.startTime, duplicate.startTime);
    expect(duplicate.words!.last.endTime, duplicate.endTime);

    notifier.shiftAll(
      const Duration(seconds: -8),
      projectDuration: const Duration(seconds: 12),
    );
    edited = notifier.state.entries.first;
    expect(edited.startTime, Duration.zero);
    expect(edited.words!.first.startTime, Duration.zero);
    expect(edited.words!.last.endTime, edited.endTime);

    final next = SubtitleEntry(
      id: 'next',
      startTime: const Duration(milliseconds: 2500),
      endTime: const Duration(seconds: 4),
      text: 'next',
    );
    notifier.initializeFromProject(
      entries: [edited, next],
      globalStyle: const SubtitleStyleModel(),
    );
    final normalized = notifier.state.entries;
    // Initial loading must preserve intentional overlaps between captions from
    // different video sources. An explicit repair still fixes this pair when
    // no source-lane map is supplied.
    expect(normalized[1].startTime, const Duration(milliseconds: 2500));
    notifier.fixOverlaps(minimumGap: const Duration(milliseconds: 100));
    final trimmed = notifier.state.entries.first;
    expect(
      trimmed.endTime,
      normalized[1].startTime - const Duration(milliseconds: 100),
    );
    expect(trimmed.words!.last.endTime, trimmed.endTime);
  });

  group('quota state serialization', () {
    test(
      'blocks runs while loading or when quota storage is unavailable',
      () async {
        expect(const QuotaState().canRun, isFalse);
        final notifier = QuotaNotifier(
          loadRunsUsed: () async => throw StateError('storage unavailable'),
          consumeRun: (_) async => 1,
        );
        addTearDown(notifier.dispose);

        await notifier.loadQuota();
        expect(notifier.state.isLoading, isFalse);
        expect(notifier.state.hasLoadError, isTrue);
        expect(notifier.state.canRun, isFalse);
        expect(await notifier.consumeRun('account-a'), isFalse);
      },
    );

    test('serializes consumers and refuses calls after the maximum', () async {
      var serviceCount = 1;
      var consumeCalls = 0;
      final notifier = QuotaNotifier(
        loadRunsUsed: () async => serviceCount,
        consumeRun: (_) async {
          consumeCalls++;
          await Future<void>.delayed(const Duration(milliseconds: 1));
          return ++serviceCount;
        },
      );
      addTearDown(notifier.dispose);

      final results = await Future.wait([
        notifier.loadQuota().then((_) => true),
        notifier.consumeRun('account-a'),
        notifier.consumeRun('account-a'),
        notifier.consumeRun('account-a'),
      ]);

      expect(results, [true, true, true, false]);
      expect(consumeCalls, 2);
      expect(notifier.state.runsUsed, 3);
      expect(notifier.state.canRun, isFalse);
    });

    test(
      'stale loads and oversized responses cannot corrupt the count',
      () async {
        final notifier = QuotaNotifier(
          loadRunsUsed: () async => 0,
          consumeRun: (_) async => 99,
        );
        addTearDown(notifier.dispose);

        await notifier.loadQuota();
        expect(await notifier.consumeRun('account-a'), isTrue);
        expect(notifier.state.runsUsed, 3);
        await notifier.loadQuota();
        expect(notifier.state.runsUsed, 3);
      },
    );
  });
}

Project _project(String id, String? ownerUid) {
  final timestamp = DateTime.utc(2026, 8, 8);
  return Project(
    id: id,
    ownerUid: ownerUid,
    name: id,
    videoPath: '/$id.mp4',
    durationMs: 1000,
    createdAt: timestamp,
    lastModifiedAt: timestamp,
    captionsModifiedAt: timestamp,
  );
}

Project _mediaProject({bool networkSecondary = false}) {
  final primaryAsset = EditorAssetReference(
    id: 'primary-asset',
    type: EditorAssetType.video,
    label: 'Primary',
    sourcePath: '/primary.mp4',
  );
  final secondaryAsset = EditorAssetReference(
    id: 'secondary-asset',
    type: EditorAssetType.video,
    label: 'Secondary',
    sourcePath: networkSecondary ? null : '/secondary.mp4',
    remoteUrl: networkSecondary ? 'https://example.test/secondary.mp4' : null,
    isNetworkBacked: networkSecondary,
  );
  final timeline = EditorTimeline(
    assets: [primaryAsset, secondaryAsset],
    tracks: [
      TimelineTrack(
        id: 'base',
        name: 'Video 1',
        type: TimelineTrackType.video,
        section: TimelineTrackSection.baseVideo,
        clips: [
          TimelineClip(
            id: 'primary-clip',
            trackId: 'base',
            type: TimelineTrackType.video,
            label: 'Primary',
            assetId: primaryAsset.id,
            startTime: Duration.zero,
            endTime: const Duration(seconds: 2),
          ),
        ],
      ),
      TimelineTrack(
        id: 'overlay',
        name: 'Overlay 1',
        type: TimelineTrackType.video,
        section: TimelineTrackSection.overlay,
        clips: [
          TimelineClip(
            id: 'secondary-clip',
            trackId: 'overlay',
            type: TimelineTrackType.video,
            label: 'Secondary',
            assetId: secondaryAsset.id,
            startTime: Duration.zero,
            endTime: const Duration(seconds: 2),
          ),
        ],
      ),
    ],
  );
  return Project(
    id: 'media-project',
    ownerUid: 'account-a',
    name: 'Media project',
    videoPath: '/primary.mp4',
    durationMs: 2000,
    timeline: timeline,
  );
}
