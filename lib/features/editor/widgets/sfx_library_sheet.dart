import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../../../core/constants/asset_pack_constants.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/openverse_sfx_service.dart';
import '../models/asset_pack_models.dart';
import '../models/sound_effect_library_asset.dart';
import '../providers/asset_pack_provider.dart';
import 'asset_pack_download_panel.dart';
import 'resizable_editor_sheet.dart';

export 'asset_pack_facade.dart' show AssetPackFacade, AssetPackServiceFacade;

typedef OpenverseSfxSearchCallback =
    Future<List<SoundEffectLibraryAsset>> Function(
      String query,
      OpenverseLicenseFilter filter,
    );

typedef OnlineSoundEffectSelected =
    Future<void> Function(SoundEffectLibraryAsset asset);

typedef PackSoundEffectSelected =
    Future<void> Function(AssetPackCatalogItem item);

typedef OnlineSoundEffectPreview =
    Future<void> Function(SoundEffectLibraryAsset asset);

typedef PackSoundEffectPreview =
    Future<void> Function(AssetPackCatalogItem item);

typedef StopSoundEffectPreview = Future<void> Function();

typedef SfxExternalUrlLauncher = Future<bool> Function(Uri uri);

enum SfxLibraryDestination { openverse, local }

/// Searchable sound-effects library.
///
/// Opening this widget never performs an Openverse request. Online work starts
/// only when the user submits the search field or presses Search. The optional
/// local pack is also install-on-demand. Its availability and release details
/// come from the public asset-pack manifest instead of a build-time visibility
/// flag.
class SfxLibrarySheet extends ConsumerStatefulWidget {
  final OnlineSoundEffectSelected onOnlineAssetSelected;
  final PackSoundEffectSelected onPackAssetSelected;
  final VoidCallback? onClose;
  final OpenverseSfxService? openverseService;
  final OpenverseSfxSearchCallback? openverseSearch;
  final SfxExternalUrlLauncher? externalUrlLauncher;
  final OnlineSoundEffectPreview? onOnlineAssetPreview;
  final PackSoundEffectPreview? onPackAssetPreview;
  final StopSoundEffectPreview? onStopPreview;

  const SfxLibrarySheet({
    super.key,
    required this.onOnlineAssetSelected,
    required this.onPackAssetSelected,
    this.onClose,
    this.openverseService,
    this.openverseSearch,
    this.externalUrlLauncher,
    this.onOnlineAssetPreview,
    this.onPackAssetPreview,
    this.onStopPreview,
  });

  @override
  ConsumerState<SfxLibrarySheet> createState() => _SfxLibrarySheetState();
}

class _SfxLibrarySheetState extends ConsumerState<SfxLibrarySheet> {
  static final Uri _openverseUri = Uri.parse('https://openverse.org/');

  final TextEditingController _onlineSearchController = TextEditingController();
  final TextEditingController _localSearchController = TextEditingController();

  OpenverseSfxService? _openverseService;
  SfxLibraryDestination _destination = SfxLibraryDestination.openverse;
  OpenverseLicenseFilter _licenseFilter = OpenverseLicenseFilter.allUsable;

  int _onlineRequestGeneration = 0;
  CancelToken? _onlineCancelToken;
  bool _hasSubmittedSearch = false;
  bool _onlineLoading = false;
  String? _onlineError;
  List<SoundEffectLibraryAsset> _onlineResults = const [];

  String? _selectedCategoryId;

  String? _selectionId;
  String? _previewId;
  String? _playingPreviewId;
  VideoPlayerController? _previewController;
  int _previewGeneration = 0;
  bool _usingInjectedPreview = false;
  bool _handlingPreviewFailure = false;
  String? _actionError;

  static const List<SfxLibraryDestination> _visibleDestinations = [
    SfxLibraryDestination.openverse,
    SfxLibraryDestination.local,
  ];

  @override
  void initState() {
    super.initState();
    _openverseService = widget.openverseService;
  }

  @override
  void dispose() {
    _onlineRequestGeneration++;
    _onlineCancelToken?.cancel('Sound-effects library closed.');
    _onlineCancelToken = null;
    _previewGeneration++;
    final previewController = _previewController;
    _previewController = null;
    previewController?.removeListener(_handlePreviewControllerValue);
    if (previewController != null) unawaited(previewController.dispose());
    if (_usingInjectedPreview && widget.onStopPreview != null) {
      unawaited(widget.onStopPreview!());
    }
    if (widget.openverseService == null) _openverseService?.close();
    _onlineSearchController.dispose();
    _localSearchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final packState = ref.watch(
      assetPackProvider.select(
        (state) => state.pack(AssetPackConstants.soundEffectsId),
      ),
    );
    return ResizableEditorSheet(
      title: 'Sound effects',
      subtitle: 'Openverse and verified on-demand SFX packs',
      initialHeightFactor: 0.78,
      minHeightFactor: 0.52,
      maxHeightFactor: 0.92,
      scrollable: false,
      contentPadding: EdgeInsets.zero,
      onClose: () => unawaited(_close()),
      child: Column(
        children: [
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 160),
              child: KeyedSubtree(
                key: ValueKey<SfxLibraryDestination>(_destination),
                child: _destination == SfxLibraryDestination.openverse
                    ? _buildOpenverseLibrary()
                    : _buildLocalLibrary(packState),
              ),
            ),
          ),
          if (_visibleDestinations.length > 1) ...[
            const Divider(height: 1, color: kBorder),
            _buildNavigationBar(packState),
          ],
        ],
      ),
    );
  }

  Widget _buildNavigationBar(AssetPackDownloadState packState) {
    final destinations = _visibleDestinations;
    return NavigationBar(
      key: const ValueKey('sfx-library-navigation'),
      height: 70,
      selectedIndex: destinations.indexOf(_destination),
      onDestinationSelected: (index) => _selectDestination(destinations[index]),
      backgroundColor: kSurfaceElevated,
      surfaceTintColor: Colors.transparent,
      indicatorColor: kAccent.withValues(alpha: 0.18),
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      destinations: [
        const NavigationDestination(
          key: ValueKey('sfx-library-nav-openverse'),
          icon: Icon(Icons.public_outlined),
          selectedIcon: Icon(Icons.public_rounded),
          label: 'Openverse',
        ),
        NavigationDestination(
          key: const ValueKey('sfx-library-nav-local'),
          icon: _buildLocalNavigationIcon(packState, selected: false),
          selectedIcon: _buildLocalNavigationIcon(packState, selected: true),
          label: 'Local SFX',
        ),
      ],
    );
  }

  Widget _buildLocalNavigationIcon(
    AssetPackDownloadState packState, {
    required bool selected,
  }) {
    final (badgeIcon, badgeColor) = switch (packState.status) {
      AssetPackDownloadStatus.queued => (Icons.schedule_rounded, kWarning),
      AssetPackDownloadStatus.checking ||
      AssetPackDownloadStatus.downloading ||
      AssetPackDownloadStatus.verifying ||
      AssetPackDownloadStatus.extracting ||
      AssetPackDownloadStatus.installing => (
        Icons.downloading_rounded,
        kAccent,
      ),
      AssetPackDownloadStatus.stopping => (
        Icons.stop_circle_outlined,
        kWarning,
      ),
      AssetPackDownloadStatus.removing => (
        Icons.delete_sweep_outlined,
        kWarning,
      ),
      AssetPackDownloadStatus.cancelled => (
        Icons.pause_circle_outline_rounded,
        kTextSecondary,
      ),
      AssetPackDownloadStatus.failed => (Icons.error_rounded, kError),
      AssetPackDownloadStatus.installed => (
        Icons.check_circle_rounded,
        kSuccess,
      ),
      AssetPackDownloadStatus.idle ||
      AssetPackDownloadStatus.available => (null, kTextSecondary),
    };
    final baseIcon = Icon(
      selected ? Icons.graphic_eq_rounded : Icons.graphic_eq_outlined,
    );
    if (badgeIcon == null) return baseIcon;
    return Semantics(
      label: 'Local SFX, ${_navigationStatusLabel(packState.status)}',
      child: ExcludeSemantics(
        child: Badge(
          key: const ValueKey('sfx-library-local-status-badge'),
          backgroundColor: badgeColor,
          smallSize: 8,
          child: baseIcon,
        ),
      ),
    );
  }

  String _navigationStatusLabel(AssetPackDownloadStatus status) {
    return switch (status) {
      AssetPackDownloadStatus.idle => 'not installed',
      AssetPackDownloadStatus.checking => 'preparing',
      AssetPackDownloadStatus.available => 'available to download',
      AssetPackDownloadStatus.queued => 'queued',
      AssetPackDownloadStatus.downloading => 'downloading',
      AssetPackDownloadStatus.verifying => 'verifying',
      AssetPackDownloadStatus.extracting => 'extracting',
      AssetPackDownloadStatus.installing => 'installing',
      AssetPackDownloadStatus.stopping => 'stopping',
      AssetPackDownloadStatus.removing => 'removing local download',
      AssetPackDownloadStatus.cancelled => 'download stopped',
      AssetPackDownloadStatus.failed => 'download failed',
      AssetPackDownloadStatus.installed => 'installed',
    };
  }

  void _selectDestination(SfxLibraryDestination destination) {
    if (destination == _destination) return;
    _onlineRequestGeneration++;
    _onlineCancelToken?.cancel('Sound-effects destination changed.');
    _onlineCancelToken = null;
    unawaited(_stopPreview());
    setState(() {
      _destination = destination;
      _actionError = null;
      _selectionId = null;
      _previewId = null;
    });
    if (destination == SfxLibraryDestination.local) {
      unawaited(
        ref
            .read(assetPackProvider.notifier)
            .refresh(
              AssetPackConstants.soundEffectsId,
              fetchRemoteMetadata: true,
            ),
      );
    }
  }

  Widget _buildOpenverseLibrary() {
    return Column(
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.public_rounded, color: kAccent, size: 16),
                SizedBox(width: 6),
                Text(
                  'Openverse',
                  style: TextStyle(
                    color: kTextPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('sfx-library-openverse-search'),
                  controller: _onlineSearchController,
                  textInputAction: TextInputAction.search,
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => unawaited(_submitOpenverseSearch()),
                  decoration: InputDecoration(
                    hintText: 'Search sound effects',
                    prefixIcon: const Icon(Icons.search_rounded, size: 20),
                    suffixIcon: _onlineSearchController.text.isEmpty
                        ? null
                        : IconButton(
                            key: const ValueKey(
                              'sfx-library-clear-openverse-search',
                            ),
                            tooltip: 'Clear search',
                            onPressed: _clearOpenverseSearch,
                            icon: const Icon(Icons.close_rounded, size: 18),
                          ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                key: const ValueKey('sfx-library-openverse-submit'),
                onPressed: _onlineLoading
                    ? null
                    : () => unawaited(_submitOpenverseSearch()),
                icon: const Icon(Icons.search_rounded, size: 18),
                label: const Text('Search'),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _filterChip(
                    keyName: 'sfx-library-filter-all-usable',
                    label: 'All usable',
                    selected:
                        _licenseFilter == OpenverseLicenseFilter.allUsable,
                    onSelected: () =>
                        _changeLicenseFilter(OpenverseLicenseFilter.allUsable),
                  ),
                  const SizedBox(width: 8),
                  _filterChip(
                    keyName: 'sfx-library-filter-public-domain',
                    label: 'Public domain',
                    selected:
                        _licenseFilter == OpenverseLicenseFilter.publicDomain,
                    onSelected: () => _changeLicenseFilter(
                      OpenverseLicenseFilter.publicDomain,
                    ),
                  ),
                  const SizedBox(width: 8),
                  _filterChip(
                    keyName: 'sfx-library-filter-attribution',
                    label: 'Attribution',
                    selected:
                        _licenseFilter == OpenverseLicenseFilter.attribution,
                    onSelected: () => _changeLicenseFilter(
                      OpenverseLicenseFilter.attribution,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
          child: Material(
            color: kAccent.withValues(alpha: 0.09),
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              key: const ValueKey('sfx-library-openverse-notice'),
              borderRadius: BorderRadius.circular(10),
              onTap: () => unawaited(_openExternalUrl(_openverseUri)),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 11, vertical: 8),
                child: Row(
                  children: [
                    Icon(Icons.info_outline_rounded, color: kAccent, size: 16),
                    SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        'Made using Openverse. Openverse does not endorse CaptionCraft.',
                        style: TextStyle(
                          color: kTextSecondary,
                          fontSize: 10,
                          height: 1.3,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                    Icon(
                      Icons.open_in_new_rounded,
                      color: kTextSecondary,
                      size: 13,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (_actionError != null) _buildActionError(),
        const Divider(height: 1, color: kBorder),
        Expanded(child: _buildOpenverseResults()),
      ],
    );
  }

  FilterChip _filterChip({
    required String keyName,
    required String label,
    required bool selected,
    required VoidCallback onSelected,
  }) {
    return FilterChip(
      key: ValueKey(keyName),
      label: Text(label),
      selected: selected,
      showCheckmark: true,
      checkmarkColor: kAccent,
      selectedColor: kAccent.withValues(alpha: 0.16),
      side: BorderSide(color: selected ? kAccent : kBorder),
      onSelected: (_) => onSelected(),
    );
  }

  void _changeLicenseFilter(OpenverseLicenseFilter filter) {
    if (_licenseFilter == filter) return;
    _onlineRequestGeneration++;
    _onlineCancelToken?.cancel('Sound-effect license filter changed.');
    _onlineCancelToken = null;
    unawaited(_stopPreview());
    setState(() {
      _licenseFilter = filter;
      _hasSubmittedSearch = false;
      _onlineLoading = false;
      _onlineError = null;
      _onlineResults = const [];
      _actionError = null;
    });
  }

  void _clearOpenverseSearch() {
    _onlineRequestGeneration++;
    _onlineCancelToken?.cancel('Sound-effect search cleared.');
    _onlineCancelToken = null;
    unawaited(_stopPreview());
    _onlineSearchController.clear();
    setState(() {
      _hasSubmittedSearch = false;
      _onlineLoading = false;
      _onlineError = null;
      _onlineResults = const [];
    });
  }

  Future<void> _submitOpenverseSearch() async {
    final query = _onlineSearchController.text.trim();
    FocusManager.instance.primaryFocus?.unfocus();
    if (query.isEmpty) {
      _onlineRequestGeneration++;
      _onlineCancelToken?.cancel('Empty sound-effect search submitted.');
      _onlineCancelToken = null;
      setState(() {
        _hasSubmittedSearch = true;
        _onlineLoading = false;
        _onlineResults = const [];
        _onlineError = 'Enter a search term before searching.';
      });
      return;
    }

    final requestGeneration = ++_onlineRequestGeneration;
    final requestedFilter = _licenseFilter;
    _onlineCancelToken?.cancel('A newer sound-effect search started.');
    final cancelToken = CancelToken();
    _onlineCancelToken = cancelToken;
    await _stopPreview();
    if (!mounted || requestGeneration != _onlineRequestGeneration) return;
    setState(() {
      _hasSubmittedSearch = true;
      _onlineLoading = true;
      _onlineError = null;
      _actionError = null;
    });

    try {
      final callback = widget.openverseSearch;
      final results = callback == null
          ? await (_openverseService ??= OpenverseSfxService()).search(
              query: query,
              filter: requestedFilter,
              cancelToken: cancelToken,
            )
          : await callback(query, requestedFilter);
      if (!mounted ||
          requestGeneration != _onlineRequestGeneration ||
          requestedFilter != _licenseFilter ||
          _destination != SfxLibraryDestination.openverse) {
        return;
      }
      setState(() {
        _onlineLoading = false;
        _onlineResults = results;
      });
    } catch (error) {
      if (!mounted ||
          requestGeneration != _onlineRequestGeneration ||
          _destination != SfxLibraryDestination.openverse) {
        return;
      }
      setState(() {
        _onlineLoading = false;
        _onlineResults = const [];
        _onlineError = _friendlyOnlineError(error);
      });
    } finally {
      if (identical(_onlineCancelToken, cancelToken)) {
        _onlineCancelToken = null;
      }
    }
  }

  Widget _buildOpenverseResults() {
    if (_onlineLoading) {
      return const Center(
        key: ValueKey('sfx-library-online-loading'),
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    if (_onlineError != null) {
      return _messagePanel(
        key: const ValueKey('sfx-library-online-error'),
        icon: _isRateLimitMessage(_onlineError!)
            ? Icons.hourglass_top_rounded
            : Icons.cloud_off_rounded,
        message: _onlineError!,
        action: _onlineSearchController.text.trim().isEmpty
            ? null
            : OutlinedButton.icon(
                key: const ValueKey('sfx-library-online-retry'),
                onPressed: () => unawaited(_submitOpenverseSearch()),
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Try again'),
              ),
      );
    }
    if (!_hasSubmittedSearch) {
      return _messagePanel(
        key: const ValueKey('sfx-library-online-ready'),
        icon: Icons.graphic_eq_rounded,
        message:
            'Enter a sound effect and press Search. Nothing is fetched until you submit.',
      );
    }
    if (_onlineResults.isEmpty) {
      return _messagePanel(
        key: const ValueKey('sfx-library-online-empty'),
        icon: Icons.search_off_rounded,
        message: 'No reusable sound effects match this search.',
      );
    }

    return ListView.separated(
      key: const ValueKey('sfx-library-openverse-results'),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      itemCount: _onlineResults.length,
      separatorBuilder: (_, _) => const SizedBox(height: 9),
      itemBuilder: (context, index) =>
          _buildOpenverseResult(_onlineResults[index]),
    );
  }

  Widget _buildOpenverseResult(SoundEffectLibraryAsset asset) {
    final adding = _selectionId == 'online:${asset.id}';
    final assetPreviewId = 'online:${asset.id}';
    final previewing = _previewId == assetPreviewId;
    final playing = _playingPreviewId == assetPreviewId;
    final creator = asset.creatorName?.trim();
    final creatorText = creator == null || creator.isEmpty
        ? 'Unknown creator'
        : creator;
    return Card(
      key: ValueKey('sfx-library-online-result-${asset.id}'),
      margin: EdgeInsets.zero,
      color: kSurfaceElevated,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: kAccent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.graphic_eq_rounded, color: kAccent),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        asset.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: kTextPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        _onlineAssetDetails(asset),
                        style: const TextStyle(
                          color: kTextSecondary,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.outlined(
                  key: ValueKey('sfx-library-online-preview-${asset.id}'),
                  tooltip: playing ? 'Stop preview' : 'Preview',
                  onPressed: _previewId == null && _selectionId == null
                      ? () => unawaited(_toggleOnlinePreview(asset))
                      : null,
                  icon: previewing
                      ? const SizedBox.square(
                          dimension: 17,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          playing
                              ? Icons.stop_rounded
                              : Icons.play_arrow_rounded,
                          size: 20,
                        ),
                ),
                const SizedBox(width: 6),
                FilledButton(
                  key: ValueKey('sfx-library-online-add-${asset.id}'),
                  onPressed: _selectionId == null && _previewId == null
                      ? () => unawaited(_selectOnlineAsset(asset))
                      : null,
                  child: adding
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text('Add'),
                ),
              ],
            ),
            const SizedBox(height: 9),
            Wrap(
              spacing: 12,
              runSpacing: 5,
              children: [
                _linkedMetadata(
                  key: ValueKey('sfx-library-creator-${asset.id}'),
                  icon: Icons.person_outline_rounded,
                  label: creatorText,
                  url: asset.creatorPageUrl,
                ),
                _linkedMetadata(
                  key: ValueKey('sfx-library-license-${asset.id}'),
                  icon: Icons.policy_outlined,
                  label: _licenseLabel(asset),
                  url: asset.licenseUrl,
                ),
                _linkedMetadata(
                  key: ValueKey('sfx-library-source-${asset.id}'),
                  icon: Icons.link_rounded,
                  label: asset.sourceName,
                  url: asset.sourcePageUrl,
                ),
              ],
            ),
            const SizedBox(height: 7),
            _linkedMetadata(
              key: ValueKey('sfx-library-attribution-${asset.id}'),
              icon: Icons.copyright_rounded,
              label: asset.attribution,
              url: asset.sourcePageUrl ?? asset.creatorPageUrl,
              maxLines: 2,
            ),
          ],
        ),
      ),
    );
  }

  Widget _linkedMetadata({
    required Key key,
    required IconData icon,
    required String label,
    String? url,
    int maxLines = 1,
  }) {
    final uri = _safeExternalUri(url);
    return InkWell(
      key: key,
      borderRadius: BorderRadius.circular(5),
      onTap: uri == null ? null : () => unawaited(_openExternalUrl(uri)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: kTextSecondary, size: 13),
            const SizedBox(width: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 245),
              child: Text(
                label,
                maxLines: maxLines,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: kTextSecondary,
                  fontSize: 9,
                  decoration: uri == null
                      ? TextDecoration.none
                      : TextDecoration.underline,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _selectOnlineAsset(SoundEffectLibraryAsset asset) async {
    if (_selectionId != null || _previewId != null) return;
    await _stopPreview();
    if (!mounted) return;
    setState(() {
      _selectionId = 'online:${asset.id}';
      _actionError = null;
    });
    try {
      await widget.onOnlineAssetSelected(asset);
      if (!mounted) return;
      await _close();
      if (mounted) setState(() => _selectionId = null);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _selectionId = null;
        _actionError = _friendlyError(error);
      });
    }
  }

  Future<void> _toggleOnlinePreview(SoundEffectLibraryAsset asset) {
    final id = 'online:${asset.id}';
    if (_playingPreviewId == id) return _stopPreview();
    return _startPreview(
      id: id,
      injectedPreview: widget.onOnlineAssetPreview == null
          ? null
          : () => widget.onOnlineAssetPreview!(asset),
      createController: () {
        final uri = _safeExternalUri(asset.previewUrl);
        if (uri == null) {
          throw const FormatException('This sound has no usable preview URL.');
        }
        return VideoPlayerController.networkUrl(uri);
      },
    );
  }

  Widget _buildLocalLibrary(AssetPackDownloadState packState) {
    final catalog = packState.catalog;
    if (catalog != null && !packState.isActive) {
      return _buildInstalledPack(catalog, packState);
    }

    final manager = ref.read(assetPackProvider.notifier);
    final panelStage = _panelStageFor(packState);
    final release = packState.release;
    final progress = packState.progress;
    return KeyedSubtree(
      key: const ValueKey('sfx-library-pack-download-panel'),
      child: AssetPackDownloadPanel(
        model: AssetPackDownloadViewModel(
          packId: AssetPackConstants.soundEffectsId,
          title: release?.title.isNotEmpty == true
              ? release!.title
              : 'CaptionCraft sound effects',
          description: release?.description ?? _localPackDescription(packState),
          stage: panelStage,
          version: release?.version ?? catalog?.version,
          assetCount: release?.assetCount ?? catalog?.items.length,
          downloadBytes: release?.archiveBytes,
          temporarySpaceBytes: release == null
              ? null
              : release.archiveBytes + release.installedBytes,
          receivedBytes: progress?.receivedBytes ?? 0,
          totalBytes: progress != null && progress.totalBytes > 0
              ? progress.totalBytes
              : release?.archiveBytes,
          queuePosition: packState.queuePosition,
          partIndex: progress?.partIndex,
          partCount: progress?.partCount,
          errorMessage: packState.errorMessage,
          icon: Icons.graphic_eq_rounded,
        ),
        onDownload: panelStage == AssetPackPanelStage.available
            ? () =>
                  unawaited(manager.enqueue(AssetPackConstants.soundEffectsId))
            : null,
        onStop: packState.canStop
            ? () => unawaited(manager.cancel(AssetPackConstants.soundEffectsId))
            : null,
        onRetry: packState.canRetry
            ? () => unawaited(manager.retry(AssetPackConstants.soundEffectsId))
            : null,
      ),
    );
  }

  AssetPackPanelStage _panelStageFor(AssetPackDownloadState packState) {
    return switch (packState.status) {
      AssetPackDownloadStatus.idle ||
      AssetPackDownloadStatus.available => AssetPackPanelStage.available,
      AssetPackDownloadStatus.checking => AssetPackPanelStage.preparing,
      AssetPackDownloadStatus.queued => AssetPackPanelStage.queued,
      AssetPackDownloadStatus.downloading => AssetPackPanelStage.downloading,
      AssetPackDownloadStatus.verifying => AssetPackPanelStage.verifying,
      AssetPackDownloadStatus.extracting => AssetPackPanelStage.extracting,
      AssetPackDownloadStatus.installing => AssetPackPanelStage.installing,
      AssetPackDownloadStatus.stopping => AssetPackPanelStage.stopping,
      AssetPackDownloadStatus.removing => AssetPackPanelStage.installed,
      AssetPackDownloadStatus.cancelled => AssetPackPanelStage.cancelled,
      AssetPackDownloadStatus.failed => AssetPackPanelStage.failed,
      AssetPackDownloadStatus.installed => AssetPackPanelStage.installed,
    };
  }

  String? _localPackDescription(AssetPackDownloadState packState) {
    if (packState.status == AssetPackDownloadStatus.idle) {
      return 'Checking the public CaptionCraft asset manifest for an available sound-effects pack.';
    }
    if (packState.catalog != null && packState.isActive) {
      return 'Your installed sounds stay available while CaptionCraft prepares the newer pack.';
    }
    return null;
  }

  Widget _buildInstalledPack(
    AssetPackCatalog catalog,
    AssetPackDownloadState packState,
  ) {
    final query = _localSearchController.text.trim().toLowerCase();
    final items = catalog.items
        .where((item) {
          if (item.mediaKind != AssetPackMediaKind.audio) return false;
          if (_selectedCategoryId != null &&
              item.categoryId != _selectedCategoryId) {
            return false;
          }
          if (query.isEmpty) return true;
          return item.title.toLowerCase().contains(query) ||
              item.categoryName.toLowerCase().contains(query) ||
              item.tags.any((tag) => tag.toLowerCase().contains(query));
        })
        .toList(growable: false);

    return Column(
      children: [
        _buildInstalledHeader(catalog, packState),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 7),
          child: TextField(
            key: const ValueKey('sfx-library-pack-search'),
            controller: _localSearchController,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: 'Search local sound effects',
              prefixIcon: const Icon(Icons.search_rounded, size: 20),
              suffixIcon: _localSearchController.text.isEmpty
                  ? null
                  : IconButton(
                      key: const ValueKey('sfx-library-clear-pack-search'),
                      tooltip: 'Clear search',
                      onPressed: () {
                        _localSearchController.clear();
                        setState(() {});
                      },
                      icon: const Icon(Icons.close_rounded, size: 18),
                    ),
            ),
          ),
        ),
        if (catalog.categoryIds.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 7),
            child: Align(
              alignment: Alignment.centerLeft,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _filterChip(
                      keyName: 'sfx-library-pack-filter-all',
                      label: 'All',
                      selected: _selectedCategoryId == null,
                      onSelected: () =>
                          setState(() => _selectedCategoryId = null),
                    ),
                    for (final categoryId in catalog.categoryIds) ...[
                      const SizedBox(width: 8),
                      _filterChip(
                        keyName: 'sfx-library-pack-filter-$categoryId',
                        label: catalog.categoryNames[categoryId] ?? categoryId,
                        selected: _selectedCategoryId == categoryId,
                        onSelected: () =>
                            setState(() => _selectedCategoryId = categoryId),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        if (_actionError != null) _buildActionError(),
        const Divider(height: 1, color: kBorder),
        Expanded(
          child: items.isEmpty
              ? _messagePanel(
                  key: const ValueKey('sfx-library-pack-empty'),
                  icon: Icons.search_off_rounded,
                  message: 'No local sound effects match these filters.',
                )
              : _buildPackGrid(items),
        ),
      ],
    );
  }

  Widget _buildInstalledHeader(
    AssetPackCatalog catalog,
    AssetPackDownloadState packState,
  ) {
    final release = packState.release;
    final installedSize = release?.installedBytes;
    final details = <String>[
      'v${catalog.version}',
      '${catalog.items.length} assets',
      if (installedSize != null)
        '${AssetPackDownloadPanel.formatBytes(installedSize)} local',
    ].join(' • ');
    final updateFailed =
        packState.status == AssetPackDownloadStatus.failed ||
        packState.status == AssetPackDownloadStatus.cancelled;
    final metadataFailed =
        packState.status == AssetPackDownloadStatus.installed &&
        packState.errorMessage?.trim().isNotEmpty == true;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
      child: Column(
        children: [
          Semantics(
            key: const ValueKey('sfx-library-pack-installed-header'),
            container: true,
            label: 'CaptionCraft sound effects installed',
            value: details,
            child: ExcludeSemantics(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: kSuccess.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(13),
                  border: Border.all(color: kSuccess.withValues(alpha: 0.28)),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.check_circle_rounded,
                      color: kSuccess,
                      size: 21,
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Installed on this device',
                            style: TextStyle(
                              color: kTextPrimary,
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            details,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: kTextSecondary,
                              fontSize: 9,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    AssetPackRemoveButton(
                      packId: catalog.id,
                      title: catalog.title,
                      isRemoving: packState.isRemoving,
                      onRemove: () async {
                        await _stopPreview();
                        await ref
                            .read(assetPackProvider.notifier)
                            .remove(catalog.id);
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (packState.removalErrorMessage != null) ...[
            const SizedBox(height: 8),
            Container(
              key: const ValueKey('sfx-library-pack-removal-error'),
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
              decoration: BoxDecoration(
                color: kWarning.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(11),
                border: Border.all(color: kWarning.withValues(alpha: 0.28)),
              ),
              child: Text(
                packState.removalErrorMessage!,
                style: const TextStyle(
                  color: kTextSecondary,
                  fontSize: 10,
                  height: 1.3,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
          if (packState.hasUpdate || updateFailed || metadataFailed) ...[
            const SizedBox(height: 8),
            _buildInstalledUpdateAction(
              catalog,
              packState,
              updateFailed: updateFailed,
              metadataFailed: metadataFailed,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildInstalledUpdateAction(
    AssetPackCatalog catalog,
    AssetPackDownloadState packState, {
    required bool updateFailed,
    required bool metadataFailed,
  }) {
    final color = updateFailed || metadataFailed ? kWarning : kAccent;
    final release = packState.release;
    final message = updateFailed
        ? 'The update did not finish. Installed v${catalog.version} is still ready.'
        : metadataFailed
        ? 'Could not check for updates. Installed sounds are unaffected.'
        : 'Version ${release?.version ?? ''} is available'
              '${release == null ? '.' : ' • ${AssetPackDownloadPanel.formatBytes(release.archiveBytes)}.'}';
    return Container(
      key: const ValueKey('sfx-library-pack-update'),
      padding: const EdgeInsets.fromLTRB(12, 9, 9, 9),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline_rounded, color: color, size: 19),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                color: kTextSecondary,
                fontSize: 10,
                height: 1.3,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          TextButton(
            key: const ValueKey('sfx-library-pack-update-action'),
            onPressed: () {
              final manager = ref.read(assetPackProvider.notifier);
              unawaited(
                metadataFailed
                    ? manager.refresh(
                        AssetPackConstants.soundEffectsId,
                        fetchRemoteMetadata: true,
                      )
                    : updateFailed
                    ? manager.retry(AssetPackConstants.soundEffectsId)
                    : manager.enqueue(AssetPackConstants.soundEffectsId),
              );
            },
            child: Text(
              metadataFailed
                  ? 'Check again'
                  : updateFailed
                  ? 'Retry'
                  : 'Update',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPackGrid(List<AssetPackCatalogItem> items) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return GridView.builder(
          key: const ValueKey('sfx-library-pack-grid'),
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: constraints.maxWidth >= 900 ? 360 : 300,
            mainAxisExtent: 128,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
          ),
          itemCount: items.length,
          itemBuilder: (context, index) => _buildPackResult(items[index]),
        );
      },
    );
  }

  Widget _buildPackResult(AssetPackCatalogItem item) {
    final adding = _selectionId == 'pack:${item.id}';
    final assetPreviewId = 'pack:${item.id}';
    final previewing = _previewId == assetPreviewId;
    final playing = _playingPreviewId == assetPreviewId;
    return Card(
      key: ValueKey('sfx-library-pack-result-${item.id}'),
      margin: EdgeInsets.zero,
      color: kSurfaceElevated,
      child: Padding(
        padding: const EdgeInsets.all(11),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.audio_file_outlined, color: kAccent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: kTextPrimary,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 5),
            Text(
              '${item.categoryName} • ${_formatDuration(item.duration)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: kTextSecondary, fontSize: 9),
            ),
            const Spacer(),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                IconButton.outlined(
                  key: ValueKey('sfx-library-pack-preview-${item.id}'),
                  tooltip: playing ? 'Stop preview' : 'Preview',
                  visualDensity: VisualDensity.compact,
                  onPressed: _previewId == null && _selectionId == null
                      ? () => unawaited(_togglePackPreview(item))
                      : null,
                  icon: previewing
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          playing
                              ? Icons.stop_rounded
                              : Icons.play_arrow_rounded,
                          size: 19,
                        ),
                ),
                const SizedBox(width: 5),
                FilledButton(
                  key: ValueKey('sfx-library-pack-add-${item.id}'),
                  onPressed: _selectionId == null && _previewId == null
                      ? () => unawaited(_selectPackAsset(item))
                      : null,
                  child: adding
                      ? const SizedBox.square(
                          dimension: 15,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text('Add'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _selectPackAsset(AssetPackCatalogItem item) async {
    if (_selectionId != null || _previewId != null) return;
    await _stopPreview();
    if (!mounted) return;
    setState(() {
      _selectionId = 'pack:${item.id}';
      _actionError = null;
    });
    try {
      await widget.onPackAssetSelected(item);
      if (!mounted) return;
      await _close();
      if (mounted) setState(() => _selectionId = null);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _selectionId = null;
        _actionError = _friendlyError(error);
      });
    }
  }

  Future<void> _togglePackPreview(AssetPackCatalogItem item) {
    final id = 'pack:${item.id}';
    if (_playingPreviewId == id) return _stopPreview();
    return _startPreview(
      id: id,
      injectedPreview: widget.onPackAssetPreview == null
          ? null
          : () => widget.onPackAssetPreview!(item),
      createController: () => VideoPlayerController.file(File(item.localPath)),
    );
  }

  Future<void> _startPreview({
    required String id,
    required Future<void> Function()? injectedPreview,
    required VideoPlayerController Function() createController,
  }) async {
    if (_selectionId != null || _previewId != null) return;
    await _stopPreview();
    if (!mounted) return;
    final generation = ++_previewGeneration;
    setState(() {
      _previewId = id;
      _actionError = null;
    });

    try {
      if (injectedPreview != null) {
        _usingInjectedPreview = true;
        await injectedPreview();
      } else {
        final controller = createController();
        _previewController = controller;
        controller.addListener(_handlePreviewControllerValue);
        await controller.initialize();
        if (!mounted || generation != _previewGeneration) {
          if (identical(_previewController, controller)) {
            _previewController = null;
          }
          controller.removeListener(_handlePreviewControllerValue);
          await controller.dispose();
          return;
        }
        await controller.setLooping(false);
        await controller.setVolume(1);
        await controller.play();
      }
      if (!mounted || generation != _previewGeneration) return;
      setState(() {
        _previewId = null;
        _playingPreviewId = id;
      });
    } catch (error) {
      if (!mounted || generation != _previewGeneration) return;
      await _releasePreviewResources();
      if (!mounted) return;
      setState(() {
        _previewId = null;
        _playingPreviewId = null;
        _actionError = 'Could not preview this sound. ${_friendlyError(error)}';
      });
    }
  }

  void _handlePreviewControllerValue() {
    if (!mounted || _handlingPreviewFailure) return;
    final controller = _previewController;
    if (controller == null || _playingPreviewId == null) return;
    final value = controller.value;
    if (value.hasError) {
      _handlingPreviewFailure = true;
      final description = value.errorDescription ?? 'Playback failed.';
      unawaited(_stopPreviewWithError(description));
      return;
    }
    if (value.isCompleted) unawaited(_stopPreview());
  }

  Future<void> _stopPreviewWithError(String message) async {
    await _stopPreview();
    _handlingPreviewFailure = false;
    if (!mounted) return;
    setState(() {
      _actionError = 'Could not preview this sound. ${_friendlyError(message)}';
    });
  }

  Future<void> _stopPreview() async {
    _previewGeneration++;
    if (mounted && (_previewId != null || _playingPreviewId != null)) {
      setState(() {
        _previewId = null;
        _playingPreviewId = null;
      });
    } else {
      _previewId = null;
      _playingPreviewId = null;
    }
    await _releasePreviewResources();
  }

  Future<void> _releasePreviewResources() async {
    final controller = _previewController;
    _previewController = null;
    if (controller != null) {
      controller.removeListener(_handlePreviewControllerValue);
      try {
        if (controller.value.isInitialized) await controller.pause();
      } catch (_) {
        // The platform may already have released a failed media handle.
      }
      try {
        await controller.dispose();
      } catch (_) {
        // A failed initialization may dispose its handle before this cleanup.
      }
    }
    if (_usingInjectedPreview) {
      _usingInjectedPreview = false;
      try {
        await widget.onStopPreview?.call();
      } catch (_) {
        // Preview teardown must never block selection or closing the sheet.
      }
    }
  }

  Widget _buildActionError() {
    return Container(
      key: const ValueKey('sfx-library-action-error'),
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: kError.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kError.withValues(alpha: 0.55)),
      ),
      child: Text(
        _actionError!,
        style: const TextStyle(color: kError, fontSize: 11),
      ),
    );
  }

  Widget _messagePanel({
    required Key key,
    required IconData icon,
    required String message,
    Widget? action,
  }) {
    return Center(
      key: key,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: kTextSecondary, size: 34),
            const SizedBox(height: 10),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: kTextSecondary,
                fontSize: 12,
                height: 1.35,
              ),
            ),
            if (action != null) ...[const SizedBox(height: 14), action],
          ],
        ),
      ),
    );
  }

  String _onlineAssetDetails(SoundEffectLibraryAsset asset) {
    final parts = <String>[
      _formatDuration(asset.duration),
      _licenseLabel(asset),
      if (asset.fileExtension.trim().isNotEmpty)
        asset.fileExtension.replaceFirst('.', '').toUpperCase(),
      if (asset.fileSizeBytes case final size?) _formatBytes(size),
    ];
    return parts.join(' • ');
  }

  String _licenseLabel(SoundEffectLibraryAsset asset) {
    final code = asset.licenseCode.trim().toUpperCase();
    final version = asset.licenseVersion?.trim();
    return version == null || version.isEmpty ? code : '$code $version';
  }

  String _formatDuration(Duration? duration) {
    if (duration == null) return 'Unknown duration';
    final seconds = duration.inSeconds;
    if (seconds >= 3600) {
      final hours = seconds ~/ 3600;
      final minutes = (seconds % 3600) ~/ 60;
      final remainder = seconds % 60;
      return '$hours:${minutes.toString().padLeft(2, '0')}:${remainder.toString().padLeft(2, '0')}';
    }
    final minutes = seconds ~/ 60;
    final remainder = seconds % 60;
    return '$minutes:${remainder.toString().padLeft(2, '0')}';
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String _friendlyOnlineError(Object error) {
    if (error is DioException && error.response?.statusCode == 429) {
      return 'Openverse is receiving too many requests. Please wait a moment and try again.';
    }
    final message = _friendlyError(error);
    if (_isRateLimitMessage(message)) {
      return 'Openverse is receiving too many requests. Please wait a moment and try again.';
    }
    return message.isEmpty
        ? 'Openverse could not complete this search.'
        : message;
  }

  bool _isRateLimitMessage(String value) {
    final normalized = value.toLowerCase();
    return normalized.contains('429') ||
        normalized.contains('rate limit') ||
        normalized.contains('too many requests');
  }

  String _friendlyError(Object error) {
    return error
        .toString()
        .replaceFirst(
          RegExp(r'^(Exception|StateError|AssetPackException):\s*'),
          '',
        )
        .trim();
  }

  Uri? _safeExternalUri(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        !const {'http', 'https'}.contains(uri.scheme.toLowerCase()) ||
        uri.host.isEmpty) {
      return null;
    }
    return uri;
  }

  Future<void> _openExternalUrl(Uri uri) async {
    try {
      final launcher = widget.externalUrlLauncher;
      final launched = launcher == null
          ? await launchUrl(uri, mode: LaunchMode.externalApplication)
          : await launcher(uri);
      if (!launched) throw StateError('Could not open provider page.');
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Could not open the provider page.')),
      );
    }
  }

  Future<void> _close() async {
    await _stopPreview();
    if (!mounted) return;
    final callback = widget.onClose;
    if (callback != null) {
      callback();
      return;
    }
    await Navigator.of(context).maybePop();
  }
}
