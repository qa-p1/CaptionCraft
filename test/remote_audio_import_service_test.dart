import 'dart:io';
import 'dart:typed_data';

import 'package:caption_craft/core/utils/remote_audio_import_service.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _audioBytes = <int>[73, 68, 51, 4, 0, 0, 0, 1, 2, 3];

void main() {
  group('RemoteAudioImportService', () {
    test('downloads a selected sound into durable project media', () async {
      final documents = await _temporaryDirectory();
      final server = await _AudioServer.start(_audioBytes);
      addTearDown(server.close);
      final progress = <(int, int)>[];

      final localPath = await RemoteAudioImportService.download(
        url: server.audioUri.toString(),
        provider: 'Openverse',
        assetId: 'openverse-42',
        suggestedFileName: 'cinematic-whoosh.MP3',
        documentsDirectoryOverride: documents,
        onProgress: (received, total) => progress.add((received, total)),
      );

      expect(
        localPath,
        p.join(
          documents.path,
          'CaptionCraft',
          'media',
          'Openverse_openverse-42.mp3',
        ),
      );
      expect(await File(localPath).readAsBytes(), _audioBytes);
      expect(await File('$localPath.part').exists(), isFalse);
      expect(server.requests, ['/audio/effect.mp3']);
      expect(progress, isNotEmpty);
      expect(progress.last, (_audioBytes.length, _audioBytes.length));
    });

    test('returns a cache hit without a second network request', () async {
      final documents = await _temporaryDirectory();
      final server = await _AudioServer.start(_audioBytes);
      addTearDown(server.close);
      final cacheProgress = <(int, int)>[];

      Future<String> download({RemoteAudioDownloadProgress? onProgress}) {
        return RemoteAudioImportService.download(
          url: server.audioUri.toString(),
          provider: 'Openverse',
          assetId: 'cached',
          documentsDirectoryOverride: documents,
          onProgress: onProgress,
        );
      }

      final firstPath = await download();
      final secondPath = await download(
        onProgress: (received, total) => cacheProgress.add((received, total)),
      );

      expect(secondPath, firstPath);
      expect(server.requests, hasLength(1));
      expect(cacheProgress, [(_audioBytes.length, _audioBytes.length)]);
    });

    test('revalidates cached audio before trusting it', () async {
      final documents = await _temporaryDirectory();
      final server = await _AudioServer.start(_audioBytes);
      addTearDown(server.close);
      var validations = 0;

      Future<String> download() => RemoteAudioImportService.download(
        url: server.audioUri.toString(),
        provider: 'Openverse',
        assetId: 'validated-cache',
        documentsDirectoryOverride: documents,
        validator: (path) async {
          validations++;
          return await File(path).length() == _audioBytes.length;
        },
      );

      final firstPath = await download();
      final secondPath = await download();

      expect(secondPath, firstPath);
      expect(validations, 2);
      expect(server.requests, hasLength(1));
    });

    test('never commits a payload that fails audio validation', () async {
      final documents = await _temporaryDirectory();
      final server = await _AudioServer.start(_audioBytes);
      addTearDown(server.close);

      await expectLater(
        RemoteAudioImportService.download(
          url: server.audioUri.toString(),
          provider: 'Openverse',
          assetId: 'not-audio',
          documentsDirectoryOverride: documents,
          validator: (_) async => false,
        ),
        throwsA(
          isA<RemoteAudioImportException>().having(
            (error) => error.message,
            'message',
            contains('usable audio'),
          ),
        ),
      );

      await _expectMediaDirectoryHasNoFiles(documents);
    });

    test('cancellation during validation prevents the final commit', () async {
      final documents = await _temporaryDirectory();
      final server = await _AudioServer.start(_audioBytes);
      addTearDown(server.close);
      final cancelToken = CancelToken();

      await expectLater(
        RemoteAudioImportService.download(
          url: server.audioUri.toString(),
          provider: 'Openverse',
          assetId: 'cancel-during-validation',
          documentsDirectoryOverride: documents,
          cancelToken: cancelToken,
          validator: (_) async {
            cancelToken.cancel('library closed');
            return true;
          },
        ),
        throwsA(
          isA<RemoteAudioImportException>().having(
            (error) => error.message,
            'message',
            contains('cancelled'),
          ),
        ),
      );

      await _expectMediaDirectoryHasNoFiles(documents);
    });

    test('rejects unsafe URLs before creating storage', () async {
      final documents = await _temporaryDirectory();

      for (final url in [
        '',
        'not a URL',
        'ftp://media.example.test/effect.mp3',
        'http://media.example.test/effect.mp3',
        'https://user:password@media.example.test/effect.mp3',
        'https:///missing-host.mp3',
      ]) {
        await expectLater(
          RemoteAudioImportService.download(
            url: url,
            provider: 'Openverse',
            assetId: 'invalid',
            documentsDirectoryOverride: documents,
          ),
          throwsA(isA<RemoteAudioImportException>()),
          reason: url,
        );
      }

      expect(
        await Directory(p.join(documents.path, 'CaptionCraft')).exists(),
        isFalse,
      );
    });

    test('rejects unsupported file types before creating storage', () async {
      final documents = await _temporaryDirectory();

      await expectLater(
        RemoteAudioImportService.download(
          url: 'https://media.example.test/payload.exe',
          provider: 'Openverse',
          assetId: 'unsupported',
          suggestedFileName: 'payload.bin',
          documentsDirectoryOverride: documents,
        ),
        throwsA(
          isA<RemoteAudioImportException>().having(
            (error) => error.message,
            'message',
            contains('not supported'),
          ),
        ),
      );

      expect(
        await Directory(p.join(documents.path, 'CaptionCraft')).exists(),
        isFalse,
      );
    });

    test('supports every allowed extension', () async {
      final documents = await _temporaryDirectory();
      final server = await _AudioServer.start(_audioBytes);
      addTearDown(server.close);

      for (final extension in const [
        'mp3',
        'wav',
        'ogg',
        'flac',
        'm4a',
        'aac',
      ]) {
        final path = await RemoteAudioImportService.download(
          url: server.audioUri.toString(),
          provider: 'Openverse',
          assetId: extension,
          suggestedFileName: 'effect.$extension',
          documentsDirectoryOverride: documents,
        );
        expect(p.extension(path), '.$extension');
      }
    });

    test('cancels and removes partial data', () async {
      final documents = await _temporaryDirectory();
      final cancelToken = CancelToken();
      final dio = _CancellingDio();
      addTearDown(() => dio.close(force: true));

      await expectLater(
        RemoteAudioImportService.download(
          url: 'https://media.example.test/cancelled.mp3',
          provider: 'Openverse',
          assetId: 'cancelled',
          documentsDirectoryOverride: documents,
          cancelToken: cancelToken,
          dioOverride: dio,
        ),
        throwsA(
          isA<RemoteAudioImportException>().having(
            (error) => error.message,
            'message',
            contains('cancelled'),
          ),
        ),
      );

      await _expectMediaDirectoryHasNoFiles(documents);
    });

    test('rejects oversized Content-Length and removes partial data', () async {
      final documents = await _temporaryDirectory();
      final dio = Dio()..httpClientAdapter = _OversizedContentLengthAdapter();
      addTearDown(() => dio.close(force: true));

      await expectLater(
        RemoteAudioImportService.download(
          url: 'https://media.example.test/oversized.mp3',
          provider: 'Openverse',
          assetId: 'too-large',
          documentsDirectoryOverride: documents,
          dioOverride: dio,
        ),
        throwsA(
          isA<RemoteAudioImportException>().having(
            (error) => error.message,
            'message',
            contains('128 MB'),
          ),
        ),
      );

      await _expectMediaDirectoryHasNoFiles(documents);
    });

    test('sanitizes provider and asset identifiers', () async {
      final documents = await _temporaryDirectory();
      final server = await _AudioServer.start(_audioBytes);
      addTearDown(server.close);

      final localPath = await RemoteAudioImportService.download(
        url: server.audioUri.toString(),
        provider: '../Openverse',
        assetId: r'..\sound:42',
        documentsDirectoryOverride: documents,
      );

      final mediaDirectory = p.join(documents.path, 'CaptionCraft', 'media');
      expect(p.dirname(localPath), mediaDirectory);
      expect(p.basename(localPath), '_Openverse__sound_42.mp3');
      expect(p.isWithin(mediaDirectory, localPath), isTrue);
    });
  });
}

Future<Directory> _temporaryDirectory() async {
  final directory = await Directory.systemTemp.createTemp(
    'caption_craft_remote_audio_test_',
  );
  addTearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });
  return directory;
}

Future<void> _expectMediaDirectoryHasNoFiles(Directory documents) async {
  final mediaDirectory = Directory(
    p.join(documents.path, 'CaptionCraft', 'media'),
  );
  expect(await mediaDirectory.exists(), isTrue);
  final files = await mediaDirectory
      .list(recursive: true)
      .where((entity) => entity is File)
      .toList();
  expect(files, isEmpty);
}

class _AudioServer {
  final HttpServer _server;
  final List<int> _bytes;
  final List<String> requests = [];

  _AudioServer._(this._server, this._bytes) {
    _server.listen(_handleRequest);
  }

  static Future<_AudioServer> start(List<int> bytes) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return _AudioServer._(server, bytes);
  }

  Uri get audioUri => Uri.parse(
    'http://${_server.address.address}:${_server.port}/audio/effect.mp3',
  );

  Future<void> close() => _server.close(force: true);

  Future<void> _handleRequest(HttpRequest request) async {
    requests.add(request.uri.path);
    if (request.uri.path != '/audio/effect.mp3') {
      request.response.statusCode = HttpStatus.notFound;
    } else {
      request.response.headers.contentType = ContentType('audio', 'mpeg');
      request.response.contentLength = _bytes.length;
      request.response.add(_bytes);
    }
    await request.response.close();
  }
}

class _CancellingDio extends DioForNative {
  @override
  Future<Response> download(
    String urlPath,
    dynamic savePath, {
    ProgressCallback? onReceiveProgress,
    Map<String, dynamic>? queryParameters,
    CancelToken? cancelToken,
    bool deleteOnError = true,
    FileAccessMode fileAccessMode = FileAccessMode.write,
    String lengthHeader = Headers.contentLengthHeader,
    Object? data,
    Options? options,
  }) async {
    await File(savePath as String).writeAsBytes(const [1, 2, 3]);
    cancelToken?.cancel('cancelled by test');
    throw DioException.requestCancelled(
      requestOptions: RequestOptions(path: urlPath),
      reason: cancelToken?.cancelError,
    );
  }
}

class _OversizedContentLengthAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromBytes(
      const [1, 2, 3],
      HttpStatus.ok,
      headers: {
        Headers.contentLengthHeader: [
          '${RemoteAudioImportService.maxDownloadBytes + 1}',
        ],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
