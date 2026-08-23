import 'dart:convert';

import 'package:caption_craft/core/utils/discover_media_extraction_service.dart';
import 'package:caption_craft/core/utils/youtube_download_service.dart';
import 'package:caption_craft/features/editor/models/discover_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Discover models', () {
    test('round trips a YouTube selection and a completed catalog item', () {
      const format = YoutubeFormatOption(
        id: 'split:137+140',
        label: '1080p · MP4',
        kind: YoutubeDownloadKind.splitVideoAudio,
        container: 'mp4',
        videoFormatTag: 137,
        audioFormatTag: 140,
        resolutionLabel: '1080p',
        width: 1920,
        height: 1080,
        framesPerSecond: 30,
        estimatedBytes: 1234,
      );
      const info = YoutubeVideoInfo(
        videoId: 'dQw4w9WgXcQ',
        canonicalUrl: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        title: 'Example',
        author: 'Creator',
        duration: Duration(seconds: 42),
        formats: <YoutubeFormatOption>[format],
      );
      final restoredInfo = YoutubeVideoInfo.fromJson(info.toJson());

      expect(restoredInfo.videoId, info.videoId);
      expect(restoredInfo.duration, const Duration(seconds: 42));
      expect(restoredInfo.formats.single.videoFormatTag, 137);

      final now = DateTime.utc(2026, 8, 11);
      final item = DiscoverDownloadItem(
        id: 'job-1',
        source: DiscoverDownloadSource.youtube,
        status: DiscoverDownloadStatus.completed,
        sourceUrl: info.canonicalUrl,
        displayName: info.title,
        fileName: 'job-1-example.mp4',
        localPath: '/downloads/job-1-example.mp4',
        mimeType: 'video/mp4',
        kind: DiscoverMediaKind.video,
        receivedBytes: 1234,
        totalBytes: 1234,
        createdAt: now,
        updatedAt: now,
        metadata: <String, dynamic>{'youtubeInfo': info.toJson()},
      );
      final restoredItem = DiscoverDownloadItem.fromJson(item.toJson());

      expect(restoredItem.status, DiscoverDownloadStatus.completed);
      expect(restoredItem.progress, 1);
      expect(restoredItem.canImport, isTrue);
      expect(restoredItem.isPausable, isFalse);
    });

    test('direct request serialization deliberately drops session headers', () {
      const request = DiscoverDownloadRequest(
        url: 'https://cdn.example.test/image.jpg',
        displayName: 'Image',
        kind: DiscoverMediaKind.image,
        headers: <String, String>{
          'Cookie': 'private-session=value',
          'Referer': 'https://example.test/',
        },
      );

      final encoded = jsonEncode(request.toJson());
      final restored = DiscoverDownloadRequest.fromJson(request.toJson());

      expect(encoded, isNot(contains('private-session')));
      expect(encoded, isNot(contains('Cookie')));
      expect(restored.headers, isEmpty);
    });
  });

  group('DOM media result normalization', () {
    test('accepts only unique HTTPS candidates and infers their kinds', () {
      final raw = jsonEncode(<Map<String, Object?>>[
        <String, Object?>{
          'url': 'https://images.example.test/photo.webp#fragment',
          'origin': 'imageElement',
          'width': 1200,
          'height': 800,
        },
        <String, Object?>{
          'url': 'https://images.example.test/photo.webp',
          'kind': 'image',
        },
        <String, Object?>{
          'url': 'http://insecure.example.test/video.mp4',
          'kind': 'video',
        },
        <String, Object?>{'url': 'data:image/png;base64,abc', 'kind': 'image'},
        <String, Object?>{
          'url': 'https://cdn.example.test/sound.mp3',
          'origin': 'link',
        },
      ]);

      final candidates = DiscoverMediaExtractionService.normalizeResult(
        raw,
        pageUrl: 'https://example.test/gallery',
      );

      expect(candidates, hasLength(2));
      expect(candidates.first.kind, DiscoverMediaKind.image);
      expect(candidates.first.url, 'https://images.example.test/photo.webp');
      expect(candidates.first.width, 1200);
      expect(candidates.last.kind, DiscoverMediaKind.audio);
      expect(candidates.last.pageUrl, 'https://example.test/gallery');
    });

    test(
      'handles a double-encoded WebView bridge result and enforces limit',
      () {
        final payload = List<Map<String, String>>.generate(
          10,
          (index) => <String, String>{
            'url': 'https://cdn.example.test/$index.mp4',
            'kind': 'video',
          },
        );
        final result = DiscoverMediaExtractionService.normalizeResult(
          jsonEncode(jsonEncode(payload)),
          limit: 3,
        );

        expect(result, hasLength(3));
        expect(
          result.every(
            (candidate) => candidate.kind == DiscoverMediaKind.video,
          ),
          isTrue,
        );
      },
    );

    test('probe script is bounded and excludes non-HTTPS bridge values', () {
      expect(
        DiscoverMediaExtractionService.extractionJavaScript,
        contains('LIMIT = 80'),
      );
      expect(
        DiscoverMediaExtractionService.extractionJavaScript,
        contains("url.protocol === 'https:'"),
      );
      expect(
        DiscoverMediaExtractionService.extractionJavaScript,
        contains('JSON.stringify'),
      );
      expect(
        DiscoverMediaExtractionService.extractionJavaScript,
        contains('data-pin-media'),
      );
      expect(
        DiscoverMediaExtractionService.extractionJavaScript,
        contains("performance.getEntriesByType('resource')"),
      );
    });
  });

  group('YouTube URL validation', () {
    test('accepts supported HTTPS URL shapes', () {
      for (final url in <String>[
        'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        'https://youtu.be/dQw4w9WgXcQ?t=12',
        'https://m.youtube.com/shorts/dQw4w9WgXcQ',
        'https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ',
      ]) {
        expect(
          YoutubeDownloadService.parseVideoIdFromUrl(url),
          'dQw4w9WgXcQ',
          reason: url,
        );
      }
    });

    test('rejects insecure, raw-id, and lookalike inputs', () {
      for (final url in <String>[
        'dQw4w9WgXcQ',
        'http://youtu.be/dQw4w9WgXcQ',
        'https://youtube.com.evil.test/watch?v=dQw4w9WgXcQ',
        'https://www.youtube.com/playlist?list=dQw4w9WgXcQ',
      ]) {
        expect(YoutubeDownloadService.parseVideoIdFromUrl(url), isNull);
      }
    });
  });
}
