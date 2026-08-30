import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:caption_craft/core/constants/asset_pack_constants.dart';
import 'package:caption_craft/core/utils/asset_pack_service.dart';
import 'package:caption_craft/features/editor/models/asset_pack_models.dart';
import 'package:caption_craft/features/editor/widgets/asset_pack_facade.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _packId = AssetPackConstants.backgroundVideosId;
const _packVersion = '2026.08.11';
const _mediaBytes = <int>[1, 2, 3, 4, 5, 6];
const _previewBytes = <int>[7, 8, 9];
const _audioBytes = <int>[10, 11, 12, 13, 14];
final _lutBytes = utf8.encode(_cubeFixture(17));

String _cubeFixture(int size) {
  final output = StringBuffer()
    ..writeln('TITLE "Fixture Film Look"')
    ..writeln('LUT_3D_SIZE $size')
    ..writeln('DOMAIN_MIN 0.0 0.0 0.0')
    ..writeln('DOMAIN_MAX 1.0 1.0 1.0');
  for (var index = 0; index < size * size * size; index++) {
    output.writeln('0.0 0.0 0.0');
  }
  return output.toString();
}

void main() {
  group('AssetPackService', () {
    test(
      'does no network work until install, then installs and reloads locally',
      () async {
        final root = await _temporaryDirectory();
        final payload = _buildPackArchive();
        final server = await _PackServer.start(payload);
        addTearDown(server.close);
        final progress = <AssetPackProgress>[];
        final service = AssetPackService(
          rootDirectoryOverride: root,
          manifestUrlOverride: server.manifestUri.toString(),
        );

        expect(server.requests, isEmpty);
        expect(await service.getInstalledCatalog(_packId), isNull);
        expect(server.requests, isEmpty);

        final installed = await service.install(
          _packId,
          onProgress: progress.add,
        );

        expect(server.requests, ['/manifest.json', '/pack.zip']);
        expect(installed.id, _packId);
        expect(installed.version, _packVersion);
        expect(installed.items, hasLength(1));
        expect(installed.items.single.mediaKind, AssetPackMediaKind.video);
        expect(
          await File(installed.items.single.localPath).readAsBytes(),
          _mediaBytes,
        );
        expect(
          await File(installed.items.single.previewPath!).readAsBytes(),
          _previewBytes,
        );
        expect(
          await File(p.join(root.path, _packId, 'current.json')).exists(),
          isTrue,
        );

        _expectPhasesInOrder(progress, const [
          AssetPackProgressPhase.fetchingManifest,
          AssetPackProgressPhase.downloading,
          AssetPackProgressPhase.verifying,
          AssetPackProgressPhase.extracting,
          AssetPackProgressPhase.installing,
          AssetPackProgressPhase.complete,
        ]);
        expect(
          progress.where(
            (event) =>
                event.phase == AssetPackProgressPhase.downloading &&
                event.receivedBytes == payload.archiveBytes.length,
          ),
          isNotEmpty,
        );
        expect(
          progress
              .lastWhere(
                (event) => event.phase == AssetPackProgressPhase.downloading,
              )
              .fraction,
          1,
        );

        final requestCount = server.requests.length;
        final reloaded = await service.getInstalledCatalog(_packId);
        expect(server.requests, hasLength(requestCount));
        expect(reloaded, isNotNull);
        expect(
          reloaded!.items.single.localPath,
          installed.items.single.localPath,
        );
      },
    );

    test(
      'sound-effects lookup stays local and install accepts audio without a preview',
      () async {
        final root = await _temporaryDirectory();
        final payload = _buildAudioPackArchive();
        final server = await _PackServer.start(
          payload,
          packId: AssetPackConstants.soundEffectsId,
        );
        addTearDown(server.close);
        final service = AssetPackService(
          rootDirectoryOverride: root,
          manifestUrlOverride: server.manifestUri.toString(),
        );

        expect(server.requests, isEmpty);
        expect(
          await service.getInstalledCatalog(AssetPackConstants.soundEffectsId),
          isNull,
        );
        expect(server.requests, isEmpty);

        final installed = await service.install(
          AssetPackConstants.soundEffectsId,
        );

        expect(server.requests, ['/manifest.json', '/pack.zip']);
        expect(installed.id, AssetPackConstants.soundEffectsId);
        final item = installed.items.single;
        expect(item.mediaKind, AssetPackMediaKind.audio);
        expect(item.duration, const Duration(milliseconds: 750));
        expect(item.hasAudio, isTrue);
        expect(item.previewPath, isNull);
        expect(await File(item.localPath).readAsBytes(), _audioBytes);

        final requestCount = server.requests.length;
        final reloaded = await service.getInstalledCatalog(
          AssetPackConstants.soundEffectsId,
        );
        expect(server.requests, hasLength(requestCount));
        expect(reloaded, isNotNull);
        expect(reloaded!.items.single.localPath, item.localPath);
      },
    );

    test(
      'LUT lookup stays local and installs a common 17-point CUBE file',
      () async {
        final root = await _temporaryDirectory();
        final payload = _buildLutPackArchive();
        final server = await _PackServer.start(
          payload,
          packId: AssetPackConstants.lutsId,
        );
        addTearDown(server.close);
        final service = AssetPackService(
          rootDirectoryOverride: root,
          manifestUrlOverride: server.manifestUri.toString(),
        );

        expect(
          await service.getInstalledCatalog(AssetPackConstants.lutsId),
          isNull,
        );
        expect(server.requests, isEmpty);

        final installed = await service.install(AssetPackConstants.lutsId);

        expect(server.requests, ['/manifest.json', '/pack.zip']);
        expect(installed.id, AssetPackConstants.lutsId);
        final item = installed.items.single;
        expect(item.mediaKind, AssetPackMediaKind.lut);
        expect(item.duration, isNull);
        expect(item.hasAudio, isFalse);
        expect(item.previewPath, isNotNull);
        expect(await File(item.localPath).readAsBytes(), _lutBytes);
      },
    );

    for (final packId in const [
      AssetPackConstants.backgroundVideosId,
      AssetPackConstants.overlaysId,
    ]) {
      test('typed facade resolves and installs $packId', () async {
        final root = await _temporaryDirectory();
        final payload = _buildPackArchive(
          catalog: _validCatalog(packId: packId),
        );
        final server = await _PackServer.start(payload, packId: packId);
        addTearDown(server.close);
        final facade = AssetPackServiceFacade(
          AssetPackService(
            rootDirectoryOverride: root,
            manifestUrlOverride: server.manifestUri.toString(),
          ),
        );

        final release = await facade.getRelease(packId);
        expect(release.id, packId);
        expect(release.version, _packVersion);

        final installed = await facade.install(packId, release: release);
        expect(installed.id, packId);
        expect(installed.items, hasLength(1));
        expect(await File(installed.items.single.localPath).exists(), isTrue);
        expect(server.requests, ['/manifest.json', '/pack.zip']);
      });
    }

    test('an unconfigured install fails before creating pack state', () async {
      final root = await _temporaryDirectory();
      final service = AssetPackService(
        rootDirectoryOverride: root,
        manifestUrlOverride: '   ',
      );

      expect(await service.getInstalledCatalog(_packId), isNull);
      await expectLater(
        service.install(_packId),
        throwsA(
          isA<AssetPackException>().having(
            (error) => error.message,
            'message',
            contains('not configured'),
          ),
        ),
      );
      expect(await Directory(p.join(root.path, _packId)).exists(), isFalse);
    });

    test(
      'explicit cancellation stops an install and clears operation data',
      () async {
        final root = await _temporaryDirectory();
        final payload = _buildPackArchive();
        final server = await _PackServer.start(payload);
        addTearDown(server.close);
        final cancelToken = CancelToken();
        final service = AssetPackService(
          rootDirectoryOverride: root,
          manifestUrlOverride: server.manifestUri.toString(),
        );

        await expectLater(
          service.install(
            _packId,
            cancelToken: cancelToken,
            onProgress: (progress) {
              if (progress.phase == AssetPackProgressPhase.downloading &&
                  progress.receivedBytes > 0) {
                cancelToken.cancel('library closed');
              }
            },
          ),
          throwsA(
            isA<AssetPackException>().having(
              (error) => error.message,
              'message',
              contains('cancelled'),
            ),
          ),
        );

        await _expectFailedInstallClean(root);
      },
    );

    test(
      'rejects a declared-size mismatch and removes temporary data',
      () async {
        final root = await _temporaryDirectory();
        final payload = _buildPackArchive();
        final server = await _PackServer.start(
          payload,
          declaredArchiveBytes: payload.archiveBytes.length + 1,
        );
        addTearDown(server.close);
        final service = AssetPackService(
          rootDirectoryOverride: root,
          manifestUrlOverride: server.manifestUri.toString(),
        );

        await expectLater(
          service.install(_packId),
          throwsA(
            isA<AssetPackException>().having(
              (error) => error.message,
              'message',
              contains('size check failed'),
            ),
          ),
        );

        await _expectFailedInstallClean(root);
      },
    );

    test('rejects a SHA mismatch and removes temporary data', () async {
      final root = await _temporaryDirectory();
      final payload = _buildPackArchive();
      final server = await _PackServer.start(payload, declaredSha256: '0' * 64);
      addTearDown(server.close);
      final service = AssetPackService(
        rootDirectoryOverride: root,
        manifestUrlOverride: server.manifestUri.toString(),
      );

      await expectLater(
        service.install(_packId),
        throwsA(
          isA<AssetPackException>().having(
            (error) => error.message,
            'message',
            contains('integrity check failed'),
          ),
        ),
      );

      await _expectFailedInstallClean(root);
    });

    test('rejects traversal entries before extracting the archive', () async {
      final root = await _temporaryDirectory();
      final payload = _buildPackArchive(
        additionalEntries: [
          ArchiveFile.bytes('../outside.txt', [42]),
        ],
      );
      final server = await _PackServer.start(payload);
      addTearDown(server.close);
      final service = AssetPackService(
        rootDirectoryOverride: root,
        manifestUrlOverride: server.manifestUri.toString(),
      );

      await expectLater(
        service.install(_packId),
        throwsA(
          isA<AssetPackException>().having(
            (error) => error.message,
            'message',
            contains('escapes its install folder'),
          ),
        ),
      );

      expect(
        await File(p.join(root.path, '.tmp', 'outside.txt')).exists(),
        isFalse,
      );
      await _expectFailedInstallClean(root);
    });

    test('rejects symbolic-link entries before extraction', () async {
      final root = await _temporaryDirectory();
      final link = ArchiveFile.string('media/linked.mp4', 'clip.mp4')
        ..mode = 0xa1ff;
      final payload = _buildPackArchive(additionalEntries: [link]);
      final server = await _PackServer.start(payload);
      addTearDown(server.close);
      final service = AssetPackService(
        rootDirectoryOverride: root,
        manifestUrlOverride: server.manifestUri.toString(),
      );

      await expectLater(
        service.install(_packId),
        throwsA(
          isA<AssetPackException>().having(
            (error) => error.message,
            'message',
            contains('symbolic links'),
          ),
        ),
      );

      await _expectFailedInstallClean(root);
    });

    test('rejects a downloaded catalog for a different pack', () async {
      final root = await _temporaryDirectory();
      final payload = _buildPackArchive(
        catalog: _validCatalog(packId: AssetPackConstants.overlaysId),
      );
      final server = await _PackServer.start(payload);
      addTearDown(server.close);
      final service = AssetPackService(
        rootDirectoryOverride: root,
        manifestUrlOverride: server.manifestUri.toString(),
      );

      await expectLater(
        service.install(_packId),
        throwsA(
          isA<AssetPackException>().having(
            (error) => error.message,
            'message',
            contains('another pack'),
          ),
        ),
      );

      await _expectFailedInstallClean(root);
    });

    test('coalesces concurrent installs into one archive request', () async {
      final root = await _temporaryDirectory();
      final payload = _buildPackArchive();
      final server = await _PackServer.start(
        payload,
        chunkSize: 32,
        chunkDelay: const Duration(milliseconds: 2),
      );
      addTearDown(server.close);
      final service = AssetPackService(
        rootDirectoryOverride: root,
        manifestUrlOverride: server.manifestUri.toString(),
      );

      final first = service.install(_packId);
      final second = service.install(_packId);
      expect(identical(first, second), isTrue);
      final catalogs = await Future.wait([first, second]);

      expect(catalogs.first.items.single.id, 'clip-1');
      expect(
        server.requests.where((path) => path == '/pack.zip'),
        hasLength(1),
      );
    });

    test('repairs a damaged content-addressed release on Retry', () async {
      final root = await _temporaryDirectory();
      final payload = _buildPackArchive();
      final server = await _PackServer.start(payload);
      addTearDown(server.close);
      final service = AssetPackService(
        rootDirectoryOverride: root,
        manifestUrlOverride: server.manifestUri.toString(),
      );

      final first = await service.install(_packId);
      final originalPath = first.items.single.localPath;
      await File(originalPath).delete();
      expect(await service.getInstalledCatalog(_packId), isNull);

      final repaired = await service.install(_packId);

      expect(repaired.items.single.localPath, originalPath);
      expect(await File(originalPath).readAsBytes(), _mediaBytes);
      expect(
        server.requests.where((path) => path == '/pack.zip'),
        hasLength(2),
      );
    });

    test('retains a stopped partial and resumes it with Range', () async {
      final root = await _temporaryDirectory();
      final padding = List<int>.generate(
        256 * 1024,
        (index) => (index * 31 + index ~/ 251) & 0xff,
      );
      final payload = _buildPackArchive(
        additionalEntries: [
          ArchiveFile.noCompress(
            'extras/resume-fixture.bin',
            padding.length,
            padding,
          ),
        ],
      );
      final server = await _PackServer.start(
        payload,
        supportRanges: true,
        chunkSize: 4096,
        chunkDelay: const Duration(milliseconds: 4),
      );
      addTearDown(server.close);
      final service = AssetPackService(
        rootDirectoryOverride: root,
        manifestUrlOverride: server.manifestUri.toString(),
      );
      final cancelToken = CancelToken();

      await expectLater(
        service.install(
          _packId,
          cancelToken: cancelToken,
          onProgress: (progress) {
            if (progress.phase == AssetPackProgressPhase.downloading &&
                progress.receivedBytes > 0 &&
                !cancelToken.isCancelled) {
              cancelToken.cancel('explicit stop');
            }
          },
        ),
        throwsA(
          isA<AssetPackException>().having(
            (error) => error.reason,
            'reason',
            AssetPackFailureReason.cancelled,
          ),
        ),
      );
      final partials = await Directory(p.join(root.path, '.downloads'))
          .list(recursive: true)
          .where((entry) => entry.path.endsWith('.part'))
          .toList();
      expect(partials, hasLength(1));
      final partialLength = await File(partials.single.path).length();
      expect(partialLength, greaterThan(0));
      expect(partialLength, lessThan(payload.archiveBytes.length));

      final installed = await service.install(_packId);

      expect(installed.items.single.id, 'clip-1');
      expect(server.rangeHeaders, isNotEmpty);
      expect(server.rangeHeaders.single, 'bytes=$partialLength-');
    });

    test('fails disk preflight before requesting any archive bytes', () async {
      final root = await _temporaryDirectory();
      final payload = _buildPackArchive();
      final server = await _PackServer.start(payload);
      addTearDown(server.close);
      final service = AssetPackService(
        rootDirectoryOverride: root,
        manifestUrlOverride: server.manifestUri.toString(),
        availableStorageProbe: (_) async => 0,
      );

      await expectLater(
        service.install(_packId),
        throwsA(
          isA<AssetPackException>()
              .having(
                (error) => error.reason,
                'reason',
                AssetPackFailureReason.storage,
              )
              .having(
                (error) => error.message,
                'message',
                contains('Not enough free space'),
              ),
        ),
      );

      expect(server.requests, ['/manifest.json']);
    });

    test('installs a schema-v2 release from disjoint archive parts', () async {
      final root = await _temporaryDirectory();
      final payloads = _buildMultipartPackArchives();
      final server = await _PackServer.startMultipart(payloads);
      addTearDown(server.close);
      final service = AssetPackService(
        rootDirectoryOverride: root,
        manifestUrlOverride: server.manifestUri.toString(),
      );
      final progress = <AssetPackProgress>[];

      final installed = await service.install(
        _packId,
        onProgress: progress.add,
      );

      expect(installed.items.single.id, 'clip-1');
      expect(server.requests, ['/manifest.json', '/part-1.zip', '/part-2.zip']);
      expect(
        progress.where(
          (event) =>
              event.phase == AssetPackProgressPhase.downloading &&
              event.partCount == 2,
        ),
        isNotEmpty,
      );
      expect(
        await File(installed.items.single.localPath).readAsBytes(),
        _mediaBytes,
      );
    });
  });

  group('AssetPackService removal', () {
    test('refuses to delete any release referenced by a project', () async {
      final root = await _temporaryDirectory();
      final oldRelease = Directory(
        p.join(root.path, _packId, 'releases', 'old_release'),
      );
      final referenced = File(p.join(oldRelease.path, 'media', 'clip.mp4'));
      await referenced.parent.create(recursive: true);
      await referenced.writeAsBytes(_mediaBytes);
      final service = AssetPackService(rootDirectoryOverride: root);

      await expectLater(
        service.uninstall(_packId, protectedPaths: {referenced.path}),
        throwsA(
          isA<AssetPackException>().having(
            (error) => error.reason,
            'reason',
            AssetPackFailureReason.inUse,
          ),
        ),
      );

      expect(await referenced.exists(), isTrue);
      expect(await Directory(p.join(root.path, _packId)).exists(), isTrue);
    });

    test(
      'removes pack releases and partial downloads but not siblings',
      () async {
        final root = await _temporaryDirectory();
        final packFile = File(
          p.join(root.path, _packId, 'releases', 'v1', 'media', 'clip.mp4'),
        );
        final partial = File(
          p.join(root.path, '.downloads', _packId, 'digest', 'part.zip.part'),
        );
        final sibling = File(p.join(root.path, '$_packId-other', 'keep.mp4'));
        await Future.wait([
          packFile.parent.create(recursive: true),
          partial.parent.create(recursive: true),
          sibling.parent.create(recursive: true),
        ]);
        await Future.wait([
          packFile.writeAsBytes(_mediaBytes),
          partial.writeAsBytes(_mediaBytes),
          sibling.writeAsBytes(_mediaBytes),
        ]);
        final service = AssetPackService(rootDirectoryOverride: root);

        await service.uninstall(_packId, protectedPaths: {sibling.path});

        expect(await Directory(p.join(root.path, _packId)).exists(), isFalse);
        expect(
          await Directory(p.join(root.path, '.downloads', _packId)).exists(),
          isFalse,
        );
        expect(await sibling.exists(), isTrue);
      },
    );

    test(
      'supports safe idempotent removal for all optional pack types',
      () async {
        final root = await _temporaryDirectory();
        final service = AssetPackService(rootDirectoryOverride: root);

        for (final packId in const {
          AssetPackConstants.backgroundVideosId,
          AssetPackConstants.overlaysId,
          AssetPackConstants.soundEffectsId,
          AssetPackConstants.lutsId,
        }) {
          final file = File(
            p.join(root.path, packId, 'releases', 'v1', 'item'),
          );
          await file.parent.create(recursive: true);
          await file.writeAsString(packId);
          await service.uninstall(packId);
          await service.uninstall(packId);
          expect(await Directory(p.join(root.path, packId)).exists(), isFalse);
        }
      },
    );
  });

  group('asset pack release validation', () {
    test('parses rich schema-v2 multipart metadata', () {
      final release = AssetPackRelease.fromJson(
        {
          'id': _packId,
          'version': _packVersion,
          'title': 'Background videos',
          'description': 'A fixture release',
          'assetCount': 1,
          'installedBytes': 30,
          'catalogPath': 'catalog.json',
          'catalogSchemaVersion': AssetPackConstants.catalogSchemaVersion,
          'parts': [
            {
              'id': 'part-1',
              'url': './part-1.zip',
              'sha256': '1' * 64,
              'bytes': 10,
            },
            {
              'id': 'part-2',
              'url': './part-2.zip',
              'sha256': '2' * 64,
              'bytes': 20,
            },
          ],
        },
        manifestUri: Uri.parse('https://media.example.test/manifest.json'),
        manifestSchemaVersion: 2,
      );

      expect(release.title, 'Background videos');
      expect(release.assetCount, 1);
      expect(release.archiveBytes, 30);
      expect(release.archiveParts, hasLength(2));
      expect(
        release.archiveParts.last.uri.toString(),
        'https://media.example.test/part-2.zip',
      );
    });

    test('rejects fractional sizes and cross-origin archive parts', () {
      Map<String, dynamic> row() => {
        'id': _packId,
        'version': _packVersion,
        'title': 'Background videos',
        'assetCount': 1,
        'installedBytes': 30,
        'catalogPath': 'catalog.json',
        'parts': [
          {
            'id': 'part-1',
            'url': './part-1.zip',
            'sha256': '1' * 64,
            'bytes': 10,
          },
        ],
      };

      final fractional = row()..['installedBytes'] = 30.5;
      expect(
        () => AssetPackRelease.fromJson(
          fractional,
          manifestUri: Uri.parse('https://media.example.test/manifest.json'),
          manifestSchemaVersion: 2,
        ),
        throwsA(isA<FormatException>()),
      );

      final crossOrigin = row();
      ((crossOrigin['parts'] as List).single as Map<String, dynamic>)['url'] =
          'https://other.example.test/part.zip';
      expect(
        () => AssetPackRelease.fromJson(
          crossOrigin,
          manifestUri: Uri.parse('https://media.example.test/manifest.json'),
          manifestSchemaVersion: 2,
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('asset pack catalog validation', () {
    test('rejects malformed JSON and malformed item fields', () async {
      final installation = await _temporaryDirectory();
      final catalogFile = File(p.join(installation.path, 'catalog.json'));

      await catalogFile.writeAsString('{not json');
      await expectLater(
        _loadCatalog(installation),
        throwsA(isA<FormatException>()),
      );

      final malformed = _validCatalog();
      ((malformed['assets'] as List).single
              as Map<String, dynamic>)['previewPath'] =
          123;
      await catalogFile.writeAsString(jsonEncode(malformed));
      await expectLater(
        _loadCatalog(installation, validateFiles: false),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects invalid and escaping relative paths', () {
      for (final value in [
        '',
        '.',
        '..',
        '../media.mp4',
        'media/../../outside.mp4',
        '/absolute/media.mp4',
        r'C:\absolute\media.mp4',
        r'\\server\share\media.mp4',
      ]) {
        expect(
          () => normalizePackRelativePath(value),
          throwsA(isA<FormatException>()),
          reason: value,
        );
      }

      expect(normalizePackRelativePath(r'media\clip.mp4'), 'media/clip.mp4');
    });

    test(
      'validates catalog identity and every referenced media file',
      () async {
        final installation = await _temporaryDirectory();
        await _writeValidInstalledPack(installation);

        await expectLater(
          AssetPackCatalog.load(
            expectedPackId: AssetPackConstants.overlaysId,
            installationDirectory: installation,
            catalogPath: 'catalog.json',
          ),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              contains('another pack'),
            ),
          ),
        );

        final loaded = await _loadCatalog(installation);
        expect(await File(loaded.items.single.localPath).exists(), isTrue);
        expect(await File(loaded.items.single.previewPath!).exists(), isTrue);

        final media = File(p.join(installation.path, 'media', 'clip.mp4'));
        await media.writeAsBytes([..._mediaBytes, 99]);
        await expectLater(
          _loadCatalog(installation),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              contains('missing or damaged'),
            ),
          ),
        );

        await media.writeAsBytes(_mediaBytes);
        await File(p.join(installation.path, 'previews', 'clip.jpg')).delete();
        await expectLater(
          _loadCatalog(installation),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              contains('preview is missing'),
            ),
          ),
        );
      },
    );

    test('loads audio with a required duration and no preview', () async {
      final installation = await _temporaryDirectory();
      final media = File(p.join(installation.path, 'sounds', 'click.m4a'));
      await media.parent.create(recursive: true);
      await media.writeAsBytes(_audioBytes);
      await File(
        p.join(installation.path, 'catalog.json'),
      ).writeAsString(jsonEncode(_validAudioCatalog()));

      final catalog = await AssetPackCatalog.load(
        expectedPackId: AssetPackConstants.soundEffectsId,
        installationDirectory: installation,
        catalogPath: 'catalog.json',
      );
      final item = catalog.items.single;

      expect(item.mediaKind, AssetPackMediaKind.audio);
      expect(item.duration, const Duration(milliseconds: 750));
      expect(item.hasAudio, isTrue);
      expect(item.previewRelativePath, isNull);
      expect(item.previewPath, isNull);
    });

    test('loads valid LUT files and rejects malformed LUT contents', () async {
      final installation = await _temporaryDirectory();
      final lut = File(p.join(installation.path, 'luts', 'film-look.cube'));
      final preview = File(
        p.join(installation.path, 'previews', 'film-look.jpg'),
      );
      await lut.parent.create(recursive: true);
      await preview.parent.create(recursive: true);
      await lut.writeAsBytes(_lutBytes);
      await preview.writeAsBytes(_previewBytes);
      await File(
        p.join(installation.path, 'catalog.json'),
      ).writeAsString(jsonEncode(_validLutCatalog()));

      final catalog = await AssetPackCatalog.load(
        expectedPackId: AssetPackConstants.lutsId,
        installationDirectory: installation,
        catalogPath: 'catalog.json',
      );
      expect(catalog.items.single.mediaKind, AssetPackMediaKind.lut);
      expect(catalog.items.single.previewPath, preview.path);

      await lut.writeAsString(
        'TITLE "Incomplete"\nLUT_3D_SIZE 17\n0.0 0.0 0.0\n',
      );
      final malformedCatalog = _validLutCatalog();
      (malformedCatalog['assets'] as List<Map<String, dynamic>>)
          .single['sizeBytes'] = await lut
          .length();
      await File(
        p.join(installation.path, 'catalog.json'),
      ).writeAsString(jsonEncode(malformedCatalog));
      await expectLater(
        AssetPackCatalog.load(
          expectedPackId: AssetPackConstants.lutsId,
          installationDirectory: installation,
          catalogPath: 'catalog.json',
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('malformed'),
          ),
        ),
      );
    });

    test(
      'streams complete 33-point CUBE files beyond the header prefix',
      () async {
        final installation = await _temporaryDirectory();
        final lut = File(p.join(installation.path, 'large-look.cube'));
        await lut.writeAsString(_cubeFixture(33));

        expect(await lut.length(), greaterThan(256 * 1024));
        await expectLater(validateLutFile(lut.path), completes);
      },
    );

    test(
      'rejects LUT catalogs without previews or supported extensions',
      () async {
        final installation = await _temporaryDirectory();
        final catalogFile = File(p.join(installation.path, 'catalog.json'));

        final withoutPreview = _validLutCatalog();
        (withoutPreview['assets'] as List<Map<String, dynamic>>).single.remove(
          'previewPath',
        );
        await catalogFile.writeAsString(jsonEncode(withoutPreview));
        await expectLater(
          AssetPackCatalog.load(
            expectedPackId: AssetPackConstants.lutsId,
            installationDirectory: installation,
            catalogPath: 'catalog.json',
            validateFiles: false,
          ),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              contains('preview is required'),
            ),
          ),
        );

        final wrongExtension = _validLutCatalog();
        (wrongExtension['assets'] as List<Map<String, dynamic>>)
                .single['relativePath'] =
            'luts/film-look.txt';
        await catalogFile.writeAsString(jsonEncode(wrongExtension));
        await expectLater(
          AssetPackCatalog.load(
            expectedPackId: AssetPackConstants.lutsId,
            installationDirectory: installation,
            catalogPath: 'catalog.json',
            validateFiles: false,
          ),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              contains('unsupported file type'),
            ),
          ),
        );
      },
    );

    test('rejects invalid audio duration and hasAudio declarations', () async {
      final installation = await _temporaryDirectory();
      final catalogFile = File(p.join(installation.path, 'catalog.json'));

      for (final invalidDuration in <Object?>[null, 0, -1, '750']) {
        final catalog = _validAudioCatalog();
        ((catalog['assets'] as List).single
                as Map<String, dynamic>)['durationMs'] =
            invalidDuration;
        await catalogFile.writeAsString(jsonEncode(catalog));
        await expectLater(
          AssetPackCatalog.load(
            expectedPackId: AssetPackConstants.soundEffectsId,
            installationDirectory: installation,
            catalogPath: 'catalog.json',
            validateFiles: false,
          ),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              contains('Audio duration'),
            ),
          ),
          reason: 'durationMs=$invalidDuration',
        );
      }

      for (final invalidHasAudio in <Object?>[null, false, 'true', 1]) {
        final catalog = _validAudioCatalog();
        ((catalog['assets'] as List).single
                as Map<String, dynamic>)['hasAudio'] =
            invalidHasAudio;
        await catalogFile.writeAsString(jsonEncode(catalog));
        await expectLater(
          AssetPackCatalog.load(
            expectedPackId: AssetPackConstants.soundEffectsId,
            installationDirectory: installation,
            catalogPath: 'catalog.json',
            validateFiles: false,
          ),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              contains('hasAudio=true'),
            ),
          ),
          reason: 'hasAudio=$invalidHasAudio',
        );
      }
    });

    test('rejects audio without explicit redistribution provenance', () async {
      final installation = await _temporaryDirectory();
      final catalogFile = File(p.join(installation.path, 'catalog.json'));

      for (final missingKey in const [
        'mimeType',
        'codec',
        'sampleRate',
        'channels',
        'license',
        'licenseUrl',
        'sourceUrl',
        'redistributionCleared',
      ]) {
        final catalog = _validAudioCatalog();
        final asset =
            (catalog['assets'] as List).single as Map<String, dynamic>;
        final metadata = asset['metadata'] as Map<String, dynamic>;
        metadata.remove(missingKey);
        await catalogFile.writeAsString(jsonEncode(catalog));

        await expectLater(
          AssetPackCatalog.load(
            expectedPackId: AssetPackConstants.soundEffectsId,
            installationDirectory: installation,
            catalogPath: 'catalog.json',
            validateFiles: false,
          ),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              contains(missingKey),
            ),
          ),
          reason: 'missing metadata.$missingKey',
        );
      }
    });
  });
}

Future<Directory> _temporaryDirectory() async {
  final directory = await Directory.systemTemp.createTemp(
    'caption_craft_asset_pack_test_',
  );
  addTearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });
  return directory;
}

Future<AssetPackCatalog> _loadCatalog(
  Directory installation, {
  bool validateFiles = true,
}) {
  return AssetPackCatalog.load(
    expectedPackId: _packId,
    installationDirectory: installation,
    catalogPath: 'catalog.json',
    validateFiles: validateFiles,
  );
}

Future<void> _writeValidInstalledPack(Directory installation) async {
  final media = File(p.join(installation.path, 'media', 'clip.mp4'));
  final preview = File(p.join(installation.path, 'previews', 'clip.jpg'));
  await media.parent.create(recursive: true);
  await preview.parent.create(recursive: true);
  await media.writeAsBytes(_mediaBytes);
  await preview.writeAsBytes(_previewBytes);
  await File(
    p.join(installation.path, 'catalog.json'),
  ).writeAsString(jsonEncode(_validCatalog()));
}

Map<String, dynamic> _validCatalog({
  String packId = _packId,
  String version = _packVersion,
}) {
  return {
    'schema': 'captioncraft-asset-pack',
    'schemaVersion': AssetPackConstants.catalogSchemaVersion,
    'pack': {'id': packId, 'title': 'Background videos', 'version': version},
    'categories': [
      {'id': 'abstract', 'name': 'Abstract'},
    ],
    'assets': [
      {
        'id': 'clip-1',
        'title': 'Test clip',
        'categoryId': 'abstract',
        'mediaType': 'video',
        'relativePath': 'media/clip.mp4',
        'previewPath': 'previews/clip.jpg',
        'sizeBytes': _mediaBytes.length,
        'width': 1920,
        'height': 1080,
        'durationMs': 1500,
        'hasAudio': false,
        'tags': ['abstract', 'loop'],
        'metadata': {'source': 'test'},
      },
    ],
  };
}

Map<String, dynamic> _validAudioCatalog({String version = _packVersion}) {
  return {
    'schema': 'captioncraft-asset-pack',
    'schemaVersion': AssetPackConstants.catalogSchemaVersion,
    'pack': {
      'id': AssetPackConstants.soundEffectsId,
      'title': 'Sound effects',
      'version': version,
    },
    'categories': [
      {'id': 'interface', 'name': 'Interface'},
    ],
    'assets': [
      <String, dynamic>{
        'id': 'click-1',
        'title': 'Click',
        'categoryId': 'interface',
        'mediaType': 'audio',
        'relativePath': 'sounds/click.m4a',
        'sizeBytes': _audioBytes.length,
        'durationMs': 750,
        'hasAudio': true,
        'tags': ['interface', 'click'],
        'metadata': {
          'mimeType': 'audio/mp4',
          'codec': 'aac',
          'sampleRate': 48000,
          'channels': 2,
          'license': 'CC0-1.0',
          'licenseUrl': 'https://creativecommons.org/publicdomain/zero/1.0/',
          'sourceUrl': 'https://example.test/sounds/click-1',
          'redistributionCleared': true,
        },
      },
    ],
  };
}

Map<String, dynamic> _validLutCatalog({String version = _packVersion}) {
  return {
    'schema': 'captioncraft-asset-pack',
    'schemaVersion': AssetPackConstants.catalogSchemaVersion,
    'pack': {
      'id': AssetPackConstants.lutsId,
      'title': 'LUTs',
      'version': version,
    },
    'categories': [
      {'id': 'cinematic', 'name': 'Cinematic'},
    ],
    'assets': <Map<String, dynamic>>[
      {
        'id': 'film-look-1',
        'title': 'Fixture Film Look',
        'categoryId': 'cinematic',
        'mediaType': 'lut',
        'relativePath': 'luts/film-look.cube',
        'previewPath': 'previews/film-look.jpg',
        'sizeBytes': _lutBytes.length,
        'hasAudio': false,
        'tags': ['cinematic', 'film'],
        'metadata': {'format': 'cube', 'gridSize': 17},
      },
    ],
  };
}

_ZipPayload _buildPackArchive({
  Map<String, dynamic>? catalog,
  List<ArchiveFile> additionalEntries = const [],
}) {
  final archive = Archive();
  final catalogBytes = utf8.encode(jsonEncode(catalog ?? _validCatalog()));
  final entries = <ArchiveFile>[
    ArchiveFile.bytes('catalog.json', catalogBytes),
    ArchiveFile.bytes('media/clip.mp4', _mediaBytes),
    ArchiveFile.bytes('previews/clip.jpg', _previewBytes),
    ...additionalEntries,
  ];
  var installedBytes = 0;
  for (final entry in entries) {
    archive.add(entry);
    if (entry.isFile) installedBytes += entry.size;
  }
  final archiveBytes = ZipEncoder().encodeBytes(archive);
  if (additionalEntries.any((entry) => entry.mode & 0xf000 == 0xa000)) {
    _markZipCentralDirectoryAsUnix(archiveBytes);
  }
  return _ZipPayload(
    archiveBytes: archiveBytes,
    installedBytes: installedBytes,
  );
}

_ZipPayload _buildAudioPackArchive() {
  final archive = Archive();
  final catalogBytes = utf8.encode(jsonEncode(_validAudioCatalog()));
  final entries = <ArchiveFile>[
    ArchiveFile.bytes('catalog.json', catalogBytes),
    ArchiveFile.bytes('sounds/click.m4a', _audioBytes),
  ];
  var installedBytes = 0;
  for (final entry in entries) {
    archive.add(entry);
    if (entry.isFile) installedBytes += entry.size;
  }
  return _ZipPayload(
    archiveBytes: ZipEncoder().encodeBytes(archive),
    installedBytes: installedBytes,
  );
}

_ZipPayload _buildLutPackArchive() {
  final archive = Archive();
  final catalogBytes = utf8.encode(jsonEncode(_validLutCatalog()));
  final entries = <ArchiveFile>[
    ArchiveFile.bytes('catalog.json', catalogBytes),
    ArchiveFile.bytes('luts/film-look.cube', _lutBytes),
    ArchiveFile.bytes('previews/film-look.jpg', _previewBytes),
  ];
  var installedBytes = 0;
  for (final entry in entries) {
    archive.add(entry);
    if (entry.isFile) installedBytes += entry.size;
  }
  return _ZipPayload(
    archiveBytes: ZipEncoder().encodeBytes(archive),
    installedBytes: installedBytes,
  );
}

List<_ZipPayload> _buildMultipartPackArchives() {
  _ZipPayload build(List<ArchiveFile> entries) {
    final archive = Archive();
    var installedBytes = 0;
    for (final entry in entries) {
      archive.add(entry);
      if (entry.isFile) installedBytes += entry.size;
    }
    return _ZipPayload(
      archiveBytes: ZipEncoder().encodeBytes(archive),
      installedBytes: installedBytes,
    );
  }

  return [
    build([
      ArchiveFile.bytes(
        'catalog.json',
        utf8.encode(jsonEncode(_validCatalog())),
      ),
      ArchiveFile.bytes('previews/clip.jpg', _previewBytes),
    ]),
    build([ArchiveFile.bytes('media/clip.mp4', _mediaBytes)]),
  ];
}

// archive's in-memory encoder identifies ZIPs as DOS-origin. Symlink mode bits
// are only meaningful for UNIX-origin central-directory entries, so adjust the
// fixture metadata to model a ZIP produced by a UNIX archiver.
void _markZipCentralDirectoryAsUnix(List<int> bytes) {
  for (var index = 0; index <= bytes.length - 6; index++) {
    if (bytes[index] == 0x50 &&
        bytes[index + 1] == 0x4b &&
        bytes[index + 2] == 0x01 &&
        bytes[index + 3] == 0x02) {
      bytes[index + 5] = 3;
    }
  }
}

void _expectPhasesInOrder(
  List<AssetPackProgress> progress,
  List<AssetPackProgressPhase> expected,
) {
  var previousIndex = -1;
  for (final phase in expected) {
    final index = progress.indexWhere(
      (event) => event.phase == phase,
      previousIndex + 1,
    );
    expect(index, greaterThan(previousIndex), reason: 'Missing phase $phase');
    previousIndex = index;
  }
}

Future<void> _expectFailedInstallClean(Directory root) async {
  expect(
    await File(p.join(root.path, _packId, 'current.json')).exists(),
    isFalse,
  );
  final temporaryRoot = Directory(p.join(root.path, '.tmp'));
  if (await temporaryRoot.exists()) {
    expect(await temporaryRoot.list().toList(), isEmpty);
  }
}

class _ZipPayload {
  final List<int> archiveBytes;
  final int installedBytes;

  const _ZipPayload({required this.archiveBytes, required this.installedBytes});
}

class _PackServer {
  final HttpServer _server;
  final List<_ZipPayload> _payloads;
  final String packId;
  final int? _declaredArchiveBytes;
  final String? _declaredSha256;
  final int schemaVersion;
  final bool supportRanges;
  final int? chunkSize;
  final Duration chunkDelay;
  final List<String> requests = [];
  final List<String> rangeHeaders = [];

  _PackServer._(
    this._server,
    this._payloads, {
    required this.packId,
    int? declaredArchiveBytes,
    String? declaredSha256,
    this.schemaVersion = 1,
    this.supportRanges = false,
    this.chunkSize,
    this.chunkDelay = Duration.zero,
  }) : _declaredArchiveBytes = declaredArchiveBytes,
       _declaredSha256 = declaredSha256 {
    _server.listen(_handleRequest);
  }

  static Future<_PackServer> start(
    _ZipPayload payload, {
    String packId = _packId,
    int? declaredArchiveBytes,
    String? declaredSha256,
    bool supportRanges = false,
    int? chunkSize,
    Duration chunkDelay = Duration.zero,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return _PackServer._(
      server,
      [payload],
      packId: packId,
      declaredArchiveBytes: declaredArchiveBytes,
      declaredSha256: declaredSha256,
      supportRanges: supportRanges,
      chunkSize: chunkSize,
      chunkDelay: chunkDelay,
    );
  }

  static Future<_PackServer> startMultipart(List<_ZipPayload> payloads) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return _PackServer._(
      server,
      payloads,
      packId: _packId,
      schemaVersion: 2,
      supportRanges: true,
    );
  }

  Uri get manifestUri => Uri.parse(
    'http://${_server.address.address}:${_server.port}/manifest.json',
  );

  Future<void> close() => _server.close(force: true);

  Future<void> _handleRequest(HttpRequest request) async {
    requests.add(request.uri.path);
    if (request.uri.path == '/manifest.json') {
      request.response.headers.contentType = ContentType.json;
      final installedBytes = _payloads.fold<int>(
        0,
        (total, payload) => total + payload.installedBytes,
      );
      request.response.write(
        jsonEncode({
          'schemaVersion': schemaVersion,
          'packs': [
            if (schemaVersion == 1)
              {
                'id': packId,
                'version': _packVersion,
                'archiveUrl': '/pack.zip',
                'sha256':
                    _declaredSha256 ??
                    sha256.convert(_payloads.single.archiveBytes).toString(),
                'archiveBytes':
                    _declaredArchiveBytes ??
                    _payloads.single.archiveBytes.length,
                'installedBytes': installedBytes,
                'catalogPath': 'catalog.json',
              }
            else
              {
                'id': packId,
                'version': _packVersion,
                'title': 'Background videos',
                'description': 'Multipart fixture',
                'assetCount': 1,
                'installedBytes': installedBytes,
                'catalogPath': 'catalog.json',
                'catalogSchemaVersion': AssetPackConstants.catalogSchemaVersion,
                'parts': [
                  for (var index = 0; index < _payloads.length; index++)
                    {
                      'id': 'part-${index + 1}',
                      'url': '/part-${index + 1}.zip',
                      'sha256': sha256
                          .convert(_payloads[index].archiveBytes)
                          .toString(),
                      'bytes': _payloads[index].archiveBytes.length,
                    },
                ],
              },
          ],
        }),
      );
    } else {
      final partMatch = RegExp(
        r'^/part-(\d+)\.zip$',
      ).firstMatch(request.uri.path);
      final payloadIndex = request.uri.path == '/pack.zip'
          ? 0
          : int.tryParse(partMatch?.group(1) ?? '') ?? -1;
      final resolvedIndex = request.uri.path == '/pack.zip'
          ? payloadIndex
          : payloadIndex - 1;
      if (resolvedIndex < 0 || resolvedIndex >= _payloads.length) {
        request.response.statusCode = HttpStatus.notFound;
      } else {
        await _writeArchiveResponse(request, _payloads[resolvedIndex]);
        return;
      }
    }
    await request.response.close();
  }

  Future<void> _writeArchiveResponse(
    HttpRequest request,
    _ZipPayload payload,
  ) async {
    final bytes = payload.archiveBytes;
    var start = 0;
    final range = request.headers.value(HttpHeaders.rangeHeader);
    if (range != null) rangeHeaders.add(range);
    final match = RegExp(r'^bytes=(\d+)-$').firstMatch(range ?? '');
    if (supportRanges && match != null) {
      start = int.parse(match.group(1)!);
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-${bytes.length - 1}/${bytes.length}',
      );
    }
    request.response.headers
      ..contentType = ContentType.binary
      ..set(HttpHeaders.etagHeader, '"fixture-v1"')
      ..set(HttpHeaders.acceptRangesHeader, 'bytes');
    request.response.contentLength = bytes.length - start;
    final size = chunkSize ?? bytes.length;
    try {
      for (var offset = start; offset < bytes.length; offset += size) {
        final end = (offset + size).clamp(0, bytes.length);
        request.response.add(bytes.sublist(offset, end));
        await request.response.flush();
        if (chunkDelay > Duration.zero) await Future<void>.delayed(chunkDelay);
      }
      await request.response.close();
    } on HttpException {
      // Expected when the cancellation test closes a streaming response.
    } on SocketException {
      // Expected when the cancellation test closes a streaming response.
    }
  }
}
