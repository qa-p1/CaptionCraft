import 'package:caption_craft/core/utils/instagram_download_service.dart';
import 'package:caption_craft/features/editor/models/discover_models.dart';
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
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('No downloadable media'),
          ),
        ),
      );
    });
  });
}
