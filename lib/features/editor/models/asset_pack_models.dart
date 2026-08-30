import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../../core/constants/asset_pack_constants.dart';

enum AssetPackMediaKind { image, video, audio, lut }

enum AssetPackProgressPhase {
  fetchingManifest,
  downloading,
  verifying,
  extracting,
  installing,
  complete,
}

class AssetPackProgress {
  final AssetPackProgressPhase phase;
  final int receivedBytes;
  final int totalBytes;
  final int partIndex;
  final int partCount;

  const AssetPackProgress({
    required this.phase,
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.partIndex = 0,
    this.partCount = 1,
  });

  double? get fraction {
    if (totalBytes <= 0) return null;
    return (receivedBytes / totalBytes).clamp(0, 1).toDouble();
  }
}

class AssetPackArchivePart {
  final String id;
  final Uri uri;
  final String sha256;
  final int bytes;

  const AssetPackArchivePart({
    required this.id,
    required this.uri,
    required this.sha256,
    required this.bytes,
  });
}

class AssetPackRelease {
  final String id;
  final String version;

  /// Legacy aliases retained for callers that still construct schema-1
  /// releases. For multipart releases these identify the first part and
  /// [sha256] is the deterministic release fingerprint.
  final Uri archiveUri;
  final String sha256;
  final int archiveBytes;
  final int installedBytes;
  final String catalogPath;
  final int catalogSchemaVersion;
  final int? minAppBuild;
  final int manifestSchemaVersion;
  final Uri? manifestUri;
  final String title;
  final String? description;
  final int? assetCount;
  final Uri? previewUri;
  final List<AssetPackArchivePart> parts;

  const AssetPackRelease({
    required this.id,
    required this.version,
    required this.archiveUri,
    required this.sha256,
    required this.archiveBytes,
    required this.installedBytes,
    required this.catalogPath,
    this.catalogSchemaVersion = AssetPackConstants.catalogSchemaVersion,
    this.minAppBuild,
    this.manifestSchemaVersion = 1,
    this.manifestUri,
    this.title = '',
    this.description,
    this.assetCount,
    this.previewUri,
    this.parts = const [],
  });

  List<AssetPackArchivePart> get archiveParts => parts.isNotEmpty
      ? parts
      : [
          AssetPackArchivePart(
            id: 'archive',
            uri: archiveUri,
            sha256: sha256,
            bytes: archiveBytes,
          ),
        ];

  String get fingerprint => parts.length <= 1
      ? sha256
      : _releaseFingerprint(
          id: id,
          version: version,
          catalogPath: catalogPath,
          parts: parts,
        );

  int get requiredTemporaryBytes => archiveBytes + installedBytes;

  factory AssetPackRelease.fromJson(
    Map<String, dynamic> json, {
    required Uri manifestUri,
    int manifestSchemaVersion = 1,
  }) {
    final id = _requiredString(json, 'id');
    final version = _requiredString(json, 'version');
    final installedBytes = _requiredPositiveInt(json, 'installedBytes');
    if (installedBytes > AssetPackConstants.maxInstalledBytes) {
      throw const FormatException('Asset pack exceeds the supported size.');
    }
    final catalogPath = normalizePackRelativePath(
      _requiredString(json, 'catalogPath'),
    );
    final catalogSchemaVersion = json.containsKey('catalogSchemaVersion')
        ? _requiredPositiveInt(json, 'catalogSchemaVersion')
        : AssetPackConstants.catalogSchemaVersion;
    if (catalogSchemaVersion != AssetPackConstants.catalogSchemaVersion) {
      throw const FormatException(
        'This pack requires an unsupported catalog format.',
      );
    }
    final minAppBuild = json.containsKey('minAppBuild')
        ? _requiredPositiveInt(json, 'minAppBuild')
        : null;
    final clientBuild = AssetPackConstants.clientBuildNumber;
    if (minAppBuild != null && clientBuild > 0 && clientBuild < minAppBuild) {
      throw const FormatException(
        'Update CaptionCraft before downloading this pack.',
      );
    }
    final title = _optionalString(json['title']) ?? _defaultPackTitle(id);
    final description = _optionalString(json['description']);
    final assetCount = json.containsKey('assetCount')
        ? _requiredPositiveInt(json, 'assetCount')
        : null;
    if (assetCount != null &&
        assetCount > AssetPackConstants.maxCatalogAssets) {
      throw const FormatException('Asset pack contains too many media items.');
    }
    final previewValue = _optionalString(json['previewUrl']);
    final previewUri = previewValue == null
        ? null
        : _resolvePublicAssetUri(
            manifestUri,
            previewValue,
            field: 'preview URL',
          );

    late final List<AssetPackArchivePart> parts;
    if (manifestSchemaVersion == 1) {
      final archiveUri = _resolvePublicAssetUri(
        manifestUri,
        _requiredString(json, 'archiveUrl'),
        field: 'archive URL',
      );
      final digest = _requiredSha256(json, 'sha256');
      final bytes = _requiredPositiveInt(json, 'archiveBytes');
      if (bytes > AssetPackConstants.maxArchiveBytes) {
        throw const FormatException('Asset pack exceeds the supported size.');
      }
      parts = [
        AssetPackArchivePart(
          id: 'archive',
          uri: archiveUri,
          sha256: digest,
          bytes: bytes,
        ),
      ];
    } else if (manifestSchemaVersion == 2) {
      final rawParts = json['parts'];
      if (rawParts is! List ||
          rawParts.isEmpty ||
          rawParts.length > AssetPackConstants.maxArchiveParts) {
        throw const FormatException(
          'Asset pack must declare a supported number of archive parts.',
        );
      }
      final partIds = <String>{};
      parts = <AssetPackArchivePart>[];
      for (final rawPart in rawParts) {
        if (rawPart is! Map<String, dynamic>) {
          throw const FormatException('Asset pack archive part is invalid.');
        }
        final partId = _requiredString(rawPart, 'id');
        if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(partId) ||
            !partIds.add(partId)) {
          throw const FormatException(
            'Asset pack archive part ID is invalid or duplicated.',
          );
        }
        final bytes = _requiredPositiveInt(rawPart, 'bytes');
        if (bytes > AssetPackConstants.maxArchivePartBytes) {
          throw const FormatException(
            'Asset pack archive part exceeds the supported size.',
          );
        }
        parts.add(
          AssetPackArchivePart(
            id: partId,
            uri: _resolvePublicAssetUri(
              manifestUri,
              _requiredString(rawPart, 'url'),
              field: 'archive part URL',
            ),
            sha256: _requiredSha256(rawPart, 'sha256'),
            bytes: bytes,
          ),
        );
      }
    } else {
      throw const FormatException('Public asset manifest is unsupported.');
    }

    final archiveBytes = parts.fold<int>(0, (sum, part) => sum + part.bytes);
    if (archiveBytes > AssetPackConstants.maxArchiveBytes) {
      throw const FormatException('Asset pack exceeds the supported size.');
    }
    final fingerprint = _releaseFingerprint(
      id: id,
      version: version,
      catalogPath: catalogPath,
      parts: parts,
    );
    return AssetPackRelease(
      id: id,
      version: version,
      archiveUri: parts.first.uri,
      sha256: parts.length == 1 ? parts.first.sha256 : fingerprint,
      archiveBytes: archiveBytes,
      installedBytes: installedBytes,
      catalogPath: catalogPath,
      catalogSchemaVersion: catalogSchemaVersion,
      minAppBuild: minAppBuild,
      manifestSchemaVersion: manifestSchemaVersion,
      manifestUri: manifestUri,
      title: title,
      description: description,
      assetCount: assetCount,
      previewUri: previewUri,
      parts: List.unmodifiable(parts),
    );
  }
}

class AssetPackCatalogItem {
  final String packId;
  final String packVersion;
  final String id;
  final String title;
  final String categoryId;
  final String categoryName;
  final AssetPackMediaKind mediaKind;
  final String relativePath;
  final String? previewRelativePath;
  final int sizeBytes;
  final int? width;
  final int? height;
  final Duration? duration;
  final bool hasAudio;
  final List<String> tags;
  final Map<String, dynamic> metadata;
  final Directory installationDirectory;

  const AssetPackCatalogItem({
    required this.packId,
    required this.packVersion,
    required this.id,
    required this.title,
    required this.categoryId,
    required this.categoryName,
    required this.mediaKind,
    required this.relativePath,
    required this.previewRelativePath,
    required this.sizeBytes,
    required this.width,
    required this.height,
    required this.duration,
    required this.hasAudio,
    required this.tags,
    required this.metadata,
    required this.installationDirectory,
  });

  String get localPath =>
      resolvePackRelativePath(installationDirectory, relativePath);

  String? get previewPath {
    final value = previewRelativePath;
    if (value == null) {
      return mediaKind == AssetPackMediaKind.image ? localPath : null;
    }
    return resolvePackRelativePath(installationDirectory, value);
  }
}

class AssetPackCatalog {
  final String id;
  final String title;
  final String version;
  final Directory installationDirectory;
  final List<AssetPackCatalogItem> items;
  final List<String> categoryIds;
  final Map<String, String> categoryNames;

  const AssetPackCatalog({
    required this.id,
    required this.title,
    required this.version,
    required this.installationDirectory,
    required this.items,
    required this.categoryIds,
    required this.categoryNames,
  });

  static Future<AssetPackCatalog> load({
    required String expectedPackId,
    required Directory installationDirectory,
    required String catalogPath,
    bool validateFiles = true,
  }) async {
    final resolvedCatalogPath = resolvePackRelativePath(
      installationDirectory,
      catalogPath,
    );
    final file = File(resolvedCatalogPath);
    if (!await file.exists()) {
      throw const FormatException('Downloaded pack is missing its catalog.');
    }
    if (await file.length() > AssetPackConstants.maxCatalogBytes) {
      throw const FormatException('Asset pack catalog is too large.');
    }
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Asset pack catalog must be a JSON object.');
    }
    if (decoded['schema'] != 'captioncraft-asset-pack' ||
        decoded['schemaVersion'] != AssetPackConstants.catalogSchemaVersion) {
      throw const FormatException('Asset pack catalog schema is unsupported.');
    }
    final pack = decoded['pack'];
    if (pack is! Map<String, dynamic>) {
      throw const FormatException('Asset pack catalog metadata is missing.');
    }
    final id = _requiredString(pack, 'id');
    if (id != expectedPackId) {
      throw const FormatException(
        'Downloaded catalog belongs to another pack.',
      );
    }
    final title = _requiredString(pack, 'title');
    final version = _requiredString(pack, 'version');

    final categoryNames = <String, String>{};
    final categoryIds = <String>[];
    final rawCategories = decoded['categories'];
    if (rawCategories is! List ||
        rawCategories.isEmpty ||
        rawCategories.length > AssetPackConstants.maxCatalogCategories) {
      throw const FormatException('Asset pack categories are invalid.');
    }
    for (final raw in rawCategories) {
      if (raw is! Map<String, dynamic>) {
        throw const FormatException('Asset pack contains an invalid category.');
      }
      final categoryId = _requiredString(raw, 'id');
      final categoryName = _requiredString(raw, 'name');
      if (categoryNames.containsKey(categoryId)) {
        throw FormatException('Duplicate asset pack category: $categoryId');
      }
      categoryIds.add(categoryId);
      categoryNames[categoryId] = categoryName;
    }

    final rawAssets = decoded['assets'];
    if (rawAssets is! List ||
        rawAssets.isEmpty ||
        rawAssets.length > AssetPackConstants.maxCatalogAssets) {
      throw const FormatException('Asset pack catalog has no media.');
    }
    final ids = <String>{};
    final referencedPaths = <String>{};
    final items = <AssetPackCatalogItem>[];
    for (final raw in rawAssets) {
      if (raw is! Map<String, dynamic>) {
        throw const FormatException('Asset pack contains an invalid item.');
      }
      final itemId = _requiredString(raw, 'id');
      if (!ids.add(itemId)) {
        throw FormatException('Duplicate asset pack item: $itemId');
      }
      final categoryId = _requiredString(raw, 'categoryId');
      final categoryName = categoryNames[categoryId];
      if (categoryName == null) {
        throw FormatException('Unknown asset category: $categoryId');
      }
      final kind = switch (_requiredString(raw, 'mediaType')) {
        'image' => AssetPackMediaKind.image,
        'video' => AssetPackMediaKind.video,
        'audio' => AssetPackMediaKind.audio,
        'lut' => AssetPackMediaKind.lut,
        _ => throw const FormatException('Unsupported pack media type.'),
      };
      final relativePath = normalizePackRelativePath(
        _requiredString(raw, 'relativePath'),
      );
      if (!referencedPaths.add(relativePath.toLowerCase())) {
        throw const FormatException('Asset pack media paths must be unique.');
      }
      final rawPreviewValue = raw['previewPath'];
      if (rawPreviewValue != null && rawPreviewValue is! String) {
        throw const FormatException(
          'Asset pack preview path must be a string.',
        );
      }
      final previewValue = (rawPreviewValue as String?)?.trim();
      final previewPath = previewValue == null || previewValue.isEmpty
          ? null
          : normalizePackRelativePath(previewValue);
      if (previewPath != null &&
          previewPath.toLowerCase() != relativePath.toLowerCase() &&
          !referencedPaths.add(previewPath.toLowerCase())) {
        throw const FormatException('Asset pack preview paths must be unique.');
      }
      final mediaFile = File(
        resolvePackRelativePath(installationDirectory, relativePath),
      );
      final sizeBytes = _requiredPositiveInt(raw, 'sizeBytes');
      if (validateFiles) {
        if (!await mediaFile.exists() ||
            await mediaFile.length() != sizeBytes) {
          throw FormatException('Pack media is missing or damaged: $itemId');
        }
        if (previewPath != null &&
            !await File(
              resolvePackRelativePath(installationDirectory, previewPath),
            ).exists()) {
          throw FormatException('Pack preview is missing: $itemId');
        }
      }
      final metadata = raw['metadata'] is Map<String, dynamic>
          ? Map<String, dynamic>.unmodifiable(
              raw['metadata'] as Map<String, dynamic>,
            )
          : const <String, dynamic>{};
      final duration = _optionalDuration(raw['durationMs']);
      final hasAudio = raw['hasAudio'] == true;
      if (kind == AssetPackMediaKind.audio && duration == null) {
        throw FormatException('Audio duration is missing or invalid: $itemId');
      }
      if (kind == AssetPackMediaKind.audio && !hasAudio) {
        throw FormatException('Audio item must declare hasAudio=true: $itemId');
      }
      if (kind == AssetPackMediaKind.audio) {
        _validateAudioMetadata(metadata, itemId);
      }
      if (kind == AssetPackMediaKind.lut) {
        final extension = p.extension(relativePath).toLowerCase();
        if (extension != '.cube' && extension != '.3dl') {
          throw FormatException('LUT has an unsupported file type: $itemId');
        }
        if (sizeBytes > AssetPackConstants.maxLutBytes) {
          throw FormatException('LUT file is too large: $itemId');
        }
        if (duration != null || hasAudio) {
          throw FormatException('LUT metadata is invalid: $itemId');
        }
        if (previewPath == null) {
          throw FormatException('LUT preview is required: $itemId');
        }
        if (validateFiles) {
          await validateLutFile(mediaFile.path, itemId: itemId);
        }
      }
      if (id == AssetPackConstants.soundEffectsId &&
          kind != AssetPackMediaKind.audio) {
        throw const FormatException(
          'The sound-effects pack may contain audio only.',
        );
      }
      if (id == AssetPackConstants.backgroundVideosId &&
          kind != AssetPackMediaKind.video) {
        throw const FormatException(
          'The background-videos pack may contain video only.',
        );
      }
      if (id == AssetPackConstants.overlaysId &&
          kind == AssetPackMediaKind.audio) {
        throw const FormatException(
          'The overlays pack may contain images and video only.',
        );
      }
      if (id == AssetPackConstants.lutsId && kind != AssetPackMediaKind.lut) {
        throw const FormatException('The LUT pack may contain LUT files only.');
      }
      items.add(
        AssetPackCatalogItem(
          packId: id,
          packVersion: version,
          id: itemId,
          title: _requiredString(raw, 'title'),
          categoryId: categoryId,
          categoryName: categoryName,
          mediaKind: kind,
          relativePath: relativePath,
          previewRelativePath: previewPath,
          sizeBytes: sizeBytes,
          width: _optionalPositiveInt(raw['width']),
          height: _optionalPositiveInt(raw['height']),
          duration: duration,
          hasAudio: hasAudio,
          tags: raw['tags'] is List
              ? List<String>.unmodifiable(
                  (raw['tags'] as List)
                      .whereType<String>()
                      .map((tag) => tag.trim())
                      .where((tag) => tag.isNotEmpty),
                )
              : const [],
          metadata: metadata,
          installationDirectory: installationDirectory,
        ),
      );
    }

    return AssetPackCatalog(
      id: id,
      title: title,
      version: version,
      installationDirectory: installationDirectory,
      items: List.unmodifiable(items),
      categoryIds: List.unmodifiable(categoryIds),
      categoryNames: Map.unmodifiable(categoryNames),
    );
  }
}

String normalizePackRelativePath(String value) {
  final normalizedInput = value.trim().replaceAll('\\', '/');
  if (normalizedInput.isEmpty ||
      normalizedInput.startsWith('/') ||
      RegExp(r'^[A-Za-z]:').hasMatch(normalizedInput)) {
    throw const FormatException('Asset pack path must be relative.');
  }
  final normalized = p.posix.normalize(normalizedInput);
  if (normalized == '.' ||
      normalized == '..' ||
      normalized.startsWith('../') ||
      normalized.split('/').contains('..')) {
    throw const FormatException('Asset pack path escapes its install folder.');
  }
  return normalized;
}

String resolvePackRelativePath(Directory root, String relativePath) {
  final normalized = normalizePackRelativePath(relativePath);
  final resolved = p.normalize(
    p.absolute(p.joinAll([root.path, ...normalized.split('/')])),
  );
  final rootPath = p.normalize(p.absolute(root.path));
  if (!p.isWithin(rootPath, resolved)) {
    throw const FormatException('Asset pack path escapes its install folder.');
  }
  return resolved;
}

String _requiredString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('Missing required asset pack field: $key');
  }
  final normalized = value.trim();
  if (normalized.length > AssetPackConstants.maxStringLength) {
    throw FormatException('Asset pack field is too long: $key');
  }
  return normalized;
}

String? _optionalString(dynamic value) {
  if (value == null) return null;
  if (value is! String) {
    throw const FormatException('Optional asset pack text must be a string.');
  }
  final normalized = value.trim();
  if (normalized.isEmpty) return null;
  if (normalized.length > AssetPackConstants.maxStringLength) {
    throw const FormatException('Optional asset pack text is too long.');
  }
  return normalized;
}

String _requiredSha256(Map<String, dynamic> json, String key) {
  final value = _requiredString(json, key).toLowerCase();
  if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(value)) {
    throw const FormatException('Asset pack SHA-256 is invalid.');
  }
  return value;
}

int _requiredPositiveInt(Map<String, dynamic> json, String key) {
  final value = _optionalPositiveInt(json[key]);
  if (value == null) {
    throw FormatException('Invalid asset pack number: $key');
  }
  return value;
}

int? _optionalPositiveInt(dynamic value) {
  if (value is int && value > 0) return value;
  return null;
}

Duration? _optionalDuration(dynamic value) {
  final milliseconds = _optionalPositiveInt(value);
  return milliseconds == null ? null : Duration(milliseconds: milliseconds);
}

void _validateAudioMetadata(Map<String, dynamic> metadata, String itemId) {
  String requiredString(String key) {
    final value = metadata[key];
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('Audio metadata is missing $key: $itemId');
    }
    return value.trim();
  }

  final mimeType = requiredString('mimeType').toLowerCase();
  if (!mimeType.startsWith('audio/')) {
    throw FormatException('Audio metadata has an invalid mimeType: $itemId');
  }
  requiredString('codec');
  if (_optionalPositiveInt(metadata['sampleRate']) == null) {
    throw FormatException('Audio metadata has an invalid sampleRate: $itemId');
  }
  if (_optionalPositiveInt(metadata['channels']) == null) {
    throw FormatException('Audio metadata has invalid channels: $itemId');
  }
  requiredString('license');
  for (final key in const ['licenseUrl', 'sourceUrl']) {
    final value = requiredString(key);
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.host.isEmpty ||
        uri.scheme.toLowerCase() != 'https') {
      throw FormatException('Audio metadata has an invalid $key: $itemId');
    }
  }
  if (metadata['redistributionCleared'] != true) {
    throw FormatException(
      'Audio metadata must declare redistributionCleared=true: $itemId',
    );
  }
}

String _defaultPackTitle(String id) => switch (id) {
  AssetPackConstants.backgroundVideosId => 'Background Videos',
  AssetPackConstants.overlaysId => 'Overlays',
  AssetPackConstants.soundEffectsId => 'Sound Effects',
  AssetPackConstants.lutsId => 'LUTs',
  _ => id,
};

Future<void> validateLutFile(String filePath, {String itemId = 'LUT'}) async {
  final file = File(filePath);
  final extension = p.extension(file.path).toLowerCase();
  if (extension != '.cube' && extension != '.3dl') {
    throw FormatException('LUT has an unsupported file type: $itemId');
  }
  final length = await file.length();
  if (length <= 0 || length > AssetPackConstants.maxLutBytes) {
    throw FormatException('LUT file size is invalid: $itemId');
  }
  final valid = extension == '.cube'
      ? await _hasValidCubeStructure(file)
      : await _hasValid3dlHeader(file, length);
  if (!valid) {
    throw FormatException('LUT file is malformed: $itemId');
  }
}

Future<bool> _hasValidCubeStructure(File file) async {
  final sizePattern = RegExp(r'^LUT_(1D|3D)_SIZE\s+(\d+)\s*$');
  final number = r'[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?';
  final dataPattern = RegExp(
    '^$number\\s+$number\\s+$number\\s*'
    r'$',
  );
  String? dimension;
  int? size;
  var dataRows = 0;
  await for (final rawLine
      in file
          .openRead()
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())) {
    final comment = rawLine.indexOf('#');
    final line = (comment < 0 ? rawLine : rawLine.substring(0, comment)).trim();
    if (line.isEmpty) continue;
    final sizeMatch = sizePattern.firstMatch(line);
    if (sizeMatch != null) {
      if (size != null) return false;
      dimension = sizeMatch.group(1);
      size = int.tryParse(sizeMatch.group(2)!);
      continue;
    }
    if (dataPattern.hasMatch(line)) dataRows++;
  }
  if (size == null || size < 2) return false;
  if (dimension == '3D' && size > 256) return false;
  if (dimension == '1D' && size > 65536) return false;
  final expectedRows = dimension == '3D' ? size * size * size : size;
  return dataRows == expectedRows;
}

Future<bool> _hasValid3dlHeader(File file, int length) async {
  final handle = await file.open();
  try {
    final prefix = utf8.decode(
      await handle.read(math.min(length, 256 * 1024)),
      allowMalformed: true,
    );
    return const LineSplitter()
        .convert(prefix)
        .map((line) => line.trim())
        .any((line) => RegExp(r'^\d+(?:\s+\d+){3,}$').hasMatch(line));
  } finally {
    await handle.close();
  }
}

Uri _resolvePublicAssetUri(
  Uri manifestUri,
  String value, {
  required String field,
}) {
  final resolved = manifestUri.resolve(value);
  if (!_isSafePublicUri(resolved) || !_sameOrigin(manifestUri, resolved)) {
    throw FormatException('Asset pack $field is invalid or cross-origin.');
  }
  return resolved;
}

bool _isSafePublicUri(Uri uri) {
  if (uri.host.isEmpty || uri.userInfo.isNotEmpty || uri.hasFragment) {
    return false;
  }
  if (uri.scheme.toLowerCase() == 'https') return true;
  return uri.scheme.toLowerCase() == 'http' && _isLoopbackHost(uri.host);
}

bool _isLoopbackHost(String host) {
  final normalized = host.toLowerCase();
  return normalized == 'localhost' ||
      normalized == '127.0.0.1' ||
      normalized == '::1';
}

bool _sameOrigin(Uri left, Uri right) {
  int effectivePort(Uri uri) {
    if (uri.hasPort) return uri.port;
    return uri.scheme.toLowerCase() == 'https' ? 443 : 80;
  }

  return left.scheme.toLowerCase() == right.scheme.toLowerCase() &&
      left.host.toLowerCase() == right.host.toLowerCase() &&
      effectivePort(left) == effectivePort(right);
}

String _releaseFingerprint({
  required String id,
  required String version,
  required String catalogPath,
  required List<AssetPackArchivePart> parts,
}) {
  if (parts.length == 1) return parts.single.sha256;
  final canonical = jsonEncode({
    'id': id,
    'version': version,
    'catalogPath': catalogPath,
    'parts': [
      for (final part in parts)
        {'id': part.id, 'sha256': part.sha256, 'bytes': part.bytes},
    ],
  });
  return sha256.convert(utf8.encode(canonical)).toString();
}
