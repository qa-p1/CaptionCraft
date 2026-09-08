# YouTube and Instagram startup repair

Working branch: `release-readiness-desktop-workflows-20260907`.
Starting commit: `80187d797ebb375f3788c000b776391c0e8939b1`.

The downloaders already bundled yt-dlp, but their Android runtime could not
start. Inspection of the pinned Serious Python 0.9.5 implementation confirmed
that Android imports the entrypoint as a module, while `main.py` only started
its server under a `__main__` guard. The bridge then waited for a readiness file
that would never be written. Android's asynchronous launch future also completes
only when Python exits, so awaiting that future would deadlock startup once the
server was running.

The bridge now explicitly invokes the server, observes native errors, and waits
for readiness independently. A slow startup retries the same interpreter rather
than launching concurrent CPython instances. Windows launch acknowledgements
are handled separately from Android completion results.

The dependency archive now has a bundled hash checked on extraction. The small
transport entrypoint ships as a separate Flutter asset and is refreshed at startup,
so release upgrades cannot silently reuse its old cached code. yt-dlp and certifi
remain at their existing pinned versions; rebuilding the dependency archive also
regenerates its hash.

YouTube inspection uses yt-dlp first. Formats obtained from yt-dlp download
through it immediately, without first waiting for an unrelated legacy manifest
request. Existing saved legacy formats retain the older client/fallback route.
Disposing downloads also cancels their extractor jobs.

Instagram extraction remains delegated to yt-dlp. Media options retain the
extractor's CDN headers through persistence, initial downloads and retries.
The Python transport retains protocol metadata and sends keepalive events while
extracting. Transport inactivity and total operation deadlines are separate;
Instagram's outer deadline accommodates cold startup plus bounded extraction.

## Validation

- Python transport regressions and a real packaged-dependency startup check pass.
  The startup check imports the module the way Android does, explicitly starts
  the server, and exchanges a loopback request without contacting a media site.
- Added Dart regressions for the pending Android launch future, shared startup,
  retry after slow readiness, native errors, direct yt-dlp routing and persisted
  Instagram headers. Flutter analysis/tests are being run for this change.
- Live YouTube requests from this development environment were blocked by
  certificate/network timeouts; they do not establish on-device download success.
  Physical Android/iOS download checks remain necessary.

Upstream implementation checked:
[Android execution](https://github.com/flet-dev/serious-python/blob/v0.9.5/src/serious_python_android/lib/src/cpython.dart),
[archive extraction](https://github.com/flet-dev/serious-python/blob/v0.9.5/src/serious_python_platform_interface/lib/src/utils.dart).
