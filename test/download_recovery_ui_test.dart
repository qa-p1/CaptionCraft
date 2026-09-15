import 'package:caption_craft/features/editor/widgets/discover_downloads_tab.dart';
import 'package:caption_craft/features/editor/screens/teleprompter_screen.dart';
import 'package:caption_craft/features/editor/models/subtitle_entry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'teleprompter ignores empty cues and retains the longest overlapping cue',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: TeleprompterScreen(
            projectName: 'Rehearsal',
            entries: [
              SubtitleEntry(
                text: 'Long cue',
                startTime: Duration.zero,
                endTime: const Duration(seconds: 10),
              ),
              SubtitleEntry(
                text: 'Short cue',
                startTime: const Duration(seconds: 5),
                endTime: const Duration(seconds: 6),
              ),
              SubtitleEntry(
                text: ' ',
                startTime: const Duration(seconds: 15),
                endTime: const Duration(seconds: 20),
              ),
            ],
          ),
        ),
      );
      expect(find.text('1 / 2'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.skip_next_rounded));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        0.5,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'failed download-library loading shows Retry instead of a spinner',
    (tester) async {
      var retries = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DiscoverDownloadsTab(
              downloads: const [],
              isInitialized: false,
              errorMessage: 'Storage unavailable',
              onInitialize: () async {
                retries++;
              },
              onAddToTimeline: (_) async {},
              onCancel: (_) async {},
              onRetry: (_) async {},
              onDelete: (_) async {},
              onOpen: (_) async => false,
            ),
          ),
        ),
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Could not load your downloads.'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Retry'));
      expect(retries, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
