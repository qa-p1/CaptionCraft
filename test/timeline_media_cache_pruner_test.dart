import 'dart:io';

import 'package:caption_craft/core/utils/timeline_media_cache_pruner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('preserved cache entry counts toward deterministic bounds', () async {
    final directory = await Directory.systemTemp.createTemp(
      'caption_craft_cache_pruner_test_',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    File cacheFile(String name) =>
        File('${directory.path}${Platform.pathSeparator}$name.cache');
    final first = cacheFile('a');
    final second = cacheFile('b');
    final preserved = cacheFile('c');
    final partial = File(
      '${directory.path}${Platform.pathSeparator}working.partial.cache',
    );
    final unrelated = File(
      '${directory.path}${Platform.pathSeparator}unrelated.txt',
    );
    for (final file in [first, second, preserved, partial, unrelated]) {
      await file.writeAsBytes([1]);
    }
    final sameTimestamp = DateTime(2026, 1, 1);
    for (final file in [first, second, preserved]) {
      await file.setLastModified(sameTimestamp);
    }

    await pruneTimelineMediaCache(
      directory: directory,
      includes: (file) =>
          file.path.endsWith('.cache') && !file.path.contains('.partial.'),
      preservingPath: preserved.path,
      maximumEntries: 2,
      maximumBytes: 2,
    );

    expect(await preserved.exists(), isTrue);
    expect(await first.exists(), isTrue);
    expect(await second.exists(), isFalse);
    expect(await partial.exists(), isTrue);
    expect(await unrelated.exists(), isTrue);
  });
}
