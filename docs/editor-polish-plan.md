# Editor polish implementation plan

- Audio: keep source playback available while an audio-only fingerprint rebuilds in the background; bound preparation and invalidate stale jobs.
- Downloads: use a maintained package for Instagram extraction; harden YouTube client selection, stream deadlines, cancellation and progress.
- Navigation: replace More with focused dock categories with back navigation, preserve feature access, and keep Canvas in the top bar only.
- Captions: one CC entry; select existing source captions for styling, generate only when absent, retain caption cleanup and file tools.
- Motion: restore keyframe state/graph/easing controls and upgrade animation presets using shared preview/export behavior.
- Interaction: selected-layer gesture ownership, streamlined timeline navigation, consistently resizable sheets.
- Settings: Account & usage contains Connected services; concise service cards and clear save/backup controls.
- Validation: focused behavior regressions, Flutter analysis/test suite, UI smoke checks and platform build where available.

Existing README/release/license changes predate this work and are preserved.

## Implemented

- Visual-only changes no longer invalidate preview audio; live fallback stays available while bounded, supersedable audio rendering completes. The blocking preparation indicator is removed.
- Replaced Instagram scraping with bundled yt-dlp. YouTube refreshes stream manifests, bounds stalled operations, reports connection state honestly and uses the packaged fallback.
- Added focused dock categories/back navigation, keyframe state controls and curve presets, six animated motion recipes, one Canvas entry and one caption workflow. Existing source captions open track-specific styling.
- Selected layers own preview pinch/drag gestures. Removed skip/frame arrows from the preview row; the timeline toolbar exposes previous/next keyframes, clipboard, work area and view controls.
- Resizable sheets include formerly fixed audio, caption editing, animation channels, Discover, effect browsing and Creator Lab results.
- Connected services lives under Account & usage settings, with themed cards and a persistent secure-save action.
- Fixed video splitting mutating locked linked-audio tracks. Added regressions for this, caption routing/style isolation, gesture ownership, audio fingerprints, downloader fallback/cancellation/limits and sheet sizing.

See `media-runtime.md` for runtime packaging and live-check details. Validation output is retained locally under `.dart_tool/editor-polish-*.log`; review screenshots are under `build/ui-review/`.

## Final verification

- `flutter analyze --no-pub`: no issues.
- Full Flutter suite: 530 passed, 36 skipped, no failures.
- Python transport suite: 4 passed.
- Phone UI review: 8 smoke checks passed; screenshots inspected with bundled fonts.
- `flutter build apk --debug --no-pub`: successful. APK contains CPython libraries and site-package archives for all three Android ABIs, and its media-runtime asset matches the generated bundle.
- Live package checks: YouTube audio downloaded with progress; Instagram extraction and HTTP media transfer succeeded.
- On-device runtime verification remains unperformed: the installed emulator cannot boot because its hardware-acceleration driver is missing. No operating-system driver changes were made. iOS and Windows binaries were not verified in the final pass.
