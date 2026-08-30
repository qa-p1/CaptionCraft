# Preparing a rights-cleared SFX pack

`tool/prepare_sfx_pack.ps1` is the release tool for a future local
`sound-effects` library. It has no default source path and must never be run
against the inspected Fairlight/y2mate collection. The source catalog, if one
exists, is ignored; the tool builds CaptionCraft schema 3 from an explicit
clearance manifest and fresh `ffprobe` results.

## Clearance manifest

Every audio file under the supplied source root must appear exactly once. Each
entry binds the clearance decision to the file's SHA-256 and requires a
specific license, HTTPS license/source URLs, and the JSON boolean
`redistributionCleared: true`.

```json
{
  "schema": "captioncraft-sfx-clearance-manifest",
  "schemaVersion": 1,
  "pack": {
    "id": "sound-effects",
    "title": "Sound Effects"
  },
  "review": {
    "redistributionRightsConfirmed": true,
    "reviewedBy": "Rights reviewer name",
    "reviewedAtUtc": "2026-08-11T00:00:00Z"
  },
  "assets": [
    {
      "id": "interface-click-001",
      "title": "Interface Click",
      "categoryId": "interface",
      "categoryName": "Interface",
      "sourcePath": "Interface/click.wav",
      "expectedSha256": "replace-with-the-file-sha256",
      "license": "CC0-1.0",
      "licenseUrl": "https://creativecommons.org/publicdomain/zero/1.0/",
      "sourceUrl": "https://example.com/original-sound-page",
      "creator": "Creator name",
      "creatorUrl": "https://example.com/creator",
      "attribution": "Optional attribution text",
      "redistributionCleared": true,
      "tags": ["click", "ui"]
    }
  ]
}
```

IDs and category IDs must be stable lowercase kebab-case strings. `creator`,
`creatorUrl`, `attribution`, and `tags` are optional; all other fields shown are
required. A clearance flag is an auditable publisher decision, not a substitute
for actually reviewing the license.

## Validate without writing

PowerShell 7 and `ffprobe` must be on `PATH`.

```powershell
pwsh -NoProfile -File .\tool\prepare_sfx_pack.ps1 `
  -SourceRoot 'D:\Rights-cleared SFX' `
  -ClearanceManifest 'D:\Rights-cleared SFX clearance.json' `
  -Version '1.0.0' `
  -ValidateOnly
```

Validation rejects undeclared audio, hash mismatches, missing/placeholder
licenses, non-HTTPS provenance, links/reparse points, non-audio streams, and
Fairlight or y2mate markers in paths, declarations, or embedded audio metadata.
It probes duration, codec, sample rate, and channels, then hashes the source
again to verify that file bytes, sizes, paths, and last-write times did not
change. `-ValidateOnly` creates no output.

## Prepare an immutable release

After a clean validation, rerun without `-ValidateOnly`:

```powershell
pwsh -NoProfile -File .\tool\prepare_sfx_pack.ps1 `
  -SourceRoot 'D:\Rights-cleared SFX' `
  -ClearanceManifest 'D:\Rights-cleared SFX clearance.json' `
  -Version '1.0.0'
```

The tool copies only normalized audio into the gitignored
`tool/asset_pack_staging/sound-effects/<version>` directory. It writes a fresh
schema-v3 `db.json` with stable IDs, probes, exact sizes, license/provenance,
source and manifest hashes, and `redistributionCleared: true`. Originals are
never renamed, rewritten, or used as the runtime catalog.

The content-addressed ZIP parts and matching schema-v2 release JSON are written under the
gitignored `tool/asset_pack_dist/packs/sound-effects/<version>` directory. The
release JSON's `pack` object is ready to merge into the public
`asset-pack-manifest.json`. Every part stays below the configured Cloudflare
cache ceiling and has its own exact byte count and SHA-256. Existing version
output is never overwritten. After preparing it, add the SFX row independently:

```powershell
pwsh -NoProfile -File .\tool\compose_asset_pack_manifest.ps1 `
  -BaseManifest .\tool\asset_pack_dist\asset-pack-manifest.json `
  -SfxRelease .\tool\asset_pack_dist\packs\sound-effects\1.0.0\sound-effects-1.0.0-REPLACE.release.json `
  -OutputPath .\tool\asset_pack_dist\asset-pack-manifest.with-sfx.json
```

`-SfxRelease` and `-LutRelease` are independent. Supply both when both optional
packs are ready; an unpublished pack never blocks the other.

Run the isolated synthetic fixture with:

```powershell
pwsh -NoProfile -File .\tool\test_prepare_sfx_pack.ps1
pwsh -NoProfile -File .\tool\test_compose_asset_pack_manifest.ps1
```

The fixture uses a generated test tone and a disposable fake repository in the
operating-system temp directory. It validates both no-write mode and a complete
temporary catalog/ZIP/release, then removes the fixture. It does not read the
real SFX source or create output in CaptionCraft's staging directories.
