import 'dart:io';
import 'dart:typed_data';

import 'package:caption_craft/core/utils/remote_media_import_service.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _downloadBytes = <int>[11, 22, 33, 44, 55, 66];

void main() {
  group('RemoteMediaImportService', () {
    test(
      'explicitly downloads selected media to durable project storage',
      () async {
        final documents = await _temporaryDirectory();
        final server = await _MediaServer.start(_downloadBytes);
        addTearDown(server.close);
        final progress = <(int, int)>[];

        final localPath = await RemoteMediaImportService.download(
          url: server.mediaUri.toString(),
          provider: 'Pexels',
          assetId: 'video-42',
          isVideo: true,
          suggestedFileName: 'Ocean.MOV',
          documentsDirectoryOverride: documents,
          onProgress: (received, total) => progress.add((received, total)),
        );

        expect(
          localPath,
          p.join(
            documents.path,
            'CaptionCraft',
            'media',
            'Pexels_video-42.mov',
          ),
        );
        expect(await File(localPath).readAsBytes(), _downloadBytes);
        expect(await File('$localPath.part').exists(), isFalse);
        expect(server.requests, ['/media/source.mov']);
        expect(progress, isNotEmpty);
        expect(progress.last, (_downloadBytes.length, _downloadBytes.length));
      },
    );

    test(
      'returns a cached selection without making a second HTTP request',
      () async {
        final documents = await _temporaryDirectory();
        final server = await _MediaServer.start(_downloadBytes);
        addTearDown(server.close);

        Future<String> select() => RemoteMediaImportService.download(
          url: server.mediaUri.toString(),
          provider: 'Pixabay',
          assetId: 'asset-7',
          isVideo: false,
          suggestedFileName: 'still.webp',
          documentsDirectoryOverride: documents,
        );

        final firstPath = await select();
        final secondPath = await select();

        expect(secondPath, firstPath);
        expect(await File(secondPath).readAsBytes(), _downloadBytes);
        expect(server.requests, hasLength(1));
      },
    );

    test('coalesces concurrent selections into one media request', () async {
      final documents = await _temporaryDirectory();
      final server = await _MediaServer.start(_downloadBytes);
      addTearDown(server.close);

      Future<String> select() => RemoteMediaImportService.download(
        url: server.mediaUri.toString(),
        provider: 'Giphy',
        assetId: 'single-flight',
        isVideo: false,
        suggestedFileName: 'single-flight.gif',
        documentsDirectoryOverride: documents,
      );

      final paths = await Future.wait([select(), select(), select()]);

      expect(paths.toSet(), hasLength(1));
      expect(await File(paths.toSet().single).readAsBytes(), _downloadBytes);
      expect(server.requests, hasLength(1));
    });

    test('preserves GIF media and reuses its durable disk cache', () async {
      final documents = await _temporaryDirectory();
      final server = await _MediaServer.start(_downloadBytes);
      addTearDown(server.close);

      Future<String> importGif() => RemoteMediaImportService.download(
        url: server.mediaUri.toString(),
        provider: 'Giphy',
        assetId: 'gif-42',
        isVideo: false,
        suggestedFileName: 'animated.gif',
        documentsDirectoryOverride: documents,
      );

      final firstPath = await importGif();
      final secondPath = await importGif();

      expect(p.extension(firstPath), '.gif');
      expect(secondPath, firstPath);
      expect(await File(firstPath).readAsBytes(), _downloadBytes);
      expect(server.requests, hasLength(1));
    });

    test('rejects invalid URLs before creating destination storage', () async {
      final documents = await _temporaryDirectory();

      for (final url in [
        '',
        'not a URL',
        'ftp://example.test/file.mp4',
        'https:///missing-host.mp4',
      ]) {
        await expectLater(
          RemoteMediaImportService.download(
            url: url,
            provider: 'Pexels',
            assetId: 'invalid',
            isVideo: true,
            documentsDirectoryOverride: documents,
          ),
          throwsA(
            isA<RemoteMediaImportException>().having(
              (error) => error.message,
              'message',
              contains('URL is invalid'),
            ),
          ),
          reason: url,
        );
      }

      expect(
        await Directory(p.join(documents.path, 'CaptionCraft')).exists(),
        isFalse,
      );
    });

    test('rejects oversized Content-Length and cleans partial data', () async {
      final documents = await _temporaryDirectory();
      final dio = Dio()..httpClientAdapter = _OversizedContentLengthAdapter();
      addTearDown(() => dio.close(force: true));

      await expectLater(
        RemoteMediaImportService.download(
          url: 'https://media.example.test/oversized.mp4',
          provider: 'Pexels',
          assetId: 'too-large-header',
          isVideo: true,
          documentsDirectoryOverride: documents,
          dioOverride: dio,
        ),
        throwsA(
          isA<RemoteMediaImportException>().having(
            (error) => error.message,
            'message',
            contains('512 MB'),
          ),
        ),
      );

      await _expectMediaDirectoryHasNoFiles(documents);
    });

    test(
      'rejects an oversized received body and cleans partial data',
      () async {
        final documents = await _temporaryDirectory();
        final dio = _OversizedBodyDio();
        addTearDown(() => dio.close(force: true));

        await expectLater(
          RemoteMediaImportService.download(
            url: 'https://media.example.test/chunked.mp4',
            provider: 'Pixabay',
            assetId: 'too-large-body',
            isVideo: true,
            documentsDirectoryOverride: documents,
            dioOverride: dio,
          ),
          throwsA(
            isA<RemoteMediaImportException>().having(
              (error) => error.message,
              'message',
              contains('512 MB'),
            ),
          ),
        );

        await _expectMediaDirectoryHasNoFiles(documents);
      },
    );

    test('sanitizes destination segments and untrusted extensions', () async {
      final documents = await _temporaryDirectory();
      final server = await _MediaServer.start(_downloadBytes);
      addTearDown(server.close);

      final localPath = await RemoteMediaImportService.download(
        url: server.mediaUri.toString(),
        provider: '../Pexels',
        assetId: r'..\asset:42',
        isVideo: false,
        suggestedFileName: '../../payload.exe',
        documentsDirectoryOverride: documents,
      );

      final mediaDirectory = p.join(documents.path, 'CaptionCraft', 'media');
      expect(p.dirname(localPath), mediaDirectory);
      expect(p.basename(localPath), '_Pexels__asset_42.jpg');
      expect(p.isWithin(mediaDirectory, localPath), isTrue);
      expect(await File(localPath).readAsBytes(), _downloadBytes);
    });
  });
}

Future<Directory> _temporaryDirectory() async {
  final directory = await Directory.systemTemp.createTemp(
    'caption_craft_remote_media_test_',
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

class _MediaServer {
  final HttpServer _server;
  final List<int> _bytes;
  final List<String> requests = [];

  _MediaServer._(this._server, this._bytes) {
    _server.listen(_handleRequest);
  }

  static Future<_MediaServer> start(List<int> bytes) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return _MediaServer._(server, bytes);
  }

  Uri get mediaUri => Uri.parse(
    'http://${_server.address.address}:${_server.port}/media/source.mov',
  );

  Future<void> close() => _server.close(force: true);

  Future<void> _handleRequest(HttpRequest request) async {
    requests.add(request.uri.path);
    if (request.uri.path != '/media/source.mov') {
      request.response.statusCode = HttpStatus.notFound;
    } else {
      request.response.headers.contentType = ContentType.binary;
      request.response.contentLength = _bytes.length;
      request.response.add(_bytes);
    }
    await request.response.close();
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
          '${RemoteMediaImportService.maxDownloadBytes + 1}',
        ],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _OversizedBodyDio extends DioForNative {
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
    onReceiveProgress?.call(RemoteMediaImportService.maxDownloadBytes + 1, -1);
    throw DioException.requestCancelled(
      requestOptions: RequestOptions(path: urlPath),
      reason: cancelToken?.cancelError,
    );
  }
}
