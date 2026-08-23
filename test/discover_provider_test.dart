import 'dart:async';

import 'package:caption_craft/core/utils/discover_download_manager.dart';
import 'package:caption_craft/features/editor/models/discover_models.dart';
import 'package:caption_craft/features/editor/providers/discover_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'DiscoverNotifier exposes inspection, acknowledgement, and queue state',
    () async {
      final facade = _FakeDiscoverFacade();
      final notifier = DiscoverNotifier(facade);
      addTearDown(() {
        notifier.dispose();
        facade.dispose();
      });

      await notifier.initialize();
      expect(notifier.state.isInitialized, isTrue);
      expect(notifier.state.downloads, isEmpty);

      final info = await notifier.inspectYoutube(
        'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
      );
      expect(info, same(facade.info));
      expect(notifier.state.youtubeInfo, same(facade.info));
      expect(notifier.state.permittedContentAcknowledged, isFalse);

      notifier.setPermittedContentAcknowledged(true);
      final queued = await notifier.enqueueYoutube(
        info: facade.info,
        format: facade.info.formats.single,
      );

      expect(queued, isNotNull);
      expect(facade.lastAcknowledgement, isTrue);
      expect(notifier.state.permittedContentAcknowledged, isFalse);
      expect(notifier.state.downloads.single.id, 'queued-youtube');
    },
  );

  test('DiscoverNotifier turns facade errors into bounded UI state', () async {
    final facade = _FakeDiscoverFacade()
      ..inspectionError = StateError('not available');
    final notifier = DiscoverNotifier(facade);
    addTearDown(() {
      notifier.dispose();
      facade.dispose();
    });

    final result = await notifier.inspectYoutube(
      'https://youtu.be/dQw4w9WgXcQ',
    );

    expect(result, isNull);
    expect(notifier.state.isInspectingYoutube, isFalse);
    expect(notifier.state.errorMessage, contains('not available'));
    notifier.clearError();
    expect(notifier.state.errorMessage, isNull);
  });
}

class _FakeDiscoverFacade implements DiscoverDownloadFacade {
  final StreamController<List<DiscoverDownloadItem>> _controller =
      StreamController<List<DiscoverDownloadItem>>.broadcast(sync: true);
  List<DiscoverDownloadItem> _items = <DiscoverDownloadItem>[];
  Object? inspectionError;
  bool? lastAcknowledgement;

  final YoutubeVideoInfo info = const YoutubeVideoInfo(
    videoId: 'dQw4w9WgXcQ',
    canonicalUrl: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
    title: 'Example',
    author: 'Creator',
    duration: Duration(seconds: 10),
    formats: <YoutubeFormatOption>[
      YoutubeFormatOption(
        id: 'muxed:18',
        label: '360p · MP4',
        kind: YoutubeDownloadKind.muxedVideo,
        container: 'mp4',
        videoFormatTag: 18,
      ),
    ],
  );

  @override
  Stream<List<DiscoverDownloadItem>> get items => _controller.stream;

  @override
  List<DiscoverDownloadItem> get currentItems =>
      List<DiscoverDownloadItem>.unmodifiable(_items);

  @override
  Future<void> initialize() async {}

  @override
  Future<YoutubeVideoInfo> inspectYoutube(String url) async {
    final error = inspectionError;
    if (error != null) throw error;
    return info;
  }

  @override
  Future<DiscoverDownloadItem> enqueueDirect(
    DiscoverDownloadRequest request,
  ) async {
    final item = _item(
      id: 'queued-direct',
      source: DiscoverDownloadSource.direct,
      sourceUrl: request.url,
      kind: request.kind,
    );
    _replace(item);
    return item;
  }

  @override
  Future<DiscoverDownloadItem> enqueueYoutube({
    required YoutubeVideoInfo info,
    required YoutubeFormatOption format,
    required bool permittedContentAcknowledged,
    String? outputFileName,
  }) async {
    lastAcknowledgement = permittedContentAcknowledged;
    if (!permittedContentAcknowledged) throw StateError('permission required');
    final item = _item(
      id: 'queued-youtube',
      source: DiscoverDownloadSource.youtube,
      sourceUrl: info.canonicalUrl,
      kind: DiscoverMediaKind.video,
    );
    _replace(item);
    return item;
  }

  DiscoverDownloadItem _item({
    required String id,
    required DiscoverDownloadSource source,
    required String sourceUrl,
    required DiscoverMediaKind kind,
  }) {
    final now = DateTime.utc(2026, 8, 11);
    return DiscoverDownloadItem(
      id: id,
      source: source,
      status: DiscoverDownloadStatus.queued,
      sourceUrl: sourceUrl,
      displayName: id,
      fileName: '$id.mp4',
      kind: kind,
      receivedBytes: 0,
      createdAt: now,
      updatedAt: now,
    );
  }

  void _replace(DiscoverDownloadItem item) {
    _items = <DiscoverDownloadItem>[item];
    _controller.add(currentItems);
  }

  @override
  Future<void> cancel(String id) async {}

  @override
  Future<void> retry(String id) async {}

  @override
  Future<void> delete(String id) async {
    _items = _items.where((item) => item.id != id).toList();
    _controller.add(currentItems);
  }

  @override
  Future<bool> open(String id) async => true;

  @override
  void dispose() {
    unawaited(_controller.close());
  }
}
