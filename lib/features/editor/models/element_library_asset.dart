enum ElementLibraryProvider { giphy, pexels, pixabay, captionCraft }

enum ElementLibraryMediaKind { image, video }

enum ElementLibraryAssetSubtype {
  photo,
  video,
  illustration,
  vector,
  gif,
  sticker,
}

/// A provider-neutral media result that can be presented or imported by the
/// editor's Elements library.
class ElementLibraryAsset {
  final String id;
  final String title;
  final String previewUrl;
  final String downloadUrl;
  final ElementLibraryProvider provider;
  final ElementLibraryMediaKind mediaKind;
  final ElementLibraryAssetSubtype subtype;
  final int? width;
  final int? height;
  final Duration? duration;
  final String attribution;
  final String? sourcePageUrl;
  final String? creatorId;
  final String? creatorName;
  final String? creatorPageUrl;

  const ElementLibraryAsset({
    required this.id,
    required this.title,
    required this.previewUrl,
    required this.downloadUrl,
    required this.provider,
    required this.mediaKind,
    required this.subtype,
    required this.attribution,
    this.width,
    this.height,
    this.duration,
    this.sourcePageUrl,
    this.creatorId,
    this.creatorName,
    this.creatorPageUrl,
  });
}
