import 'dart:io';

import 'package:caption_craft/core/utils/effect_preset_library_service.dart';
import 'package:caption_craft/features/editor/models/editor_effect_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
  test(
    'reusable preset library persists and replaces entries atomically',
    () async {
      final directory = await Directory.systemTemp.createTemp('cc_presets_');
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final service = EffectPresetLibraryService(
        rootProvider: () async => directory,
      );
      final preset = EditorEffectPreset(
        id: 'preset',
        name: 'Glow stack',
        stack: EditorEffectStack(
          effects: [EditorEffect(type: EditorEffectType.glow)],
        ),
      );

      await service.save(preset);
      await service.save(
        EditorEffectPreset(
          id: preset.id,
          name: 'Updated glow stack',
          stack: preset.stack,
        ),
      );
      final restored = await service.load();

      expect(restored, hasLength(1));
      expect(restored.single.id, preset.id);
      expect(restored.single.name, 'Updated glow stack');
      expect(restored.single.stack.effects.single.type, EditorEffectType.glow);

      await service.delete(preset.id);
      expect(await service.load(), isEmpty);
    },
  );

  test(
    'ccfx export embeds LUT data and import restores a portable path',
    () async {
      final sourceRoot = await Directory.systemTemp.createTemp('cc_export_');
      final importRoot = await Directory.systemTemp.createTemp('cc_import_');
      addTearDown(() async {
        if (await sourceRoot.exists()) await sourceRoot.delete(recursive: true);
        if (await importRoot.exists()) await importRoot.delete(recursive: true);
      });
      final lut = File(path.join(sourceRoot.path, 'cinematic.cube'));
      const lutContents = '''
TITLE "Portable LUT"
LUT_3D_SIZE 2
0 0 0
1 0 0
0 1 0
1 1 0
0 0 1
1 0 1
0 1 1
1 1 1
''';
      await lut.writeAsString(lutContents);
      final preset = EditorEffectPreset(
        name: 'Portable grade',
        stack: EditorEffectStack(
          effects: [
            EditorEffect(
              id: 'lut-effect',
              type: EditorEffectType.lut,
              parameters: {'path': lut.path, 'intensity': 0.65},
            ),
            EditorEffect(type: EditorEffectType.bloom),
          ],
        ),
      );
      final exported = path.join(sourceRoot.path, 'portable.ccfx');
      final exportService = EffectPresetLibraryService(
        rootProvider: () async => sourceRoot,
      );
      await exportService.exportPreset(preset: preset, outputPath: exported);

      final importService = EffectPresetLibraryService(
        rootProvider: () async => importRoot,
      );
      final imported = await importService.importPreset(exported);
      final importedLut = imported.stack.effects.singleWhere(
        (effect) => effect.type == EditorEffectType.lut,
      );
      final importedPath = importedLut.parameters['path'] as String;

      expect(imported.id, isNot(preset.id));
      expect(importedLut.parameters['intensity'], 0.65);
      expect(await File(importedPath).exists(), isTrue);
      expect(await File(importedPath).readAsString(), lutContents);
      expect((await importService.load()).single.id, imported.id);
    },
  );

  test(
    'invalid ccfx files are rejected instead of polluting the library',
    () async {
      final directory = await Directory.systemTemp.createTemp('cc_bad_preset_');
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final invalid = File(path.join(directory.path, 'invalid.ccfx'));
      await invalid.writeAsString('{"format":"something-else"}');
      final service = EffectPresetLibraryService(
        rootProvider: () async => directory,
      );

      await expectLater(
        service.importPreset(invalid.path),
        throwsA(isA<FormatException>()),
      );
      expect(await service.load(), isEmpty);
    },
  );
}
