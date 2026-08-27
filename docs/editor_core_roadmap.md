# Editor core and timeline roadmap

This roadmap focuses on long, multi-layer projects and predictable editing.
The first milestone fixes playback-clock/audio stability and replaces linear-only
keyframes with a reusable curve model and graph editor. Later milestones build
on those foundations rather than adding isolated controls.

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
12. [x] Add a graph editor with draggable keys, tangent handles, presets, panning, and zoom.
13. [x] Make graph drags a single undo transaction instead of one undo step per pointer update.
14. [ ] Add device-level playback stress fixtures for long-GOP 4K/60 media and overlapping audio.

## Milestone 2 — heavy-project timeline interaction

15. [ ] Virtualize off-screen clips, thumbnails, waveforms, and keyframe lanes.
16. [ ] Separate live gesture state from committed render state to avoid full preview rebuilds.
17. [ ] Add proxy media generation, relinking, and preview-quality controls.
18. [ ] Cache waveforms by source fingerprint and source window.
19. [ ] Add dropped-frame, buffering, decoder-count, and clock-drift diagnostics.
20. [ ] Add zoom-to-playhead, zoom-to-selection, and exact frame navigation.
21. [ ] Add configurable snapping for frames, clip edges, markers, beats, and keyframes.
22. [ ] Implement ripple, roll, slip, and slide trim tools.
23. [ ] Add linked selection, grouping, track targeting, and sync-lock controls.
24. [ ] Make split, duplicate, delete, trim, and ripple edits atomic undo transactions.

## Milestone 3 — professional audio and animation workflows

25. [ ] Add deterministic audio bus mixing with per-track mute, solo, gain, pan, and meters.
26. [ ] Add peak-safe normalization and configurable fade shapes in preview and export.
27. [ ] Add dialogue/music ducking controls with attack, release, threshold, and sidechain lanes.
28. [ ] Add graph box selection, multi-key dragging, copy/paste, and numeric time/value entry.
29. [ ] Preserve cubic curve shape exactly when splitting or trimming through an animated segment.
30. [ ] Add animation-channel visibility, solo, locking, and reusable curve presets.

## Release gates

- `flutter analyze` must be clean.
- Unit and widget tests must pass on the pinned Flutter version.
- Preview/export parity tests must cover every interpolation mode.
- Stress playback must be verified on a real iOS device before merging.
- Work lands through a feature branch and pull request, never directly on the default branch.
