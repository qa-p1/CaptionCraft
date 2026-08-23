import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:caption_craft/core/utils/discover_download_manager.dart';
import 'package:caption_craft/core/utils/youtube_download_service.dart';
import 'package:caption_craft/features/editor/models/discover_models.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('DiscoverDownloadManager', () {
    test(
      'downloads direct media atomically without persisting headers',
      () async {
        final storage = await _temporaryDirectory();
        final dio = _WritingDio(const <int>[
          0x89,
          0x50,
          0x4e,
          0x47,
          0x0d,
          0x0a,
          0x1a,
          0x0a,
          1,
          2,
          3,
        ], mimeType: 'image/png');
        final youtube = _FakeYoutubeService();
        final manager = DiscoverDownloadManager(
          dio: dio,
          youtubeService: youtube,
          storageDirectory: storage,
          idGenerator: () => 'direct-id',
        );
        addTearDown(manager.dispose);
        await manager.initialize();
        final completed = manager.items
            .expand((items) => items)
            .firstWhere(
              (item) => item.status == DiscoverDownloadStatus.completed,
            );

        await manager.enqueueDirect(
          const DiscoverDownloadRequest(
            url: 'https://cdn.example.test/media/no-extension',
            displayName: '../Poster',
            kind: DiscoverMediaKind.image,
            mimeType: 'image/png',
            headers: <String, String>{
              'Cookie': 'private-token=secret',
              'Referer': 'https://example.test/gallery',
              'Host': 'malicious-override.test',
            },
          ),
        );
        final item = await completed.timeout(const Duration(seconds: 2));

        expect(item.canImport, isTrue);
        expect(item.localPath, isNotNull);
        expect(p.isWithin(storage.path, item.localPath!), isTrue);
        expect(await File(item.localPath!).readAsBytes(), dio.bytes);
        expect(dio.receivedHeaders['Cookie'], 'private-token=secret');
        expect(dio.receivedHeaders, isNot(contains('Host')));
        expect(await File('${item.localPath}.part').exists(), isFalse);

        final catalog = await File(
          p.join(storage.path, 'downloads.json'),
        ).readAsString();
        expect(catalog, isNot(contains('private-token')));
        expect(catalog, isNot(contains('Cookie')));

        await manager.delete(item.id);
        expect(await File(item.localPath!).exists(), isFalse);
        expect(manager.currentItems, isEmpty);
      },
    );

    test('strips sensitive headers on a cross-host HTTPS redirect', () async {
      final storage = await _temporaryDirectory();
      final dio = _RedirectingDio(
        location: 'https://media-cdn.example.test/final.png',
      );
      final manager = DiscoverDownloadManager(
        dio: dio,
        youtubeService: _FakeYoutubeService(),
        storageDirectory: storage,
        idGenerator: () => 'redirect-id',
      );
      addTearDown(manager.dispose);
      await manager.initialize();
      final completed = manager.items
          .expand((items) => items)
          .firstWhere(
            (item) => item.status == DiscoverDownloadStatus.completed,
          );

      await manager.enqueueDirect(
        const DiscoverDownloadRequest(
          url: 'https://page.example.test/media',
          displayName: 'Redirected image',
          kind: DiscoverMediaKind.image,
          headers: <String, String>{
            'Cookie': 'private-cookie',
            'Authorization': 'Bearer private-token',
            'Referer': 'https://page.example.test/gallery',
            'X-Session-Token': 'private-session',
            'User-Agent': 'CaptionCraft test',
          },
        ),
      );
      final item = await completed.timeout(const Duration(seconds: 2));

      expect(dio.requestedUrls, <String>[
        'https://page.example.test/media',
        'https://media-cdn.example.test/final.png',
      ]);
      expect(dio.headersByRequest.first, contains('Cookie'));
      expect(dio.headersByRequest.last, isNot(contains('Cookie')));
      expect(dio.headersByRequest.last, isNot(contains('Authorization')));
      expect(dio.headersByRequest.last, isNot(contains('Referer')));
      expect(dio.headersByRequest.last, isNot(contains('X-Session-Token')));
      expect(dio.headersByRequest.last['User-Agent'], 'CaptionCraft test');
      expect(dio.followRedirects, everyElement(isFalse));
      await manager.delete(item.id);
    });

    test(
      'rejects an HTTPS to HTTP redirect before the second request',
      () async {
        final storage = await _temporaryDirectory();
        final dio = _RedirectingDio(
          location: 'http://media-cdn.example.test/final.png',
        );
        final manager = DiscoverDownloadManager(
          dio: dio,
          youtubeService: _FakeYoutubeService(),
          storageDirectory: storage,
          idGenerator: () => 'downgrade-id',
        );
        addTearDown(manager.dispose);
        await manager.initialize();
        final failed = manager.items
            .expand((items) => items)
            .firstWhere((item) => item.status == DiscoverDownloadStatus.failed);

        await manager.enqueueDirect(
          const DiscoverDownloadRequest(
            url: 'https://page.example.test/media',
            displayName: 'Unsafe redirect',
            kind: DiscoverMediaKind.image,
            headers: <String, String>{'Cookie': 'do-not-leak'},
          ),
        );
        final item = await failed.timeout(const Duration(seconds: 2));

        expect(dio.requestedUrls, hasLength(1));
        expect(item.errorMessage, contains('HTTPS'));
        expect(
          storage.listSync().whereType<File>().where(
            (file) => file.path.endsWith('.part'),
          ),
          isEmpty,
        );
        await manager.delete(item.id);
      },
    );

    test('reconciles interrupted jobs and removes orphan part files', () async {
      final storage = await _temporaryDirectory();
      final part = File(p.join(storage.path, 'interrupted.mp4.part'));
      await part.writeAsBytes(const <int>[1, 2, 3]);
      final time = DateTime.utc(2026, 8, 11);
      final interrupted = DiscoverDownloadItem(
        id: 'interrupted',
        source: DiscoverDownloadSource.direct,
        status: DiscoverDownloadStatus.downloading,
        sourceUrl: 'https://cdn.example.test/interrupted.mp4',
        displayName: 'Interrupted',
        fileName: 'interrupted.mp4',
        kind: DiscoverMediaKind.video,
        receivedBytes: 3,
        createdAt: time,
        updatedAt: time,
      );
      await File(p.join(storage.path, 'downloads.json')).writeAsString(
        jsonEncode(<String, Object>{
          'version': DiscoverDownloadManager.catalogVersion,
          'items': <Map<String, dynamic>>[interrupted.toJson()],
        }),
      );
      final manager = DiscoverDownloadManager(
        storageDirectory: storage,
        youtubeService: _FakeYoutubeService(),
      );
      addTearDown(manager.dispose);

      await manager.initialize();

      expect(await part.exists(), isFalse);
      expect(manager.currentItems, hasLength(1));
      expect(manager.currentItems.single.status, DiscoverDownloadStatus.failed);
      expect(manager.currentItems.single.canRetry, isTrue);
      expect(manager.currentItems.single.errorMessage, contains('closed'));
    });

    test(
      'requires permission acknowledgement before a YouTube enqueue',
      () async {
        final storage = await _temporaryDirectory();
        final youtube = _FakeYoutubeService();
        final manager = DiscoverDownloadManager(
          storageDirectory: storage,
          youtubeService: youtube,
          idGenerator: () => 'youtube-id',
        );
        addTearDown(manager.dispose);
        await manager.initialize();

        await expectLater(
          manager.enqueueYoutube(
            info: youtube.info,
            format: youtube.info.formats.single,
            permittedContentAcknowledged: false,
          ),
          throwsStateError,
        );
        expect(youtube.downloadCalls, 0);

        final completed = manager.items
            .expand((items) => items)
            .firstWhere(
              (item) => item.status == DiscoverDownloadStatus.completed,
            );
        await manager.enqueueYoutube(
          info: youtube.info,
          format: youtube.info.formats.single,
          permittedContentAcknowledged: true,
        );
        final item = await completed.timeout(const Duration(seconds: 2));

        expect(youtube.downloadCalls, 1);
        expect(item.kind, DiscoverMediaKind.video);
        expect(item.mimeType, 'video/mp4');
        expect(await File(item.localPath!).exists(), isTrue);
        await manager.delete(item.id);
      },
    );

    test(
      'cancel during catalog persistence prevents YouTube startup',
      () async {
        final storage = await _temporaryDirectory();
        final youtube = _FakeYoutubeService();
        final downloadingWriteGate = Completer<void>();
        var shouldDelayDownloading = false;
        final manager = DiscoverDownloadManager(
          storageDirectory: storage,
          youtubeService: youtube,
          idGenerator: () => 'cancel-before-start',
          catalogWriter: (catalog, snapshot) async {
            if (shouldDelayDownloading &&
                snapshot.contains('"status":"downloading"')) {
              await downloadingWriteGate.future;
            }
            await catalog.writeAsString(snapshot, flush: true);
          },
        );
        addTearDown(manager.dispose);
        await manager.initialize();
        shouldDelayDownloading = true;
        final downloading = manager.items
            .expand((items) => items)
            .firstWhere(
              (item) => item.status == DiscoverDownloadStatus.downloading,
            );
        final item = await manager.enqueueYoutube(
          info: youtube.info,
          format: youtube.info.formats.single,
          permittedContentAcknowledged: true,
        );
        await downloading.timeout(const Duration(seconds: 2));
        final cancelled = manager.items
            .expand((items) => items)
            .firstWhere(
              (value) => value.status == DiscoverDownloadStatus.cancelled,
            );

        final cancel = manager.cancel(item.id);
        await cancelled.timeout(const Duration(seconds: 2));
        downloadingWriteGate.complete();
        await cancel.timeout(const Duration(seconds: 2));

        expect(youtube.downloadCalls, 0);
        expect(
          manager.currentItems.single.status,
          DiscoverDownloadStatus.cancelled,
        );
      },
    );

    test(
      'throttles bursty network progress updates to protect UI frames',
      () async {
        final storage = await _temporaryDirectory();
        final dio = _BurstProgressDio();
        final manager = DiscoverDownloadManager(
          dio: dio,
          youtubeService: _FakeYoutubeService(),
          storageDirectory: storage,
          idGenerator: () => 'bursty-progress',
        );
        addTearDown(manager.dispose);
        await manager.initialize();
        var emissions = 0;
        final subscription = manager.items.listen((_) => emissions++);
        addTearDown(subscription.cancel);
        final completed = manager.items
            .expand((items) => items)
            .firstWhere(
              (item) => item.status == DiscoverDownloadStatus.completed,
            );

        await manager.enqueueDirect(
          const DiscoverDownloadRequest(
            url: 'https://cdn.example.test/bursty.png',
            displayName: 'Bursty image',
            kind: DiscoverMediaKind.image,
            mimeType: 'image/png',
          ),
        );
        final item = await completed.timeout(const Duration(seconds: 2));

        expect(dio.progressCallbacks, 100);
        expect(emissions, lessThan(10));
        await manager.delete(item.id);
      },
    );
  });
}

Future<Directory> _temporaryDirectory() async {
  final directory = await Directory.systemTemp.createTemp(
    'discover_manager_test_',
  );
  addTearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });
  return directory;
}

class _WritingDio extends DioForNative {
  _WritingDio(this.bytes, {required this.mimeType});

  final List<int> bytes;
  final String mimeType;
  Map<String, dynamic> receivedHeaders = <String, dynamic>{};

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
    receivedHeaders = Map<String, dynamic>.from(options?.headers ?? const {});
    await File(savePath as String).writeAsBytes(bytes, flush: true);
    onReceiveProgress?.call(bytes.length, bytes.length);
    final requestOptions = RequestOptions(path: urlPath);
    return Response<dynamic>(
      requestOptions: requestOptions,
      statusCode: HttpStatus.ok,
      headers: Headers.fromMap(<String, List<String>>{
        Headers.contentTypeHeader: <String>[mimeType],
        Headers.contentLengthHeader: <String>['${bytes.length}'],
      }),
    );
  }
}

class _BurstProgressDio extends DioForNative {
  final List<int> bytes = <int>[
    0x89,
    0x50,
    0x4e,
    0x47,
    0x0d,
    0x0a,
    0x1a,
    0x0a,
    ...List<int>.filled(92, 1),
  ];
  int progressCallbacks = 0;

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
    await File(savePath as String).writeAsBytes(bytes, flush: true);
    for (var received = 1; received <= bytes.length; received++) {
      progressCallbacks++;
      onReceiveProgress?.call(received, bytes.length);
    }
    return Response<dynamic>(
      requestOptions: RequestOptions(path: urlPath),
      statusCode: HttpStatus.ok,
      headers: Headers.fromMap(<String, List<String>>{
        Headers.contentTypeHeader: <String>['image/png'],
        Headers.contentLengthHeader: <String>['${bytes.length}'],
      }),
    );
  }
}

class _RedirectingDio extends DioForNative {
  _RedirectingDio({required this.location});

  final String location;
  final List<String> requestedUrls = <String>[];
  final List<Map<String, dynamic>> headersByRequest = <Map<String, dynamic>>[];
  final List<bool?> followRedirects = <bool?>[];

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
    requestedUrls.add(urlPath);
    headersByRequest.add(
      Map<String, dynamic>.from(options?.headers ?? const {}),
    );
    followRedirects.add(options?.followRedirects);
    final requestOptions = RequestOptions(path: urlPath);
    if (requestedUrls.length == 1) {
      await File(savePath as String).writeAsBytes(const <int>[1], flush: true);
      onReceiveProgress?.call(1, 1);
      return Response<dynamic>(
        requestOptions: requestOptions,
        statusCode: HttpStatus.found,
        headers: Headers.fromMap(<String, List<String>>{
          HttpHeaders.locationHeader: <String>[location],
        }),
      );
    }
    const bytes = <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1];
    await File(savePath as String).writeAsBytes(bytes, flush: true);
    onReceiveProgress?.call(bytes.length, bytes.length);
    return Response<dynamic>(
      requestOptions: requestOptions,
      statusCode: HttpStatus.ok,
      headers: Headers.fromMap(<String, List<String>>{
        Headers.contentTypeHeader: <String>['image/png'],
      }),
    );
  }
}

class _FakeYoutubeService implements YoutubeMediaService {
  final YoutubeVideoInfo info = const YoutubeVideoInfo(
    videoId: 'dQw4w9WgXcQ',
    canonicalUrl: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
    title: 'Allowed example',
    author: 'Creator',
    duration: Duration(seconds: 30),
    formats: <YoutubeFormatOption>[
      YoutubeFormatOption(
        id: 'muxed:18',
        label: '360p · MP4',
        kind: YoutubeDownloadKind.muxedVideo,
        container: 'mp4',
        videoFormatTag: 18,
        audioFormatTag: 18,
        estimatedBytes: 4,
      ),
    ],
  );

  int downloadCalls = 0;

  @override
  Future<YoutubeVideoInfo> inspect(String url) async => info;

  @override
  Future<YoutubeDownloadResult> download({
    required String jobId,
    required YoutubeVideoInfo info,
    required YoutubeFormatOption format,
    required String outputPath,
    required YoutubeProgressCallback onProgress,
    required void Function() onProcessing,
    int maxBytes = YoutubeDownloadService.defaultMaxBytes,
  }) async {
    downloadCalls++;
    const bytes = <int>[0, 0, 0, 1];
    await File(outputPath).writeAsBytes(bytes, flush: true);
    onProgress(bytes.length, bytes.length);
    return const YoutubeDownloadResult(
      path: '',
      mimeType: 'video/mp4',
      totalBytes: 4,
    ).withPath(outputPath);
  }

  @override
  Future<void> cancel(String jobId) async {}

  @override
  void dispose() {}
}

extension on YoutubeDownloadResult {
  YoutubeDownloadResult withPath(String path) => YoutubeDownloadResult(
    path: path,
    mimeType: mimeType,
    totalBytes: totalBytes,
  );
}
