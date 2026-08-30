import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/constants/asset_pack_constants.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/giphy_service.dart';
import '../../../core/utils/pexels_service.dart';
import '../../../core/utils/pixabay_service.dart';
import '../models/asset_pack_models.dart';
import '../models/element_library_asset.dart';
import '../providers/asset_pack_provider.dart';
import 'asset_pack_download_panel.dart';
import 'resizable_editor_sheet.dart';

export 'asset_pack_facade.dart' show AssetPackFacade, AssetPackServiceFacade;

typedef GiphySearchCallback =
    Future<List<GiphyAssetResult>> Function(String query, GiphySearchKind kind);

typedef PexelsSearchCallback =
    Future<List<ElementLibraryAsset>> Function(
      String query,
      PexelsMediaFilter filter,
    );

typedef PixabaySearchCallback =
    Future<List<ElementLibraryAsset>> Function(
      String query,
      PixabayMediaFilter filter,
    );

typedef OnlineElementAssetSelected =
    Future<void> Function(ElementLibraryAsset asset);

typedef PackElementAssetSelected =
    Future<void> Function(AssetPackCatalogItem item);

typedef ExternalUrlLauncher = Future<bool> Function(Uri uri);

enum ElementLibraryDestination {
  giphy,
  pexels,
  pixabay,
  backgroundVideos,
  overlays,
  luts,
}

/// A single resizable Elements library with a persistent provider menu.
class ElementLibrarySheet extends ConsumerStatefulWidget {
  final OnlineElementAssetSelected onOnlineAssetSelected;
  final PackElementAssetSelected onPackAssetSelected;
  final VoidCallback? onClose;
  final GiphySearchCallback? giphySearch;
  final PexelsService? pexelsService;
  final PixabayService? pixabayService;
  final PexelsSearchCallback? pexelsSearch;
  final PixabaySearchCallback? pixabaySearch;
  final ExternalUrlLauncher? externalUrlLauncher;
  final ElementLibraryDestination initialDestination;
  final Duration searchDebounce;
  final String title;
  final String subtitle;
  final bool showNavigation;

  const ElementLibrarySheet({
    super.key,
    required this.onOnlineAssetSelected,
    required this.onPackAssetSelected,
    this.onClose,
    this.giphySearch,
    this.pexelsService,
    this.pixabayService,
    this.pexelsSearch,
    this.pixabaySearch,
    this.externalUrlLauncher,
    this.initialDestination = ElementLibraryDestination.giphy,
    this.searchDebounce = const Duration(milliseconds: 300),
    this.title = 'Elements',
    this.subtitle = 'Stock media and verified on-demand packs',
    this.showNavigation = true,
  });

  @override
  ConsumerState<ElementLibrarySheet> createState() =>
      _ElementLibrarySheetState();
}

class _ElementLibrarySheetState extends ConsumerState<ElementLibrarySheet> {
  final TextEditingController _onlineSearchController = TextEditingController();
  final TextEditingController _packSearchController = TextEditingController();

  PexelsService? _pexelsService;
  PixabayService? _pixabayService;
  late ElementLibraryDestination _destination;

  Timer? _searchTimer;
  int _onlineRequestGeneration = 0;

  GiphySearchKind _giphyKind = GiphySearchKind.both;
  PexelsMediaFilter _pexelsFilter = PexelsMediaFilter.all;
  PixabayMediaFilter _pixabayFilter = PixabayMediaFilter.all;

  List<ElementLibraryAsset> _onlineResults = const [];
  bool _onlineLoading = false;
  String? _onlineError;

  String? _selectedCategoryId;

  String? _selectionId;
  String? _selectionError;

  bool get _isOnlineDestination => switch (_destination) {
    ElementLibraryDestination.giphy ||
    ElementLibraryDestination.pexels ||
    ElementLibraryDestination.pixabay => true,
    ElementLibraryDestination.backgroundVideos ||
    ElementLibraryDestination.overlays ||
    ElementLibraryDestination.luts => false,
  };

  String? get _activePackId => switch (_destination) {
    ElementLibraryDestination.backgroundVideos =>
      AssetPackConstants.backgroundVideosId,
    ElementLibraryDestination.overlays => AssetPackConstants.overlaysId,
    ElementLibraryDestination.luts => AssetPackConstants.lutsId,
    _ => null,
  };

  @override
  void initState() {
    super.initState();
    _destination = widget.initialDestination;
    _pexelsService = widget.pexelsService;
    _pixabayService = widget.pixabayService;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_isOnlineDestination) {
        unawaited(_loadOnlineResults());
      } else {
        unawaited(_refreshPack(_activePackId!));
      }
    });
  }

  @override
  void dispose() {
    _onlineRequestGeneration++;
    _searchTimer?.cancel();
    _onlineSearchController.dispose();
    _packSearchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final packState = ref.watch(assetPackProvider);
    return ResizableEditorSheet(
      title: widget.title,
      subtitle: widget.subtitle,
      icon: Icons.widgets_outlined,
      initialHeightFactor: 0.78,
      minHeightFactor: 0.52,
      maxHeightFactor: 0.92,
      scrollable: false,
      contentPadding: EdgeInsets.zero,
      onClose: _close,
      child: Column(
        children: [
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 160),
              child: KeyedSubtree(
                key: ValueKey<ElementLibraryDestination>(_destination),
                child: _isOnlineDestination
                    ? _buildOnlineLibrary()
                    : _buildPackLibrary(
                        _activePackId!,
                        packState.pack(_activePackId!),
                      ),
              ),
            ),
          ),
          if (widget.showNavigation) ...[
            const Divider(height: 1, color: kBorder),
            _buildNavigationBar(packState),
          ],
        ],
      ),
    );
  }

  Widget _buildNavigationBar(AssetPackManagerState packState) {
    return NavigationBar(
      key: const ValueKey('element-library-navigation'),
      height: 70,
      selectedIndex: _destination.index,
      onDestinationSelected: _selectDestination,
      backgroundColor: kSurfaceElevated,
      surfaceTintColor: Colors.transparent,
      indicatorColor: kAccent.withValues(alpha: 0.18),
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      destinations: [
        const NavigationDestination(
          key: ValueKey('element-library-nav-giphy'),
          icon: Icon(Icons.gif_box_outlined),
          selectedIcon: Icon(Icons.gif_box_rounded),
          label: 'GIPHY',
        ),
        const NavigationDestination(
          key: ValueKey('element-library-nav-pexels'),
          icon: Icon(Icons.photo_library_outlined),
          selectedIcon: Icon(Icons.photo_library_rounded),
          label: 'Pexels',
        ),
        const NavigationDestination(
          key: ValueKey('element-library-nav-pixabay'),
          icon: Icon(Icons.image_search_outlined),
          selectedIcon: Icon(Icons.image_search_rounded),
          label: 'Pixabay',
        ),
        NavigationDestination(
          key: ValueKey('element-library-nav-background-videos'),
          icon: _packNavigationIcon(
            Icons.video_library_outlined,
            packState.pack(AssetPackConstants.backgroundVideosId),
          ),
          selectedIcon: _packNavigationIcon(
            Icons.video_library_rounded,
            packState.pack(AssetPackConstants.backgroundVideosId),
            selected: true,
          ),
          label: 'BG Videos',
        ),
        NavigationDestination(
          key: ValueKey('element-library-nav-overlays'),
          icon: _packNavigationIcon(
            Icons.layers_outlined,
            packState.pack(AssetPackConstants.overlaysId),
          ),
          selectedIcon: _packNavigationIcon(
            Icons.layers_rounded,
            packState.pack(AssetPackConstants.overlaysId),
            selected: true,
          ),
          label: 'Overlays',
        ),
        NavigationDestination(
          key: const ValueKey('element-library-nav-luts'),
          icon: _packNavigationIcon(
            Icons.color_lens_outlined,
            packState.pack(AssetPackConstants.lutsId),
          ),
          selectedIcon: _packNavigationIcon(
            Icons.color_lens_rounded,
            packState.pack(AssetPackConstants.lutsId),
            selected: true,
          ),
          label: 'LUTs',
        ),
      ],
    );
  }

  void _selectDestination(int index) {
    final next = ElementLibraryDestination.values[index];
    if (next == _destination) return;

    _searchTimer?.cancel();
    _onlineRequestGeneration++;
    setState(() {
      _destination = next;
      _onlineResults = const [];
      _onlineError = null;
      _onlineLoading = false;
      _selectedCategoryId = null;
      _packSearchController.clear();
      _selectionError = null;
    });

    if (_isOnlineDestination) {
      unawaited(_loadOnlineResults());
    } else {
      unawaited(_refreshPack(_activePackId!));
    }
  }

  Widget _buildOnlineLibrary() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  key: ValueKey('element-library-search-${_destination.name}'),
                  controller: _onlineSearchController,
                  onChanged: _onOnlineQueryChanged,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) {
                    _searchTimer?.cancel();
                    unawaited(_loadOnlineResults());
                  },
                  decoration: InputDecoration(
                    hintText: _onlineSearchHint,
                    prefixIcon: const Icon(Icons.search_rounded, size: 20),
                    suffixIcon: _onlineSearchController.text.isEmpty
                        ? null
                        : IconButton(
                            key: const ValueKey(
                              'element-library-clear-online-search',
                            ),
                            tooltip: 'Clear search',
                            onPressed: _clearOnlineSearch,
                            icon: const Icon(Icons.close_rounded, size: 18),
                          ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                key: ValueKey('element-library-refresh-${_destination.name}'),
                tooltip: 'Refresh',
                onPressed: _onlineLoading
                    ? null
                    : () => unawaited(_loadOnlineResults(forceRefresh: true)),
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 7),
          child: Align(
            alignment: Alignment.centerLeft,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: _buildOnlineFilters(),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: InkWell(
              key: ValueKey('element-library-attribution-${_destination.name}'),
              borderRadius: BorderRadius.circular(6),
              onTap: () => unawaited(_openExternalUrl(_providerHomeUrl)),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _providerAttribution,
                      style: const TextStyle(
                        color: kTextSecondary,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.35,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Icon(
                      Icons.open_in_new_rounded,
                      color: kTextSecondary,
                      size: 11,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (_selectionError != null) _buildSelectionError(),
        const Divider(height: 1, color: kBorder),
        Expanded(child: _buildOnlineResults()),
      ],
    );
  }

  String get _onlineSearchHint => switch (_destination) {
    ElementLibraryDestination.giphy => 'Search GIFs and stickers',
    ElementLibraryDestination.pexels => 'Search Pexels photos and videos',
    ElementLibraryDestination.pixabay => 'Search Pixabay media',
    _ => 'Search media',
  };

  String get _providerAttribution => switch (_destination) {
    ElementLibraryDestination.giphy => 'Powered by GIPHY',
    ElementLibraryDestination.pexels => 'Photos and videos provided by Pexels',
    ElementLibraryDestination.pixabay => 'Media provided by Pixabay',
    _ => '',
  };

  String get _providerHomeUrl => switch (_destination) {
    ElementLibraryDestination.giphy => 'https://giphy.com/',
    ElementLibraryDestination.pexels => 'https://www.pexels.com/',
    ElementLibraryDestination.pixabay => 'https://pixabay.com/',
    _ => '',
  };

  Widget _buildOnlineFilters() {
    return switch (_destination) {
      ElementLibraryDestination.giphy => Row(
        children: [
          _filterChip(
            keyName: 'element-library-filter-giphy-all',
            label: 'All',
            selected: _giphyKind == GiphySearchKind.both,
            onSelected: () => _changeGiphyKind(GiphySearchKind.both),
          ),
          _chipGap,
          _filterChip(
            keyName: 'element-library-filter-giphy-gifs',
            label: 'GIFs',
            selected: _giphyKind == GiphySearchKind.gifs,
            onSelected: () => _changeGiphyKind(GiphySearchKind.gifs),
          ),
          _chipGap,
          _filterChip(
            keyName: 'element-library-filter-giphy-stickers',
            label: 'Stickers',
            selected: _giphyKind == GiphySearchKind.stickers,
            onSelected: () => _changeGiphyKind(GiphySearchKind.stickers),
          ),
        ],
      ),
      ElementLibraryDestination.pexels => Row(
        children: [
          _filterChip(
            keyName: 'element-library-filter-pexels-all',
            label: 'All',
            selected: _pexelsFilter == PexelsMediaFilter.all,
            onSelected: () => _changePexelsFilter(PexelsMediaFilter.all),
          ),
          _chipGap,
          _filterChip(
            keyName: 'element-library-filter-pexels-photos',
            label: 'Photos',
            selected: _pexelsFilter == PexelsMediaFilter.photos,
            onSelected: () => _changePexelsFilter(PexelsMediaFilter.photos),
          ),
          _chipGap,
          _filterChip(
            keyName: 'element-library-filter-pexels-videos',
            label: 'Videos',
            selected: _pexelsFilter == PexelsMediaFilter.videos,
            onSelected: () => _changePexelsFilter(PexelsMediaFilter.videos),
          ),
        ],
      ),
      ElementLibraryDestination.pixabay => Row(
        children: [
          _filterChip(
            keyName: 'element-library-filter-pixabay-all',
            label: 'All',
            selected: _pixabayFilter == PixabayMediaFilter.all,
            onSelected: () => _changePixabayFilter(PixabayMediaFilter.all),
          ),
          _chipGap,
          _filterChip(
            keyName: 'element-library-filter-pixabay-photos',
            label: 'Photos',
            selected: _pixabayFilter == PixabayMediaFilter.photos,
            onSelected: () => _changePixabayFilter(PixabayMediaFilter.photos),
          ),
          _chipGap,
          _filterChip(
            keyName: 'element-library-filter-pixabay-illustrations',
            label: 'Illustrations',
            selected: _pixabayFilter == PixabayMediaFilter.illustrations,
            onSelected: () =>
                _changePixabayFilter(PixabayMediaFilter.illustrations),
          ),
          _chipGap,
          _filterChip(
            keyName: 'element-library-filter-pixabay-vectors',
            label: 'Vectors',
            selected: _pixabayFilter == PixabayMediaFilter.vectors,
            onSelected: () => _changePixabayFilter(PixabayMediaFilter.vectors),
          ),
          _chipGap,
          _filterChip(
            keyName: 'element-library-filter-pixabay-videos',
            label: 'Videos',
            selected: _pixabayFilter == PixabayMediaFilter.videos,
            onSelected: () => _changePixabayFilter(PixabayMediaFilter.videos),
          ),
        ],
      ),
      _ => const SizedBox.shrink(),
    };
  }

  static const Widget _chipGap = SizedBox(width: 8);

  Widget _filterChip({
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

  void _changeGiphyKind(GiphySearchKind kind) {
    if (_giphyKind == kind) return;
    setState(() => _giphyKind = kind);
    unawaited(_loadOnlineResults());
  }

  void _changePexelsFilter(PexelsMediaFilter filter) {
    if (_pexelsFilter == filter) return;
    setState(() => _pexelsFilter = filter);
    unawaited(_loadOnlineResults());
  }

  void _changePixabayFilter(PixabayMediaFilter filter) {
    if (_pixabayFilter == filter) return;
    setState(() => _pixabayFilter = filter);
    unawaited(_loadOnlineResults());
  }

  void _onOnlineQueryChanged(String _) {
    setState(() {});
    _searchTimer?.cancel();
    _searchTimer = Timer(widget.searchDebounce, () {
      unawaited(_loadOnlineResults());
    });
  }

  void _clearOnlineSearch() {
    _searchTimer?.cancel();
    _onlineSearchController.clear();
    setState(() {});
    unawaited(_loadOnlineResults());
  }

  Future<void> _loadOnlineResults({bool forceRefresh = false}) async {
    if (!_isOnlineDestination) return;
    _searchTimer?.cancel();
    final requestGeneration = ++_onlineRequestGeneration;
    final requestedDestination = _destination;
    final query = _onlineSearchController.text.trim();
    setState(() {
      _onlineLoading = true;
      _onlineError = null;
      _selectionError = null;
    });

    try {
      final results = await switch (requestedDestination) {
        ElementLibraryDestination.giphy => _searchGiphy(
          query,
          forceRefresh: forceRefresh,
        ),
        ElementLibraryDestination.pexels => _searchPexels(query),
        ElementLibraryDestination.pixabay => _searchPixabay(query),
        _ => Future<List<ElementLibraryAsset>>.value(const []),
      };
      if (!mounted ||
          requestGeneration != _onlineRequestGeneration ||
          requestedDestination != _destination) {
        return;
      }
      setState(() {
        _onlineResults = results;
        _onlineLoading = false;
      });
    } catch (error) {
      if (!mounted ||
          requestGeneration != _onlineRequestGeneration ||
          requestedDestination != _destination) {
        return;
      }
      setState(() {
        _onlineResults = const [];
        _onlineLoading = false;
        _onlineError = _friendlyError(error);
      });
    }
  }

  Future<List<ElementLibraryAsset>> _searchGiphy(
    String query, {
    bool forceRefresh = false,
  }) async {
    final callback = widget.giphySearch;
    final results = callback == null
        ? await GiphyService.shared.search(
            query: query,
            kind: _giphyKind,
            forceRefresh: forceRefresh,
          )
        : await callback(query, _giphyKind);
    return results.map(_normalizeGiphyResult).toList(growable: false);
  }

  Future<List<ElementLibraryAsset>> _searchPexels(String query) {
    final callback = widget.pexelsSearch;
    if (callback != null) return callback(query, _pexelsFilter);
    return (_pexelsService ??= PexelsService()).search(
      query: query,
      filter: _pexelsFilter,
    );
  }

  Future<List<ElementLibraryAsset>> _searchPixabay(String query) {
    final callback = widget.pixabaySearch;
    if (callback != null) return callback(query, _pixabayFilter);
    return (_pixabayService ??= PixabayService()).search(
      query: query,
      filter: _pixabayFilter,
    );
  }

  ElementLibraryAsset _normalizeGiphyResult(GiphyAssetResult result) {
    final subtype = result.isSticker
        ? ElementLibraryAssetSubtype.sticker
        : ElementLibraryAssetSubtype.gif;
    final typeLabel = result.isSticker ? 'Sticker' : 'GIF';
    return ElementLibraryAsset(
      id: 'giphy-${result.isSticker ? 'sticker' : 'gif'}-${result.id}',
      title: result.title.trim().isEmpty ? typeLabel : result.title.trim(),
      previewUrl: result.previewUrl,
      downloadUrl: result.originalUrl,
      provider: ElementLibraryProvider.giphy,
      mediaKind: ElementLibraryMediaKind.image,
      subtype: subtype,
      width: result.width,
      height: result.height,
      attribution: '$typeLabel via GIPHY',
      sourcePageUrl: result.sourcePageUrl,
    );
  }

  Widget _buildOnlineResults() {
    if (_onlineLoading) {
      return Center(
        key: const ValueKey('element-library-online-loading'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.cloud_download_rounded,
              color: kTextSecondary,
              size: 28,
            ),
            const SizedBox(height: 10),
            const Text(
              'Loading media…',
              style: TextStyle(color: kTextSecondary),
            ),
          ],
        ),
      );
    }
    if (_onlineError != null) {
      return _messagePanel(
        key: const ValueKey('element-library-online-error'),
        icon: Icons.cloud_off_rounded,
        message: _onlineError!,
        action: OutlinedButton.icon(
          key: ValueKey('element-library-retry-${_destination.name}'),
          onPressed: () => unawaited(_loadOnlineResults()),
          icon: const Icon(Icons.refresh_rounded, size: 18),
          label: const Text('Try again'),
        ),
      );
    }
    if (_onlineResults.isEmpty) {
      return _messagePanel(
        key: const ValueKey('element-library-online-empty'),
        icon: Icons.search_off_rounded,
        message: _onlineSearchController.text.trim().isEmpty
            ? 'Nothing popular is available right now.'
            : 'No results match this search.',
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxTileWidth = constraints.maxWidth >= 900 ? 220.0 : 185.0;
        return GridView.builder(
          key: ValueKey('element-library-grid-${_destination.name}'),
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: maxTileWidth,
            mainAxisExtent: 192,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
          ),
          itemCount: _onlineResults.length,
          itemBuilder: (context, index) {
            return _buildOnlineTile(_onlineResults[index]);
          },
        );
      },
    );
  }

  Widget _buildOnlineTile(ElementLibraryAsset asset) {
    final selecting = _selectionId == 'online:${asset.id}';
    final sourceUrl = _assetSourceUrl(asset);
    return Card(
      key: ValueKey('element-library-result-${asset.id}'),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _selectionId == null
            ? () => unawaited(_selectOnlineAsset(asset))
            : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.network(
                    asset.previewUrl,
                    fit: BoxFit.cover,
                    cacheWidth: 440,
                    cacheHeight: 320,
                    filterQuality: FilterQuality.low,
                    gaplessPlayback: true,
                    errorBuilder: (_, _, _) => _brokenPreview(),
                  ),
                  if (asset.mediaKind == ElementLibraryMediaKind.video)
                    const Positioned(
                      top: 8,
                      right: 8,
                      child: _MediaBadge(
                        icon: Icons.play_arrow_rounded,
                        label: 'Video',
                      ),
                    ),
                  if (selecting)
                    const ColoredBox(
                      color: Color(0x88000000),
                      child: Center(
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(9, 7, 9, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    asset.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: kTextPrimary,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: sourceUrl == null
                        ? null
                        : () => unawaited(_openExternalUrl(sourceUrl)),
                    child: Text(
                      asset.attribution,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: kTextSecondary,
                        fontSize: 9,
                        decoration: sourceUrl == null
                            ? TextDecoration.none
                            : TextDecoration.underline,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _selectOnlineAsset(ElementLibraryAsset asset) async {
    if (_selectionId != null) return;
    setState(() {
      _selectionId = 'online:${asset.id}';
      _selectionError = null;
    });
    try {
      await widget.onOnlineAssetSelected(asset);
      if (!mounted) return;
      _close();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _selectionId = null;
        _selectionError = _friendlyError(error);
      });
    }
  }

  Widget _buildPackLibrary(String packId, AssetPackDownloadState packState) {
    final catalog = packState.catalog;
    if (catalog != null && !packState.isActive) {
      return _buildInstalledPack(catalog, packState);
    }
    if ((packState.status == AssetPackDownloadStatus.idle ||
            packState.status == AssetPackDownloadStatus.checking) &&
        !packState.installRequested) {
      return Center(
        key: ValueKey('element-library-pack-checking-$packId'),
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(strokeWidth: 2),
            SizedBox(height: 12),
            Text(
              'Checking this pack…',
              style: TextStyle(color: kTextSecondary, fontSize: 12),
            ),
          ],
        ),
      );
    }

    final release = packState.release;
    final progress = packState.progress;
    final title = release?.title ?? _packTitle(packId);
    final model = AssetPackDownloadViewModel(
      packId: packId,
      title: title,
      description: release?.description ?? _packDescription(packId),
      stage: _panelStage(packState.status),
      version: release?.version ?? catalog?.version,
      assetCount: release?.assetCount ?? catalog?.items.length,
      downloadBytes: release?.archiveBytes,
      temporarySpaceBytes: release == null
          ? null
          : release.archiveBytes + release.installedBytes,
      receivedBytes: progress?.receivedBytes ?? 0,
      totalBytes: progress?.totalBytes,
      queuePosition: packState.queuePosition,
      partIndex: progress?.partIndex,
      partCount: progress?.partCount,
      errorMessage: packState.errorMessage,
      icon: switch (packId) {
        AssetPackConstants.backgroundVideosId =>
          Icons.video_collection_outlined,
        AssetPackConstants.lutsId => Icons.color_lens_outlined,
        _ => Icons.layers_outlined,
      },
    );
    return AssetPackDownloadPanel(
      key: ValueKey('element-library-pack-download-panel-$packId'),
      model: model,
      onDownload: () =>
          unawaited(ref.read(assetPackProvider.notifier).enqueue(packId)),
      onStop: () =>
          unawaited(ref.read(assetPackProvider.notifier).cancel(packId)),
      onRetry: () => unawaited(
        release == null
            ? _refreshPack(packId)
            : ref.read(assetPackProvider.notifier).retry(packId),
      ),
    );
  }

  Future<void> _refreshPack(String packId) {
    return ref
        .read(assetPackProvider.notifier)
        .refresh(packId, fetchRemoteMetadata: true);
  }

  Widget _buildInstalledPack(
    AssetPackCatalog catalog,
    AssetPackDownloadState packState,
  ) {
    final query = _packSearchController.text.trim().toLowerCase();
    final items = catalog.items
        .where((item) {
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
        _buildInstalledPackHeader(catalog, packState),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 7),
          child: TextField(
            key: ValueKey('element-library-pack-search-${catalog.id}'),
            controller: _packSearchController,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: 'Search ${catalog.title}',
              prefixIcon: const Icon(Icons.search_rounded, size: 20),
              suffixIcon: _packSearchController.text.isEmpty
                  ? null
                  : IconButton(
                      key: const ValueKey('element-library-clear-pack-search'),
                      tooltip: 'Clear search',
                      onPressed: () {
                        _packSearchController.clear();
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
                      keyName: 'element-library-pack-filter-${catalog.id}-all',
                      label: 'All',
                      selected: _selectedCategoryId == null,
                      onSelected: () {
                        setState(() => _selectedCategoryId = null);
                      },
                    ),
                    for (final categoryId in catalog.categoryIds) ...[
                      _chipGap,
                      _filterChip(
                        keyName:
                            'element-library-pack-filter-${catalog.id}-$categoryId',
                        label: catalog.categoryNames[categoryId] ?? categoryId,
                        selected: _selectedCategoryId == categoryId,
                        onSelected: () {
                          setState(() => _selectedCategoryId = categoryId);
                        },
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'CaptionCraft ${catalog.title} • stored locally',
              style: const TextStyle(
                color: kTextSecondary,
                fontSize: 10,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
        if (_selectionError != null) _buildSelectionError(),
        const Divider(height: 1, color: kBorder),
        Expanded(
          child: items.isEmpty
              ? _messagePanel(
                  key: const ValueKey('element-library-pack-empty'),
                  icon: Icons.search_off_rounded,
                  message: 'No local assets match these filters.',
                )
              : _buildPackGrid(items),
        ),
      ],
    );
  }

  Widget _buildInstalledPackHeader(
    AssetPackCatalog catalog,
    AssetPackDownloadState packState,
  ) {
    final mediaBytes = catalog.items.fold<int>(
      0,
      (total, item) => total + item.sizeBytes,
    );
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
          Container(
            key: ValueKey('element-library-pack-installed-${catalog.id}'),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
                  size: 20,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Ready on this device',
                        style: TextStyle(
                          color: kTextPrimary,
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'v${catalog.version} • ${catalog.items.length} assets • '
                        '${AssetPackDownloadPanel.formatBytes(mediaBytes)}',
                        maxLines: 1,
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
                  onRemove: () =>
                      ref.read(assetPackProvider.notifier).remove(catalog.id),
                ),
              ],
            ),
          ),
          if (packState.removalErrorMessage != null) ...[
            const SizedBox(height: 8),
            Container(
              key: ValueKey('element-library-pack-removal-error-${catalog.id}'),
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
            _buildInstalledPackAction(
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

  Widget _buildInstalledPackAction(
    AssetPackCatalog catalog,
    AssetPackDownloadState packState, {
    required bool updateFailed,
    required bool metadataFailed,
  }) {
    final color = updateFailed || metadataFailed ? kWarning : kAccent;
    final release = packState.release;
    final message = updateFailed
        ? 'The update did not finish. Your installed v${catalog.version} '
              'library is still ready to use.'
        : metadataFailed
        ? 'Could not check for updates. Your installed library is unaffected.'
        : 'Version ${release?.version ?? ''} is available'
              '${release == null ? '.' : ' • ${AssetPackDownloadPanel.formatBytes(release.archiveBytes)}.'}';
    return Container(
      key: ValueKey('element-library-pack-update-${catalog.id}'),
      padding: const EdgeInsets.fromLTRB(12, 9, 9, 9),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(
            updateFailed || metadataFailed
                ? Icons.info_outline_rounded
                : Icons.system_update_alt_rounded,
            color: color,
            size: 19,
          ),
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
          const SizedBox(width: 8),
          TextButton(
            key: ValueKey('element-library-pack-update-action-${catalog.id}'),
            onPressed: () => unawaited(
              metadataFailed
                  ? _refreshPack(catalog.id)
                  : updateFailed
                  ? ref.read(assetPackProvider.notifier).retry(catalog.id)
                  : ref.read(assetPackProvider.notifier).enqueue(catalog.id),
            ),
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
        final maxTileWidth = constraints.maxWidth >= 900 ? 220.0 : 185.0;
        return GridView.builder(
          key: ValueKey('element-library-pack-grid-${_activePackId!}'),
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: maxTileWidth,
            mainAxisExtent: 186,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
          ),
          itemCount: items.length,
          itemBuilder: (context, index) => _buildPackTile(items[index]),
        );
      },
    );
  }

  Widget _buildPackTile(AssetPackCatalogItem item) {
    final selecting = _selectionId == 'pack:${item.id}';
    final previewPath = item.previewPath;
    return Card(
      key: ValueKey('element-library-pack-result-${item.id}'),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _selectionId == null
            ? () => unawaited(_selectPackAsset(item))
            : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (previewPath == null)
                    _brokenPreview(
                      icon: switch (item.mediaKind) {
                        AssetPackMediaKind.video => Icons.movie_outlined,
                        AssetPackMediaKind.lut => Icons.color_lens_outlined,
                        _ => Icons.image_outlined,
                      },
                    )
                  else
                    Image.file(
                      File(previewPath),
                      fit: BoxFit.cover,
                      cacheWidth: 440,
                      cacheHeight: 320,
                      filterQuality: FilterQuality.low,
                      gaplessPlayback: true,
                      errorBuilder: (_, _, _) => _brokenPreview(),
                    ),
                  if (item.mediaKind == AssetPackMediaKind.video)
                    const Positioned(
                      top: 8,
                      right: 8,
                      child: _MediaBadge(
                        icon: Icons.play_arrow_rounded,
                        label: 'Video',
                      ),
                    ),
                  if (item.mediaKind == AssetPackMediaKind.lut)
                    const Positioned(
                      top: 8,
                      right: 8,
                      child: _MediaBadge(
                        icon: Icons.color_lens_outlined,
                        label: 'LUT',
                      ),
                    ),
                  if (selecting)
                    const ColoredBox(
                      color: Color(0x88000000),
                      child: Center(
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(9, 7, 9, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: kTextPrimary,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    item.categoryName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: kTextSecondary, fontSize: 9),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _selectPackAsset(AssetPackCatalogItem item) async {
    if (_selectionId != null) return;
    setState(() {
      _selectionId = 'pack:${item.id}';
      _selectionError = null;
    });
    try {
      await widget.onPackAssetSelected(item);
      if (!mounted) return;
      _close();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _selectionId = null;
        _selectionError = _friendlyError(error);
      });
    }
  }

  Widget _buildSelectionError() {
    return Container(
      key: const ValueKey('element-library-selection-error'),
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: kError.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kError.withValues(alpha: 0.55)),
      ),
      child: Text(
        _selectionError!,
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

  Widget _brokenPreview({IconData icon = Icons.broken_image_outlined}) {
    return ColoredBox(
      color: kSurfaceHigh,
      child: Center(child: Icon(icon, color: kTextSecondary, size: 30)),
    );
  }

  String _packTitle(String packId) {
    return switch (packId) {
      AssetPackConstants.backgroundVideosId => 'Background videos',
      AssetPackConstants.lutsId => 'LUTs',
      _ => 'Overlays',
    };
  }

  String _packDescription(String packId) {
    return switch (packId) {
      AssetPackConstants.backgroundVideosId =>
        'Curated motion backgrounds that stay available offline after a '
            'verified download.',
      AssetPackConstants.lutsId =>
        'Previewable color looks stored locally after a verified download.',
      _ =>
        'Curated image and video overlays, verified before they are added '
            'to your local library.',
    };
  }

  AssetPackPanelStage _panelStage(AssetPackDownloadStatus status) {
    return switch (status) {
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

  Widget _packNavigationIcon(
    IconData icon,
    AssetPackDownloadState packState, {
    bool selected = false,
  }) {
    final indicator = switch (packState.status) {
      AssetPackDownloadStatus.checking when !packState.installRequested =>
        const Icon(Icons.more_horiz_rounded, color: kTextSecondary, size: 13),
      AssetPackDownloadStatus.queued ||
      AssetPackDownloadStatus.checking ||
      AssetPackDownloadStatus.downloading ||
      AssetPackDownloadStatus.verifying ||
      AssetPackDownloadStatus.extracting ||
      AssetPackDownloadStatus.installing ||
      AssetPackDownloadStatus.stopping ||
      AssetPackDownloadStatus.removing => const SizedBox.square(
        dimension: 11,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      AssetPackDownloadStatus.installed => const Icon(
        Icons.check_circle_rounded,
        color: kSuccess,
        size: 13,
      ),
      AssetPackDownloadStatus.failed => const Icon(
        Icons.error_rounded,
        color: kError,
        size: 13,
      ),
      AssetPackDownloadStatus.cancelled => const Icon(
        Icons.stop_circle_rounded,
        color: kTextSecondary,
        size: 13,
      ),
      AssetPackDownloadStatus.idle || AssetPackDownloadStatus.available => null,
    };
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Icon(icon),
        if (indicator != null)
          Positioned(
            right: -6,
            top: -5,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: selected ? kSurfaceElevated : kSurface,
                shape: BoxShape.circle,
              ),
              child: Padding(
                padding: const EdgeInsets.all(1.5),
                child: indicator,
              ),
            ),
          ),
      ],
    );
  }

  String _friendlyError(Object error) {
    return error
        .toString()
        .replaceFirst(RegExp(r'^(Exception|AssetPackException):\s*'), '')
        .trim();
  }

  String? _assetSourceUrl(ElementLibraryAsset asset) {
    final source = asset.sourcePageUrl?.trim();
    if (source != null && source.isNotEmpty) return source;
    final creator = asset.creatorPageUrl?.trim();
    return creator == null || creator.isEmpty ? null : creator;
  }

  Future<void> _openExternalUrl(String value) async {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !const {'http', 'https'}.contains(uri.scheme.toLowerCase()) ||
        uri.host.isEmpty) {
      return;
    }
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

  void _close() {
    final callback = widget.onClose;
    if (callback != null) {
      callback();
      return;
    }
    unawaited(Navigator.of(context).maybePop());
  }
}

class _MediaBadge extends StatelessWidget {
  final IconData icon;
  final String label;

  const _MediaBadge({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.68),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 13),
            const SizedBox(width: 3),
            Text(
              label,
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
}
