import 'dart:async';

import 'package:caption_craft/core/utils/instagram_download_service.dart';
import 'package:caption_craft/features/editor/models/discover_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('InstagramDownloadService', () {
    test(
      'chooses complete progressive media before separate DASH video',
      () async {
        final service = InstagramDownloadService(
          extractor: (_) async => {
            'formats': [
              {
                'format_id': '0',
                'url': 'https://media.example/complete.mp4',
                'ext': 'mp4',
                'protocol': 'https',
                'vcodec': 'h264',
                'acodec': 'aac',
              },
              {
                'format_id': 'dash-123v',
                'url': 'https://media.example/video-only.mp4',
                'ext': 'mp4',
                'protocol': 'https',
                'vcodec': 'h264',
                'acodec': 'none',
              },
            ],
          },
        );
        addTearDown(service.dispose);
        final info = await service.inspect(
          'https://www.instagram.com/reel/Caption123/',
        );
        expect(info.media.single.url, 'https://media.example/complete.mp4');
      },
    );

    test('image MIME without an extension remains usable', () async {
      final service = InstagramDownloadService(
        extractor: (_) async => {
          'url': 'https://media.example/image',
          'mime_type': 'image/png',
        },
      );
      addTearDown(service.dispose);
      final info = await service.inspect(
        'https://www.instagram.com/p/Caption123/',
      );
      expect(info.media.single.kind, DiscoverMediaKind.image);
      expect(info.media.single.mimeType, 'image/png');
    });

    test('does not expose adaptive manifests as downloadable media', () async {
      final service = InstagramDownloadService(
        extractor: (_) async => {
          'formats': [
            {
              'format_id': 'dash-123v',
              'url': 'https://media.example/video.m3u8',
              'ext': 'mp4',
              'protocol': 'm3u8_native',
              'vcodec': 'h264',
              'acodec': 'none',
            },
          ],
        },
      );
      addTearDown(service.dispose);

      await expectLater(
        service.inspect('https://www.instagram.com/reel/Caption123/'),
        throwsA(
          isA<InstagramDownloadException>().having(
            (error) => error.kind,
            'kind',
            InstagramFailureKind.unavailable,
          ),
        ),
      );
    });

    test('does not expose protocol-only adaptive manifests', () async {
      final service = InstagramDownloadService(
        extractor: (_) async => {
          'formats': [
            {
              'format_id': 'video-123',
              'url': 'https://media.example/video?token=secret',
              'ext': 'mp4',
              'protocol': 'm3u8_native',
              'vcodec': 'h264',
              'acodec': 'none',
            },
          ],
        },
      );
      addTearDown(service.dispose);

      await expectLater(
        service.inspect('https://www.instagram.com/reel/Caption123/'),
        throwsA(
          isA<InstagramDownloadException>().having(
            (error) => error.kind,
            'kind',
            InstagramFailureKind.unavailable,
          ),
        ),
      );
    });

    test('accepts uppercase HTTPS CDN URLs and removes fragments', () async {
      final service = InstagramDownloadService(
        extractor: (_) async => {
          'url': 'HTTPS://media.example/reel.mp4#fragment',
          'ext': 'mp4',
        },
      );
      addTearDown(service.dispose);

      final info = await service.inspect(
        'https://www.instagram.com/reel/Caption123/',
      );

      final mediaUri = Uri.parse(info.media.single.url);
      expect(mediaUri.scheme.toLowerCase(), 'https');
      expect(mediaUri.path, '/reel.mp4');
      expect(mediaUri.hasFragment, isFalse);
    });

    test('preserves extractor CDN headers through persisted media', () async {
      final service = InstagramDownloadService(
        extractor: (_) async => {
          'url': 'https://media.example/reel.mp4',
          'ext': 'mp4',
          'http_headers': {
            'User-Agent': 'extractor-agent',
            'Referer': 'https://www.instagram.com/',
          },
        },
      );
      addTearDown(service.dispose);
      final info = await service.inspect(
        'https://www.instagram.com/reel/Caption123/',
      );
      final restored = InstagramMediaOption.fromJson(
        info.media.single.toJson(),
      );
      final headers = InstagramDownloadService.downloadHeaders(
        info.canonicalUrl,
        restored.httpHeaders,
      );
      expect(headers['User-Agent'], 'extractor-agent');
      expect(headers['Referer'], 'https://www.instagram.com/');
    });

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

    test(
      'delegates canonical URL to package and maps carousel media',
      () async {
        String? requested;
        final service = InstagramDownloadService(
          extractor: (url) async {
            requested = url;
            return {
              'title': 'A post',
              'uploader': 'creator',
              'entries': [
                {'url': 'https://cdn.example/video.mp4', 'ext': 'mp4'},
                {'url': 'https://cdn.example/photo.jpg', 'ext': 'jpg'},
                {'url': 'http://unsafe.example/video.mp4', 'ext': 'mp4'},
                {'url': 'https://cdn.example/video.mp4', 'ext': 'mp4'},
              ],
            };
          },
        );
        final result = await service.inspect(
          'https://instagram.com/p/Post123/?tracking=1',
        );
        expect(requested, 'https://www.instagram.com/p/Post123/');
        expect(result.media, hasLength(2));
        expect(result.media.last.kind, DiscoverMediaKind.image);
        service.dispose();
      },
    );

    test('a stalled package request times out', () async {
      final service = InstagramDownloadService(
        extractor: (_) => Completer<Map<String, dynamic>>().future,
        inspectionTimeout: const Duration(milliseconds: 10),
      );
      await expectLater(
        service.inspect('https://instagram.com/reel/Video123/'),
        throwsA(
          isA<InstagramDownloadException>().having(
            (e) => e.kind,
            'kind',
            InstagramFailureKind.timedOut,
          ),
        ),
      );
      service.dispose();
    });

    test(
      'dispose interrupts inspection and late completion is ignored',
      () async {
        final pending = Completer<Map<String, dynamic>>();
        final service = InstagramDownloadService(
          extractor: (_) => pending.future,
        );
        final result = service.inspect('https://instagram.com/reel/Video123/');
        final expectation = expectLater(
          result,
          throwsA(
            isA<InstagramDownloadException>().having(
              (e) => e.kind,
              'kind',
              InstagramFailureKind.disposed,
            ),
          ),
        );
        service.dispose();
        await expectation;
        pending.complete({'url': 'https://cdn.example/video.mp4'});
      },
    );

    test('login failures and empty package results are actionable', () async {
      final service = InstagramDownloadService(
        extractor: (_) async => throw StateError('Login required'),
      );
      await expectLater(
        service.inspect('https://instagram.com/reel/Video123/'),
        throwsA(
          isA<InstagramDownloadException>().having(
            (e) => e.kind,
            'kind',
            InstagramFailureKind.privateOrLoginRequired,
          ),
        ),
      );
      service.dispose();
      final empty = InstagramDownloadService(extractor: (_) async => {});
      await expectLater(
        empty.inspect('https://instagram.com/reel/Video123/'),
        throwsA(isA<InstagramDownloadException>()),
      );
      empty.dispose();
    });
  });
}
