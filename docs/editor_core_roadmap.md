# Editor core and timeline roadmap

This roadmap focuses on long, multi-layer projects and predictable editing.
The status below was audited against the implementation and tests on
`editor-heavy-project-foundation`; a checked parent is used only when the whole
requirement is implemented. Partially complete requirements remain unchecked
and expose their implemented and outstanding pieces underneath.

See [Editor architecture](editor_architecture.md) for state ownership,
preview/export semantics, caching, and known limitations.

## Milestone 1 — playback and animation foundation

1. [x] Use one monotonic composition clock instead of decoder callbacks as the playhead.
2. [x] Add media-specific drift thresholds and correction cooldowns.
3. [x] Stop hard-seek storms on audible media during normal playback.
4. [x] Keep explicit paused scrubbing and discontinuous seeks frame-accurate.
5. [x] Never change playback speed to conceal ordinary clock drift.
6. [x] Warm a bounded number of upcoming audio decoders before clip boundaries.
7. [x] Warm the next base-video decoder and hand it off at the cut.
8. [x] Keep inactive warm decoders paused and silent.
9. [x] Persist hold, linear, ease-in, ease-out, ease-in-out, and cubic Bézier interpolation.
10. [x] Preserve legacy projects by defaulting old keyframes to linear.
11. [x] Use the model curve evaluator in preview and sampled FFmpeg export expressions.
12. [x] Add a graph editor with draggable keys, tangent handles, 15 timing presets, custom Bézier curves, panning, and zoom.
13. [x] Make graph drags a single undo transaction instead of one undo step per pointer update.
14. [ ] Add device-level playback stress fixtures for long-GOP 4K/60 media and overlapping audio.
    - [x] Cover thirty simultaneous visual layers and thirty overlapping audio voices with deterministic automated stress fixtures.
    - [x] Bound dense visual preview composition and audio-bus decoder demand in tests.
    - [ ] Validate long-GOP 4K/60 playback and thermal/memory behavior on a physical iOS device.

## Milestone 2 — heavy-project timeline interaction

15. [x] Complete heavy-project timeline indexing and virtualization.
    - [x] Resolve active preview clips and overlapping captions with interval indexes and bounded warm-window queries.
    - [x] Horizontally virtualize off-screen clips, thumbnails, waveforms, keyframe lanes, transitions, and markers.
    - [x] Virtualize vertically off-screen track lanes and labels while pinning active gestures.
16. [ ] Separate live gesture state from committed render state to avoid full preview rebuilds.
    - [x] Use edit revisions to freeze expensive audio/composite invalidation during continuous gestures.
    - [x] Commit one render revision and one undo transaction when the gesture ends.
    - [ ] Isolate every remaining provider/widget rebuild from live inspector and transform updates.
17. [x] Add proxy media generation, relinking, and preview-quality controls.
    - [x] Generate genuine per-source H.264/AAC proxies with deterministic source/profile fingerprints.
    - [x] Persist Auto, Proxy, and Original preview quality with backwards-compatible defaults.
    - [x] Validate persisted proxies after source relinking and keep an offline-original project previewable when a valid proxy exists.
    - [x] Cancel/discard stale jobs and bound proxy cache entry count and total bytes.
    - [x] Always resolve original media for final export.
18. [x] Cache waveforms by source fingerprint and source window.
    - [x] Include source version, source window, audio stream, and render density in cache identity.
    - [x] Deduplicate concurrent work, serialize FFmpeg jobs, support cancellation, and prune by entry/byte limits.
19. [x] Add missed-tick, buffering, decoder-count, clock-drift, and correction diagnostics.
20. [x] Add zoom-to-playhead, zoom-to-selection, and exact frame navigation.
    - [x] Keep zoom anchored deterministically and calculate frame boundaries from absolute rational frame numbers without accumulated millisecond drift.
21. [x] Add configurable snapping.
    - [x] Configure frames, playhead, clip edges, markers, beat markers, keyframes, selection boundaries, and work-area boundaries independently.
    - [x] Query an immutable sorted index instead of scanning the full project during pointer updates.
22. [ ] Implement ripple, roll, slip, and slide trim tools.
    - [x] Preserve source bounds and animation curves for ordinary start/end trim, split, and playback-rate retiming.
    - [x] Keep existing ripple delete and linked source-window behavior.
    - [ ] Add a dedicated ripple-trim gesture/tool.
    - [ ] Add roll edit.
    - [ ] Add slip edit.
    - [ ] Add slide edit.
23. [ ] Add linked selection, grouping, track targeting, and sync-lock controls.
    - [x] Support primary/multi-selection, linked clip timing, and locked-track guards.
    - [ ] Persist group identity and apply move, duplicate, and delete to groups.
    - [ ] Add explicit track targeting.
    - [ ] Add sync lock independently from track lock.
24. [ ] Make split, duplicate, delete, trim, and ripple edits atomic undo transactions.
    - [x] Keep split, duplicate, delete, direct manipulation, keyframe drag, graph drag, and existing trim gestures atomic.
    - [ ] Cover the outstanding professional trim, group, targeting, and sync-lock operations once implemented.

## Milestone 3 — professional audio and animation workflows

25. [ ] Add deterministic audio bus mixing with per-track mute, solo, gain, pan, and meters.
    - [x] Mix overlapping audio at 48 kHz through one deterministic preview/export bus.
    - [x] Apply track mute/solo/gain/pan, clip gain/pan, and volume keyframes with shared preview/export filter semantics.
    - [ ] Add per-track and master meters.
26. [x] Add peak-safe normalization and configurable fade shapes in preview and export.
    - [x] Apply normalization with limiting even for a single input.
    - [x] Persist and render linear (`tri`), logarithmic, exponential, and quarter-sine fade curves.
27. [ ] Add dialogue/music ducking controls with attack, release, threshold, and sidechain lanes.
    - [x] Persist duck amount, attack, release, and optional sidechain track selection.
    - [x] Apply deterministic timeline-lane duck envelopes in preview and export.
    - [ ] Add signal-sensitive threshold detection and metered compressor behavior.
28. [x] Add graph box selection, multi-key dragging, copy/paste, and numeric time/value entry.
    - [x] Apply multi-key moves and edits as one transaction and guard locked channels.
29. [x] Preserve cubic curve shape exactly when splitting or trimming through an animated segment.
    - [x] Subdivide cubic Bézier segments with De Casteljau math and rebase retained curves deterministically.
    - [x] Preserve hold/linear/ease semantics and normalized curves through split, start trim, end trim, and retiming.
30. [ ] Add animation-channel visibility, solo, locking, and reusable curve presets.
    - [x] Ship reusable Hold, Linear, Ease, Sine, Quad, Cubic, and Back timing presets.
    - [x] Add session-scoped channel visibility, solo, and locking controls.
    - [ ] Persist channel display/lock configuration and add simultaneous multi-channel graph display.

## Current feature branch — state animation and canvas manipulation

- [x] Treat base video, image, and GIF clips as normal transformable canvas layers.
- [x] Give base media the same drag, pinch-scale, and two-finger rotation gestures as overlays.
- [x] Size overlay gesture bounds from visible fitted/cropped media instead of a fixed layout slot.
- [x] Apply the selection outline after fit, scale, rotation, and transition transforms.
- [x] Pause and pin the playhead when a direct-manipulation gesture starts.
- [x] Capture position, scale, rotation, opacity, volume, and blur as one state keyframe.
- [x] Automatically create/update a complete state when a keyed clip changes later in time.
- [x] Keep unkeyed clips editing their base values until animation is intentionally armed.
- [x] Add dedicated Add/Update, Delete, Previous, and Next state controls.
- [x] Give keyframes a first-class bottom-dock category instead of nesting them under Effects.
- [x] Apply an outgoing preset to every channel in the current state in one operation.
- [x] Preserve individual-channel editing as an advanced workflow in the graph editor.

## Verification snapshot

- [x] `flutter pub get --enforce-lockfile` succeeds on GitHub Actions with Flutter 3.41.2.
- [x] `flutter analyze` is clean on Flutter 3.41.2.
- [x] All editor, timeline, preview, proxy, waveform, audio, animation, persistence, and undo tests pass.
- [ ] The complete `flutter test` invocation is green.
    - [x] 399 tests pass and 22 platform/integration fixtures skip as designed.
    - [ ] Three unrelated Linux visual-golden comparisons differ from their checked-in PNG baselines; no editor task file or golden was changed to mask them.
- [x] Preview/export parity tests cover every interpolation mode and the shared audio filter graph.
- [ ] Stress playback is verified on a real iOS device.
- [x] Work remains isolated to `editor-heavy-project-foundation`; it is not merged into the default branch.
