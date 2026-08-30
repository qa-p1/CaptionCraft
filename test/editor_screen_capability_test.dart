import 'package:caption_craft/core/theme/app_theme.dart';
import 'package:caption_craft/features/auth/providers/auth_provider.dart';
import 'package:caption_craft/features/editor/models/timeline_models.dart';
import 'package:caption_craft/features/editor/models/subtitle_entry.dart';
import 'package:caption_craft/features/editor/providers/editor_provider.dart';
import 'package:caption_craft/features/editor/screens/editor_screen.dart';
import 'package:caption_craft/shared/models/project_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Discover video stays an audible overlay without an audio lane', () {
    const duration = Duration(seconds: 3);
    final baseClip = TimelineClip(
      id: 'base',
      trackId: 'base-track',
      type: TimelineTrackType.video,
      label: 'Base',
      startTime: Duration.zero,
      endTime: const Duration(seconds: 10),
    );
    final occupiedOverlay = TimelineClip(
      id: 'existing-overlay',
      trackId: 'overlay-track',
      type: TimelineTrackType.image,
      label: 'Existing overlay',
      startTime: Duration.zero,
      endTime: const Duration(seconds: 2),
    );
    final baseTrack = TimelineTrack(
      id: 'base-track',
      name: 'Base layer',
      type: TimelineTrackType.video,
      section: TimelineTrackSection.baseVideo,
      clips: [baseClip],
    );
    final overlayTrack = TimelineTrack(
      id: 'overlay-track',
      name: 'Overlay 1',
      type: TimelineTrackType.video,
      section: TimelineTrackSection.overlay,
      clips: [occupiedOverlay],
    );
    final timeline = EditorTimeline(tracks: [overlayTrack, baseTrack]);

    final placement = resolveClosestReusableTrackPlacement(
      tracks: timeline.tracksForSection(TimelineTrackSection.overlay),
      clipType: TimelineTrackType.video,
      desiredStart: const Duration(seconds: 1),
      duration: duration,
    );
    final mix = resolveTimelineInsertionAudioMix(
      assetType: EditorAssetType.video,
      section: TimelineTrackSection.overlay,
      metadata: const {'hasAudio': true},
    );

    expect(placement?.track.id, overlayTrack.id);
    expect(placement?.start, occupiedOverlay.endTime);
    expect(mix.muted, isFalse);
    expect(timeline.tracksForSection(TimelineTrackSection.audio), isEmpty);
    expect(
      timeline.tracksForSection(TimelineTrackSection.baseVideo).single.clips,
      [baseClip],
    );
  });

  test('caption generation repairs mixed lanes into one lane per source', () {
    TimelineClip source(String id, String label) => TimelineClip(
      id: id,
      trackId: 'overlay-track',
      type: TimelineTrackType.video,
      label: label,
      startTime: Duration.zero,
      endTime: const Duration(seconds: 5),
    );

    TimelineClip caption(String id, String sourceId, int startMs) =>
        TimelineClip.fromSubtitleEntry(
          SubtitleEntry(
            id: id,
            startTime: Duration(milliseconds: startMs),
            endTime: Duration(milliseconds: startMs + 500),
            text: id,
          ),
          trackId: 'captions-a',
          linkedClipId: sourceId,
        );

    final sourceA = source('video-a', 'Interview A');
    final sourceB = source('video-b', 'Interview B');
    final mixedTrack = TimelineTrack(
      id: 'captions-a',
      name: 'Legacy captions',
      type: TimelineTrackType.subtitle,
      section: TimelineTrackSection.textSubtitle,
      clips: [
        caption('caption-a', sourceA.id, 0),
        caption('old-caption-b', sourceB.id, 700),
      ],
    );
    final timeline = EditorTimeline(tracks: [mixedTrack]);

    final routing = resolveCaptionTrackRouting(
      timeline: timeline,
      sourceClip: sourceB,
    );
    expect(routing.isBlocked, isFalse);
    expect(routing.destination!.id, isNot(mixedTrack.id));

    final repaired = replaceGeneratedCaptionsForSource(
      timeline: timeline,
      sourceClip: sourceB,
      destinationTrack: routing.destination!,
      generatedEntries: [
        SubtitleEntry(
          id: 'new-caption-b',
          startTime: const Duration(seconds: 1),
          endTime: const Duration(seconds: 2),
          text: 'B caption',
        ),
      ],
    );
    final captionTracks = repaired.tracks
        .where((track) => track.type == TimelineTrackType.subtitle)
        .toList();
    final trackA = captionTracks.singleWhere(
      (track) => track.clips.any((clip) => clip.linkedClipId == sourceA.id),
    );
    final trackB = captionTracks.singleWhere(
      (track) => track.clips.any((clip) => clip.linkedClipId == sourceB.id),
    );

    expect(trackA.clips.map((clip) => clip.id), ['caption-a']);
    expect(trackB.id, routing.destination!.id);
    expect(trackB.name, 'Captions · Interview B');
    expect(trackB.clips.map((clip) => clip.id), ['new-caption-b']);
    expect(trackB.clips.single.linkedClipId, sourceB.id);
  });

  test('overlay captions never fall back to the base media path', () {
    final base = TimelineClip(
      id: 'base-video',
      trackId: 'base-track',
      type: TimelineTrackType.video,
      label: 'Base',
      startTime: Duration.zero,
      endTime: const Duration(seconds: 4),
    );
    final overlay = TimelineClip(
      id: 'overlay-video',
      trackId: 'overlay-track',
      type: TimelineTrackType.video,
      label: 'Overlay',
      startTime: Duration.zero,
      endTime: const Duration(seconds: 4),
    );
    final timeline = EditorTimeline(
      tracks: [
        TimelineTrack(
          id: 'overlay-track',
          name: 'Overlay',
          type: TimelineTrackType.video,
          section: TimelineTrackSection.overlay,
          clips: [overlay],
        ),
        TimelineTrack(
          id: 'base-track',
          name: 'Base layer',
          type: TimelineTrackType.video,
          section: TimelineTrackSection.baseVideo,
          clips: [base],
        ),
      ],
    );

    expect(
      resolveCaptionMediaPath(
        timeline: timeline,
        sourceClip: overlay,
        legacyBaseVideoPath: 'base.mp4',
      ),
      isEmpty,
    );
    expect(
      resolveCaptionMediaPath(
        timeline: timeline,
        sourceClip: base,
        legacyBaseVideoPath: 'base.mp4',
      ),
      'base.mp4',
    );
  });

  test('exact separated audio follows transport edits and video splits', () {
    final video = TimelineClip(
      id: 'video',
      trackId: 'video-track',
      type: TimelineTrackType.video,
      label: 'Video',
      assetId: 'asset',
      startTime: Duration.zero,
      endTime: const Duration(seconds: 8),
      sourceStartTime: Duration.zero,
      sourceDuration: const Duration(seconds: 8),
    );
    final audio = TimelineClip(
      id: 'audio',
      trackId: 'audio-track',
      type: TimelineTrackType.audio,
      label: 'Video audio',
      assetId: 'asset',
      linkedClipId: video.id,
      startTime: video.startTime,
      endTime: video.endTime,
      sourceStartTime: video.sourceStartTime,
      sourceDuration: video.sourceDuration,
      audioMix: const AudioMixSettings(
        volume: 0.65,
        fadeInMs: 300,
        fadeOutMs: 450,
      ),
      autoDuck: true,
      duckAmount: 0.4,
      denoise: true,
      keyframes: [
        TimelineKeyframe(
          time: Duration(seconds: 2),
          property: TimelineKeyframeProperty.volume,
          value: 0.5,
        ),
        TimelineKeyframe(
          time: Duration(seconds: 6),
          property: TimelineKeyframeProperty.volume,
          value: 0.9,
        ),
      ],
    );
    expect(
      isExactSeparatedAudioTransportMirror(video: video, audio: audio),
      isTrue,
    );
    final audioOwner = resolveEffectiveAudioOwner(
      timeline: EditorTimeline(
        tracks: [
          TimelineTrack(
            id: 'video-track',
            name: 'Base layer',
            type: TimelineTrackType.video,
            section: TimelineTrackSection.baseVideo,
            clips: [
              video.copyWith(audioMix: video.audioMix.copyWith(muted: true)),
            ],
          ),
          TimelineTrack(
            id: 'audio-track',
            name: 'Audio',
            type: TimelineTrackType.audio,
            section: TimelineTrackSection.audio,
            clips: [audio],
          ),
        ],
      ),
      clip: video,
    );
    expect(audioOwner?.clip.id, audio.id);
    expect(
      isExactSeparatedAudioTransportMirror(
        video: video,
        audio: audio.copyWith(startTime: const Duration(milliseconds: 50)),
      ),
      isFalse,
    );

    final spedVideo = video.copyWith(
      endTime: const Duration(seconds: 4),
      playbackRate: 2,
    );
    final spedAudio = syncSeparatedAudioTransport(
      audio: audio,
      updatedVideo: spedVideo,
    );
    expect(spedAudio.endTime, spedVideo.endTime);
    expect(spedAudio.playbackRate, 2);
    expect(spedAudio.audioMix, audio.audioMix);

    final trimmedVideo = video.copyWith(
      endTime: const Duration(seconds: 4),
      sourceStartTime: const Duration(seconds: 2),
      sourceDuration: const Duration(seconds: 4),
    );
    final trimmedAudio = syncSeparatedAudioTransport(
      audio: audio,
      updatedVideo: trimmedVideo,
    );
    expect(trimmedAudio.sourceStartTime, const Duration(seconds: 2));
    expect(trimmedAudio.sourceDuration, const Duration(seconds: 4));

    final reversedAudio = syncSeparatedAudioTransport(
      audio: audio,
      updatedVideo: video.copyWith(isReversed: true),
    );
    expect(reversedAudio.isReversed, isTrue);

    final leftVideo = video.copyWith(
      endTime: const Duration(seconds: 4),
      sourceDuration: const Duration(seconds: 4),
    );
    final rightVideo = video.copyWith(
      id: 'video-right',
      startTime: const Duration(seconds: 4),
      sourceStartTime: const Duration(seconds: 4),
      sourceDuration: const Duration(seconds: 4),
    );
    final split = splitExactSeparatedAudioMirror(
      originalVideo: video,
      leftVideo: leftVideo,
      rightVideo: rightVideo,
      audio: audio,
      rightAudioId: 'audio-right',
      splitAt: const Duration(seconds: 4),
    );
    expect(split.left.linkedClipId, video.id);
    expect(split.left.endTime, const Duration(seconds: 4));
    expect(split.left.sourceDuration, const Duration(seconds: 4));
    expect(split.left.audioMix.fadeOutMs, 0);
    expect(split.right.id, 'audio-right');
    expect(split.right.linkedClipId, rightVideo.id);
    expect(split.right.startTime, const Duration(seconds: 4));
    expect(split.right.sourceStartTime, const Duration(seconds: 4));
    expect(split.right.audioMix.fadeInMs, 0);
    expect(split.right.keyframes.first.time, Duration.zero);

    final duplicate = restoreAttachedAudioForDuplicate(
      duplicateVideo: video.copyWith(id: 'duplicate'),
      separatedAudio: audio,
    );
    expect(duplicate.audioMix, audio.audioMix);
    expect(duplicate.autoDuck, isTrue);
    expect(duplicate.duckAmount, 0.4);
    expect(duplicate.denoise, isTrue);
  });

  test('subtitle insertion never falls back to a text lane', () {
    final textTrack = TimelineTrack(
      id: 'text',
      name: 'Text',
      type: TimelineTrackType.text,
      section: TimelineTrackSection.textSubtitle,
    );
    final lockedSubtitleTrack = TimelineTrack(
      id: 'locked-subtitles',
      name: 'Locked subtitles',
      type: TimelineTrackType.subtitle,
      section: TimelineTrackSection.textSubtitle,
      isLocked: true,
    );
    final subtitleTrack = TimelineTrack(
      id: 'subtitles',
      name: 'Subtitles',
      type: TimelineTrackType.subtitle,
      section: TimelineTrackSection.textSubtitle,
    );
    final timeline = EditorTimeline(
      tracks: [textTrack, lockedSubtitleTrack, subtitleTrack],
    );

    expect(
      timeline.insertionTrackFor(
        section: TimelineTrackSection.textSubtitle,
        clipType: TimelineTrackType.subtitle,
        preferredTrackId: textTrack.id,
      ),
      same(subtitleTrack),
    );
    expect(
      EditorTimeline(tracks: [textTrack, subtitleTrack]).insertionTrackFor(
        section: TimelineTrackSection.textSubtitle,
        clipType: TimelineTrackType.subtitle,
        preferredTrackId: textTrack.id,
      ),
      same(subtitleTrack),
    );
    expect(
      EditorTimeline(
        tracks: [textTrack, lockedSubtitleTrack],
      ).insertionTrackFor(
        section: TimelineTrackSection.textSubtitle,
        clipType: TimelineTrackType.subtitle,
        preferredTrackId: textTrack.id,
      ),
      isNull,
    );
  });

  testWidgets('dock stays navigable while clip tools respect lock state', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    final container = ProviderContainer(
      overrides: [currentUserProvider.overrideWithValue(null)],
    );
    addTearDown(container.dispose);
    final project = _lockedVideoProject();

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.darkTheme,
          home: EditorScreen(project: project),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));

    container.read(editorProvider.notifier)
      ..selectTrack('locked-video')
      ..selectClip('locked-clip');
    await tester.pump();

    InkWell keyedInkWell(String key) {
      final inkWellFinder = find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(InkWell),
      );
      expect(inkWellFinder, findsOneWidget);
      return tester.widget<InkWell>(inkWellFinder.first);
    }

    Future<void> finishDockTransition() async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));
    }

    for (final category in const [
      'edit',
      'effects',
      'audio',
      'text',
      'timeline',
      'canvas',
      'studio',
      'discover',
    ]) {
      expect(keyedInkWell('dock_category_$category').onTap, isNotNull);
    }

    final dock = find.byKey(const ValueKey('editor_tool_dock'));
    for (final duplicate in const ['Overlay', 'Add Text', 'Split']) {
      expect(
        find.descendant(of: dock, matching: find.text(duplicate)),
        findsNothing,
      );
    }

    await tester.tap(find.byKey(const ValueKey('dock_category_effects')));
    await finishDockTransition();
    expect(keyedInkWell('dock_subgroup_effectsColor').onTap, isNotNull);
    await tester.tap(find.byKey(const ValueKey('dock_subgroup_effectsColor')));
    await finishDockTransition();
    expect(
      keyedInkWell('dock_tool_effects_effectsColor_chroma_key').onTap,
      isNull,
    );
    expect(keyedInkWell('dock_tool_effects_effectsColor_adjust').onTap, isNull);
    // Blur/filter additions are timeline-wide and stay available even when
    // the selected source track is locked.
    expect(
      keyedInkWell('dock_tool_effects_effectsColor_filters').onTap,
      isNotNull,
    );
    expect(keyedInkWell('dock_back_button').onTap, isNotNull);

    await tester.tap(find.byKey(const ValueKey('dock_back_button')));
    await finishDockTransition();
    await tester.tap(find.byKey(const ValueKey('dock_back_button')));
    await finishDockTransition();
    await tester.tap(find.byKey(const ValueKey('dock_category_edit')));
    await finishDockTransition();
    expect(keyedInkWell('dock_subgroup_editTiming').onTap, isNotNull);
    await tester.tap(find.byKey(const ValueKey('dock_subgroup_editTiming')));
    await finishDockTransition();
    expect(keyedInkWell('dock_tool_edit_editTiming_timing').onTap, isNull);
    expect(keyedInkWell('dock_tool_edit_editTiming_freeze').onTap, isNull);
    expect(find.text('Add'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('visual dock exposes live chroma key for overlay media', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    final container = ProviderContainer(
      overrides: [currentUserProvider.overrideWithValue(null)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.darkTheme,
          home: EditorScreen(project: _chromaOverlayProject()),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 650));

    container.read(editorProvider.notifier)
      ..selectTrack('overlay_track')
      ..selectClip('overlay_image');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('dock_category_effects')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));
    await tester.tap(find.byKey(const ValueKey('dock_subgroup_effectsColor')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));

    final chromaTool = find.descendant(
      of: find.byKey(
        const ValueKey('dock_tool_effects_effectsColor_chroma_key'),
      ),
      matching: find.byType(InkWell),
    );
    expect(tester.widget<InkWell>(chromaTool.first).onTap, isNotNull);
    await tester.ensureVisible(chromaTool.first);
    await tester.tap(chromaTool.first);
    await tester.pumpAndSettle();

    expect(find.text('Chroma key'), findsOneWidget);
    expect(find.byKey(const ValueKey('fixed_editor_sheet')), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Use #0000FF as chroma key'));
    await tester.pump();

    final updated = container
        .read(editorProvider)
        .timeline
        .tracks
        .expand((track) => track.clips)
        .singleWhere((clip) => clip.id == 'overlay_image');
    expect(updated.chromaKeyEnabled, isTrue);
    expect(updated.chromaKeyColor, const Color(0xFF0000FF));
    expect(tester.takeException(), isNull);
  });

  testWidgets('audio controls retain a copyable SFX attribution', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    final container = ProviderContainer(
      overrides: [currentUserProvider.overrideWithValue(null)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.darkTheme,
          home: EditorScreen(project: _attributedAudioProject()),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 650));

    container.read(editorProvider.notifier)
      ..selectTrack('sfx-track')
      ..selectClip('sfx-clip');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('dock_category_audio')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));
    await tester.tap(find.byKey(const ValueKey('dock_subgroup_audioMix')));
    await tester.pumpAndSettle();

    expect(find.text('Audio Clip Controls'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('audio-clip-attribution')),
      findsOneWidget,
    );
    expect(
      find.text('Door hit by Field Recordist (CC BY 4.0)'),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('copy-audio-attribution')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('relink-separated-audio')), findsNothing);
    expect(
      find.byKey(const ValueKey('reattach-separated-audio')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('video audio stays attached until the user separates it', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    final container = ProviderContainer(
      overrides: [currentUserProvider.overrideWithValue(null)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.darkTheme,
          home: EditorScreen(project: _audibleVideoProject()),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 650));

    final initialTimeline = container.read(editorProvider).timeline;
    expect(
      initialTimeline.tracks.any(
        (track) => track.section == TimelineTrackSection.audio,
      ),
      isFalse,
    );
    container.read(editorProvider.notifier)
      ..selectTrack('base-track')
      ..selectClip('base-video');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('dock_category_audio')));
    await tester.pump(const Duration(milliseconds: 260));
    await tester.tap(find.byKey(const ValueKey('dock_subgroup_audioMix')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('separate-video-audio')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('separate-video-audio')));
    await tester.pump();

    final separatedTimeline = container.read(editorProvider).timeline;
    final video = separatedTimeline.tracks
        .expand((track) => track.clips)
        .singleWhere((clip) => clip.id == 'base-video');
    final audioTrack = separatedTimeline.tracks.singleWhere(
      (track) =>
          track.section == TimelineTrackSection.audio &&
          track.role == TimelineTrackRole.regular,
    );
    expect(video.audioMix.muted, isTrue);
    expect(video.embeddedAudioSeparated, isTrue);
    expect(audioTrack.clips, hasLength(1));
    expect(audioTrack.clips.single.linkedClipId, video.id);
    expect(audioTrack.clips.single.separatedAudioSourceClipId, video.id);
    expect(audioTrack.clips.single.audioMix.muted, isFalse);
    expect(find.byKey(const ValueKey('separate-video-audio')), findsNothing);
    expect(
      find.byKey(const ValueKey('edit-separated-video-audio')),
      findsOneWidget,
    );
    expect(find.text('Unmute'), findsNothing);
    expect(find.textContaining('prevent duplicate playback'), findsOneWidget);

    final editor = container.read(editorProvider.notifier);
    expect(container.read(editorProvider).canUndo, isTrue);
    editor.undo();
    await tester.pump();
    final undoneTimeline = container.read(editorProvider).timeline;
    expect(
      undoneTimeline.tracks.any(
        (track) => track.section == TimelineTrackSection.audio,
      ),
      isFalse,
    );
    expect(
      undoneTimeline.tracks
          .expand((track) => track.clips)
          .singleWhere((clip) => clip.id == video.id)
          .embeddedAudioSeparated,
      isFalse,
    );
    editor.redo();
    await tester.pump();
    expect(
      container
          .read(editorProvider)
          .timeline
          .tracks
          .expand((track) => track.clips)
          .singleWhere((clip) => clip.id == video.id)
          .embeddedAudioSeparated,
      isTrue,
    );
    expect(
      find.byKey(const ValueKey('edit-separated-video-audio')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('edit-separated-video-audio')));
    await tester.pumpAndSettle();
    expect(container.read(editorProvider).selectedTrackId, audioTrack.id);
    expect(
      container.read(editorProvider).selectedClipId,
      audioTrack.clips.single.id,
    );
    expect(tester.takeException(), isNull);
  });
}

Project _lockedVideoProject() {
  const duration = Duration(seconds: 8);
  const sourcePath = 'locked-source.mp4';
  final asset = EditorAssetReference(
    id: 'locked-asset',
    type: EditorAssetType.video,
    label: 'Locked source',
    sourcePath: sourcePath,
    metadata: const {'durationMs': 8000, 'hasAudio': true},
  );
  final timeline = EditorTimeline(
    assets: [asset],
    tracks: [
      TimelineTrack(
        id: 'locked-video',
        name: 'Video',
        type: TimelineTrackType.video,
        section: TimelineTrackSection.baseVideo,
        isLocked: true,
        clips: [
          TimelineClip(
            id: 'locked-clip',
            trackId: 'locked-video',
            type: TimelineTrackType.video,
            label: 'Locked source',
            assetId: asset.id,
            startTime: Duration.zero,
            endTime: duration,
            sourceDuration: duration,
          ),
        ],
      ),
    ],
  );
  return Project(
    id: 'locked-project',
    name: 'Locked project',
    videoPath: sourcePath,
    durationMs: duration.inMilliseconds,
    timeline: timeline,
  )..cacheVideoAvailability(true);
}

Project _chromaOverlayProject() {
  const duration = Duration(seconds: 8);
  final videoAsset = EditorAssetReference(
    id: 'source_asset',
    type: EditorAssetType.video,
    label: 'Source',
    sourcePath: 'missing-source.mp4',
    metadata: const {'durationMs': 8000, 'hasAudio': false},
  );
  final imageAsset = EditorAssetReference(
    id: 'overlay_asset',
    type: EditorAssetType.image,
    label: 'Green-screen overlay',
    sourcePath: 'missing-overlay.png',
  );
  final timeline = EditorTimeline(
    assets: [videoAsset, imageAsset],
    tracks: [
      TimelineTrack(
        id: 'overlay_track',
        name: 'Overlay',
        type: TimelineTrackType.video,
        section: TimelineTrackSection.overlay,
        clips: [
          TimelineClip(
            id: 'overlay_image',
            trackId: 'overlay_track',
            type: TimelineTrackType.image,
            label: 'Green-screen overlay',
            assetId: imageAsset.id,
            startTime: Duration.zero,
            endTime: duration,
            sourceDuration: duration,
          ),
        ],
      ),
      TimelineTrack(
        id: 'source_track',
        name: 'Source video',
        type: TimelineTrackType.video,
        section: TimelineTrackSection.baseVideo,
        role: TimelineTrackRole.sourceVideo,
        clips: [
          TimelineClip(
            id: 'source_clip',
            trackId: 'source_track',
            type: TimelineTrackType.video,
            label: 'Source',
            assetId: videoAsset.id,
            startTime: Duration.zero,
            endTime: duration,
            sourceDuration: duration,
          ),
        ],
      ),
    ],
  );
  return Project(
    id: 'chroma-overlay-project',
    name: 'Chroma overlay project',
    videoPath: 'missing-source.mp4',
    durationMs: duration.inMilliseconds,
    timeline: timeline,
  )..cacheVideoAvailability(true);
}

Project _audibleVideoProject() {
  const duration = Duration(seconds: 6);
  final asset = EditorAssetReference(
    id: 'base-asset',
    type: EditorAssetType.video,
    label: 'Base clip',
    sourcePath: 'missing-base.mp4',
    metadata: const {'durationMs': 6000, 'hasAudio': true},
  );
  final timeline = EditorTimeline(
    assets: [asset],
    tracks: [
      TimelineTrack(
        id: 'base-track',
        name: 'Base layer',
        type: TimelineTrackType.video,
        section: TimelineTrackSection.baseVideo,
        clips: [
          TimelineClip(
            id: 'base-video',
            trackId: 'base-track',
            type: TimelineTrackType.video,
            label: 'Base clip',
            assetId: asset.id,
            startTime: Duration.zero,
            endTime: duration,
            sourceDuration: duration,
          ),
        ],
      ),
    ],
  );
  return Project(
    id: 'audible-video-project',
    name: 'Audible video',
    videoPath: 'missing-base.mp4',
    durationMs: duration.inMilliseconds,
    timeline: timeline,
  )..cacheVideoAvailability(true);
}

Project _attributedAudioProject() {
  const duration = Duration(seconds: 4);
  final videoAsset = EditorAssetReference(
    id: 'attribution-video-asset',
    type: EditorAssetType.video,
    label: 'Source',
    sourcePath: 'missing-source.mp4',
    metadata: const {'durationMs': 4000, 'hasAudio': false},
  );
  final audioAsset = EditorAssetReference(
    id: 'attribution-sfx-asset',
    type: EditorAssetType.audio,
    label: 'Door hit',
    sourcePath: 'missing-door-hit.mp3',
    metadata: const {
      'durationMs': 1200,
      'hasAudio': true,
      'provider': 'openverse',
      'license': 'by',
      'attribution': 'Door hit by Field Recordist (CC BY 4.0)',
    },
  );
  final timeline = EditorTimeline(
    assets: [videoAsset, audioAsset],
    tracks: [
      TimelineTrack(
        id: 'source-track',
        name: 'Source video',
        type: TimelineTrackType.video,
        section: TimelineTrackSection.baseVideo,
        role: TimelineTrackRole.sourceVideo,
        clips: [
          TimelineClip(
            id: 'source-clip',
            trackId: 'source-track',
            type: TimelineTrackType.video,
            label: 'Source',
            assetId: videoAsset.id,
            startTime: Duration.zero,
            endTime: duration,
            sourceDuration: duration,
          ),
        ],
      ),
      TimelineTrack(
        id: 'sfx-track',
        name: 'Sound effects',
        type: TimelineTrackType.audio,
        section: TimelineTrackSection.audio,
        clips: [
          TimelineClip(
            id: 'sfx-clip',
            trackId: 'sfx-track',
            type: TimelineTrackType.audio,
            label: 'Door hit',
            assetId: audioAsset.id,
            startTime: Duration.zero,
            endTime: const Duration(milliseconds: 1200),
            sourceDuration: const Duration(milliseconds: 1200),
          ),
        ],
      ),
    ],
  );
  return Project(
    id: 'attributed-audio-project',
    name: 'Attributed audio project',
    videoPath: 'missing-source.mp4',
    durationMs: duration.inMilliseconds,
    timeline: timeline,
  )..cacheVideoAvailability(true);
}
