import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/discover_media_extraction_service.dart';
import '../models/discover_models.dart';

typedef DiscoverBrowserDownloadCallback =
    Future<void> Function(
      DiscoveredMediaCandidate candidate,
      Map<String, String> headers,
    );

typedef DiscoverBrowserSurfaceBuilder =
    Widget Function(BuildContext context, DiscoverBrowserCallbacks callbacks);

/// Small browser-control surface that keeps native WebView types out of tests.
abstract interface class DiscoverBrowserController {
  Future<void> load(Uri uri);

  Future<void> goBack();

  Future<void> goForward();

  Future<void> reload();

  Future<void> stop();

  Future<bool> canGoBack();

  Future<bool> canGoForward();

  Future<List<DiscoveredMediaCandidate>> scanMedia({required int limit});

  Future<Map<String, String>> downloadHeaders(Uri resourceUri);
}

/// Optional lifecycle hook used by native browser surfaces while another
/// Discover destination is visible. Test and custom browser implementations do
/// not need to implement it.
abstract interface class DiscoverBrowserLifecycleController {
  Future<void> setActive(bool active);
}

class DiscoverBrowserCallbacks {
  final ValueChanged<DiscoverBrowserController> onControllerCreated;
  final ValueChanged<Uri?> onNavigationStarted;
  final void Function(Uri? uri, String? title) onNavigationFinished;
  final ValueChanged<int> onProgress;
  final ValueChanged<String> onError;
  final ValueChanged<DiscoveredMediaCandidate> onDownloadRequested;

  const DiscoverBrowserCallbacks({
    required this.onControllerCreated,
    required this.onNavigationStarted,
    required this.onNavigationFinished,
    required this.onProgress,
    required this.onError,
    required this.onDownloadRequested,
  });
}

class DiscoverBrowserTab extends StatefulWidget {
  static final Uri defaultHome = Uri.https('www.google.com');

  final DiscoverBrowserDownloadCallback onDownload;
  final Uri homeUri;
  final DiscoverBrowserSurfaceBuilder? surfaceBuilder;
  final DiscoverBrowserController? controllerOverride;
  final bool isActive;

  DiscoverBrowserTab({
    super.key,
    required this.onDownload,
    this.surfaceBuilder,
    this.controllerOverride,
    this.isActive = true,
    Uri? homeUri,
  }) : homeUri = homeUri ?? defaultHome;

  @override
  State<DiscoverBrowserTab> createState() => _DiscoverBrowserTabState();
}

class _DiscoverBrowserTabState extends State<DiscoverBrowserTab>
    with AutomaticKeepAliveClientMixin {
  static const int _scanLimit = DiscoverMediaExtractionService.maxCandidates;

  late final TextEditingController _addressController;
  DiscoverBrowserController? _browserController;
  Uri? _currentUri;
  String? _pageTitle;
  String? _error;
  int _progress = 0;
  bool _canGoBack = false;
  bool _canGoForward = false;
  bool _showCandidates = false;
  bool _isScanning = false;
  List<DiscoveredMediaCandidate> _candidates = const [];
  final Set<String> _downloadingCandidateUrls = <String>{};
  final Set<String> _queuedCandidateUrls = <String>{};

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _currentUri = widget.homeUri;
    _addressController = TextEditingController(text: widget.homeUri.toString());
    _browserController = widget.controllerOverride;
    if (_browserController != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_refreshNavigationState());
      });
    }
  }

  @override
  void didUpdateWidget(covariant DiscoverBrowserTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controllerOverride, widget.controllerOverride) &&
        widget.controllerOverride != null) {
      _browserController = widget.controllerOverride;
      unawaited(_refreshNavigationState());
    }
    if (oldWidget.isActive != widget.isActive) {
      _updateBrowserActivity();
    }
  }

  @override
  void dispose() {
    _releaseCandidatePreviews(_candidates);
    _addressController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final callbacks = DiscoverBrowserCallbacks(
      onControllerCreated: _handleControllerCreated,
      onNavigationStarted: _handleNavigationStarted,
      onNavigationFinished: _handleNavigationFinished,
      onProgress: _handleProgress,
      onError: _handleError,
      onDownloadRequested: (candidate) =>
          unawaited(_downloadCandidate(candidate)),
    );

    return Column(
      key: const ValueKey('discover-browser-tab'),
      children: [
        _buildAddressBar(),
        _buildNavigationBar(),
        if (_progress > 0 && _progress < 100)
          LinearProgressIndicator(
            key: const ValueKey('discover-browser-progress'),
            value: _progress / 100,
            minHeight: 2,
          ),
        if (_error != null) _buildErrorBanner(),
        const Divider(height: 1, color: kBorder),
        Expanded(
          child: _showCandidates
              ? _buildCandidateBrowser()
              : Stack(
                  fit: StackFit.expand,
                  children: [
                    widget.surfaceBuilder?.call(context, callbacks) ??
                        _NativeDiscoverBrowserSurface(
                          initialUri: widget.homeUri,
                          callbacks: callbacks,
                        ),
                    if (_browserController == null)
                      const IgnorePointer(
                        child: Center(
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _buildAddressBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              key: const ValueKey('discover-browser-address'),
              controller: _addressController,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.go,
              autocorrect: false,
              enableSuggestions: false,
              onSubmitted: (_) => unawaited(_navigateFromAddress()),
              decoration: InputDecoration(
                hintText: 'Search or enter a secure web address',
                prefixIcon: Icon(
                  _currentUri?.scheme == 'https'
                      ? Icons.lock_outline_rounded
                      : Icons.search_rounded,
                  size: 18,
                  color: _currentUri?.scheme == 'https'
                      ? kSuccess
                      : kTextSecondary,
                ),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 11,
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          IconButton.filledTonal(
            key: const ValueKey('discover-browser-go'),
            tooltip: 'Go',
            onPressed: _browserController == null
                ? null
                : () => unawaited(_navigateFromAddress()),
            icon: const Icon(Icons.arrow_forward_rounded, size: 20),
          ),
        ],
      ),
    );
  }

  Widget _buildNavigationBar() {
    return SizedBox(
      height: 46,
      child: Row(
        children: [
          _browserAction(
            key: 'discover-browser-back',
            tooltip: 'Back',
            icon: Icons.arrow_back_rounded,
            enabled: _browserController != null && _canGoBack,
            action: () async {
              await _browserController?.goBack();
              await _refreshNavigationState();
            },
          ),
          _browserAction(
            key: 'discover-browser-forward',
            tooltip: 'Forward',
            icon: Icons.arrow_forward_rounded,
            enabled: _browserController != null && _canGoForward,
            action: () async {
              await _browserController?.goForward();
              await _refreshNavigationState();
            },
          ),
          _browserAction(
            key: 'discover-browser-reload',
            tooltip: _progress > 0 && _progress < 100 ? 'Stop' : 'Reload',
            icon: _progress > 0 && _progress < 100
                ? Icons.close_rounded
                : Icons.refresh_rounded,
            enabled: _browserController != null,
            action: () async {
              if (_progress > 0 && _progress < 100) {
                await _browserController?.stop();
              } else {
                await _browserController?.reload();
              }
            },
          ),
          _browserAction(
            key: 'discover-browser-home',
            tooltip: 'Home',
            icon: Icons.home_outlined,
            enabled: _browserController != null,
            action: () => _navigate(widget.homeUri),
          ),
          const Spacer(),
          if (_pageTitle?.trim().isNotEmpty == true)
            Flexible(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  _pageTitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: kTextSecondary,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          _browserAction(
            key: 'discover-browser-open-external',
            tooltip: 'Open in device browser',
            icon: Icons.open_in_new_rounded,
            enabled: _currentUri?.scheme == 'https',
            action: _openExternally,
          ),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Badge(
              isLabelVisible: _candidates.isNotEmpty,
              label: Text('${_candidates.length}'),
              child: IconButton(
                key: const ValueKey('discover-browser-scan'),
                tooltip: 'Find downloadable media on this page',
                onPressed: _browserController == null || _isScanning
                    ? null
                    : () => unawaited(_scanPage()),
                icon: _isScanning
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.perm_media_outlined, size: 20),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _browserAction({
    required String key,
    required String tooltip,
    required IconData icon,
    required bool enabled,
    required Future<void> Function() action,
  }) {
    return IconButton(
      key: ValueKey(key),
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      onPressed: enabled ? () => unawaited(action()) : null,
      icon: Icon(icon, size: 19),
    );
  }

  Widget _buildErrorBanner() {
    return Container(
      key: const ValueKey('discover-browser-error'),
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
      decoration: BoxDecoration(
        color: kError.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kError.withValues(alpha: 0.45)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded, color: kError, size: 17),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _error!,
              style: const TextStyle(color: kTextPrimary, fontSize: 11),
            ),
          ),
          IconButton(
            tooltip: 'Dismiss',
            visualDensity: VisualDensity.compact,
            onPressed: () => setState(() => _error = null),
            icon: const Icon(Icons.close_rounded, size: 17),
          ),
        ],
      ),
    );
  }

  Widget _buildCandidateBrowser() {
    return Column(
      key: const ValueKey('discover-browser-candidates'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 9, 8, 8),
          child: Row(
            children: [
              IconButton(
                key: const ValueKey('discover-browser-candidates-back'),
                tooltip: 'Back to page',
                onPressed: () => setState(() => _showCandidates = false),
                icon: const Icon(Icons.arrow_back_rounded),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Tap media to add it',
                      style: TextStyle(
                        color: kTextPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      '${_candidates.length} result${_candidates.length == 1 ? '' : 's'} • no extra download menu',
                      style: const TextStyle(
                        color: kTextSecondary,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: kBorder),
        Expanded(
          child: _candidates.isEmpty
              ? _emptyCandidates()
              : LayoutBuilder(
                  builder: (context, constraints) {
                    return GridView.builder(
                      key: const ValueKey('discover-browser-candidate-grid'),
                      padding: const EdgeInsets.all(12),
                      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: constraints.maxWidth >= 900
                            ? 230
                            : 190,
                        mainAxisExtent: 202,
                        mainAxisSpacing: 10,
                        crossAxisSpacing: 10,
                      ),
                      itemCount: _candidates.length,
                      itemBuilder: (context, index) =>
                          _buildCandidateTile(_candidates[index]),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _emptyCandidates() {
    return const Center(
      key: ValueKey('discover-browser-candidates-empty'),
      child: Padding(
        padding: EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.image_not_supported_outlined,
              size: 36,
              color: kTextSecondary,
            ),
            SizedBox(height: 10),
            Text(
              'No direct HTTPS images or videos were found. Dynamic, DRM, and blob media cannot be downloaded here.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: kTextSecondary,
                fontSize: 12,
                height: 1.35,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCandidateTile(DiscoveredMediaCandidate candidate) {
    final downloading = _downloadingCandidateUrls.contains(candidate.url);
    final queued = _queuedCandidateUrls.contains(candidate.url);
    final previewUrl =
        candidate.thumbnailUrl ??
        (candidate.kind == DiscoverMediaKind.image ? candidate.url : null);
    return Card(
      key: ValueKey('discover-browser-candidate-${candidate.url}'),
      clipBehavior: Clip.antiAlias,
      child: Semantics(
        button: true,
        label: queued
            ? '${_candidateTitle(candidate)} is queued'
            : 'Download ${_candidateTitle(candidate)}',
        child: InkWell(
          key: ValueKey('discover-browser-add-${candidate.url}'),
          onTap: downloading || queued
              ? null
              : () => unawaited(_downloadCandidate(candidate)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (previewUrl != null)
                      Image(
                        image: _candidatePreviewProvider(previewUrl),
                        fit: BoxFit.cover,
                        filterQuality: FilterQuality.low,
                        gaplessPlayback: false,
                        excludeFromSemantics: true,
                        errorBuilder: (_, _, _) =>
                            _candidatePlaceholder(candidate),
                      )
                    else
                      _candidatePlaceholder(candidate),
                    Positioned(
                      right: 7,
                      top: 7,
                      child: _kindBadge(candidate.kind),
                    ),
                    if (downloading)
                      ColoredBox(
                        color: Colors.black.withValues(alpha: 0.62),
                        child: const Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              CircularProgressIndicator(strokeWidth: 2),
                              SizedBox(height: 8),
                              Text(
                                'Adding…',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(9, 7, 9, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _candidateTitle(candidate),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: kTextPrimary,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _candidateDetails(candidate),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: kTextSecondary,
                              fontSize: 9,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(
                      queued
                          ? Icons.check_circle_rounded
                          : Icons.download_for_offline_rounded,
                      color: queued ? kSuccess : kAccent,
                      size: 22,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  ImageProvider<Object> _candidatePreviewProvider(String url) {
    return ResizeImage.resizeIfNeeded(420, 280, NetworkImage(url));
  }

  void _releaseCandidatePreviews(
    Iterable<DiscoveredMediaCandidate> candidates,
  ) {
    for (final candidate in candidates) {
      final previewUrl =
          candidate.thumbnailUrl ??
          (candidate.kind == DiscoverMediaKind.image ? candidate.url : null);
      if (previewUrl != null) {
        unawaited(_candidatePreviewProvider(previewUrl).evict());
      }
    }
  }

  Widget _candidatePlaceholder(DiscoveredMediaCandidate candidate) {
    return ColoredBox(
      color: kSurfaceHigh,
      child: Center(
        child: Icon(
          candidate.kind == DiscoverMediaKind.video
              ? Icons.movie_outlined
              : Icons.image_outlined,
          color: kTextSecondary,
          size: 34,
        ),
      ),
    );
  }

  Widget _kindBadge(DiscoverMediaKind kind) {
    final isVideo = kind == DiscoverMediaKind.video;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isVideo ? Icons.play_arrow_rounded : Icons.image_outlined,
              size: 12,
              color: Colors.white,
            ),
            const SizedBox(width: 3),
            Text(
              isVideo ? 'Video' : 'Image',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 9,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _handleControllerCreated(DiscoverBrowserController controller) {
    _browserController = controller;
    if (mounted) {
      setState(() {});
      unawaited(_refreshNavigationState());
      _updateBrowserActivity();
    }
  }

  void _handleNavigationStarted(Uri? uri) {
    if (!mounted) return;
    _releaseCandidatePreviews(_candidates);
    setState(() {
      _currentUri = uri ?? _currentUri;
      _progress = 1;
      _error = null;
      _showCandidates = false;
      _candidates = const [];
      if (uri != null) _addressController.text = uri.toString();
    });
  }

  void _handleNavigationFinished(Uri? uri, String? title) {
    if (!mounted) return;
    setState(() {
      _currentUri = uri ?? _currentUri;
      _pageTitle = title?.trim().isEmpty == true ? null : title;
      _progress = 100;
      if (uri != null) _addressController.text = uri.toString();
    });
    unawaited(_refreshNavigationState());
  }

  void _handleProgress(int value) {
    if (!mounted) return;
    setState(() => _progress = value.clamp(0, 100));
  }

  void _handleError(String message) {
    if (!mounted) return;
    setState(() {
      _progress = 100;
      _error = message.trim().isEmpty
          ? 'This page could not be opened.'
          : message;
    });
  }

  Future<void> _refreshNavigationState() async {
    final controller = _browserController;
    if (controller == null) return;
    try {
      final values = await Future.wait<bool>([
        controller.canGoBack(),
        controller.canGoForward(),
      ]);
      if (!mounted) return;
      setState(() {
        _canGoBack = values[0];
        _canGoForward = values[1];
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _canGoBack = false;
        _canGoForward = false;
      });
    }
  }

  Future<void> _navigateFromAddress() async {
    final value = _addressController.text.trim();
    if (value.isEmpty) return;
    final uri = _secureUriForInput(value);
    if (uri == null) {
      _handleError('Only secure HTTPS pages can be opened in Discover.');
      return;
    }
    await _navigate(uri);
  }

  Uri? _secureUriForInput(String input) {
    final parsed = Uri.tryParse(input);
    if (parsed != null && parsed.hasScheme) {
      if (parsed.scheme.toLowerCase() != 'https' || parsed.host.isEmpty) {
        return null;
      }
      return parsed;
    }
    final looksLikeHost =
        !input.contains(RegExp(r'\s')) &&
        (input.contains('.') || input.toLowerCase() == 'localhost');
    if (looksLikeHost) {
      final hostUri = Uri.tryParse('https://$input');
      if (hostUri != null && hostUri.host.isNotEmpty) return hostUri;
    }
    return Uri.https('www.google.com', '/search', {'q': input});
  }

  Future<void> _navigate(Uri uri) async {
    if (uri.scheme != 'https' || uri.host.isEmpty) {
      _handleError('Only secure HTTPS pages can be opened in Discover.');
      return;
    }
    setState(() {
      _error = null;
      _showCandidates = false;
    });
    await _browserController?.load(uri);
  }

  Future<void> _openExternally() async {
    final uri = _currentUri;
    if (uri == null || uri.scheme != 'https') return;
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened && mounted) _handleError('Could not open the device browser.');
  }

  Future<void> _scanPage() async {
    final controller = _browserController;
    if (controller == null || _isScanning) return;
    setState(() {
      _isScanning = true;
      _error = null;
    });
    try {
      final results = await controller.scanMedia(limit: _scanLimit);
      if (!mounted) return;
      final unique = <String, DiscoveredMediaCandidate>{};
      for (final candidate in results) {
        final uri = Uri.tryParse(candidate.url);
        if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) continue;
        if (candidate.kind != DiscoverMediaKind.image &&
            candidate.kind != DiscoverMediaKind.video) {
          continue;
        }
        unique.putIfAbsent(candidate.url, () => candidate);
        if (unique.length >= _scanLimit) break;
      }
      setState(() {
        _candidates = unique.values.toList(growable: false);
        _showCandidates = true;
      });
    } catch (error) {
      if (mounted) {
        _handleError('Could not inspect this page: ${_friendlyError(error)}');
      }
    } finally {
      if (mounted) setState(() => _isScanning = false);
    }
  }

  Future<void> _downloadCandidate(DiscoveredMediaCandidate candidate) async {
    if (_downloadingCandidateUrls.contains(candidate.url) ||
        _queuedCandidateUrls.contains(candidate.url)) {
      return;
    }
    setState(() => _downloadingCandidateUrls.add(candidate.url));
    try {
      final uri = Uri.parse(candidate.url);
      final headers =
          await _browserController?.downloadHeaders(uri) ?? <String, String>{};
      await widget.onDownload(candidate, headers);
      if (!mounted) return;
      setState(() => _queuedCandidateUrls.add(candidate.url));
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Download added. Track it in Downloads.')),
      );
    } catch (error) {
      if (!mounted) return;
      _handleError('Could not queue this media: ${_friendlyError(error)}');
    } finally {
      if (mounted) {
        setState(() => _downloadingCandidateUrls.remove(candidate.url));
      }
    }
  }

  void _updateBrowserActivity() {
    final controller = _browserController;
    if (controller != null &&
        controller is DiscoverBrowserLifecycleController) {
      unawaited(
        (controller as DiscoverBrowserLifecycleController).setActive(
          widget.isActive,
        ),
      );
    }
  }

  String _candidateTitle(DiscoveredMediaCandidate candidate) {
    final title = candidate.title?.trim();
    if (title != null && title.isNotEmpty) return title;
    final uri = Uri.tryParse(candidate.url);
    if (uri != null && uri.pathSegments.isNotEmpty) {
      final name = Uri.decodeComponent(uri.pathSegments.last).trim();
      if (name.isNotEmpty) return name;
    }
    return candidate.kind == DiscoverMediaKind.video
        ? 'Page video'
        : 'Page image';
  }

  String _candidateDetails(DiscoveredMediaCandidate candidate) {
    final parts = <String>[];
    if ((candidate.width ?? 0) > 0 && (candidate.height ?? 0) > 0) {
      parts.add('${candidate.width}×${candidate.height}');
    }
    if (candidate.contentLength case final bytes? when bytes > 0) {
      parts.add(_formatBytes(bytes));
    }
    final mime = candidate.mimeType?.trim();
    if (mime != null && mime.isNotEmpty) parts.add(mime);
    if (parts.isEmpty) {
      parts.add(Uri.tryParse(candidate.url)?.host ?? 'Web media');
    }
    return parts.join(' • ');
  }

  String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '$bytes B';
  }

  String _friendlyError(Object error) => error
      .toString()
      .replaceFirst(RegExp(r'^(Exception|StateError):\s*'), '')
      .trim();
}

class _NativeDiscoverBrowserSurface extends StatefulWidget {
  final Uri initialUri;
  final DiscoverBrowserCallbacks callbacks;

  const _NativeDiscoverBrowserSurface({
    required this.initialUri,
    required this.callbacks,
  });

  @override
  State<_NativeDiscoverBrowserSurface> createState() =>
      _NativeDiscoverBrowserSurfaceState();
}

class _NativeDiscoverBrowserSurfaceState
    extends State<_NativeDiscoverBrowserSurface> {
  _NativeDiscoverBrowserController? _browserController;
  late Uri _currentUri = widget.initialUri;

  @override
  Widget build(BuildContext context) {
    return InAppWebView(
      key: const ValueKey('discover-native-webview'),
      initialUrlRequest: URLRequest(url: WebUri(widget.initialUri.toString())),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        domStorageEnabled: true,
        databaseEnabled: false,
        cacheEnabled: true,
        allowsInlineMediaPlayback: true,
        mediaPlaybackRequiresUserGesture: true,
        supportMultipleWindows: false,
        javaScriptCanOpenWindowsAutomatically: false,
        allowFileAccess: false,
        allowContentAccess: false,
        allowFileAccessFromFileURLs: false,
        allowUniversalAccessFromFileURLs: false,
        safeBrowsingEnabled: true,
        mixedContentMode: MixedContentMode.MIXED_CONTENT_NEVER_ALLOW,
        disableContextMenu: true,
        useShouldOverrideUrlLoading: true,
        useOnDownloadStart: true,
      ),
      onWebViewCreated: (controller) {
        final adapter = _NativeDiscoverBrowserController(
          controller,
          initialUri: _currentUri,
        );
        _browserController = adapter;
        widget.callbacks.onControllerCreated(adapter);
      },
      onLoadStart: (_, url) {
        final uri = _asSecureUri(url);
        if (uri != null) _currentUri = uri;
        _browserController?.recordPageUri(uri);
        widget.callbacks.onNavigationStarted(uri);
      },
      onLoadStop: (controller, url) async {
        final uri = _asSecureUri(url);
        if (uri != null) _currentUri = uri;
        _browserController?.recordPageUri(uri);
        String? title;
        try {
          title = await controller.getTitle();
        } catch (_) {
          // A title is cosmetic; navigation and downloads remain usable on
          // platforms that do not expose this optional channel method.
        }
        widget.callbacks.onNavigationFinished(uri, title);
      },
      onProgressChanged: (_, progress) => widget.callbacks.onProgress(progress),
      onTitleChanged: (_, title) {
        // onLoadStop supplies title and URL atomically; title changes during
        // loading do not need to rebuild the full browser chrome.
      },
      onReceivedError: (_, request, error) {
        if (request.isForMainFrame == true) {
          widget.callbacks.onError(error.description);
        }
      },
      onReceivedHttpError: (_, request, response) {
        if (request.isForMainFrame == true &&
            (response.statusCode ?? 0) >= 400) {
          widget.callbacks.onError(
            'This page returned HTTP ${response.statusCode}.',
          );
        }
      },
      shouldOverrideUrlLoading: (_, action) async {
        if (!action.isForMainFrame) return NavigationActionPolicy.ALLOW;
        final url = action.request.url;
        if (url == null) return NavigationActionPolicy.CANCEL;
        final uri = Uri.tryParse(url.toString());
        if (uri == null || uri.scheme.toLowerCase() != 'https') {
          widget.callbacks.onError('Discover only opens secure HTTPS pages.');
          return NavigationActionPolicy.CANCEL;
        }
        return NavigationActionPolicy.ALLOW;
      },
      onLongPressHitTestResult: (_, result) {
        final type = result.type;
        if (type != InAppWebViewHitTestResultType.IMAGE_TYPE &&
            type != InAppWebViewHitTestResultType.SRC_IMAGE_ANCHOR_TYPE) {
          return;
        }
        final uri = Uri.tryParse(result.extra?.trim() ?? '');
        if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
          widget.callbacks.onError(
            'Only secure HTTPS images can be added directly.',
          );
          return;
        }
        widget.callbacks.onDownloadRequested(
          DiscoveredMediaCandidate(
            url: uri.toString(),
            kind: DiscoverMediaKind.image,
            origin: DiscoverMediaOrigin.imageElement,
            pageUrl: _currentUri.toString(),
            title: uri.pathSegments.isEmpty
                ? 'Web image'
                : Uri.decodeComponent(uri.pathSegments.last),
          ),
        );
      },
      onDownloadStartRequest: (_, request) {
        final uri = Uri.tryParse(request.url.toString());
        if (uri == null || uri.scheme != 'https') {
          widget.callbacks.onError(
            'Only secure HTTPS downloads are supported.',
          );
          return;
        }
        widget.callbacks.onDownloadRequested(
          DiscoveredMediaCandidate(
            url: uri.toString(),
            kind: _kindFromMimeAndUrl(request.mimeType, uri),
            origin: DiscoverMediaOrigin.direct,
            pageUrl: _currentUri.toString(),
            title: request.suggestedFilename,
            mimeType: request.mimeType,
            contentLength: request.contentLength > 0
                ? request.contentLength
                : null,
          ),
        );
      },
    );
  }

  static Uri? _asSecureUri(WebUri? url) {
    if (url == null) return null;
    final uri = Uri.tryParse(url.toString());
    return uri?.scheme == 'https' ? uri : null;
  }
}

class _NativeDiscoverBrowserController
    implements DiscoverBrowserController, DiscoverBrowserLifecycleController {
  final InAppWebViewController _controller;
  Uri? _currentUri;
  bool _isActive = true;

  _NativeDiscoverBrowserController(this._controller, {required Uri initialUri})
    : _currentUri = initialUri;

  void recordPageUri(Uri? uri) {
    if (uri?.scheme == 'https') _currentUri = uri;
  }

  @override
  Future<void> load(Uri uri) {
    return _controller.loadUrl(
      urlRequest: URLRequest(url: WebUri(uri.toString())),
    );
  }

  @override
  Future<void> goBack() => _controller.goBack();

  @override
  Future<void> goForward() => _controller.goForward();

  @override
  Future<void> reload() => _controller.reload();

  @override
  Future<void> stop() => _controller.stopLoading();

  @override
  Future<bool> canGoBack() => _controller.canGoBack();

  @override
  Future<bool> canGoForward() => _controller.canGoForward();

  @override
  Future<List<DiscoveredMediaCandidate>> scanMedia({required int limit}) async {
    final safeLimit = limit.clamp(
      1,
      DiscoverMediaExtractionService.maxCandidates,
    );
    final raw = await _controller.evaluateJavascript(
      source: DiscoverMediaExtractionService.extractionJavaScript,
    );
    return DiscoverMediaExtractionService.normalizeResult(
      raw,
      pageUrl: _currentUri?.toString(),
      limit: safeLimit,
    );
  }

  @override
  Future<Map<String, String>> downloadHeaders(Uri resourceUri) async {
    final headers = <String, String>{};
    final currentUri = _currentUri;
    if (currentUri?.scheme == 'https') {
      headers['Referer'] = currentUri.toString();
    }
    try {
      final userAgent = await _controller.evaluateJavascript(
        source: 'navigator.userAgent',
      );
      if (userAgent is String && userAgent.trim().isNotEmpty) {
        headers['User-Agent'] = userAgent.trim();
      }
    } catch (_) {
      // Referrer alone is still useful when a platform hides the user agent.
    }
    try {
      final cookies = await CookieManager.instance().getCookies(
        url: WebUri(resourceUri.toString()),
      );
      if (cookies.isNotEmpty) {
        headers['Cookie'] = cookies
            .map((cookie) => '${cookie.name}=${cookie.value}')
            .join('; ');
      }
    } catch (_) {
      // Public assets can still be queued when cookies are unavailable.
    }
    return headers;
  }

  @override
  Future<void> setActive(bool active) async {
    if (_isActive == active) return;
    _isActive = active;
    if (!active) {
      try {
        await _controller.evaluateJavascript(
          source:
              "document.querySelectorAll('video,audio').forEach((media) => media.pause())",
        );
      } catch (_) {
        // Media pausing is a best-effort battery optimization.
      }
      try {
        await _controller.setAllMediaPlaybackSuspended(suspended: true);
      } catch (_) {
        // This suspension API is available on recent Apple WebViews only.
      }
      try {
        await _controller.pause();
      } catch (_) {
        // pause() is Android-only; Apple and desktop implementations can keep
        // their page alive without making this lifecycle hook fatal.
      }
      return;
    }
    try {
      await _controller.setAllMediaPlaybackSuspended(suspended: false);
    } catch (_) {
      // This suspension API is available on recent Apple WebViews only.
    }
    try {
      await _controller.resume();
    } catch (_) {
      // resume() is Android-only and optional on other platforms.
    }
  }
}

DiscoverMediaKind _kindFromMimeAndUrl(String? mimeType, Uri uri) {
  final mime = mimeType?.toLowerCase() ?? '';
  if (mime.startsWith('image/')) return DiscoverMediaKind.image;
  if (mime.startsWith('video/')) return DiscoverMediaKind.video;
  if (mime.startsWith('audio/')) return DiscoverMediaKind.audio;
  final path = uri.path.toLowerCase();
  if (RegExp(r'\.(png|jpe?g|webp|gif)$').hasMatch(path)) {
    return DiscoverMediaKind.image;
  }
  if (RegExp(r'\.(mp4|m4v|mov|webm)$').hasMatch(path)) {
    return DiscoverMediaKind.video;
  }
  if (RegExp(r'\.(mp3|m4a|aac|wav|ogg|flac)$').hasMatch(path)) {
    return DiscoverMediaKind.audio;
  }
  return DiscoverMediaKind.unknown;
}
