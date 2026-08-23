enum SoundEffectLibraryProvider { openverse }

/// License groupings exposed by the Openverse sound-effects search.
///
/// The initial integration deliberately excludes non-commercial,
/// no-derivatives, and share-alike licenses. This keeps exported projects
/// commercially usable without silently introducing incompatible terms.
enum OpenverseLicenseFilter { allUsable, publicDomain, attribution }

/// A provider-neutral online sound-effect result that can be previewed and
/// explicitly imported into an editor project.
class SoundEffectLibraryAsset {
  final String id;
  final String title;
  final String previewUrl;
  final String downloadUrl;
  final SoundEffectLibraryProvider provider;
  final Duration? duration;
  final int? fileSizeBytes;

  /// Lowercase extension without a leading dot.
  final String fileExtension;

  final String attribution;
  final String licenseCode;
  final String? licenseVersion;
  final String? licenseUrl;
  final String sourceName;
  final String? sourcePageUrl;
  final String? creatorName;
  final String? creatorPageUrl;
  final List<String> tags;
  final String? thumbnailUrl;
  final String? waveformUrl;

  const SoundEffectLibraryAsset({
    required this.id,
    required this.title,
    required this.previewUrl,
    required this.downloadUrl,
    required this.provider,
    required this.fileExtension,
    required this.attribution,
    required this.licenseCode,
    required this.sourceName,
    required this.tags,
    this.duration,
    this.fileSizeBytes,
    this.licenseVersion,
    this.licenseUrl,
    this.sourcePageUrl,
    this.creatorName,
    this.creatorPageUrl,
    this.thumbnailUrl,
    this.waveformUrl,
  });
}
