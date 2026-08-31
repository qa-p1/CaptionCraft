import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class StorageCapacityService {
  StorageCapacityService._();

  static const MethodChannel _channel = MethodChannel(
    'captioncraft/asset_pack_storage',
  );

  static Future<int?> availableBytes(Directory directory) async {
    try {
      final value = await _channel.invokeMethod<num>('availableBytes', {
        'path': directory.path,
      });
      return value?.toInt();
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    } on FlutterError {
      return null;
    }
  }

  static Future<void> requireAvailable({
    required Directory directory,
    required int requiredBytes,
    required String operation,
  }) async {
    final available = await availableBytes(directory);
    if (available == null || available >= requiredBytes) return;
    throw InsufficientStorageException(
      operation: operation,
      requiredBytes: requiredBytes,
      availableBytes: available,
    );
  }

  static bool isDiskFull(FileSystemException error) {
    final code = error.osError?.errorCode;
    return code == 28 || code == 112;
  }

  static String formatBytes(int bytes) {
    const gibibyte = 1024 * 1024 * 1024;
    const mebibyte = 1024 * 1024;
    if (bytes >= gibibyte) {
      return '${(bytes / gibibyte).toStringAsFixed(1)} GB';
    }
    return '${(bytes / mebibyte).toStringAsFixed(0)} MB';
  }
}

class InsufficientStorageException implements Exception {
  const InsufficientStorageException({
    required this.operation,
    required this.requiredBytes,
    required this.availableBytes,
  });

  final String operation;
  final int requiredBytes;
  final int availableBytes;

  @override
  String toString() {
    return '$operation needs about '
        '${StorageCapacityService.formatBytes(requiredBytes)} free, but only '
        '${StorageCapacityService.formatBytes(availableBytes)} is available. '
        'Free storage or choose a smaller export and try again.';
  }
}
