import 'dart:async';

import 'package:caption_craft/features/home/screens/processing_screen.dart';
import 'package:caption_craft/shared/models/processing_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('system back asks before cancelling transcription', (
    tester,
  ) async {
    final progress = StreamController<ProcessingProgress>();
    var cancelCount = 0;
    addTearDown(progress.close);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: ProcessingScreen(
            progressStream: progress.stream,
            onCancel: () => cancelCount++,
          ),
        ),
      ),
    );

    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Stop transcription?'), findsOneWidget);
    expect(cancelCount, 0);

    await tester.tap(find.widgetWithText(FilledButton, 'Stop'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(cancelCount, 1);
  });
}
