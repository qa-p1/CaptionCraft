import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

typedef RemoteAudioDownloadProgress =
    void Function(int receivedBytes, int totalBytes);
typedef RemoteAudioFileValidator = Future<bool> Function(String path);

/// Downloads only a sound effect that the user explicitly selected.
class RemoteAudioImportService {
  RemoteAudioImportService._();

  static const int maxDownloadBytes = 128 * 1024 * 1024;
  static const Set<String> supportedExtensions = {
    '.mp3',
    '.wav',
    '.ogg',
    '.flac',
    '.m4a',
    '.aac',
  };

  static Future<String> download({
    required String url,
    required String provider,
    required String assetId,
    String? suggestedFileName,
    RemoteAudioDownloadProgress? onProgress,
    RemoteAudioFileValidator? validator,
    CancelToken? cancelToken,
    @visibleForTesting Directory? documentsDirectoryOverride,
    @visibleForTesting Dio? dioOverride,
  }) async {
    if (cancelToken?.isCancelled == true) {
      throw const RemoteAudioImportException(
        'Sound-effect download cancelled.',
      );
    }
    final uri = _validatedDownloadUri(url);
    final extension = _safeExtension(
      suggestedFileName: suggestedFileName,
      uri: uri,
    );
    final documents =
        documentsDirectoryOverride ?? await getApplicationDocumentsDirectory();
    final mediaDirectory = Directory(
      p.join(documents.path, 'CaptionCraft', 'media'),
    );
    await mediaDirectory.create(recursive: true);

    final safeProvider = _safeSegment(provider, fallback: 'library');
    final safeAssetId = _safeSegment(assetId, fallback: 'sound');
    final destination = File(
      p.join(mediaDirectory.path, '${safeProvider}_$safeAssetId$extension'),
    );
    if (!p.isWithin(mediaDirectory.path, destination.path)) {
      throw const RemoteAudioImportException(
        'The sound-effect destination is invalid.',
      );
    }

    if (await destination.exists()) {
      final cachedLength = await destination.length();
      if (cachedLength > 0 && cachedLength <= maxDownloadBytes) {
        if (validator == null ||
            await _validateAudioFile(destination, validator)) {
          onProgress?.call(cachedLength, cachedLength);
          return destination.path;
        }
      }
      await _deleteIfPresent(destination);
    }

    final partial = File('${destination.path}.part');
    await _deleteIfPresent(partial);
    final effectiveCancelToken = cancelToken ?? CancelToken();
    var exceededLimit = false;
    final ownsDio = dioOverride == null;
    final dio =
        dioOverride ??
        Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 20),
            receiveTimeout: const Duration(minutes: 10),
          ),
        );

    try {
      await dio.download(
        uri.toString(),
        partial.path,
        cancelToken: effectiveCancelToken,
        deleteOnError: true,
        options: Options(responseType: ResponseType.stream),
        onReceiveProgress: (received, total) {
          if (received > maxDownloadBytes || total > maxDownloadBytes) {
            exceededLimit = true;
            effectiveCancelToken.cancel('Sound effect exceeds download limit.');
            return;
          }
          onProgress?.call(received, total);
        },
      );
    } on DioException catch (error) {
      await _deleteIfPresent(partial);
      if (exceededLimit) {
        throw const RemoteAudioImportException(
          'This sound effect exceeds the 128 MB download limit.',
        );
      }
      if (CancelToken.isCancel(error)) {
        throw const RemoteAudioImportException(
          'Sound-effect download cancelled.',
        );
      }
      throw RemoteAudioImportException(
        'Could not download this sound effect: '
        '${error.message ?? 'network error'}.',
      );
    } on Object catch (error) {
      await _deleteIfPresent(partial);
      throw RemoteAudioImportException(
        'Could not download this sound effect: $error.',
      );
    } finally {
      if (ownsDio) dio.close(force: true);
      if (exceededLimit || effectiveCancelToken.isCancelled) {
        await _deleteIfPresent(partial);
      }
    }

    if (!await partial.exists()) {
      throw const RemoteAudioImportException(
        'Sound-effect download did not finish.',
      );
    }

    final length = await partial.length();
    if (length <= 0 || length > maxDownloadBytes) {
      await _deleteIfPresent(partial);
      throw const RemoteAudioImportException(
        'Downloaded sound effect is empty or too large.',
      );
    }
    if (validator != null && !await _validateAudioFile(partial, validator)) {
      await _deleteIfPresent(partial);
      throw const RemoteAudioImportException(
        'The downloaded file does not contain usable audio.',
      );
    }
    if (effectiveCancelToken.isCancelled) {
      await _deleteIfPresent(partial);
      throw const RemoteAudioImportException(
        'Sound-effect download cancelled.',
      );
    }

    try {
      if (await destination.exists()) await destination.delete();
      await partial.rename(destination.path);
    } on FileSystemException catch (error) {
      await _deleteIfPresent(partial);
      throw RemoteAudioImportException(
        'Could not save this sound effect: ${error.message}.',
      );
    }
    return destination.path;
  }

  static Uri _validatedDownloadUri(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null || uri.host.isEmpty) {
      throw const RemoteAudioImportException(
        'Sound-effect download URL is invalid.',
      );
    }
    final scheme = uri.scheme.toLowerCase();
    final isLoopbackHttp =
        scheme == 'http' &&
        const {
          'localhost',
          '127.0.0.1',
          '::1',
        }.contains(uri.host.toLowerCase());
    if (scheme != 'https' && !isLoopbackHttp) {
      throw const RemoteAudioImportException(
        'Sound-effect download URL must use HTTPS.',
      );
    }
    if (uri.userInfo.isNotEmpty) {
      throw const RemoteAudioImportException(
        'Sound-effect download URL is invalid.',
      );
    }
    return uri;
  }

  static String _safeExtension({
    required String? suggestedFileName,
    required Uri uri,
  }) {
    for (final candidate in [suggestedFileName, uri.path]) {
      if (candidate == null) continue;
      final raw = p.extension(Uri.tryParse(candidate)?.path ?? candidate);
      final normalized = raw.toLowerCase();
      if (supportedExtensions.contains(normalized)) return normalized;
    }
    throw const RemoteAudioImportException(
      'This sound-effect file type is not supported.',
    );
  }

  static String _safeSegment(String value, {required String fallback}) {
    var result = value
        .trim()
        .replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    if (result.length > 80) result = result.substring(0, 80);
    return result.isEmpty ? fallback : result;
  }

  static Future<void> _deleteIfPresent(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Cleanup must not obscure the useful download error.
    }
  }

  static Future<bool> _validateAudioFile(
    File file,
    RemoteAudioFileValidator validator,
  ) async {
    try {
      return await validator(file.path);
    } on Object catch (error) {
      await _deleteIfPresent(file);
      throw RemoteAudioImportException(
        'Could not validate this sound effect: $error.',
      );
    }
  }
}

class RemoteAudioImportException implements Exception {
  final String message;

  const RemoteAudioImportException(this.message);

  @override
  String toString() => message;
}
