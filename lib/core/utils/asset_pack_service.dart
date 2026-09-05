import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../features/editor/models/asset_pack_models.dart';
import '../constants/asset_pack_constants.dart';
import 'storage_capacity_service.dart';

typedef AssetPackProgressCallback = void Function(AssetPackProgress progress);
typedef AssetPackAvailableStorageProbe =
    Future<int?> Function(Directory directory);

enum AssetPackFailureReason {
  cancelled,
  busy,
  inUse,
  configuration,
  network,
  storage,
  integrity,
  invalidManifest,
  invalidArchive,
  filesystem,
}

/// Installs optional media libraries into app-managed storage.
///
/// Construction and [getInstalledCatalog] are strictly local. Release metadata
/// is fetched only when a pack tab asks for it, and media bytes are fetched only
/// by [install]. Verified partial downloads are durable so Stop, a connection
/// drop, or an app restart can continue with an HTTP range request.
class AssetPackService {
  AssetPackService({
    Dio? dio,
    @visibleForTesting Directory? rootDirectoryOverride,
    @visibleForTesting String? manifestUrlOverride,
    @visibleForTesting AssetPackAvailableStorageProbe? availableStorageProbe,
  }) : _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 25),
               receiveTimeout: const Duration(hours: 1),
               sendTimeout: const Duration(seconds: 25),
             ),
           ),
       _rootDirectoryOverride = rootDirectoryOverride,
       _manifestUrlOverride = manifestUrlOverride,
       _availableStorageProbe =
           availableStorageProbe ?? _platformAvailableStorageBytes;

  final Dio _dio;
  final Directory? _rootDirectoryOverride;
  final String? _manifestUrlOverride;
  final AssetPackAvailableStorageProbe? _availableStorageProbe;
  final Map<String, Future<AssetPackCatalog>> _installOperations = {};

  static Future<int?> _platformAvailableStorageBytes(Directory directory) =>
      StorageCapacityService.availableBytes(directory);

  Future<AssetPackCatalog?> getInstalledCatalog(String packId) async {
    _validatePackId(packId);
    final root = await _rootDirectory();
    final packRoot = Directory(p.join(root.path, packId));
    final markerData = await _readInstallMarker(packRoot, packId);
    if (markerData == null) return null;
    try {
      final releaseName = _safePathSegment(markerData.releaseDirectory);
      final installationDirectory = Directory(
        p.join(packRoot.path, 'releases', releaseName),
      );
      if (!await installationDirectory.exists()) return null;
      final catalog = await AssetPackCatalog.load(
        expectedPackId: packId,
        installationDirectory: installationDirectory,
        catalogPath: markerData.catalogPath,
      );
      if (catalog.version != markerData.version) return null;
      return catalog;
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  /// Fetches the small public descriptor for [packId], never the archives.
  Future<AssetPackRelease> getRelease(
    String packId, {
    CancelToken? cancelToken,
  }) async {
    _validatePackId(packId);
    _throwIfCancelled(cancelToken);
    final manifestUri = _manifestUri();
    try {
      final response = await _dio.get<String>(
        manifestUri.toString(),
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.plain,
          headers: const {HttpHeaders.acceptHeader: 'application/json'},
        ),
      );
      _validateFinalUri(manifestUri, response.realUri, 'manifest');
      final declaredLength = int.tryParse(
        response.headers.value(HttpHeaders.contentLengthHeader) ?? '',
      );
      if (declaredLength != null &&
          declaredLength > AssetPackConstants.maxManifestBytes) {
        throw const FormatException('Public asset manifest is too large.');
      }
      final body = response.data ?? '';
      if (utf8.encode(body).length > AssetPackConstants.maxManifestBytes) {
        throw const FormatException('Public asset manifest is too large.');
      }
      final data = jsonDecode(body);
      if (data is! Map<String, dynamic>) {
        throw const FormatException(
          'Public asset manifest must be a JSON object.',
        );
      }
      final schemaVersion = data['schemaVersion'];
      if (schemaVersion is! int ||
          !AssetPackConstants.supportedManifestSchemaVersions.contains(
            schemaVersion,
          )) {
        throw const FormatException('Public asset manifest is unsupported.');
      }
      final rawPacks = data['packs'];
      if (rawPacks is! List || rawPacks.length > 100) {
        throw const FormatException('Public asset manifest packs are invalid.');
      }
      final ids = <String>{};
      Map<String, dynamic>? requested;
      for (final raw in rawPacks) {
        if (raw is! Map) {
          throw const FormatException(
            'Public asset manifest contains an invalid pack.',
          );
        }
        final row = Map<String, dynamic>.from(raw);
        final id = row['id'];
        if (id is! String || id.trim().isEmpty || !ids.add(id.trim())) {
          throw const FormatException(
            'Public asset manifest contains duplicate or invalid pack IDs.',
          );
        }
        if (id.trim() == packId) requested = row;
      }
      if (requested == null) {
        throw const FormatException(
          'This pack has not been published yet. Check again after it is uploaded.',
        );
      }
      final release = AssetPackRelease.fromJson(
        requested,
        manifestUri: response.realUri,
        manifestSchemaVersion: schemaVersion,
      );
      if (release.id != packId) {
        throw const FormatException(
          'Public release belongs to another asset pack.',
        );
      }
      return release;
    } on AssetPackException {
      rethrow;
    } on DioException catch (error) {
      if (CancelToken.isCancel(error) || cancelToken?.isCancelled == true) {
        throw const AssetPackException.cancelled();
      }
      throw AssetPackException(
        'Could not load the asset-pack manifest: '
        '${error.message ?? 'network error'}.',
        reason: AssetPackFailureReason.network,
        retryable: true,
      );
    } on FormatException catch (error) {
      throw AssetPackException(
        error.message.toString(),
        reason: AssetPackFailureReason.invalidManifest,
      );
    }
  }

  /// Installs or updates a pack. Concurrent calls for the same pack join one
  /// operation even if multiple sheets request it at the same time.
  Future<AssetPackCatalog> install(
    String packId, {
    AssetPackRelease? release,
    AssetPackProgressCallback? onProgress,
    CancelToken? cancelToken,
  }) {
    _validatePackId(packId);
    final existing = _installOperations[packId];
    if (existing != null) return existing;
    late final Future<AssetPackCatalog> operation;
    operation =
        _install(
          packId,
          suppliedRelease: release,
          onProgress: onProgress,
          cancelToken: cancelToken,
        ).whenComplete(() {
          if (identical(_installOperations[packId], operation)) {
            _installOperations.remove(packId);
          }
        });
    _installOperations[packId] = operation;
    return operation;
  }

  /// Removes all locally downloaded data for [packId].
  ///
  /// The caller supplies every path referenced by current and saved projects.
  /// Removal is refused if even one reference resolves inside this pack's
  /// managed directory. This intentionally protects old release directories as
  /// well as the current release because saved projects may still point to an
  /// older content-addressed version.
  Future<void> uninstall(
    String packId, {
    Set<String> protectedPaths = const <String>{},
  }) async {
    _validatePackId(packId);
    if (_installOperations.containsKey(packId)) {
      throw const AssetPackException(
        'Wait for this asset-pack download to finish or stop it first.',
        reason: AssetPackFailureReason.busy,
        retryable: true,
      );
    }

    final root = await _rootDirectory();
    final rootPath = p.normalize(p.absolute(root.path));
    final packRoot = Directory(p.join(rootPath, packId));
    final packPath = p.normalize(p.absolute(packRoot.path));
    final expectedPackPath = p.normalize(p.join(rootPath, packId));
    if (!p.equals(packPath, expectedPackPath) ||
        !p.isWithin(rootPath, packPath)) {
      throw const AssetPackException(
        'CaptionCraft refused an unsafe asset-pack removal path.',
        reason: AssetPackFailureReason.filesystem,
      );
    }

    final referencedInsidePack = protectedPaths.any((path) {
      final value = path.trim();
      if (value.isEmpty) return false;
      final protectedPath = p.normalize(p.absolute(value));
      return p.equals(protectedPath, packPath) ||
          p.isWithin(packPath, protectedPath);
    });
    if (referencedInsidePack) {
      throw const AssetPackException(
        'This library is still used by a project. Remove its clips from every '
        'project before deleting the downloaded assets.',
        reason: AssetPackFailureReason.inUse,
      );
    }

    try {
      await _deleteDirectoryWithin(root, packRoot);
      final downloadsRoot = Directory(p.join(rootPath, '.downloads'));
      final packDownloads = Directory(p.join(downloadsRoot.path, packId));
      await _deleteDirectoryWithin(downloadsRoot, packDownloads);
      await _deleteEmptyDirectory(downloadsRoot);
    } on AssetPackException {
      rethrow;
    } on FileSystemException catch (error) {
      throw AssetPackException(
        'Could not remove this asset pack: ${error.message}.',
        reason: AssetPackFailureReason.filesystem,
        retryable: true,
      );
    }
  }

  Future<AssetPackCatalog> _install(
    String packId, {
    required AssetPackRelease? suppliedRelease,
    AssetPackProgressCallback? onProgress,
    CancelToken? cancelToken,
  }) async {
    onProgress?.call(
      const AssetPackProgress(phase: AssetPackProgressPhase.fetchingManifest),
    );
    final release =
        suppliedRelease ?? await getRelease(packId, cancelToken: cancelToken);
    if (release.id != packId) {
      throw const AssetPackException(
        'Release metadata belongs to another asset pack.',
        reason: AssetPackFailureReason.invalidManifest,
      );
    }
    _throwIfCancelled(cancelToken);

    final root = await _rootDirectory();
    await root.create(recursive: true);
    final packRoot = Directory(p.join(root.path, packId));
    final releasesRoot = Directory(p.join(packRoot.path, 'releases'));
    final temporaryRoot = Directory(p.join(root.path, '.tmp'));
    final downloadsRoot = Directory(
      p.join(root.path, '.downloads', _safePathSegment(packId)),
    );
    await Future.wait([
      packRoot.create(recursive: true),
      releasesRoot.create(recursive: true),
      temporaryRoot.create(recursive: true),
      downloadsRoot.create(recursive: true),
    ]);
    await _removeStaleOperationDirectories(root, temporaryRoot);

    final releaseName = _safePathSegment(
      '${release.version}_${release.fingerprint.substring(0, 12)}',
    );
    final finalDirectory = Directory(p.join(releasesRoot.path, releaseName));
    final recovered = await _loadExistingRelease(
      packRoot: packRoot,
      packId: packId,
      release: release,
      releaseName: releaseName,
      finalDirectory: finalDirectory,
    );
    if (recovered != null) {
      onProgress?.call(
        AssetPackProgress(
          phase: AssetPackProgressPhase.complete,
          receivedBytes: release.archiveBytes,
          totalBytes: release.archiveBytes,
          partCount: release.archiveParts.length,
          partIndex: release.archiveParts.length - 1,
        ),
      );
      return recovered;
    }

    final downloadDirectory = Directory(
      p.join(downloadsRoot.path, release.fingerprint),
    );
    await downloadDirectory.create(recursive: true);
    await _ensureEnoughStorage(root, release, downloadDirectory);

    final operationId =
        '${_safePathSegment(packId)}_${DateTime.now().microsecondsSinceEpoch}';
    final operationRoot = Directory(p.join(temporaryRoot.path, operationId));
    final extractionRoot = Directory(p.join(operationRoot.path, 'extracted'));
    await extractionRoot.create(recursive: true);

    final partFiles = <File>[];
    try {
      var completedDownloadBytes = 0;
      final parts = release.archiveParts;
      for (var index = 0; index < parts.length; index++) {
        final part = parts[index];
        _throwIfCancelled(cancelToken);
        final partFile = File(
          p.join(
            downloadDirectory.path,
            '${_safePathSegment(part.id)}.zip.part',
          ),
        );
        partFiles.add(partFile);
        await _downloadPart(
          part: part,
          file: partFile,
          metadataFile: File('${partFile.path}.json'),
          completedBytes: completedDownloadBytes,
          releaseTotalBytes: release.archiveBytes,
          partIndex: index,
          partCount: parts.length,
          onProgress: onProgress,
          cancelToken: cancelToken,
        );
        completedDownloadBytes += part.bytes;
      }

      for (var index = 0; index < parts.length; index++) {
        _throwIfCancelled(cancelToken);
        onProgress?.call(
          AssetPackProgress(
            phase: AssetPackProgressPhase.verifying,
            receivedBytes: release.archiveBytes,
            totalBytes: release.archiveBytes,
            partIndex: index,
            partCount: parts.length,
          ),
        );
        final actualDigest = await _sha256File(
          partFiles[index],
          cancelToken: cancelToken,
        );
        if (actualDigest != parts[index].sha256) {
          await _deleteFileIfPresent(partFiles[index]);
          await _deleteFileIfPresent(File('${partFiles[index].path}.json'));
          throw const AssetPackException(
            'Pack integrity check failed. Please download it again.',
            reason: AssetPackFailureReason.integrity,
            retryable: true,
          );
        }
      }

      onProgress?.call(
        AssetPackProgress(
          phase: AssetPackProgressPhase.extracting,
          receivedBytes: release.archiveBytes,
          totalBytes: release.archiveBytes,
          partCount: parts.length,
        ),
      );
      var installedBytes = 0;
      var archiveEntries = 0;
      final extractedFiles = <String>{};
      for (var index = 0; index < parts.length; index++) {
        _throwIfCancelled(cancelToken);
        final result = await _extractArchiveInWorker(
          archiveFile: partFiles[index],
          outputDirectory: extractionRoot,
          existingFilePaths: extractedFiles,
          remainingInstalledBytes: release.installedBytes - installedBytes,
          remainingEntries:
              AssetPackConstants.maxArchiveEntries - archiveEntries,
          cancelToken: cancelToken,
        );
        installedBytes += result.installedBytes;
        archiveEntries += result.entryCount;
        extractedFiles.addAll(result.filePaths);
        onProgress?.call(
          AssetPackProgress(
            phase: AssetPackProgressPhase.extracting,
            receivedBytes: release.archiveBytes,
            totalBytes: release.archiveBytes,
            partIndex: index,
            partCount: parts.length,
          ),
        );
      }
      if (installedBytes != release.installedBytes) {
        throw const AssetPackException(
          'Pack extracted-size check failed.',
          reason: AssetPackFailureReason.invalidArchive,
        );
      }

      final catalog = await AssetPackCatalog.load(
        expectedPackId: packId,
        installationDirectory: extractionRoot,
        catalogPath: release.catalogPath,
      );
      if (catalog.version != release.version) {
        throw const AssetPackException(
          'Pack version does not match the public manifest.',
          reason: AssetPackFailureReason.integrity,
        );
      }
      if (release.assetCount != null &&
          catalog.items.length != release.assetCount) {
        throw const AssetPackException(
          'Pack asset count does not match the public manifest.',
          reason: AssetPackFailureReason.integrity,
        );
      }

      onProgress?.call(
        AssetPackProgress(
          phase: AssetPackProgressPhase.installing,
          receivedBytes: release.archiveBytes,
          totalBytes: release.archiveBytes,
          partCount: parts.length,
        ),
      );
      _throwIfCancelled(cancelToken);
      if (await finalDirectory.exists()) {
        // A damaged content-addressed release must never make Retry loop
        // forever. Replacing this exact path also repairs saved timelines that
        // already reference it.
        await _deleteDirectoryWithin(releasesRoot, finalDirectory);
      }
      await _writeReleaseReceipt(
        extractionRoot,
        packId: packId,
        release: release,
      );
      final installedDirectory = await extractionRoot.rename(
        finalDirectory.path,
      );
      await _writeInstallMarker(
        packRoot: packRoot,
        packId: packId,
        release: release,
        releaseName: releaseName,
      );
      final installedCatalog = await AssetPackCatalog.load(
        expectedPackId: packId,
        installationDirectory: installedDirectory,
        catalogPath: release.catalogPath,
      );
      for (final file in partFiles) {
        await _deleteFileIfPresent(file);
        await _deleteFileIfPresent(File('${file.path}.json'));
      }
      await _deleteEmptyDirectory(downloadDirectory);
      onProgress?.call(
        AssetPackProgress(
          phase: AssetPackProgressPhase.complete,
          receivedBytes: release.archiveBytes,
          totalBytes: release.archiveBytes,
          partIndex: parts.length - 1,
          partCount: parts.length,
        ),
      );
      return installedCatalog;
    } on AssetPackException {
      rethrow;
    } on DioException catch (error) {
      if (CancelToken.isCancel(error) || cancelToken?.isCancelled == true) {
        throw const AssetPackException.cancelled();
      }
      throw AssetPackException(
        'Could not download this pack: ${error.message ?? 'network error'}.',
        reason: AssetPackFailureReason.network,
        retryable: true,
      );
    } on FormatException catch (error) {
      throw AssetPackException(
        error.message.toString(),
        reason: AssetPackFailureReason.invalidArchive,
      );
    } on FileSystemException catch (error) {
      throw AssetPackException(
        'Could not install this pack: ${error.message}.',
        reason: AssetPackFailureReason.filesystem,
        retryable: true,
      );
    } finally {
      await _deleteTemporaryDirectory(root, operationRoot);
    }
  }

  Future<void> _downloadPart({
    required AssetPackArchivePart part,
    required File file,
    required File metadataFile,
    required int completedBytes,
    required int releaseTotalBytes,
    required int partIndex,
    required int partCount,
    required AssetPackProgressCallback? onProgress,
    required CancelToken? cancelToken,
  }) async {
    var existingBytes = await file.exists() ? await file.length() : 0;
    var metadata = await _readPartialMetadata(metadataFile);
    final metadataMatches =
        metadata != null &&
        metadata.uri == part.uri.toString() &&
        metadata.sha256 == part.sha256 &&
        metadata.expectedBytes == part.bytes;
    if (!metadataMatches || existingBytes > part.bytes) {
      await _deleteFileIfPresent(file);
      await _deleteFileIfPresent(metadataFile);
      existingBytes = 0;
      metadata = null;
    }
    if (existingBytes == part.bytes) {
      onProgress?.call(
        AssetPackProgress(
          phase: AssetPackProgressPhase.downloading,
          receivedBytes: completedBytes + existingBytes,
          totalBytes: releaseTotalBytes,
          partIndex: partIndex,
          partCount: partCount,
        ),
      );
      return;
    }

    final headers = <String, dynamic>{
      HttpHeaders.acceptEncodingHeader: 'identity',
      if (existingBytes > 0) HttpHeaders.rangeHeader: 'bytes=$existingBytes-',
      if (existingBytes > 0 && metadata?.validator != null)
        'If-Range': metadata!.validator,
    };
    late Response<ResponseBody> response;
    try {
      response = await _dio.get<ResponseBody>(
        part.uri.toString(),
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.stream,
          headers: headers,
          followRedirects: true,
        ),
      );
    } on DioException catch (error) {
      if (CancelToken.isCancel(error) || cancelToken?.isCancelled == true) {
        throw const AssetPackException.cancelled();
      }
      rethrow;
    }
    _validateFinalUri(part.uri, response.realUri, 'archive');
    final status = response.statusCode ?? 0;
    if (existingBytes > 0 && status != HttpStatus.partialContent) {
      await _deleteFileIfPresent(file);
      await _deleteFileIfPresent(metadataFile);
      return _downloadPart(
        part: part,
        file: file,
        metadataFile: metadataFile,
        completedBytes: completedBytes,
        releaseTotalBytes: releaseTotalBytes,
        partIndex: partIndex,
        partCount: partCount,
        onProgress: onProgress,
        cancelToken: cancelToken,
      );
    }
    if (existingBytes == 0 &&
        status != HttpStatus.ok &&
        status != HttpStatus.partialContent) {
      throw AssetPackException(
        'Archive server returned HTTP $status.',
        reason: AssetPackFailureReason.network,
        retryable: true,
      );
    }
    if (existingBytes > 0) {
      final contentRange = response.headers.value(
        HttpHeaders.contentRangeHeader,
      );
      if (!_validContentRange(contentRange, existingBytes, part.bytes)) {
        await _deleteFileIfPresent(file);
        await _deleteFileIfPresent(metadataFile);
        throw const AssetPackException(
          'The download server returned an invalid resume range.',
          reason: AssetPackFailureReason.network,
          retryable: true,
        );
      }
    }
    final expectedResponseBytes = part.bytes - existingBytes;
    final contentLength = int.tryParse(
      response.headers.value(HttpHeaders.contentLengthHeader) ?? '',
    );
    if (contentLength != null && contentLength != expectedResponseBytes) {
      throw const AssetPackException(
        'Pack size check failed because the server returned an unexpected '
        'content length.',
        reason: AssetPackFailureReason.network,
        retryable: true,
      );
    }
    final validator =
        response.headers.value(HttpHeaders.etagHeader) ??
        response.headers.value(HttpHeaders.lastModifiedHeader);
    await _writePartialMetadata(
      metadataFile,
      _PartialMetadata(
        uri: part.uri.toString(),
        sha256: part.sha256,
        expectedBytes: part.bytes,
        validator: validator,
      ),
    );

    final sink = file.openWrite(
      mode: existingBytes > 0 ? FileMode.append : FileMode.write,
    );
    var written = existingBytes;
    try {
      final stream = response.data?.stream;
      if (stream == null) {
        throw const AssetPackException(
          'The pack download returned no data.',
          reason: AssetPackFailureReason.network,
          retryable: true,
        );
      }
      await for (final chunk in stream) {
        _throwIfCancelled(cancelToken);
        written += chunk.length;
        if (written > part.bytes) {
          throw const AssetPackException(
            'The downloaded pack exceeded its declared size.',
            reason: AssetPackFailureReason.integrity,
          );
        }
        sink.add(chunk);
        onProgress?.call(
          AssetPackProgress(
            phase: AssetPackProgressPhase.downloading,
            receivedBytes: completedBytes + written,
            totalBytes: releaseTotalBytes,
            partIndex: partIndex,
            partCount: partCount,
          ),
        );
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    _throwIfCancelled(cancelToken);
    final actualLength = await file.length();
    if (actualLength != part.bytes) {
      throw AssetPackException(
        'Pack size check failed (expected ${part.bytes} bytes, '
        'received $actualLength).',
        reason: AssetPackFailureReason.network,
        retryable: true,
      );
    }
  }

  Future<String> _sha256File(
    File file, {
    required CancelToken? cancelToken,
  }) async {
    Digest? digest;
    final output = _DigestSink((value) => digest = value);
    final input = sha256.startChunkedConversion(output);
    try {
      await for (final chunk in file.openRead()) {
        _throwIfCancelled(cancelToken);
        input.add(chunk);
      }
      input.close();
      _throwIfCancelled(cancelToken);
      return digest!.toString().toLowerCase();
    } finally {
      if (digest == null) input.close();
    }
  }

  Future<_ExtractionResult> _extractArchiveInWorker({
    required File archiveFile,
    required Directory outputDirectory,
    required Set<String> existingFilePaths,
    required int remainingInstalledBytes,
    required int remainingEntries,
    required CancelToken? cancelToken,
  }) async {
    _throwIfCancelled(cancelToken);
    final receivePort = ReceivePort();
    final completer = Completer<_ExtractionResult>();
    late StreamSubscription<dynamic> subscription;
    Isolate? isolate;
    subscription = receivePort.listen((message) {
      if (completer.isCompleted || message is! Map) return;
      if (message['ok'] == true) {
        completer.complete(
          _ExtractionResult(
            installedBytes: message['installedBytes'] as int,
            entryCount: message['entryCount'] as int,
            filePaths: Set<String>.from(message['filePaths'] as List),
          ),
        );
      } else {
        completer.completeError(
          AssetPackException(
            (message['message'] as String?) ?? 'Could not extract this pack.',
            reason: AssetPackFailureReason.invalidArchive,
          ),
        );
      }
    });
    try {
      isolate = await Isolate.spawn<Map<String, Object?>>(
        _assetPackExtractionWorker,
        {
          'sendPort': receivePort.sendPort,
          'archivePath': archiveFile.path,
          'outputPath': outputDirectory.path,
          'existingFilePaths': existingFilePaths.toList(growable: false),
          'remainingInstalledBytes': remainingInstalledBytes,
          'remainingEntries': remainingEntries,
        },
        debugName: 'asset-pack-extractor',
      );
      if (cancelToken != null) {
        unawaited(
          cancelToken.whenCancel.then((_) {
            isolate?.kill(priority: Isolate.immediate);
            if (!completer.isCompleted) {
              completer.completeError(const AssetPackException.cancelled());
            }
          }),
        );
      }
      return await completer.future;
    } finally {
      isolate?.kill(priority: Isolate.immediate);
      await subscription.cancel();
      receivePort.close();
    }
  }

  Future<AssetPackCatalog?> _loadExistingRelease({
    required Directory packRoot,
    required String packId,
    required AssetPackRelease release,
    required String releaseName,
    required Directory finalDirectory,
  }) async {
    if (!await finalDirectory.exists()) return null;
    try {
      final catalog = await AssetPackCatalog.load(
        expectedPackId: packId,
        installationDirectory: finalDirectory,
        catalogPath: release.catalogPath,
      );
      if (catalog.version != release.version ||
          (release.assetCount != null &&
              catalog.items.length != release.assetCount)) {
        throw const FormatException('Installed release metadata is damaged.');
      }
      await _writeInstallMarker(
        packRoot: packRoot,
        packId: packId,
        release: release,
        releaseName: releaseName,
      );
      return catalog;
    } on FileSystemException {
      return null;
    } on FormatException {
      // Keep the path until the replacement has been fully verified in .tmp;
      // deleting it here would create a gap if the redownload fails.
      return null;
    }
  }

  Future<void> _ensureEnoughStorage(
    Directory root,
    AssetPackRelease release,
    Directory downloadDirectory,
  ) async {
    final probe = _availableStorageProbe;
    if (probe == null) return;
    var reusableBytes = 0;
    for (final part in release.archiveParts) {
      final file = File(
        p.join(downloadDirectory.path, '${_safePathSegment(part.id)}.zip.part'),
      );
      if (await file.exists()) {
        reusableBytes += (await file.length()).clamp(0, part.bytes);
      }
    }
    final requiredBytes =
        release.archiveBytes - reusableBytes + release.installedBytes;
    final availableBytes = await probe(root);
    if (availableBytes != null && availableBytes < requiredBytes) {
      throw AssetPackException(
        'Not enough free space. This pack needs about '
        '${_formatBytes(requiredBytes)} available.',
        reason: AssetPackFailureReason.storage,
      );
    }
  }

  Future<_InstallMarker?> _readInstallMarker(
    Directory packRoot,
    String packId,
  ) async {
    final marker = File(p.join(packRoot.path, 'current.json'));
    final next = File('${marker.path}.next');
    final backup = File('${marker.path}.bak');
    for (final candidate in [marker, next, backup]) {
      final parsed = await _parseInstallMarker(candidate, packId);
      if (parsed == null) continue;
      if (candidate.path != marker.path && !await marker.exists()) {
        try {
          await candidate.rename(marker.path);
        } on FileSystemException {
          // The parsed backup remains usable even if recovery cannot rename it.
        }
      }
      return parsed;
    }
    return null;
  }

  Future<_InstallMarker?> _parseInstallMarker(File file, String packId) async {
    if (!await file.exists()) return null;
    try {
      if (await file.length() > 64 * 1024) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic> || decoded['packId'] != packId) {
        return null;
      }
      final schemaVersion = decoded['schemaVersion'];
      if (schemaVersion is! int || schemaVersion < 1 || schemaVersion > 2) {
        return null;
      }
      final version = decoded['version'];
      final releaseDirectory = decoded['releaseDirectory'];
      final catalogPath = decoded['catalogPath'];
      if (version is! String ||
          version.trim().isEmpty ||
          releaseDirectory is! String ||
          catalogPath is! String) {
        return null;
      }
      return _InstallMarker(
        version: version.trim(),
        releaseDirectory: _safePathSegment(releaseDirectory),
        catalogPath: normalizePackRelativePath(catalogPath),
      );
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  Future<void> _writeInstallMarker({
    required Directory packRoot,
    required String packId,
    required AssetPackRelease release,
    required String releaseName,
  }) async {
    final marker = File(p.join(packRoot.path, 'current.json'));
    final next = File('${marker.path}.next');
    final backup = File('${marker.path}.bak');
    await next.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'schemaVersion': 2,
        'packId': packId,
        'version': release.version,
        'fingerprint': release.fingerprint,
        'releaseDirectory': releaseName,
        'catalogPath': release.catalogPath,
        'installedAt': DateTime.now().toUtc().toIso8601String(),
      }),
      flush: true,
    );
    try {
      await _deleteFileIfPresent(backup);
      if (await marker.exists()) await marker.rename(backup.path);
      await next.rename(marker.path);
      await _deleteFileIfPresent(backup);
    } catch (_) {
      if (!await marker.exists() && await backup.exists()) {
        try {
          await backup.rename(marker.path);
        } on FileSystemException {
          // Reader recovery also understands the backup file.
        }
      }
      rethrow;
    }
  }

  Future<void> _writeReleaseReceipt(
    Directory releaseDirectory, {
    required String packId,
    required AssetPackRelease release,
  }) async {
    await File(
      p.join(releaseDirectory.path, '.captioncraft-release.json'),
    ).writeAsString(
      jsonEncode({
        'schemaVersion': 1,
        'packId': packId,
        'version': release.version,
        'fingerprint': release.fingerprint,
        'catalogPath': release.catalogPath,
      }),
      flush: true,
    );
  }

  Future<_PartialMetadata?> _readPartialMetadata(File file) async {
    if (!await file.exists()) return null;
    try {
      if (await file.length() > 32 * 1024) return null;
      final value = jsonDecode(await file.readAsString());
      if (value is! Map<String, dynamic> ||
          value['uri'] is! String ||
          value['sha256'] is! String ||
          value['expectedBytes'] is! int) {
        return null;
      }
      return _PartialMetadata(
        uri: value['uri'] as String,
        sha256: value['sha256'] as String,
        expectedBytes: value['expectedBytes'] as int,
        validator: value['validator'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _writePartialMetadata(
    File file,
    _PartialMetadata metadata,
  ) async {
    final next = File('${file.path}.next');
    await next.writeAsString(
      jsonEncode({
        'schemaVersion': 1,
        'uri': metadata.uri,
        'sha256': metadata.sha256,
        'expectedBytes': metadata.expectedBytes,
        'validator': metadata.validator,
      }),
      flush: true,
    );
    await _deleteFileIfPresent(file);
    await next.rename(file.path);
  }

  Uri _manifestUri() {
    final value = (_manifestUrlOverride ?? AssetPackConstants.manifestUrl)
        .trim();
    if (value.isEmpty) {
      throw const AssetPackException(
        'Download source not configured. Add '
        'CAPTIONCRAFT_ASSET_MANIFEST_URL to your build environment.',
        reason: AssetPackFailureReason.configuration,
      );
    }
    final uri = Uri.tryParse(value);
    if (uri == null || !_safePublicUri(uri)) {
      throw const AssetPackException(
        'Asset pack manifest URL must use HTTPS.',
        reason: AssetPackFailureReason.configuration,
      );
    }
    return uri;
  }

  void _validateFinalUri(Uri requested, Uri actual, String label) {
    if (!_safePublicUri(actual) || !_sameOrigin(requested, actual)) {
      throw AssetPackException(
        'Asset pack $label redirected to an untrusted location.',
        reason: AssetPackFailureReason.invalidManifest,
      );
    }
  }

  Future<Directory> _rootDirectory() async {
    final override = _rootDirectoryOverride;
    if (override != null) return override;
    final support = await getApplicationSupportDirectory();
    return Directory(p.join(support.path, 'caption_craft', 'media_packs'));
  }

  Future<void> _removeStaleOperationDirectories(
    Directory root,
    Directory temporaryRoot,
  ) async {
    if (!await temporaryRoot.exists()) return;
    final cutoff = DateTime.now().subtract(const Duration(days: 1));
    await for (final entity in temporaryRoot.list(followLinks: false)) {
      if (entity is! Directory) continue;
      try {
        final modified = await entity.stat().then((value) => value.modified);
        if (modified.isBefore(cutoff)) {
          await _deleteTemporaryDirectory(root, entity);
        }
      } on FileSystemException {
        // Reconciliation is best effort and never blocks a new install.
      }
    }
  }

  Future<void> _deleteTemporaryDirectory(
    Directory root,
    Directory temporary,
  ) async {
    final rootPath = p.normalize(p.absolute(root.path));
    final targetPath = p.normalize(p.absolute(temporary.path));
    if (!p.isWithin(rootPath, targetPath)) return;
    try {
      if (await temporary.exists()) await temporary.delete(recursive: true);
    } on FileSystemException {
      // Cleanup must not hide the original result.
    }
  }

  Future<void> _deleteDirectoryWithin(
    Directory parent,
    Directory target,
  ) async {
    final parentPath = p.normalize(p.absolute(parent.path));
    final targetPath = p.normalize(p.absolute(target.path));
    if (!p.isWithin(parentPath, targetPath)) {
      throw const FileSystemException('Unsafe asset-pack directory target.');
    }
    if (await target.exists()) await target.delete(recursive: true);
  }

  Future<void> _deleteFileIfPresent(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Callers either recover or report their primary operation error.
    }
  }

  Future<void> _deleteEmptyDirectory(Directory directory) async {
    try {
      if (await directory.exists() &&
          await directory.list(followLinks: false).isEmpty) {
        await directory.delete();
      }
    } on FileSystemException {
      // A harmless empty directory can be reconciled later.
    }
  }

  void _validatePackId(String packId) {
    if (!const {
      AssetPackConstants.backgroundVideosId,
      AssetPackConstants.overlaysId,
      AssetPackConstants.soundEffectsId,
      AssetPackConstants.lutsId,
    }.contains(packId)) {
      throw ArgumentError.value(packId, 'packId', 'Unsupported asset pack.');
    }
  }

  void _throwIfCancelled(CancelToken? cancelToken) {
    if (cancelToken?.isCancelled == true) {
      throw const AssetPackException.cancelled();
    }
  }
}

class AssetPackException implements Exception {
  const AssetPackException(
    this.message, {
    this.reason = AssetPackFailureReason.filesystem,
    this.retryable = false,
  });

  const AssetPackException.cancelled()
    : message = 'Asset pack download cancelled.',
      reason = AssetPackFailureReason.cancelled,
      retryable = true;

  final String message;
  final AssetPackFailureReason reason;
  final bool retryable;

  bool get isCancelled => reason == AssetPackFailureReason.cancelled;

  @override
  String toString() => message;
}

class _PartialMetadata {
  const _PartialMetadata({
    required this.uri,
    required this.sha256,
    required this.expectedBytes,
    required this.validator,
  });

  final String uri;
  final String sha256;
  final int expectedBytes;
  final String? validator;
}

class _InstallMarker {
  const _InstallMarker({
    required this.version,
    required this.releaseDirectory,
    required this.catalogPath,
  });

  final String version;
  final String releaseDirectory;
  final String catalogPath;
}

class _ExtractionResult {
  const _ExtractionResult({
    required this.installedBytes,
    required this.entryCount,
    required this.filePaths,
  });

  final int installedBytes;
  final int entryCount;
  final Set<String> filePaths;
}

class _DigestSink implements Sink<Digest> {
  const _DigestSink(this.onDigest);

  final void Function(Digest digest) onDigest;

  @override
  void add(Digest data) => onDigest(data);

  @override
  void close() {}
}

void _assetPackExtractionWorker(Map<String, Object?> args) {
  final sendPort = args['sendPort']! as SendPort;
  InputFileStream? input;
  late Map<String, Object?> result;
  try {
    final archivePath = args['archivePath']! as String;
    final outputPath = args['outputPath']! as String;
    final remainingInstalledBytes = args['remainingInstalledBytes']! as int;
    final remainingEntries = args['remainingEntries']! as int;
    final existingFilePaths = Set<String>.from(
      args['existingFilePaths']! as List,
    );
    input = InputFileStream(archivePath);
    final decoder = ZipDecoder();
    final archive = decoder.decodeStream(input);
    final headers = decoder.directory.fileHeaders;
    if (headers.isEmpty ||
        headers.length > remainingEntries ||
        archive.isEmpty) {
      throw const FormatException(
        'Pack archive has an invalid number of files.',
      );
    }

    var declaredBytes = 0;
    final headerPaths = <String, bool>{};
    for (final header in headers) {
      final normalized = normalizePackRelativePath(header.filename);
      final lower = normalized.toLowerCase();
      final isDirectory =
          header.filename.endsWith('/') || header.filename.endsWith(r'\');
      final previousWasDirectory = headerPaths[lower];
      if (previousWasDirectory != null &&
          (!isDirectory || !previousWasDirectory)) {
        throw const FormatException(
          'Pack archive contains duplicate file paths.',
        );
      }
      headerPaths[lower] = isDirectory;
      if ((header.generalPurposeBitFlag & 0x1) != 0) {
        throw const FormatException(
          'Encrypted asset-pack archives are not supported.',
        );
      }
      if (!isDirectory &&
          header.compressionMethod != 0 &&
          header.compressionMethod != 8) {
        throw const FormatException(
          'Pack archive uses an unsupported compression method.',
        );
      }
      if (!isDirectory) {
        declaredBytes += header.uncompressedSize;
        if (declaredBytes > remainingInstalledBytes) {
          throw const FormatException(
            'Pack archive expands beyond its declared size.',
          );
        }
      }
    }

    final root = Directory(outputPath)..createSync(recursive: true);
    var installedBytes = 0;
    final writtenFiles = <String>{};
    for (final entry in archive) {
      final normalized = normalizePackRelativePath(entry.name);
      final lower = normalized.toLowerCase();
      if (entry.isSymbolicLink) {
        throw const FormatException(
          'Pack archive contains unsupported symbolic links.',
        );
      }
      final resolved = resolvePackRelativePath(root, normalized);
      if (entry.isDirectory) {
        Directory(resolved).createSync(recursive: true);
        continue;
      }
      if (!existingFilePaths.add(lower) || !writtenFiles.add(lower)) {
        throw const FormatException(
          'Pack archive contains duplicate file paths.',
        );
      }
      final outputFile = File(resolved);
      if (outputFile.existsSync() || Directory(resolved).existsSync()) {
        throw const FormatException(
          'Pack archive would overwrite another extracted path.',
        );
      }
      outputFile.parent.createSync(recursive: true);
      final output = OutputFileStream(resolved, bufferSize: 1024 * 1024);
      try {
        entry.writeContent(output);
      } finally {
        output.closeSync();
      }
      final actualBytes = outputFile.lengthSync();
      if (actualBytes != entry.size) {
        throw const FormatException(
          'Pack archive produced a damaged output file.',
        );
      }
      installedBytes += actualBytes;
      if (installedBytes > remainingInstalledBytes) {
        throw const FormatException(
          'Pack archive expands beyond its declared size.',
        );
      }
    }
    result = {
      'ok': true,
      'installedBytes': installedBytes,
      'entryCount': headers.length,
      'filePaths': writtenFiles.toList(growable: false),
    };
  } catch (error) {
    result = {'ok': false, 'message': error.toString()};
  }
  try {
    // Close the ZIP before notifying the parent. The parent tears the worker
    // down as soon as it receives the result; sending first can strand an open
    // archive handle on Windows and make the installed pack undeletable.
    input?.closeSync();
  } catch (error) {
    result = {'ok': false, 'message': error.toString()};
  }
  sendPort.send(result);
}

String _safePathSegment(String value) {
  final normalized = value.trim().replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  if (normalized.isEmpty || normalized == '.' || normalized == '..') {
    throw const FormatException('Asset pack path segment is invalid.');
  }
  return normalized;
}

bool _validContentRange(String? value, int start, int total) {
  if (value == null) return false;
  final match = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(value.trim());
  if (match == null) return false;
  final parsedStart = int.tryParse(match.group(1)!);
  final parsedEnd = int.tryParse(match.group(2)!);
  final parsedTotal = int.tryParse(match.group(3)!);
  return parsedStart == start &&
      parsedEnd != null &&
      parsedEnd >= start &&
      parsedEnd < total &&
      parsedTotal == total;
}

bool _safePublicUri(Uri uri) {
  if (uri.host.isEmpty || uri.userInfo.isNotEmpty || uri.hasFragment) {
    return false;
  }
  if (uri.scheme.toLowerCase() == 'https') return true;
  return uri.scheme.toLowerCase() == 'http' && _isLoopbackHost(uri.host);
}

bool _isLoopbackHost(String host) {
  final value = host.toLowerCase();
  return value == 'localhost' || value == '127.0.0.1' || value == '::1';
}

bool _sameOrigin(Uri left, Uri right) {
  int port(Uri uri) {
    if (uri.hasPort) return uri.port;
    return uri.scheme.toLowerCase() == 'https' ? 443 : 80;
  }

  return left.scheme.toLowerCase() == right.scheme.toLowerCase() &&
      left.host.toLowerCase() == right.host.toLowerCase() &&
      port(left) == port(right);
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}
