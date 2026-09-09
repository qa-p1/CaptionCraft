# Edge-case audit and recovery polish

Base: `da8b2171517b8ca6bd7535f0b8fa72f72e556c22`.
Branch: `release-readiness-desktop-workflows-20260907`, continuing PR #9.
The base passed the full Flutter suite, analysis, Windows release validation,
signed Android release validation, and the unsigned iOS build.

## Confirmed defects repaired

| Area | Failure and resulting behavior |
| --- | --- |
| Transcription cancellation | Cancelling speech processing used global FFmpeg cancellation. Probing, extraction, chunking and thumbnail creation now belong to the transcription's own `MediaJob`. |
| Native cancellation errors | A synchronously throwing cancellation could prevent other owned sessions from being stopped. All callbacks are now attempted, repeated cancellation shares one result, and late sessions still receive cancellation. |
| Transcription lifecycle | Concurrent runs could reset cancellation; disposal only closed the stream; cancellation during the final thumbnail could still return a completed project. Runs are exclusive, disposal cancels native/network work, and late results are discarded. |
| Audio boundaries | Chunking rounded the total length down to whole seconds. Ranges now retain milliseconds and the configured overlap. Segment transcription validates the start and clamps the requested duration to the remaining source. |
| Partial audio | Native exceptions could leave extraction/chunk files behind. Owned outputs are cleaned on failure/cancellation, and empty output is rejected. |
| Download cleanup | Terminal status appeared before file cleanup completed, allowing an immediate retry to collide with the previous worker. Retry and deletion now wait for that worker. |
| Instagram retry | A pending lookup could restart a cancelled download or replace its cancelled state with an error. Retry generations reject late results/errors. Missing carousel selections fail instead of downloading another item. |
| Queue persistence | Cancellation could wait for a failed disk write before stopping YouTube. Native cancellation now starts first. Failed enqueue persistence leaves an actionable failed item instead of a stranded queued item. |
| Download initialization | Failed initialization was cached permanently, and disposal during initialization could still launch work. Failed attempts can be retried and disposed managers reject late work. |
| Recovery UI | Failed download-library initialization now displays a working Retry button instead of a loading indicator or misleading empty-library state. |
| Subtitle import | Invalid fractions, negative timestamps, invalid minute/second fields and trailing garbage could be accepted. Parsing now consumes the full timestamp, retains existing comma/short-fraction compatibility, and correctly handles 100-hour SRT timestamps. |
| Teleprompter | Empty/invalid cues could enter rehearsal, and an earlier overlapping cue extending beyond the last cue was cut short. Rehearsal uses valid cues and the maximum end time. |
| Project deletion | Local deletion did not check account ownership. It now rejects a mismatched owner, records deletion before removing snapshots, rejects saves while deletion is pending, and ignores leftover recovery copies for deleted projects. |

## Full-editor and UI continuation

The continuation expanded the review to timeline editing, selection, inspector
input, audio routing, source trim, home navigation, and the agreement between
persisted processing state and visible controls.

| Area | Failure and resulting behavior |
| --- | --- |
| Split entry points | Toolbar/context-menu and keyboard splits had separate implementations. Both now use the shared split transaction, retaining the screen's trailing-half selection behavior. |
| Caption splitting | Splits could discard confidence and word timings or stretch all words into the leading half. Both cue halves retain confidence and only their intersecting word intervals, clipped at the split. Undo/redo restores the complete transaction. |
| Freeze frames | Changing each half's source window could clamp a frozen timestamp to a different frame. Frozen halves retain the original source window and frame. |
| Split relationships | Newly split audio/captions could retain a group ID without being included in the group, and scoped effects could stop at the leading half. Split members are added to groups/compounds and scoped effect stacks are split and copied. |
| Locked and independent companions | Existing toolbar behavior is retained: independently timed audio and locked companion tracks remain untouched. Locked split targets and fragments shorter than 100 ms are rejected. |
| Ripple delete | Clips moved while markers and export work-area boundaries stayed behind. Downstream markers and boundaries now follow the deleted range; markers inside the removed range are removed. Undo restores them. |
| Source trim | An open inspector could apply a stale clip snapshot or ripple into locked tracks. Trim resolves the live clip, rejects changes affecting locked tracks, and handles sources shorter than 100 ms without an invalid clamp range. |
| Provider lifetime | Retaining an editor widget while replacing its provider scope could leave commands referencing disposed notifiers. The shared controller now rebinds to current notifiers and clears its old clipboard. |
| Inspector fields | Blurring a field after changing selection could commit against the next clip; locking a clip could still commit pending input. Selection/lock changes cancel pending fields and submission rechecks editability. |
| Audio bus creation | Creating and assigning a bus took two undo steps and could leave an orphan bus after the target disappeared. The combined backend operation validates the live track and records one transaction. |
| Audio bus UI | Backend deletion was unreachable from the mixer. The mixer now exposes deletion with confirmation, returns assigned tracks to Master output, respects locked tracks, and supports undo. The routing dropdown follows undo and external routing changes. |
| Small-screen audio | Expanding advanced audio exposed channel dropdown overflow on phone widths. Dropdowns constrain their content and bus actions wrap onto another row. A mixer widget regression covers deletion, undo and layout. |
| Home navigation | A delete dialog returning after its screen was disposed could access a dead widget reference. It now checks mounting before continuing. |

## Verification

Added regressions cover delayed native/network completion, per-job cancellation,
overlapping transcription, invalid/clipped source ranges, fractional chunk tails,
initialization recovery/disposal, retry during worker cleanup, late Instagram
results/errors, missing carousel items, failed queue writes, recovery UI,
teleprompter overlap, malformed subtitle imports, and project deletion ownership
and recovery markers.

New editor regressions cover caption split metadata and undo/redo, freeze-frame
continuity, locked companions, group/effect membership, ripple markers/work area,
audio bus transactions and inspector selection/lock transitions. The existing
full suite also exercises actual editor gestures, rendered FFmpeg output,
preview/export parity, settings/vault recovery, media libraries and persistence.

The six embedded Python runtime checks pass locally. Formatting is checked with
the pinned Dart SDK. Full Flutter analysis/tests and native builds run in GitHub
Actions; final results are recorded in PR #9 so documentation updates do not
continually restart release builds.

Timestamp syntax was checked against the
[WebVTT specification](https://www.w3.org/TR/webvtt1/#webvtt-timestamp).
This importer intentionally preserves its existing compatibility with commas and
one/two-digit decimal fractions.

## Scope and remaining verification

This is a source audit and regression pass, not proof that every possible app
state is bug-free. It reviewed core editor commands and timing, UI lifecycle and input, audio routing,
backend/control wiring, persistence/deletion, download state transitions,
transcription/native job lifecycle, and subtitle interchange. Unsupported render
features documented in the effects roadmap remain guarded; exposing dormant
model fields alone would not provide a working feature.
Physical-device media downloads, long-session memory/audio stress, and native
interaction checks remain necessary. The larger desktop roadmap remains open.
No default-branch merge or public release is part of this change.
