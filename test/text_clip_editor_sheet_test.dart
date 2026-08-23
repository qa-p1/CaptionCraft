import 'package:caption_craft/features/editor/models/subtitle_style_model.dart';
import 'package:caption_craft/features/editor/widgets/text_clip_editor_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'text editor offers live preview, presets, fonts and animations',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(() {
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
      });

      final controller = TextEditingController(text: 'Launch day');
      final focusNode = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focusNode.dispose);
      var style = const SubtitleStyleModel(
        position: SubtitlePosition.center,
        fontSize: 32,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            resizeToAvoidBottomInset: false,
            body: Align(
              alignment: Alignment.bottomCenter,
              child: TextClipEditorSheet(
                title: 'Add text',
                controller: controller,
                focusNode: focusNode,
                initialStyle: style,
                onTextChanged: (_) {},
                onStyleChanged: (next) => style = next,
                onDone: () {},
                onCancel: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));

      expect(
        find.byKey(const ValueKey('text_editor_sample_preview')),
        findsOneWidget,
      );
      expect(textClipStylePresets.length, greaterThanOrEqualTo(6));
      expect(find.text('Clean Title'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('text_editor_preset_Social Pop')),
      );
      await tester.pump();
      expect(style.fontFamily, 'Poppins');
      expect(style.isBold, isTrue);
      expect(style.animationPreset, SubtitleAnimationPreset.wordPop);

      await tester.tap(find.text('Style'));
      await tester.pump(const Duration(milliseconds: 160));
      expect(
        find.byKey(const ValueKey('text_editor_font_Roboto')),
        findsOneWidget,
      );

      await tester.tap(find.text('Animate'));
      await tester.pump(const Duration(milliseconds: 160));
      expect(
        find.byKey(const ValueKey('text_editor_animation_static')),
        findsOneWidget,
      );
      expect(find.text('Bounce In'), findsOneWidget);
      await tester.ensureVisible(find.text('Bounce In'));
      await tester.tap(find.text('Bounce In'));
      await tester.pump();
      expect(style.animationPreset, SubtitleAnimationPreset.bounceIn);
    },
  );

  testWidgets(
    'text editor remains above the keyboard with its preview visible',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(() {
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
      });

      final controller = TextEditingController(text: 'Keyboard-safe title');
      final focusNode = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focusNode.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(390, 844),
              viewInsets: EdgeInsets.only(bottom: 300),
            ),
            child: Scaffold(
              resizeToAvoidBottomInset: false,
              body: Align(
                alignment: Alignment.bottomCenter,
                child: TextClipEditorSheet(
                  title: 'Edit text',
                  controller: controller,
                  focusNode: focusNode,
                  initialStyle: const SubtitleStyleModel(
                    position: SubtitlePosition.center,
                    fontSize: 32,
                  ),
                  onTextChanged: (_) {},
                  onStyleChanged: (_) {},
                  onDone: () {},
                  onCancel: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 150));

      final preview = find.byKey(const ValueKey('text_editor_sample_preview'));
      final sheet = find.byKey(const ValueKey('resizable_editor_sheet'));
      expect(preview, findsOneWidget);
      expect(tester.getRect(preview).height, greaterThanOrEqualTo(80));
      expect(tester.getRect(sheet).bottom, lessThanOrEqualTo(545));
      expect(tester.takeException(), isNull);
    },
  );

  test('style can explicitly return from an animation to static', () {
    const animated = SubtitleStyleModel(
      animationPreset: SubtitleAnimationPreset.zoomIn,
    );

    final staticStyle = animated.copyWith(clearAnimationPreset: true);

    expect(staticStyle.animationPreset, isNull);
    expect(animated.copyWith().animationPreset, SubtitleAnimationPreset.zoomIn);
  });

  test('all text animation choices survive project JSON', () {
    for (final preset in SubtitleAnimationPreset.values) {
      final restored = SubtitleStyleModel.fromJson(
        SubtitleStyleModel(animationPreset: preset).toJson(),
      );
      expect(restored.animationPreset, preset);
    }
  });
}
