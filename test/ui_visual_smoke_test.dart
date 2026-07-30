import 'dart:async';

import 'package:caption_craft/core/theme/app_theme.dart';
import 'package:caption_craft/features/auth/screens/login_screen.dart';
import 'package:caption_craft/features/auth/providers/auth_provider.dart';
import 'package:caption_craft/features/editor/models/subtitle_entry.dart';
import 'package:caption_craft/features/editor/models/timeline_models.dart';
import 'package:caption_craft/features/home/screens/home_screen.dart';
import 'package:caption_craft/features/home/screens/processing_screen.dart';
import 'package:caption_craft/features/quota/providers/quota_provider.dart';
import 'package:caption_craft/features/quota/screens/quota_exhausted_screen.dart';
import 'package:caption_craft/shared/models/processing_state.dart';
import 'package:caption_craft/shared/models/project_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  Future<void> pumpLogin(WidgetTester tester, {required Size size}) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.darkTheme,
          home: const LoginScreen(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('login studio has a complete desktop layout', (tester) async {
    await pumpLogin(tester, size: const Size(1280, 800));

    expect(find.text('The timeline\nis yours.'), findsOneWidget);
    expect(find.text('Welcome back to the cut.'), findsOneWidget);
    expect(find.text('Enter studio'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('login studio remains usable on a phone', (tester) async {
    await pumpLogin(tester, size: const Size(390, 844));

    expect(find.text('Welcome back to the cut.'), findsOneWidget);
    expect(find.text('Enter studio'), findsOneWidget);
    expect(find.byType(TextFormField), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('captures the desktop studio for visual inspection', (
    tester,
  ) async {
    await pumpLogin(tester, size: const Size(1280, 800));
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/login_studio_desktop.png'),
    );
  });

  testWidgets('home studio is responsive and exposes project tools', (
    tester,
  ) async {
    final projects = _sampleProjects();
    await tester.binding.setSurfaceSize(const Size(1180, 860));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [currentUserProvider.overrideWithValue(null)],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.darkTheme,
          home: HomeScreen(initialProjects: projects),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Make the cut. Own the frame.'), findsOneWidget);
    expect(find.text('Your cuts'), findsOneWidget);
    expect(find.text('Summer launch'), findsOneWidget);
    expect(find.text('City stories'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/home_studio_desktop.png'),
    );
  });

  testWidgets('transcription process remains usable on a phone', (
    tester,
  ) async {
    final progress = StreamController<ProcessingProgress>();
    addTearDown(progress.close);
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.darkTheme,
          home: ProcessingScreen(
            progressStream: progress.stream,
            onCancel: () {},
          ),
        ),
      ),
    );
    progress.add(
      const ProcessingProgress(
        stage: ProcessingStage.transcribing,
        progress: 0.58,
        message: 'Recognizing speech…',
        currentChunk: 2,
        totalChunks: 5,
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Building editable captions'), findsOneWidget);
    expect(find.text('58%'), findsOneWidget);
    expect(find.text('Segment 3 of 5'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('quota limit is honest and keeps editing available', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [quotaProvider.overrideWith((ref) => _TestQuotaNotifier())],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.darkTheme,
          home: const QuotaExhaustedScreen(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.text('Automatic transcription\nlimit reached.'),
      findsOneWidget,
    );
    expect(find.text('Continue editing'), findsOneWidget);
    expect(find.text('Full video export'), findsOneWidget);
    expect(find.text('Upgrade'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

class _TestQuotaNotifier extends QuotaNotifier {
  _TestQuotaNotifier() {
    state = const QuotaState(runsUsed: 3, maxRuns: 3, isLoading: false);
  }
}

List<Project> _sampleProjects() {
  final now = DateTime(2026, 7, 28, 20);
  return List.generate(5, (index) {
    final duration = Duration(seconds: 42 + index * 37);
    final videoAsset = EditorAssetReference(
      id: 'asset_$index',
      type: EditorAssetType.video,
      label: 'Source ${index + 1}',
      sourcePath: 'sample_$index.mp4',
      metadata: {
        'durationMs': duration.inMilliseconds,
        'width': 1920,
        'height': 1080,
        'hasAudio': true,
        'frameRate': 30,
      },
    );
    final subtitles = List.generate(
      3 + index,
      (caption) => SubtitleEntry(
        id: 'subtitle_${index}_$caption',
        startTime: Duration(seconds: caption * 3),
        endTime: Duration(seconds: caption * 3 + 2),
        text: 'Sample caption ${caption + 1}',
      ),
    );
    final timeline = EditorTimeline(
      assets: [videoAsset],
      tracks: [
        TimelineTrack(
          id: 'video_$index',
          name: 'Video 1',
          type: TimelineTrackType.video,
          section: TimelineTrackSection.baseVideo,
          clips: [
            TimelineClip(
              id: 'clip_$index',
              trackId: 'video_$index',
              type: TimelineTrackType.video,
              label: 'Source ${index + 1}',
              assetId: videoAsset.id,
              startTime: Duration.zero,
              endTime: duration,
            ),
          ],
        ),
      ],
    );
    final project = Project(
      id: 'project_$index',
      name: const [
        'Summer launch',
        'City stories',
        'Product reel',
        'Late night cut',
        'Travel diary',
      ][index],
      videoPath: 'sample_$index.mp4',
      durationMs: duration.inMilliseconds,
      subtitles: subtitles,
      timeline: timeline,
      isFavorite: index == 0 || index == 3,
      lastExportPath: index == 1 ? 'last_export.mp4' : null,
      createdAt: now.subtract(Duration(days: index + 1)),
      lastModifiedAt: now.subtract(Duration(hours: index * 9)),
    );
    project.cacheVideoAvailability(index != 4);
    return project;
  });
}
