# Windows editor overhaul

Planning baseline: 7 September 2026. Android release snapshot: `0.10.0+2006`, captured before Windows implementation. Status: inspection and implementation plan complete; the work below is pending implementation and validation.

## Intended result

CaptionCraft should support an ordinary editing session from importing footage through delivery using a mouse and keyboard, with a responsive desktop workspace and recoverable project state. The viewer, timeline and inspector should cooperate. Common edits should stay in context, and advanced features should be discoverable without a wall of buttons or repeated modal navigation.

Use the familiar organization of a professional desktop editor as the reference: media on the left, viewer in the center, properties on the right and timeline below. Retain CaptionCraft's visual identity and caption workflow. Completion means verified editing workflows, not merely a desktop-looking screenshot. Complete feature parity with a large grading, compositing and finishing suite is a separate scope.

## Inspection findings

These findings come from the current source. Native Windows behavior still needs validation against a newly built application; the supplied screenshot is useful evidence of the earlier layout, not proof that every current feature is broken.

| Area | Current evidence | Required change |
| --- | --- | --- |
| Workspace | `editor_screen.dart` chooses portrait/landscape layouts; tall landscape caps preview height at 420 logical pixels and retains the mobile bottom dock. | Explicit desktop workspace with resizable regions and sensible compact-window behavior. |
| Timeline width | `timeline_panel.dart` calculates content width as duration × zoom + 120, without a viewport minimum. | Fill the available width for short projects; retain scrolling and virtualized rendering for long projects. |
| Track controls | Track rail is 50 pixels wide; track names and controls largely live behind touch interactions. | Readable track headers, visible lock/mute/solo/visibility state, direct mouse controls. |
| Mouse editing | Clip movement and trimming use a 480 ms hold recognizer; track reordering also uses a long press. | Immediate intentional mouse drag after movement slop, appropriate cursors and right-click actions; preserve touch behavior. |
| Viewer manipulation | `_OverlayTransformBox` provides scale/move/rotation gestures and selected borders, with no desktop handle UI. | Mouse hover outlines, selection handles, rotation affordance, reliable gesture ownership and numerical controls. |
| Commands | Shortcut service handles several edit and transport commands, but has no general cut/copy/paste/duplicate mapping. Clipboard state is private to the timeline widget. | Shared command and clipboard layer used by shortcuts, menus and contextual controls. |
| Import | Ctrl+I invokes the single-file overlay picker. Base, audio and overlay imports are separate flows. | Batch import into a media pool before deliberate timeline placement. |
| Relink | `_relinkClipMedia` creates a replacement asset and sets `sourceStartTime` to zero. | Separate locating the same source from replacing footage; preserve edits when relinking. |
| Background work | Export cancellation calls `FFmpegService.cancelAll()`. Some operations register a global statistics callback. | Per-job cancellation and progress ownership; prevent jobs from stopping or reporting progress for each other. |
| Export destination | Export screen creates a timestamped MP4 in Documents/CaptionCraft/Exports. | Choose destination and filename before rendering; reliable overwrite and partial-output handling. |
| Export replacement | Export service deletes an existing output before rendering. Current timestamp names limit collisions, but this becomes unsafe with user-chosen paths. | Render to a unique sibling temporary file, verify it, then commit the result with recoverable replacement. |
| Timing | Workspace frame rate is an integer; J currently steps backward while L plays forward. | Explicit frame/timecode semantics; investigate fractional-rate accuracy and make transport behavior truthful and consistent. |
| Desktop window | Native minimum size, DPI handling and guarded close already exist. | Preserve these; add placement/workspace restoration and verify monitor/DPI transitions. |

Existing foundations to reuse and strengthen: ordered undo history, linked clips, groups/compounds, adjustment layers, source proxies, cached composite/audio previews, timeline virtualization, snapping, work areas, keyframe curves, effect stacks, audio mixing/loudness, scopes, subtitle quality checks, local save queues, temporary/backup project recovery, export cancellation and output probing. These are not all missing features. Their accessibility, integration and native behavior need work.

## Workspace and visual design

```text
Project name / saved state          File  Edit  View  Help          Export
-----------------------------------------------------------------------
Media / Effects / Captions  |                 | Selection inspector
Search, bins, assets       | Timeline viewer | Properties / Animation
Source details and ranges |                 | Contextual controls
                          | Transport       | Advanced sections
------------------------- draggable divider ---------------------------
Editing tools / snapping / keyframe navigation           Timeline zoom
Track names and controls  | Ruler, work area, markers
Video and overlay tracks  | Clips, thumbnails, fades and keyframes
Text and caption tracks   | Cues and titles
Audio tracks              | Waveforms and gain
-----------------------------------------------------------------------
Selection / time information                      Background job status
```

- Default side panels approximately 240–280 pixels left and 280–340 right, constrained by available width. The viewer uses the remaining space; no fixed mobile preview maximum.
- Horizontal and vertical splitters have visible hover feedback, resize cursors, minimum sizes and double-click reset. Save panel widths, timeline height and collapsed state as local preferences, outside project undo history.
- At narrower widths, collapse the media panel first, then use a toggleable inspector. Preserve viewer and timeline usability. Do not squeeze three panels below their usable minimums or fall back to a stretched phone dock.
- Large windows can show a source viewer alongside the timeline viewer when requested. Compact windows use a source/timeline viewer tab, with independent playheads and clear focus.
- Give the timeline a practical initial height with room for several tracks. Users can enlarge it, maximize the viewer or reset the workspace without losing selection, zoom or playback position.
- Use consistent spacing, readable text, restrained accent color, strong selection contrast and descriptive tooltips. Reserve persistent warning color for actionable problems. Job activity belongs in a status area, not over the canvas.
- Keep Windows title-bar behavior and system scaling. Restore window placement onto an available monitor, including after disconnecting a display.

## Feature organization

One primary home for each feature; context menus and keyboard shortcuts invoke the same command rather than implementing separate versions of the feature.

| Home | Responsibilities |
| --- | --- |
| Project header / File | Project lifecycle, save state, import, portable project operations, delivery. |
| Media panel | Local assets, search/bins, source information, import/download activity, missing-media resolution. |
| Effects library | Searchable visual/audio effects, transitions and motion presets; apply to the intended compatible selection. |
| Captions panel | Select source or existing caption track, generate when needed, edit/search cues, style, timing and quality checks. |
| Inspector | Selected clip/track properties, transform/crop, timing, audio, effects and animation. Show only relevant sections. |
| Viewer controls | Playback, viewer fit/zoom, safe guides and canvas configuration. Canvas configuration has one visible home. |
| Timeline toolbar | Editing mode, undo/redo, snapping, ripple/linked-selection state, previous/next keyframe, view and zoom controls. |
| Timeline context menus | Short selection-specific actions: split, duplicate, delete, link/group, properties; track-specific controls on track headers. |
| Status / jobs | Background processing, progress, cancellation, retries and concise actionable errors. |

Advanced color, curve, effect and audio editors should use the inspector or an appropriately sized desktop dialog. Extract reusable control content from existing sheets so mobile sheets and desktop panels share editing logic. Do not simply put a phone bottom sheet in the inspector or create nested panels for single actions such as chroma key.

## Implementation phases

### 1. Desktop foundation and timeline geometry

- Introduce a desktop workspace component and platform/input-aware layout policy. Keep mobile layout behavior separate.
- Implement resizable/collapsible panels, workspace reset and persistent local layout preferences with validated/clamped values.
- Fix full-width timeline geometry, ruler/background coverage and scrolling constraints. Keep horizontal and vertical virtualization, stable clip keys and selection through rebuilds.
- Add named track headers, direct track controls, clear selected/locked states and a sensible row-height control.
- Organize the timeline toolbar into stable groups with zoom controls at the right. Preserve every existing capability through the feature map, without a generic long “More” menu.
- Make horizontal/vertical scrollbars visible and draggable for mouse users. Wheel scrolls tracks, Shift+wheel scrolls time, Ctrl+wheel zooms around the pointer. Keep touchpad scrolling usable and avoid intercepting inspector scrolls.

Acceptance: no overflow or clipped timeline at minimum supported size, 1280×800, 1366×768, 1920×1080 and ultrawide sizes; short, long and empty projects all occupy the viewport correctly; repeated split resizing does not reset editor state.

### 2. Shared commands and mouse timeline editing

- Establish shared command definitions: identifiers, labels, shortcuts, enabled-state rules and callbacks. Preserve existing chronological undo behavior across captions and timeline edits.
- Centralize clipboard state. Add cut/copy/paste, duplicate, split-selected, delete and ripple-delete with explicit multi-selection, linked-clip and locked-track semantics. Preserve relative timing and track relationships when pasting a selection.
- Add immediate mouse move/trim/reorder, edge hit areas with resize cursors, double-click to edit and right-click context menus at the pointer.
- Support Ctrl-click selection toggling, Shift selection/range behavior and background marquee selection. Dragging selected clips moves the intended selection; a click alone creates no undo entry.
- Preserve source bounds, snapping, linked audio, cross-track compatibility and auto-scroll during drag. Show the prospective edit while dragging. Escape restores the gesture's starting state, and one completed gesture produces one undo step.
- Expose existing precision/ripple operations properly. Audit roll/slip/slide and only expose modes whose model operations are complete; implement missing essential precision operations with source-bound tests.
- Add searchable shortcut help and consistent menu shortcut labels. Editable text fields retain their standard shortcuts. Disable background editor commands while a modal owns focus.

Acceptance: perform import, select, move, trim, split, duplicate, paste, ripple-delete and undo without touch holds. Exercise mixed subtitle/video/audio selections and locked tracks. Clipboard actions work from the same selection regardless of whether invoked by menu or keyboard.

### 3. Viewer handles and live inspector

- Show an outline on a hovered eligible element. Selection exposes corner/edge resize targets and a rotation handle, with appropriate directional cursors. Keep handles legible at viewer zoom levels and high DPI.
- Lock the active pointer and target clip for an interaction. Other layers, timeline selection and asynchronous preview refreshes must not steal the edit. Release ownership on completion/cancel, focus loss or target removal.
- Perform coordinate conversion through viewer zoom, letterboxing and the layer's rotation/scale. Use gesture-start state to avoid cumulative scaling drift.
- Support proportional resize with a fixed opposite anchor, Alt for center resize and Shift rotation snapping. Current transform stores uniform scale; do not accidentally introduce stretching through handles. Free stretch requires an explicit model/rendering extension, separate from crop.
- Put position, scale, rotation, opacity, crop/fit and reset in the inspector. Numeric entry supports keyboard commit/cancel and validates bounds. Changes update the canvas immediately and use the same undo transactions as handles.
- Provide layer selection through the timeline and an overlap chooser so an obscured object is still selectable. Locked/hidden items cannot be accidentally manipulated.
- Move keyframe editing into a proper Animation inspector: property channels, add/update/remove, previous/next, current-state indication, interpolation graph, presets and reset. Identify the interval affected by an easing change. Reuse the existing curve implementation and motion presets.

Acceptance: resize and rotate base video, an overlay, text and captions on an overlapping composition at multiple viewer zooms. Verify anchor stability, focus loss, Escape, undo/redo and keyframed transforms. Export a reference frame and compare positioning to preview.

### 4. Media pool and project portability

- Batch-import supported video, audio and image files into an asset pool. Support Explorer drops using an established maintained integration; inspect its native behavior before adoption.
- Probe asynchronously with bounded concurrency. Show per-file progress/failure and continue importing valid files if one is unsupported. Avoid duplicate probing and main-thread directory scans.
- Add asset search, type filtering, simple bins, thumbnails, duration/resolution/audio metadata and usage indicators. Remove-from-pool must not silently delete source files.
- Open assets in the source viewer, mark a source In/Out range and insert/append it deliberately. Dragging an asset onto the timeline shows its destination and respects compatible/locked tracks.
- On project open, identify offline assets and expose a clear relink list. Relink updates all references to the same asset while preserving source trim, effects, keyframes and linked audio. Match candidates using more than filename alone; ambiguity requires a deliberate choice.
- Keep “Replace footage” distinct: it may change source identity/duration and needs an explicit policy for clips that exceed the new source bounds.
- Add Save As/project duplication and a portable project file or collect-media package. Preserve relative references, use a versioned manifest, avoid overwriting sources and validate restored media. Reuse existing local save/recovery machinery.

Acceptance: import several mixed files, create multiple uses of one asset, save/reopen, move the source directory and relink without changing edits. Open a collected project from a different directory. Unsupported or missing media leaves the project editable.

### 5. Playback and background-job reliability

- Introduce per-job ownership for FFmpeg sessions, progress callbacks, cancellation and temporary paths. Export cancellation must stop only export-owned work; stale preview work must not update current state.
- Keep a bounded background queue with priorities for active playback and user-requested work. Coalesce obsolete preview requests and avoid simultaneous duplicate proxy/audio/waveform builds.
- Retain immediate source playback/fallback while preparing optimized audio or composite previews. Use the last valid preview where appropriate; expose concise status without a blocking preparation screen.
- Verify rapid seek, play/pause, source changes, reverse clips, speed changes, transitions, linked audio and multiple audio layers. Prevent stale seek completions, dead players and late callbacks after disposal.
- Audit supported Windows decoder formats. Use cached proxies for unsupported/expensive sources, with actionable failure state when fallback cannot be generated. Do not silently show an unexplained black viewer.
- Verify preview quality settings, source changes and cache invalidation. Export always resolves original media. Avoid deleting cache entries still used by playback or export.
- Define accurate project timebase/frame stepping, including fractional source rates and variable-frame-rate imports. Keep legacy projects compatible. Give transport commands accurate labels; reverse shuttle requires an actual supported implementation rather than relabeling backward frame steps.
- Surface source/proxy/cache and performance information on demand. Include job retry/cancel and memory/cache limits without flooding normal editing with diagnostics.

Acceptance: rapid edits and seeks during proxy/audio preparation stay interactive; cancellation leaves unrelated jobs running; failed/timeout jobs release resources and can be retried. Validate long-project A/V sync and preview/export timing on native Windows.

### 6. Delivery, recovery and finishing workflows

- Desktop export chooses a destination, filename, range and settings before render. Support entire timeline/work area and relevant resolution/frame-rate options, with clear source/canvas behavior.
- Protect source paths and existing outputs. Render to a separate temporary output, verify it, then finalize; cancellation or failure preserves an existing destination and removes only owned partial files.
- Keep disk-space checks for both output and temporary volumes. Handle read-only paths, Unicode/spaces, missing source media, unavailable codecs and disconnected output drives with useful recovery actions.
- Add a modest export job list with state, retry and reveal/open output. Snapshot each queued render's timeline/settings so subsequent edits cannot change its result. Enable concurrent editing only once render/job isolation is verified.
- Preserve guarded window close, queued autosaves and backup recovery. Clearly distinguish saved locally from cloud sync; cloud/network problems must not prevent local editing.
- Make captions practical for long projects: source/track selection, cue search/navigation, correction, timing, scoped style and quality warnings together. Generating again for an already-captioned source is an intentional replacement action.
- Expose audio mixing with readable track controls, meters, gain/pan/fades and existing effects. Keep keyframing and color controls attached to their selected scope and show that scope clearly.
- Finish empty states, loading/error transitions, keyboard focus order, tooltips, disabled-state explanations, text scaling and preferences/account navigation at desktop widths.

Acceptance: complete and cancel exports, retry failures, reveal results, reopen a recovered project and close during a save/render. Verify output video, audio, captions, keyframes and effects against the timeline, including a work-area render.

## Architecture and change boundaries

- Extract workspace, media pool, command routing, selection inspector and preview manipulation into focused components. Avoid expanding the already large editor screen into another monolithic desktop implementation.
- Share providers and editing operations across platforms; vary their presentation and pointer behavior. Keep platform-specific integrations behind services with testable interfaces.
- Persist editor preferences separately from project content. New project fields use backward-compatible defaults and explicit schema handling. Old projects must open without destructive migration.
- Treat a single gesture or logical command as one undoable transaction. Selection/view-only changes must not become project edits unless they change intentional project settings.
- Preserve the Android release snapshot and unrelated existing workspace changes. Desktop code and subsequent shared fixes belong to the next source state, not the already uploaded APK.
- Before adopting a new dependency, verify its maintained upstream, license, supported Windows behavior and release packaging. Prefer existing packages and native facilities where they meet the requirement.

## Verification and completion gates

1. **Automated behavior:** targeted widget/model/service tests for layout constraints, mouse drags, handles, clipboard, selection, locks, undo, relink, job isolation, destination protection and project migration. Run the full existing Flutter suite after shared changes and retain downloader/runtime checks when packaging changes.
2. **Visual checks:** capture the real desktop workspace with media, multiple tracks and a selected layer; inspect minimum/normal/large windows, expanded/collapsed panels and representative dialogs. Include mobile portrait and landscape regression captures.
3. **Native Windows build:** use the repository's verified native-dependency preparation; build a release bundle with every required DLL/runtime/asset. The previous native build was blocked by an incomplete dependency archive, so widget tests alone cannot satisfy this gate.
4. **Native editing session:** import several videos, images and audio; cut/reorder/trim, manipulate overlapping layers, add captions, adjust audio, keyframe a layer, save/close/reopen and export. Repeat core actions using shortcuts, context menus and pointer controls.
5. **Failure checks:** moved media, malformed file, slow download, rapid cancellation, denied output path, low storage simulation, stale background completion and close during work. Confirm recovery and absence of unrelated-job cancellation.
6. **Performance:** record fixture size, hardware and measurements for startup, seek latency, timeline drag/scroll and memory. Target responsive input during background work and smooth scrolling on the reference machine; investigate sustained frame-budget misses instead of claiming universal performance from screenshots. Include a short project, a 30-minute multitrack project and a dense caption/clip fixture.
7. **Display/input matrix:** 100%, 125%, 150% and 200% Windows scaling; window maximize/restore/snap; monitor changes where hardware permits; mouse, wheel and available touchpad. Unsupported physical test configurations are reported explicitly.
8. **Delivery evidence:** release build location, validation results, representative screenshots and a concise list of remaining limitations. Mark phases complete only after their acceptance checks pass. Do not call the editor daily-drivable while basic import/edit/save/export or cancellation checks remain unresolved.

## Priority decisions

The first implementation slice is desktop layout, timeline geometry and command/input foundations. Next are viewer handles and inspector, followed by media workflow and job isolation; delivery/recovery and full-session validation finish the work. Job isolation should be brought forward wherever it blocks reliable preview or export testing.

Source review, bins, portable projects and deliberate export destinations are included because they remove routine desktop workflow friction. Multicam, collaboration, advanced compositing-node systems, plugin hosting and automatic scene/beat intelligence are future extensions. They should not displace the core usability and reliability work above.
