# SFX library and redistribution gate

CaptionCraft supports a `sound-effects` asset pack through the same verified,
user-triggered installer used by Background Videos and Overlays. No SFX media
is bundled with the Flutter application. The Local SFX destination is always
present; before publication it shows a retryable manifest state rather than a
dead or build-flag-gated tab.

## Why the inspected folder is not a release source

The inspected source is `D:\Aadi\Editing assests\sfx`. Its included
`FairlightSoundLibraryLicense.txt` limits the Fairlight sounds to projects
created and finished in DaVinci Resolve and prohibits distributing or
sublicensing the raw sounds. The remaining MP3 files do not contain adequate
redistribution provenance; several retain YouTube/y2mate metadata.

Accordingly, CaptionCraft must not copy, archive, upload, or publish these
files. The source folder was inspected read-only and no SFX staging or ZIP was
created from it.

The read-only audit found 600 probeable audio effects across 30 non-music
categories (about 1.543 GiB and 151.7 minutes) after excluding Music, installer
payloads, and two visual-video files. The existing schema-v2 `db.json` is also
stale: it lists missing support files and has no durations, codecs, channel
counts, sample rates, or per-file license provenance. Even apart from the
license restriction, it is not suitable for direct runtime use.

## Rights-cleared replacement contract

When a replacement library with explicit redistribution rights is available,
rewrite only a copied staging catalog to `captioncraft-asset-pack` schema 3.
Do not consume its source database as-is. A valid release uses:

```json
{
  "schema": "captioncraft-asset-pack",
  "schemaVersion": 3,
  "pack": {
    "id": "sound-effects",
    "title": "Sound Effects",
    "version": "1.0.0"
  },
  "categories": [
    {"id": "interface", "name": "Interface"}
  ],
  "assets": [
    {
      "id": "interface-click-001",
      "title": "Interface click",
      "categoryId": "interface",
      "mediaType": "audio",
      "relativePath": "sounds/interface/interface-click-001.wav",
      "sizeBytes": 123456,
      "durationMs": 420,
      "hasAudio": true,
      "tags": ["interface", "click"],
      "metadata": {
        "mimeType": "audio/wav",
        "codec": "pcm_s16le",
        "sampleRate": 48000,
        "channels": 2,
        "license": "CC0-1.0",
        "licenseUrl": "https://creativecommons.org/publicdomain/zero/1.0/",
        "sourceUrl": "https://example.com/source",
        "redistributionCleared": true
      }
    }
  ]
}
```

Every entry must have a stable ID, normalized relative path, exact byte size,
positive duration, codec/sample-rate/channel metadata, flat search tags, and
explicit license/provenance. The runtime rejects audio entries unless every
required metadata field is present, both provenance links are valid web URLs,
and `redistributionCleared` is exactly `true`. This flag records the publisher's
clearance decision; it does not replace reviewing the actual license.
Reject entries without redistribution clearance.
Waveform previews are optional; audio files never require image previews.

Use `tool/prepare_sfx_pack.ps1` for that future release; it builds the catalog
from a separate, hash-bound clearance manifest and fresh media probes rather
than trusting a source `db.json`. See `docs/sfx-pack-preparation.md`.

Create cacheable immutable ZIP parts, add their exact sizes and SHA-256 release
row to the schema-v2 public asset-pack manifest, and upload every part before
publishing the manifest. No feature flag or app rebuild is required. Until a
rights-cleared `sound-effects` release is listed, the destination explains that
the pack has not been published and provides **Check again**.

## Online provider

The visible online source is Openverse. Searches run only after explicit user
submission, request the `sound_effect` category, and allow only CC0, Public
Domain Mark, or CC BY results. Selected sounds are downloaded into durable
CaptionCraft project media only after FFmpeg confirms a real audio stream and
positive duration; invalid payloads and partial downloads are removed. Source,
creator, license, and attribution data remain attached to the editor asset, and
the saved credit can be copied from Audio Clip Controls.

Do not add Freesound directly without a separate commercial API agreement and
a backend that protects its credentials. Pixabay has no documented audio API.
