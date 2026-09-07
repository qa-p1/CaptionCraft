# Windows implementation handoff

The user requested implementation by `gpt-5.6-luna` agents at `max` reasoning effort. The root agent orchestrates, reviews and routes corrections; it does not implement application changes. Read `windows-editor-plan.md` for the full scope and acceptance checks.

## Release baseline

- Android draft is complete: `build-0.10.0-2006-editor-polish-arm64-20260907`.
- Signed ARM64 APK, exact pre-Windows working-tree source archive, source manifest and checksums are attached. Do not rebuild or alter this draft during Windows work.
- Extensive uncommitted Android changes and unrelated user changes already existed. Preserve them. No reset, clean, broad revert, automatic commit or public release.

## Current workers and ownership

The original three workers stopped during an interruption. Their partial code remains; no desktop test results were reported. Replacement workers resume those files:

| Worker | Exclusive application ownership | Immediate deliverable |
| --- | --- | --- |
| `/root/resume_workspace` | `editor_screen.dart`, `desktop_*` widgets/preferences, `resizable_editor_sheet.dart` | Finish responsive workspace, real inspector, command integration and dedicated tests. |
| `/root/resume_timeline` | `timeline_panel.dart`, `timeline_editor_controller.dart`, `editor_shortcuts.dart`, necessary provider commands | Correct clipboard/selection operations, full-width timeline and mouse behavior with tests. |
| `/root/resume_viewer` | `video_preview_panel.dart`, `preview_transform_controls.dart` | Correct resize/rotation/hit testing/cancellation with tests; prepare verified native build dependencies. |

All use Luna at maximum effort. There are three worker slots. Stagger subsequent slices as workers finish; do not overlap ownership.

## Integration contracts

- `TimelinePanel` and `VideoPreviewPanel` receive `desktopMode`, default false. Workspace passes true on Windows, including fullscreen preview.
- Shared `TimelineEditorController` owns clipboard/command behavior; workspace wires it to menus and keyboard commands. Communicate enum/API changes before use.
- Existing robust `_splitClipAtPlayhead` must be reused or extracted for the controller, including reverse/source bounds, keyframes and linked audio.
- Existing `EditorNotifier.cancelTimelineGestureEdit()` restores the gesture baseline. Do not simulate Escape using global undo.

## Review corrections already sent to workers

Workspace:

- Serialize preference saves; coalesce rapid changes; catch optional preference-write failures.
- Delayed preference load must not overwrite a newer user resize. Reject non-finite values.
- Splitters require actual hover/drag feedback, not a constant AnimatedContainer.
- Inspector text-controller selection validity is not an editing-state test. Use focus/editing state so unfocused fields follow preview changes and keyframe seeks, while focused typing is preserved.
- Desktop labels should be readable around 12–13 pixels rather than miniature 9-pixel mobile tabs.

Timeline/controller:

- Validate locks across every linked clip a command will mutate, in both enabled state and execution.
- Define symmetric linked-selection behavior, including separated audio source IDs.
- Allocate new caption IDs on paste and preserve relative timing.
- Remap separated audio/group/compound relationships when cloning; do not retain links to originals inadvertently.
- Reuse the robust split implementation; the prototype loses source/reverse/keyframe/linked-audio behavior.
- Validate overlap before normalization and commit timeline/caption state atomically. Subtitle-only deletion must remove the timeline cue as well.

Viewer:

- Include the left edge in resize-handle classification and test all eight targets.
- A rotation handle drawn outside a widget's bounds needs a real hit-test area; `Clip.none` alone does not provide one.
- Capture and match the initiating pointer ID.
- Compute anchor movement using the accepted scale factor after model bounds, not the unrestricted pointer factor.
- Snap the absolute rotation angle, not just its delta.
- Test stable screen-coordinate geometry, cancellation and readable handles at different scales.

## Remaining waves after these slices pass

1. Workspace owner: batch media import, asset/source workflow, trim-preserving relink, portable projects and source/media library integration.
2. Viewer owner: per-job FFmpeg cancellation/progress and preview reliability; protected output transactions and desktop export destination/range/jobs.
3. Timeline owner: native Windows build integration, native window placement, focused end-to-end tests and remaining precision editing gaps.
4. Cross-review and fixes, full analysis/test suite, actual native Windows editing session, visual/layout checks, release-bundle verification and honest completion report.

Use the plan's acceptance criteria. Do not mark the whole editor complete because the first layout renders or individual widget tests pass.

## Environment and build notes

- Workspace: `D:\Aadi\Coding\App dev\CaptionCraft`; shell: PowerShell.
- Flutter: `D:\Aadi\Programs\flutter\bin\flutter.bat` (3.41.2).
- Verified Windows dependency URLs, sizes and hashes are in `.github/workflows/build-windows-release.yml`. Prepare under `.dart_tool/windows-deps` so build cleanup cannot erase downloads.
- No new native Windows build has been validated yet. Prior attempts hit an incomplete Firebase dependency archive.
- Widget tests should use existing editor testing factories and keep `project.subtitles` consistent with timeline captions.
- During concurrent source edits, run focused tests and report cross-file compile failures to the owner. Run the full suite after integration stabilizes.
