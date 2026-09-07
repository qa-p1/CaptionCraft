# CaptionCraft

A local-first video editor for Android, iOS, and Windows. Cut a multi-track
timeline, create word-timed captions, add stock media and effects, and export
H.264/AAC video. Connect your own AI and media services only when needed.

[Release notes](docs/releases/v0.10.0.md) · [API setup](docs/connected-services.md) ·
[Report a bug](https://github.com/qa-p1/CaptionCraft/issues) · [GPL-3.0-or-later](LICENSE)

## Release status

**v0.10.0 / build 2006:** all three platform release workflows passed for
[ebec11b](https://github.com/qa-p1/CaptionCraft/commit/ebec11b9cc70f76c9a5c1a7c5a855b9dfb5e4dfd).
The binary release remains a draft pending verification of corresponding source
and build materials for its native FFmpeg dependencies. See the
[distribution checklist](docs/releases/v0.10.0.md#distribution-checklist).
Build success does not establish store approval or completed real-device QA.

| Platform | Artifact | Installation / limitations |
| --- | --- | --- |
| Android 7.0+ | Signed APKs: arm64-v8a, armeabi-v7a, x86_64 | ARM64 suits most current phones. The AAB is for Play Console, not direct installation. |
| Windows x64 | Portable ZIP | Extract completely; run caption_craft.exe beside its DLLs and data folder. Local projects/keys only; no cloud login. |
| iOS 15+ | **Unsigned** IPA | Requires Apple signing/provisioning. Not directly installable or an App Store/TestFlight release. |

Public assets will appear on the [Releases page](https://github.com/qa-p1/CaptionCraft/releases).
Windows is an unsigned portable application, not an installer. Clean Windows
10/11 testing, runtime prerequisites, and security-reputation checks remain.
Back up important projects/media before upgrading; do not uninstall merely to
bypass an Android signing-certificate mismatch.

## Features

- Multi-video timelines with audio, overlays, text, effects, transitions, and keyframes.
- Automatic or manual captions, per-cue styling, karaoke timing, and SRT/VTT import/export.
- Undo/redo, autosave, account-scoped local projects, and supported cloud sync.
- Canvas presets, work-area playback, preview, and H.264/AAC video export.
- Optional GIF/sticker, stock-media and licensed sound-effect libraries.
- Desktop keyboard controls and save-before-close handling.

## Get started

1. Open CaptionCraft. Sign in on Android/iOS; Windows opens in local desktop mode.
2. Choose **Set up services** or **Skip for now**.
3. Import local media, edit your timeline, add captions, and export.

Local import, editing, manual captions, and export require no API keys.
Return to **Settings → Connected services** from Home or Profile at any time.

| Optional service | Enables | Get a key |
| --- | --- | --- |
| Groq | Automatic captions | [Groq console](https://console.groq.com/keys) |
| GIPHY | GIFs and stickers | [Developer dashboard](https://developers.giphy.com/dashboard/) |
| Pexels | Stock photos and videos | [Pexels API](https://www.pexels.com/api/) |
| Pixabay | Stock images and videos | [Pixabay API](https://pixabay.com/api/docs/) |

Provider links open the native browser. Provider signup/approval may take longer
than the two-minute in-app setup; your provider's quotas and charges apply.
There is no .env file, embedded developer key, or transcription proxy to configure.

Keys are encrypted before cloud backup and remembered in device secure storage.
**Keep your recovery code:** another device may need it once to unlock the backup.
Windows keys stay on that PC only. See [setup, privacy and recovery](docs/connected-services.md).

## Desktop shortcuts

Press **Shift+/** (`?`) for in-app shortcut help. Editor shortcuts do not replace
normal typing in text fields.

| Action | Shortcut |
| --- | --- |
| Play / pause | Space |
| Step backward / pause / play forward | J / K / L |
| Step backward / forward | Left / Right |
| Previous / next edit point | Up / Down |
| Undo / redo | Ctrl+Z / Ctrl+Shift+Z or Ctrl+Y |
| Save / export / import | Ctrl+S / Ctrl+E / Ctrl+I |
| Split at playhead | Ctrl+B |
| Work-area in / out / clear | I / O / Alt+X |
| Toggle snapping / add marker / fullscreen | N / M / F |

J steps backward; it is not reverse shuttle playback. CaptionCraft does not
claim feature parity with professional desktop editors.

## Media and service limitations

- Instagram can deny anonymous access even to public posts/Reels. Private,
  removed, login-required, and rate-limited content is not guaranteed downloadable.
- Automatic captions send selected audio to Groq. Stock searches send the query
  and corresponding key to their provider.
- Background-video, overlay, LUT, and local SFX packs are separate optional downloads.
  Opening Elements fetches only the small public descriptor; media downloads
  start when requested. Packs may not yet be published.
- Selected stock items and LUTs are copied into durable project media. Sound
  effects retain source/license attribution; check licenses for your own use.
- Openverse sound search requires no API key. The inspected Fairlight sound
  library is not redistributed. Music remains a placeholder.

## Build from source

Use **Flutter 3.41.2**, the committed lockfile, and your platform's native toolchain:
Android SDK/JDK, macOS/Xcode for iOS, or Visual Studio C++ desktop tools for Windows.

```sh
git clone https://github.com/qa-p1/CaptionCraft.git
cd CaptionCraft
flutter pub get --enforce-lockfile
flutter run
```

```sh
flutter analyze
flutter test
flutter build apk --release --split-per-abi
flutter build windows --release
# On macOS:
flutter build ios --release --no-codesign
```

Android release signing requires your own `android/key.properties` and keystore;
missing signing configuration fails rather than using a debug key.
Windows native archive versions/hashes are pinned in the
[Windows workflow](.github/workflows/build-windows-release.yml).
For your own distribution, provision your Firebase project/client options and
deploy its owner-scoped Firestore rules. Never commit signing material or API keys.

## Documentation and contributing

- [v0.10.0 release notes and validation](docs/releases/v0.10.0.md)
- [Connected services and encrypted backups](docs/connected-services.md)
- [Editor architecture](docs/editor_architecture.md) and [roadmap](docs/editor_core_roadmap.md)
- [Effects, color and audio](docs/editor_effects_audio_status.md)
- [Asset-pack publishing](docs/asset-pack-deployment.md), [LUTs](docs/lut-pack.md), [sound effects](docs/sfx-library.md)
- [Historical release-readiness audit](docs/release-readiness-2026-08-31.md)

For bug reports, include app version, OS/device, reproduction steps and sanitized
logs. Never post API keys, recovery codes, signing files, or private media.
Keep changes focused and include regression tests. Contributions to
CaptionCraft-owned code are accepted under GPL-3.0-or-later.

## License

CaptionCraft-owned code is licensed under **GNU GPL version 3 or later**; see
[LICENSE](LICENSE). You may use, study, modify and redistribute it under those
terms. This license choice also covers CaptionCraft-owned code at the v0.10.0
build commit identified above.

Third-party components, fonts and imported media retain their original licenses;
see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Licensing the application
does not replace the corresponding-source obligations of its native libraries.
