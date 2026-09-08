# Embedded media downloader

Instagram extraction uses the maintained [yt-dlp package](https://github.com/yt-dlp/yt-dlp). YouTube uses yt-dlp first; youtube_explode_dart remains a fallback for inspection and previously saved legacy formats. Website parsing belongs to those packages.

`assets/media_runtime.zip` contains `tools/media_runtime/main.py`, yt-dlp 2026.8.19 and certifi 2026.7.22, including their wheel license metadata. [Serious Python](https://github.com/flet-dev/serious-python) embeds CPython in the application. End users do not install Python or configure a server.

Rebuild the pinned asset from the repository root:

```sh
python tools/build_media_runtime.py
```

Only pure Python wheels enter the asset. Native CPython libraries are supplied by the platform plugin during the normal Flutter build. Android's Gradle wrappers and the iOS Podfile provide the plugin's site-packages location; the small per-platform marker packages keep the plugin archives valid while application dependencies load from the shared Flutter asset. Android extracts native libraries and builds the Python bridge with NDK 28.2.13676358. In Android Studio builds that bypass the Gradle wrapper, set `SERIOUS_PYTHON_SITE_PACKAGES` to the absolute `tools/media_runtime/site-packages` directory.

The bridge starts lazily on loopback with an ephemeral port and a session token. Requests only support Instagram and YouTube HTTPS URLs. Transfers send byte progress, have inactivity deadlines, enforce size limits, use isolated operation IDs, and signal cancellation to the worker. YouTube split streams are combined with the existing FFmpeg service. Instagram prefers the progressive video supplied by yt-dlp so an adaptive video-only representation does not silently discard audio.

Startup fixes and verification are recorded in [Downloader startup repair](downloader-startup-fix.md).

Run transport and service regressions:

```sh
python -m unittest tools/test_media_runtime.py
flutter test test/yt_dlp_bridge_test.dart test/instagram_download_service_test.dart test/youtube_download_service_test.dart
```

Live checks during this change successfully inspected Instagram Reel `Chunk8-jurw`, read media bytes with HTTP 200, and downloaded YouTube `jNQXAC9IVRw` audio with byte progress. These checks used the packaged Python dependencies on the development machine. They do not substitute for an on-device test of the native Flutter bridge. Site removals, private posts, login requirements and rate limits still produce explicit errors.
