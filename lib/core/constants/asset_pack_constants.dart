import 'package:flutter_dotenv/flutter_dotenv.dart';

class AssetPackConstants {
  AssetPackConstants._();

  static const _definedManifestUrl = String.fromEnvironment(
    'CAPTIONCRAFT_ASSET_MANIFEST_URL',
  );
  static const _definedBuildNumber = String.fromEnvironment(
    'FLUTTER_BUILD_NUMBER',
  );

  /// Public, credential-free JSON endpoint describing downloadable packs.
  ///
  /// This value is deliberately only read when a user requests a download.
  static String get manifestUrl {
    final defined = _definedManifestUrl.trim();
    if (defined.isNotEmpty) return defined;
    if (!dotenv.isInitialized) return '';
    return dotenv.env['CAPTIONCRAFT_ASSET_MANIFEST_URL']?.trim() ?? '';
  }

  static int get clientBuildNumber =>
      int.tryParse(_definedBuildNumber.trim()) ?? 0;

  static const String backgroundVideosId = 'background-videos';
  static const String overlaysId = 'overlays';
  static const String soundEffectsId = 'sound-effects';
  static const String lutsId = 'luts';

  /// Schema 1 is the original single-ZIP format. Schema 2 adds public release
  /// metadata and independently verifiable ZIP parts small enough for normal
  /// Cloudflare CDN caching tiers.
  static const int manifestSchemaVersion = 1;
  static const int latestManifestSchemaVersion = 2;
  static const Set<int> supportedManifestSchemaVersions = {1, 2};
  static const int catalogSchemaVersion = 3;

  static const int maxArchiveBytes = 5 * 1024 * 1024 * 1024;
  static const int maxArchivePartBytes = 480 * 1024 * 1024;
  static const int maxInstalledBytes = 8 * 1024 * 1024 * 1024;
  static const int maxArchiveEntries = 5000;
  static const int maxArchiveParts = 64;
  static const int maxManifestBytes = 1024 * 1024;
  static const int maxCatalogBytes = 16 * 1024 * 1024;
  static const int maxCatalogAssets = 10000;
  static const int maxCatalogCategories = 1000;
  static const int maxStringLength = 2048;
  static const int maxLutBytes = 64 * 1024 * 1024;
}
