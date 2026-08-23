import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:mime/mime.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../features/editor/models/discover_models.dart';
import 'youtube_download_service.dart';

typedef DiscoverCatalogWriter =
    Future<void> Function(File catalog, String snapshot);

abstract class DiscoverDownloadFacade {
  Stream<List<DiscoverDownloadItem>> get items;

  List<DiscoverDownloadItem> get currentItems;

  Future<void> initialize();

  Future<DiscoverDownloadItem> enqueueDirect(DiscoverDownloadRequest request);

  Future<YoutubeVideoInfo> inspectYoutube(String url);

  Future<DiscoverDownloadItem> enqueueYoutube({
    required YoutubeVideoInfo info,
    required YoutubeFormatOption format,
    required bool permittedContentAcknowledged,
    String? outputFileName,
  });

  Future<void> cancel(String id);

  Future<void> retry(String id);

  Future<void> delete(String id);

  Future<bool> open(String id);

  void dispose();
}

class DiscoverDownloadManager implements DiscoverDownloadFacade {
  DiscoverDownloadManager({
    Dio? dio,
    YoutubeMediaService? youtubeService,
    Directory? storageDirectory,
    Future<Directory> Function()? documentsDirectoryProvider,
    DateTime Function()? clock,
    String Function()? idGenerator,
    Future<bool> Function(String path)? fileOpener,
    DiscoverCatalogWriter? catalogWriter,
    this.maxDirectBytes = 512 * 1024 * 1024,
    this.maxYoutubeBytes = YoutubeDownloadService.defaultMaxBytes,
  }) : _dio = dio ?? Dio(),
       _youtubeService = youtubeService ?? YoutubeDownloadService(),
       _storageDirectoryOverride = storageDirectory,
       _documentsDirectoryProvider =
           documentsDirectoryProvider ?? getApplicationDocumentsDirectory,
       _clock = clock ?? DateTime.now,
       _idGenerator = idGenerator ?? const Uuid().v4,
       _fileOpener = fileOpener ?? _openWithPlatform,
       _catalogWriter = catalogWriter ?? _writeCatalogAtomically;

  static const int catalogVersion = 1;

  final Dio _dio;
  final YoutubeMediaService _youtubeService;
  final Directory? _storageDirectoryOverride;
  final Future<Directory> Function() _documentsDirectoryProvider;
  final DateTime Function() _clock;
  final String Function() _idGenerator;
  final Future<bool> Function(String path) _fileOpener;
  final DiscoverCatalogWriter _catalogWriter;
  final int maxDirectBytes;
  final int maxYoutubeBytes;

  final StreamController<List<DiscoverDownloadItem>> _itemsController =
      StreamController<List<DiscoverDownloadItem>>.broadcast(sync: true);
  final Map<String, _DirectJobControl> _directJobs =
      <String, _DirectJobControl>{};
  final Map<String, DiscoverDownloadRequest> _directRequests =
      <String, DiscoverDownloadRequest>{};
  final Map<String, Future<void>> _activeJobs = <String, Future<void>>{};
  final Map<String, int> _lastProgressEmitMicros = <String, int>{};
  final Stopwatch _progressClock = Stopwatch()..start();

  List<DiscoverDownloadItem> _currentItems = <DiscoverDownloadItem>[];
  Directory? _storageDirectory;
  File? _catalogFile;
  Future<void>? _initialization;
  Future<void> _catalogWriteTail = Future<void>.value();
  bool _disposed = false;

  @override
  Stream<List<DiscoverDownloadItem>> get items => _itemsController.stream;

  @override
  List<DiscoverDownloadItem> get currentItems =>
      List<DiscoverDownloadItem>.unmodifiable(_currentItems);

  @override
  Future<void> initialize() {
    _ensureNotDisposed();
    return _initialization ??= _initialize();
  }

  Future<void> _initialize() async {
    final storage =
        _storageDirectoryOverride ??
        Directory(
          p.join(
            (await _documentsDirectoryProvider()).path,
            'CaptionCraft',
            'discover_downloads',
          ),
        );
    await storage.create(recursive: true);
    _storageDirectory = storage;
    _catalogFile = File(p.join(storage.path, 'downloads.json'));
    await _cleanupParts(storage);
    _currentItems = await _readCatalog(storage);
    final reconciled = await _reconcile(_currentItems);
    _currentItems = _sortItems(reconciled);
    _emit();
    await _persist();
  }

  @override
  Future<DiscoverDownloadItem> enqueueDirect(
    DiscoverDownloadRequest request,
  ) async {
    await initialize();
    final uri = _validatedHttpsUri(request.url);
    final id = _uniqueId();
    final fileName = _fileNameFor(
      id: id,
      requestedName: request.displayName,
      sourceUri: uri,
      kind: request.kind,
      mimeType: request.mimeType,
    );
    final now = _clock().toUtc();
    final safeRequest = DiscoverDownloadRequest(
      url: uri.toString(),
      displayName: _boundedDisplayName(request.displayName),
      kind: request.kind,
      pageUrl: _optionalHttpsUrl(request.pageUrl),
      headers: _ephemeralHeaders(request.headers),
      mimeType: _boundedMime(request.mimeType),
      metadata: _jsonSafeMap(request.metadata),
    );
    final item = DiscoverDownloadItem(
      id: id,
      source: DiscoverDownloadSource.direct,
      status: DiscoverDownloadStatus.queued,
      sourceUrl: safeRequest.url,
      pageUrl: safeRequest.pageUrl,
      displayName: safeRequest.displayName,
      fileName: fileName,
      mimeType: safeRequest.mimeType,
      kind: safeRequest.kind,
      receivedBytes: 0,
      createdAt: now,
      updatedAt: now,
      metadata: safeRequest.metadata,
    );
    _directRequests[id] = safeRequest;
    await _addAndPersist(item);
    _startJob(id, () => _runDirect(id, safeRequest));
    return item;
  }

  @override
  Future<YoutubeVideoInfo> inspectYoutube(String url) {
    _ensureNotDisposed();
    return _youtubeService.inspect(url);
  }

  @override
  Future<DiscoverDownloadItem> enqueueYoutube({
    required YoutubeVideoInfo info,
    required YoutubeFormatOption format,
    required bool permittedContentAcknowledged,
    String? outputFileName,
  }) async {
    await initialize();
    if (!permittedContentAcknowledged) {
      throw StateError(
        'Confirm that you own the content or have permission to download it.',
      );
    }
    final parsedVideoId = YoutubeDownloadService.parseVideoIdFromUrl(
      info.canonicalUrl,
    );
    if (parsedVideoId == null || parsedVideoId != info.videoId) {
      throw const FormatException(
        'The inspected YouTube URL and video identifier do not match.',
      );
    }
    final selected = info.formats.where((value) => value.id == format.id);
    if (selected.isEmpty) {
      throw ArgumentError('The selected format does not belong to this video.');
    }
    final selectedFormat = selected.first;
    final id = _uniqueId();
    final sourceUri = _validatedHttpsUri(info.canonicalUrl);
    final requestedName = outputFileName?.trim().isNotEmpty == true
        ? outputFileName!.trim()
        : info.title;
    final kind = selectedFormat.kind == YoutubeDownloadKind.audioOnly
        ? DiscoverMediaKind.audio
        : DiscoverMediaKind.video;
    final fileName = _fileNameFor(
      id: id,
      requestedName: requestedName,
      sourceUri: sourceUri,
      kind: kind,
      preferredExtension: selectedFormat.container,
    );
    final now = _clock().toUtc();
    final item = DiscoverDownloadItem(
      id: id,
      source: DiscoverDownloadSource.youtube,
      status: DiscoverDownloadStatus.queued,
      sourceUrl: sourceUri.toString(),
      displayName: _boundedDisplayName(requestedName),
      fileName: fileName,
      mimeType: _youtubeMime(selectedFormat),
      kind: kind,
      receivedBytes: 0,
      totalBytes: selectedFormat.estimatedBytes,
      createdAt: now,
      updatedAt: now,
      metadata: <String, dynamic>{
        'youtubeInfo': info.toJson(),
        'youtubeFormat': selectedFormat.toJson(),
        'permittedContentAcknowledged': true,
      },
    );
    await _addAndPersist(item);
    _startJob(id, () => _runYoutube(id, info, selectedFormat));
    return item;
  }

  Future<void> _runDirect(String id, DiscoverDownloadRequest request) async {
    final item = _itemById(id);
    if (item == null) return;
    final storage = _requireStorage();
    final destination = File(p.join(storage.path, item.fileName));
    final part = File('${destination.path}.part');
    final control = _DirectJobControl(CancelToken());
    _directJobs[id] = control;
    try {
      await _deleteIfExists(part);
      await _replaceAndPersist(
        item.copyWith(
          status: DiscoverDownloadStatus.downloading,
          receivedBytes: 0,
          updatedAt: _clock().toUtc(),
          clearErrorMessage: true,
          clearLocalPath: true,
        ),
      );
      final download = await _downloadWithSafeRedirects(
        id: id,
        initialUri: Uri.parse(request.url),
        part: part,
        initialHeaders: request.headers,
        control: control,
      );
      final response = download.response;
      if (!await part.exists() || await part.length() == 0) {
        throw StateError('The downloaded file is empty.');
      }
      final length = await part.length();
      if (length > maxDirectBytes) {
        throw StateError('The download exceeded the size limit.');
      }
      final responseMime = response.headers
          .value(Headers.contentTypeHeader)
          ?.split(';')
          .first
          .trim();
      final sniffedMime = await _sniffMime(
        part,
        responseMime,
        download.finalUri.toString(),
      );
      _validateDownloadedMime(sniffedMime, download.finalUri.toString());
      final resolvedKind = _kindForMimeOrPath(
        sniffedMime,
        download.finalUri.toString(),
        fallback: request.kind,
      );
      _throwIfDirectCancelled(control, id);
      await _deleteIfExists(destination);
      _throwIfDirectCancelled(control, id);
      await part.rename(destination.path);
      final current = _itemById(id);
      if (current == null) {
        await _deleteIfExists(destination);
        return;
      }
      if (control.userCancelled ||
          current.status == DiscoverDownloadStatus.cancelled) {
        await _deleteIfExists(destination);
        throw StateError('Download was cancelled.');
      }
      await _replaceAndPersist(
        current.copyWith(
          status: DiscoverDownloadStatus.completed,
          localPath: destination.path,
          mimeType: sniffedMime,
          kind: resolvedKind,
          receivedBytes: length,
          totalBytes: length,
          updatedAt: _clock().toUtc(),
          clearErrorMessage: true,
        ),
      );
    } catch (error) {
      final current = _itemById(id);
      if (current != null) {
        final wasCancelled =
            control.userCancelled ||
            current.status == DiscoverDownloadStatus.cancelled;
        await _replaceAndPersist(
          current.copyWith(
            status: wasCancelled
                ? DiscoverDownloadStatus.cancelled
                : DiscoverDownloadStatus.failed,
            errorMessage: wasCancelled
                ? null
                : control.exceededLimit
                ? 'The download exceeded the ${_sizeLabel(maxDirectBytes)} limit.'
                : _friendlyError(error),
            updatedAt: _clock().toUtc(),
            clearLocalPath: true,
          ),
        );
      }
    } finally {
      _directJobs.remove(id);
      _lastProgressEmitMicros.remove(id);
      await _deleteIfExists(part);
    }
  }

  Future<({Response<dynamic> response, Uri finalUri})>
  _downloadWithSafeRedirects({
    required String id,
    required Uri initialUri,
    required File part,
    required Map<String, String> initialHeaders,
    required _DirectJobControl control,
  }) async {
    const redirectStatuses = <int>{301, 302, 303, 307, 308};
    const maxRedirects = 5;
    var currentUri = _validatedHttpsUri(initialUri.toString());
    var headers = Map<String, String>.from(initialHeaders);
    final visited = <String>{currentUri.toString()};

    for (var redirectCount = 0; ; redirectCount++) {
      _throwIfDirectCancelled(control, id);
      await _deleteIfExists(part);
      final response = await _dio.download(
        currentUri.toString(),
        part.path,
        cancelToken: control.cancelToken,
        deleteOnError: false,
        options: Options(
          headers: headers,
          followRedirects: false,
          maxRedirects: 0,
          receiveTimeout: const Duration(minutes: 10),
          sendTimeout: const Duration(seconds: 30),
          validateStatus: (status) =>
              status != null &&
              ((status >= 200 && status < 300) ||
                  redirectStatuses.contains(status)),
        ),
        onReceiveProgress: (received, total) {
          if (received > maxDirectBytes || total > maxDirectBytes) {
            control.exceededLimit = true;
            control.cancelToken.cancel('Download size limit exceeded.');
            return;
          }
          _updateProgress(id, received, total > 0 ? total : null);
        },
      );
      final status = response.statusCode;
      if (status != null && status >= 200 && status < 300) {
        if (response.realUri.scheme.toLowerCase() != 'https') {
          throw StateError('The download resolved to an insecure URL.');
        }
        return (response: response, finalUri: currentUri);
      }

      await _deleteIfExists(part);
      if (redirectCount >= maxRedirects) {
        throw StateError('The download redirected too many times.');
      }
      final location = response.headers.value(HttpHeaders.locationHeader);
      if (location == null || location.trim().isEmpty) {
        throw StateError(
          'The download redirect did not include a destination.',
        );
      }
      final nextUri = _validatedHttpsUri(
        currentUri.resolve(location.trim()).toString(),
      );
      if (!visited.add(nextUri.toString())) {
        throw StateError('The download entered a redirect loop.');
      }
      if (!_sameAuthority(currentUri, nextUri)) {
        headers = _headersForCrossAuthorityRedirect(headers);
      }
      currentUri = nextUri;
    }
  }

  static bool _sameAuthority(Uri first, Uri second) =>
      first.host.toLowerCase() == second.host.toLowerCase() &&
      _effectivePort(first) == _effectivePort(second);

  static int _effectivePort(Uri uri) {
    if (uri.hasPort) return uri.port;
    return uri.scheme.toLowerCase() == 'https' ? 443 : 80;
  }

  static Map<String, String> _headersForCrossAuthorityRedirect(
    Map<String, String> headers,
  ) {
    const sensitiveNames = <String>{
      'authorization',
      'proxy-authorization',
      'cookie',
      'cookie2',
      'referer',
      'origin',
      'x-api-key',
    };
    return <String, String>{
      for (final entry in headers.entries)
        if (!sensitiveNames.contains(entry.key.toLowerCase()) &&
            !entry.key.toLowerCase().contains('token') &&
            !entry.key.toLowerCase().contains('session'))
          entry.key: entry.value,
    };
  }

  Future<void> _runYoutube(
    String id,
    YoutubeVideoInfo info,
    YoutubeFormatOption format,
  ) async {
    final item = _itemById(id);
    if (item == null) return;
    final destination = File(p.join(_requireStorage().path, item.fileName));
    try {
      await _replaceAndPersist(
        item.copyWith(
          status: DiscoverDownloadStatus.downloading,
          receivedBytes: 0,
          updatedAt: _clock().toUtc(),
          clearErrorMessage: true,
          clearLocalPath: true,
        ),
      );
      final beforeStart = _itemById(id);
      if (beforeStart == null ||
          beforeStart.status == DiscoverDownloadStatus.cancelled) {
        return;
      }
      final result = await _youtubeService.download(
        jobId: id,
        info: info,
        format: format,
        outputPath: destination.path,
        maxBytes: maxYoutubeBytes,
        onProgress: (received, total) => _updateProgress(id, received, total),
        onProcessing: () {
          final current = _itemById(id);
          if (current == null ||
              current.status == DiscoverDownloadStatus.cancelled) {
            return;
          }
          _replaceWithoutPersist(
            current.copyWith(
              status: DiscoverDownloadStatus.processing,
              updatedAt: _clock().toUtc(),
            ),
          );
        },
      );
      final current = _itemById(id);
      if (current == null) {
        await _deleteIfExists(destination);
        return;
      }
      if (current.status == DiscoverDownloadStatus.cancelled) {
        await _deleteIfExists(destination);
        return;
      }
      await _replaceAndPersist(
        current.copyWith(
          status: DiscoverDownloadStatus.completed,
          localPath: result.path,
          mimeType: result.mimeType,
          receivedBytes: result.totalBytes,
          totalBytes: result.totalBytes,
          updatedAt: _clock().toUtc(),
          clearErrorMessage: true,
        ),
      );
    } catch (error) {
      final current = _itemById(id);
      if (current != null) {
        final wasCancelled =
            error is YoutubeDownloadCancelledException ||
            current.status == DiscoverDownloadStatus.cancelled;
        await _replaceAndPersist(
          current.copyWith(
            status: wasCancelled
                ? DiscoverDownloadStatus.cancelled
                : DiscoverDownloadStatus.failed,
            errorMessage: wasCancelled ? null : _friendlyError(error),
            updatedAt: _clock().toUtc(),
            clearLocalPath: true,
          ),
        );
      }
      if (_itemById(id)?.status != DiscoverDownloadStatus.completed) {
        await _deleteIfExists(destination);
      }
    } finally {
      _lastProgressEmitMicros.remove(id);
    }
  }

  @override
  Future<void> cancel(String id) async {
    await initialize();
    final item = _itemById(id);
    if (item == null || item.isTerminal) return;
    final direct = _directJobs[id];
    if (direct != null) {
      direct.userCancelled = true;
      direct.cancelToken.cancel('Cancelled by user.');
    }
    final current = _itemById(id);
    if (current != null) {
      await _replaceAndPersist(
        current.copyWith(
          status: DiscoverDownloadStatus.cancelled,
          updatedAt: _clock().toUtc(),
          clearErrorMessage: true,
          clearLocalPath: true,
        ),
      );
    }
    if (item.source == DiscoverDownloadSource.youtube) {
      await _youtubeService.cancel(id);
    }
    final activeJob = _activeJobs[id];
    if (activeJob != null) {
      try {
        await activeJob;
      } catch (_) {
        // The worker has already translated failures into item state.
      }
    }
  }

  @override
  Future<void> retry(String id) async {
    await initialize();
    final item = _itemById(id);
    if (item == null) {
      throw ArgumentError.value(id, 'id', 'Download not found.');
    }
    if (!item.canRetry) {
      throw StateError('Only failed or cancelled downloads can be retried.');
    }
    if (item.localPath != null) await _deleteManagedPath(item.localPath!);
    final queued = item.copyWith(
      status: DiscoverDownloadStatus.queued,
      receivedBytes: 0,
      updatedAt: _clock().toUtc(),
      clearTotalBytes: item.source == DiscoverDownloadSource.direct,
      clearLocalPath: true,
      clearErrorMessage: true,
    );
    await _replaceAndPersist(queued);
    if (item.source == DiscoverDownloadSource.direct) {
      _validatedHttpsUri(item.sourceUrl);
      final request =
          _directRequests[id] ??
          DiscoverDownloadRequest(
            url: item.sourceUrl,
            displayName: item.displayName,
            kind: item.kind,
            pageUrl: item.pageUrl,
            mimeType: item.mimeType,
            metadata: item.metadata,
          );
      _directRequests[id] = request;
      _startJob(id, () => _runDirect(id, request));
      return;
    }
    final infoJson = item.metadata['youtubeInfo'];
    final formatJson = item.metadata['youtubeFormat'];
    final acknowledged = item.metadata['permittedContentAcknowledged'] == true;
    if (infoJson is! Map || formatJson is! Map || !acknowledged) {
      await _markFailed(id, 'This YouTube download cannot be safely retried.');
      return;
    }
    final info = YoutubeVideoInfo.fromJson(_stringKeyedMap(infoJson));
    final format = YoutubeFormatOption.fromJson(_stringKeyedMap(formatJson));
    _startJob(id, () => _runYoutube(id, info, format));
  }

  void _startJob(String id, Future<void> Function() run) {
    late final Future<void> job;
    job = run();
    _activeJobs[id] = job;
    unawaited(() async {
      try {
        await job;
      } catch (_) {
        // Workers normally report errors in state. Persistence failures should
        // not surface as unhandled asynchronous errors either.
      } finally {
        if (identical(_activeJobs[id], job)) _activeJobs.remove(id);
      }
    }());
  }

  @override
  Future<void> delete(String id) async {
    await initialize();
    final item = _itemById(id);
    if (item == null) return;
    if (!item.isTerminal) await cancel(id);
    _directRequests.remove(id);
    _currentItems = _currentItems.where((value) => value.id != id).toList();
    _emit();
    await _persist();
    if (item.localPath != null) await _deleteManagedPath(item.localPath!);
    final predicted = File(p.join(_requireStorage().path, item.fileName));
    await _deleteIfExists(predicted);
    await _deleteIfExists(File('${predicted.path}.part'));
  }

  @override
  Future<bool> open(String id) async {
    await initialize();
    final item = _itemById(id);
    final path = item?.localPath;
    if (item == null || !item.canImport || path == null) return false;
    if (!_isManagedPath(path) || !await File(path).exists()) return false;
    return _fileOpener(path);
  }

  Future<void> _markFailed(String id, String message) async {
    final item = _itemById(id);
    if (item == null) return;
    await _replaceAndPersist(
      item.copyWith(
        status: DiscoverDownloadStatus.failed,
        errorMessage: message,
        updatedAt: _clock().toUtc(),
      ),
    );
  }

  void _updateProgress(String id, int received, int? total) {
    final item = _itemById(id);
    if (item == null || item.status == DiscoverDownloadStatus.cancelled) return;
    final updated = item.copyWith(
      receivedBytes: math.max(0, received),
      totalBytes: total != null && total > 0 ? total : null,
      updatedAt: _clock().toUtc(),
    );
    final index = _currentItems.indexWhere((value) => value.id == id);
    if (index < 0) return;
    final items = List<DiscoverDownloadItem>.from(_currentItems);
    items[index] = updated;
    _currentItems = items;

    // Dio can report progress hundreds of times per second. Rebuilding the
    // entire Discover sheet for every network chunk wastes CPU/GPU time and is
    // especially noticeable as heat on mobile devices. Keep the precise state
    // internally, but publish at most roughly eight frames per second plus the
    // first and final updates.
    const minimumIntervalMicros = 120000;
    final now = _progressClock.elapsedMicroseconds;
    final previous = _lastProgressEmitMicros[id];
    final isComplete = total != null && total > 0 && received >= total;
    if (previous == null ||
        isComplete ||
        now - previous >= minimumIntervalMicros) {
      _lastProgressEmitMicros[id] = now;
      _emit();
    }
  }

  Future<void> _addAndPersist(DiscoverDownloadItem item) async {
    _currentItems = _sortItems(<DiscoverDownloadItem>[item, ..._currentItems]);
    _emit();
    await _persist();
  }

  void _replaceWithoutPersist(DiscoverDownloadItem item) {
    final index = _currentItems.indexWhere((value) => value.id == item.id);
    if (index < 0) return;
    final updated = List<DiscoverDownloadItem>.from(_currentItems);
    updated[index] = item;
    _currentItems = _sortItems(updated);
    _emit();
  }

  Future<void> _replaceAndPersist(DiscoverDownloadItem item) async {
    _replaceWithoutPersist(item);
    await _persist();
  }

  DiscoverDownloadItem? _itemById(String id) {
    for (final item in _currentItems) {
      if (item.id == id) return item;
    }
    return null;
  }

  void _emit() {
    if (!_itemsController.isClosed) {
      _itemsController.add(currentItems);
    }
  }

  Future<void> _persist() {
    final catalog = _catalogFile;
    if (catalog == null) return Future<void>.value();
    final snapshot = jsonEncode(<String, dynamic>{
      'version': catalogVersion,
      'items': _currentItems.map((item) => item.toJson()).toList(),
    });
    final previous = _catalogWriteTail;
    final operation = () async {
      try {
        await previous;
      } catch (_) {
        // A later snapshot can repair a failed earlier write.
      }
      await _catalogWriter(catalog, snapshot);
    }();
    _catalogWriteTail = operation;
    return operation;
  }

  static Future<void> _writeCatalogAtomically(
    File catalog,
    String snapshot,
  ) async {
    final temporary = File('${catalog.path}.tmp');
    final backup = File('${catalog.path}.bak');
    await temporary.writeAsString(snapshot, flush: true);
    if (await catalog.exists()) {
      await _deleteIfExists(backup);
      await catalog.copy(backup.path);
      await catalog.delete();
    }
    await temporary.rename(catalog.path);
  }

  static Future<List<DiscoverDownloadItem>> _readCatalog(
    Directory storage,
  ) async {
    final candidates = <File>[
      File(p.join(storage.path, 'downloads.json')),
      File(p.join(storage.path, 'downloads.json.tmp')),
      File(p.join(storage.path, 'downloads.json.bak')),
    ];
    for (final file in candidates) {
      if (!await file.exists()) continue;
      try {
        if (await file.length() > 4 * 1024 * 1024) continue;
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is! Map ||
            decoded['version'] != catalogVersion ||
            decoded['items'] is! List) {
          continue;
        }
        final items = <DiscoverDownloadItem>[];
        for (final value in (decoded['items'] as List).take(2000)) {
          if (value is! Map) continue;
          final item = DiscoverDownloadItem.fromJson(_stringKeyedMap(value));
          if (item.id.isNotEmpty) items.add(item);
        }
        // The primary catalog is the last committed transaction. A valid
        // temporary file is used only when a crash happened after removing the
        // old catalog and before the atomic rename; the backup is last resort.
        return items;
      } catch (_) {
        // Try the next atomic catalog candidate.
      }
    }
    return <DiscoverDownloadItem>[];
  }

  Future<List<DiscoverDownloadItem>> _reconcile(
    List<DiscoverDownloadItem> items,
  ) async {
    final seen = <String>{};
    final reconciled = <DiscoverDownloadItem>[];
    for (final item in items) {
      if (!_isSafeId(item.id)) continue;
      if (!seen.add(item.id)) continue;
      var next = item;
      if (!_isSafeFileName(next.fileName)) {
        final sourceUri =
            Uri.tryParse(next.sourceUrl) ??
            Uri.https('invalid.local', '/download');
        next = next.copyWith(
          fileName: _fileNameFor(
            id: next.id,
            requestedName: next.displayName,
            sourceUri: sourceUri,
            kind: next.kind,
            mimeType: next.mimeType,
          ),
        );
      }
      if (const <DiscoverDownloadStatus>{
        DiscoverDownloadStatus.queued,
        DiscoverDownloadStatus.downloading,
        DiscoverDownloadStatus.processing,
      }.contains(item.status)) {
        final recoveredFile = File(
          p.join(_requireStorage().path, next.fileName),
        );
        if (_isManagedPath(recoveredFile.path) &&
            await recoveredFile.exists() &&
            await recoveredFile.length() > 0) {
          final length = await recoveredFile.length();
          final mimeType = lookupMimeType(recoveredFile.path);
          next = next.copyWith(
            status: DiscoverDownloadStatus.completed,
            localPath: recoveredFile.path,
            mimeType: mimeType,
            kind: _kindForMimeOrPath(
              mimeType,
              recoveredFile.path,
              fallback: next.kind,
            ),
            receivedBytes: length,
            totalBytes: length,
            updatedAt: _clock().toUtc(),
            clearErrorMessage: true,
          );
        } else {
          next = next.copyWith(
            status: DiscoverDownloadStatus.failed,
            errorMessage:
                'The app closed before this download finished. Retry it.',
            updatedAt: _clock().toUtc(),
            clearLocalPath: true,
          );
        }
      } else if (next.status == DiscoverDownloadStatus.completed) {
        final path = next.localPath;
        if (path == null ||
            !_isManagedPath(path) ||
            !await File(path).exists() ||
            await File(path).length() == 0) {
          next = next.copyWith(
            status: DiscoverDownloadStatus.failed,
            errorMessage: 'The downloaded file is missing. Retry it.',
            updatedAt: _clock().toUtc(),
            clearLocalPath: true,
          );
        }
      } else if (next.localPath != null && !_isManagedPath(next.localPath!)) {
        next = next.copyWith(clearLocalPath: true);
      }
      reconciled.add(next);
    }
    return reconciled;
  }

  static Future<void> _cleanupParts(Directory storage) async {
    await for (final entity in storage.list(followLinks: false)) {
      if (entity is File && entity.path.endsWith('.part')) {
        await _deleteIfExists(entity);
      }
    }
  }

  Future<void> _deleteManagedPath(String path) async {
    if (_isManagedPath(path)) await _deleteIfExists(File(path));
  }

  bool _isManagedPath(String candidate) {
    final storage = _storageDirectory;
    if (storage == null) return false;
    final root = p.normalize(p.absolute(storage.path));
    final path = p.normalize(p.absolute(candidate));
    if (Platform.isWindows) {
      return p.isWithin(root.toLowerCase(), path.toLowerCase());
    }
    return p.isWithin(root, path);
  }

  Directory _requireStorage() {
    final value = _storageDirectory;
    if (value == null) throw StateError('Download manager is not initialized.');
    return value;
  }

  static Uri _validatedHttpsUri(String input) {
    final uri = Uri.tryParse(input.trim());
    if (uri == null ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const FormatException(
        'Only valid HTTPS download URLs are supported.',
      );
    }
    if (!uri.hasFragment) return uri;
    final normalized = uri.toString();
    return Uri.parse(normalized.substring(0, normalized.lastIndexOf('#')));
  }

  static String? _optionalHttpsUrl(String? input) {
    if (input == null || input.trim().isEmpty) return null;
    try {
      return _validatedHttpsUri(input).toString();
    } on FormatException {
      return null;
    }
  }

  static Map<String, String> _ephemeralHeaders(Map<String, String> headers) {
    const blocked = <String>{
      'host',
      'content-length',
      'transfer-encoding',
      'connection',
      'proxy-connection',
    };
    final safe = <String, String>{};
    for (final entry in headers.entries.take(32)) {
      final name = entry.key.trim();
      final value = entry.value.trim();
      if (name.isEmpty ||
          name.length > 100 ||
          value.length > 8192 ||
          name.contains(RegExp(r'[\r\n]')) ||
          value.contains(RegExp(r'[\r\n]')) ||
          blocked.contains(name.toLowerCase())) {
        continue;
      }
      safe[name] = value;
    }
    return Map<String, String>.unmodifiable(safe);
  }

  static String _fileNameFor({
    required String id,
    required String requestedName,
    required Uri sourceUri,
    required DiscoverMediaKind kind,
    String? mimeType,
    String? preferredExtension,
  }) {
    var name = _boundedDisplayName(requestedName)
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'[. ]+$'), '')
        .trim();
    if (name.isEmpty) name = 'download';
    if (name.length > 96) name = name.substring(0, 96).trimRight();
    final requestedExtension = p.extension(name);
    var extension = _safeExtension(requestedExtension);
    if (requestedExtension.isNotEmpty && extension == null) {
      name = name.substring(0, name.length - requestedExtension.length);
      if (name.isEmpty) name = 'download';
    }
    if (extension == null) {
      extension =
          _safeExtension(preferredExtension) ??
          _safeExtension(p.extension(sourceUri.path)) ??
          _extensionForMime(mimeType) ??
          switch (kind) {
            DiscoverMediaKind.image => 'jpg',
            DiscoverMediaKind.video => 'mp4',
            DiscoverMediaKind.audio => 'm4a',
            DiscoverMediaKind.unknown => 'bin',
          };
      name = '$name.$extension';
    }
    return '$id-$name';
  }

  static String? _safeExtension(String? value) {
    if (value == null) return null;
    final extension = value.replaceFirst(RegExp(r'^\.'), '').toLowerCase();
    const supported = <String>{
      'jpg',
      'jpeg',
      'png',
      'gif',
      'webp',
      'avif',
      'bmp',
      'svg',
      'mp4',
      'm4v',
      'mov',
      'webm',
      'mkv',
      'avi',
      '3gp',
      '3gpp',
      'mp3',
      'm4a',
      'aac',
      'wav',
      'ogg',
      'flac',
      'opus',
    };
    return supported.contains(extension) ? extension : null;
  }

  static String? _extensionForMime(String? mimeType) => switch (mimeType) {
    'image/jpeg' => 'jpg',
    'image/png' => 'png',
    'image/gif' => 'gif',
    'image/webp' => 'webp',
    'image/avif' => 'avif',
    'video/mp4' => 'mp4',
    'video/quicktime' => 'mov',
    'video/webm' => 'webm',
    'audio/mpeg' => 'mp3',
    'audio/mp4' => 'm4a',
    'audio/webm' => 'webm',
    'audio/ogg' => 'ogg',
    _ => null,
  };

  static Future<String?> _sniffMime(
    File file,
    String? responseMime,
    String sourceUrl,
  ) async {
    final random = await file.open();
    try {
      final header = await random.read(math.min(64, await file.length()));
      final leadingText = utf8
          .decode(header, allowMalformed: true)
          .trimLeft()
          .toLowerCase();
      if (leadingText.startsWith('<!doctype html') ||
          leadingText.startsWith('<html') ||
          leadingText.startsWith('<head') ||
          leadingText.startsWith('<body')) {
        return 'text/html';
      }
      return lookupMimeType('', headerBytes: header) ??
          _boundedMime(responseMime) ??
          lookupMimeType(Uri.parse(sourceUrl).path, headerBytes: header) ??
          lookupMimeType(file.path, headerBytes: header);
    } finally {
      await random.close();
    }
  }

  static void _validateDownloadedMime(String? mimeType, String sourceUrl) {
    final mime = mimeType?.toLowerCase();
    if (mime == 'text/html' || mime == 'application/xhtml+xml') {
      throw StateError(
        'The server returned a web page instead of a media file.',
      );
    }
    final path = Uri.parse(sourceUrl).path.toLowerCase();
    if (mime == 'application/vnd.apple.mpegurl' ||
        mime == 'application/x-mpegurl' ||
        path.endsWith('.m3u8') ||
        path.endsWith('.mpd')) {
      throw StateError('Streaming manifests are not direct media downloads.');
    }
    if (mime != null &&
        !mime.startsWith('image/') &&
        !mime.startsWith('video/') &&
        !mime.startsWith('audio/') &&
        !const <String>{
          'application/octet-stream',
          'binary/octet-stream',
          'application/mp4',
          'application/ogg',
          'application/x-matroska',
        }.contains(mime)) {
      throw StateError('The server response is not a supported media file.');
    }
  }

  static DiscoverMediaKind _kindForMimeOrPath(
    String? mimeType,
    String path, {
    required DiscoverMediaKind fallback,
  }) {
    final mime = mimeType?.toLowerCase() ?? '';
    if (mime.startsWith('image/')) return DiscoverMediaKind.image;
    if (mime.startsWith('video/')) return DiscoverMediaKind.video;
    if (mime.startsWith('audio/')) return DiscoverMediaKind.audio;
    if (mime == 'application/mp4' || mime == 'application/x-matroska') {
      return DiscoverMediaKind.video;
    }
    return fallback;
  }

  static String? _boundedMime(String? value) {
    if (value == null) return null;
    final mime = value.split(';').first.trim().toLowerCase();
    return mime.isNotEmpty && mime.length <= 200 ? mime : null;
  }

  static String _boundedDisplayName(String value) {
    final compact = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (compact.isEmpty) return 'Downloaded media';
    return compact.length <= 160
        ? compact
        : compact.substring(0, 160).trimRight();
  }

  static Map<String, dynamic> _jsonSafeMap(Map<String, dynamic> metadata) {
    try {
      final encoded = jsonEncode(metadata);
      if (encoded.length > 64 * 1024) return const <String, dynamic>{};
      final decoded = jsonDecode(encoded);
      return decoded is Map
          ? _stringKeyedMap(decoded)
          : const <String, dynamic>{};
    } catch (_) {
      return const <String, dynamic>{};
    }
  }

  static Map<String, dynamic> _stringKeyedMap(Map value) =>
      value.map((key, entry) => MapEntry(key.toString(), entry));

  static String _youtubeMime(YoutubeFormatOption format) {
    if (format.kind == YoutubeDownloadKind.audioOnly) {
      return format.container == 'webm' ? 'audio/webm' : 'audio/mp4';
    }
    return format.container == 'webm' ? 'video/webm' : 'video/mp4';
  }

  static List<DiscoverDownloadItem> _sortItems(
    Iterable<DiscoverDownloadItem> items,
  ) {
    final sorted = items.toList();
    sorted.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return sorted;
  }

  String _uniqueId() {
    for (var attempt = 0; attempt < 10; attempt++) {
      final value = _idGenerator().trim();
      if (_isSafeId(value) && _itemById(value) == null) return value;
    }
    return '${_clock().microsecondsSinceEpoch}-${_currentItems.length}';
  }

  static bool _isSafeId(String value) =>
      RegExp(r'^[A-Za-z0-9_-]{1,100}$').hasMatch(value);

  static bool _isSafeFileName(String value) {
    if (value.isEmpty || value.length > 220 || value.endsWith('.part')) {
      return false;
    }
    if (p.basename(value) != value || p.extension(value).isEmpty) return false;
    return !const <String>{
      'downloads.json',
      'downloads.json.tmp',
      'downloads.json.bak',
    }.contains(value.toLowerCase());
  }

  void _throwIfDirectCancelled(_DirectJobControl control, String id) {
    if (control.userCancelled ||
        _itemById(id)?.status == DiscoverDownloadStatus.cancelled) {
      throw StateError('Download was cancelled.');
    }
  }

  static String _friendlyError(Object error) {
    if (error is DioException) {
      if (error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.receiveTimeout ||
          error.type == DioExceptionType.sendTimeout) {
        return 'The download timed out. Check the connection and retry.';
      }
      final status = error.response?.statusCode;
      return status == null
          ? 'The media could not be downloaded. Check the connection and retry.'
          : 'The server rejected the download (HTTP $status).';
    }
    final message = error.toString().replaceFirst(
      RegExp(r'^\w+(?:Error|Exception):\s*'),
      '',
    );
    return message.length <= 300 ? message : '${message.substring(0, 297)}...';
  }

  static String _sizeLabel(int bytes) =>
      '${(bytes / (1024 * 1024)).round()} MB';

  static Future<void> _deleteIfExists(File file) async {
    if (await file.exists()) await file.delete();
  }

  static Future<bool> _openWithPlatform(String path) async {
    final result = await OpenFilex.open(path);
    return result.type == ResultType.done;
  }

  void _ensureNotDisposed() {
    if (_disposed) throw StateError('DiscoverDownloadManager is disposed.');
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final job in _directJobs.values) {
      job.userCancelled = true;
      job.cancelToken.cancel('Download manager disposed.');
    }
    for (final item in _currentItems) {
      if (item.source == DiscoverDownloadSource.youtube && !item.isTerminal) {
        unawaited(_youtubeService.cancel(item.id));
      }
    }
    _youtubeService.dispose();
    _lastProgressEmitMicros.clear();
    _progressClock.stop();
    unawaited(_itemsController.close());
  }
}

class _DirectJobControl {
  _DirectJobControl(this.cancelToken);

  final CancelToken cancelToken;
  bool userCancelled = false;
  bool exceededLimit = false;
}
