# CaptionCraft

CaptionCraft is a local-first, multi-track video editor built with Flutter. It
combines a conventional timeline workflow with word-timed captions and a real
FFmpeg composition pipeline.

## Editing workflow

- Multi-video timeline with gaps, overlays, text, captions, and audio lanes
- Trim, split, ripple editing, snapping, markers, zoom, copy, paste, duplicate,
  track reorder, lock, hide, mute, solo, and editor-wide undo/redo
- Clip transforms, fit modes, opacity, layer order, playback speed, filters,
  color correction, fades, transitions, and clip animation
- Audio volume, stereo pan, normalization, mute, and fade controls
- Canvas presets for original, 16:9, 9:16, 1:1, and 4:5 with background,
  grids, safe areas, and guide snapping
- Automatic word-timed captions, manual editing, style overrides, karaoke
  timing, quality checks, overlap repair, find/replace, batch shifting,
  normalization, and SRT/VTT import/export
- H.264/AAC delivery with selectable resolution, frame rate, quality, audio,
  caption burn-in, gallery saving, output verification, and playback preview

## Creator Lab

Creator Lab adds 23 offline-first workflows directly inside the editor:

- 15 precision tools for line balancing, reading-speed timing, automatic
  splitting and merging, filler and echo cleanup, punctuation, frame snapping,
  empty and sound-cue cleanup, term masking, speaker labels, glossary
  enforcement, and collision-safe timing padding
- A pace heatmap and confidence review queue with jump-to-cue navigation
- Seven signature experiences: Viral Moment Radar, Magic Chapter Director,
  Kinetic Caption Director, B-roll Storyboard, Social Launch Pack, Karaoke Time
  Machine, and a mirrored full-screen Teleprompter Stage

Projects autosave locally and reconcile with Firestore when the signed-in
workspace is online. Original media and delivered files are not deleted when a
project is removed.

## Local setup

1. Install Flutter and an Android/iOS toolchain.
2. Copy `.env.example` to `.env`.
3. Add development API credentials.
4. Run:

```sh
flutter pub get
flutter run
```

`.env`, Firebase platform files, and release signing files are intentionally
ignored. Client-side API credentials can always be recovered from a distributed
app; production deployments should put paid transcription credentials behind an
authenticated server proxy.

For Android release signing, create `android/key.properties`:

```properties
storeFile=your-release-key.jks
storePassword=...
keyAlias=...
keyPassword=...
```

Without that local file, release builds use the debug key so development and CI
validation remain possible; do not publish that fallback build.

## Verification

```sh
flutter analyze
flutter test
flutter build apk --debug
flutter build apk --release
```

The test suite includes schema compatibility, editor history, subtitle
workflows, responsive UI/goldens, and a real FFmpeg integration render that
probes the delivered video, audio, duration, and dimensions.
