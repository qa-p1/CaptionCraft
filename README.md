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
# Add GROQ_API_KEY and GIPHY_API_KEY to .env
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

## Distribution note

Do not ship a Groq key in a public client: proxy transcription through an
authenticated backend with App Check and server-side quota enforcement. The
FFmpeg package includes Full-GPL components, so satisfy its licensing and source
distribution requirements before publishing binaries.
