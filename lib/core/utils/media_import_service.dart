import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Moves picker-backed media out of temporary provider/cache locations before
/// its path is persisted in a project.
class MediaImportService {
  MediaImportService._();

  static const String _mediaDirectoryName = 'media';
  static const String _productDirectoryName = 'CaptionCraft';

  /// Returns a durable path for [sourcePath].
  ///
  /// Android and iOS picker results are copied into application Documents.
  /// Desktop picker paths already point at user-managed files and pass through.
  /// Supplying [documentsDirectoryOverride] enables the mobile copy behavior in
  /// tests without invoking the path-provider platform channel.
  static Future<String> persistFile(
    String sourcePath, {
    String? originalFileName,
    @visibleForTesting Directory? documentsDirectoryOverride,
  }) async {
    if (sourcePath.trim().isEmpty) {
      throw ArgumentError.value(sourcePath, 'sourcePath', 'Cannot be empty.');
    }
    final normalizedSourcePath = p.normalize(p.absolute(sourcePath.trim()));

    final source = File(normalizedSourcePath);
    if (!await source.exists()) {
      throw FileSystemException(
        'Selected media file does not exist.',
        sourcePath,
      );
    }
    final sourceLength = await source.length();
    if (sourceLength == 0) {
      throw FileSystemException('Selected media file is empty.', sourcePath);
    }

    final shouldPersist =
        documentsDirectoryOverride != null ||
        Platform.isAndroid ||
        Platform.isIOS;
    if (!shouldPersist) return normalizedSourcePath;

    final documentsDirectory =
        documentsDirectoryOverride ?? await getApplicationDocumentsDirectory();
    final mediaDirectory = Directory(
      p.join(
        documentsDirectory.path,
        _productDirectoryName,
        _mediaDirectoryName,
      ),
    );
    await mediaDirectory.create(recursive: true);

    final normalizedMediaDirectory = p.normalize(
      p.absolute(mediaDirectory.path),
    );
    if (p.equals(normalizedSourcePath, normalizedMediaDirectory) ||
        p.isWithin(normalizedMediaDirectory, normalizedSourcePath)) {
      return normalizedSourcePath;
    }

    final safeFileName = _safeFileName(
      originalFileName?.trim().isNotEmpty == true
          ? originalFileName!
          : p.basename(normalizedSourcePath),
    );
    final extension = p.extension(safeFileName);
    final stem = p.basenameWithoutExtension(safeFileName);
    final uniqueSuffix = DateTime.now().microsecondsSinceEpoch;
    var destinationPath = p.join(
      normalizedMediaDirectory,
      '${stem}_$uniqueSuffix$extension',
    );
    var collisionIndex = 1;
    while (await File(destinationPath).exists()) {
      destinationPath = p.join(
        normalizedMediaDirectory,
        '${stem}_${uniqueSuffix}_$collisionIndex$extension',
      );
      collisionIndex++;
    }

    final partialPath = '$destinationPath.part';
    try {
      await source.copy(partialPath);
      final partialFile = File(partialPath);
      if (!await partialFile.exists() ||
          await partialFile.length() != sourceLength) {
        throw const FileSystemException('Could not copy the selected media.');
      }
      await partialFile.rename(destinationPath);
      return destinationPath;
    } catch (_) {
      try {
        final partialFile = File(partialPath);
        if (await partialFile.exists()) await partialFile.delete();
      } catch (_) {
        // Preserve the import failure; partial cleanup is best-effort.
      }
      rethrow;
    }
  }

  static String _safeFileName(String candidate) {
    final basename = p.basename(candidate);
    final extension = p
        .extension(basename)
        .replaceAll(RegExp(r'[^A-Za-z0-9.]'), '')
        .toLowerCase();
    var stem = p
        .basenameWithoutExtension(basename)
        .replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '_')
        .trim();
    if (stem.isEmpty) stem = 'media';
    if (stem.length > 80) stem = stem.substring(0, 80).trim();
    return '$stem$extension';
  }
}
