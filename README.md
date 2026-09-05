# CaptionCraft

CaptionCraft is a local-first Flutter video editor for Android, iOS, and
Windows. It combines a multi-track timeline, word-timed captions, Creator Lab
tools, and an FFmpeg H.264/AAC export pipeline.

## Highlights

- Multi-video editing with overlays, text, audio, effects, transitions, and keyframes
- Automatic and manual captions with per-cue styling, karaoke timing, and SRT/VTT I/O
- Undo/redo, autosave, account-scoped local projects, and Firestore reconciliation
- Canvas presets, work-area playback, export preview, and gallery delivery

## Run locally

```sh
flutter pub get
flutter run
```

On first login, optionally connect Groq, GIPHY, Pexels and Pixabay in
**Settings → Connected services**. Each provider link opens in your device's
browser. Editing, manual captions and export work without keys. No .env file,
embedded developer API key, or transcription proxy is required.

Keys are encrypted with AES-256-GCM before cloud backup and cached in the
device's secure storage. Keep the recovery code in a password manager: another
device or reinstall needs it once to unlock the backup. CaptionCraft cannot
recover a lost code. Windows local mode stores keys on that PC only.
If the code is lost, Settings can replace the locked backup after confirmation;
you will need to enter your provider keys again. See [Connected services](docs/connected-services.md)
for setup, privacy, offline behavior and recovery details.

Firebase client options are tracked. Deploy the matching Firestore policy before
using cloud sync:

```sh
firebase deploy --only firestore:rules --project captioncraft-b1abb
```

## Verify and build

```sh
flutter analyze
flutter test
flutter build apk --release --split-per-abi
flutter build windows --release
```

Release builds require `android/key.properties` with `storeFile`,
`storePassword`, `keyAlias`, and `keyPassword`; they fail instead of silently
using a debug key.

## Editor engineering documentation

- [Editor architecture](docs/editor_architecture.md) — playback ownership,
  timeline scaling, animation, proxy/waveform caches, audio semantics,
  persistence, and undo boundaries.
- [Editor core roadmap](docs/editor_core_roadmap.md) — audited complete,
  partial, and outstanding timeline/editor requirements for the feature branch.
- [Effects, color, and audio status](docs/editor_effects_audio_status.md) —
  implemented delivery paths and explicit unsupported boundaries.
- [Release-readiness audit](docs/release-readiness-2026-08-31.md) — fixed
  failure modes, automated coverage, and real-device/store release gates.

## Optional Elements libraries

GIPHY, Pexels, and Pixabay search results are loaded only while their Elements
tab is active. A selected Pexels or Pixabay item is copied into durable project
media before it is placed on the timeline.

The CaptionCraft Background Videos, Overlays, and LUT packs are separate downloads;
their media is never included in the app bundle. Opening Elements checks local
state and fetches only the small public release descriptor. Media transfer
starts only after **Download pack** is tapped. Downloads belong to an app-scoped
queue, continue when the sheet is closed, resume verified partial data after a
Stop/network interruption, and can be stopped only with the visible **Stop
download** action. See `docs/asset-pack-deployment.md` for staging, Cloudflare
R2 publishing, checksum, multipart, and manifest instructions.

LUTs also have a dedicated **Effects → LUTs** section with a previewable pack,
custom CUBE/3DL import, strength control, and multi-clip application. Selected
looks are copied into durable project media before persistence. See
`docs/lut-pack.md` for the rights manifest, preparation tool, and release flow.

## Sound-effects library

SFX opens a separate resizable library backed by the anonymous Openverse audio
API. Searches run only when submitted and are restricted to the sound-effect
category plus CC0, Public Domain Mark, and CC BY licenses. A selected result is
downloaded into durable project media before timeline insertion, and its
creator, source, license, and attribution remain in the editor asset metadata.
The downloaded payload must pass an audio-stream probe before it is committed;
saved attribution can be copied later from Audio Clip Controls. No Openverse
credential is required or stored in the app.

The Local SFX destination uses the same manifest-driven installer as Background
Videos and Overlays. It remains visible before publication and offers a
refreshable “not published yet” state, so adding a rights-cleared
`sound-effects` row to the manifest enables it without another app build. The
inspected Fairlight-based folder cannot be redistributed by CaptionCraft; see
`docs/sfx-library.md`. Music remains a placeholder and is intentionally
unchanged.

## Distribution note

Users supply their own service credentials at runtime. No developer API keys
are embedded in binaries. Requests use the provider's HTTPS API; users manage
quotas, billing, and revocation in their provider accounts. The
FFmpeg package includes Full-GPL components, so satisfy its licensing and source
distribution requirements before publishing binaries.
