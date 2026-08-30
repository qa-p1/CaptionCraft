import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../../features/editor/models/editor_effect_models.dart';

class EffectPresetLibraryService {
  final Future<Directory> Function() _rootProvider;

  EffectPresetLibraryService({Future<Directory> Function()? rootProvider})
    : _rootProvider = rootProvider ?? _defaultRoot;

  static const int fileFormatVersion = 1;
  static const int _maximumPresetBytes = 16 * 1024 * 1024;
  static const int _maximumLibraryEntries = 500;

  Future<List<EditorEffectPreset>> load() async {
    final file = await _libraryFile();
    if (!await file.exists()) return const [];
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map || decoded['presets'] is! List) return const [];
      final presets = <EditorEffectPreset>[];
      for (final value in decoded['presets'] as List) {
        if (value is! Map) continue;
        try {
          final preset = EditorEffectPreset.fromJson(
            Map<String, dynamic>.from(value),
          );
          if (preset.stack.isNotEmpty) presets.add(preset);
        } catch (_) {
          // One damaged entry must not hide the rest of the local library.
        }
      }
      presets.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return List.unmodifiable(presets.take(_maximumLibraryEntries));
    } catch (_) {
      return const [];
    }
  }

  Future<void> save(EditorEffectPreset preset) async {
    if (preset.stack.isEmpty) {
      throw ArgumentError('An effect preset cannot be empty.');
    }
    final presets = [...await load()]
      ..removeWhere((candidate) => candidate.id == preset.id)
      ..insert(0, preset);
    await _writeLibrary(presets.take(_maximumLibraryEntries).toList());
  }

  Future<void> delete(String presetId) async {
    final presets = [...await load()]
      ..removeWhere((candidate) => candidate.id == presetId);
    await _writeLibrary(presets);
  }

  Future<void> exportPreset({
    required EditorEffectPreset preset,
    required String outputPath,
  }) async {
    final embeddedAssets = <Map<String, dynamic>>[];
    for (final effect in preset.stack.effects) {
      if (effect.type != EditorEffectType.lut) continue;
      final sourcePath = effect.parameters['path']?.toString().trim();
      if (sourcePath == null || sourcePath.isEmpty) continue;
      final file = File(sourcePath);
      if (!await file.exists()) continue;
      final bytes = await file.readAsBytes();
      if (bytes.length > _maximumPresetBytes) {
        throw StateError('The LUT in this preset is too large to embed.');
      }
      embeddedAssets.add({
        'effectId': effect.id,
        'fileName': path.basename(file.path),
        'bytes': base64Encode(bytes),
      });
    }
    final payload = jsonEncode({
      'format': 'captioncraft.effectPreset',
      'version': fileFormatVersion,
      'preset': preset.toJson(),
      'assets': embeddedAssets,
    });
    if (utf8.encode(payload).length > _maximumPresetBytes) {
      throw StateError('The exported preset exceeds 16 MB.');
    }
    final output = File(outputPath);
    await output.parent.create(recursive: true);
    await output.writeAsString(payload, flush: true);
  }

  Future<EditorEffectPreset> importPreset(String sourcePath) async {
    final source = File(sourcePath);
    if (!await source.exists()) throw ArgumentError('Preset file not found.');
    if (await source.length() > _maximumPresetBytes) {
      throw const FormatException('Preset files must be 16 MB or smaller.');
    }
    final decoded = jsonDecode(await source.readAsString());
    if (decoded is! Map ||
        decoded['format'] != 'captioncraft.effectPreset' ||
        decoded['version'] != fileFormatVersion ||
        decoded['preset'] is! Map) {
      throw const FormatException(
        'This is not a supported CaptionCraft preset.',
      );
    }
    final imported = EditorEffectPreset.fromJson(
      Map<String, dynamic>.from(decoded['preset'] as Map),
    );
    if (imported.stack.isEmpty) {
      throw const FormatException('The imported effect stack is empty.');
    }
    final preset = EditorEffectPreset(
      name: imported.name,
      description: imported.description,
      stack: imported.stack,
    );
    final root = await _rootProvider();
    final assetRoot = Directory(path.join(root.path, 'assets', preset.id));
    final assetPaths = <String, String>{};
    final rawAssets = decoded['assets'];
    if (rawAssets is List) {
      for (final value in rawAssets) {
        if (value is! Map) continue;
        final effectId = value['effectId']?.toString();
        final encoded = value['bytes']?.toString();
        if (effectId == null || encoded == null) continue;
        final bytes = base64Decode(encoded);
        final safeName = path
            .basename(value['fileName']?.toString() ?? '$effectId.cube')
            .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
        await assetRoot.create(recursive: true);
        final output = File(path.join(assetRoot.path, safeName));
        await output.writeAsBytes(bytes, flush: true);
        assetPaths[effectId] = output.path;
      }
    }
    final resolved = EditorEffectPreset(
      id: preset.id,
      name: preset.name,
      description: preset.description,
      stack: preset.stack.copyWith(
        effects: preset.stack.effects.map((effect) {
          final resolvedPath = assetPaths[effect.id];
          return resolvedPath == null
              ? effect
              : effect.copyWith(
                  parameters: {...effect.parameters, 'path': resolvedPath},
                );
        }).toList(),
      ),
      createdAt: preset.createdAt,
    );
    await save(resolved);
    return resolved;
  }

  Future<File> _libraryFile() async {
    final root = await _rootProvider();
    return File(path.join(root.path, 'effect_presets.json'));
  }

  Future<void> _writeLibrary(List<EditorEffectPreset> presets) async {
    final file = await _libraryFile();
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({
        'version': fileFormatVersion,
        'presets': presets.map((preset) => preset.toJson()).toList(),
      }),
      flush: true,
    );
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }

  static Future<Directory> _defaultRoot() async {
    final support = await getApplicationSupportDirectory();
    return Directory(path.join(support.path, 'effect_preset_library'));
  }
}
