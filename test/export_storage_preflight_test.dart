import 'dart:io';

import 'package:caption_craft/core/utils/storage_capacity_service.dart';
import 'package:caption_craft/core/utils/timeline_export_service.dart';
import 'package:caption_craft/features/editor/models/export_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'export storage estimate grows with quality, duration, and downloads',
    () {
      const canvas = ExportCanvasSize(
        width: 1920,
        height: 1080,
        framesPerSecond: 30,
      );
      final compact = TimelineExportService.estimateStorageRequirements(
        canvasSize: canvas,
        duration: const Duration(minutes: 2),
        quality: ExportQuality.compact,
        includeAudio: false,
        networkAssetCount: 0,
      );
      final demanding = TimelineExportService.estimateStorageRequirements(
        canvasSize: canvas,
        duration: const Duration(minutes: 4),
        quality: ExportQuality.maximum,
        includeAudio: true,
        networkAssetCount: 3,
      );

      expect(demanding.outputBytes, greaterThan(compact.outputBytes));
      expect(demanding.workingBytes, greaterThan(compact.workingBytes));
      expect(
        demanding.combinedBytes,
        demanding.outputBytes + demanding.workingBytes,
      );
    },
  );

  test('disk-full errors are recognized on Unix and Windows', () {
    expect(
      StorageCapacityService.isDiskFull(
        const FileSystemException('write failed', '', OSError('full', 28)),
      ),
      isTrue,
    );
    expect(
      StorageCapacityService.isDiskFull(
        const FileSystemException('write failed', '', OSError('full', 112)),
      ),
      isTrue,
    );
    expect(
      StorageCapacityService.formatBytes(3 * 1024 * 1024 * 1024),
      '3.0 GB',
    );
  });
}
