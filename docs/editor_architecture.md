# Editor architecture

This document describes the editor implementation on
`editor-heavy-project-foundation`. It complements the status-oriented
[editor roadmap](editor_core_roadmap.md) and records the boundaries that should
remain stable as unfinished roadmap work is added.

## Ownership and data flow

| Concern | Primary implementation | Responsibility |
| --- | --- | --- |
| Persistent timeline model | `lib/features/editor/models/timeline_models.dart` | Clips, tracks, assets, workspace settings, transforms, animation, audio controls, schema defaults, and JSON compatibility |
| Editor state and history | `lib/features/editor/providers/editor_provider.dart` | Immutable timeline updates, selection, playhead, edit/commit revisions, and undo/redo transactions |
| Timeline interaction | `lib/features/editor/widgets/timeline_panel.dart` | Virtualized lanes, clip gestures, trim, zoom, ruler, frame navigation, snapping, waveforms, and keyframe lanes |
| Timeline indexes and edit math | `lib/features/editor/services/` | Sorted snapping targets and pure curve-preserving split/trim/retime operations |
| Preview composition | `lib/features/editor/widgets/video_preview_panel.dart` | Composition clock, decoder ownership, visual layers, direct manipulation, proxy resolution, diagnostics, and preview audio lifecycle |
| Preview audio bus | `lib/core/utils/timeline_preview_audio_service.dart` | Cached preview mix rendering using export audio semantics |
| Source proxy and waveform caches | `lib/core/utils/timeline_proxy_media_service.dart`, `lib/core/utils/timeline_waveform_cache.dart` | Deterministic identity, serialized native jobs, cancellation, atomic output, and bounded cleanup |
| Export | `lib/core/utils/timeline_export_service.dart` | Original-media FFmpeg graph, animation sampling, visual composition, and deterministic audio mix |

The `EditorTimeline` is the only persistent editing model. Preview, graph
editing, and export do not maintain competing animation or audio models.

## Playback and preview

Playback position comes from a monotonic composition clock. Decoder callbacks
report readiness and drift but do not own the playhead. Media-specific drift
thresholds and correction cooldowns prevent normal callback jitter from
causing hard-seek storms or playback-rate modulation.

Paused scrubs and explicit discontinuities remain accurate seeks. Upcoming
audio decoders and the next base-video decoder are warmed within bounded
windows; inactive warm decoders remain paused and silent. Dense visual overlap
can be collapsed into a silent composite preview, while audible overlap is
rendered into one 48 kHz preview bus. Both caches expose decoder/load
diagnostics and release stale controllers and native work.

## Live edits and committed render state

Continuous canvas, graph, and timeline gestures publish live model values for
visual feedback. The provider's gesture session keeps `editRevision` stable so
expensive preview-audio/composite invalidation remains pinned until the gesture
commits. Ending the session advances that revision and leaves one history
transaction.

This separation covers native media work and undo coalescing. Some broad
provider/widget rebuilds still occur during live inspector and transform
updates; further rebuild isolation remains roadmap item 16 rather than a second
state system.

## Timeline scale and snapping

Timeline lanes are horizontally and vertically virtualized. Mounted clips,
markers, thumbnails, waveforms, transitions, and keyframe lanes are restricted
to the visible window, while an active gesture item stays pinned. Playback and
caption resolution use interval indexes and bounded time-window queries.

Snapping uses one immutable, sorted `TimelineSnapIndex` per timeline identity.
Pointer updates use binary searches for clip edges, markers, beats, and absolute
keyframe positions. Frames, playhead, selection, and work-area boundaries are
independently configurable. Frame navigation derives each boundary from its
absolute frame number, avoiding accumulated rounded-millisecond drift.

## Animation and curve-preserving edits

State keyframes capture position X/Y, scale, rotation, opacity, volume, and
blur together. Once animation is armed, later gestures and inspector changes
update the complete state at the frame-snapped playhead. The graph editor uses
the same `TimelineKeyframe` values and interpolation evaluator as preview and
export.

Split and inward trim operations preserve the visible segment of an animation.
For a cut through a cubic Bézier segment, De Casteljau subdivision produces two
normalized child timing curves. Start trim rebases the retained tail, end trim
retains the leading curve, and retiming scales key times without changing
normalized handles. Hold and linear/ease semantics are retained as their native
interpolation modes.

Graph selection state, clipboard contents, channel visibility, solo, and locks
are deliberately session-owned UI state. Animation data and curve presets are
persistent; multi-channel display configuration is not yet persistent.

## Proxies, waveforms, and cache boundaries

Source proxies are distinct from dense composite/render caches. Their identity
includes the source fingerprint and encoding profile. Preview can select Auto,
Proxy, or Original quality, and a persisted valid proxy can keep an offline
source previewable. Relinking changes the source fingerprint and invalidates a
stale proxy. Final export always resolves the original asset.

Waveform identity includes the source fingerprint, source window, audio stream,
and requested density. Identical in-flight requests share one job. Proxy and
waveform generation are serialized, write through temporary files, discard
cancelled output, and enforce entry/byte limits. Generated media belongs only
in app cache directories and must never be committed.

## Audio semantics

Preview and export share the FFmpeg audio-filter builder. The deterministic bus
applies track mute/solo/gain/pan, clip gain/pan, volume keyframes, configurable
fade curves, normalization, limiting, and timeline-lane duck envelopes. It is
designed for many simultaneous voices without asking platform player callbacks
to form the final mix.

The live platform-player fallback approximates gain and fade envelopes while a
bus is unavailable; exact pan and complete mix parity come from the rendered
bus. Per-track/master meters and signal-threshold ducking remain unfinished and
are documented as partial roadmap items.

## Persistence and compatibility

New persistent fields use safe defaults when absent: preview quality defaults
to Auto, snapping uses the standard target set, track gain/pan are neutral,
fade shape defaults preserve legacy linear behavior, and duck timing/source
fields use normalized fallbacks. Unknown or malformed enum values use existing
model fallback conventions. The schema revision was advanced without removing
legacy decoding paths.

Proxy metadata is stored with the asset, but cache files are replaceable and
are never an export source of truth. Graph clipboard and channel presentation
state are intentionally not serialized.

## Undo and remaining boundaries

One gesture produces one undo transaction for direct manipulation, clip moves
and trims, graph/keyframe drags, state changes, split, duplicate, and delete.
The existing architecture should be extended—not duplicated—for the remaining
roll, slip, slide, group, track-target, sync-lock, meter, and threshold-ducking
work. Those capabilities remain explicitly partial in the roadmap.

## Verification

The branch workflow pins Flutter 3.41.2 and runs:

```sh
flutter pub get --enforce-lockfile
flutter analyze
flutter test
```

The latest implementation audit has a clean analyzer and passing editor-core
tests. The full suite currently reports 399 passed, 22 skipped, and three
unrelated Linux visual-golden mismatches. Physical iOS long-GOP 4K/60 stress
validation has not been performed and must remain an explicit release gate.
