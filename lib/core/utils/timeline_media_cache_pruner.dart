import 'dart:io';

import 'package:path/path.dart' as p;

Future<void> pruneTimelineMediaCache({
  required Directory directory,
  required bool Function(File file) includes,
  required String preservingPath,
  required int maximumEntries,
  required int maximumBytes,
}) async {
  final entries = <({File file, FileStat stat, String key})>[];
  await for (final entity in directory.list(followLinks: false)) {
    if (entity is! File || !includes(entity)) continue;
    try {
      entries.add((
        file: entity,
        stat: await entity.stat(),
        key: _pathKey(entity.path),
      ));
    } catch (_) {}
  }

  final preservingKey = _pathKey(preservingPath);
  entries.sort((first, second) {
    final firstPreserved = first.key == preservingKey;
    final secondPreserved = second.key == preservingKey;
    if (firstPreserved != secondPreserved) return firstPreserved ? -1 : 1;
    final modified = second.stat.modified.compareTo(first.stat.modified);
    return modified != 0 ? modified : first.key.compareTo(second.key);
  });

  var retainedBytes = 0;
  var retainedEntries = 0;
  for (final entry in entries) {
    final preserve = entry.key == preservingKey;
    final fits =
        retainedEntries < maximumEntries &&
        retainedBytes + entry.stat.size <= maximumBytes;
    if (preserve || fits) {
      retainedEntries++;
      retainedBytes += entry.stat.size;
      continue;
    }
    try {
      await entry.file.delete();
    } catch (_) {}
  }
}

String _pathKey(String path) {
  final normalized = p.normalize(p.absolute(path));
  return Platform.isWindows ? normalized.toLowerCase() : normalized;
}
