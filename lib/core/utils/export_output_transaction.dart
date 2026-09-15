import 'dart:io';

import 'package:path/path.dart' as p;

/// Renders on the destination volume. The previous video remains intact until
/// the caller has verified the new video and commits it.
class ExportOutputTransaction {
  ExportOutputTransaction._(this.destination, this.directory, this._original);

  final File destination;
  final Directory directory;
  final FileStat? _original;
  bool _committed = false;
  bool _hasBackup = false;

  String get renderPath => p.join(directory.path, 'render.mp4');
  String get _backupPath => p.join(directory.path, 'previous.mp4');

  static Future<ExportOutputTransaction> create(
    String outputPath, {
    required Iterable<String> sourcePaths,
  }) async {
    final destination = File(p.normalize(p.absolute(outputPath)));
    if (p.extension(destination.path).toLowerCase() != '.mp4') {
      throw ArgumentError('Choose an MP4 export destination.');
    }
    await destination.parent.create(recursive: true);
    final parent = await destination.parent.resolveSymbolicLinks();
    final resolvedPath = p.join(parent, p.basename(destination.path));
    final type = await FileSystemEntity.type(
      destination.path,
      followLinks: false,
    );
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.file) {
      throw const FileSystemException(
        'The export destination must be a regular file.',
      );
    }
    for (final sourcePath in sourcePaths.where((path) => path.isNotEmpty)) {
      final source = File(sourcePath);
      final exists = await source.exists();
      final resolved = exists
          ? await source.resolveSymbolicLinks()
          : p.normalize(p.absolute(sourcePath));
      final equal = Platform.isWindows
          ? resolved.toLowerCase() == resolvedPath.toLowerCase()
          : p.equals(resolved, resolvedPath);
      if (equal ||
          (type == FileSystemEntityType.file &&
              exists &&
              await FileSystemEntity.identical(
                source.path,
                destination.path,
              ))) {
        throw const FileSystemException(
          'Choose a destination different from your source media.',
        );
      }
    }
    final original = type == FileSystemEntityType.file
        ? await destination.stat()
        : null;
    final directory = await destination.parent.createTemp(
      '.captioncraft-export-',
    );
    return ExportOutputTransaction._(destination, directory, original);
  }

  Future<void> commit() async {
    if (_committed) throw StateError('This export is already committed.');
    final rendered = File(renderPath);
    if (!await rendered.exists() || await rendered.length() == 0) {
      throw const FileSystemException('The rendered video is empty.');
    }
    final currentType = await FileSystemEntity.type(
      destination.path,
      followLinks: false,
    );
    final current = await destination.stat();
    if ((_original == null && currentType != FileSystemEntityType.notFound) ||
        (_original != null &&
            (currentType != FileSystemEntityType.file ||
                current.size != _original.size ||
                current.modified != _original.modified ||
                current.changed != _original.changed))) {
      throw const FileSystemException(
        'The destination changed during export. Choose another filename and retry.',
      );
    }
    if (_original != null) {
      await destination.rename(_backupPath);
      _hasBackup = true;
    }
    try {
      await rendered.rename(destination.path);
      _committed = true;
    } catch (_) {
      if (_hasBackup) {
        try {
          await File(_backupPath).rename(destination.path);
          _hasBackup = false;
        } catch (_) {
          throw FileSystemException(
            'Could not finalize export. Your previous video is preserved at $_backupPath.',
          );
        }
      }
      rethrow;
    }
  }

  Future<void> dispose() async {
    try {
      if (_hasBackup && !_committed) {
        // Never remove the only surviving copy if rollback failed.
        final rendered = File(renderPath);
        if (await rendered.exists()) await rendered.delete();
      } else if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    } catch (_) {
      // A disconnected output drive must not hide the original failure.
    }
  }
}
