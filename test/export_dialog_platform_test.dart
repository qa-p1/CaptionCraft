import 'dart:io';

import 'package:caption_craft/core/theme/app_theme.dart';
import 'package:caption_craft/features/editor/models/export_settings.dart';
import 'package:caption_craft/features/editor/widgets/export_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'desktop exports never offer or request mobile gallery delivery',
    (tester) async {
      final supportsGallery = Platform.isAndroid || Platform.isIOS;
      ExportSettings? submitted;

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.darkTheme,
          home: Scaffold(
            body: ExportDialog(onExport: (settings) => submitted = settings),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Copy to gallery'),
        supportsGallery ? findsOneWidget : findsNothing,
      );
      await tester.tap(find.text('Render video'));
      await tester.pump();

      expect(submitted, isNotNull);
      expect(submitted!.saveToGallery, supportsGallery);
      expect(tester.takeException(), isNull);
    },
  );
}
