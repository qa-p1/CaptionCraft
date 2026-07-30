import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// A deterministic on-disk font bundle shared by Flutter preview and libass.
class CaptionFontBundle {
  final String directoryPath;
  final List<String> families;

  const CaptionFontBundle({
    required this.directoryPath,
    required this.families,
  });
}

class CaptionFontService {
  CaptionFontService._();

  static const List<String> supportedFamilies = [
    'Roboto',
    'Inter',
    'Poppins',
    'Montserrat',
    'Playfair Display',
    'Space Mono',
  ];

  static const _bundleVersion = 'v1';
  static const List<_CaptionFontAsset> _fontAssets = [
    _CaptionFontAsset(
      assetPath: 'assets/fonts/Roboto-Variable.ttf',
      fileName: 'Roboto-Variable.ttf',
    ),
    _CaptionFontAsset(
      assetPath: 'assets/fonts/Roboto-Italic-Variable.ttf',
      fileName: 'Roboto-Italic-Variable.ttf',
    ),
    _CaptionFontAsset(
      assetPath: 'assets/fonts/Inter-Variable.ttf',
      fileName: 'Inter-Variable.ttf',
    ),
    _CaptionFontAsset(
      assetPath: 'assets/fonts/Inter-Italic-Variable.ttf',
      fileName: 'Inter-Italic-Variable.ttf',
    ),
    _CaptionFontAsset(
      assetPath: 'assets/fonts/Poppins-Regular.ttf',
      fileName: 'Poppins-Regular.ttf',
    ),
    _CaptionFontAsset(
      assetPath: 'assets/fonts/Poppins-Bold.ttf',
      fileName: 'Poppins-Bold.ttf',
    ),
    _CaptionFontAsset(
      assetPath: 'assets/fonts/Poppins-Italic.ttf',
      fileName: 'Poppins-Italic.ttf',
    ),
    _CaptionFontAsset(
      assetPath: 'assets/fonts/Poppins-BoldItalic.ttf',
      fileName: 'Poppins-BoldItalic.ttf',
    ),
    _CaptionFontAsset(
      assetPath: 'assets/fonts/Montserrat-Variable.ttf',
      fileName: 'Montserrat-Variable.ttf',
    ),
    _CaptionFontAsset(
      assetPath: 'assets/fonts/Montserrat-Italic-Variable.ttf',
      fileName: 'Montserrat-Italic-Variable.ttf',
    ),
    _CaptionFontAsset(
      assetPath: 'assets/fonts/PlayfairDisplay-Variable.ttf',
      fileName: 'PlayfairDisplay-Variable.ttf',
    ),
    _CaptionFontAsset(
      assetPath: 'assets/fonts/PlayfairDisplay-Italic-Variable.ttf',
      fileName: 'PlayfairDisplay-Italic-Variable.ttf',
    ),
    _CaptionFontAsset(
      assetPath: 'assets/fonts/SpaceMono-Regular.ttf',
      fileName: 'SpaceMono-Regular.ttf',
    ),
    _CaptionFontAsset(
      assetPath: 'assets/fonts/SpaceMono-Bold.ttf',
      fileName: 'SpaceMono-Bold.ttf',
    ),
    _CaptionFontAsset(
      assetPath: 'assets/fonts/SpaceMono-Italic.ttf',
      fileName: 'SpaceMono-Italic.ttf',
    ),
    _CaptionFontAsset(
      assetPath: 'assets/fonts/SpaceMono-BoldItalic.ttf',
      fileName: 'SpaceMono-BoldItalic.ttf',
    ),
  ];

  static Future<CaptionFontBundle>? _activePreparation;

  /// Resolves persisted/legacy family names to a font guaranteed in the bundle.
  static String resolveFamily(String family) {
    final normalized = family.trim().toLowerCase();
    for (final supported in supportedFamilies) {
      if (supported.toLowerCase() == normalized) return supported;
    }
    return switch (normalized) {
      'arial' || 'helvetica' || 'sans' || 'sans-serif' => 'Roboto',
      'times' || 'times new roman' || 'serif' => 'Playfair Display',
      'mono' || 'monospace' || 'space mono' => 'Space Mono',
      _ => 'Inter',
    };
  }

  /// Materializes bundled font assets and registers them with FFmpeg fontconfig.
  ///
  /// Android has no default fontconfig configuration, so merely naming a font
  /// in an ASS style can otherwise produce a successful video with no glyphs.
  static Future<CaptionFontBundle> prepareForExport() async {
    final existing = _activePreparation;
    if (existing != null) return existing;

    final preparation = _prepare();
    _activePreparation = preparation;
    try {
      return await preparation;
    } catch (_) {
      if (identical(_activePreparation, preparation)) {
        _activePreparation = null;
      }
      rethrow;
    }
  }

  static Future<CaptionFontBundle> _prepare() async {
    try {
      final supportDirectory = await getApplicationSupportDirectory();
      final fontDirectory = Directory(
        p.join(
          supportDirectory.path,
          'caption_craft',
          'caption_fonts',
          _bundleVersion,
        ),
      );
      await fontDirectory.create(recursive: true);

      for (final asset in _fontAssets) {
        final data = await rootBundle.load(asset.assetPath);
        final bytes = _bytesFromData(data);
        if (bytes.isEmpty) {
          throw StateError('Bundled font is empty: ${asset.assetPath}');
        }
        final outputFile = File(p.join(fontDirectory.path, asset.fileName));
        final isCurrent =
            await outputFile.exists() &&
            await outputFile.length() == bytes.length;
        if (!isCurrent) {
          await outputFile.writeAsBytes(bytes, flush: true);
        }
      }

      final missingFonts = <String>[];
      for (final asset in _fontAssets) {
        final file = File(p.join(fontDirectory.path, asset.fileName));
        if (!await file.exists() || await file.length() == 0) {
          missingFonts.add(asset.fileName);
        }
      }
      if (missingFonts.isNotEmpty) {
        throw StateError(
          'Caption font extraction was incomplete: ${missingFonts.join(', ')}',
        );
      }

      await FFmpegKitConfig.setFontDirectory(fontDirectory.path);
      return CaptionFontBundle(
        directoryPath: fontDirectory.path,
        families: supportedFamilies,
      );
    } catch (error) {
      throw StateError(
        'Caption fonts could not be prepared for video export. '
        'Reopen the app and try again. Details: $error',
      );
    }
  }

  static Uint8List _bytesFromData(ByteData data) {
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }
}

class _CaptionFontAsset {
  final String assetPath;
  final String fileName;

  const _CaptionFontAsset({required this.assetPath, required this.fileName});
}
