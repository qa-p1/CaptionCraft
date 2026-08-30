import 'dart:async';

import 'package:caption_craft/core/theme/app_theme.dart';
import 'package:caption_craft/core/utils/discover_download_manager.dart';
import 'package:caption_craft/core/utils/discover_media_extraction_service.dart';
import 'package:caption_craft/features/editor/models/discover_models.dart';
import 'package:caption_craft/features/editor/providers/discover_provider.dart';
import 'package:caption_craft/features/editor/widgets/discover_browser_tab.dart';
import 'package:caption_craft/features/editor/widgets/discover_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('keeps all Discover destinations and browser state alive', (
    tester,
  ) async {
    final facade = _FakeDiscoverFacade();
    final browser = _FakeBrowserController();
    await _pumpSheet(tester, facade: facade, browser: browser);

    final fullScreenSheet = find.byKey(
      const ValueKey('discover-fullscreen-sheet'),
    );
    expect(fullScreenSheet, findsOne);
    expect(tester.getSize(fullScreenSheet), const Size(430, 900));
    expect(
      find.text('Find media online, download it, and add it to your timeline.'),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('discover-navigation')), findsOne);
    expect(find.byKey(const ValueKey('discover-nav-browser')), findsOne);
    expect(find.byKey(const ValueKey('discover-nav-youtube')), findsOne);
    expect(find.byKey(const ValueKey('discover-nav-instagram')), findsOne);
    expect(find.byKey(const ValueKey('discover-nav-downloads')), findsOne);
    expect(find.byKey(const ValueKey('fake-browser-surface')), findsOne);

    final address = find.byKey(const ValueKey('discover-browser-address'));
    await tester.enterText(address, 'state survives switching tabs');
    await tester.tap(find.byKey(const ValueKey('discover-nav-youtube')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('discover-youtube-tab')), findsOne);
    await tester.tap(find.byKey(const ValueKey('discover-nav-downloads')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('discover-downloads-tab')), findsOne);
    await tester.tap(find.byKey(const ValueKey('discover-nav-browser')));
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(address).controller!.text,
      'state survives switching tabs',
    );
    expect(browser.loadCalls, isEmpty);
    expect(browser.activeStates, [false, true]);
  });

  testWidgets('modal Discover opens full screen without the old tagline', (
    tester,
  ) async {
    final facade = _FakeDiscoverFacade();
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
      facade.dispose();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [discoverDownloadFacadeProvider.overrideWithValue(facade)],
        child: MaterialApp(
          theme: AppTheme.darkTheme,
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: FilledButton(
                  key: const ValueKey('open-discover'),
                  onPressed: () => showDiscoverSheet<void>(
                    context: context,
                    browserControllerOverride: _FakeBrowserController(),
                    browserSurfaceBuilder: (_, _) =>
                        const ColoredBox(color: kBackground),
                    onAddToTimeline: (_) async {},
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('open-discover')));
    await tester.pump();

    final sheet = find.byKey(const ValueKey('discover-fullscreen-sheet'));
    expect(sheet, findsOne);
    expect(tester.getSize(sheet), const Size(430, 900));
    expect(
      find.text('Find media online, download it, and add it to your timeline.'),
      findsNothing,
    );
  });

  testWidgets('browser enforces HTTPS and queues scanned media only', (
    tester,
  ) async {
    const candidate = DiscoveredMediaCandidate(
      url: 'https://cdn.example.test/poster.jpg',
      kind: DiscoverMediaKind.image,
      origin: DiscoverMediaOrigin.imageElement,
      pageUrl: 'https://example.test/gallery',
      title: 'Example image',
      mimeType: 'image/jpeg',
    );
    final facade = _FakeDiscoverFacade();
    final browser = _FakeBrowserController(scanResults: const [candidate]);
    final imported = <DiscoverDownloadItem>[];
    await _pumpSheet(
      tester,
      facade: facade,
      browser: browser,
      onAddToTimeline: (item) async => imported.add(item),
    );

    final address = find.byKey(const ValueKey('discover-browser-address'));
    await tester.enterText(address, 'http://insecure.example.test/media');
    await tester.tap(find.byKey(const ValueKey('discover-browser-go')));
    await tester.pumpAndSettle();
    expect(browser.loadCalls, isEmpty);
    expect(find.textContaining('HTTPS'), findsOne);

    await tester.enterText(address, 'example.test/gallery');
    await tester.tap(find.byKey(const ValueKey('discover-browser-go')));
    await tester.pumpAndSettle();
    expect(browser.loadCalls.single.scheme, 'https');

    await tester.tap(find.byKey(const ValueKey('discover-browser-scan')));
    await tester.pumpAndSettle();
    expect(browser.scanLimits, [DiscoverMediaExtractionService.maxCandidates]);
    expect(
      find.byKey(
        const ValueKey(
          'discover-browser-candidate-https://cdn.example.test/poster.jpg',
        ),
      ),
      findsOne,
    );

    final candidateAdd = find.byKey(
      const ValueKey(
        'discover-browser-add-https://cdn.example.test/poster.jpg',
      ),
    );
    final candidateGrid = find.descendant(
      of: find.byKey(const ValueKey('discover-browser-candidate-grid')),
      matching: find.byType(Scrollable),
    );
    await tester.drag(candidateGrid, const Offset(0, -140));
    await tester.pumpAndSettle();
    await tester.tap(candidateAdd);
    await tester.pump(const Duration(milliseconds: 300));
    expect(facade.directRequests, hasLength(1));
    expect(facade.directRequests.single.url, candidate.url);
    expect(facade.directRequests.single.headers['Cookie'], 'session=fake');
    facade.completeDirect(
      facade.currentItems.single.id,
      localPath: r'C:\downloads\poster.jpg',
    );
    await tester.pump();
    expect(imported, isEmpty);
    expect(find.text('Download added. Track it in Downloads.'), findsOne);
    await tester.tap(candidateAdd);
    await tester.pump();
    expect(facade.directRequests, hasLength(1));
    expect(
      find.byKey(
        const ValueKey(
          'discover-browser-download-https://cdn.example.test/poster.jpg',
        ),
      ),
      findsNothing,
    );
  });

  testWidgets('YouTube inspection exposes formats and requires permission', (
    tester,
  ) async {
    final facade = _FakeDiscoverFacade(youtubeInfo: _youtubeInfo());
    final imported = <DiscoverDownloadItem>[];
    await _pumpSheet(
      tester,
      facade: facade,
      browser: _FakeBrowserController(),
      initialDestination: DiscoverDestination.youtube,
      onAddToTimeline: (item) async => imported.add(item),
    );

    await tester.enterText(
      find.byKey(const ValueKey('discover-youtube-url')),
      'https://www.youtube.com/watch?v=abc123',
    );
    await tester.tap(find.byKey(const ValueKey('discover-youtube-inspect')));
    await tester.pumpAndSettle();

    expect(facade.inspectedUrls, hasLength(1));
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Text && widget.data == 'A test video',
      ),
      findsOne,
    );
    expect(
      find.byKey(
        const ValueKey(
          'discover-youtube-kind-YoutubeDownloadKind.splitVideoAudio',
        ),
      ),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('discover-youtube-kind-splitVideoAudio')),
      findsOne,
    );
    final audioKind = find.byKey(
      const ValueKey('discover-youtube-kind-audioOnly'),
    );
    await tester.tap(audioKind);
    await tester.pump();
    expect(tester.widget<ChoiceChip>(audioKind).selected, isTrue);
    final splitKind = find.byKey(
      const ValueKey('discover-youtube-kind-splitVideoAudio'),
    );
    await tester.tap(splitKind);
    await tester.pump();
    expect(tester.widget<ChoiceChip>(splitKind).selected, isTrue);

    final download = find.byKey(const ValueKey('discover-youtube-download'));
    await tester.scrollUntilVisible(
      download,
      250,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('discover-youtube-options')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(tester.widget<ButtonStyleButton>(download).onPressed, isNull);
    final permission = find.byKey(
      const ValueKey('discover-youtube-permission'),
    );
    await tester.ensureVisible(permission);
    await tester.tap(permission);
    await tester.pump();
    await tester.ensureVisible(download);
    expect(tester.widget<ButtonStyleButton>(download).onPressed, isNotNull);
    await tester.tap(download);
    await tester.pump(const Duration(milliseconds: 300));

    expect(facade.youtubeRequests, hasLength(1));
    expect(facade.youtubeRequests.single.acknowledged, isTrue);
    expect(
      facade.youtubeRequests.single.format.kind,
      YoutubeDownloadKind.splitVideoAudio,
    );
    expect(imported, isEmpty);
    expect(
      find.text('YouTube download added. Track it in Downloads.'),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('discover-youtube-active-download')),
      findsOne,
    );
  });

  testWidgets('Instagram inspection exposes media and requires permission', (
    tester,
  ) async {
    final facade = _FakeDiscoverFacade(instagramInfo: _instagramInfo());
    await _pumpSheet(
      tester,
      facade: facade,
      browser: _FakeBrowserController(),
      initialDestination: DiscoverDestination.instagram,
    );

    await tester.enterText(
      find.byKey(const ValueKey('discover-instagram-url')),
      'https://www.instagram.com/reel/Caption123/',
    );
    await tester.tap(find.byKey(const ValueKey('discover-instagram-inspect')));
    await tester.pumpAndSettle();

    expect(facade.inspectedInstagramUrls, hasLength(1));
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Text && widget.data == 'A test Reel',
      ),
      findsOne,
    );
    expect(
      find.byKey(const ValueKey('discover-instagram-media-Caption123-0')),
      findsOne,
    );

    final download = find.byKey(const ValueKey('discover-instagram-download'));
    await tester.scrollUntilVisible(
      download,
      220,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('discover-instagram-tab')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(tester.widget<ButtonStyleButton>(download).onPressed, isNull);
    final permission = find.byKey(
      const ValueKey('discover-instagram-permission'),
    );
    await tester.ensureVisible(permission);
    await tester.tap(permission);
    await tester.pump();
    await tester.ensureVisible(download);
    expect(tester.widget<ButtonStyleButton>(download).onPressed, isNotNull);
    await tester.tap(download);
    await tester.pump(const Duration(milliseconds: 300));

    expect(facade.instagramRequests, hasLength(1));
    expect(facade.instagramRequests.single.acknowledged, isTrue);
    expect(facade.instagramRequests.single.media.id, 'Caption123-0');
    expect(
      find.text('Instagram download added. Track it in Downloads.'),
      findsOne,
    );
    expect(
      find.byKey(const ValueKey('discover-instagram-active-download')),
      findsOne,
    );
  });

  testWidgets('download actions work and timeline import closes Discover', (
    tester,
  ) async {
    final now = DateTime.utc(2026, 8, 11);
    final facade = _FakeDiscoverFacade(
      initialItems: [
        _item(
          id: 'ready',
          status: DiscoverDownloadStatus.completed,
          now: now,
          localPath: r'C:\downloads\ready.mp4',
        ),
      ],
    );
    final imported = <DiscoverDownloadItem>[];
    await _pumpSheet(
      tester,
      facade: facade,
      browser: _FakeBrowserController(),
      initialDestination: DiscoverDestination.downloads,
      onAddToTimeline: (item) async => imported.add(item),
    );

    final open = find.byKey(const ValueKey('discover-download-open-ready'));
    await tester.tap(open);
    await tester.pump();
    expect(facade.openedIds, ['ready']);

    final add = find.byKey(const ValueKey('discover-download-add-ready'));
    await tester.tap(add);
    await tester.pump();
    expect(imported.map((item) => item.id), ['ready']);
    expect(
      find.byKey(const ValueKey('discover-fullscreen-sheet')),
      findsNothing,
    );
  });

  testWidgets('download queue exposes retry and cancel actions', (
    tester,
  ) async {
    final now = DateTime.utc(2026, 8, 11);
    final facade = _FakeDiscoverFacade(
      initialItems: [
        _item(
          id: 'active',
          status: DiscoverDownloadStatus.downloading,
          now: now,
          receivedBytes: 50,
          totalBytes: 100,
        ),
        _item(
          id: 'failed',
          status: DiscoverDownloadStatus.failed,
          now: now.subtract(const Duration(seconds: 1)),
          errorMessage: 'Network disconnected.',
        ),
      ],
    );
    await _pumpSheet(
      tester,
      facade: facade,
      browser: _FakeBrowserController(),
      initialDestination: DiscoverDestination.downloads,
    );

    final cancel = find.byKey(
      const ValueKey('discover-download-cancel-active'),
    );
    await tester.tap(cancel);
    await tester.pump();
    expect(facade.cancelledIds, ['active']);

    final retry = find.byKey(const ValueKey('discover-download-retry-failed'));
    final listScrollable = find.descendant(
      of: find.byKey(const ValueKey('discover-download-list')),
      matching: find.byType(Scrollable),
    );
    await tester.drag(listScrollable, const Offset(0, -260));
    await tester.pumpAndSettle();
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await tester.pump();
    expect(facade.retriedIds, ['failed']);
  });
}

Future<void> _pumpSheet(
  WidgetTester tester, {
  required _FakeDiscoverFacade facade,
  required _FakeBrowserController browser,
  DiscoverDestination initialDestination = DiscoverDestination.browser,
  DiscoverTimelineImportCallback? onAddToTimeline,
}) async {
  await tester.binding.setSurfaceSize(const Size(430, 900));
  addTearDown(() async {
    await tester.binding.setSurfaceSize(null);
    facade.dispose();
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [discoverDownloadFacadeProvider.overrideWithValue(facade)],
      child: MaterialApp(
        theme: AppTheme.darkTheme,
        home: _DiscoverSheetHarness(
          initialDestination: initialDestination,
          browser: browser,
          onAddToTimeline: onAddToTimeline ?? (_) async {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _DiscoverSheetHarness extends StatefulWidget {
  const _DiscoverSheetHarness({
    required this.initialDestination,
    required this.browser,
    required this.onAddToTimeline,
  });

  final DiscoverDestination initialDestination;
  final _FakeBrowserController browser;
  final DiscoverTimelineImportCallback onAddToTimeline;

  @override
  State<_DiscoverSheetHarness> createState() => _DiscoverSheetHarnessState();
}

class _DiscoverSheetHarnessState extends State<_DiscoverSheetHarness> {
  var _isOpen = true;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _isOpen
          ? Align(
              alignment: Alignment.bottomCenter,
              child: DiscoverSheet(
                initialDestination: widget.initialDestination,
                browserControllerOverride: widget.browser,
                browserSurfaceBuilder: (_, _) => const ColoredBox(
                  key: ValueKey('fake-browser-surface'),
                  color: kBackground,
                  child: Center(child: Text('Fake browser')),
                ),
                onAddToTimeline: widget.onAddToTimeline,
                onClose: () => setState(() => _isOpen = false),
              ),
            )
          : const SizedBox.shrink(),
    );
  }
}

class _FakeBrowserController
    implements DiscoverBrowserController, DiscoverBrowserLifecycleController {
  _FakeBrowserController({this.scanResults = const []});

  final List<DiscoveredMediaCandidate> scanResults;
  final List<Uri> loadCalls = <Uri>[];
  final List<int> scanLimits = <int>[];
  final List<bool> activeStates = <bool>[];

  @override
  Future<void> setActive(bool active) async => activeStates.add(active);

  @override
  Future<bool> canGoBack() async => false;

  @override
  Future<bool> canGoForward() async => false;

  @override
  Future<Map<String, String>> downloadHeaders(Uri resourceUri) async => const {
    'Referer': 'https://example.test/gallery',
    'Cookie': 'session=fake',
  };

  @override
  Future<void> goBack() async {}

  @override
  Future<void> goForward() async {}

  @override
  Future<void> load(Uri uri) async => loadCalls.add(uri);

  @override
  Future<void> reload() async {}

  @override
  Future<List<DiscoveredMediaCandidate>> scanMedia({required int limit}) async {
    scanLimits.add(limit);
    return scanResults.take(limit).toList(growable: false);
  }

  @override
  Future<void> stop() async {}
}

class _YoutubeRequestRecord {
  const _YoutubeRequestRecord({
    required this.info,
    required this.format,
    required this.acknowledged,
    this.outputFileName,
  });

  final YoutubeVideoInfo info;
  final YoutubeFormatOption format;
  final bool acknowledged;
  final String? outputFileName;
}

class _InstagramRequestRecord {
  const _InstagramRequestRecord({
    required this.info,
    required this.media,
    required this.acknowledged,
    this.outputFileName,
  });

  final InstagramPostInfo info;
  final InstagramMediaOption media;
  final bool acknowledged;
  final String? outputFileName;
}

class _FakeDiscoverFacade implements DiscoverDownloadFacade {
  _FakeDiscoverFacade({
    List<DiscoverDownloadItem> initialItems = const [],
    YoutubeVideoInfo? youtubeInfo,
    InstagramPostInfo? instagramInfo,
  }) : _items = [...initialItems],
       youtubeInfo = youtubeInfo ?? _youtubeInfo(),
       instagramInfo = instagramInfo ?? _instagramInfo();

  final StreamController<List<DiscoverDownloadItem>> _controller =
      StreamController<List<DiscoverDownloadItem>>.broadcast(sync: true);
  List<DiscoverDownloadItem> _items;
  final YoutubeVideoInfo youtubeInfo;
  final InstagramPostInfo instagramInfo;
  final List<DiscoverDownloadRequest> directRequests = [];
  final List<String> inspectedUrls = [];
  final List<String> inspectedInstagramUrls = [];
  final List<_YoutubeRequestRecord> youtubeRequests = [];
  final List<_InstagramRequestRecord> instagramRequests = [];
  final List<String> cancelledIds = [];
  final List<String> retriedIds = [];
  final List<String> deletedIds = [];
  final List<String> openedIds = [];
  int _counter = 0;

  @override
  List<DiscoverDownloadItem> get currentItems => List.unmodifiable(_items);

  @override
  Stream<List<DiscoverDownloadItem>> get items => _controller.stream;

  @override
  Future<void> initialize() async {}

  @override
  Future<DiscoverDownloadItem> enqueueDirect(
    DiscoverDownloadRequest request,
  ) async {
    directRequests.add(request);
    final now = DateTime.utc(2026, 8, 11, 12, 0, _counter++);
    final item = DiscoverDownloadItem(
      id: 'direct-$_counter',
      source: DiscoverDownloadSource.direct,
      status: DiscoverDownloadStatus.queued,
      sourceUrl: request.url,
      pageUrl: request.pageUrl,
      displayName: request.displayName,
      fileName: request.displayName,
      mimeType: request.mimeType,
      kind: request.kind,
      receivedBytes: 0,
      createdAt: now,
      updatedAt: now,
    );
    _replace(items: [item, ..._items]);
    return item;
  }

  @override
  Future<YoutubeVideoInfo> inspectYoutube(String url) async {
    inspectedUrls.add(url);
    return youtubeInfo;
  }

  @override
  Future<InstagramPostInfo> inspectInstagram(String url) async {
    inspectedInstagramUrls.add(url);
    return instagramInfo;
  }

  @override
  Future<DiscoverDownloadItem> enqueueYoutube({
    required YoutubeVideoInfo info,
    required YoutubeFormatOption format,
    required bool permittedContentAcknowledged,
    String? outputFileName,
  }) async {
    if (!permittedContentAcknowledged) {
      throw StateError('Permission acknowledgement is required.');
    }
    youtubeRequests.add(
      _YoutubeRequestRecord(
        info: info,
        format: format,
        acknowledged: permittedContentAcknowledged,
        outputFileName: outputFileName,
      ),
    );
    final now = DateTime.utc(2026, 8, 11, 13, 0, _counter++);
    final item = DiscoverDownloadItem(
      id: 'youtube-$_counter',
      source: DiscoverDownloadSource.youtube,
      status: DiscoverDownloadStatus.downloading,
      sourceUrl: info.canonicalUrl,
      displayName: info.title,
      fileName: '${outputFileName ?? info.title}.${format.container}',
      kind: format.kind == YoutubeDownloadKind.audioOnly
          ? DiscoverMediaKind.audio
          : DiscoverMediaKind.video,
      receivedBytes: 25,
      totalBytes: 100,
      createdAt: now,
      updatedAt: now,
    );
    _replace(items: [item, ..._items]);
    return item;
  }

  @override
  Future<DiscoverDownloadItem> enqueueInstagram({
    required InstagramPostInfo info,
    required InstagramMediaOption media,
    required bool permittedContentAcknowledged,
    String? outputFileName,
  }) async {
    if (!permittedContentAcknowledged) {
      throw StateError('Permission acknowledgement is required.');
    }
    instagramRequests.add(
      _InstagramRequestRecord(
        info: info,
        media: media,
        acknowledged: permittedContentAcknowledged,
        outputFileName: outputFileName,
      ),
    );
    final now = DateTime.utc(2026, 8, 11, 14, 0, _counter++);
    final item = DiscoverDownloadItem(
      id: 'instagram-$_counter',
      source: DiscoverDownloadSource.instagram,
      status: DiscoverDownloadStatus.downloading,
      sourceUrl: info.canonicalUrl,
      pageUrl: info.canonicalUrl,
      displayName: info.title,
      fileName:
          '${outputFileName ?? info.title}.${media.kind == DiscoverMediaKind.video ? 'mp4' : 'jpg'}',
      mimeType: media.mimeType,
      kind: media.kind,
      receivedBytes: 25,
      totalBytes: 100,
      createdAt: now,
      updatedAt: now,
    );
    _replace(items: [item, ..._items]);
    return item;
  }

  @override
  Future<void> cancel(String id) async {
    cancelledIds.add(id);
    _updateStatus(id, DiscoverDownloadStatus.cancelled);
  }

  @override
  Future<void> retry(String id) async {
    retriedIds.add(id);
    _updateStatus(id, DiscoverDownloadStatus.queued);
  }

  @override
  Future<void> delete(String id) async {
    deletedIds.add(id);
    _replace(items: _items.where((item) => item.id != id).toList());
  }

  @override
  Future<bool> open(String id) async {
    openedIds.add(id);
    return true;
  }

  void _updateStatus(String id, DiscoverDownloadStatus status) {
    _replace(
      items: _items
          .map(
            (item) => item.id == id
                ? item.copyWith(status: status, updatedAt: item.updatedAt)
                : item,
          )
          .toList(),
    );
  }

  void completeDirect(String id, {required String localPath}) {
    _replace(
      items: _items
          .map(
            (item) => item.id == id
                ? item.copyWith(
                    status: DiscoverDownloadStatus.completed,
                    localPath: localPath,
                    receivedBytes: 128,
                    totalBytes: 128,
                    updatedAt: item.updatedAt.add(const Duration(seconds: 1)),
                  )
                : item,
          )
          .toList(),
    );
  }

  void _replace({required List<DiscoverDownloadItem> items}) {
    _items = items;
    if (!_controller.isClosed) _controller.add(currentItems);
  }

  @override
  void dispose() {
    if (!_controller.isClosed) unawaited(_controller.close());
  }
}

YoutubeVideoInfo _youtubeInfo() {
  return const YoutubeVideoInfo(
    videoId: 'abc123',
    canonicalUrl: 'https://www.youtube.com/watch?v=abc123',
    title: 'A test video',
    author: 'Test creator',
    duration: Duration(minutes: 2, seconds: 4),
    formats: [
      YoutubeFormatOption(
        id: 'muxed-720',
        label: '720p MP4',
        kind: YoutubeDownloadKind.muxedVideo,
        container: 'mp4',
        videoFormatTag: 22,
        audioFormatTag: 22,
        resolutionLabel: '720p',
        estimatedBytes: 8 * 1024 * 1024,
      ),
      YoutubeFormatOption(
        id: 'split-1080',
        label: '1080p MP4',
        kind: YoutubeDownloadKind.splitVideoAudio,
        container: 'mp4',
        videoFormatTag: 137,
        audioFormatTag: 140,
        resolutionLabel: '1080p',
        estimatedBytes: 18 * 1024 * 1024,
      ),
      YoutubeFormatOption(
        id: 'audio-m4a',
        label: 'Audio M4A',
        kind: YoutubeDownloadKind.audioOnly,
        container: 'm4a',
        audioFormatTag: 140,
        bitrate: 128000,
        estimatedBytes: 2 * 1024 * 1024,
      ),
    ],
  );
}

InstagramPostInfo _instagramInfo() {
  return const InstagramPostInfo(
    shortcode: 'Caption123',
    canonicalUrl: 'https://www.instagram.com/reel/Caption123/',
    title: 'A test Reel',
    author: 'Test creator',
    isReel: true,
    media: <InstagramMediaOption>[
      InstagramMediaOption(
        id: 'Caption123-0',
        url: 'https://cdn.example.test/reel.mp4',
        kind: DiscoverMediaKind.video,
        mimeType: 'video/mp4',
      ),
    ],
  );
}

DiscoverDownloadItem _item({
  required String id,
  required DiscoverDownloadStatus status,
  required DateTime now,
  String? localPath,
  String? errorMessage,
  int receivedBytes = 0,
  int? totalBytes,
}) {
  return DiscoverDownloadItem(
    id: id,
    source: DiscoverDownloadSource.direct,
    status: status,
    sourceUrl: 'https://cdn.example.test/$id.mp4',
    displayName: 'Download $id',
    fileName: '$id.mp4',
    localPath: localPath,
    mimeType: 'video/mp4',
    kind: DiscoverMediaKind.video,
    receivedBytes: receivedBytes,
    totalBytes: totalBytes,
    createdAt: now,
    updatedAt: now,
    errorMessage: errorMessage,
  );
}
