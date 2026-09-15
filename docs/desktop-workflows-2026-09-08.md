# Desktop media and export continuation

Base: `master` at `3247d11e4369efd49c786035b8c7881b5a646b50` (`feat: polish editor workflows and desktop foundation`).
Working branch: `release-readiness-desktop-workflows-20260907`.

The September 7 Windows handoff identified incomplete media and delivery
workflows. Source inspection confirmed that the media pool could not import or
place assets independently, the relink command actually replaced footage and
reset trims, and cancelling export stopped every native FFmpeg session.
Export failure could also delete an existing destination before a render began.

## Implemented workflows

- Windows media import and Ctrl+I accept batches of mixed video, image, GIF and
  audio files. Two workers bound probing; duplicate paths are skipped. Each
  file reports failure independently while valid files enter the asset pool.
  Imported files are not automatically inserted into the timeline.
- The media pool provides search, type filters, offline-source filtering,
  usage counts and asset actions. Insert/append reuse asset identity and the
  existing compatible-track placement/undo machinery. Removing an unused asset
  from the pool does not delete its source file; used assets cannot be removed.
- Source review opens an independent viewer with In/Out selection and deliberate
  insert/append actions. Source review pauses timeline playback and leaves its
  playhead unchanged. Selected source ranges retain their source offsets.
- Relink operates on the shared asset and all asset records using its old path.
  It preserves clip IDs, source trims, speed, reverse, keyframes and linked audio,
  clears stale proxies and checks source bounds/dimensions/audio compatibility.
  Locked companion tracks prevent relinking. Users choose the replacement path;
  no ambiguous filename matching runs automatically.
- Replace footage remains a separate clip operation. It rechecks the current
  selection and every affected linked-track lock after the file picker returns,
  and handles separated-audio relationships consistently.
- Desktop video export chooses an MP4 destination before rendering. Work-area
  export is available when In/Out are set; rendering keeps the complete timeline
  timebase for effects/captions, then selects the output range.
- Each export owns its native render/probe sessions and download cancellation.
  Cancellation before native ID allocation also cancels a late session. Export
  cancellation no longer calls global FFmpeg cancellation. Statistics are
  session-local instead of replacing a process-global progress callback.
- Rendering uses a unique temporary directory beside the destination. Source
  paths, symlink aliases and hard-link aliases are protected. A verified result
  replaces the destination with a recoverable backup; failures/cancellation
  clean only owned partial files. Concurrent destination changes are rejected.
  Failed rollback retains the backup and reports its recovery path.
- Removed unused desktop-zoom prototype code that failed analysis. Rotation
  normalization uses bounded arithmetic, including for non-finite/extreme
  values, instead of potentially unending subtraction loops.
- Corrected the desktop transform surface so painting, pointer hit testing and
  coordinate conversion share the child offset. Rotation handles outside the
  content frame now use the same geometry as the visible control.
- Corrected both Android Gradle launchers to invoke `GradleWrapperMain` through
  the classpath. The wrapper JAR supplied by Flutter lacks the main-manifest
  entry required by the previous `java -jar` invocation.

## Verification

Before the final fixes, the focused Linux run passed 29 tests, including every
new media/export regression, and failed the existing outside-frame rotation
handle test. That failure led to the transform-surface correction above.
Formatting and the reported analysis lints have been corrected. A new local
full-suite run could not start because the temporary SDK/package cache was
cleared and package restoration was blocked by network approval. The branch's
current GitHub Actions runs are the authoritative validation for the final code;
do not treat an older successful build as validation of a newer commit.

Commit `6d6f82b` passed Linux formatting/analysis and Windows analysis/regression
tests. The full Linux suite exposed an outdated phone-editor golden: its
transport and selection appearance predated the latest base commit. The CI
images were inspected against the current source before refreshing that baseline.
The same run confirmed the rotation-handle fix and passed 599 tests, with four
failures. Besides the golden, it exposed duplicate preview keys, lost nearest-gap
placement for single-clip paste, and an obsolete lock-feedback assertion. Those
are corrected; locked Paste is verified disabled, and single-clip paste reuses
the nearest gap. Caption word timestamps now shift with pasted cues, with
regression coverage. The final full-suite result remains pending.

The signed Android app bundle/APK build and output verification passed on
`6d6f82b` after the wrapper fix.

The prior checkpoint (`6cb82a9`) built an unsigned iOS IPA successfully. Windows
stopped at analysis, and Android failed at the wrapper launcher; both discovered
source problems are corrected here, pending validation of this commit.

New regression coverage exercises job ownership and late cancellation, protected
outputs and competing writes, bounded/deduplicated batch import, trim-preserving
relink and locked/missing-audio cases, source-range UI, media-pool actions, and
an actual FFmpeg work-area render (start frame, duration and audio).

## Boundaries still open in the larger Windows plan

This continuation does not mark the entire Windows overhaul complete. Remaining
work includes portable collected projects/Save As, media bins and Explorer drops,
dragging assets directly onto tracks, an export job queue, native window-placement
restoration, the remaining precision editing modes, and the broader background
scheduler. Transcription's legacy global cancellation remains separate work;
this change isolates cancellation initiated by export.

Windows editing sessions, long-project playback/sync and memory measurements,
DPI/monitor transitions and physical mobile QA require the respective devices.
The source viewer currently opens as a separate desktop dialog. Frame-rate
model precision and preview/export comparison across the complete effect catalog
remain governed by the existing Windows/editor roadmaps.

No public release, signing setup, existing release draft or default branch is
changed by this continuation.
