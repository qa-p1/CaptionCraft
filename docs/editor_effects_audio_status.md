# Effects, color, and audio implementation status

Updated September 13 against `release-readiness-desktop-workflows-20260907`.
The earlier document described an older foundation and incorrectly listed
several subsequently connected features as unsupported. The implementation
boundaries below come from current consumers and regression fixtures; they
do not establish physical-device validation.

## Working now

- Ordered, toggleable, drag-reorderable effect stacks persist on clips, tracks,
  groups, compound sets, adjustment layers, and the project. Stacks can be
  copied, pasted, saved as presets, and restored through undo/redo.
- Visual effect parameters support timed keyframes. Gaussian, directional, and
  motion blur are distinct implementations. The full exposed stylized, lens,
  glow, geometry, shadow/stroke, and distortion catalog produces valid FFmpeg
  filters; compatibility tests parse every type and verify every visible
  numeric parameter changes delivery output.
- Rectangle, ellipse, and freeform effect masks, feathering, inversion, and
  tracking keyframes persist. Adjustment layers can be created, trimmed, split, and
  duplicated and process lower visual layers during their active range.
- Standard scalar color controls, RGB channels, RGB curve, tone/global wheels,
  and LUT intensity are shared by preview/export paths. Whites and the other
  exposed controls are no longer dead state.
- Custom and pack LUTs are durable, reusable project assets. The dedicated LUT
  library shows generated previews and applies one look atomically to one or
  many selected visual clips.
- Audio remains non-destructive and persistent: multiple tracks, detach/relink,
  source-channel modes, volume/pan/fades, volume keyframes, mute/solo, buses,
  EQ, dynamics, restoration, reverb/delay/distortion, pitch/time-stretch,
  normalization/limiting, and deterministic lane ducking feed the shared
  preview/export audio graph.
- Hue curves, HSL/skin-tone qualifiers, spatial masks, and neutral-reference
  sampling are connected through `advanced_color_controls.dart` and the shared
  color graph. `color_scope_and_tracking_test.dart` exercises freeform mask UI,
  persisted tracking, actual moving-target tracking, and scope graphs.
- Waveform, RGB parade, vectorscope, and histogram have FFmpeg scope consumers.
  Object tracking uses FFmpeg template matching (`find_rect`). These are real
  processing paths, with limitations described below.
- Color management supports SDR, HLG, PQ, and wide-gamut output paths. Automatic
  and Log remain input interpretations and are rejected as project output
  spaces; preserving HDR with SDR output is also rejected.
- Audio analysis measures peak, RMS, and loudness. A saved loudness pass is reused
  only when its source/render fingerprint matches; otherwise normalization uses
  the fallback pass. Bus creation, assignment, and deletion have mixer controls
  and undo. See `audio_workflow_foundation_test.dart` and
  `editor_screen_capability_test.dart`.

Many named stylized effects are deterministic FFmpeg approximations rather than
GPU shader simulations. During active playback the bounded live fallback also
approximates advanced effects; the accurate cached composite is used after the
edit/playback settles and final export always uses the full graph.

## Still incomplete

- Group and compound records are shared processing sets over member clips, not
  true flattened nested timelines with independent internal timebases.
- Template matching is not general object recognition or planar tracking.
  Occlusion, scale/rotation changes, long clips, and native-device performance
  still need physical-media verification.
- HDR processing code and deterministic fixtures do not verify display
  calibration, every camera Log profile, or encoded HDR playback on devices.
- Scopes are sampled/cached processing, not proof of continuous real-time scope
  performance on all devices. Audio measurements are analysis results, not
  continuously sampled live mixer meters.
- Signal-threshold sidechain ducking is not implemented; existing ducking follows
  timeline activity.
- Generic audio-effect parameter keyframes are not exposed because several
  filters cannot be safely timeline-enabled; volume automation is supported.
- Intelligent music remix/stretch-to-duration remains outstanding. Bus routing
  is persisted and exposed; true nested submix/compound timelines remain outside
  the current processing-set model.

These boundaries must stay visible in product copy and tests; a roadmap checkbox
or serialized model field alone must not be used to claim completion.
