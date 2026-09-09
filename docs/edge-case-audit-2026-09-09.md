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

## Verification

Added regressions cover delayed native/network completion, per-job cancellation,
overlapping transcription, invalid/clipped source ranges, fractional chunk tails,
initialization recovery/disposal, retry during worker cleanup, late Instagram
results/errors, missing carousel items, failed queue writes, recovery UI,
teleprompter overlap, malformed subtitle imports, and project deletion ownership
and recovery markers.

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
state is bug-free. It reviewed persistence/deletion, download state transitions,
transcription/native job lifecycle, subtitle interchange and affected UI flows.
Existing full-suite tests continue to cover editor, playback and export behavior.
Physical-device media downloads, long-session memory/audio stress, and native
interaction checks remain necessary. The larger desktop roadmap remains open.
No default-branch merge or public release is part of this change.
