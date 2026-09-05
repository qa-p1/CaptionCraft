import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:caption_craft/core/utils/giphy_service.dart';
import 'package:caption_craft/core/utils/pexels_service.dart';
import 'package:caption_craft/core/utils/pixabay_service.dart';
import 'package:caption_craft/features/editor/models/element_library_asset.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('GiphyService', () {
    test(
      'single-flights and caches normalized searches with light previews',
      () async {
        var requestCount = 0;
        final requests = <_CapturedRequest>[];
        final server = await _jsonServer((request) {
          requestCount++;
          requests.add(_CapturedRequest.from(request));
          return {
            'data': [
              {
                'id': 'wave-1',
                'title': 'Ocean wave',
                'url': 'https://giphy.com/gifs/wave-1',
                'images': {
                  'fixed_width_small': {
                    'url': 'https://media.giphy.test/wave-preview.gif',
                    'webp': 'https://media.giphy.test/wave-preview.webp',
                    'width': '100',
                    'height': '80',
                  },
                  'original': {
                    'url': 'https://media.giphy.test/wave-original.gif',
                    'width': '640',
                    'height': '512',
                  },
                },
              },
            ],
          };
        });
        addTearDown(() => server.close(force: true));
        final service = GiphyService(
          apiKey: 'giphy-key',
          baseUrl: _baseUrl(server, 'v1'),
        );

        final concurrent = await Future.wait([
          service.search(query: ' Ocean Wave ', kind: GiphySearchKind.gifs),
          service.search(query: 'Ocean Wave', kind: GiphySearchKind.gifs),
        ]);
        final cached = await service.search(
          query: 'ocean wave',
          kind: GiphySearchKind.gifs,
        );

        expect(requestCount, 1);
        expect(concurrent.first, same(concurrent.last));
        expect(cached, same(concurrent.first));
        expect(cached.single.previewUrl, endsWith('wave-preview.webp'));
        expect(cached.single.originalUrl, endsWith('wave-original.gif'));
        expect(cached.single.sourcePageUrl, 'https://giphy.com/gifs/wave-1');
        expect(cached.single.width, 640);
        expect(cached.single.height, 512);
        expect(requests.single.path, '/v1/gifs/search');
        expect(requests.single.query['q'], 'Ocean Wave');
        expect(requests.single.query['rating'], 'pg-13');

        await service.search(
          query: 'Ocean Wave',
          kind: GiphySearchKind.gifs,
          forceRefresh: true,
        );
        expect(requestCount, 2);
      },
    );

    test('a one-result mixed search does not over-fetch stickers', () async {
      final paths = <String>[];
      final server = await _jsonServer((request) {
        paths.add(request.uri.path);
        return {'data': <dynamic>[]};
      });
      addTearDown(() => server.close(force: true));
      final service = GiphyService(
        apiKey: 'giphy-key',
        baseUrl: _baseUrl(server, 'v1'),
      );

      await service.search(query: '', kind: GiphySearchKind.both, limit: 1);

      expect(paths, ['/v1/gifs/trending']);
    });

    test('rejects a missing API key before making a request', () {
      final service = GiphyService(
        apiKey: '',
        baseUrl: 'http://localhost:1/v1',
      );

      expect(
        service.search(query: '', kind: GiphySearchKind.gifs),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('PexelsService', () {
    test(
      'uses curated/popular endpoints and normalizes photo and video data',
      () async {
        final requests = <_CapturedRequest>[];
        final server = await _jsonServer((request) {
          requests.add(_CapturedRequest.from(request));
          if (request.uri.path.endsWith('/curated')) {
            return {
              'photos': [
                {
                  'id': 71,
                  'width': 4000,
                  'height': 3000,
                  'url': 'https://www.pexels.com/photo/71/',
                  'photographer': 'Ava Lens',
                  'photographer_id': 901,
                  'photographer_url': 'https://www.pexels.com/@ava-lens',
                  'alt': 'Sunlit mountains',
                  'src': {
                    'medium': 'https://images.pexels.test/71-medium.jpg',
                    'original': 'https://images.pexels.test/71-original.jpg',
                  },
                },
                {'id': 72, 'src': <String, dynamic>{}},
              ],
            };
          }
          if (request.uri.path.endsWith('/videos/popular')) {
            return {
              'videos': [
                {
                  'id': 81,
                  'width': 3840,
                  'height': 2160,
                  'url': 'https://www.pexels.com/video/81/',
                  'image': 'https://images.pexels.test/81-poster.jpg',
                  'duration': 8,
                  'user': {
                    'id': 902,
                    'name': 'Milo Motion',
                    'url': 'https://www.pexels.com/@milo-motion',
                  },
                  'video_files': [
                    {
                      'file_type': 'video/mp4',
                      'width': 3840,
                      'height': 2160,
                      'link': 'https://videos.pexels.test/81-4k.mp4',
                    },
                    {
                      'file_type': 'video/webm',
                      'width': 1920,
                      'height': 1080,
                      'link': 'https://videos.pexels.test/81.webm',
                    },
                    {
                      'file_type': 'video/mp4',
                      'width': 1280,
                      'height': 720,
                      'link': 'https://videos.pexels.test/81-720.mp4',
                    },
                  ],
                },
              ],
            };
          }
          return <String, dynamic>{};
        });
        addTearDown(() => server.close(force: true));

        final service = PexelsService(
          apiKey: 'pexels-test-key',
          baseUrl: _baseUrl(server, 'v1'),
        );
        final assets = await service.search(
          query: '  ',
          filter: PexelsMediaFilter.all,
          page: 2,
          limit: 6,
        );

        expect(
          requests.map((request) => request.path),
          unorderedEquals(['/v1/curated', '/v1/videos/popular']),
        );
        for (final request in requests) {
          expect(request.authorization, 'pexels-test-key');
          expect(request.query['page'], '2');
          expect(request.query['per_page'], '3');
          expect(request.query, isNot(contains('query')));
        }

        expect(assets, hasLength(2));
        final photo = assets.first;
        expect(photo.id, 'pexels-photo-71');
        expect(photo.provider, ElementLibraryProvider.pexels);
        expect(photo.mediaKind, ElementLibraryMediaKind.image);
        expect(photo.subtype, ElementLibraryAssetSubtype.photo);
        expect(photo.previewUrl, endsWith('71-medium.jpg'));
        expect(photo.downloadUrl, endsWith('71-original.jpg'));
        expect(photo.width, 4000);
        expect(photo.height, 3000);
        expect(photo.creatorId, '901');
        expect(photo.creatorName, 'Ava Lens');
        expect(photo.attribution, 'Photo by Ava Lens on Pexels');
        expect(photo.sourcePageUrl, 'https://www.pexels.com/photo/71/');

        final video = assets.last;
        expect(video.id, 'pexels-video-81');
        expect(video.mediaKind, ElementLibraryMediaKind.video);
        expect(video.subtype, ElementLibraryAssetSubtype.video);
        expect(video.downloadUrl, endsWith('81-720.mp4'));
        expect(video.previewUrl, endsWith('81-poster.jpg'));
        expect(video.width, 1280);
        expect(video.height, 720);
        expect(video.duration, const Duration(seconds: 8));
        expect(video.creatorName, 'Milo Motion');
        expect(video.attribution, 'Video by Milo Motion on Pexels');
      },
    );

    test('uses search endpoints and forwards a trimmed query', () async {
      final requests = <_CapturedRequest>[];
      final server = await _jsonServer((request) {
        requests.add(_CapturedRequest.from(request));
        return request.uri.path.endsWith('/videos/search')
            ? {'videos': <dynamic>[]}
            : {'photos': <dynamic>[]};
      });
      addTearDown(() => server.close(force: true));
      final service = PexelsService(
        apiKey: 'key',
        baseUrl: _baseUrl(server, 'v1'),
      );

      await service.search(
        query: '  ocean light  ',
        filter: PexelsMediaFilter.photos,
      );
      await service.search(
        query: '  ocean light  ',
        filter: PexelsMediaFilter.videos,
      );

      expect(requests[0].path, '/v1/search');
      expect(requests[1].path, '/v1/videos/search');
      expect(requests[0].query['query'], 'ocean light');
      expect(requests[1].query['query'], 'ocean light');
    });

    test('rejects a missing API key before making a request', () {
      final service = PexelsService(
        apiKey: '  ',
        baseUrl: 'http://localhost:1/v1',
      );

      expect(service.search(), throwsA(isA<StateError>()));
    });

    test(
      'close is idempotent without taking ownership of an injected client',
      () async {
        final adapter = _CloseTrackingAdapter();
        final client = Dio()..httpClientAdapter = adapter;
        final service = PexelsService(
          client: client,
          apiKey: 'key',
          baseUrl: 'https://api.pexels.test/v1',
        );

        service.close();
        service.close();

        await expectLater(service.search(), throwsA(isA<StateError>()));
        expect(adapter.closed, isFalse);
        client.close(force: true);
        expect(adapter.closed, isTrue);
      },
    );
  });

  group('PixabayService', () {
    test(
      'merges all images with videos, enforces safe search, and uses raster vectors',
      () async {
        final requests = <_CapturedRequest>[];
        final server = await _jsonServer((request) {
          requests.add(_CapturedRequest.from(request));
          if (request.uri.path.endsWith('/videos/')) {
            return {
              'hits': [
                {
                  'id': 42,
                  'pageURL': 'https://pixabay.com/videos/id-42/',
                  'tags': 'ocean, wave',
                  'duration': 12,
                  'user_id': 501,
                  'user': 'OceanMaker',
                  'videos': {
                    'large': {
                      'url': 'https://cdn.pixabay.test/42-large.mp4',
                      'width': 3840,
                      'height': 2160,
                      'thumbnail': 'https://cdn.pixabay.test/42-large.jpg',
                    },
                    'medium': {
                      'url': 'https://cdn.pixabay.test/42-medium.mp4',
                      'width': 1920,
                      'height': 1080,
                      'thumbnail': 'https://cdn.pixabay.test/42-medium.jpg',
                    },
                  },
                },
              ],
            };
          }
          return {
            'hits': [
              {
                'id': 31,
                'pageURL': 'https://pixabay.com/vectors/id-31/',
                'type': 'vector',
                'tags': 'leaf, botanical',
                'previewURL': 'https://cdn.pixabay.test/31-preview.jpg',
                'webformatURL': 'https://cdn.pixabay.test/31-web.jpg',
                'largeImageURL': 'https://cdn.pixabay.test/31-large.jpg',
                'vectorURL': 'https://cdn.pixabay.test/31.svg',
                'imageWidth': 2400,
                'imageHeight': 1600,
                'user_id': 502,
                'user': 'VectorArtist',
              },
            ],
          };
        });
        addTearDown(() => server.close(force: true));

        final service = PixabayService(
          apiKey: 'pixabay-test-key',
          baseUrl: _baseUrl(server, 'api'),
        );
        final assets = await service.search(
          filter: PixabayMediaFilter.all,
          page: 3,
          limit: 8,
        );

        expect(
          requests.map((request) => request.path),
          unorderedEquals(['/api/', '/api/videos/']),
        );
        final imageRequest = requests.singleWhere(
          (request) => request.path == '/api/',
        );
        expect(imageRequest.query['key'], 'pixabay-test-key');
        expect(imageRequest.query['image_type'], 'all');
        expect(imageRequest.query['safesearch'], 'true');
        expect(imageRequest.query['order'], 'popular');
        expect(imageRequest.query['page'], '3');
        expect(imageRequest.query['per_page'], '4');
        expect(imageRequest.query, isNot(contains('q')));
        final videoRequest = requests.singleWhere(
          (request) => request.path == '/api/videos/',
        );
        expect(videoRequest.query['safesearch'], 'true');
        expect(videoRequest.query['per_page'], '4');

        expect(assets, hasLength(2));
        final vector = assets.first;
        expect(vector.id, 'pixabay-image-31');
        expect(vector.provider, ElementLibraryProvider.pixabay);
        expect(vector.mediaKind, ElementLibraryMediaKind.image);
        expect(vector.subtype, ElementLibraryAssetSubtype.vector);
        expect(vector.previewUrl, endsWith('31-web.jpg'));
        expect(vector.downloadUrl, endsWith('31-large.jpg'));
        expect(vector.downloadUrl, isNot(endsWith('.svg')));
        expect(vector.width, 2400);
        expect(vector.height, 1600);
        expect(vector.creatorName, 'VectorArtist');
        expect(
          vector.creatorPageUrl,
          'https://pixabay.com/users/VectorArtist-502/',
        );
        expect(vector.attribution, 'Vector by VectorArtist on Pixabay');

        final video = assets.last;
        expect(video.id, 'pixabay-video-42');
        expect(video.mediaKind, ElementLibraryMediaKind.video);
        expect(video.downloadUrl, endsWith('42-medium.mp4'));
        expect(video.previewUrl, endsWith('42-medium.jpg'));
        expect(video.width, 1920);
        expect(video.height, 1080);
        expect(video.duration, const Duration(seconds: 12));
        expect(video.sourcePageUrl, 'https://pixabay.com/videos/id-42/');
        expect(video.attribution, 'Video by OceanMaker on Pixabay');
      },
    );

    test(
      'maps each image filter to the Pixabay image_type parameter',
      () async {
        final requests = <_CapturedRequest>[];
        final server = await _jsonServer((request) {
          requests.add(_CapturedRequest.from(request));
          return {'hits': <dynamic>[]};
        });
        addTearDown(() => server.close(force: true));
        final service = PixabayService(
          apiKey: 'key',
          baseUrl: _baseUrl(server, 'api'),
        );

        for (final filter in const [
          PixabayMediaFilter.photos,
          PixabayMediaFilter.illustrations,
          PixabayMediaFilter.vectors,
        ]) {
          await service.search(
            query: '  space ship  ',
            filter: filter,
            limit: 1,
          );
        }

        expect(requests.map((request) => request.query['image_type']), [
          'photo',
          'illustration',
          'vector',
        ]);
        for (final request in requests) {
          expect(request.query['q'], 'space ship');
          expect(request.query['safesearch'], 'true');
          expect(request.query['per_page'], '3');
        }
      },
    );

    test('caches identical Pixabay requests for 24 hours', () async {
      var requestCount = 0;
      final server = await _jsonServer((request) {
        requestCount++;
        return {'hits': <dynamic>[]};
      });
      addTearDown(() => server.close(force: true));
      final service = PixabayService(
        apiKey: 'cache-key',
        baseUrl: _baseUrl(server, 'cache-api'),
      );

      await service.search(
        query: 'reusable query',
        filter: PixabayMediaFilter.photos,
      );
      await service.search(
        query: ' reusable query ',
        filter: PixabayMediaFilter.photos,
      );

      expect(requestCount, 1);
    });

    test('rejects a missing API key before making a request', () {
      final service = PixabayService(
        apiKey: '',
        baseUrl: 'http://localhost:1/api',
      );

      expect(service.search(), throwsA(isA<StateError>()));
    });

    test(
      'close is idempotent without taking ownership of an injected client',
      () async {
        final adapter = _CloseTrackingAdapter();
        final client = Dio()..httpClientAdapter = adapter;
        final service = PixabayService(
          client: client,
          apiKey: 'key',
          baseUrl: 'https://pixabay.test/api',
        );

        service.close();
        service.close();

        await expectLater(service.search(), throwsA(isA<StateError>()));
        expect(adapter.closed, isFalse);
        client.close(force: true);
        expect(adapter.closed, isTrue);
      },
    );
  });
}

class _CloseTrackingAdapter implements HttpClientAdapter {
  bool closed = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    throw UnimplementedError('No request is expected in this test.');
  }

  @override
  void close({bool force = false}) {
    closed = true;
  }
}

Future<HttpServer> _jsonServer(
  Map<String, dynamic> Function(HttpRequest request) responseFor,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final responseBody = responseFor(request);
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(responseBody));
    await request.response.close();
  });
  return server;
}

String _baseUrl(HttpServer server, String path) =>
    'http://${server.address.address}:${server.port}/$path';

class _CapturedRequest {
  final String path;
  final Map<String, String> query;
  final String? authorization;

  const _CapturedRequest({
    required this.path,
    required this.query,
    required this.authorization,
  });

  factory _CapturedRequest.from(HttpRequest request) => _CapturedRequest(
    path: request.uri.path,
    query: Map<String, String>.from(request.uri.queryParameters),
    authorization: request.headers.value(HttpHeaders.authorizationHeader),
  );
}
