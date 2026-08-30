# Effects, color, and audio implementation status

This status is audited against implementation and tests on
`editor-heavy-project-foundation`. Persisted fields are not counted as complete
unless preview/export or an explicit delivery guard consumes them.

## Working now

- Ordered, toggleable, drag-reorderable effect stacks persist on clips, tracks,
  groups, compound sets, adjustment layers, and the project. Stacks can be
  copied, pasted, saved as presets, and restored through undo/redo.
- Visual effect parameters support timed keyframes. Gaussian, directional, and
  motion blur are distinct implementations. The full exposed stylized, lens,
  glow, geometry, shadow/stroke, and distortion catalog produces valid FFmpeg
  filters; compatibility tests parse every type and verify every visible
  numeric parameter changes delivery output.
- Rectangle and ellipse effect masks, feathering, inversion, and tracking
  metadata persist. Adjustment layers can be created, trimmed, split, and
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
- Unsupported selective-color and HDR/Log delivery states fail clearly instead
  of silently exporting a different SDR result.

Many named stylized effects are deterministic FFmpeg approximations rather than
GPU shader simulations. During active playback the bounded live fallback also
approximates advanced effects; the accurate cached composite is used after the
edit/playback settles and final export always uses the full graph.

## Still incomplete

- Group and compound records are shared processing sets over member clips, not
  true flattened nested timelines with independent internal timebases.
- Freeform mask drawing and actual object/planar tracking are not implemented;
  the current tracking fields are metadata only.
- Hue-vs-hue/saturation/luminance curves, HSL qualifiers, tracked selective
  corrections, skin-tone tools, and neutral-reference white-balance sampling
  have persistence foundations but no supported render/UI workflow. Export is
  intentionally blocked if that dormant state is present.
- SDR Rec.709 is the supported delivery path. Camera-log transforms, HLG/PQ,
  wide-gamut processing, metadata override, and HDR export are not implemented
  and are intentionally blocked rather than silently converted.
- Waveform monitor, RGB parade, vectorscope, histogram, and playing video scopes
  are not implemented.
- Audio meters are not real-time peak/RMS/LUFS meters, loudness normalization is
  one-pass, and signal-threshold sidechain ducking is not implemented.
- Generic audio-effect parameter keyframes are not exposed because several
  filters cannot be safely timeline-enabled; volume automation is supported.
- Intelligent music remix/stretch-to-duration and persisted advanced bus/submix
  routing UI remain outstanding.

These boundaries must stay visible in product copy and tests; a roadmap checkbox
or serialized model field alone must not be used to claim completion.
