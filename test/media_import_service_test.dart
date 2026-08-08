import 'dart:io';

import 'package:caption_craft/core/utils/media_import_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temporaryDirectory;
  late Directory documentsDirectory;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'captioncraft_media_import_',
    );
    documentsDirectory = Directory(
      p.join(temporaryDirectory.path, 'documents'),
    );
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('documents override copies picker media into durable storage', () async {
    final source = File(p.join(temporaryDirectory.path, 'picked video.MP4'));
    await source.writeAsBytes(const [1, 2, 3, 4]);

    final persistedPath = await MediaImportService.persistFile(
      source.path,
      documentsDirectoryOverride: documentsDirectory,
    );

    expect(p.equals(persistedPath, source.path), isFalse);
    expect(
      p.isWithin(
        p.join(documentsDirectory.path, 'CaptionCraft', 'media'),
        persistedPath,
      ),
      isTrue,
    );
    expect(await File(persistedPath).readAsBytes(), const [1, 2, 3, 4]);
    expect(await source.exists(), isTrue);
    expect(p.extension(persistedPath), '.mp4');
  });

  test('a file already in managed storage is not copied again', () async {
    final managedDirectory = Directory(
      p.join(documentsDirectory.path, 'CaptionCraft', 'media'),
    );
    await managedDirectory.create(recursive: true);
    final source = File(p.join(managedDirectory.path, 'existing.mp4'));
    await source.writeAsBytes(const [7, 8, 9]);

    final persistedPath = await MediaImportService.persistFile(
      source.path,
      documentsDirectoryOverride: documentsDirectory,
    );

    expect(p.equals(persistedPath, source.path), isTrue);
    expect(await managedDirectory.list().length, 1);
  });

  test('missing and empty files are rejected', () async {
    await expectLater(
      MediaImportService.persistFile(
        p.join(temporaryDirectory.path, 'missing.mp4'),
        documentsDirectoryOverride: documentsDirectory,
      ),
      throwsA(isA<FileSystemException>()),
    );

    final empty = File(p.join(temporaryDirectory.path, 'empty.mp4'));
    await empty.create();
    await expectLater(
      MediaImportService.persistFile(
        empty.path,
        documentsDirectoryOverride: documentsDirectory,
      ),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('desktop imports pass through the selected user path', () async {
    if (Platform.isAndroid || Platform.isIOS) {
      markTestSkipped('Desktop-only behavior.');
      return;
    }
    final source = File(p.join(temporaryDirectory.path, 'desktop.mp4'));
    await source.writeAsBytes(const [1]);

    final result = await MediaImportService.persistFile(source.path);

    expect(p.equals(result, p.normalize(p.absolute(source.path))), isTrue);
  });
}
