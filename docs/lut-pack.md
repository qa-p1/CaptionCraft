# LUT library and release preparation

CaptionCraft exposes LUTs as their own **Effects → LUTs** bottom-control
section. **Library** opens a dedicated offline pack with image previews;
**Import** accepts a local `.cube` or `.3dl`; **Strength** opens the shared
color controls; and **Clear** removes the look from every selected visual clip.

Pack and manual imports are copied into app-owned project media before their
paths are persisted. Applying one look to a multi-selection is one atomic
undo/redo transaction. Removing the downloaded pack later cannot break a saved
project that already uses one of its LUTs.

## Supported pack contract

The public pack ID is `luts`. Runtime catalog entries must:

- use catalog schema 3 and `mediaType: "lut"`;
- point to a non-empty `.cube` or `.3dl` file no larger than 64 MiB;
- include a unique image `previewPath`;
- omit duration/audio data and declare `hasAudio: false`; and
- belong to a declared category.

The installer verifies archive hashes, extracted sizes, catalog identity,
preview presence, file extension, and a recognizable LUT header before making
the release current. Common 17-, 33-, and 65-point CUBE files are accepted.

## Source manifest

`tool/prepare_lut_pack.ps1` never trusts a vendor database or modifies the
source pack. It requires a hash-bound source manifest with explicit
redistribution review for every LUT and for the image/video used to generate
previews.

```json
{
  "schema": "captioncraft-lut-source-manifest",
  "schemaVersion": 1,
  "pack": {"id": "luts", "title": "LUTs"},
  "review": {
    "redistributionRightsConfirmed": true,
    "reviewedBy": "Reviewer name",
    "reviewedAtUtc": "2026-08-29T00:00:00Z"
  },
  "preview": {
    "expectedSha256": "64-lowercase-or-uppercase-hex-characters",
    "license": "CC0-1.0",
    "licenseUrl": "https://creativecommons.org/publicdomain/zero/1.0/",
    "sourceUrl": "https://example.com/preview-source",
    "redistributionCleared": true
  },
  "assets": [
    {
      "id": "cinematic-film-001",
      "title": "Cinematic Film",
      "categoryId": "cinematic",
      "categoryName": "Cinematic",
      "sourcePath": "Cinematic/Cinematic Film.cube",
      "expectedSha256": "64-lowercase-or-uppercase-hex-characters",
      "license": "License identifier",
      "licenseUrl": "https://example.com/license",
      "sourceUrl": "https://example.com/original-lut-page",
      "creator": "Creator name",
      "attribution": "Optional attribution text",
      "redistributionCleared": true,
      "tags": ["film", "cinematic"]
    }
  ]
}
```

IDs and category IDs must be stable lowercase kebab-case. Every CUBE/3DL file
under `SourceRoot` must be declared exactly once and match its SHA-256. Public
license/source links must use HTTPS. A clearance flag records the publisher's
review; it is not a substitute for having redistribution rights.

## Validate and prepare

PowerShell 7 and `ffmpeg` must be on `PATH`.

```powershell
pwsh -NoProfile -File .\tool\prepare_lut_pack.ps1 `
  -SourceRoot 'D:\My rights-cleared LUT pack' `
  -PackManifest 'D:\My LUT pack manifest.json' `
  -PreviewSource 'D:\Preview source.jpg' `
  -Version '1.0.0' `
  -ValidateOnly
```

Validation checks paths, links/reparse points, hashes, metadata, headers, file
sizes, and actual FFmpeg `lut3d` parsing. It also re-hashes the source tree to
prove it was not changed. `-ValidateOnly` creates no staging or distribution
output.

After validation, rerun without `-ValidateOnly`. The tool generates a real
640×360 preview through each look, writes a schema-3 `db.json`, creates
content-addressed ZIP parts, and emits a schema-2 release descriptor beneath:

```text
tool/asset_pack_staging/luts/<version>/
tool/asset_pack_dist/packs/luts/<version>/
```

Existing version output is never overwritten. Test the complete workflow with:

```powershell
pwsh -NoProfile -File .\tool\test_prepare_lut_pack.ps1
```

## Compose and publish

Add the generated LUT release to the current background/overlay manifest:

```powershell
pwsh -NoProfile -File .\tool\compose_asset_pack_manifest.ps1 `
  -BaseManifest .\tool\asset_pack_dist\asset-pack-manifest.json `
  -LutRelease .\tool\asset_pack_dist\packs\luts\1.0.0\luts-1.0.0-REPLACE.release.json `
  -OutputPath .\tool\asset_pack_dist\asset-pack-manifest.with-luts.json
```

`-SfxRelease` and `-LutRelease` are independent optional additions, so an
unpublished SFX pack never blocks LUT deployment. Supply both to produce a
four-pack manifest. Upload immutable pack parts first and the composed manifest
last, following [Optional asset-pack deployment](asset-pack-deployment.md).
