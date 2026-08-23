# Optional asset-pack deployment

CaptionCraft's background-video and overlay libraries are deployment artifacts, not Flutter assets. Never add `tool/asset_pack_staging`, `tool/asset_pack_dist`, or either source media directory to `pubspec.yaml`.

## Prepare a release

Requirements: PowerShell 7, `ffmpeg`, and `ffprobe` on `PATH`, plus enough free disk space for the source copies and archive parts.

From the repository root, run:

```powershell
pwsh -NoProfile -File .\tool\prepare_asset_packs.ps1
```

The tool deliberately stops if either generated target already exists. This prevents an accidental overwrite of a previous preparation run. Move or remove a previous generated run explicitly before starting another one.

The preparation process:

1. validates and SHA-256 hashes the read-only trees at `D:\Aadi\Editing assests\background` and `D:\Aadi\Editing assests\Overlays`;
2. copies both trees into the gitignored `tool/asset_pack_staging` directory and verifies the copies;
3. probes every media item, generates a JPG preview, and rewrites only the copied `db.json` files to CaptionCraft catalog schema version 3;
4. transcodes the guarded staging AVI overlay to H.264/yuv420p MP4;
5. writes independent, content-addressed ZIP parts below 450 MiB and a schema-v2 public manifest under the gitignored `tool/asset_pack_dist` directory; and
6. hashes the original trees again, including their last-write timestamps, to prove they were not modified.

The first part of each pack contains `db.json`; files are disjoint across parts.
`asset-pack-manifest.json` exposes safe UI metadata plus exact per-part hashes,
byte counts, extracted byte counts, and relative immutable URLs.
`preparation-report.json` records media counts and the before/after source-tree
verification.

## Publish

Upload only `asset-pack-manifest.json` and the referenced files beneath
`packs/`, without changing relative paths. Do not publish
`preparation-report.json`; it can contain local source paths. Each `parts[].url`
is relative to the public manifest and points to a versioned, hash-suffixed
object. Configure `CAPTIONCRAFT_ASSET_MANIFEST_URL` with the final public HTTPS
URL of `asset-pack-manifest.json`.

Use a public object-storage/CDN origin with byte-range requests and stable HTTPS
URLs. Cloudflare's normal Free/Pro/Business cache limit is 512 MB per object;
the generated sub-450 MiB parts stay cacheable while the old 0.7–1.0 GB
schema-v1 ZIPs bypass edge cache. Set the manifest to a short cache lifetime and
the content-addressed parts to `public, max-age=31536000, immutable`.

Keep `preparation-report.json` private if exposing local source paths is undesirable. The app needs only the manifest and the two paths beneath `packs/`.

### Recommended host: Cloudflare R2

Use an R2 Standard bucket behind a custom domain. R2 is a better match than
Cloudinary for these archives: its free allowance currently includes 10 GB-month
of storage and 10 million Class B reads per month, direct egress from R2 is
free, and its object limit is far above either pack. Cloudinary's Free plan caps
raw files at 10 MB, so it cannot hold these ZIPs. Check the current official
[R2 pricing](https://developers.cloudflare.com/r2/pricing/),
[R2 limits](https://developers.cloudflare.com/r2/platform/limits/), and
[Cloudinary plan limits](https://cloudinary.com/pricing/compare-plans/) before
publishing.

1. Create one private R2 bucket, then expose it through a production custom
   domain. Cloudflare documents `r2.dev` as a rate-limited development URL, so
   do not ship that hostname in release builds. See
   [public bucket delivery](https://developers.cloudflare.com/r2/buckets/public-buckets/).
2. If CaptionCraft is built for web, add a bucket CORS rule for the deployed web
   origin. Native Android/iOS HTTP is not browser-CORS constrained. A minimal
   rule is:

   ```json
   [
     {
       "AllowedOrigins": ["https://editor.example.com"],
       "AllowedMethods": ["GET", "HEAD"],
       "AllowedHeaders": ["Range", "If-Range"],
       "ExposeHeaders": ["ETag", "Last-Modified", "Content-Length", "Content-Range", "Accept-Ranges"],
       "MaxAgeSeconds": 86400
     }
   ]
   ```

   Replace the example origin and follow Cloudflare's current
   [R2 CORS guide](https://developers.cloudflare.com/r2/buckets/cors/).
3. Create an R2 API token with write access for this bucket. Keep its access key
   and secret only in your local publisher environment or CI secret store—never
   in Flutter, `.env.example`, the public manifest, or Firestore.
4. Upload the generated files while preserving their paths. With AWS CLI and
   R2's S3-compatible endpoint:

   ```powershell
   aws s3 cp .\tool\asset_pack_dist\packs "s3://YOUR_BUCKET/packs" `
     --recursive `
     --endpoint-url "https://YOUR_ACCOUNT_ID.r2.cloudflarestorage.com" `
     --cache-control "public,max-age=31536000,immutable"

   aws s3 cp .\tool\asset_pack_dist\asset-pack-manifest.json `
     "s3://YOUR_BUCKET/asset-pack-manifest.json" `
     --endpoint-url "https://YOUR_ACCOUNT_ID.r2.cloudflarestorage.com" `
     --cache-control "no-cache"
   ```

5. Open the custom-domain manifest URL and every resolved part URL, verify a
   `Range: bytes=0-0` request returns `206` plus `Content-Range`, then set
   only the public index URL in `.env`:

   ```dotenv
   CAPTIONCRAFT_ASSET_MANIFEST_URL=https://media.example.com/asset-pack-manifest.json
   ```

R2 bucket versioning is not currently available, so the generated immutable
version/hash paths are intentional. Publish all new parts first and the small
manifest last; never overwrite an object already referenced by a manifest.

The client supports legacy schema-v1 single ZIPs during migration, but new
releases should use schema 2. It keeps partial parts with their validator and
uses `Range`/`If-Range` on Retry, verifies every SHA-256 before extraction,
serializes large installs, and keeps older release directories because saved
timelines can still reference their paths. Do not add a Remove/prune operation
until selected pack media is copied into project-owned storage or references
are tracked.

Before making either pack public, confirm that every source file permits
redistribution. The source folders contain no retained license or creator
provenance, so technical preparation alone does not establish publishing
rights.

The optional SFX installer contract is documented separately in
`docs/sfx-library.md`. Do not add the inspected Fairlight-based SFX folder to
this deployment: its included license prohibits raw redistribution. A future
rights-cleared `sound-effects` pack may use the same manifest and R2 layout.
