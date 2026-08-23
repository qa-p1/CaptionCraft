import 'package:dio/dio.dart';

import '../../../core/utils/asset_pack_service.dart';
import '../models/asset_pack_models.dart';

/// The small surface an editor library needs from [AssetPackService].
///
/// Keeping this interface injectable makes it possible to verify that opening
/// a library only reads local state and never starts a download by itself.
abstract interface class AssetPackFacade {
  Future<AssetPackCatalog?> getInstalledCatalog(String packId);

  Future<AssetPackRelease> getRelease(
    String packId, {
    CancelToken? cancelToken,
  });

  Future<AssetPackCatalog> install(
    String packId, {
    AssetPackRelease? release,
    AssetPackProgressCallback? onProgress,
    CancelToken? cancelToken,
  });
}

/// Optional capability exposed by facades that can remove a downloaded pack.
///
/// Kept separate from [AssetPackFacade] so lightweight/read-only integrations
/// remain source compatible. [protectedPaths] is the final safety boundary:
/// an implementation must refuse removal when any path belongs to the pack.
abstract interface class AssetPackRemovalFacade {
  Future<void> uninstall(
    String packId, {
    Set<String> protectedPaths = const <String>{},
  });
}

class AssetPackServiceFacade
    implements AssetPackFacade, AssetPackRemovalFacade {
  final AssetPackService _service;

  AssetPackServiceFacade([AssetPackService? service])
    : _service = service ?? AssetPackService();

  @override
  Future<AssetPackCatalog?> getInstalledCatalog(String packId) {
    return _service.getInstalledCatalog(packId);
  }

  @override
  Future<AssetPackRelease> getRelease(
    String packId, {
    CancelToken? cancelToken,
  }) {
    return _service.getRelease(packId, cancelToken: cancelToken);
  }

  @override
  Future<AssetPackCatalog> install(
    String packId, {
    AssetPackRelease? release,
    AssetPackProgressCallback? onProgress,
    CancelToken? cancelToken,
  }) {
    return _service.install(
      packId,
      release: release,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
  }

  @override
  Future<void> uninstall(
    String packId, {
    Set<String> protectedPaths = const <String>{},
  }) {
    return _service.uninstall(packId, protectedPaths: protectedPaths);
  }
}
