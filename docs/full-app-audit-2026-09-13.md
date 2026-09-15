# Full-app audit continuation

Branch: `release-readiness-desktop-workflows-20260907` · draft PR #9.
Verified starting commit: `438f2a6627c723464a74eba2162baf290d8b5035`.

This pass continues the existing desktop, downloader, cancellation, persistence,
split/undo, caption timing, and audio-routing fixes. Six isolated area audits
were reviewed centrally. Proposed changes without a demonstrated defect were
excluded; this is not a claim that all possible edge cases are eliminated.

## Confirmed shared editor fixes

- Completed transcription now resolves the live source and merges into the
  current timeline. Moving the source during processing changes caption
  placement correctly, while unrelated captions, tracks, and markers survive.
  Deleted/relinked/retimed sources, newly added source captions, locked caption
  destinations, cancelled routes, and changed project/account owners reject
  stale completion instead of overwriting current work.
- Speed edits are constructed before publishing state. An affected locked
  caption/audio/downstream track rejects the transaction. Linked captions
  outside the original source window no longer trigger an invalid clamp range.
  Downstream work-area boundaries follow the existing clip/marker ripple.
- Multi-lane clipboard enablement checks collisions among the proposed clips,
  including when deleted source lanes resolve to one fallback lane. Existing
  single-clip nearest-gap placement remains intact.
- The legacy-project close test starts its filesystem-backed close in the real
  async zone and awaits pending writes. It verifies the saved schema as well as
  returning to Home, avoiding the prior accidental short disk-save deadline.

## Editor interaction fixes

- Keyframe numeric input rejects non-finite times before converting them to
  durations. An empty or dynamically removed property list displays an empty
  state and ends the active edit instead of indexing a missing property.
- Deleting a track checks locks on linked companion tracks. Successful removal
  synchronizes caption state and repairs mixed selections while retaining
  surviving clips. The regression exercises deletion followed by undo/redo.
- Caption lane sliders and presets now change their targeted cues instead of
  the global style. Color dialogs retain the live target style, and all these
  mutations recheck current lane locks. Global style controls respect locked
  caption lanes too.
- Stale subtitle IDs no longer throw or create empty undo actions. Splitting
  cues clips crossing word timings to each resulting cue. Transcription falls
  back to segment timing when word arrays are empty, preserves equal-timestamp
  input order, and deduplicates without reordering its caller's source list.

## Playback, downloads, and project lifecycle

- Pending seeks and playback position are clamped when timeline duration
  shrinks. Editor seek requests preserve microseconds instead of truncating
  them to milliseconds; native decoder precision is still platform dependent.
- Ducking now follows the same mute/solo bus routing as the audible graph.
  Separated video originals cannot keep ducking music after their detached
  audio has been muted. This applies to the shared preview/export graph.
- A definite embedded-runtime launch failure can be retried. Corrupt readiness
  markers and slow startup retain the same interpreter rather than launching
  another one. Instagram inspection rejects adaptive manifests that the direct
  transfer path cannot consume, and retains usable MIME for image-only posts.
- Failed catalog writes produce observable retryable download states. Failed
  publication cleans newly owned media after the worker finishes; a destination
  that existed before the worker is preserved during that failure path.
- Python limits lazy playlist iteration before materializing entries, retaining
  the existing 24-entry transport bound without consuming an entire iterator.
- Home relinking now probes existing assets and calls the shared media-pool
  relink validator. Clip source windows, IDs, speed, linked asset references,
  dimensions, locks, and proxy invalidation follow the editor's existing rules.
  Empty picker results are cancellation; duplicated projects start without an
  export path belonging to the original project.
- Missing creation timestamps use the known modification timestamp. Invalid
  ownership/core project fields still fail strict parsing, and merged schema
  versions still follow the caption/style source for migration.

## Capability map

These paths distinguish existing working features from fixes in this pass.

| User action | Handler/provider | Persisted state | Preview/export consumer | Regression coverage |
| --- | --- | --- | --- | --- |
| Split, paste, ripple delete | `TimelineEditorController` and editor history | Clips, relationships, cues, markers, workspace | Timeline preview and export graph | `timeline_editor_controller_test`, `editor_transaction_edge_cases_test`, `timeline_editor_controller_edge_cases_test` |
| Change speed | Screen speed transaction and `EditorNotifier` | Clip transport, linked timing, workspace | Shared media/audio render inputs | `editor_playback_rate_transaction_test`, source-resolution and rendering-parity suites |
| Generate captions | Transcription pipeline, live caption update, subtitle provider | Cue IDs, text, style, confidence, word timings, source links | Caption preview and export | `editor_async_caption_result_test`, `transcription_lifecycle_test`, subtitle/export suites |
| Inspector/keyframe input | Desktop inspector and graph editor callbacks | Clip transforms and keyframes | Preview interpolation and FFmpeg expressions | Inspector, graph, and gesture suites |
| Mixer routing and ducking | Editor audio settings and buses | Track/bus IDs, mute/solo, audio mix | Shared preview/export audio graph | `audio_workflow_foundation_test`, audio preview/rendering-parity suites |
| Discover → Add to Timeline | Download manager and media import service | Download catalog, durable asset path, timeline asset reference | Standard media preview/export | Discover manager/provider/import and downloader suites |
| Relink source | Home and media-pool relink service | Shared asset paths, retained clip source windows, cleared proxies | Original source for export; valid proxies for preview | `home_relink_regression_test`, `desktop_media_workflow_test`, source-resolution suites |
| Save/reopen | Editor local save barrier and project storage | Versioned project and recovery snapshots | Editor initialization | `project_persistence_test`, `editor_screen_entry_test` |
| Connected services | Settings screen and API-key vault | Secure local keys and supported encrypted backup | Groq and media-service clients | Settings/vault/runtime-key suites |
| Advanced color, tracking, scopes | Color controls, scope/tracking services | Color management, masks, tracked keys | Shared color graph and sampled scopes | `color_scope_and_tracking_test`, effect export/parity suites |

The effects/audio status document previously described an older foundation. It
now reflects the already connected selective-color, tracking, scope, loudness,
and bus workflows. Serialized fields alone were not treated as usable features.

## Validation evidence

- Baseline `438f2a6`: push validation and Android/Windows/iOS builds succeeded.
  PR validation failed in the legacy-project close test with “Editor did not
  close after its bounded save wait”; the actual job log was inspected.
- First shared-fix checkpoint `3234908`: **650 Flutter tests passed**, static
  analysis clean, **6 Python runtime tests passed**, Android debug packaging
  and Android/Windows/iOS release builds succeeded. Validation failed only on
  formatting; its exact formatter diff was applied afterward.
- CI now emits formatting diffs and runs analysis/tests after a formatting
  failure. A failing gate still fails the job.
- The local Flutter SDK did not survive the resumed workspace and its download
  host was unreachable. Flutter results in this pass are from GitHub CI, not
  newly claimed local runs. The local Python suite passed all six baseline
  runtime tests.
- Reviewed integration checkpoint `923085c` adds the playback, download, Home,
  and clipboard fixes. The integrated local Python runtime suite passes all
  **7 tests**, including a lazy-iterator regression reproduced on the baseline.
- PR validation for `923085c` passed **665 Flutter tests**, clean analysis,
  **7 Python tests**, and Android debug packaging. Push validation also passed
  its test and analysis steps. Android, Windows, and iOS build workflows
  succeeded. Formatting was the validation failure; its exact diff was applied.
- Final integrated validation is recorded below when the completed patch runs.

## Remaining limits

Live YouTube/Instagram downloads, native mobile playback/cancellation, Windows
interaction, long-GOP 4K/60 thermal/memory stress, and HDR display/output checks
still require physical-media/device verification. Transport fixtures do not
prove live-site availability.

Groups/compounds remain processing sets rather than nested timelines. Template
tracking is not planar tracking. Scopes and loudness analysis do not establish
continuous real-time metering performance. Dedicated ripple/roll/slip/slide
tools, generic audio-effect automation, and intelligent music remix remain
roadmap work. Invalid output color-space combinations retain explicit guards.
