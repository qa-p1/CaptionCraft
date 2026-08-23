# CaptionCraft

CaptionCraft is a local-first Flutter video editor for Android and iOS. It
combines a multi-track timeline, word-timed captions, Creator Lab tools, and an
FFmpeg H.264/AAC export pipeline.

## Highlights

- Multi-video editing with overlays, text, audio, effects, transitions, and keyframes
- Automatic and manual captions with per-cue styling, karaoke timing, and SRT/VTT I/O
- Undo/redo, autosave, account-scoped local projects, and Firestore reconciliation
- Canvas presets, work-area playback, export preview, and gallery delivery

## Run locally

```sh
cp .env.example .env
# Add GROQ_API_KEY, GIPHY_API_KEY, PEXELS_API_KEY, and PIXABAY_API_KEY.
# Set CAPTIONCRAFT_ASSET_MANIFEST_URL after publishing optional media packs.
flutter pub get
flutter run --dart-define-from-file=.env
```

Firebase client options are tracked. Deploy the matching Firestore policy before
using cloud sync:

```sh
firebase deploy --only firestore:rules
```

## Verify and build

```sh
flutter analyze
flutter test
flutter build apk --release --split-per-abi --dart-define-from-file=.env
```

Release builds require `android/key.properties` with `storeFile`,
`storePassword`, `keyAlias`, and `keyPassword`; they fail instead of silently
using a debug key.

## Optional Elements libraries

GIPHY, Pexels, and Pixabay search results are loaded only while their Elements
tab is active. A selected Pexels or Pixabay item is copied into durable project
media before it is placed on the timeline.

The CaptionCraft Background Videos and Overlays packs are separate downloads;
their media is never included in the app bundle. Opening Elements checks local
state and fetches only the small public release descriptor. Media transfer
starts only after **Download pack** is tapped. Downloads belong to an app-scoped
queue, continue when the sheet is closed, resume verified partial data after a
Stop/network interruption, and can be stopped only with the visible **Stop
download** action. See `docs/asset-pack-deployment.md` for staging, Cloudflare
R2 publishing, checksum, multipart, and manifest instructions.

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

Do not ship a Groq key in a public client: proxy transcription through an
authenticated backend with App Check and server-side quota enforcement. The
FFmpeg package includes Full-GPL components, so satisfy its licensing and source
distribution requirements before publishing binaries.
