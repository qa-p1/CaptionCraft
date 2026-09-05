import 'dart:async';
import 'dart:typed_data';

import 'package:caption_craft/core/utils/instagram_download_service.dart';
import 'package:caption_craft/features/editor/models/discover_models.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('InstagramDownloadService', () {
    test('accepts supported HTTPS Reel and post URLs only', () {
      final reel = InstagramDownloadService.parseUrl(
        'https://m.instagram.com/reels/Caption123/?utm_source=test',
      );
      final post = InstagramDownloadService.parseUrl(
        'https://instagram.com/p/Post_456/',
      );

      expect(reel?.shortcode, 'Caption123');
      expect(
        reel?.canonicalUri.toString(),
        'https://www.instagram.com/reel/Caption123/',
      );
      expect(reel?.isReel, isTrue);
      expect(post?.shortcode, 'Post_456');
      expect(post?.isReel, isFalse);
      expect(
        InstagramDownloadService.parseUrl(
          'https://www.instagram.com/tv/Video789',
        )?.shortcode,
        'Video789',
      );
      expect(
        InstagramDownloadService.parseUrl(
          'http://www.instagram.com/reel/Caption123/',
        ),
        isNull,
      );
      expect(
        InstagramDownloadService.parseUrl(
          'https://example.test/reel/Caption123/',
        ),
        isNull,
      );
      expect(
        InstagramDownloadService.parseUrl(
          'https://www.instagram.com/accounts/login/',
        ),
        isNull,
      );
      expect(
        InstagramDownloadService.parseUrl(
          'https://www.instagram.com:444/reel/Caption123/',
        ),
        isNull,
      );
      expect(
        InstagramDownloadService.parseUrl(
          'https://www.instagram.com/reel//Caption123/',
        ),
        isNull,
      );
      expect(
        InstagramDownloadService.parseUrl(
          'https://www.instagram.com/reel/Caption123/extra',
        ),
        isNull,
      );
      expect(
        InstagramDownloadService.parseUrl(
          'https://www.instagram.com/reel/Caption123//',
        ),
        isNull,
      );
      expect(
        InstagramDownloadService.parseUrl(
          'https://www.instagram.com@evil.example/reel/Caption123/',
        ),
        isNull,
      );
      expect(
        InstagramDownloadService.parseUrl(
          'https://www.instagram.com/reel/${List.filled(2048, 'a').join()}',
        ),
        isNull,
      );
    });

    test('extracts public Reel media and decodes expiring CDN URLs', () async {
      Uri? requested;
      final service = InstagramDownloadService(
        pageLoader: (uri) async {
          requested = uri;
          return r'''
            <html><head>
              <meta property="og:title" content="Creator on Instagram: &quot;A Reel&quot;">
              <meta property="og:image" content="https://cdn.example.test/thumb.jpg?x=1&amp;y=2">
              <meta property="og:video:secure_url" content="https://cdn.example.test/fallback.mp4">
            </head><body>
              <script type="application/json">
                {"video_url":"https:\/\/cdn.example.test\/reel.mp4?token=a\u0026part=b"}
              </script>
            </body></html>
          ''';
        },
      );
      addTearDown(service.dispose);

      final info = await service.inspect(
        'https://www.instagram.com/reel/Caption123/?igsh=test',
      );

      expect(
        requested.toString(),
        'https://www.instagram.com/reel/Caption123/',
      );
      expect(info.shortcode, 'Caption123');
      expect(info.isReel, isTrue);
      expect(info.author, 'Creator');
      expect(info.thumbnailUrl, 'https://cdn.example.test/thumb.jpg?x=1&y=2');
      expect(info.media, isNotEmpty);
      expect(info.media.first.kind, DiscoverMediaKind.video);
      expect(
        info.media.first.url,
        'https://cdn.example.test/reel.mp4?token=a&part=b',
      );
    });

    test('extracts image and video choices from a public post', () async {
      final service = InstagramDownloadService(
        pageLoader: (_) async => r'''
          <meta property="og:title" content="Gallery on Instagram">
          <script type="application/json">
            {
              "display_url":"https:\/\/cdn.example.test\/first.jpg",
              "video_url":"https:\/\/cdn.example.test\/second.mp4",
              "display_url":"https:\/\/cdn.example.test\/third.jpg"
            }
          </script>
        ''',
      );
      addTearDown(service.dispose);

      final info = await service.inspect(
        'https://www.instagram.com/p/Post_456/',
      );

      expect(info.isReel, isFalse);
      expect(info.media.map((media) => media.kind), <DiscoverMediaKind>[
        DiscoverMediaKind.image,
        DiscoverMediaKind.video,
        DiscoverMediaKind.image,
      ]);
      expect(info.media.map((media) => media.id).toSet(), hasLength(3));
    });

    test('rejects pages that do not expose downloadable public media', () {
      final service = InstagramDownloadService(
        pageLoader: (_) async => '<html>Log in to continue</html>',
      );
      addTearDown(service.dispose);

      expect(
        service.inspect('https://www.instagram.com/reel/Caption123/'),
        throwsA(
          isA<InstagramDownloadException>()
              .having(
                (error) => error.kind,
                'kind',
                InstagramFailureKind.privateOrLoginRequired,
              )
              .having(
                (error) => error.message,
                'message',
                contains('requires a login'),
              ),
        ),
      );
    });

    test(
      'never accepts Open Graph assets from a login shell as post media',
      () {
        final service = InstagramDownloadService(
          pageLoader: (_) async => '''
          <html>
            <head>
              <meta property="og:image" content="https://cdn.example.test/instagram-login-brand.jpg">
            </head>
            <body>
              <script>{"display_url":"https://cdn.example.test/login-promo.jpg"}</script>
              Log in to continue
            </body>
          </html>
        ''',
        );
        addTearDown(service.dispose);

        expect(
          service.inspect('https://www.instagram.com/p/Caption123/'),
          throwsA(
            isA<InstagramDownloadException>().having(
              (error) => error.kind,
              'kind',
              InstagramFailureKind.privateOrLoginRequired,
            ),
          ),
        );
      },
    );

    test(
      'falls back to public embed pages when the canonical page is gated',
      () async {
        final requested = <Uri>[];
        final service = InstagramDownloadService(
          pageLoader: (uri) async {
            requested.add(uri);
            if (uri.path == '/reel/Caption123/') {
              return '<html>Log in to continue</html>';
            }
            return r'''
            <meta property="og:title" content="Creator on Instagram: Reel">
            <meta property="og:image" content="https://cdn.example.test/thumb.jpg">
            <script type="application/json">
              {"contentUrl":"https:\/\/cdn.example.test\/fallback.mp4?x=1\u0026y=2"}
            </script>
          ''';
          },
        );
        addTearDown(service.dispose);

        final info = await service.inspect(
          'https://www.instagram.com/reel/Caption123/',
        );

        expect(requested.map((uri) => uri.path), <String>[
          '/reel/Caption123/',
          '/reel/Caption123/embed/',
        ]);
        expect(info.media, hasLength(1));
        expect(info.media.single.kind, DiscoverMediaKind.video);
        expect(
          info.media.single.url,
          'https://cdn.example.test/fallback.mp4?x=1&y=2',
        );
      },
    );

    test(
      'extracts video_versions URLs used by current page payloads',
      () async {
        final service = InstagramDownloadService(
          pageLoader: (_) async => r'''
          <meta property="og:title" content="Creator on Instagram: Reel">
          <script type="application/json">
            {"video_versions":[
              {"type":101,"url":"https:\/\/cdn.example.test\/version.mp4?token=a\u0026b=c"}
            ]}
          </script>
        ''',
        );
        addTearDown(service.dispose);

        final info = await service.inspect(
          'https://www.instagram.com/reel/Caption123/',
        );

        expect(info.media.single.kind, DiscoverMediaKind.video);
        expect(
          info.media.single.url,
          'https://cdn.example.test/version.mp4?token=a&b=c',
        );
      },
    );

    test('classifies rate limits instead of reporting unsupported media', () {
      final service = InstagramDownloadService(
        pageLoader: (_) async => '<html>Please wait a few minutes</html>',
      );
      addTearDown(service.dispose);

      expect(
        service.inspect('https://www.instagram.com/p/Caption123/'),
        throwsA(
          isA<InstagramDownloadException>().having(
            (error) => error.kind,
            'kind',
            InstagramFailureKind.rateLimited,
          ),
        ),
      );
    });

    test('reports Instagram error shells as anonymous access blocking', () {
      final service = InstagramDownloadService(
        pageLoader: (_) async =>
            '<script>{"pageID":"httpErrorPage","root":"PolarisErrorRoot"}</script>',
      );
      addTearDown(service.dispose);

      expect(
        service.inspect('https://www.instagram.com/p/Caption123/'),
        throwsA(
          isA<InstagramDownloadException>().having(
            (error) => error.kind,
            'kind',
            InstagramFailureKind.accessBlocked,
          ),
        ),
      );
    });

    test('distinguishes private and unavailable pages', () async {
      final privateService = InstagramDownloadService(
        pageLoader: (_) async => '<html>This account is private</html>',
      );
      final unavailableService = InstagramDownloadService(
        pageLoader: (_) async => "<html>Page isn't available</html>",
      );
      addTearDown(privateService.dispose);
      addTearDown(unavailableService.dispose);

      await expectLater(
        privateService.inspect('https://www.instagram.com/p/Caption123/'),
        throwsA(
          isA<InstagramDownloadException>()
              .having(
                (error) => error.kind,
                'kind',
                InstagramFailureKind.privateOrLoginRequired,
              )
              .having((error) => error.message, 'message', contains('private')),
        ),
      );
      await expectLater(
        unavailableService.inspect('https://www.instagram.com/p/Caption123/'),
        throwsA(
          isA<InstagramDownloadException>()
              .having(
                (error) => error.kind,
                'kind',
                InstagramFailureKind.unavailable,
              )
              .having(
                (error) => error.message,
                'message',
                contains('unavailable'),
              ),
        ),
      );
    });

    test('maps an injected loader failure to a useful network error', () {
      final service = InstagramDownloadService(
        pageLoader: (_) => Future<String>.error(StateError('socket closed')),
      );
      addTearDown(service.dispose);

      expect(
        service.inspect('https://www.instagram.com/p/Caption123/'),
        throwsA(
          isA<InstagramDownloadException>()
              .having(
                (error) => error.kind,
                'kind',
                InstagramFailureKind.network,
              )
              .having(
                (error) => error.message,
                'message',
                contains('could not be reached'),
              ),
        ),
      );
    });

    test('bounds custom page loaders and reports a timeout', () {
      final never = Completer<String>();
      final service = InstagramDownloadService(
        pageLoader: (_) => never.future,
        pageRequestTimeout: const Duration(milliseconds: 1),
      );
      addTearDown(service.dispose);

      expect(
        service.inspect('https://www.instagram.com/p/Caption123/'),
        throwsA(
          isA<InstagramDownloadException>().having(
            (error) => error.kind,
            'kind',
            InstagramFailureKind.timedOut,
          ),
        ),
      );
    });

    test('bounds the complete fallback sequence, not only each request', () {
      final never = Completer<String>();
      final service = InstagramDownloadService(
        pageLoader: (_) => never.future,
        pageRequestTimeout: const Duration(minutes: 1),
        inspectionTimeout: const Duration(milliseconds: 10),
      );
      addTearDown(service.dispose);

      expect(
        service.inspect('https://www.instagram.com/p/Caption123/'),
        throwsA(
          isA<InstagramDownloadException>().having(
            (error) => error.kind,
            'kind',
            InstagramFailureKind.timedOut,
          ),
        ),
      );
    });

    test('dispose promptly aborts a pending injected page load', () async {
      final pageRequested = Completer<void>();
      final never = Completer<String>();
      final service = InstagramDownloadService(
        pageLoader: (_) {
          if (!pageRequested.isCompleted) pageRequested.complete();
          return never.future;
        },
        pageRequestTimeout: const Duration(minutes: 1),
        inspectionTimeout: const Duration(minutes: 1),
      );

      final inspection = service.inspect(
        'https://www.instagram.com/p/Caption123/',
      );
      await pageRequested.future;
      service.dispose();

      await expectLater(
        inspection.timeout(const Duration(seconds: 1)),
        throwsA(
          isA<InstagramDownloadException>().having(
            (error) => error.kind,
            'kind',
            InstagramFailureKind.disposed,
          ),
        ),
      );
    });

    test('cancellation overrides failures from earlier fallbacks', () async {
      final finalFallbackRequested = Completer<void>();
      final never = Completer<String>();
      var requestCount = 0;
      final service = InstagramDownloadService(
        pageLoader: (_) {
          requestCount++;
          if (requestCount < 3) {
            return Future<String>.value('<html>Log in to continue</html>');
          }
          finalFallbackRequested.complete();
          return never.future;
        },
        pageRequestTimeout: const Duration(minutes: 1),
        inspectionTimeout: const Duration(minutes: 1),
      );

      final inspection = service.inspect(
        'https://www.instagram.com/p/Caption123/',
      );
      await finalFallbackRequested.future;
      service.dispose();

      await expectLater(
        inspection.timeout(const Duration(seconds: 1)),
        throwsA(
          isA<InstagramDownloadException>().having(
            (error) => error.kind,
            'kind',
            InstagramFailureKind.disposed,
          ),
        ),
      );
    });

    test('never follows an Instagram redirect to another authority', () async {
      final requested = <Uri>[];
      final dio = Dio();
      dio.httpClientAdapter = _CallbackHttpClientAdapter((options) async {
        requested.add(options.uri);
        return ResponseBody.fromString(
          '',
          302,
          headers: <String, List<String>>{
            'location': <String>['https://example.test/collect'],
          },
        );
      });
      final service = InstagramDownloadService(dio: dio);
      addTearDown(() {
        service.dispose();
        dio.close(force: true);
      });

      await expectLater(
        service.inspect('https://www.instagram.com/p/Caption123/'),
        throwsA(
          isA<InstagramDownloadException>().having(
            (error) => error.kind,
            'kind',
            InstagramFailureKind.accessBlocked,
          ),
        ),
      );
      expect(requested, isNotEmpty);
      expect(requested.every((uri) => uri.host == 'www.instagram.com'), isTrue);
    });

    test('rejects chunked page bodies above the memory limit', () async {
      final dio = Dio();
      dio.httpClientAdapter = _CallbackHttpClientAdapter((_) async {
        return ResponseBody(
          Stream<Uint8List>.fromIterable(<Uint8List>[
            Uint8List(4 * 1024 * 1024),
            Uint8List(1),
          ]),
          200,
          headers: <String, List<String>>{
            Headers.contentTypeHeader: <String>['text/html; charset=utf-8'],
          },
        );
      });
      final service = InstagramDownloadService(dio: dio);
      addTearDown(() {
        service.dispose();
        dio.close(force: true);
      });

      await expectLater(
        service.inspect('https://www.instagram.com/p/Caption123/'),
        throwsA(
          isA<InstagramDownloadException>().having(
            (error) => error.kind,
            'kind',
            InstagramFailureKind.unsupported,
          ),
        ),
      );
    });

    test('dispose is idempotent and prevents later inspections', () {
      final service = InstagramDownloadService(
        pageLoader: (_) async => '<html></html>',
      );

      service.dispose();
      service.dispose();

      expect(
        service.inspect('https://www.instagram.com/p/Caption123/'),
        throwsA(
          isA<InstagramDownloadException>().having(
            (error) => error.kind,
            'kind',
            InstagramFailureKind.disposed,
          ),
        ),
      );
    });
  });
}

class _CallbackHttpClientAdapter implements HttpClientAdapter {
  _CallbackHttpClientAdapter(this.callback);

  final Future<ResponseBody> Function(RequestOptions options) callback;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => callback(options);

  @override
  void close({bool force = false}) {}
}
