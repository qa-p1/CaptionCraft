import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../models/discover_models.dart';
import '../providers/discover_provider.dart';
import 'discover_browser_tab.dart';
import 'discover_downloads_tab.dart';
import 'discover_instagram_tab.dart';
import 'discover_youtube_tab.dart';

enum DiscoverDestination { browser, youtube, instagram, downloads }

typedef DiscoverTimelineImportCallback =
    Future<void> Function(DiscoverDownloadItem item);

/// Full-screen Discover workspace.
///
/// The tab bodies are kept alive in an [IndexedStack], so browser navigation,
/// inspected social media, and download scroll position survive tab changes.
/// Browser, YouTube, and Instagram actions only enqueue downloads; a completed
/// item enters the timeline solely through Downloads, then closes Discover.
class DiscoverSheet extends ConsumerStatefulWidget {
  final DiscoverTimelineImportCallback onAddToTimeline;
  final VoidCallback? onClose;
  final DiscoverDestination initialDestination;
  final DiscoverBrowserSurfaceBuilder? browserSurfaceBuilder;
  final DiscoverBrowserController? browserControllerOverride;
  final Uri? browserHomeUri;

  const DiscoverSheet({
    super.key,
    required this.onAddToTimeline,
    this.onClose,
    this.initialDestination = DiscoverDestination.browser,
    this.browserSurfaceBuilder,
    this.browserControllerOverride,
    this.browserHomeUri,
  });

  @override
  ConsumerState<DiscoverSheet> createState() => _DiscoverSheetState();
}

class _DiscoverSheetState extends ConsumerState<DiscoverSheet> {
  late int _selectedIndex;

  @override
  void initState() {
    super.initState();
    _selectedIndex = widget.initialDestination.index;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(ref.read(discoverProvider.notifier).initialize());
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(discoverProvider);
    final notifier = ref.read(discoverProvider.notifier);
    final activeDownloads = state.downloads
        .where((item) => !item.isTerminal)
        .length;

    return Material(
      key: const ValueKey('discover-fullscreen-sheet'),
      color: kSurface,
      child: SafeArea(
        child: Column(
          key: const ValueKey('discover-sheet-content'),
          children: [
            SizedBox(
              height: 48,
              child: Padding(
                padding: const EdgeInsets.only(left: 16, right: 6),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Discover',
                        style: TextStyle(
                          color: kTextPrimary,
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('discover-close'),
                      tooltip: 'Close Discover',
                      onPressed:
                          widget.onClose ??
                          () => Navigator.of(context).maybePop(),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
            ),
            const Divider(height: 1, color: kBorder),
            Expanded(
              child: IndexedStack(
                key: const ValueKey('discover-tabs'),
                index: _selectedIndex,
                children: [
                  DiscoverBrowserTab(
                    isActive:
                        _selectedIndex == DiscoverDestination.browser.index,
                    homeUri: widget.browserHomeUri,
                    surfaceBuilder: widget.browserSurfaceBuilder,
                    controllerOverride: widget.browserControllerOverride,
                    onDownload: (candidate, headers) async {
                      final item = await notifier.enqueueDirect(
                        DiscoverDownloadRequest.fromCandidate(
                          candidate,
                          displayName: _candidateName(candidate),
                          headers: headers,
                        ),
                      );
                      if (item == null) {
                        throw StateError(
                          ref.read(discoverProvider).errorMessage ??
                              'The media could not be added to Downloads.',
                        );
                      }
                    },
                  ),
                  DiscoverYoutubeTab(
                    videoInfo: state.youtubeInfo,
                    downloads: state.downloads,
                    isInspecting: state.isInspectingYoutube,
                    isEnqueuing: state.isEnqueuing,
                    permittedContentAcknowledged:
                        state.permittedContentAcknowledged,
                    errorMessage: state.errorMessage,
                    onInspect: (url) async {
                      final info = await notifier.inspectYoutube(url);
                      if (info == null) {
                        throw StateError(
                          ref.read(discoverProvider).errorMessage ??
                              'This YouTube link could not be inspected.',
                        );
                      }
                    },
                    onEnqueue: (info, format, outputFileName) async {
                      final item = await notifier.enqueueYoutube(
                        info: info,
                        format: format,
                        outputFileName: outputFileName,
                      );
                      if (item == null) {
                        throw StateError(
                          ref.read(discoverProvider).errorMessage ??
                              'The YouTube download could not be started.',
                        );
                      }
                    },
                    onAcknowledgementChanged:
                        notifier.setPermittedContentAcknowledged,
                    onCancel: notifier.cancel,
                  ),
                  DiscoverInstagramTab(
                    postInfo: state.instagramInfo,
                    downloads: state.downloads,
                    isInspecting: state.isInspectingInstagram,
                    isEnqueuing: state.isEnqueuing,
                    permittedContentAcknowledged:
                        state.permittedContentAcknowledged,
                    errorMessage: state.errorMessage,
                    onInspect: (url) async {
                      final info = await notifier.inspectInstagram(url);
                      if (info == null) {
                        throw StateError(
                          ref.read(discoverProvider).errorMessage ??
                              'This Instagram link could not be inspected.',
                        );
                      }
                    },
                    onEnqueue: (info, media, outputFileName) async {
                      final item = await notifier.enqueueInstagram(
                        info: info,
                        media: media,
                        outputFileName: outputFileName,
                      );
                      if (item == null) {
                        throw StateError(
                          ref.read(discoverProvider).errorMessage ??
                              'The Instagram download could not be started.',
                        );
                      }
                    },
                    onAcknowledgementChanged:
                        notifier.setPermittedContentAcknowledged,
                    onCancel: notifier.cancel,
                  ),
                  DiscoverDownloadsTab(
                    downloads: state.downloads,
                    isInitialized: state.isInitialized,
                    errorMessage: state.errorMessage,
                    onAddToTimeline: _addToTimelineAndClose,
                    onCancel: notifier.cancel,
                    onRetry: notifier.retry,
                    onDelete: notifier.delete,
                    onOpen: notifier.open,
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: kBorder),
            NavigationBar(
              key: const ValueKey('discover-navigation'),
              height: 68,
              selectedIndex: _selectedIndex,
              onDestinationSelected: (index) {
                FocusManager.instance.primaryFocus?.unfocus();
                setState(() => _selectedIndex = index);
              },
              backgroundColor: kSurface,
              indicatorColor: kAccent.withValues(alpha: 0.18),
              destinations: [
                const NavigationDestination(
                  key: ValueKey('discover-nav-browser'),
                  icon: Icon(Icons.public_outlined),
                  selectedIcon: Icon(Icons.public_rounded, color: kAccent),
                  label: 'Browser',
                ),
                const NavigationDestination(
                  key: ValueKey('discover-nav-youtube'),
                  icon: Icon(Icons.smart_display_outlined),
                  selectedIcon: Icon(
                    Icons.smart_display_rounded,
                    color: kAccent,
                  ),
                  label: 'YouTube',
                ),
                const NavigationDestination(
                  key: ValueKey('discover-nav-instagram'),
                  icon: Icon(Icons.camera_alt_outlined),
                  selectedIcon: Icon(Icons.camera_alt_rounded, color: kAccent),
                  label: 'Instagram',
                ),
                NavigationDestination(
                  key: const ValueKey('discover-nav-downloads'),
                  icon: _downloadsIcon(activeDownloads, selected: false),
                  selectedIcon: _downloadsIcon(activeDownloads, selected: true),
                  label: 'Downloads',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _addToTimelineAndClose(DiscoverDownloadItem item) async {
    await widget.onAddToTimeline(item);
    if (!mounted) return;
    final close = widget.onClose;
    if (close != null) {
      close();
    } else {
      await Navigator.of(context).maybePop();
    }
  }

  Widget _downloadsIcon(int activeDownloads, {required bool selected}) {
    final icon = Icon(
      selected ? Icons.download_for_offline_rounded : Icons.download_outlined,
      color: selected ? kAccent : null,
    );
    if (activeDownloads == 0) return icon;
    return Badge(
      key: const ValueKey('discover-nav-download-badge'),
      label: Text(activeDownloads > 99 ? '99+' : '$activeDownloads'),
      backgroundColor: kAccent,
      child: icon,
    );
  }

  String _candidateName(DiscoveredMediaCandidate candidate) {
    final title = candidate.title?.trim();
    if (title?.isNotEmpty == true) return title!;
    final uri = Uri.tryParse(candidate.url);
    if (uri != null && uri.pathSegments.isNotEmpty) {
      final segment = Uri.decodeComponent(uri.pathSegments.last).trim();
      if (segment.isNotEmpty) return segment;
    }
    return switch (candidate.kind) {
      DiscoverMediaKind.image => 'Downloaded image',
      DiscoverMediaKind.video => 'Downloaded video',
      DiscoverMediaKind.audio => 'Downloaded audio',
      DiscoverMediaKind.unknown => 'Downloaded media',
    };
  }
}

/// Presents [DiscoverSheet] as a modal editor panel.
Future<T?> showDiscoverSheet<T>({
  required BuildContext context,
  required DiscoverTimelineImportCallback onAddToTimeline,
  DiscoverDestination initialDestination = DiscoverDestination.browser,
  DiscoverBrowserSurfaceBuilder? browserSurfaceBuilder,
  DiscoverBrowserController? browserControllerOverride,
  Uri? browserHomeUri,
  Color barrierColor = const Color(0x66000000),
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: false,
    enableDrag: false,
    showDragHandle: false,
    requestFocus: false,
    sheetAnimationStyle: AnimationStyle.noAnimation,
    backgroundColor: Colors.transparent,
    barrierColor: barrierColor,
    builder: (sheetContext) => FractionallySizedBox(
      heightFactor: 1,
      child: DiscoverSheet(
        initialDestination: initialDestination,
        browserSurfaceBuilder: browserSurfaceBuilder,
        browserControllerOverride: browserControllerOverride,
        browserHomeUri: browserHomeUri,
        onAddToTimeline: onAddToTimeline,
        onClose: () => Navigator.of(sheetContext).pop(),
      ),
    ),
  );
}
