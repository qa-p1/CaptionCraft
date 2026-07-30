enum ExportResolution { original, p1080, p720, p480 }

enum ExportFrameRate { source, fps24, fps30, fps60 }

enum ExportQuality { compact, balanced, high, maximum }

class ExportSettings {
  final ExportResolution resolution;
  final ExportFrameRate frameRate;
  final ExportQuality quality;
  final bool includeAudio;
  final bool burnSubtitles;
  final bool saveToGallery;

  const ExportSettings({
    this.resolution = ExportResolution.original,
    this.frameRate = ExportFrameRate.source,
    this.quality = ExportQuality.high,
    this.includeAudio = true,
    this.burnSubtitles = true,
    this.saveToGallery = true,
  });

  int? get targetHeight {
    switch (resolution) {
      case ExportResolution.original:
        return null;
      case ExportResolution.p1080:
        return 1080;
      case ExportResolution.p720:
        return 720;
      case ExportResolution.p480:
        return 480;
    }
  }

  int? get targetFps {
    switch (frameRate) {
      case ExportFrameRate.source:
        return null;
      case ExportFrameRate.fps24:
        return 24;
      case ExportFrameRate.fps30:
        return 30;
      case ExportFrameRate.fps60:
        return 60;
    }
  }

  int get crf {
    switch (quality) {
      case ExportQuality.compact:
        return 28;
      case ExportQuality.balanced:
        return 23;
      case ExportQuality.high:
        return 19;
      case ExportQuality.maximum:
        return 16;
    }
  }

  String get preset {
    switch (quality) {
      case ExportQuality.compact:
        return 'veryfast';
      case ExportQuality.balanced:
        return 'fast';
      case ExportQuality.high:
        return 'medium';
      case ExportQuality.maximum:
        return 'slow';
    }
  }

  String get resolutionLabel {
    switch (resolution) {
      case ExportResolution.original:
        return 'Original';
      case ExportResolution.p1080:
        return '1080p';
      case ExportResolution.p720:
        return '720p';
      case ExportResolution.p480:
        return '480p';
    }
  }

  String get frameRateLabel {
    switch (frameRate) {
      case ExportFrameRate.source:
        return 'Source';
      case ExportFrameRate.fps24:
        return '24 fps';
      case ExportFrameRate.fps30:
        return '30 fps';
      case ExportFrameRate.fps60:
        return '60 fps';
    }
  }

  String get qualityLabel {
    switch (quality) {
      case ExportQuality.compact:
        return 'Compact';
      case ExportQuality.balanced:
        return 'Balanced';
      case ExportQuality.high:
        return 'High';
      case ExportQuality.maximum:
        return 'Maximum';
    }
  }

  ExportSettings copyWith({
    ExportResolution? resolution,
    ExportFrameRate? frameRate,
    ExportQuality? quality,
    bool? includeAudio,
    bool? burnSubtitles,
    bool? saveToGallery,
  }) {
    return ExportSettings(
      resolution: resolution ?? this.resolution,
      frameRate: frameRate ?? this.frameRate,
      quality: quality ?? this.quality,
      includeAudio: includeAudio ?? this.includeAudio,
      burnSubtitles: burnSubtitles ?? this.burnSubtitles,
      saveToGallery: saveToGallery ?? this.saveToGallery,
    );
  }
}
