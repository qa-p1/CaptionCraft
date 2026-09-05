import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

typedef RemoteMediaDownloadProgress =
    void Function(int receivedBytes, int totalBytes);

/// Materializes a user-selected stock-library item into durable project media.
///
/// Search previews stay remote, but the original is downloaded only after the
/// user taps an item. This keeps video preview/export reliable and avoids
/// permanently hotlinking provider image URLs.
class RemoteMediaImportService {
  RemoteMediaImportService._();

  static const int maxDownloadBytes = 512 * 1024 * 1024;
  static final Map<String, Future<String>> _inFlightDownloads = {};

  static Future<String> download({
    required String url,
    required String provider,
    required String assetId,
    required bool isVideo,
    String? suggestedFileName,
    RemoteMediaDownloadProgress? onProgress,
    CancelToken? cancelToken,
    @visibleForTesting Directory? documentsDirectoryOverride,
    @visibleForTesting Dio? dioOverride,
  }) async {
    final uri = _validatedDownloadUri(url);

    final documents =
        documentsDirectoryOverride ?? await getApplicationDocumentsDirectory();
    final mediaDirectory = Directory(
      p.join(documents.path, 'CaptionCraft', 'media'),
    );
    await mediaDirectory.create(recursive: true);

    final extension = _safeExtension(
      suggestedFileName ?? uri.path,
      isVideo: isVideo,
    );
    final safeProvider = _safeSegment(provider, fallback: 'library');
    final safeId = _safeSegment(assetId, fallback: 'asset');
    final destination = File(
      p.join(mediaDirectory.path, '${safeProvider}_$safeId$extension'),
    );
    if (await destination.exists() && await destination.length() > 0) {
      return destination.path;
    }

    final activeDownload = _inFlightDownloads[destination.path];
    if (activeDownload != null) return activeDownload;
    final operation = _downloadToDestination(
      uri: uri,
      destination: destination,
      onProgress: onProgress,
      cancelToken: cancelToken,
      dioOverride: dioOverride,
    );
    _inFlightDownloads[destination.path] = operation;
    try {
      return await operation;
    } finally {
      if (identical(_inFlightDownloads[destination.path], operation)) {
        _inFlightDownloads.remove(destination.path);
      }
    }
  }

  static Future<String> _downloadToDestination({
    required Uri uri,
    required File destination,
    required RemoteMediaDownloadProgress? onProgress,
    required CancelToken? cancelToken,
    required Dio? dioOverride,
  }) async {
    final partial = File('${destination.path}.part');
    final effectiveCancelToken = cancelToken ?? CancelToken();
    var exceededLimit = false;
    final ownsDio = dioOverride == null;
    final dio =
        dioOverride ??
        Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 20),
            receiveTimeout: const Duration(minutes: 15),
          ),
        );
    try {
      final response = await dio.download(
        uri.toString(),
        partial.path,
        cancelToken: effectiveCancelToken,
        deleteOnError: true,
        options: Options(responseType: ResponseType.stream),
        onReceiveProgress: (received, total) {
          if (received > maxDownloadBytes || total > maxDownloadBytes) {
            exceededLimit = true;
            effectiveCancelToken.cancel('Media exceeds download limit.');
            return;
          }
          onProgress?.call(received, total);
        },
      );
      if (!_isAllowedDownloadUri(response.realUri)) {
        throw const RemoteMediaImportException(
          'The media provider redirected to an unsafe download URL.',
        );
      }
      final contentType = response.headers
          .value(Headers.contentTypeHeader)
          ?.toLowerCase();
      if (contentType != null &&
          (contentType.startsWith('text/') ||
              contentType.contains('html') ||
              contentType.contains('json') ||
              contentType.contains('xml'))) {
        throw const RemoteMediaImportException(
          'The media provider returned a web page instead of media.',
        );
      }
    } on RemoteMediaImportException {
      await _deleteIfPresent(partial);
      rethrow;
    } on DioException catch (error) {
      await _deleteIfPresent(partial);
      if (exceededLimit) {
        throw const RemoteMediaImportException(
          'This media exceeds the 512 MB download limit.',
        );
      }
      if (CancelToken.isCancel(error)) {
        throw const RemoteMediaImportException('Media download cancelled.');
      }
      throw RemoteMediaImportException(
        'Could not download this media: ${error.message ?? 'network error'}.',
      );
    } finally {
      if (ownsDio) dio.close(force: true);
      if (exceededLimit) {
        await _deleteIfPresent(partial);
      }
    }

    if (!await partial.exists()) {
      throw const RemoteMediaImportException('Media download did not finish.');
    }
    final length = await partial.length();
    if (length == 0 || length > maxDownloadBytes) {
      await partial.delete();
      throw const RemoteMediaImportException(
        'Downloaded media is empty or too large.',
      );
    }
    try {
      if (await destination.exists()) await destination.delete();
      await partial.rename(destination.path);
    } on FileSystemException catch (error) {
      await _deleteIfPresent(partial);
      throw RemoteMediaImportException(
        'Could not save this media: ${error.message}. Check available storage.',
      );
    }
    return destination.path;
  }

  static Uri _validatedDownloadUri(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null || !_isAllowedDownloadUri(uri)) {
      throw const RemoteMediaImportException('Media download URL is invalid.');
    }
    return uri;
  }

  static bool _isAllowedDownloadUri(Uri uri) {
    if (uri.host.isEmpty || uri.userInfo.isNotEmpty || uri.hasFragment) {
      return false;
    }
    final scheme = uri.scheme.toLowerCase();
    if (scheme == 'https') return true;
    final isLoopback = const {
      'localhost',
      '127.0.0.1',
      '::1',
    }.contains(uri.host.toLowerCase());
    return scheme == 'http' && isLoopback;
  }

  static Future<void> _deleteIfPresent(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Cleanup must not replace the actionable download or storage error.
    }
  }

  static String _safeExtension(String value, {required bool isVideo}) {
    final raw = p.extension(Uri.tryParse(value)?.path ?? value).toLowerCase();
    const videoExtensions = {'.mp4', '.mov', '.m4v'};
    const imageExtensions = {'.jpg', '.jpeg', '.png', '.webp', '.gif'};
    if (isVideo && videoExtensions.contains(raw)) return raw;
    if (!isVideo && imageExtensions.contains(raw)) return raw;
    return isVideo ? '.mp4' : '.jpg';
  }

  static String _safeSegment(String value, {required String fallback}) {
    var result = value
        .trim()
        .replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    if (result.length > 80) result = result.substring(0, 80);
    return result.isEmpty ? fallback : result;
  }
}

class RemoteMediaImportException implements Exception {
  final String message;

  const RemoteMediaImportException(this.message);

  @override
  String toString() => message;
}
