// ignore_for_file: use_build_context_synchronously

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/editor_change_log_service.dart';
import '../../../core/utils/ffmpeg_service.dart';
import '../../../core/utils/firebase_service.dart';
import '../../../core/utils/giphy_service.dart';
import '../../../core/utils/media_import_service.dart';
import '../../../core/utils/subtitle_export_service.dart';
import '../../../core/utils/subtitle_quality_service.dart';
import '../../../shared/models/project_model.dart';
import '../../../shared/widgets/snack_bar_helper.dart';
import '../../auth/providers/auth_provider.dart';
import '../../home/providers/transcription_pipeline.dart';
import '../../home/screens/processing_screen.dart';
import '../../quota/providers/quota_provider.dart';
import '../../quota/screens/quota_exhausted_screen.dart';
import '../models/subtitle_entry.dart';
import '../models/subtitle_style_model.dart';
import '../models/timeline_models.dart';
import '../models/export_settings.dart';
import '../providers/editor_provider.dart';
import '../providers/playback_provider.dart';
import '../providers/subtitle_provider.dart';
import 'creator_lab_screen.dart';
import 'export_video_screen.dart';
import '../widgets/export_dialog.dart';
import '../widgets/subtitle_edit_modal.dart';
import '../widgets/subtitle_style_panel.dart';
import '../widgets/timeline_panel.dart';
import '../widgets/video_preview_panel.dart';

/// Main editor screen with 3-panel layout:
/// Video Preview (top-left), Style Panel (top-right), Timeline (bottom).
class EditorScreen extends ConsumerStatefulWidget {
  final Project project;

  const EditorScreen({super.key, required this.project});

  @override
  ConsumerState<EditorScreen> createState() => _EditorScreenState();
}

enum _CanvasAspectRatio { original, ratio16x9, ratio9x16, ratio1x1, ratio4x5 }

enum _BottomActionCategory { add, edit, effects, audio, canvas }

enum _BottomActionSubgroup {
  addMedia,
  addText,
  addTracks,
  editTiming,
  editTransform,
  editArrange,
  effectsLooks,
  effectsBlur,
  effectsMotion,
  audioMix,
  audioFades,
  audioEnhance,
  canvasFormat,
  canvasGuides,
  canvasStudio,
}

class _EditorScreenState extends ConsumerState<EditorScreen>
    with WidgetsBindingObserver {
  Timer? _saveDebounce;
  Timer? _remoteSaveDebounce;
  bool _isSavingProject = false;
  Project? _queuedProjectSnapshot;
  bool _queuedRemoteSync = false;
  String? _queuedUserUid;
  String _queuedChangeType = 'queued_editor_change';
  Future<void>? _activeProjectSave;
  DateTime? _lastSavedAt;
  Object? _localSaveError;
  bool _remoteSyncPending = false;
  bool _isClosing = false;
  bool _editorInitialized = false;
  bool _isInitializingEditor = true;
  Object? _editorInitializationError;
  String? _currentUserUid;
  late Project _projectSnapshot;
  _CanvasAspectRatio _canvasAspectRatio = _CanvasAspectRatio.original;
  _BottomActionCategory? _activeBottomCategory;
  _BottomActionSubgroup? _activeBottomSubgroup;
  final GlobalKey _previewKey = GlobalKey(debugLabel: 'editor-video-preview');
  bool _isPreviewFullscreen = false;
  bool _isGeneratingSubtitles = false;
  TimelineClip? _clipAttributeClipboard;

  @override
  void initState() {
    super.initState();
    _projectSnapshot = widget.project;
    _currentUserUid = ref.read(currentUserProvider)?.uid;
    _canvasAspectRatio = _canvasAspectRatioFromPreset(
      widget.project.timeline.canvasSettings.aspectRatioPreset,
    );
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeEditor();
    });
  }

  void _initializeEditor() {
    if (!mounted || _editorInitialized) return;

    try {
      final initialStyle = widget.project.editorGlobalStyle;
      final didNormalizeLegacyStyle =
          initialStyle.fontSize != widget.project.globalStyle.fontSize ||
          initialStyle.maxWidthFactor !=
              widget.project.globalStyle.maxWidthFactor;
      final didUpgradeProjectSchema =
          widget.project.projectSchemaVersion < Project.currentSchemaVersion;
      final initialTimeline = widget.project.timeline.mergeSubtitleEntries(
        subtitles: widget.project.subtitles,
        globalStyle: initialStyle,
      );

      ref
          .read(subtitleProvider.notifier)
          .initializeFromProject(
            entries: widget.project.subtitles,
            globalStyle: initialStyle,
          );
      ref
          .read(editorProvider.notifier)
          .loadProject(
            videoPath: widget.project.videoPath,
            projectId: widget.project.id,
            projectName: widget.project.name,
            timeline: initialTimeline,
          );
      _projectSnapshot = widget.project.copyWith(
        projectSchemaVersion: Project.currentSchemaVersion,
        globalStyle: initialStyle,
        timeline: initialTimeline,
      );

      if (!mounted) return;
      setState(() {
        _editorInitialized = true;
        _isInitializingEditor = false;
        _editorInitializationError = null;
      });
      if (didUpgradeProjectSchema) {
        _scheduleProjectSave(
          changeType: didNormalizeLegacyStyle
              ? 'subtitle_style_migrated'
              : 'project_schema_migrated',
        );
      }
    } catch (error, stackTrace) {
      debugPrint('Editor initialization failed: $error\n$stackTrace');
      if (!mounted) return;
      setState(() {
        _isInitializingEditor = false;
        _editorInitializationError = error;
      });
    }
  }

  @override
  void dispose() {
    // Riverpod invalidates ConsumerState.ref before State.dispose is invoked.
    // Provider listeners and PopScope keep this snapshot current while mounted,
    // so disposal must only use cached values.
    final finalSnapshot = _projectSnapshot;
    final userUid = _currentUserUid;
    _isClosing = true;
    _saveDebounce?.cancel();
    _remoteSaveDebounce?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    if (_isPreviewFullscreen) {
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    }
    unawaited(
      _saveProjectState(
        project: finalSnapshot,
        userUid: userUid,
        syncRemote: false,
        changeType: 'editor_disposed',
      ),
    );
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(
        _flushProjectSave(
          syncRemote: false,
          changeType: 'app_lifecycle_$state',
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    _currentUserUid = ref.watch(currentUserProvider)?.uid;
    if (!_editorInitialized) {
      return _buildEditorStartup();
    }

    final editorState = ref.watch(editorProvider);
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final selectedClip = _selectedClipFromState(editorState);

    ref.listen(subtitleProvider, (prev, next) {
      final entriesChanged = prev?.entries != next.entries;
      final styleChanged = prev?.globalStyle != next.globalStyle;
      if (entriesChanged || styleChanged) {
        _scheduleProjectSave(
          changeType: entriesChanged ? 'subtitles_changed' : 'style_changed',
        );
      }
    });
    ref.listen(editorProvider.select((state) => state.timeline), (prev, next) {
      if (prev != null && prev != next) {
        _scheduleProjectSave(changeType: 'timeline_changed');
      }
    });

    return PopScope(
      canPop: !_isPreviewFullscreen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _isPreviewFullscreen) {
          _setPreviewFullscreen(false);
          return;
        }
        if (didPop) {
          unawaited(
            _flushProjectSave(syncRemote: false, changeType: 'editor_popped'),
          );
        }
      },
      child: Scaffold(
        backgroundColor: kBackground,
        appBar: _isPreviewFullscreen ? null : _buildEditorToolbar(context),
        body: _isPreviewFullscreen
            ? _buildFullscreenPreview()
            : isLandscape
            ? _buildLandscape(context, selectedClip)
            : _buildPortrait(context, selectedClip),
      ),
    );
  }

  Widget _buildEditorStartup() {
    final error = _editorInitializationError;
    return Scaffold(
      backgroundColor: kBackground,
      appBar: AppBar(
        backgroundColor: kBackground,
        title: Text(
          widget.project.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: error == null
                ? const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 18),
                      Text(
                        'Opening editor…',
                        style: TextStyle(
                          color: kTextSecondary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.error_outline_rounded,
                        color: kError,
                        size: 40,
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'This project could not be prepared for editing.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: kTextPrimary,
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        error.toString().replaceFirst('Exception: ', ''),
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: kTextSecondary),
                      ),
                      const SizedBox(height: 20),
                      FilledButton.icon(
                        onPressed: _isInitializingEditor
                            ? null
                            : () {
                                setState(() {
                                  _isInitializingEditor = true;
                                  _editorInitializationError = null;
                                });
                                _initializeEditor();
                              },
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('Try again'),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  PreferredSizeWidget _buildEditorToolbar(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final compact = width < 560;
    final phoneToolbar = width < 480;
    final showAspect = width >= 640;

    return AppBar(
      toolbarHeight: 62,
      leadingWidth: 48,
      titleSpacing: 0,
      backgroundColor: kBackground,
      bottom: const PreferredSize(
        preferredSize: Size.fromHeight(1),
        child: Divider(height: 1),
      ),
      title: Row(
        children: [
          if (!phoneToolbar)
            Container(
              width: 31,
              height: 31,
              margin: const EdgeInsets.only(right: 10),
              decoration: BoxDecoration(
                color: kAccent,
                borderRadius: BorderRadius.circular(9),
              ),
              child: const Icon(
                Icons.content_cut_rounded,
                color: kOnAccent,
                size: 17,
              ),
            ),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.project.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: kTextPrimary,
                      fontSize: compact ? 13 : 15,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.25,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: _localSaveError != null
                              ? kError
                              : _isSavingProject
                              ? kWarning
                              : _remoteSyncPending
                              ? kInfo
                              : kSuccess,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(
                          _localSaveError != null
                              ? 'LOCAL SAVE FAILED'
                              : _isSavingProject
                              ? 'SAVING LOCALLY'
                              : _remoteSyncPending
                              ? 'LOCAL SAVED · SYNC PENDING'
                              : _lastSavedAt == null
                              ? 'AUTOSAVE READY'
                              : 'SAVED LOCALLY',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: kTextSecondary,
                            fontSize: 7.5,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.85,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      actions: [
        if (showAspect) ...[
          const SizedBox(width: 8),
          _buildAspectRatioPicker(),
        ],
        if (phoneToolbar)
          _compactToolbarButton(
            tooltip: 'Subtitle import and sidecar export',
            icon: Icons.more_horiz_rounded,
            onTap: _showExportActions,
          )
        else
          IconButton(
            tooltip: 'Subtitle import and sidecar export',
            onPressed: _showExportActions,
            icon: const Icon(Icons.more_horiz_rounded, size: 21),
          ),
        if (!phoneToolbar)
          IconButton(
            tooltip: 'Editor tools',
            onPressed: _showEditorToolsSheet,
            icon: const Icon(Icons.auto_awesome_mosaic_outlined, size: 20),
          ),
        if (phoneToolbar)
          _compactToolbarButton(
            tooltip: 'Editor tools',
            icon: Icons.auto_awesome_mosaic_outlined,
            onTap: _showEditorToolsSheet,
          ),
        if (phoneToolbar)
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: _compactToolbarButton(
              tooltip: 'Export video',
              icon: Icons.file_upload_outlined,
              onTap: _showExportDialog,
            ),
          )
        else
          Padding(
            padding: EdgeInsets.fromLTRB(0, 10, compact ? 8 : 12, 10),
            child: FilledButton.icon(
              onPressed: _showExportDialog,
              style: FilledButton.styleFrom(
                padding: EdgeInsets.symmetric(horizontal: compact ? 11 : 15),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              icon: const Icon(Icons.file_upload_outlined, size: 17),
              label: Text(compact ? 'Export' : 'Export master'),
            ),
          ),
      ],
    );
  }

  Widget _compactToolbarButton({
    required String tooltip,
    required IconData icon,
    required VoidCallback onTap,
    bool enabled = true,
  }) {
    return IconButton(
      tooltip: tooltip,
      onPressed: enabled ? onTap : null,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 38, height: 44),
      padding: EdgeInsets.zero,
      icon: Icon(icon, size: 19),
    );
  }

  void _showExportActions() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.40,
      ),
      backgroundColor: kSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) {
        final state = ref.read(subtitleProvider);
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                leading: const Icon(
                  Icons.movie_creation_outlined,
                  color: kAccent,
                ),
                title: const Text('Export video'),
                subtitle: const Text('Burn subtitles into video'),
                onTap: () {
                  Navigator.pop(context);
                  _showExportDialog();
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.subtitles_rounded,
                  color: kTextPrimary,
                ),
                title: const Text('Export SRT'),
                onTap: () async {
                  Navigator.pop(context);
                  if (state.entries.isEmpty) {
                    SnackBarHelper.showInfo(context, 'No subtitles to export');
                    return;
                  }
                  await _exportSubtitleFile('srt');
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.subtitles_outlined,
                  color: kTextPrimary,
                ),
                title: const Text('Export VTT'),
                onTap: () async {
                  Navigator.pop(context);
                  if (state.entries.isEmpty) {
                    SnackBarHelper.showInfo(context, 'No subtitles to export');
                    return;
                  }
                  await _exportSubtitleFile('vtt');
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.file_upload_rounded,
                  color: kTextPrimary,
                ),
                title: const Text('Import SRT / VTT'),
                onTap: () async {
                  Navigator.pop(context);
                  await _importSubtitleFile();
                },
              ),
              const SizedBox(height: 6),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showEditorToolsSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: kSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: FractionallySizedBox(
            heightFactor: 0.88,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 24),
              children: [
                Center(
                  child: Container(
                    width: 42,
                    height: 4,
                    decoration: BoxDecoration(
                      color: kBorder,
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                const Text(
                  'Editor tools',
                  style: TextStyle(
                    color: kTextPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Non-destructive tools for animation, finishing, and a faster timeline workflow.',
                  style: TextStyle(color: kTextSecondary, fontSize: 12),
                ),
                _toolSectionTitle('New editing features'),
                _toolTile(
                  sheetContext,
                  Icons.key_rounded,
                  'Keyframe opacity',
                  'Animate clip opacity at the playhead',
                  () => _addSelectedKeyframe(TimelineKeyframeProperty.opacity),
                ),
                _toolTile(
                  sheetContext,
                  Icons.zoom_in_rounded,
                  'Keyframe scale',
                  'Animate zooms and punch-ins',
                  () => _addSelectedKeyframe(TimelineKeyframeProperty.scale),
                ),
                _toolTile(
                  sheetContext,
                  Icons.open_with_rounded,
                  'Keyframe X position',
                  'Animate horizontal movement at the playhead',
                  () =>
                      _addSelectedKeyframe(TimelineKeyframeProperty.positionX),
                ),
                _toolTile(
                  sheetContext,
                  Icons.height_rounded,
                  'Keyframe Y position',
                  'Animate vertical movement at the playhead',
                  () =>
                      _addSelectedKeyframe(TimelineKeyframeProperty.positionY),
                ),
                _toolTile(
                  sheetContext,
                  Icons.rotate_right_rounded,
                  'Keyframe rotation',
                  'Animate rotation over time',
                  () => _addSelectedKeyframe(TimelineKeyframeProperty.rotation),
                ),
                _toolTile(
                  sheetContext,
                  Icons.volume_up_rounded,
                  'Keyframe volume',
                  'Create a volume automation point',
                  () => _addSelectedKeyframe(TimelineKeyframeProperty.volume),
                ),
                _toolTile(
                  sheetContext,
                  Icons.blur_on_rounded,
                  'Keyframe blur strength',
                  'Animate an enabled blur at the playhead',
                  () => _addSelectedKeyframe(
                    TimelineKeyframeProperty.blurStrength,
                  ),
                ),
                _toolTile(
                  sheetContext,
                  Icons.delete_sweep_rounded,
                  'Clear clip keyframes',
                  'Remove all animation points from the selected clip',
                  _clearSelectedKeyframes,
                ),
                _toolTile(
                  sheetContext,
                  Icons.pause_circle_outline_rounded,
                  'Toggle freeze frame',
                  'Hold the selected visual clip on its current frame',
                  _toggleSelectedFreezeFrame,
                ),
                _toolTile(
                  sheetContext,
                  Icons.vibration_rounded,
                  'Toggle stabilisation',
                  'Stabilise a video during final rendering',
                  () => _toggleSelectedClipFlag(
                    (clip) => clip.copyWith(stabilize: !clip.stabilize),
                    supports: (clip, _) => clip.type == TimelineTrackType.video,
                    unsupportedMessage: 'Stabilisation requires a video clip.',
                  ),
                ),
                _toolTile(
                  sheetContext,
                  Icons.noise_aware_rounded,
                  'Toggle noise reduction',
                  'Clean picture and/or sound during final rendering',
                  () => _toggleSelectedClipFlag(
                    (clip) => clip.copyWith(denoise: !clip.denoise),
                    supports: (clip, timeline) =>
                        clip.type == TimelineTrackType.video ||
                        timeline.clipHasAudio(clip),
                    unsupportedMessage:
                        'Noise reduction requires video or audio media.',
                  ),
                ),
                _toolTile(
                  sheetContext,
                  Icons.colorize_rounded,
                  'Chroma key settings',
                  'Remove a selected screen colour from visual media',
                  _openSelectedChromaKeySheet,
                ),
                _toolTile(
                  sheetContext,
                  Icons.record_voice_over_rounded,
                  'Toggle auto ducking',
                  'Lower music under captions and voice clips',
                  () => _toggleSelectedClipFlag(
                    (clip) => clip.copyWith(autoDuck: !clip.autoDuck),
                    supports: (clip, timeline) => timeline.clipHasAudio(clip),
                    unsupportedMessage: 'Auto ducking requires an audio clip.',
                  ),
                ),
                _toolTile(
                  sheetContext,
                  Icons.sticky_note_2_outlined,
                  'Add clip note',
                  'Keep an edit note attached to the clip',
                  _setSelectedClipNote,
                ),
                _toolTile(
                  sheetContext,
                  Icons.palette_outlined,
                  'Cycle clip colour',
                  'Colour-code clips for fast scanning',
                  _cycleSelectedClipColor,
                ),
                _toolTile(
                  sheetContext,
                  Icons.copy_all_rounded,
                  'Copy clip attributes',
                  'Copy transform, timing, audio, and effect settings',
                  _copyClipAttributes,
                ),
                _toolTile(
                  sheetContext,
                  Icons.content_paste_go_rounded,
                  'Paste clip attributes',
                  'Apply copied settings to the selected clips',
                  _pasteClipAttributes,
                ),
                _toolTile(
                  sheetContext,
                  Icons.call_split_rounded,
                  'Split every track',
                  'Cut all clips crossing the playhead together',
                  _splitEveryTrackAtPlayhead,
                ),
                _toolTile(
                  sheetContext,
                  Icons.music_note_rounded,
                  'Generate beat markers',
                  'Add a half-second beat grid across the composition',
                  _generateBeatMarkers,
                ),
                _toolTile(
                  sheetContext,
                  Icons.bookmark_add_outlined,
                  'Add chapter marker',
                  'Mark the current playhead as a chapter',
                  _addChapterMarker,
                ),
                _toolTile(
                  sheetContext,
                  Icons.tune_rounded,
                  'Set project frame rate',
                  'Choose 24, 25, 30, 50, or 60 fps snapping',
                  _chooseProjectFrameRate,
                ),
                _toolTile(
                  sheetContext,
                  Icons.clear_all_rounded,
                  'Clear all markers',
                  'Remove marker, beat, and chapter guides',
                  _clearAllMarkers,
                ),
                _toolSectionTitle('Editor workflow improvements'),
                _toolTile(
                  sheetContext,
                  Icons.select_all_rounded,
                  'Select all clips',
                  'Select every clip for batch actions',
                  _selectAllClips,
                ),
                _toolTile(
                  sheetContext,
                  Icons.deselect_rounded,
                  'Clear multi-selection',
                  'Return to a single-clip selection',
                  () {
                    final primaryClipId = ref
                        .read(editorProvider)
                        .selectedClipId;
                    final notifier = ref.read(editorProvider.notifier);
                    notifier.clearClipSelection();
                    if (primaryClipId != null) {
                      notifier.selectClip(primaryClipId);
                    }
                  },
                ),
                _toolTile(
                  sheetContext,
                  Icons.keyboard_double_arrow_left_rounded,
                  'Nudge selection one frame left',
                  'Precision alignment without dragging',
                  () => _nudgeSelectedClips(-1),
                ),
                _toolTile(
                  sheetContext,
                  Icons.keyboard_double_arrow_right_rounded,
                  'Nudge selection one frame right',
                  'Precision alignment without dragging',
                  () => _nudgeSelectedClips(1),
                ),
                _toolTile(
                  sheetContext,
                  Icons.edit_outlined,
                  'Rename selected track',
                  'Give a lane a useful production name',
                  _renameSelectedTrack,
                ),
                _toolTile(
                  sheetContext,
                  Icons.library_add_outlined,
                  'Duplicate selected track',
                  'Clone a lane and all of its clip settings',
                  _duplicateSelectedTrack,
                ),
                _toolTile(
                  sheetContext,
                  Icons.arrow_upward_rounded,
                  'Move selected track up',
                  'Reorder the layer stack one row',
                  () => _moveSelectedTrack(-1),
                ),
                _toolTile(
                  sheetContext,
                  Icons.arrow_downward_rounded,
                  'Move selected track down',
                  'Reorder the layer stack one row',
                  () => _moveSelectedTrack(1),
                ),
                _toolTile(
                  sheetContext,
                  Icons.unfold_less_rounded,
                  'Collapse all tracks',
                  'Make dense projects easier to scan',
                  () => ref
                      .read(editorProvider.notifier)
                      .setAllTracks(collapsed: true),
                ),
                _toolTile(
                  sheetContext,
                  Icons.unfold_more_rounded,
                  'Expand all tracks',
                  'Restore full-height lanes',
                  () => ref
                      .read(editorProvider.notifier)
                      .setAllTracks(collapsed: false),
                ),
                _toolTile(
                  sheetContext,
                  Icons.lock_rounded,
                  'Lock all tracks',
                  'Protect the current layout before polishing',
                  () => ref
                      .read(editorProvider.notifier)
                      .setAllTracks(locked: true),
                ),
                _toolTile(
                  sheetContext,
                  Icons.lock_open_rounded,
                  'Unlock all tracks',
                  'Resume editing every lane',
                  () => ref
                      .read(editorProvider.notifier)
                      .setAllTracks(locked: false),
                ),
                _toolTile(
                  sheetContext,
                  Icons.volume_off_rounded,
                  'Mute all tracks',
                  'Silence every audio-capable lane',
                  () => ref
                      .read(editorProvider.notifier)
                      .setAllTracks(muted: true),
                ),
                _toolTile(
                  sheetContext,
                  Icons.volume_up_rounded,
                  'Unmute all tracks',
                  'Restore every lane’s monitor audio',
                  () => ref
                      .read(editorProvider.notifier)
                      .setAllTracks(muted: false),
                ),
                _toolTile(
                  sheetContext,
                  Icons.access_time_rounded,
                  'Toggle timecode ruler',
                  'Switch between frame-aware and seconds labels',
                  () => _toggleWorkspace(
                    (settings) =>
                        settings.copyWith(showTimecode: !settings.showTimecode),
                  ),
                ),
                _toolTile(
                  sheetContext,
                  Icons.photo_library_outlined,
                  'Toggle thumbnails',
                  'Reduce visual noise on compact timelines',
                  () => _toggleWorkspace(
                    (settings) => settings.copyWith(
                      showThumbnails: !settings.showThumbnails,
                    ),
                  ),
                ),
                _toolTile(
                  sheetContext,
                  Icons.graphic_eq_rounded,
                  'Toggle waveforms',
                  'Show or hide audio amplitude guides',
                  () => _toggleWorkspace(
                    (settings) => settings.copyWith(
                      showWaveforms: !settings.showWaveforms,
                    ),
                  ),
                ),
                _toolTile(
                  sheetContext,
                  Icons.key_rounded,
                  'Toggle keyframe guides',
                  'Show or hide animation diamonds in clips',
                  () => _toggleWorkspace(
                    (settings) => settings.copyWith(
                      showKeyframes: !settings.showKeyframes,
                    ),
                  ),
                ),
                _toolTile(
                  sheetContext,
                  Icons.follow_the_signs_rounded,
                  'Toggle playhead follow',
                  'Keep the timeline centered during playback',
                  () => _toggleWorkspace(
                    (settings) => settings.copyWith(
                      autoFollowPlayhead: !settings.autoFollowPlayhead,
                    ),
                  ),
                ),
                _toolTile(
                  sheetContext,
                  Icons.text_fields_rounded,
                  'Toggle clip labels',
                  'Use a clean icon-and-envelope timeline view',
                  () => _toggleWorkspace(
                    (settings) => settings.copyWith(
                      showClipLabels: !settings.showClipLabels,
                    ),
                  ),
                ),
                _toolTile(
                  sheetContext,
                  Icons.grid_4x4_rounded,
                  'Toggle canvas grid',
                  'Use guides for consistent framing',
                  () => _updateCanvasSettings(
                    (settings) =>
                        settings.copyWith(showGrid: !settings.showGrid),
                  ),
                ),
                _toolTile(
                  sheetContext,
                  Icons.crop_free_rounded,
                  'Toggle safe areas',
                  'Preview social-platform title-safe margins',
                  () => _updateCanvasSettings(
                    (settings) => settings.copyWith(
                      showSafeAreas: !settings.showSafeAreas,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _toolSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 4),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(
          color: kAccent,
          fontSize: 10,
          fontWeight: FontWeight.w900,
          letterSpacing: 1.1,
        ),
      ),
    );
  }

  Widget _toolTile(
    BuildContext sheetContext,
    IconData icon,
    String title,
    String subtitle,
    VoidCallback onTap,
  ) {
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: kAccent.withValues(alpha: 0.11),
          borderRadius: BorderRadius.circular(9),
        ),
        child: Icon(icon, color: kAccent, size: 18),
      ),
      title: Text(
        title,
        style: const TextStyle(
          color: kTextPrimary,
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(color: kTextSecondary, fontSize: 11),
      ),
      onTap: () {
        Navigator.pop(sheetContext);
        onTap();
      },
    );
  }

  TimelineClip? _toolSelectedClip() {
    return _selectedClipFromState(ref.read(editorProvider));
  }

  bool _toggleSelectedClipFlag(
    TimelineClip Function(TimelineClip) mapper, {
    bool Function(TimelineClip clip, EditorTimeline timeline)? supports,
    String unsupportedMessage = 'This tool does not support the selected clip.',
  }) {
    final clip = _toolSelectedClip();
    if (clip == null) {
      SnackBarHelper.showInfo(context, 'Select a clip first.');
      return false;
    }
    final timeline = ref.read(editorProvider).timeline;
    if (supports != null && !supports(clip, timeline)) {
      SnackBarHelper.showInfo(context, unsupportedMessage);
      return false;
    }
    final changed = ref
        .read(editorProvider.notifier)
        .updateClip(clip.id, mapper);
    if (!changed) {
      SnackBarHelper.showInfo(context, 'Unlock the selected track first.');
    }
    return changed;
  }

  void _toggleSelectedFreezeFrame() {
    final clip = _toolSelectedClip();
    if (clip == null) {
      SnackBarHelper.showInfo(context, 'Select a video clip first.');
      return;
    }
    if (clip.type != TimelineTrackType.video &&
        clip.type != TimelineTrackType.gif) {
      SnackBarHelper.showInfo(
        context,
        'Freeze frame requires a video or animated GIF clip.',
      );
      return;
    }
    if (clip.freezeFrame) {
      _toggleSelectedClipFlag(
        (current) => current.copyWith(
          freezeFrame: false,
          clearFreezeFrameSourceTime: true,
        ),
      );
      return;
    }

    final position = ref.read(playbackProvider).position;
    if (position < clip.startTime || position > clip.endTime) {
      SnackBarHelper.showInfo(
        context,
        'Move the playhead inside the selected clip first.',
      );
      return;
    }
    final elapsedMs = (position - clip.startTime).inMilliseconds.clamp(
      0,
      clip.duration.inMilliseconds,
    );
    final forwardOffsetMs = (elapsedMs * clip.playbackRate).round();
    final declaredSpanMs = clip.sourceDuration.inMilliseconds;
    final spanMs = declaredSpanMs > 0
        ? declaredSpanMs
        : math.max(
            1,
            (clip.duration.inMilliseconds * clip.playbackRate).round(),
          );
    final sourceOffsetMs = clip.isReversed
        ? (spanMs - forwardOffsetMs - 1).clamp(0, math.max(0, spanMs - 1))
        : forwardOffsetMs.clamp(0, math.max(0, spanMs - 1));
    final sourceTime =
        clip.sourceStartTime + Duration(milliseconds: sourceOffsetMs.toInt());
    final changed = _toggleSelectedClipFlag(
      (current) => current.copyWith(
        freezeFrame: true,
        freezeFrameSourceTime: sourceTime,
      ),
      supports: (candidate, _) =>
          candidate.type == TimelineTrackType.video ||
          candidate.type == TimelineTrackType.gif,
      unsupportedMessage: 'Freeze frame requires video or animated GIF media.',
    );
    if (changed) {
      SnackBarHelper.showSuccess(
        context,
        'Frame held at ${_formatEditorDuration(sourceTime)}.',
      );
    }
  }

  Future<void> _openSelectedChromaKeySheet() async {
    final clip = _toolSelectedClip();
    if (clip == null || !clip.supportsVisualEffects) {
      SnackBarHelper.showInfo(context, 'Select visual media first.');
      return;
    }
    final track = _trackForClip(clip, ref.read(editorProvider));
    if (track == null || track.isLocked) {
      SnackBarHelper.showInfo(context, 'Unlock the selected track first.');
      return;
    }
    var liveClip = clip;
    const keyColors = [
      Color(0xFF00FF00),
      Color(0xFF00A651),
      Color(0xFF0000FF),
      Color(0xFFFF00FF),
      Color(0xFFFFFFFF),
      Color(0xFF000000),
    ];
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => StatefulBuilder(
        builder: (context, setSheetState) {
          void update(
            TimelineClip Function(TimelineClip current) mapper, {
            bool recordHistory = true,
          }) {
            _updateTimelineClip(liveClip, mapper, recordHistory: recordHistory);
            final latest = _clipById(liveClip.id, ref.read(editorProvider));
            if (latest != null) setSheetState(() => liveClip = latest);
          }

          return _buildEditorSheet(
            title: 'Chroma key',
            subtitle:
                'Live key preview; export uses the same colour with precise RGB-distance removal',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Remove screen colour'),
                  subtitle: const Text(
                    'Makes pixels close to the key colour transparent',
                  ),
                  value: liveClip.chromaKeyEnabled,
                  onChanged: (value) => update(
                    (current) => current.copyWith(chromaKeyEnabled: value),
                  ),
                ),
                const SizedBox(height: 12),
                _sheetSectionTitle('KEY COLOUR'),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: keyColors.map((color) {
                    final selected =
                        color.toARGB32() == liveClip.chromaKeyColor.toARGB32();
                    return Semantics(
                      label: 'Use ${_hexColor(color)} as chroma key',
                      button: true,
                      selected: selected,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(999),
                        onTap: () => update(
                          (current) => current.copyWith(
                            chromaKeyEnabled: true,
                            chromaKeyColor: color,
                          ),
                        ),
                        child: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: color,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: selected ? kAccent : kBorder,
                              width: selected ? 3 : 1,
                            ),
                          ),
                          child: selected
                              ? Icon(
                                  Icons.check_rounded,
                                  size: 20,
                                  color: color.computeLuminance() > 0.5
                                      ? Colors.black
                                      : Colors.white,
                                )
                              : null,
                        ),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 18),
                _sheetSliderHeader(
                  'Similarity',
                  '${(liveClip.chromaKeySimilarity * 100).round()}%',
                ),
                Slider(
                  value: liveClip.chromaKeySimilarity.clamp(0.01, 1.0),
                  min: 0.01,
                  max: 1,
                  divisions: 99,
                  label: '${(liveClip.chromaKeySimilarity * 100).round()}%',
                  onChangeStart: (_) => ref
                      .read(editorProvider.notifier)
                      .beginTimelineGestureEdit(),
                  onChanged: (value) => update(
                    (current) => current.copyWith(
                      chromaKeyEnabled: true,
                      chromaKeySimilarity: value,
                    ),
                    recordHistory: false,
                  ),
                  onChangeEnd: (_) => ref
                      .read(editorProvider.notifier)
                      .endTimelineGestureEdit(),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  String _hexColor(Color color) {
    final value = color.toARGB32() & 0xFFFFFF;
    return '#${value.toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }

  Future<void> _addSelectedKeyframe(TimelineKeyframeProperty property) async {
    final clip = _toolSelectedClip();
    if (clip == null) {
      SnackBarHelper.showInfo(context, 'Select a clip first.');
      return;
    }
    final timeline = ref.read(editorProvider).timeline;
    final isVolume = property == TimelineKeyframeProperty.volume;
    final isBlur = property == TimelineKeyframeProperty.blurStrength;
    if (isVolume && !timeline.clipHasAudio(clip)) {
      SnackBarHelper.showInfo(context, 'Volume keyframes require audio media.');
      return;
    }
    if (isBlur && !clip.blur.isEnabled) {
      SnackBarHelper.showInfo(context, 'Enable blur on this clip first.');
      return;
    }
    if (!isVolume && !isBlur && !clip.supportsVisualEffects) {
      SnackBarHelper.showInfo(
        context,
        'Transform keyframes require visual media.',
      );
      return;
    }
    final position = ref.read(playbackProvider).position;
    if (position < clip.startTime || position > clip.endTime) {
      SnackBarHelper.showInfo(
        context,
        'Move the playhead inside the selected clip.',
      );
      return;
    }
    final transform = clip.transformAt(position);
    final initialValue = switch (property) {
      TimelineKeyframeProperty.opacity => transform.opacity,
      TimelineKeyframeProperty.scale => transform.scale,
      TimelineKeyframeProperty.rotation => transform.rotation,
      TimelineKeyframeProperty.positionX => transform.offsetX,
      TimelineKeyframeProperty.positionY => transform.offsetY,
      TimelineKeyframeProperty.volume => clip.volumeAt(position),
      TimelineKeyframeProperty.blurStrength =>
        clip.blurAt(position).safeStrength,
    };
    final (minimum, maximum, divisions) = switch (property) {
      TimelineKeyframeProperty.opacity => (0.0, 1.0, 100),
      TimelineKeyframeProperty.scale => (0.2, 4.0, 190),
      TimelineKeyframeProperty.rotation => (-math.pi * 2, math.pi * 2, 144),
      TimelineKeyframeProperty.positionX => (
        -kTimelineDesignWidth / 2,
        kTimelineDesignWidth / 2,
        156,
      ),
      TimelineKeyframeProperty.positionY => (
        -kTimelineDesignHeight / 2,
        kTimelineDesignHeight / 2,
        144,
      ),
      TimelineKeyframeProperty.volume => (0.0, 2.0, 100),
      TimelineKeyframeProperty.blurStrength => (0.0, 30.0, 120),
    };
    var value = initialValue.clamp(minimum, maximum).toDouble();
    String formattedValue(double candidate) => switch (property) {
      TimelineKeyframeProperty.opacity ||
      TimelineKeyframeProperty.volume => '${(candidate * 100).round()}%',
      TimelineKeyframeProperty.scale => '${candidate.toStringAsFixed(2)}×',
      TimelineKeyframeProperty.rotation =>
        '${(candidate * 180 / math.pi).round()}°',
      TimelineKeyframeProperty.positionX ||
      TimelineKeyframeProperty.positionY => candidate.round().toString(),
      TimelineKeyframeProperty.blurStrength => candidate.toStringAsFixed(1),
    };
    final selectedValue = await showDialog<double>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('${property.name} keyframe'),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Value at ${_formatEditorDuration(position)}',
                  style: const TextStyle(color: kTextSecondary, fontSize: 12),
                ),
                const SizedBox(height: 12),
                Text(
                  formattedValue(value),
                  style: const TextStyle(
                    color: kTextPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Slider(
                  value: value,
                  min: minimum,
                  max: maximum,
                  divisions: divisions,
                  label: formattedValue(value),
                  onChanged: (next) => setDialogState(() => value = next),
                ),
                if (property == TimelineKeyframeProperty.volume)
                  const Text(
                    'Device preview monitors up to 100%; gain above 100% is applied in the export mix.',
                    style: TextStyle(color: kTextSecondary, fontSize: 11),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, value),
              child: const Text('Set keyframe'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || selectedValue == null) return;
    final ok = ref
        .read(editorProvider.notifier)
        .upsertKeyframe(
          clipId: clip.id,
          property: property,
          time: position - clip.startTime,
          value: selectedValue,
        );
    if (ok) {
      SnackBarHelper.showSuccess(context, '${property.name} keyframe added.');
    } else {
      SnackBarHelper.showInfo(context, 'Unlock the selected track first.');
    }
  }

  void _clearSelectedKeyframes() {
    final clip = _toolSelectedClip();
    if (clip == null) return;
    ref.read(editorProvider.notifier).removeKeyframes(clip.id);
  }

  Future<void> _setSelectedClipNote() async {
    final clip = _toolSelectedClip();
    if (clip == null) return;
    final controller = TextEditingController(text: clip.notes ?? '');
    final note = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clip note'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 4,
          decoration: const InputDecoration(
            hintText: 'What should you remember about this clip?',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('Save note'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (!mounted || note == null) return;
    ref
        .read(editorProvider.notifier)
        .updateClip(
          clip.id,
          (current) => note.trim().isEmpty
              ? current.copyWith(clearNotes: true)
              : current.copyWith(notes: note.trim()),
        );
  }

  void _cycleSelectedClipColor() {
    final clip = _toolSelectedClip();
    if (clip == null) return;
    const colors = [
      Color(0x00000000),
      Color(0xFF4F8CFF),
      Color(0xFF9B6DFF),
      Color(0xFFEF7187),
      Color(0xFFF4B942),
      Color(0xFF44C38A),
    ];
    final current = colors.indexWhere(
      (color) => color.toARGB32() == clip.timelineColor.toARGB32(),
    );
    final next = colors[(current + 1) % colors.length];
    ref
        .read(editorProvider.notifier)
        .updateClip(
          clip.id,
          (currentClip) => currentClip.copyWith(timelineColor: next),
        );
  }

  void _copyClipAttributes() {
    final clip = _toolSelectedClip();
    if (clip == null) return;
    setState(() => _clipAttributeClipboard = clip);
    SnackBarHelper.showInfo(context, 'Clip attributes copied.');
  }

  void _pasteClipAttributes() {
    final source = _clipAttributeClipboard;
    final editorState = ref.read(editorProvider);
    if (source == null || editorState.selectedClipIds.isEmpty) {
      SnackBarHelper.showInfo(
        context,
        'Copy clip attributes first, then select clips.',
      );
      return;
    }
    final selected = editorState.selectedClipIds;
    final timeline = editorState.timeline;
    final sourceHasAudio = timeline.clipHasAudio(source);
    final sourceIsFilterEffect =
        source.isEffect && source.effectKind == TimelineEffectKind.filter;
    final sourceIsBlurEffect =
        source.isEffect && source.effectKind == TimelineEffectKind.blur;
    final tracks = editorState.timeline.tracks.map((track) {
      if (track.isLocked) return track;
      return track.copyWith(
        clips: track.clips.map((clip) {
          if (!selected.contains(clip.id)) return clip;

          final targetHasAudio = timeline.clipHasAudio(clip);
          final targetIsFilterEffect =
              clip.isEffect && clip.effectKind == TimelineEffectKind.filter;
          final targetIsBlurEffect =
              clip.isEffect && clip.effectKind == TimelineEffectKind.blur;
          final copyFullTransform =
              source.supportsVisualEffects && clip.supportsVisualEffects;
          final copyBasicTransform =
              source.supportsTransform && clip.supportsTransform;
          final copyVisualSettings = copyFullTransform;
          final copyColor =
              (source.supportsVisualEffects || sourceIsFilterEffect) &&
              (clip.supportsVisualEffects || targetIsFilterEffect);
          final copyBlur =
              (source.supportsVisualEffects || sourceIsBlurEffect) &&
              (clip.supportsVisualEffects || targetIsBlurEffect);
          final copyAudio = sourceHasAudio && targetHasAudio;
          final copySourceTiming =
              source.supportsSourceTiming && clip.supportsSourceTiming;
          final copyTransitions =
              source.supportsClipAnimation && clip.supportsClipAnimation;
          final copyFreeze =
              (source.type == TimelineTrackType.video ||
                  source.type == TimelineTrackType.gif) &&
              (clip.type == TimelineTrackType.video ||
                  clip.type == TimelineTrackType.gif);
          final copyDenoise =
              (source.type == TimelineTrackType.video || sourceHasAudio) &&
              (clip.type == TimelineTrackType.video || targetHasAudio);

          final copiedKeyframeProperties = <TimelineKeyframeProperty>{
            if (copyFullTransform) ...[
              TimelineKeyframeProperty.opacity,
              TimelineKeyframeProperty.scale,
              TimelineKeyframeProperty.rotation,
              TimelineKeyframeProperty.positionX,
              TimelineKeyframeProperty.positionY,
            ],
            if (copyAudio) TimelineKeyframeProperty.volume,
            if (copyBlur) TimelineKeyframeProperty.blurStrength,
          };
          final nextKeyframes = clip.keyframes
              .where(
                (keyframe) =>
                    !copiedKeyframeProperties.contains(keyframe.property),
              )
              .toList();
          final copiedFramesByPropertyAndTime = <String, TimelineKeyframe>{};
          for (final keyframe in source.keyframes) {
            if (!copiedKeyframeProperties.contains(keyframe.property)) {
              continue;
            }
            final timeMs = keyframe.time.inMilliseconds
                .clamp(0, math.max(0, clip.duration.inMilliseconds))
                .toInt();
            copiedFramesByPropertyAndTime['${keyframe.property.name}:$timeMs'] =
                TimelineKeyframe(
                  time: Duration(milliseconds: timeMs),
                  property: keyframe.property,
                  value: keyframe.value,
                );
          }
          nextKeyframes.addAll(copiedFramesByPropertyAndTime.values);
          nextKeyframes.sort((a, b) => a.time.compareTo(b.time));

          var nextTransform = clip.transform;
          if (copyFullTransform) {
            nextTransform = source.transform;
          } else if (copyBasicTransform) {
            nextTransform = clip.transform.copyWith(
              offsetX: source.transform.offsetX,
              offsetY: source.transform.offsetY,
              scale: source.transform.scale,
            );
          }

          Duration? nextFreezeSourceTime = clip.freezeFrameSourceTime;
          if (copyFreeze) {
            if (!source.freezeFrame) {
              nextFreezeSourceTime = null;
            } else {
              final sourceSpanMs = math.max(
                1,
                source.sourceDuration.inMilliseconds > 0
                    ? source.sourceDuration.inMilliseconds
                    : (source.duration.inMilliseconds * source.playbackRate)
                          .round(),
              );
              final sourceOffsetMs =
                  (source.effectiveFreezeFrameSourceTime -
                          source.sourceStartTime)
                      .inMilliseconds
                      .clamp(0, sourceSpanMs - 1);
              final relativeOffset = sourceOffsetMs / sourceSpanMs;
              final targetSpanMs = math.max(
                1,
                clip.sourceDuration.inMilliseconds > 0
                    ? clip.sourceDuration.inMilliseconds
                    : (clip.duration.inMilliseconds * clip.playbackRate)
                          .round(),
              );
              nextFreezeSourceTime =
                  clip.sourceStartTime +
                  Duration(
                    milliseconds: (relativeOffset * (targetSpanMs - 1)).round(),
                  );
            }
          }

          return clip.copyWith(
            transform: nextTransform,
            audioMix: copyAudio ? source.audioMix : clip.audioMix,
            fitMode: copyVisualSettings ? source.fitMode : clip.fitMode,
            playbackRate: copySourceTiming
                ? source.playbackRate
                : clip.playbackRate,
            isReversed: copySourceTiming && clip.supportsReversePlayback
                ? source.isReversed
                : clip.isReversed,
            crop: copyVisualSettings ? source.crop : clip.crop,
            blur: copyBlur ? source.blur : clip.blur,
            colorAdjustments: copyColor
                ? source.colorAdjustments
                : clip.colorAdjustments,
            introTransition: copyTransitions
                ? source.introTransition
                : clip.introTransition,
            outroTransition: copyTransitions
                ? source.outroTransition
                : clip.outroTransition,
            keyframes: nextKeyframes,
            freezeFrame: copyFreeze ? source.freezeFrame : clip.freezeFrame,
            freezeFrameSourceTime: nextFreezeSourceTime,
            clearFreezeFrameSourceTime:
                copyFreeze && nextFreezeSourceTime == null,
            stabilize:
                source.type == TimelineTrackType.video &&
                    clip.type == TimelineTrackType.video
                ? source.stabilize
                : clip.stabilize,
            denoise: copyDenoise ? source.denoise : clip.denoise,
            chromaKeyEnabled: copyVisualSettings
                ? source.chromaKeyEnabled
                : clip.chromaKeyEnabled,
            chromaKeyColor: copyVisualSettings
                ? source.chromaKeyColor
                : clip.chromaKeyColor,
            chromaKeySimilarity: copyVisualSettings
                ? source.chromaKeySimilarity
                : clip.chromaKeySimilarity,
            timelineColor: source.timelineColor,
            autoDuck: copyAudio ? source.autoDuck : clip.autoDuck,
            duckAmount: copyAudio ? source.duckAmount : clip.duckAmount,
          );
        }).toList(),
      );
    }).toList();
    ref
        .read(editorProvider.notifier)
        .setTimeline(editorState.timeline.copyWith(tracks: tracks));
  }

  void _splitEveryTrackAtPlayhead() {
    final position = ref.read(playbackProvider).position;
    final ids = ref
        .read(editorProvider)
        .timeline
        .tracks
        .expand((track) => track.clips)
        .where((clip) => clip.startTime < position && clip.endTime > position)
        .map((clip) => clip.id)
        .toList();
    final notifier = ref.read(editorProvider.notifier);
    notifier.beginTimelineGestureEdit();
    try {
      for (final id in ids) {
        final live = _clipById(id, ref.read(editorProvider));
        if (live != null) _splitClipAtPlayhead(live);
      }
    } finally {
      notifier.endTimelineGestureEdit();
    }
    if (ids.isEmpty) {
      SnackBarHelper.showInfo(context, 'No clips cross the playhead.');
    }
  }

  void _generateBeatMarkers() {
    final timeline = ref.read(editorProvider).timeline;
    final duration = timeline.duration;
    if (duration <= Duration.zero) return;
    final markers = [...timeline.markers];
    for (var ms = 0; ms <= duration.inMilliseconds; ms += 500) {
      if (markers.any(
        (marker) =>
            marker.type == TimelineMarkerType.beat &&
            (marker.position.inMilliseconds - ms).abs() < 40,
      )) {
        continue;
      }
      markers.add(
        TimelineMarker(
          position: Duration(milliseconds: ms),
          label: 'Beat ${ms ~/ 500 + 1}',
          type: TimelineMarkerType.beat,
          color: const Color(0xFF67E8F9),
        ),
      );
    }
    ref
        .read(editorProvider.notifier)
        .setTimeline(
          timeline.copyWith(
            markers: markers..sort((a, b) => a.position.compareTo(b.position)),
          ),
        );
  }

  void _addChapterMarker() {
    final timeline = ref.read(editorProvider).timeline;
    final position = ref.read(playbackProvider).position;
    final marker = TimelineMarker(
      position: position,
      label:
          'Chapter ${timeline.markers.where((marker) => marker.type == TimelineMarkerType.chapter).length + 1}',
      type: TimelineMarkerType.chapter,
      color: const Color(0xFFF59E0B),
    );
    ref
        .read(editorProvider.notifier)
        .setTimeline(timeline.copyWith(markers: [...timeline.markers, marker]));
  }

  void _clearAllMarkers() {
    final timeline = ref.read(editorProvider).timeline;
    if (timeline.markers.isEmpty) return;
    ref
        .read(editorProvider.notifier)
        .setTimeline(timeline.copyWith(markers: const []));
  }

  Future<void> _chooseProjectFrameRate() async {
    final current = ref
        .read(editorProvider)
        .timeline
        .workspaceSettings
        .frameRate;
    final selected = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Project frame rate'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final rate in const [24, 25, 30, 50, 60])
              ListTile(
                leading: Icon(
                  rate == current
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  color: rate == current ? kAccent : kTextSecondary,
                ),
                title: Text('$rate fps'),
                onTap: () => Navigator.pop(dialogContext, rate),
              ),
          ],
        ),
      ),
    );
    if (!mounted || selected == null) return;
    _toggleWorkspace((settings) => settings.copyWith(frameRate: selected));
  }

  void _selectAllClips() {
    final ids = ref
        .read(editorProvider)
        .timeline
        .tracks
        .expand((track) => track.clips)
        .map((clip) => clip.id);
    ref.read(editorProvider.notifier).selectClipIds(ids);
  }

  void _nudgeSelectedClips(int direction) {
    final editorState = ref.read(editorProvider);
    final selected = editorState.selectedClipIds;
    if (selected.isEmpty) return;
    final frameMs = math.max(
      1,
      (1000 / editorState.timeline.workspaceSettings.frameRate).round(),
    );
    final requestedDeltaMs = frameMs * direction;
    final movableClips = editorState.timeline.tracks
        .where((track) => !track.isLocked)
        .expand((track) => track.clips)
        .where((clip) => selected.contains(clip.id))
        .toList();
    if (movableClips.isEmpty) return;
    final earliestStartMs = movableClips
        .map((clip) => clip.startTime.inMilliseconds)
        .reduce(math.min);
    // Clamp the group once so clips at zero do not collapse spacing between
    // independently-clamped selected clips.
    final effectiveDeltaMs = math.max(requestedDeltaMs, -earliestStartMs);
    if (effectiveDeltaMs == 0) return;
    final nextTracks = editorState.timeline.tracks.map((track) {
      if (track.isLocked) return track;
      return track.copyWith(
        clips: track.clips.map((clip) {
          if (!selected.contains(clip.id)) return clip;
          final start = clip.startTime.inMilliseconds + effectiveDeltaMs;
          return clip.copyWith(
            startTime: Duration(milliseconds: start),
            endTime: Duration(
              milliseconds: start + clip.duration.inMilliseconds,
            ),
          );
        }).toList(),
      );
    }).toList();
    final nextTimeline = editorState.timeline.copyWith(tracks: nextTracks);
    ref.read(editorProvider.notifier).setTimeline(nextTimeline);
    ref
        .read(subtitleProvider.notifier)
        .syncFromTimeline(nextTimeline.subtitleEntries);
  }

  Future<void> _renameSelectedTrack() async {
    final editorState = ref.read(editorProvider);
    final track = editorState.timeline.tracks
        .where((candidate) => candidate.id == editorState.selectedTrackId)
        .firstOrNull;
    if (track == null) return;
    final controller = TextEditingController(text: track.name);
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rename track'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (!mounted || name == null) return;
    ref.read(editorProvider.notifier).renameTrack(track.id, name);
  }

  void _duplicateSelectedTrack() {
    final trackId = ref.read(editorProvider).selectedTrackId;
    if (trackId == null) return;
    ref.read(editorProvider.notifier).duplicateTrack(trackId);
  }

  void _moveSelectedTrack(int direction) {
    final trackId = ref.read(editorProvider).selectedTrackId;
    if (trackId == null) return;
    ref.read(editorProvider.notifier).reorderTrack(trackId, direction);
  }

  void _toggleWorkspace(
    TimelineWorkspaceSettings Function(TimelineWorkspaceSettings current)
    mapper,
  ) {
    ref.read(editorProvider.notifier).setWorkspaceSettings(mapper);
  }

  Future<void> _exportSubtitleFile(String format) async {
    final state = ref.read(subtitleProvider);
    String? generatedPath;
    try {
      generatedPath = format == 'srt'
          ? await SubtitleExportService.generateSrt(state.entries)
          : await SubtitleExportService.generateVtt(state.entries);

      final generatedFile = File(generatedPath);
      if (!await generatedFile.exists() || await generatedFile.length() == 0) {
        throw Exception(
          'Generated ${format.toUpperCase()} file is empty. Cannot export.',
        );
      }

      final savePath = await _resolveSubtitleExportPath(format);
      if (savePath == null) return;

      final outputFile = File(savePath);
      final bytes = await generatedFile.readAsBytes();
      if (await outputFile.exists()) {
        await outputFile.delete();
      }
      await outputFile.create(recursive: true);
      await outputFile.writeAsBytes(bytes, flush: true);

      final outputSize = await outputFile.length();
      if (outputSize == 0) {
        throw Exception(
          '${format.toUpperCase()} export failed (0 KB output file).',
        );
      }

      if (!mounted) return;
      SnackBarHelper.showSuccess(
        context,
        '${format.toUpperCase()} exported to:\n$savePath',
      );
    } catch (e) {
      if (!mounted) return;
      SnackBarHelper.showError(context, 'Export failed: $e');
    } finally {
      if (generatedPath != null) {
        try {
          final temporaryFile = File(generatedPath);
          if (await temporaryFile.exists()) await temporaryFile.delete();
        } catch (_) {
          // The delivered subtitle file is independent from its temp source.
        }
      }
    }
  }

  Future<String?> _resolveSubtitleExportPath(String format) async {
    final safeProjectName = _safeProjectName();
    final fileName = '${safeProjectName}_subtitles.$format';

    if (Platform.isAndroid || Platform.isIOS) {
      final Directory baseDir = Platform.isAndroid
          ? (await getExternalStorageDirectory() ??
                await getApplicationDocumentsDirectory())
          : await getApplicationDocumentsDirectory();

      final exportDir = Directory(
        path.join(baseDir.path, 'CaptionCraft', 'exports'),
      );
      if (!await exportDir.exists()) {
        await exportDir.create(recursive: true);
      }
      return path.join(exportDir.path, fileName);
    }

    final picked = await FilePicker.platform.saveFile(
      dialogTitle: 'Save ${format.toUpperCase()} file',
      fileName: fileName,
      type: FileType.custom,
      allowedExtensions: [format],
    );
    if (picked == null) return null;

    // Some Android storage providers return content:// URIs; fallback to app export dir.
    if (picked.startsWith('content://')) {
      final fallbackDir = await getApplicationDocumentsDirectory();
      final exportDir = Directory(path.join(fallbackDir.path, 'exports'));
      if (!await exportDir.exists()) {
        await exportDir.create(recursive: true);
      }
      return path.join(exportDir.path, fileName);
    }

    return picked;
  }

  Future<void> _importSubtitleFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['srt', 'vtt'],
        allowMultiple: false,
      );

      if (result == null || result.files.isEmpty) return;
      final filePath = result.files.first.path;
      if (filePath == null) return;
      final subtitleFile = File(filePath);
      if (!await subtitleFile.exists()) {
        throw Exception('The selected subtitle file is no longer available.');
      }
      if (await subtitleFile.length() > 10 * 1024 * 1024) {
        throw Exception('Subtitle files must be smaller than 10 MB.');
      }

      final lowerPath = filePath.toLowerCase();
      final parsedEntries = lowerPath.endsWith('.vtt')
          ? await SubtitleExportService.importVtt(filePath)
          : await SubtitleExportService.importSrt(filePath);

      if (parsedEntries.isEmpty) {
        if (!mounted) return;
        SnackBarHelper.showWarning(context, 'No subtitles found in file');
        return;
      }

      final editorState = ref.read(editorProvider);
      final compositionDuration =
          editorState.timeline.baseVideoDuration > Duration.zero
          ? editorState.timeline.baseVideoDuration
          : _projectSnapshot.duration;
      final entries = SubtitleExportService.clampEntriesToDuration(
        parsedEntries,
        compositionDuration,
      );
      if (entries.isEmpty) {
        if (!mounted) return;
        SnackBarHelper.showWarning(
          context,
          'No imported subtitles overlap this project.',
        );
        return;
      }

      final imported = ref
          .read(editorProvider.notifier)
          .replaceSubtitleEntries(entries);
      if (!imported) {
        if (!mounted) return;
        SnackBarHelper.showInfo(
          context,
          'Unlock the subtitle track before importing captions.',
        );
        return;
      }
      _scheduleProjectSave(immediate: true, changeType: 'subtitles_imported');
      if (!mounted) return;
      SnackBarHelper.showSuccess(
        context,
        entries.length == parsedEntries.length
            ? 'Imported ${entries.length} subtitles'
            : 'Imported ${entries.length}; skipped cues outside the project',
      );
    } catch (e) {
      if (!mounted) return;
      SnackBarHelper.showError(context, 'Import failed: $e');
    }
  }

  void _showExportDialog() {
    showDialog(
      context: context,
      builder: (_) => ExportDialog(
        onExport: (settings) {
          Navigator.pop(context);
          unawaited(_openExportVideoScreen(settings));
        },
      ),
    );
  }

  Future<void> _openExportVideoScreen(ExportSettings settings) async {
    final subtitleState = ref.read(subtitleProvider);
    final editorState = ref.read(editorProvider);
    final timeline = editorState.timeline.mergeSubtitleEntries(
      subtitles: subtitleState.entries,
      globalStyle: subtitleState.globalStyle,
    );
    final projectSnapshot = _projectSnapshot.copyWith(
      subtitles: List<SubtitleEntry>.from(subtitleState.entries),
      globalStyle: subtitleState.globalStyle,
      timeline: timeline,
      lastModifiedAt: DateTime.now(),
    );
    final exportedPath = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => ExportVideoScreen(
          project: projectSnapshot,
          timeline: timeline,
          settings: settings,
          entries: List<SubtitleEntry>.from(subtitleState.entries),
          globalStyle: subtitleState.globalStyle,
        ),
      ),
    );
    if (!mounted) return;
    final persistedProject = await ProjectLocalStorage.loadProject(
      widget.project.id,
      ownerUid: _projectSnapshot.ownerUid ?? _currentUserUid,
    );
    if (persistedProject != null) {
      _projectSnapshot = persistedProject;
    } else if (exportedPath != null) {
      _projectSnapshot = projectSnapshot.copyWith(
        lastExportPath: exportedPath,
        lastModifiedAt: DateTime.now(),
      );
    }
  }

  Future<void> _handleGenerateSubtitles() async {
    if (_isGeneratingSubtitles) return;
    setState(() => _isGeneratingSubtitles = true);
    try {
      final quota = ref.read(quotaProvider);
      if (!quota.canRun) {
        if (!mounted) return;
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const QuotaExhaustedScreen()),
        );
        return;
      }

      final timeline = ref.read(editorProvider).timeline;
      final targetClip = await _chooseCaptionSourceClip(timeline);
      if (targetClip == null || !mounted) return;

      await _generateSubtitlesForMediaClip(targetClip, timeline);
    } finally {
      if (mounted) {
        setState(() => _isGeneratingSubtitles = false);
      } else {
        _isGeneratingSubtitles = false;
      }
    }
  }

  Future<TimelineClip?> _chooseCaptionSourceClip(
    EditorTimeline timeline,
  ) async {
    final captionSources =
        timeline.tracks
            .expand((track) => track.clips)
            .where((clip) => timeline.clipHasAudio(clip))
            .toList()
          ..sort((a, b) {
            final startCompare = a.startTime.compareTo(b.startTime);
            if (startCompare != 0) return startCompare;
            return a.type.index.compareTo(b.type.index);
          });

    if (captionSources.isEmpty) {
      SnackBarHelper.showInfo(
        context,
        'Add a video or audio clip before generating captions.',
      );
      return null;
    }

    return showModalBottomSheet<TimelineClip>(
      context: context,
      backgroundColor: kSurface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.56,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),
              Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: kBorder,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                'Choose caption source',
                style: TextStyle(
                  color: kTextPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: captionSources.length,
                  separatorBuilder: (_, _) =>
                      const Divider(color: kBorder, height: 1),
                  itemBuilder: (_, index) {
                    final clip = captionSources[index];
                    final isAudio = clip.type == TimelineTrackType.audio;
                    return ListTile(
                      leading: Icon(
                        isAudio
                            ? Icons.graphic_eq_rounded
                            : Icons.movie_creation_outlined,
                        color: kTextPrimary,
                      ),
                      title: Text(
                        clip.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: kTextPrimary),
                      ),
                      subtitle: Text(
                        '${isAudio ? 'Audio' : 'Video'} • '
                        '${SubtitleEntry.formatDisplayTime(clip.startTime)} - '
                        '${SubtitleEntry.formatDisplayTime(clip.endTime)}',
                        style: TextStyle(color: kTextSecondary, fontSize: 12),
                      ),
                      onTap: () => Navigator.pop(context, clip),
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _generateSubtitlesForMediaClip(
    TimelineClip targetClip,
    EditorTimeline timeline,
  ) async {
    final existingSubtitleTrack = _resolveInsertionTrack(
      timeline,
      TimelineTrackSection.textSubtitle,
      TimelineTrackType.subtitle,
    );
    final hasExistingSubtitleTrack = timeline.tracks.any(
      (track) => track.type == TimelineTrackType.subtitle,
    );
    final subtitleTrack =
        existingSubtitleTrack ??
        (hasExistingSubtitleTrack
            ? null
            : _createOptionalTrack(
                timeline,
                TimelineTrackSection.textSubtitle,
                TimelineTrackType.subtitle,
              ));
    if (subtitleTrack == null ||
        subtitleTrack.isLocked ||
        !subtitleTrack.acceptsClipType(TimelineTrackType.subtitle)) {
      SnackBarHelper.showInfo(
        context,
        'Add or unlock a subtitle track before generating captions.',
      );
      return;
    }

    final user = ref.read(currentUserProvider);
    if (user == null) {
      SnackBarHelper.showError(context, 'Sign in to generate subtitles.');
      return;
    }

    EditorAssetReference? sourceAsset;
    for (final asset in timeline.assets) {
      if (asset.id == targetClip.assetId) {
        sourceAsset = asset;
        break;
      }
    }
    final mediaPath =
        sourceAsset?.sourcePath ??
        (targetClip.type == TimelineTrackType.video
            ? widget.project.videoPath
            : '');
    if (mediaPath.isEmpty) {
      SnackBarHelper.showError(
        context,
        'Media source is missing for this clip.',
      );
      return;
    }

    if (!ref.read(quotaProvider).canRun) {
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const QuotaExhaustedScreen()),
      );
      return;
    }

    if (!mounted) return;
    final pipeline = TranscriptionPipeline();
    final processingNavigator = Navigator.of(context);
    var processingClosed = false;
    var cancellationRequested = false;
    late final MaterialPageRoute<void> processingRoute;

    void closeProcessingRoute() {
      if (processingClosed) return;
      processingClosed = true;
      if (processingNavigator.mounted && processingRoute.isActive) {
        processingNavigator.removeRoute(processingRoute);
      }
    }

    processingRoute = MaterialPageRoute<void>(
      builder: (_) => ProcessingScreen(
        progressStream: pipeline.progressStream,
        onCancel: () {
          cancellationRequested = true;
          pipeline.cancel();
          closeProcessingRoute();
        },
      ),
    );
    unawaited(
      processingNavigator.push<void>(processingRoute).whenComplete(() {
        processingClosed = true;
      }),
    );

    try {
      final generatedEntries = await pipeline.transcribeVideoSegment(
        videoPath: mediaPath,
        startTime: targetClip.sourceStartTime,
        clipDuration: targetClip.sourceDuration,
      );

      if (generatedEntries == null || generatedEntries.isEmpty) {
        closeProcessingRoute();
        if (cancellationRequested) return;
        if (mounted) {
          SnackBarHelper.showInfo(
            context,
            'No subtitles detected for this clip.',
          );
        }
        return;
      }

      // A free run is charged only after transcription produces usable cues.
      // Failed, cancelled, and silent-media attempts do not consume the quota.
      final quotaRecorded = await ref
          .read(quotaProvider.notifier)
          .consumeRun(user.uid);

      final shiftedEntries = targetClip.mapSourceSubtitlesToTimeline(
        generatedEntries,
      );

      final existingLinkedSubtitleIds = subtitleTrack.clips
          .where((clip) => clip.linkedClipId == targetClip.id)
          .map((clip) => clip.id)
          .toSet();

      final currentSubtitleState = ref.read(subtitleProvider);
      final mergedEntries = [
        ...currentSubtitleState.entries.where(
          (entry) => !existingLinkedSubtitleIds.contains(entry.id),
        ),
        ...shiftedEntries,
      ]..sort((a, b) => a.startTime.compareTo(b.startTime));

      final nextTimeline = _timelineWithGeneratedSubtitles(
        timeline: timeline,
        targetClip: targetClip,
        subtitleTrack: subtitleTrack,
        generatedEntries: shiftedEntries,
      );

      ref
          .read(editorProvider.notifier)
          .replaceTimelineAndSubtitleEntries(
            timeline: nextTimeline,
            entries: mergedEntries,
          );
      _scheduleProjectSave(immediate: true, changeType: 'subtitles_generated');

      closeProcessingRoute();
      if (mounted) {
        SnackBarHelper.showSuccess(
          context,
          'Generated ${shiftedEntries.length} captions for ${targetClip.label}',
        );
        if (!quotaRecorded) {
          SnackBarHelper.showWarning(
            context,
            'Captions were created, but usage could not be synced.',
          );
        }
      }
    } catch (e) {
      closeProcessingRoute();
      if (mounted && !cancellationRequested) {
        SnackBarHelper.showError(
          context,
          e.toString().replaceFirst('Exception: ', ''),
        );
      }
    } finally {
      pipeline.dispose();
    }
  }

  EditorTimeline _timelineWithGeneratedSubtitles({
    required EditorTimeline timeline,
    required TimelineClip targetClip,
    required TimelineTrack subtitleTrack,
    required List<SubtitleEntry> generatedEntries,
  }) {
    final subtitleTrackId = subtitleTrack.id;
    final existingSubtitleClips = subtitleTrack.clips
        .where((clip) => clip.linkedClipId != targetClip.id)
        .toList();

    final generatedSubtitleClips = generatedEntries
        .map(
          (entry) => TimelineClip.fromSubtitleEntry(
            entry,
            trackId: subtitleTrackId,
            linkedClipId: targetClip.id,
          ),
        )
        .toList();

    final mergedTrack = subtitleTrack.copyWith(
      type: TimelineTrackType.subtitle,
      section: TimelineTrackSection.textSubtitle,
      clips: [...existingSubtitleClips, ...generatedSubtitleClips]
        ..sort((a, b) => a.startTime.compareTo(b.startTime)),
    );

    final trackExists = timeline.tracks.any(
      (track) => track.id == subtitleTrackId,
    );

    return timeline.copyWith(
      tracks: trackExists
          ? timeline.tracks
                .map(
                  (track) => track.id == subtitleTrackId ? mergedTrack : track,
                )
                .toList()
          : [...timeline.tracks, mergedTrack],
    );
  }

  void _scheduleProjectSave({
    bool immediate = false,
    String changeType = 'editor_change',
  }) {
    if (!_editorInitialized) return;
    _saveDebounce?.cancel();
    _remoteSaveDebounce?.cancel();
    final userUid = ref.read(currentUserProvider)?.uid;
    final project = _captureProjectSnapshot(
      captionsChanged: _changeAffectsCaptions(changeType),
    );
    if (userUid != null) {
      _remoteSyncPending = true;
    }
    if (immediate) {
      unawaited(
        _saveProjectState(
          project: project,
          userUid: userUid,
          syncRemote: true,
          changeType: changeType,
        ),
      );
      return;
    }

    // Timeline drags can publish dozens of revisions per second. Keep the
    // latest snapshot in memory, then coalesce disk writes after the gesture
    // settles instead of serializing the entire project for every pointer move.
    _saveDebounce = Timer(const Duration(milliseconds: 650), () {
      unawaited(
        _saveProjectState(
          project: _projectSnapshot,
          userUid: userUid,
          syncRemote: false,
          changeType: changeType,
        ),
      );
    });
    _remoteSaveDebounce = Timer(const Duration(seconds: 2), () {
      unawaited(
        _saveProjectState(
          project: _projectSnapshot,
          userUid: userUid,
          syncRemote: true,
          changeType: '${changeType}_remote_sync',
        ),
      );
    });
  }

  Future<void> _flushProjectSave({
    bool syncRemote = true,
    String changeType = 'editor_flush',
  }) async {
    _saveDebounce?.cancel();
    _remoteSaveDebounce?.cancel();
    final userUid = ref.read(currentUserProvider)?.uid;
    final project = _captureProjectSnapshot();
    await _saveProjectState(
      project: project,
      userUid: userUid,
      syncRemote: syncRemote,
      changeType: changeType,
    );
  }

  Project _captureProjectSnapshot({bool captionsChanged = false}) {
    if (!_editorInitialized) return _projectSnapshot;

    final subtitleState = ref.read(subtitleProvider);
    final editorState = ref.read(editorProvider);
    final entries = List<SubtitleEntry>.from(subtitleState.entries);
    final mergedTimeline = editorState.timeline.mergeSubtitleEntries(
      subtitles: entries,
      globalStyle: subtitleState.globalStyle,
    );
    final now = DateTime.now();
    final project = _projectSnapshot.copyWith(
      subtitles: entries,
      globalStyle: subtitleState.globalStyle,
      timeline: mergedTimeline,
      lastModifiedAt: now,
      captionsModifiedAt: captionsChanged
          ? now
          : _projectSnapshot.captionsModifiedAt,
    );
    _projectSnapshot = project;
    return project;
  }

  bool _changeAffectsCaptions(String changeType) {
    return changeType.contains('subtitle') ||
        changeType.contains('caption') ||
        changeType.contains('style');
  }

  Future<void> _saveProjectState({
    required Project project,
    required String? userUid,
    bool syncRemote = true,
    String changeType = 'editor_change',
  }) {
    _queuedProjectSnapshot = project;
    _queuedRemoteSync = _queuedRemoteSync || (syncRemote && userUid != null);
    if (userUid != null) {
      _queuedUserUid = userUid;
    }
    _queuedChangeType = changeType;

    final activeSave = _activeProjectSave;
    if (activeSave != null) return activeSave;

    late final Future<void> saveDrain;
    saveDrain = _drainProjectSaves().whenComplete(() {
      if (identical(_activeProjectSave, saveDrain)) {
        _activeProjectSave = null;
      }
    });
    _activeProjectSave = saveDrain;
    return saveDrain;
  }

  Future<void> _drainProjectSaves() async {
    _isSavingProject = true;
    if (mounted && !_isClosing) {
      setState(() {});
    }

    try {
      while (_queuedProjectSnapshot != null) {
        final project = _queuedProjectSnapshot!;
        final shouldSyncRemote = _queuedRemoteSync;
        final userUid = _queuedUserUid;
        final changeType = _queuedChangeType;

        _queuedProjectSnapshot = null;
        _queuedRemoteSync = false;
        _queuedUserUid = null;
        _queuedChangeType = 'queued_editor_change';

        var savedLocally = false;
        try {
          await EditorChangeLogService.saveLocalSnapshot(
            project: project,
            changeType: changeType,
          );
          savedLocally = true;
          _lastSavedAt = DateTime.now();
          _localSaveError = null;
        } catch (error) {
          _localSaveError = error;
        }

        if (savedLocally && shouldSyncRemote && userUid != null) {
          if (_queuedProjectSnapshot != null) {
            _queuedRemoteSync = true;
            _queuedUserUid ??= userUid;
          } else {
            try {
              await FirebaseService.saveProject(
                userUid,
                project.id,
                project.toFirestore(),
              );
              _remoteSyncPending = false;
            } catch (_) {
              _remoteSyncPending = true;
            }
          }
        }
      }
    } finally {
      _isSavingProject = false;
      if (mounted && !_isClosing) {
        setState(() {});
      }
    }
  }

  String _safeProjectName() {
    final cleaned = widget.project.name
        .replaceAll(RegExp(r'[^A-Za-z0-9_\-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return cleaned.isEmpty ? 'caption_craft' : cleaned;
  }

  TimelineClip? _selectedClipFromState(EditorState editorState) {
    if (editorState.selectedClipId == null) return null;
    for (final track in editorState.timeline.tracks) {
      for (final clip in track.clips) {
        if (clip.id == editorState.selectedClipId) {
          return clip;
        }
      }
    }
    return null;
  }

  TimelineTrack? _trackForClip(TimelineClip? clip, EditorState editorState) {
    if (clip == null) return null;
    for (final track in editorState.timeline.tracks) {
      if (track.clips.any((candidate) => candidate.id == clip.id)) {
        return track;
      }
    }
    return null;
  }

  TimelineClip? _clipById(String clipId, EditorState editorState) {
    for (final track in editorState.timeline.tracks) {
      for (final clip in track.clips) {
        if (clip.id == clipId) {
          return clip;
        }
      }
    }
    return null;
  }

  void _updateTimelineClip(
    TimelineClip target,
    TimelineClip Function(TimelineClip current) mapper, {
    bool recordHistory = true,
  }) {
    final editorState = ref.read(editorProvider);
    final track = _trackForClip(target, editorState);
    if (track == null || track.isLocked) {
      SnackBarHelper.showInfo(context, 'Unlock the track to edit this clip.');
      return;
    }
    final nextTracks = editorState.timeline.tracks.map((timelineTrack) {
      final clips = timelineTrack.clips
          .map((clip) => clip.id == target.id ? mapper(clip) : clip)
          .toList();
      return timelineTrack.copyWith(clips: clips);
    }).toList();
    ref
        .read(editorProvider.notifier)
        .setTimeline(
          editorState.timeline.copyWith(tracks: nextTracks),
          recordHistory: recordHistory,
        );
  }

  void _updateClipPlaybackRate(
    TimelineClip target,
    double playbackRate, {
    bool recordHistory = true,
  }) {
    final editorState = ref.read(editorProvider);
    final timeline = editorState.timeline;
    final liveTarget = _clipById(target.id, editorState) ?? target;
    final track = _trackForClip(liveTarget, editorState);
    if (track == null || track.isLocked) {
      SnackBarHelper.showInfo(context, 'Unlock the track to change speed.');
      return;
    }
    final safeRate = playbackRate.clamp(0.25, 4).toDouble();
    final sourceDurationMs = liveTarget.sourceDuration.inMilliseconds > 0
        ? liveTarget.sourceDuration.inMilliseconds
        : liveTarget.duration.inMilliseconds;
    final nextDuration = Duration(
      milliseconds: math.max(100, (sourceDurationMs / safeRate).round()),
    );
    final nextEnd = liveTarget.startTime + nextDuration;
    final rippleDelta = nextDuration - liveTarget.duration;
    final isBase = track.section == TimelineTrackSection.baseVideo;
    final oldEnd = liveTarget.endTime;
    final oldDurationMs = math.max(1, liveTarget.duration.inMilliseconds);

    final retimedTracks = timeline.tracks.map((timelineTrack) {
      if (timelineTrack.id != track.id && timelineTrack.isLocked) {
        return timelineTrack;
      }
      final clips = timelineTrack.clips.map((clip) {
        if (clip.id == liveTarget.id) {
          return clip.copyWith(playbackRate: safeRate, endTime: nextEnd);
        }

        final isSubtitleClip =
            timelineTrack.type == TimelineTrackType.subtitle ||
            clip.type == TimelineTrackType.subtitle;
        final intersectsChangedClip =
            clip.startTime < oldEnd && clip.endTime > liveTarget.startTime;
        final belongsToChangedClip =
            clip.linkedClipId == liveTarget.id ||
            (isBase &&
                isSubtitleClip &&
                clip.linkedClipId == null &&
                intersectsChangedClip);
        if (belongsToChangedClip) {
          final relativeStartMs = (clip.startTime - liveTarget.startTime)
              .inMilliseconds
              .clamp(0, oldDurationMs)
              .toInt();
          final relativeEndMs = (clip.endTime - liveTarget.startTime)
              .inMilliseconds
              .clamp(relativeStartMs + 1, oldDurationMs)
              .toInt();
          final startRatio = relativeStartMs / oldDurationMs;
          final endRatio = relativeEndMs / oldDurationMs;
          final nextStart =
              liveTarget.startTime +
              Duration(
                milliseconds: (nextDuration.inMilliseconds * startRatio)
                    .round(),
              );
          final scaledEnd =
              liveTarget.startTime +
              Duration(
                milliseconds: (nextDuration.inMilliseconds * endRatio).round(),
              );
          return clip.copyWith(
            linkedClipId: liveTarget.id,
            startTime: nextStart,
            endTime: scaledEnd > nextStart + const Duration(milliseconds: 80)
                ? scaledEnd
                : nextStart + const Duration(milliseconds: 80),
          );
        }
        if (isBase && clip.startTime >= oldEnd) {
          return clip.copyWith(
            startTime: clip.startTime + rippleDelta,
            endTime: clip.endTime + rippleDelta,
          );
        }
        return clip;
      }).toList()..sort((a, b) => a.startTime.compareTo(b.startTime));
      return timelineTrack.copyWith(clips: clips);
    }).toList();
    final nextTracks = retimedTracks
        .map(
          (timelineTrack) =>
              timelineTrack.type == TimelineTrackType.subtitle &&
                  !timelineTrack.isLocked
              ? timelineTrack.copyWith(
                  clips: _removeSubtitleTimingCollisions(timelineTrack.clips),
                )
              : timelineTrack,
        )
        .toList();
    final markers = timeline.markers.map((marker) {
      if (isBase && marker.position >= oldEnd) {
        return marker.copyWith(position: marker.position + rippleDelta);
      }
      return marker;
    }).toList();
    final nextTimeline = timeline.copyWith(
      tracks: nextTracks,
      markers: markers,
    );
    ref
        .read(editorProvider.notifier)
        .setTimeline(nextTimeline, recordHistory: recordHistory);
    ref
        .read(subtitleProvider.notifier)
        .syncFromTimeline(nextTimeline.subtitleEntries);
  }

  List<TimelineClip> _removeSubtitleTimingCollisions(List<TimelineClip> clips) {
    final sorted = [...clips]
      ..sort((a, b) => a.startTime.compareTo(b.startTime));
    final result = <TimelineClip>[];
    var nextAvailable = Duration.zero;
    for (final clip in sorted) {
      final start = clip.startTime < nextAvailable
          ? nextAvailable
          : clip.startTime;
      final minimumEnd = start + const Duration(milliseconds: 80);
      final end = clip.endTime < minimumEnd ? minimumEnd : clip.endTime;
      result.add(clip.copyWith(startTime: start, endTime: end));
      nextAvailable = end + const Duration(milliseconds: 20);
    }
    return result;
  }

  bool _isVisualClip(TimelineClip? clip) {
    return clip?.supportsVisualEffects ?? false;
  }

  bool _canReverseClip(TimelineClip? clip) {
    return clip?.supportsReversePlayback ?? false;
  }

  void _toggleClipReverse(TimelineClip clip) {
    if (!_canReverseClip(clip)) return;
    _updateTimelineClip(
      clip,
      (current) => current.copyWith(isReversed: !current.isReversed),
    );
  }

  void _setClipFit(TimelineClip clip, ClipFitMode fitMode) {
    if (!clip.supportsVisualEffects) return;
    _updateTimelineClip(clip, (current) => current.copyWith(fitMode: fitMode));
  }

  void _rotateClip(TimelineClip clip, double radians) {
    if (!clip.supportsVisualEffects) return;
    _updateTimelineClip(
      clip,
      (current) => current.copyWith(
        transform: current.transform.copyWith(
          rotation: current.transform.rotation + radians,
        ),
      ),
    );
  }

  void _toggleClipFlip(TimelineClip clip, {required bool horizontal}) {
    if (!clip.supportsVisualEffects) return;
    _updateTimelineClip(
      clip,
      (current) => current.copyWith(
        transform: horizontal
            ? current.transform.copyWith(flipX: !current.transform.flipX)
            : current.transform.copyWith(flipY: !current.transform.flipY),
      ),
    );
  }

  void _changeClipLayer(TimelineClip clip, int delta) {
    final editorState = ref.read(editorProvider);
    final track = _trackForClip(clip, editorState);
    final supportsLayering =
        track != null &&
        !track.isLocked &&
        track.section == TimelineTrackSection.overlay;
    if (!supportsLayering) return;
    _updateTimelineClip(
      clip,
      (current) => current.copyWith(layer: math.max(0, current.layer + delta)),
    );
  }

  void _toggleClipEnabled(TimelineClip clip) {
    _updateTimelineClip(
      clip,
      (current) => current.copyWith(enabled: !current.enabled),
    );
  }

  void _resetClipTransform(TimelineClip clip) {
    if (!clip.supportsVisualEffects) return;
    _updateTimelineClip(
      clip,
      (current) => current.copyWith(
        transform: const TimelineTransform(),
        crop: const ClipCropSettings(),
        fitMode: current.type == TimelineTrackType.video
            ? ClipFitMode.cover
            : ClipFitMode.contain,
      ),
    );
  }

  void _addEffectOverlay({
    required TimelineClip anchor,
    required TimelineEffectKind kind,
    required String label,
    ClipBlurSettings blur = const ClipBlurSettings(),
    ClipColorAdjustments colorAdjustments = const ClipColorAdjustments(),
  }) {
    final editorState = ref.read(editorProvider);
    final liveAnchor = _clipById(anchor.id, editorState);
    final anchorTrack = _trackForClip(liveAnchor, editorState);
    if (liveAnchor == null ||
        anchorTrack == null ||
        anchorTrack.isLocked ||
        !liveAnchor.supportsVisualEffects) {
      return;
    }
    final timeline = editorState.timeline;
    final existingEffectTrack = _resolveInsertionTrack(
      timeline,
      TimelineTrackSection.overlay,
      TimelineTrackType.effect,
    );
    final effectTrack =
        existingEffectTrack ??
        _createOptionalTrack(
          timeline,
          TimelineTrackSection.overlay,
          TimelineTrackType.effect,
        );
    if (effectTrack == null ||
        !effectTrack.acceptsClipType(TimelineTrackType.effect)) {
      SnackBarHelper.showInfo(
        context,
        'Add or unlock an effects track before applying this effect.',
      );
      return;
    }
    final effectClip = TimelineClip.effect(
      trackId: effectTrack.id,
      effectKind: kind,
      label: label,
      startTime: liveAnchor.startTime,
      endTime: liveAnchor.endTime,
      blur: blur,
      colorAdjustments: colorAdjustments,
      layer: effectTrack.clips.length,
    );
    final updatedEffectTrack = effectTrack.copyWith(
      clips: [...effectTrack.clips, effectClip],
    );
    final nextTracks = existingEffectTrack != null
        ? timeline.tracks
              .map(
                (track) =>
                    track.id == effectTrack.id ? updatedEffectTrack : track,
              )
              .toList()
        : [...timeline.tracks, updatedEffectTrack];
    ref
        .read(editorProvider.notifier)
        .setTimeline(timeline.copyWith(tracks: nextTracks));
    ref.read(editorProvider.notifier)
      ..selectTrack(effectTrack.id)
      ..selectClip(effectClip.id);
    if (mounted) {
      SnackBarHelper.showSuccess(
        context,
        '$label added as a movable timeline overlay',
      );
    }
  }

  void _replaceFilterEffect(TimelineClip effectClip, ClipFilterPreset preset) {
    final adjustments = ClipColorAdjustments.forPreset(preset);
    _updateTimelineClip(
      effectClip,
      (current) => current.copyWith(
        label: '${_filterPresetLabel(preset)} filter',
        colorAdjustments: adjustments,
      ),
    );
  }

  void _setBlurMode(TimelineClip clip, ClipBlurMode mode) {
    _updateTimelineClip(
      clip,
      (current) => current.copyWith(
        label: current.isEffect
            ? (mode == ClipBlurMode.region ? 'Region blur' : 'Whole blur')
            : current.label,
        blur: current.blur.copyWith(mode: mode),
      ),
    );
  }

  Future<void> _openBlurSheet(TimelineClip initialClip) async {
    final editorState = ref.read(editorProvider);
    final initialTrack = _trackForClip(initialClip, editorState);
    final isBlurEffect =
        initialClip.isEffect &&
        initialClip.effectKind == TimelineEffectKind.blur;
    if (initialTrack == null ||
        initialTrack.isLocked ||
        (!isBlurEffect && !initialClip.supportsVisualEffects)) {
      return;
    }
    var clip = _clipById(initialClip.id, editorState) ?? initialClip;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => StatefulBuilder(
        builder: (context, setSheetState) {
          void update(
            ClipBlurSettings Function(ClipBlurSettings current) mapper, {
            bool recordHistory = true,
          }) {
            _updateTimelineClip(
              clip,
              (current) => current.copyWith(blur: mapper(current.blur)),
              recordHistory: recordHistory,
            );
            final latest = _clipById(clip.id, ref.read(editorProvider));
            if (latest != null) setSheetState(() => clip = latest);
          }

          final blur = clip.blur;
          Widget regionSlider({
            required String label,
            required double value,
            required double maximum,
            required ClipBlurSettings Function(double value) mapper,
          }) {
            final safeMaximum = math.max(0.01, maximum);
            return Column(
              children: [
                _sheetSliderHeader(label, '${(value * 100).round()}%'),
                Slider(
                  value: value.clamp(0.0, safeMaximum).toDouble(),
                  min: 0,
                  max: safeMaximum,
                  divisions: math.max(1, (safeMaximum * 100).round()),
                  onChangeStart: (_) => ref
                      .read(editorProvider.notifier)
                      .beginTimelineGestureEdit(),
                  onChanged: (next) =>
                      update((_) => mapper(next), recordHistory: false),
                  onChangeEnd: (_) => ref
                      .read(editorProvider.notifier)
                      .endTimelineGestureEdit(),
                ),
              ],
            );
          }

          return _buildEditorSheet(
            title: 'Blur',
            subtitle: 'Rendered in preview and final export',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _sheetSectionTitle('MODE'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    ChoiceChip(
                      label: const Text('Whole frame'),
                      selected: blur.mode == ClipBlurMode.full,
                      onSelected: (_) => update(
                        (current) => current.copyWith(mode: ClipBlurMode.full),
                      ),
                    ),
                    ChoiceChip(
                      label: const Text('Privacy region'),
                      selected: blur.mode == ClipBlurMode.region,
                      onSelected: (_) => update(
                        (current) =>
                            current.copyWith(mode: ClipBlurMode.region),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                _sheetSliderHeader(
                  'Strength',
                  blur.safeStrength.toStringAsFixed(1),
                ),
                Slider(
                  value: blur.safeStrength,
                  min: 0.5,
                  max: 30,
                  divisions: 118,
                  label: blur.safeStrength.toStringAsFixed(1),
                  onChangeStart: (_) => ref
                      .read(editorProvider.notifier)
                      .beginTimelineGestureEdit(),
                  onChanged: (value) => update(
                    (current) => current.copyWith(strength: value),
                    recordHistory: false,
                  ),
                  onChangeEnd: (_) => ref
                      .read(editorProvider.notifier)
                      .endTimelineGestureEdit(),
                ),
                if (blur.mode == ClipBlurMode.region) ...[
                  const SizedBox(height: 14),
                  _sheetSectionTitle('REGION'),
                  const SizedBox(height: 6),
                  regionSlider(
                    label: 'Left',
                    value: blur.safeRegionX,
                    maximum: 1 - blur.safeRegionWidth,
                    mapper: (value) => blur.copyWith(regionX: value),
                  ),
                  regionSlider(
                    label: 'Top',
                    value: blur.safeRegionY,
                    maximum: 1 - blur.safeRegionHeight,
                    mapper: (value) => blur.copyWith(regionY: value),
                  ),
                  regionSlider(
                    label: 'Width',
                    value: blur.safeRegionWidth,
                    maximum: 1,
                    mapper: (value) => blur.copyWith(
                      regionWidth: value
                          .clamp(0.08, 1 - blur.safeRegionX)
                          .toDouble(),
                    ),
                  ),
                  regionSlider(
                    label: 'Height',
                    value: blur.safeRegionHeight,
                    maximum: 1,
                    mapper: (value) => blur.copyWith(
                      regionHeight: value
                          .clamp(0.08, 1 - blur.safeRegionY)
                          .toDouble(),
                    ),
                  ),
                  const Text(
                    'You can also drag and resize the privacy region directly on the preview.',
                    style: TextStyle(color: kTextSecondary, fontSize: 11),
                  ),
                ],
                if (clip.keyframes.any(
                  (frame) =>
                      frame.property == TimelineKeyframeProperty.blurStrength,
                )) ...[
                  const SizedBox(height: 12),
                  const Text(
                    'Blur strength is animated by keyframes on this clip.',
                    style: TextStyle(color: kAccentSecondary, fontSize: 11),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  void _toggleClipMute(TimelineClip clip) {
    final timeline = ref.read(editorProvider).timeline;
    if (!timeline.clipHasAudio(clip)) return;
    _updateTimelineClip(
      clip,
      (current) => current.copyWith(
        audioMix: current.audioMix.copyWith(muted: !current.audioMix.muted),
      ),
    );
  }

  void _toggleClipNormalize(TimelineClip clip) {
    final timeline = ref.read(editorProvider).timeline;
    if (!timeline.clipHasAudio(clip)) return;
    _updateTimelineClip(
      clip,
      (current) => current.copyWith(
        audioMix: current.audioMix.copyWith(
          normalize: !current.audioMix.normalize,
        ),
      ),
    );
  }

  void _toggleQuickFade(TimelineClip clip, {required bool fadeIn}) {
    final timeline = ref.read(editorProvider).timeline;
    if (!timeline.clipHasAudio(clip)) return;
    _updateTimelineClip(clip, (current) {
      final mix = current.audioMix;
      return current.copyWith(
        audioMix: fadeIn
            ? mix.copyWith(fadeInMs: mix.fadeInMs == 0 ? 500 : 0)
            : mix.copyWith(fadeOutMs: mix.fadeOutMs == 0 ? 500 : 0),
      );
    });
  }

  void _duplicateClip(TimelineClip clip) {
    final editorState = ref.read(editorProvider);
    final track = _trackForClip(clip, editorState);
    if (track == null || track.isLocked) {
      SnackBarHelper.showInfo(context, 'Unlock the track to duplicate clips.');
      return;
    }
    final timeline = editorState.timeline;
    final newStart = track.section == TimelineTrackSection.baseVideo
        ? timeline.duration
        : clip.endTime;
    final duplicate = clip.copyWith(
      id: const Uuid().v4(),
      startTime: newStart,
      endTime: newStart + clip.duration,
      clearLinkedClipId: true,
    );
    final nextTracks = timeline.tracks.map((candidate) {
      if (candidate.id != track.id) return candidate;
      final clips = [...candidate.clips, duplicate]
        ..sort((a, b) => a.startTime.compareTo(b.startTime));
      return candidate.copyWith(clips: clips);
    }).toList();
    ref
        .read(editorProvider.notifier)
        .setTimeline(timeline.copyWith(tracks: nextTracks));
    ref.read(editorProvider.notifier)
      ..selectTrack(track.id)
      ..selectClip(duplicate.id);
  }

  void _deleteClip(TimelineClip clip) {
    final editorState = ref.read(editorProvider);
    final track = _trackForClip(clip, editorState);
    if (track == null || track.isLocked) {
      SnackBarHelper.showInfo(context, 'Unlock the track to delete clips.');
      return;
    }
    if (track.section == TimelineTrackSection.baseVideo &&
        track.clips.where((candidate) => candidate.enabled).length <= 1) {
      SnackBarHelper.showInfo(
        context,
        'Keep at least one base video clip in the timeline.',
      );
      return;
    }
    final nextTracks = editorState.timeline.tracks.map((candidate) {
      if (candidate.id != track.id && candidate.isLocked) return candidate;
      final clips = candidate.clips
          .where(
            (item) =>
                item.id != clip.id &&
                (item.linkedClipId == null || item.linkedClipId != clip.id),
          )
          .toList();
      return candidate.copyWith(clips: clips);
    }).toList();
    final nextTimeline = editorState.timeline.copyWith(tracks: nextTracks);
    ref.read(editorProvider.notifier)
      ..setTimeline(nextTimeline)
      ..selectClip(null);
    ref
        .read(subtitleProvider.notifier)
        .syncFromTimeline(nextTimeline.subtitleEntries);
  }

  void _splitClipAtPlayhead(TimelineClip clip) {
    final editorState = ref.read(editorProvider);
    final timeline = editorState.timeline;
    final track = _trackForClip(clip, editorState);
    if (track == null || track.isLocked) {
      SnackBarHelper.showInfo(context, 'Unlock the track to split clips.');
      return;
    }
    final splitPoint = ref.read(playbackProvider).position;
    if (splitPoint <= clip.startTime ||
        splitPoint >= clip.endTime ||
        (splitPoint - clip.startTime).inMilliseconds < 100 ||
        (clip.endTime - splitPoint).inMilliseconds < 100) {
      SnackBarHelper.showInfo(
        context,
        'Move the playhead inside the selected clip to split it.',
      );
      return;
    }

    final rightId = const Uuid().v4();
    final timelineOffsetMs = (splitPoint - clip.startTime).inMilliseconds;
    final sourceOffsetMs = (timelineOffsetMs * clip.playbackRate).round();
    final sourceDurationMs = math.max(
      sourceOffsetMs + 1,
      clip.sourceDuration.inMilliseconds,
    );
    final leftKeyframes = <TimelineKeyframe>[];
    final rightKeyframes = <TimelineKeyframe>[];
    for (final property in TimelineKeyframeProperty.values) {
      final propertyFrames =
          clip.keyframes
              .where((keyframe) => keyframe.property == property)
              .toList()
            ..sort((a, b) => a.time.compareTo(b.time));
      if (propertyFrames.isEmpty) continue;
      final boundaryValue = clip.keyframedValue(
        property,
        splitPoint,
        fallback: propertyFrames.first.value,
      );
      leftKeyframes.addAll(
        propertyFrames.where(
          (keyframe) => keyframe.time.inMilliseconds <= timelineOffsetMs,
        ),
      );
      if (!leftKeyframes.any(
        (keyframe) =>
            keyframe.property == property &&
            keyframe.time.inMilliseconds == timelineOffsetMs,
      )) {
        leftKeyframes.add(
          TimelineKeyframe(
            time: Duration(milliseconds: timelineOffsetMs),
            property: property,
            value: boundaryValue,
          ),
        );
      }
      rightKeyframes.add(
        TimelineKeyframe(
          time: Duration.zero,
          property: property,
          value: boundaryValue,
        ),
      );
      rightKeyframes.addAll(
        propertyFrames
            .where(
              (keyframe) => keyframe.time.inMilliseconds > timelineOffsetMs,
            )
            .map(
              (keyframe) => TimelineKeyframe(
                time: keyframe.time - Duration(milliseconds: timelineOffsetMs),
                property: property,
                value: keyframe.value,
              ),
            ),
      );
    }
    leftKeyframes.sort((a, b) => a.time.compareTo(b.time));
    rightKeyframes.sort((a, b) => a.time.compareTo(b.time));
    final leftSourceStart = clip.isReversed
        ? clip.sourceStartTime +
              Duration(milliseconds: sourceDurationMs - sourceOffsetMs)
        : clip.sourceStartTime;
    final rightSourceStart = clip.isReversed
        ? clip.sourceStartTime
        : clip.sourceStartTime + Duration(milliseconds: sourceOffsetMs);
    final left = clip.copyWith(
      endTime: splitPoint,
      sourceStartTime: leftSourceStart,
      sourceDuration: Duration(milliseconds: sourceOffsetMs),
      keyframes: leftKeyframes,
      outroTransition: const ClipTransition(),
      audioMix: clip.audioMix.copyWith(fadeOutMs: 0),
    );
    final right = clip.copyWith(
      id: rightId,
      startTime: splitPoint,
      sourceStartTime: rightSourceStart,
      sourceDuration: Duration(
        milliseconds: math.max(1, sourceDurationMs - sourceOffsetMs),
      ),
      keyframes: rightKeyframes,
      introTransition: const ClipTransition(),
      audioMix: clip.audioMix.copyWith(fadeInMs: 0),
    );

    final nextTracks = <TimelineTrack>[];
    for (final candidateTrack in timeline.tracks) {
      if (candidateTrack.id == track.id) {
        final clips = <TimelineClip>[];
        for (final candidate in candidateTrack.clips) {
          if (candidate.id == clip.id) {
            clips.addAll([left, right]);
          } else {
            clips.add(candidate);
          }
        }
        clips.sort((a, b) => a.startTime.compareTo(b.startTime));
        nextTracks.add(candidateTrack.copyWith(clips: clips));
        continue;
      }
      if (candidateTrack.type != TimelineTrackType.subtitle) {
        nextTracks.add(candidateTrack);
        continue;
      }
      if (candidateTrack.isLocked) {
        nextTracks.add(candidateTrack);
        continue;
      }
      final captions = <TimelineClip>[];
      for (final caption in candidateTrack.clips) {
        if (caption.linkedClipId != clip.id || caption.endTime <= splitPoint) {
          captions.add(caption);
        } else if (caption.startTime >= splitPoint) {
          captions.add(caption.copyWith(linkedClipId: rightId));
        } else {
          captions.add(caption.copyWith(endTime: splitPoint));
          captions.add(
            caption.copyWith(
              id: const Uuid().v4(),
              linkedClipId: rightId,
              startTime: splitPoint,
            ),
          );
        }
      }
      captions.sort((a, b) => a.startTime.compareTo(b.startTime));
      nextTracks.add(candidateTrack.copyWith(clips: captions));
    }
    final nextTimeline = timeline.copyWith(tracks: nextTracks);
    ref.read(editorProvider.notifier)
      ..setTimeline(nextTimeline)
      ..selectClip(rightId);
    ref
        .read(subtitleProvider.notifier)
        .syncFromTimeline(nextTimeline.subtitleEntries);
  }

  int _assetDurationMs(EditorTimeline timeline, TimelineClip clip) {
    final asset = timeline.assetForClip(clip);
    final metadataDuration = (asset?.metadata['durationMs'] as num?)?.toInt();
    if (metadataDuration != null && metadataDuration > 0) {
      return metadataDuration;
    }
    return math.max(
      100,
      clip.sourceStartTime.inMilliseconds +
          math.max(clip.sourceDuration.inMilliseconds, 100),
    );
  }

  void _applySourceTrim(
    TimelineClip target, {
    required int sourceStartMs,
    required int sourceEndMs,
  }) {
    final editorState = ref.read(editorProvider);
    final timeline = editorState.timeline;
    final track = _trackForClip(target, editorState);
    if (track == null || track.isLocked) {
      SnackBarHelper.showInfo(context, 'Unlock the track to trim this clip.');
      return;
    }
    final assetDurationMs = _assetDurationMs(timeline, target);
    final safeStart = sourceStartMs.clamp(0, assetDurationMs - 100).toInt();
    final safeEnd = sourceEndMs.clamp(safeStart + 100, assetDurationMs).toInt();
    final sourceDuration = Duration(milliseconds: safeEnd - safeStart);
    final nextDuration = Duration(
      milliseconds: math.max(
        100,
        (sourceDuration.inMilliseconds / target.playbackRate).round(),
      ),
    );
    final nextEnd = target.startTime + nextDuration;
    final oldEnd = target.endTime;
    final rippleDelta = nextEnd - oldEnd;
    final isBase = track.section == TimelineTrackSection.baseVideo;

    final nextTracks = timeline.tracks.map((candidateTrack) {
      if (candidateTrack.id != track.id && candidateTrack.isLocked) {
        return candidateTrack;
      }
      final clips = candidateTrack.clips.map((clip) {
        if (clip.id == target.id) {
          return clip.copyWith(
            sourceStartTime: Duration(milliseconds: safeStart),
            sourceDuration: sourceDuration,
            endTime: nextEnd,
          );
        }
        if (clip.linkedClipId == target.id) {
          final oldDurationMs = math.max(1, target.duration.inMilliseconds);
          final startRatio =
              (clip.startTime - target.startTime).inMilliseconds /
              oldDurationMs;
          final endRatio =
              (clip.endTime - target.startTime).inMilliseconds / oldDurationMs;
          return clip.copyWith(
            startTime:
                target.startTime +
                Duration(
                  milliseconds: (nextDuration.inMilliseconds * startRatio)
                      .round(),
                ),
            endTime:
                target.startTime +
                Duration(
                  milliseconds: (nextDuration.inMilliseconds * endRatio)
                      .round(),
                ),
          );
        }
        if (isBase && clip.startTime >= oldEnd) {
          return clip.copyWith(
            startTime: clip.startTime + rippleDelta,
            endTime: clip.endTime + rippleDelta,
          );
        }
        return clip;
      }).toList()..sort((a, b) => a.startTime.compareTo(b.startTime));
      return candidateTrack.copyWith(clips: clips);
    }).toList();
    final markers = timeline.markers.map((marker) {
      if (isBase && marker.position >= oldEnd) {
        return marker.copyWith(position: marker.position + rippleDelta);
      }
      return marker;
    }).toList();
    final nextTimeline = timeline.copyWith(
      tracks: nextTracks,
      markers: markers,
    );
    ref.read(editorProvider.notifier).setTimeline(nextTimeline);
    ref
        .read(subtitleProvider.notifier)
        .syncFromTimeline(nextTimeline.subtitleEntries);
  }

  void _updateCanvasSettings(
    CanvasSettings Function(CanvasSettings current) mapper, {
    bool recordHistory = true,
  }) {
    final editorState = ref.read(editorProvider);
    ref
        .read(editorProvider.notifier)
        .setTimeline(
          editorState.timeline.copyWith(
            canvasSettings: mapper(editorState.timeline.canvasSettings),
          ),
          recordHistory: recordHistory,
        );
  }

  Future<void> _openClipInspectorSheet(TimelineClip initialClip) async {
    final initialState = ref.read(editorProvider);
    final initialTrack = _trackForClip(initialClip, initialState);
    if (!initialClip.supportsVisualEffects ||
        initialTrack == null ||
        initialTrack.isLocked) {
      return;
    }
    var clip = initialClip;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) {
          void refreshClip() {
            final latest = _clipById(clip.id, ref.read(editorProvider));
            if (latest != null) {
              setSheetState(() => clip = latest);
            }
          }

          void update(
            TimelineClip Function(TimelineClip current) mapper, {
            bool recordHistory = true,
          }) {
            _updateTimelineClip(clip, mapper, recordHistory: recordHistory);
            refreshClip();
          }

          return _buildEditorSheet(
            title: 'Clip inspector',
            subtitle: clip.label,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _sheetSectionTitle('LAYOUT'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: ClipFitMode.values.map((fit) {
                    return ChoiceChip(
                      label: Text(switch (fit) {
                        ClipFitMode.cover => 'Fill',
                        ClipFitMode.contain => 'Fit',
                        ClipFitMode.stretch => 'Stretch',
                      }),
                      selected: clip.fitMode == fit,
                      onSelected: (_) {
                        update((current) => current.copyWith(fitMode: fit));
                      },
                    );
                  }).toList(),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: _sheetActionTile(
                        icon: Icons.rotate_left_rounded,
                        label: 'Rotate −90°',
                        onTap: () => update(
                          (current) => current.copyWith(
                            transform: current.transform.copyWith(
                              rotation:
                                  current.transform.rotation - math.pi / 2,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _sheetActionTile(
                        icon: Icons.rotate_right_rounded,
                        label: 'Rotate +90°',
                        onTap: () => update(
                          (current) => current.copyWith(
                            transform: current.transform.copyWith(
                              rotation:
                                  current.transform.rotation + math.pi / 2,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _sheetActionTile(
                        icon: Icons.flip_rounded,
                        label: 'Flip horizontal',
                        active: clip.transform.flipX,
                        onTap: () => update(
                          (current) => current.copyWith(
                            transform: current.transform.copyWith(
                              flipX: !current.transform.flipX,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _sheetActionTile(
                        icon: Icons.flip_camera_android_rounded,
                        label: 'Flip vertical',
                        active: clip.transform.flipY,
                        onTap: () => update(
                          (current) => current.copyWith(
                            transform: current.transform.copyWith(
                              flipY: !current.transform.flipY,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                _sheetSliderHeader(
                  'Opacity',
                  '${(clip.transform.opacity * 100).round()}%',
                ),
                Slider(
                  value: clip.transform.opacity.clamp(0.0, 1.0),
                  onChangeStart: (_) => ref
                      .read(editorProvider.notifier)
                      .beginTimelineGestureEdit(),
                  onChanged: (value) => update(
                    (current) => current.copyWith(
                      transform: current.transform.copyWith(opacity: value),
                    ),
                    recordHistory: false,
                  ),
                  onChangeEnd: (_) => ref
                      .read(editorProvider.notifier)
                      .endTimelineGestureEdit(),
                ),
                if (clip.type == TimelineTrackType.video ||
                    clip.type == TimelineTrackType.audio) ...[
                  const SizedBox(height: 10),
                  _sheetSectionTitle('SPEED'),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: const [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 4.0]
                        .map(
                          (speed) => ChoiceChip(
                            label: Text('${speed}x'),
                            selected: (clip.playbackRate - speed).abs() < 0.001,
                            onSelected: (_) {
                              _updateClipPlaybackRate(clip, speed);
                              refreshClip();
                            },
                          ),
                        )
                        .toList(),
                  ),
                ],
                const SizedBox(height: 18),
                _sheetSectionTitle('LAYER'),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _sheetActionTile(
                        icon: Icons.move_down_rounded,
                        label: 'Send backward',
                        onTap: () => update(
                          (current) => current.copyWith(
                            layer: math.max(0, current.layer - 1),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _sheetActionTile(
                        icon: Icons.move_up_rounded,
                        label: 'Bring forward',
                        onTap: () => update(
                          (current) =>
                              current.copyWith(layer: current.layer + 1),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Clip enabled'),
                  subtitle: const Text('Disabled clips are skipped in export'),
                  value: clip.enabled,
                  onChanged: (value) =>
                      update((current) => current.copyWith(enabled: value)),
                ),
                if (clip.assetId != null)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.link_rounded),
                    title: const Text('Relink media'),
                    subtitle: const Text('Replace a missing or moved source'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () async {
                      await _relinkClipMedia(clip);
                      refreshClip();
                    },
                  ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () => update(
                    (current) => current.copyWith(
                      transform: const TimelineTransform(),
                      fitMode: current.type == TimelineTrackType.video
                          ? ClipFitMode.cover
                          : ClipFitMode.contain,
                    ),
                  ),
                  icon: const Icon(Icons.restart_alt_rounded),
                  label: const Text('Reset transform'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _openTimingSheet(TimelineClip initialClip) async {
    final initialState = ref.read(editorProvider);
    final initialTrack = _trackForClip(initialClip, initialState);
    if (!initialClip.supportsSourceTiming ||
        initialTrack == null ||
        initialTrack.isLocked) {
      return;
    }
    var clip = initialClip;
    final initialTimeline = ref.read(editorProvider).timeline;
    final initialAssetDurationMs = _assetDurationMs(initialTimeline, clip);
    var trimRange = RangeValues(
      clip.sourceStartTime.inMilliseconds
          .clamp(0, initialAssetDurationMs - 100)
          .toDouble(),
      (clip.sourceStartTime.inMilliseconds +
              math.max(100, clip.sourceDuration.inMilliseconds))
          .clamp(100, initialAssetDurationMs)
          .toDouble(),
    );

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => StatefulBuilder(
        builder: (context, setSheetState) {
          void refreshClip() {
            final latest = _clipById(clip.id, ref.read(editorProvider));
            if (latest == null) return;
            setSheetState(() {
              clip = latest;
              final timeline = ref.read(editorProvider).timeline;
              final assetDurationMs = _assetDurationMs(timeline, latest);
              trimRange = RangeValues(
                latest.sourceStartTime.inMilliseconds
                    .clamp(0, assetDurationMs - 100)
                    .toDouble(),
                (latest.sourceStartTime.inMilliseconds +
                        math.max(100, latest.sourceDuration.inMilliseconds))
                    .clamp(100, assetDurationMs)
                    .toDouble(),
              );
            });
          }

          final timeline = ref.read(editorProvider).timeline;
          final assetDurationMs = _assetDurationMs(timeline, clip);
          final canReverse = _canReverseClip(clip);
          return _buildEditorSheet(
            title: 'Timing',
            subtitle: canReverse
                ? 'Trim, speed, split and reverse'
                : 'Trim, speed and split',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _sheetSectionTitle('SOURCE TRIM'),
                const SizedBox(height: 5),
                Text(
                  '${_formatEditorDuration(Duration(milliseconds: trimRange.start.round()))}'
                  '  —  '
                  '${_formatEditorDuration(Duration(milliseconds: trimRange.end.round()))}',
                  style: const TextStyle(
                    color: kTextSecondary,
                    fontFamily: 'monospace',
                    fontSize: 11,
                  ),
                ),
                RangeSlider(
                  values: RangeValues(
                    trimRange.start.clamp(0, assetDurationMs - 100).toDouble(),
                    trimRange.end.clamp(100, assetDurationMs).toDouble(),
                  ),
                  min: 0,
                  max: assetDurationMs.toDouble(),
                  divisions: (assetDurationMs ~/ 100).clamp(1, 1000),
                  labels: RangeLabels(
                    _formatEditorDuration(
                      Duration(milliseconds: trimRange.start.round()),
                    ),
                    _formatEditorDuration(
                      Duration(milliseconds: trimRange.end.round()),
                    ),
                  ),
                  onChanged: (value) {
                    if (value.end - value.start < 100) return;
                    setSheetState(() => trimRange = value);
                  },
                  onChangeEnd: (value) {
                    _applySourceTrim(
                      clip,
                      sourceStartMs: value.start.round(),
                      sourceEndMs: value.end.round(),
                    );
                    refreshClip();
                  },
                ),
                const SizedBox(height: 14),
                _sheetSectionTitle('SPEED'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: const [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 4.0]
                      .map(
                        (speed) => ChoiceChip(
                          label: Text('${speed}x'),
                          selected: (clip.playbackRate - speed).abs() < 0.001,
                          onSelected: (_) {
                            _updateClipPlaybackRate(clip, speed);
                            refreshClip();
                          },
                        ),
                      )
                      .toList(),
                ),
                const SizedBox(height: 8),
                _sheetSliderHeader(
                  'Fine speed',
                  '${clip.playbackRate.toStringAsFixed(2)}x',
                ),
                Slider(
                  value: clip.playbackRate.clamp(0.25, 4),
                  min: 0.25,
                  max: 4,
                  divisions: 75,
                  onChangeStart: (_) => ref
                      .read(editorProvider.notifier)
                      .beginTimelineGestureEdit(),
                  onChanged: (value) {
                    _updateClipPlaybackRate(clip, value, recordHistory: false);
                    refreshClip();
                  },
                  onChangeEnd: (_) => ref
                      .read(editorProvider.notifier)
                      .endTimelineGestureEdit(),
                ),
                if (canReverse) ...[
                  const SizedBox(height: 10),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Reverse playback'),
                    subtitle: const Text(
                      'Preview scrubs backward; export reverses picture and audio',
                    ),
                    value: clip.isReversed,
                    onChanged: (_) {
                      _toggleClipReverse(clip);
                      refreshClip();
                    },
                  ),
                ],
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _sheetActionTile(
                        icon: Icons.content_cut_rounded,
                        label: 'Split at playhead',
                        onTap: () {
                          _splitClipAtPlayhead(clip);
                          Navigator.pop(context);
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _sheetActionTile(
                        icon: Icons.restart_alt_rounded,
                        label: 'Reset speed',
                        onTap: () {
                          _updateClipPlaybackRate(clip, 1);
                          refreshClip();
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  String _formatEditorDuration(Duration duration) {
    final totalMs = math.max(0, duration.inMilliseconds);
    final minutes = totalMs ~/ 60000;
    final seconds = (totalMs % 60000) ~/ 1000;
    final millis = totalMs % 1000;
    return '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}.'
        '${millis.toString().padLeft(3, '0')}';
  }

  ClipCropSettings _centerCropForAspect(
    TimelineClip clip,
    double targetAspect,
  ) {
    final timeline = ref.read(editorProvider).timeline;
    final asset = timeline.assetForClip(clip);
    var width = (asset?.metadata['width'] as num?)?.toDouble() ?? 0;
    var height = (asset?.metadata['height'] as num?)?.toDouble() ?? 0;
    if (width <= 0 || height <= 0) {
      final canvasAspect = _selectedAspectRatioValue;
      width = canvasAspect ?? 16 / 9;
      height = 1;
    }
    final sourceAspect = width / height;
    if ((sourceAspect - targetAspect).abs() < 0.001) {
      return const ClipCropSettings();
    }
    if (sourceAspect > targetAspect) {
      final visibleWidth = (targetAspect / sourceAspect).clamp(0.05, 1.0);
      final inset = (1 - visibleWidth) / 2;
      return ClipCropSettings(left: inset, right: inset);
    }
    final visibleHeight = (sourceAspect / targetAspect).clamp(0.05, 1.0);
    final inset = (1 - visibleHeight) / 2;
    return ClipCropSettings(top: inset, bottom: inset);
  }

  Future<void> _openCropSheet(TimelineClip initialClip) async {
    final editorState = ref.read(editorProvider);
    final track = _trackForClip(initialClip, editorState);
    if (!_isVisualClip(initialClip) || track == null || track.isLocked) return;
    var clip = initialClip;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => StatefulBuilder(
        builder: (context, setSheetState) {
          void update(ClipCropSettings crop, {bool recordHistory = true}) {
            _updateTimelineClip(
              clip,
              (current) => current.copyWith(crop: crop),
              recordHistory: recordHistory,
            );
            final latest = _clipById(clip.id, ref.read(editorProvider));
            if (latest != null) setSheetState(() => clip = latest);
          }

          Widget cropSlider({
            required String label,
            required double value,
            required double opposite,
            required ClipCropSettings Function(double value) mapper,
          }) {
            final max = math.max(0.0, 0.9 - opposite);
            return Column(
              children: [
                _sheetSliderHeader(label, '${(value * 100).round()}%'),
                Slider(
                  value: value.clamp(0, max),
                  min: 0,
                  max: math.max(0.01, max),
                  divisions: math.max(1, (max * 100).round()),
                  onChangeStart: (_) => ref
                      .read(editorProvider.notifier)
                      .beginTimelineGestureEdit(),
                  onChanged: (next) =>
                      update(mapper(next), recordHistory: false),
                  onChangeEnd: (_) => ref
                      .read(editorProvider.notifier)
                      .endTimelineGestureEdit(),
                ),
              ],
            );
          }

          final crop = clip.crop;
          return _buildEditorSheet(
            title: 'Crop',
            subtitle: 'Non-destructive and reusable on any visual clip',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _sheetSectionTitle('ASPECT PRESETS'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ActionChip(
                      avatar: const Icon(Icons.restart_alt_rounded, size: 16),
                      label: const Text('Original'),
                      onPressed: () => update(const ClipCropSettings()),
                    ),
                    for (final preset in const [
                      (1.0, '1:1'),
                      (16 / 9, '16:9'),
                      (9 / 16, '9:16'),
                      (4 / 5, '4:5'),
                    ])
                      ActionChip(
                        label: Text(preset.$2),
                        onPressed: () =>
                            update(_centerCropForAspect(clip, preset.$1)),
                      ),
                  ],
                ),
                const SizedBox(height: 18),
                _sheetSectionTitle('FREE CROP'),
                cropSlider(
                  label: 'Left',
                  value: crop.safeLeft,
                  opposite: crop.safeRight,
                  mapper: (value) => crop.copyWith(left: value),
                ),
                cropSlider(
                  label: 'Right',
                  value: crop.safeRight,
                  opposite: crop.safeLeft,
                  mapper: (value) => crop.copyWith(right: value),
                ),
                cropSlider(
                  label: 'Top',
                  value: crop.safeTop,
                  opposite: crop.safeBottom,
                  mapper: (value) => crop.copyWith(top: value),
                ),
                cropSlider(
                  label: 'Bottom',
                  value: crop.safeBottom,
                  opposite: crop.safeTop,
                  mapper: (value) => crop.copyWith(bottom: value),
                ),
                const SizedBox(height: 8),
                Text(
                  'Visible area: ${(crop.visibleWidth * 100).round()}% × '
                  '${(crop.visibleHeight * 100).round()}%',
                  style: const TextStyle(color: kTextSecondary, fontSize: 11),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _openFilterSheet(TimelineClip initialClip) async {
    final isExistingFilter =
        initialClip.type == TimelineTrackType.effect &&
        initialClip.effectKind == TimelineEffectKind.filter;
    final editorState = ref.read(editorProvider);
    final track = _trackForClip(initialClip, editorState);
    if (track == null ||
        track.isLocked ||
        (!isExistingFilter && !initialClip.supportsVisualEffects)) {
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _buildEditorSheet(
        title: isExistingFilter
            ? 'Change filter overlay'
            : 'Add filter overlay',
        subtitle: isExistingFilter
            ? 'Choose a preset for this timeline overlay'
            : 'The preset becomes a draggable, resizable timeline clip',
        child: Wrap(
          spacing: 10,
          runSpacing: 10,
          children: ClipFilterPreset.values
              .where((preset) => preset != ClipFilterPreset.original)
              .map((preset) {
                return ActionChip(
                  avatar: const Icon(Icons.tonality_rounded, size: 17),
                  label: Text(_filterPresetLabel(preset)),
                  onPressed: () {
                    if (isExistingFilter) {
                      _replaceFilterEffect(initialClip, preset);
                    } else {
                      final adjustments = ClipColorAdjustments.forPreset(
                        preset,
                      );
                      _addEffectOverlay(
                        anchor: initialClip,
                        kind: TimelineEffectKind.filter,
                        label: '${_filterPresetLabel(preset)} filter',
                        colorAdjustments: adjustments,
                      );
                    }
                    Navigator.pop(context);
                  },
                );
              })
              .toList(),
        ),
      ),
    );
  }

  Future<void> _openColorAdjustmentsSheet(TimelineClip initialClip) async {
    final initialState = ref.read(editorProvider);
    final initialTrack = _trackForClip(initialClip, initialState);
    final isFilterEffect =
        initialClip.isEffect &&
        initialClip.effectKind == TimelineEffectKind.filter;
    if (initialTrack == null ||
        initialTrack.isLocked ||
        (!isFilterEffect && !initialClip.supportsVisualEffects)) {
      return;
    }
    var clip = _clipById(initialClip.id, initialState) ?? initialClip;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => StatefulBuilder(
        builder: (context, setSheetState) {
          void update(
            ClipColorAdjustments Function(ClipColorAdjustments current)
            mapper, {
            bool recordHistory = true,
          }) {
            _updateTimelineClip(
              clip,
              (current) => current.copyWith(
                colorAdjustments: mapper(current.colorAdjustments),
              ),
              recordHistory: recordHistory,
            );
            final latest = _clipById(clip.id, ref.read(editorProvider));
            if (latest != null) setSheetState(() => clip = latest);
          }

          final adjustments = clip.colorAdjustments;
          Widget adjustmentSlider({
            required String label,
            required double value,
            required double minimum,
            required double maximum,
            required ClipColorAdjustments Function(double value) mapper,
            String Function(double value)? formatter,
          }) {
            final format =
                formatter ?? (candidate) => '${(candidate * 100).round()}%';
            return Column(
              children: [
                _sheetSliderHeader(label, format(value)),
                Slider(
                  value: value.clamp(minimum, maximum).toDouble(),
                  min: minimum,
                  max: maximum,
                  divisions: 100,
                  label: format(value),
                  onChangeStart: (_) => ref
                      .read(editorProvider.notifier)
                      .beginTimelineGestureEdit(),
                  onChanged: (next) =>
                      update((_) => mapper(next), recordHistory: false),
                  onChangeEnd: (_) => ref
                      .read(editorProvider.notifier)
                      .endTimelineGestureEdit(),
                ),
              ],
            );
          }

          return _buildEditorSheet(
            title: 'Color correction',
            subtitle:
                'Color and vignette preview live; spatial sharpening is finalized on export',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                adjustmentSlider(
                  label: 'Brightness',
                  value: adjustments.brightness,
                  minimum: -1,
                  maximum: 1,
                  mapper: (value) => adjustments.copyWith(brightness: value),
                ),
                adjustmentSlider(
                  label: 'Contrast',
                  value: adjustments.contrast,
                  minimum: 0.1,
                  maximum: 3,
                  formatter: (value) => '${value.toStringAsFixed(2)}×',
                  mapper: (value) => adjustments.copyWith(contrast: value),
                ),
                adjustmentSlider(
                  label: 'Saturation',
                  value: adjustments.saturation,
                  minimum: 0,
                  maximum: 3,
                  formatter: (value) => '${value.toStringAsFixed(2)}×',
                  mapper: (value) => adjustments.copyWith(saturation: value),
                ),
                adjustmentSlider(
                  label: 'Temperature',
                  value: adjustments.temperature,
                  minimum: -1,
                  maximum: 1,
                  mapper: (value) => adjustments.copyWith(temperature: value),
                ),
                adjustmentSlider(
                  label: 'Fade',
                  value: adjustments.fade,
                  minimum: 0,
                  maximum: 1,
                  mapper: (value) => adjustments.copyWith(fade: value),
                ),
                adjustmentSlider(
                  label: 'Vignette',
                  value: adjustments.vignette,
                  minimum: 0,
                  maximum: 1,
                  mapper: (value) => adjustments.copyWith(vignette: value),
                ),
                adjustmentSlider(
                  label: 'Sharpen (export)',
                  value: adjustments.sharpen,
                  minimum: 0,
                  maximum: 1,
                  mapper: (value) => adjustments.copyWith(sharpen: value),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () => update((_) => const ClipColorAdjustments()),
                  icon: const Icon(Icons.restart_alt_rounded),
                  label: const Text('Reset color correction'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _openCanvasSettingsSheet() async {
    var canvas = ref.read(editorProvider).timeline.canvasSettings;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => StatefulBuilder(
        builder: (context, setSheetState) {
          void update(CanvasSettings next, {bool recordHistory = true}) {
            setSheetState(() => canvas = next);
            _updateCanvasSettings((_) => next, recordHistory: recordHistory);
          }

          const backgroundColors = [
            Colors.black,
            Color(0xFF111512),
            Color(0xFF202420),
            Color(0xFFF3F0E7),
            Color(0xFF17324D),
            Color(0xFF4A2318),
          ];
          return _buildEditorSheet(
            title: 'Canvas',
            subtitle: 'Format, background and guides',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _sheetSectionTitle('FORMAT'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: CanvasAspectRatioPreset.values.map((preset) {
                    final label = switch (preset) {
                      CanvasAspectRatioPreset.original => 'Original',
                      CanvasAspectRatioPreset.ratio16x9 => '16:9',
                      CanvasAspectRatioPreset.ratio9x16 => '9:16',
                      CanvasAspectRatioPreset.ratio1x1 => '1:1',
                      CanvasAspectRatioPreset.ratio4x5 => '4:5',
                    };
                    return ChoiceChip(
                      label: Text(label),
                      selected: canvas.aspectRatioPreset == preset,
                      onSelected: (_) {
                        update(canvas.copyWith(aspectRatioPreset: preset));
                        setState(() {
                          _canvasAspectRatio = _canvasAspectRatioFromPreset(
                            preset,
                          );
                        });
                      },
                    );
                  }).toList(),
                ),
                const SizedBox(height: 20),
                _sheetSectionTitle('BACKGROUND'),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 12,
                  children: backgroundColors.map((color) {
                    final selected = canvas.backgroundColor == color;
                    return InkWell(
                      borderRadius: BorderRadius.circular(999),
                      onTap: () =>
                          update(canvas.copyWith(backgroundColor: color)),
                      child: Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: selected ? kAccent : kBorder,
                            width: selected ? 3 : 1,
                          ),
                        ),
                        child: selected
                            ? Icon(
                                Icons.check_rounded,
                                color: color.computeLuminance() > 0.5
                                    ? Colors.black
                                    : Colors.white,
                                size: 18,
                              )
                            : null,
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 18),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Title and action safe areas'),
                  subtitle: const Text('Preview guides are never exported'),
                  value: canvas.showSafeAreas,
                  onChanged: (value) =>
                      update(canvas.copyWith(showSafeAreas: value)),
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Composition grid'),
                  subtitle: Text(
                    '${canvas.gridDivisions} × ${canvas.gridDivisions}',
                  ),
                  value: canvas.showGrid,
                  onChanged: (value) =>
                      update(canvas.copyWith(showGrid: value)),
                ),
                if (canvas.showGrid)
                  Slider(
                    value: canvas.gridDivisions.toDouble(),
                    min: 2,
                    max: 6,
                    divisions: 4,
                    label: '${canvas.gridDivisions}',
                    onChanged: (value) =>
                        update(canvas.copyWith(gridDivisions: value.round())),
                  ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Snap objects to guides'),
                  value: canvas.snapToGuides,
                  onChanged: (value) =>
                      update(canvas.copyWith(snapToGuides: value)),
                ),
                const SizedBox(height: 4),
                OutlinedButton.icon(
                  onPressed:
                      !canvas.showGrid &&
                          !canvas.showSafeAreas &&
                          !canvas.snapToGuides
                      ? null
                      : () => update(
                          canvas.copyWith(
                            showGrid: false,
                            showSafeAreas: false,
                            snapToGuides: false,
                          ),
                        ),
                  icon: const Icon(Icons.layers_clear_rounded),
                  label: const Text('Clear all guides'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _openCreatorLab() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => CreatorLabScreen(projectName: _projectSnapshot.name),
      ),
    );
  }

  Future<void> _openSubtitleToolsSheet() async {
    final hasLockedSubtitleLane = ref
        .read(editorProvider)
        .timeline
        .tracks
        .any(
          (track) => track.type == TimelineTrackType.subtitle && track.isLocked,
        );
    if (hasLockedSubtitleLane) {
      SnackBarHelper.showInfo(
        context,
        'Unlock the subtitle track before editing captions.',
      );
      return;
    }
    var report = SubtitleQualityService.analyze(
      ref.read(subtitleProvider).entries,
    );
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => StatefulBuilder(
        builder: (context, setSheetState) {
          void refreshReport() {
            setSheetState(() {
              report = SubtitleQualityService.analyze(
                ref.read(subtitleProvider).entries,
              );
            });
          }

          return _buildEditorSheet(
            title: 'Caption workshop',
            subtitle:
                '${report.cueCount} cues • '
                '${report.averageCharactersPerSecond.toStringAsFixed(1)} avg CPS',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: report.isClean
                        ? kSuccess.withValues(alpha: 0.08)
                        : kWarning.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: report.isClean
                          ? kSuccess.withValues(alpha: 0.28)
                          : kWarning.withValues(alpha: 0.28),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        report.isClean
                            ? Icons.verified_rounded
                            : Icons.rule_rounded,
                        color: report.isClean ? kSuccess : kWarning,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          report.isClean
                              ? 'Captions pass readability checks'
                              : '${report.issues.length} readability issues found',
                          style: TextStyle(
                            color: kTextPrimary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (!report.isClean) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: SubtitleIssueType.values
                        .where((type) => report.countFor(type) > 0)
                        .map(
                          (type) => Chip(
                            label: Text(
                              '${_subtitleIssueLabel(type)} '
                              '${report.countFor(type)}',
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ],
                const SizedBox(height: 14),
                _sheetSectionTitle('EDIT'),
                const SizedBox(height: 8),
                _sheetListAction(
                  icon: Icons.search_rounded,
                  title: 'Find and replace',
                  subtitle: 'Change repeated words across every cue',
                  onTap: () async {
                    await _showSubtitleFindReplaceDialog();
                    refreshReport();
                  },
                ),
                _sheetListAction(
                  icon: Icons.more_time_rounded,
                  title: 'Shift all timings',
                  subtitle: 'Move the complete subtitle track earlier or later',
                  onTap: () async {
                    await _showSubtitleShiftDialog();
                    refreshReport();
                  },
                ),
                _sheetListAction(
                  icon: Icons.auto_fix_high_rounded,
                  title: 'Normalize spacing',
                  subtitle: 'Clean repeated spaces and ragged line breaks',
                  onTap: () {
                    ref.read(subtitleProvider.notifier).normalizeText();
                    refreshReport();
                  },
                ),
                _sheetListAction(
                  icon: Icons.format_line_spacing_rounded,
                  title: 'Resolve overlaps',
                  subtitle: 'Insert an 80ms gap where cues collide',
                  onTap: () {
                    ref.read(subtitleProvider.notifier).fixOverlaps();
                    refreshReport();
                  },
                ),
                const SizedBox(height: 14),
                _sheetSectionTitle('CASE'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: SubtitleTextCase.values.map((textCase) {
                    return ActionChip(
                      label: Text(switch (textCase) {
                        SubtitleTextCase.sentence => 'Sentence',
                        SubtitleTextCase.upper => 'UPPER',
                        SubtitleTextCase.lower => 'lower',
                        SubtitleTextCase.title => 'Title Case',
                      }),
                      onPressed: () {
                        ref
                            .read(subtitleProvider.notifier)
                            .convertCase(textCase);
                        refreshReport();
                      },
                    );
                  }).toList(),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: () {
                    final playhead = ref.read(playbackProvider).position;
                    final duration = ref.read(editorProvider).timeline.duration;
                    final end = playhead + const Duration(seconds: 2);
                    ref
                        .read(subtitleProvider.notifier)
                        .addEntry(playhead, end > duration ? duration : end);
                    refreshReport();
                  },
                  icon: const Icon(Icons.add_comment_rounded),
                  label: const Text('Add cue at playhead'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _showSubtitleFindReplaceDialog() async {
    final findController = TextEditingController();
    final replaceController = TextEditingController();
    var matchCase = false;
    final shouldReplace = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Find and replace'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: findController,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Find'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: replaceController,
                decoration: const InputDecoration(labelText: 'Replace with'),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Match case'),
                value: matchCase,
                onChanged: (value) =>
                    setDialogState(() => matchCase = value ?? false),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Replace all'),
            ),
          ],
        ),
      ),
    );
    if (shouldReplace == true) {
      final count = ref
          .read(subtitleProvider.notifier)
          .replaceText(
            query: findController.text,
            replacement: replaceController.text,
            matchCase: matchCase,
          );
      if (mounted) {
        SnackBarHelper.showInfo(context, '$count replacements made');
      }
    }
    findController.dispose();
    replaceController.dispose();
  }

  Future<void> _showSubtitleShiftDialog() async {
    final controller = TextEditingController(text: '0');
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Shift subtitle timings'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(signed: true),
          decoration: const InputDecoration(
            labelText: 'Milliseconds',
            helperText: 'Negative moves cues earlier',
            prefixText: '± ',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    controller.dispose();
    final milliseconds = int.tryParse(result?.trim() ?? '');
    if (milliseconds == null || milliseconds == 0) return;
    ref
        .read(subtitleProvider.notifier)
        .shiftAll(
          Duration(milliseconds: milliseconds),
          projectDuration: ref.read(editorProvider).timeline.duration,
        );
  }

  Future<void> _relinkClipMedia(TimelineClip clip) async {
    try {
      final fileType = switch (clip.type) {
        TimelineTrackType.audio => FileType.audio,
        TimelineTrackType.video => FileType.video,
        _ => FileType.image,
      };
      final result = await FilePicker.platform.pickFiles(
        type: fileType,
        allowMultiple: false,
      );
      final file = result?.files.firstOrNull;
      final selectedPath = file?.path;
      if (selectedPath == null) return;
      final sourcePath = await MediaImportService.persistFile(
        selectedPath,
        originalFileName: file!.name,
      );
      final mediaInfo =
          clip.type == TimelineTrackType.image ||
              clip.type == TimelineTrackType.gif ||
              clip.type == TimelineTrackType.sticker
          ? <String, dynamic>{}
          : await FFmpegService.getMediaInfo(sourcePath);
      if (!mounted) return;
      final editorState = ref.read(editorProvider);
      final timeline = editorState.timeline;
      final assets = timeline.assets.map((asset) {
        if (asset.id != clip.assetId) return asset;
        return asset.copyWith(
          label: file.name,
          sourcePath: sourcePath,
          clearRemoteUrl: true,
          isNetworkBacked: false,
          metadata: {...asset.metadata, ...mediaInfo},
        );
      }).toList();
      ref
          .read(editorProvider.notifier)
          .setTimeline(timeline.copyWith(assets: assets));
      SnackBarHelper.showSuccess(context, 'Media relinked');
    } catch (error) {
      if (mounted) {
        SnackBarHelper.showError(
          context,
          'Could not relink media: ${error.toString().replaceFirst('Exception: ', '')}',
        );
      }
    }
  }

  Widget _buildEditorSheet({
    required String title,
    required String subtitle,
    required Widget child,
  }) {
    return SafeArea(
      top: false,
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.40,
        ),
        decoration: const BoxDecoration(
          color: kSurface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 42,
              height: 4,
              decoration: BoxDecoration(
                color: kBorder,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: TextStyle(
                            color: kTextPrimary,
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: kTextSecondary, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 28),
                child: child,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sheetSectionTitle(String label) {
    return Text(
      label,
      style: TextStyle(
        color: kTextSecondary,
        fontSize: 10,
        fontWeight: FontWeight.w800,
        letterSpacing: 1.1,
      ),
    );
  }

  Widget _sheetSliderHeader(String label, String value) {
    return Row(
      children: [
        Text(label, style: TextStyle(color: kTextPrimary, fontSize: 13)),
        const Spacer(),
        Text(
          value,
          style: TextStyle(
            fontFamily: 'monospace',
            color: kTextSecondary,
            fontSize: 11,
          ),
        ),
      ],
    );
  }

  Widget _sheetActionTile({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool active = false,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        decoration: BoxDecoration(
          color: active ? kAccent.withValues(alpha: 0.12) : kSurfaceElevated,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: active ? kAccent : kBorder),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: active ? kAccent : kTextSecondary, size: 17),
            const SizedBox(width: 7),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: active ? kAccent : kTextPrimary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sheetListAction({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: kSurfaceElevated,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: kBorder),
        ),
        child: Icon(icon, color: kTextSecondary, size: 19),
      ),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: onTap,
    );
  }

  String _filterPresetLabel(ClipFilterPreset preset) {
    return switch (preset) {
      ClipFilterPreset.original => 'Original',
      ClipFilterPreset.cinematic => 'Cinema',
      ClipFilterPreset.warm => 'Warm',
      ClipFilterPreset.cool => 'Cool',
      ClipFilterPreset.vivid => 'Vivid',
      ClipFilterPreset.muted => 'Muted',
      ClipFilterPreset.monochrome => 'Mono',
      ClipFilterPreset.vintage => 'Vintage',
    };
  }

  String _subtitleIssueLabel(SubtitleIssueType type) {
    return switch (type) {
      SubtitleIssueType.overlap => 'Overlap',
      SubtitleIssueType.tooFast => 'Too fast',
      SubtitleIssueType.tooLong => 'Too long',
      SubtitleIssueType.tooShort => 'Too short',
      SubtitleIssueType.tooManyLines => 'Too many lines',
      SubtitleIssueType.longLine => 'Long line',
      SubtitleIssueType.lowConfidence => 'Review',
      SubtitleIssueType.empty => 'Empty',
    };
  }

  Widget _buildPortrait(BuildContext context, TimelineClip? selectedClip) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const actionBarHeight = 64.0;
        final workspaceHeight = math.max(
          0.0,
          constraints.maxHeight - actionBarHeight,
        );
        final minimumTimelineHeight = math.min(230.0, workspaceHeight * 0.55);
        final availablePreviewHeight = math.max(
          0.0,
          workspaceHeight - minimumTimelineHeight,
        );
        final minimumPreviewHeight = math.min(190.0, availablePreviewHeight);
        final maximumPreviewHeight = math.min(420.0, availablePreviewHeight);
        final previewHeight = (workspaceHeight * 0.43)
            .clamp(minimumPreviewHeight, maximumPreviewHeight)
            .toDouble();

        return Column(
          children: [
            SizedBox(height: previewHeight, child: _buildVideoPreview()),
            Expanded(child: _buildTimelinePanel()),
            _buildBottomQuickActions(context, selectedClip),
          ],
        );
      },
    );
  }

  Widget _buildLandscape(BuildContext context, TimelineClip? selectedClip) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const actionBarHeight = 64.0;
        final workspaceHeight = math.max(
          0.0,
          constraints.maxHeight - actionBarHeight,
        );
        final useSideBySideWorkspace = constraints.maxHeight < 560;

        final workspace = useSideBySideWorkspace
            ? Row(
                children: [
                  Expanded(flex: 5, child: _buildVideoPreview()),
                  const VerticalDivider(width: 1, thickness: 1, color: kBorder),
                  Expanded(flex: 6, child: _buildTimelinePanel()),
                ],
              )
            : _buildTallLandscapeWorkspace(workspaceHeight);

        return Column(
          children: [
            Expanded(child: workspace),
            _buildBottomQuickActions(context, selectedClip),
          ],
        );
      },
    );
  }

  Widget _buildTallLandscapeWorkspace(double workspaceHeight) {
    final minimumTimelineHeight = math.min(300.0, workspaceHeight * 0.48);
    final availablePreviewHeight = math.max(
      0.0,
      workspaceHeight - minimumTimelineHeight,
    );
    final minimumPreviewHeight = math.min(230.0, availablePreviewHeight);
    final maximumPreviewHeight = math.min(420.0, availablePreviewHeight);
    final previewHeight = (workspaceHeight * 0.48)
        .clamp(minimumPreviewHeight, maximumPreviewHeight)
        .toDouble();

    return Column(
      children: [
        SizedBox(height: previewHeight, child: _buildVideoPreview()),
        Expanded(child: _buildTimelinePanel()),
      ],
    );
  }

  Widget _buildVideoPreview() {
    return VideoPreviewPanel(
      key: _previewKey,
      videoPath: widget.project.videoPath,
      targetAspectRatio: _selectedAspectRatioValue,
      onFullscreenToggle: () => _setPreviewFullscreen(true),
    );
  }

  Widget _buildTimelinePanel() {
    return TimelinePanel(
      onEditRequested: _openSubtitleTextEditor,
      onTextClipEditRequested: _editTextClip,
      onTransitionRequested: _openTransitionSheet,
      onOverlayAddRequested: _pickOverlayMediaForTrack,
    );
  }

  Widget _buildFullscreenPreview() {
    return ColoredBox(
      color: Colors.black,
      child: SafeArea(
        child: VideoPreviewPanel(
          key: _previewKey,
          videoPath: widget.project.videoPath,
          targetAspectRatio: _selectedAspectRatioValue,
          isFullscreen: true,
          onFullscreenToggle: () => _setPreviewFullscreen(false),
        ),
      ),
    );
  }

  void _setPreviewFullscreen(bool fullscreen) {
    if (_isPreviewFullscreen == fullscreen || !mounted) return;
    setState(() => _isPreviewFullscreen = fullscreen);
    unawaited(
      SystemChrome.setEnabledSystemUIMode(
        fullscreen ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
      ),
    );
  }

  PopupMenuButton<_CanvasAspectRatio> _buildAspectRatioPicker() {
    return PopupMenuButton<_CanvasAspectRatio>(
      tooltip: 'Aspect ratio',
      color: kSurface,
      onSelected: (value) {
        setState(() => _canvasAspectRatio = value);
        final editorState = ref.read(editorProvider);
        ref
            .read(editorProvider.notifier)
            .setTimeline(
              editorState.timeline.copyWith(
                canvasSettings: editorState.timeline.canvasSettings.copyWith(
                  aspectRatioPreset: _canvasPresetFromRatio(value),
                ),
              ),
            );
      },
      itemBuilder: (_) => [
        _aspectMenuItem(_CanvasAspectRatio.original, 'Original'),
        _aspectMenuItem(_CanvasAspectRatio.ratio16x9, '16:9'),
        _aspectMenuItem(_CanvasAspectRatio.ratio9x16, '9:16'),
        _aspectMenuItem(_CanvasAspectRatio.ratio1x1, '1:1'),
        _aspectMenuItem(_CanvasAspectRatio.ratio4x5, '4:5'),
      ],
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: kSurface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: kBorder),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.crop_rounded, size: 16, color: kTextSecondary),
            const SizedBox(width: 6),
            Text(
              _aspectRatioLabel(_canvasAspectRatio),
              style: TextStyle(
                color: kTextSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  PopupMenuItem<_CanvasAspectRatio> _aspectMenuItem(
    _CanvasAspectRatio ratio,
    String label,
  ) {
    return PopupMenuItem(
      value: ratio,
      child: Row(
        children: [
          if (_canvasAspectRatio == ratio) ...[
            const Icon(Icons.check_rounded, size: 16, color: kAccent),
            const SizedBox(width: 8),
          ],
          Text(label, style: TextStyle(color: kTextPrimary)),
        ],
      ),
    );
  }

  String _aspectRatioLabel(_CanvasAspectRatio ratio) {
    switch (ratio) {
      case _CanvasAspectRatio.original:
        return 'Original';
      case _CanvasAspectRatio.ratio16x9:
        return '16:9';
      case _CanvasAspectRatio.ratio9x16:
        return '9:16';
      case _CanvasAspectRatio.ratio1x1:
        return '1:1';
      case _CanvasAspectRatio.ratio4x5:
        return '4:5';
    }
  }

  _CanvasAspectRatio _canvasAspectRatioFromPreset(
    CanvasAspectRatioPreset preset,
  ) {
    return switch (preset) {
      CanvasAspectRatioPreset.original => _CanvasAspectRatio.original,
      CanvasAspectRatioPreset.ratio16x9 => _CanvasAspectRatio.ratio16x9,
      CanvasAspectRatioPreset.ratio9x16 => _CanvasAspectRatio.ratio9x16,
      CanvasAspectRatioPreset.ratio1x1 => _CanvasAspectRatio.ratio1x1,
      CanvasAspectRatioPreset.ratio4x5 => _CanvasAspectRatio.ratio4x5,
    };
  }

  CanvasAspectRatioPreset _canvasPresetFromRatio(_CanvasAspectRatio ratio) {
    return switch (ratio) {
      _CanvasAspectRatio.original => CanvasAspectRatioPreset.original,
      _CanvasAspectRatio.ratio16x9 => CanvasAspectRatioPreset.ratio16x9,
      _CanvasAspectRatio.ratio9x16 => CanvasAspectRatioPreset.ratio9x16,
      _CanvasAspectRatio.ratio1x1 => CanvasAspectRatioPreset.ratio1x1,
      _CanvasAspectRatio.ratio4x5 => CanvasAspectRatioPreset.ratio4x5,
    };
  }

  double? get _selectedAspectRatioValue {
    switch (_canvasAspectRatio) {
      case _CanvasAspectRatio.original:
        return null;
      case _CanvasAspectRatio.ratio16x9:
        return 16 / 9;
      case _CanvasAspectRatio.ratio9x16:
        return 9 / 16;
      case _CanvasAspectRatio.ratio1x1:
        return 1;
      case _CanvasAspectRatio.ratio4x5:
        return 4 / 5;
    }
  }

  Future<void> _openSubtitleTextEditor(SubtitleEntry entry) async {
    final editorState = ref.read(editorProvider);
    final clip = _clipById(entry.id, editorState);
    final track = clip == null ? null : _trackForClip(clip, editorState);
    if (track?.isLocked == true) return;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => SubtitleEditModal(entry: entry),
    );
  }

  Future<void> _pickOverlayMedia() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: false,
        type: FileType.custom,
        allowedExtensions: ['png', 'jpg', 'jpeg', 'webp', 'gif', 'mp4', 'mov'],
      );
      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      final selectedPath = file.path;
      if (selectedPath == null) return;
      final filePath = await MediaImportService.persistFile(
        selectedPath,
        originalFileName: file.name,
      );

      final extension = path.extension(filePath).toLowerCase();
      final assetType = switch (extension) {
        '.png' || '.jpg' || '.jpeg' || '.webp' => EditorAssetType.image,
        '.gif' => EditorAssetType.gif,
        '.mp4' || '.mov' => EditorAssetType.video,
        _ => EditorAssetType.unknown,
      };
      if (assetType == EditorAssetType.unknown) {
        SnackBarHelper.showWarning(context, 'Unsupported overlay file type.');
        return;
      }

      final clipType = switch (assetType) {
        EditorAssetType.image => TimelineTrackType.image,
        EditorAssetType.gif => TimelineTrackType.gif,
        EditorAssetType.video => TimelineTrackType.video,
        _ => TimelineTrackType.image,
      };

      Duration? sourceDuration;
      Map<String, dynamic> metadata = const {};
      if (assetType == EditorAssetType.video) {
        final mediaInfo = await FFmpegService.getMediaInfo(filePath);
        sourceDuration = Duration(
          milliseconds: (mediaInfo['durationMs'] as int?) ?? 0,
        );
        if (sourceDuration <= Duration.zero) {
          throw Exception('Could not read the selected video duration.');
        }
        metadata = {
          'durationMs': mediaInfo['durationMs'],
          'width': mediaInfo['width'],
          'height': mediaInfo['height'],
          'hasAudio': mediaInfo['hasAudio'],
          'frameRate': mediaInfo['frameRate'],
        };
      }

      if (!mounted) return;

      _insertClipIntoTimeline(
        section: TimelineTrackSection.overlay,
        assetType: assetType,
        clipType: clipType,
        sourcePath: filePath,
        label: file.name,
        sourceDuration: sourceDuration,
        metadata: metadata,
      );
    } catch (error) {
      if (mounted) {
        SnackBarHelper.showError(
          context,
          'Could not add overlay: ${error.toString().replaceFirst('Exception: ', '')}',
        );
      }
    }
  }

  Future<void> _pickOverlayMediaForTrack(TimelineTrack track) async {
    ref.read(editorProvider.notifier).selectTrack(track.id);
    await _pickOverlayMedia();
  }

  Future<void> _pickAudioMedia() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: false,
        type: FileType.audio,
      );
      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      final selectedPath = file.path;
      if (selectedPath == null) return;
      final filePath = await MediaImportService.persistFile(
        selectedPath,
        originalFileName: file.name,
      );

      final mediaInfo = await FFmpegService.getMediaInfo(filePath);
      final duration = Duration(
        milliseconds: (mediaInfo['durationMs'] as int?) ?? 0,
      );
      if (duration <= Duration.zero) {
        throw Exception('Could not read the selected audio duration.');
      }

      if (!mounted) return;

      _insertClipIntoTimeline(
        section: TimelineTrackSection.audio,
        assetType: EditorAssetType.audio,
        clipType: TimelineTrackType.audio,
        sourcePath: filePath,
        label: file.name,
        sourceDuration: duration,
        metadata: {
          'durationMs': mediaInfo['durationMs'],
          'hasAudio': mediaInfo['hasAudio'],
        },
      );
    } catch (error) {
      if (mounted) {
        SnackBarHelper.showError(
          context,
          'Could not add audio: ${error.toString().replaceFirst('Exception: ', '')}',
        );
      }
    }
  }

  Duration _currentCompositionDuration(EditorTimeline timeline) {
    return timeline.baseVideoDuration > Duration.zero
        ? timeline.baseVideoDuration
        : timeline.duration;
  }

  void _insertClipIntoTimeline({
    required TimelineTrackSection section,
    required EditorAssetType assetType,
    required TimelineTrackType clipType,
    String? sourcePath,
    String? remoteUrl,
    bool isNetworkBacked = false,
    required String label,
    required Duration? sourceDuration,
    Map<String, dynamic> metadata = const {},
  }) {
    final editorState = ref.read(editorProvider);
    final timeline = editorState.timeline;
    final existingTrack = _resolveInsertionTrack(timeline, section, clipType);
    final targetTrack =
        existingTrack ?? _createOptionalTrack(timeline, section, clipType);
    if (targetTrack == null) return;
    if (!targetTrack.acceptsClipType(clipType)) {
      SnackBarHelper.showInfo(
        context,
        'Add or unlock a compatible track before inserting this clip.',
      );
      return;
    }
    final workingTracks = existingTrack == null
        ? [...timeline.tracks, targetTrack]
        : timeline.tracks;

    final playhead = ref.read(playbackProvider).position;
    final maxDuration = _currentCompositionDuration(timeline);
    final defaultDuration =
        sourceDuration == null || sourceDuration == Duration.zero
        ? const Duration(seconds: 4)
        : sourceDuration;
    final endTime = playhead + defaultDuration > maxDuration
        ? maxDuration
        : playhead + defaultDuration;
    if (endTime <= playhead) {
      SnackBarHelper.showInfo(
        context,
        'Move the playhead earlier to add media.',
      );
      return;
    }

    final asset = EditorAssetReference(
      type: assetType,
      label: label,
      sourcePath: sourcePath,
      remoteUrl: remoteUrl,
      isNetworkBacked: isNetworkBacked,
      metadata: metadata,
    );
    final audioMix =
        assetType == EditorAssetType.video &&
            section == TimelineTrackSection.overlay
        ? const AudioMixSettings(muted: true, volume: 1)
        : const AudioMixSettings();
    final clip = TimelineClip(
      trackId: targetTrack.id,
      type: clipType,
      label: label,
      assetId: asset.id,
      startTime: playhead,
      endTime: endTime,
      sourceStartTime: Duration.zero,
      sourceDuration: sourceDuration ?? (endTime - playhead),
      fitMode: section == TimelineTrackSection.overlay
          ? ClipFitMode.contain
          : ClipFitMode.cover,
      audioMix: audioMix,
    );

    final nextTracks = workingTracks.map((track) {
      if (track.id != targetTrack.id) return track;
      return track.copyWith(clips: [...track.clips, clip]);
    }).toList();
    final nextTimeline = timeline.copyWith(
      assets: [...timeline.assets, asset],
      tracks: nextTracks,
    );

    ref.read(editorProvider.notifier).setTimeline(nextTimeline);
    ref.read(editorProvider.notifier).selectTrack(targetTrack.id);
    ref.read(editorProvider.notifier).selectClip(clip.id);
    SnackBarHelper.showSuccess(context, '$label added at playhead');
  }

  Future<void> _openGiphyPickerSheet() async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.40,
      ),
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.4),
      builder: (_) => _GiphyPickerSheet(onSelected: _insertGiphyAsset),
    );
  }

  Future<void> _insertGiphyAsset(GiphyAssetResult result) async {
    _insertClipIntoTimeline(
      section: TimelineTrackSection.overlay,
      assetType: result.isSticker
          ? EditorAssetType.sticker
          : EditorAssetType.gif,
      clipType: result.isSticker
          ? TimelineTrackType.sticker
          : TimelineTrackType.gif,
      label: result.title,
      sourceDuration: const Duration(seconds: 4),
      remoteUrl: result.originalUrl,
      isNetworkBacked: true,
      metadata: {
        'previewUrl': result.previewUrl,
        'giphyId': result.id,
        'width': result.width,
        'height': result.height,
        'provider': 'giphy',
      },
    );
  }

  Future<void> _addTextClipAtPlayhead() async {
    final enteredText = await _showTextClipDialog();
    if (enteredText == null || enteredText.trim().isEmpty) return;

    final editorState = ref.read(editorProvider);
    final timeline = editorState.timeline;
    final existingTrack = _resolveInsertionTrack(
      timeline,
      TimelineTrackSection.textSubtitle,
      TimelineTrackType.text,
    );
    final targetTrack =
        existingTrack ??
        _createOptionalTrack(
          timeline,
          TimelineTrackSection.textSubtitle,
          TimelineTrackType.text,
        );
    if (targetTrack == null) return;
    if (!targetTrack.acceptsClipType(TimelineTrackType.text)) {
      SnackBarHelper.showInfo(
        context,
        'Add or unlock a text track before inserting text.',
      );
      return;
    }
    final workingTracks = existingTrack == null
        ? [...timeline.tracks, targetTrack]
        : timeline.tracks;

    final playhead = ref.read(playbackProvider).position;
    final maxDuration = _currentCompositionDuration(timeline);
    final endTime = (playhead + const Duration(seconds: 4)) > maxDuration
        ? maxDuration
        : playhead + const Duration(seconds: 4);
    if (endTime <= playhead) {
      SnackBarHelper.showInfo(
        context,
        'Move the playhead earlier to add text.',
      );
      return;
    }

    final clip = TimelineClip(
      trackId: targetTrack.id,
      type: TimelineTrackType.text,
      label: enteredText.trim(),
      text: enteredText.trim(),
      startTime: playhead,
      endTime: endTime,
      subtitleStyle: const SubtitleStyleModel(
        position: SubtitlePosition.center,
        fontSize: 32,
        maxWidthFactor: 0.75,
      ),
      fitMode: ClipFitMode.contain,
    );

    final nextTracks = workingTracks.map((track) {
      if (track.id != targetTrack.id) return track;
      return track.copyWith(clips: [...track.clips, clip]);
    }).toList();

    ref
        .read(editorProvider.notifier)
        .setTimeline(timeline.copyWith(tracks: nextTracks));
    ref.read(editorProvider.notifier).selectTrack(targetTrack.id);
    ref.read(editorProvider.notifier).selectClip(clip.id);
    SnackBarHelper.showSuccess(context, 'Text clip added at playhead');
  }

  Future<void> _editTextClip(TimelineClip clip) async {
    if (clip.type != TimelineTrackType.text) return;
    final currentState = ref.read(editorProvider);
    final currentTrack = _trackForClip(clip, currentState);
    if (currentTrack == null || currentTrack.isLocked) return;
    final enteredText = await _showTextClipDialog(
      initialValue: clip.text ?? '',
    );
    if (enteredText == null || enteredText.trim().isEmpty) return;

    final editorState = ref.read(editorProvider);
    final liveClip = _clipById(clip.id, editorState);
    final liveTrack = _trackForClip(liveClip, editorState);
    if (liveClip == null || liveTrack == null || liveTrack.isLocked) return;
    _updateTimelineClip(
      liveClip,
      (current) =>
          current.copyWith(label: enteredText.trim(), text: enteredText.trim()),
    );
    SnackBarHelper.showSuccess(context, 'Text updated');
  }

  Future<void> _openClipAnimationSheetForSelection(TimelineClip clip) async {
    final editorState = ref.read(editorProvider);
    final track = _trackForClip(clip, editorState);
    if (track == null || track.isLocked || !clip.supportsClipAnimation) return;
    await _openClipAnimationSheet(clip, track);
  }

  Future<String?> _showTextClipDialog({String initialValue = ''}) async {
    final controller = TextEditingController(text: initialValue);
    final focusNode = FocusNode();
    final result = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.40,
      ),
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final viewInsets = MediaQuery.of(sheetContext).viewInsets;
        return Padding(
          padding: EdgeInsets.only(bottom: viewInsets.bottom),
          child: Container(
            decoration: const BoxDecoration(
              color: kSurface,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 44,
                    height: 4,
                    decoration: BoxDecoration(
                      color: kBorder,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  initialValue.isEmpty ? 'Add Text Clip' : 'Edit Text Clip',
                  style: TextStyle(
                    color: kTextPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  focusNode: focusNode,
                  autofocus: true,
                  maxLines: 5,
                  minLines: 3,
                  style: TextStyle(color: kTextPrimary),
                  decoration: InputDecoration(
                    hintText: 'Type your text',
                    hintStyle: TextStyle(color: kTextSecondary),
                    filled: true,
                    fillColor: kSurfaceElevated,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: kBorder),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: kBorder),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: kAccent),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () {
                          focusNode.unfocus();
                          Navigator.of(sheetContext).pop();
                        },
                        child: const Text('Cancel'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () {
                          focusNode.unfocus();
                          Navigator.of(sheetContext).pop(controller.text);
                        },
                        child: const Text('Save'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
    focusNode.dispose();
    controller.dispose();
    return result;
  }

  void _updateSelectedClipTransition({
    required TimelineClip clip,
    bool updateIntro = false,
    bool updateOutro = true,
    TransitionType? type,
    int? durationMs,
  }) {
    final editorState = ref.read(editorProvider);
    final liveClip = _clipById(clip.id, editorState);
    final track = _trackForClip(liveClip, editorState);
    if (liveClip == null ||
        track == null ||
        track.isLocked ||
        !liveClip.supportsClipAnimation) {
      return;
    }
    _updateTimelineClip(
      liveClip,
      (current) => current.copyWith(
        introTransition: updateIntro
            ? current.introTransition.copyWith(
                type: type ?? current.introTransition.type,
                durationMs: durationMs ?? current.introTransition.durationMs,
              )
            : current.introTransition,
        outroTransition: updateOutro
            ? current.outroTransition.copyWith(
                type: type ?? current.outroTransition.type,
                durationMs: durationMs ?? current.outroTransition.durationMs,
              )
            : current.outroTransition,
      ),
    );
  }

  void _updateSelectedClipAudioMix(
    TimelineClip clip, {
    bool? muted,
    double? volume,
    int? fadeInMs,
    int? fadeOutMs,
    double? pan,
    bool? normalize,
  }) {
    final editorState = ref.read(editorProvider);
    final track = _trackForClip(clip, editorState);
    if (track == null ||
        track.isLocked ||
        !editorState.timeline.clipHasAudio(clip)) {
      return;
    }
    final nextTracks = editorState.timeline.tracks.map((track) {
      final nextClips = track.clips
          .map(
            (candidate) => candidate.id == clip.id
                ? candidate.copyWith(
                    audioMix: candidate.audioMix.copyWith(
                      muted: muted ?? candidate.audioMix.muted,
                      volume: volume ?? candidate.audioMix.volume,
                      fadeInMs: fadeInMs ?? candidate.audioMix.fadeInMs,
                      fadeOutMs: fadeOutMs ?? candidate.audioMix.fadeOutMs,
                      pan: pan ?? candidate.audioMix.pan,
                      normalize: normalize ?? candidate.audioMix.normalize,
                    ),
                  )
                : candidate,
          )
          .toList();
      return track.copyWith(clips: nextClips);
    }).toList();

    ref
        .read(editorProvider.notifier)
        .setTimeline(editorState.timeline.copyWith(tracks: nextTracks));
  }

  TimelineTrack? _resolveInsertionTrack(
    EditorTimeline timeline,
    TimelineTrackSection section,
    TimelineTrackType clipType,
  ) {
    final editorState = ref.read(editorProvider);
    return timeline.insertionTrackFor(
      section: section,
      clipType: clipType,
      preferredTrackId: editorState.selectedTrackId,
    );
  }

  TimelineTrack? _createOptionalTrack(
    EditorTimeline timeline,
    TimelineTrackSection section,
    TimelineTrackType clipType,
  ) {
    final isCompatibleType = switch (section) {
      TimelineTrackSection.overlay =>
        clipType.isVisualMedia || clipType == TimelineTrackType.effect,
      TimelineTrackSection.textSubtitle =>
        clipType == TimelineTrackType.text ||
            clipType == TimelineTrackType.subtitle,
      TimelineTrackSection.audio => clipType == TimelineTrackType.audio,
      TimelineTrackSection.baseVideo => false,
    };
    if (!isCompatibleType) return null;

    final name = switch (clipType) {
      TimelineTrackType.effect =>
        'Effects ${timeline.tracks.where((track) => track.type == clipType).length + 1}',
      TimelineTrackType.subtitle =>
        'Subtitles ${timeline.tracks.where((track) => track.type == clipType).length + 1}',
      _ => timeline.nextTrackNameForSection(section),
    };
    return TimelineTrack(name: name, type: clipType, section: section);
  }

  _SelectionCapabilities _selectionCapabilitiesFor(
    EditorState editorState,
    TimelineClip? selectedClip,
  ) {
    final selectedTrack = _trackForClip(selectedClip, editorState);
    final canEdit =
        selectedClip != null &&
        selectedTrack != null &&
        !selectedTrack.isLocked;
    final canVisualEffects = canEdit && selectedClip.supportsVisualEffects;
    final canTransform = canEdit && selectedClip.supportsVisualEffects;
    final canAnimate = canEdit && selectedClip.supportsClipAnimation;
    final canTransition =
        canEdit &&
        selectedTrack.section == TimelineTrackSection.baseVideo &&
        selectedClip.type == TimelineTrackType.video;
    final canAdjustAudio =
        canEdit && editorState.timeline.clipHasAudio(selectedClip);
    final canChangeLayer =
        canEdit && selectedTrack.section == TimelineTrackSection.overlay;
    final canArrange =
        canEdit && selectedClip.type != TimelineTrackType.subtitle;
    final isFilterEffect =
        canEdit &&
        selectedClip.type == TimelineTrackType.effect &&
        selectedClip.effectKind == TimelineEffectKind.filter;
    final isBlurEffect =
        canEdit &&
        selectedClip.type == TimelineTrackType.effect &&
        selectedClip.effectKind == TimelineEffectKind.blur;

    return _SelectionCapabilities(
      hasSelection: selectedClip != null,
      canEdit: canEdit,
      canAdjustAudio: canAdjustAudio,
      canVisualEffects: canVisualEffects,
      canTransform: canTransform,
      canAnimate: canAnimate,
      canTransition: canTransition,
      canArrange: canArrange,
      canChangeLayer: canChangeLayer,
      isFilterEffect: isFilterEffect,
      isBlurEffect: isBlurEffect,
    );
  }

  bool _isCategoryAvailable(
    _BottomActionCategory category,
    _SelectionCapabilities capabilities,
  ) {
    if (!capabilities.hasSelection) return true;
    return switch (category) {
      _BottomActionCategory.add || _BottomActionCategory.canvas => true,
      _BottomActionCategory.edit => capabilities.canEdit,
      _BottomActionCategory.effects => capabilities.canUseEffects,
      _BottomActionCategory.audio => capabilities.canAdjustAudio,
    };
  }

  bool _isSubgroupAvailable(
    _BottomActionSubgroup subgroup,
    _SelectionCapabilities capabilities,
  ) {
    if (!capabilities.hasSelection) return true;
    return switch (subgroup) {
      _BottomActionSubgroup.addMedia ||
      _BottomActionSubgroup.addText ||
      _BottomActionSubgroup.addTracks ||
      _BottomActionSubgroup.canvasFormat ||
      _BottomActionSubgroup.canvasGuides ||
      _BottomActionSubgroup.canvasStudio => true,
      _BottomActionSubgroup.editTiming => capabilities.canEdit,
      _BottomActionSubgroup.editTransform => capabilities.canVisualEffects,
      _BottomActionSubgroup.editArrange => capabilities.canArrange,
      _BottomActionSubgroup.effectsLooks => capabilities.canUseLooks,
      _BottomActionSubgroup.effectsBlur => capabilities.canUseBlur,
      _BottomActionSubgroup.effectsMotion => capabilities.canUseMotion,
      _BottomActionSubgroup.audioMix ||
      _BottomActionSubgroup.audioFades ||
      _BottomActionSubgroup.audioEnhance => capabilities.canAdjustAudio,
    };
  }

  Widget _buildBottomQuickActions(
    BuildContext context,
    TimelineClip? selectedClip,
  ) {
    final editorState = ref.read(editorProvider);
    final capabilities = _selectionCapabilitiesFor(editorState, selectedClip);
    final requestedCategory = _activeBottomCategory;
    final activeCategory =
        requestedCategory != null &&
            _isCategoryAvailable(requestedCategory, capabilities)
        ? requestedCategory
        : null;
    final requestedSubgroup = _activeBottomSubgroup;
    final activeSubgroup =
        activeCategory != null &&
            requestedSubgroup != null &&
            _isSubgroupAvailable(requestedSubgroup, capabilities)
        ? requestedSubgroup
        : null;

    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: const BoxDecoration(
        color: kSurface,
        border: Border(top: BorderSide(color: kBorder)),
      ),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) {
          final isCategoryRow = child.key == const ValueKey('categories');
          final offset = Tween<Offset>(
            begin: isCategoryRow
                ? const Offset(-0.18, 0)
                : const Offset(0.18, 0),
            end: Offset.zero,
          ).animate(animation);
          return FadeTransition(
            opacity: animation,
            child: SlideTransition(position: offset, child: child),
          );
        },
        child: activeCategory == null
            ? _buildCategoryRow(capabilities)
            : activeSubgroup == null
            ? _buildSubgroupRow(activeCategory, capabilities)
            : _buildToolRow(
                subgroup: activeSubgroup,
                selectedClip: selectedClip,
                capabilities: capabilities,
              ),
      ),
    );
  }

  Widget _buildCategoryRow(_SelectionCapabilities capabilities) {
    final categories = [
      _ActionSpec(
        label: 'Add',
        tooltip: 'Add media, text and tracks',
        icon: Icons.add_circle_outline_rounded,
        onTap: () => setState(() {
          _activeBottomCategory = _BottomActionCategory.add;
          _activeBottomSubgroup = null;
        }),
      ),
      _ActionSpec(
        label: 'Edit',
        tooltip: 'Timing, transform and arrange',
        icon: Icons.content_cut_rounded,
        onTap: _isCategoryAvailable(_BottomActionCategory.edit, capabilities)
            ? () => setState(() {
                _activeBottomCategory = _BottomActionCategory.edit;
                _activeBottomSubgroup = null;
              })
            : null,
      ),
      _ActionSpec(
        label: 'Effects',
        tooltip: 'Looks, blur and motion',
        icon: Icons.auto_fix_high_rounded,
        onTap: _isCategoryAvailable(_BottomActionCategory.effects, capabilities)
            ? () => setState(() {
                _activeBottomCategory = _BottomActionCategory.effects;
                _activeBottomSubgroup = null;
              })
            : null,
      ),
      _ActionSpec(
        label: 'Audio',
        tooltip: 'Mix, fades and enhancement',
        icon: Icons.graphic_eq_rounded,
        onTap: _isCategoryAvailable(_BottomActionCategory.audio, capabilities)
            ? () => setState(() {
                _activeBottomCategory = _BottomActionCategory.audio;
                _activeBottomSubgroup = null;
              })
            : null,
      ),
      _ActionSpec(
        label: 'Canvas',
        tooltip: 'Format, guides and studio tools',
        icon: Icons.aspect_ratio_rounded,
        onTap: () => setState(() {
          _activeBottomCategory = _BottomActionCategory.canvas;
          _activeBottomSubgroup = null;
        }),
      ),
    ];
    return _buildActionScroller(
      key: const ValueKey('categories'),
      actions: categories,
      spread: true,
    );
  }

  Widget _buildSubgroupRow(
    _BottomActionCategory category,
    _SelectionCapabilities capabilities,
  ) {
    final subgroups = switch (category) {
      _BottomActionCategory.add => [
        (
          _BottomActionSubgroup.addMedia,
          'Media',
          'Add visual and audio media',
          Icons.perm_media_rounded,
        ),
        (
          _BottomActionSubgroup.addText,
          'Text',
          'Text and captions',
          Icons.title_rounded,
        ),
        (
          _BottomActionSubgroup.addTracks,
          'Tracks',
          'Add timeline lanes',
          Icons.view_timeline_outlined,
        ),
      ],
      _BottomActionCategory.edit => [
        (
          _BottomActionSubgroup.editTiming,
          'Timing',
          'Trim, speed, split and reverse',
          Icons.av_timer_rounded,
        ),
        (
          _BottomActionSubgroup.editTransform,
          'Transform',
          'Crop, fit, rotate and flip',
          Icons.crop_rotate_rounded,
        ),
        (
          _BottomActionSubgroup.editArrange,
          'Arrange',
          'Layer, duplicate and visibility',
          Icons.layers_rounded,
        ),
      ],
      _BottomActionCategory.effects => [
        (
          _BottomActionSubgroup.effectsLooks,
          'Looks',
          'Filters and color correction',
          Icons.tonality_rounded,
        ),
        (
          _BottomActionSubgroup.effectsBlur,
          'Blur',
          'Whole and privacy-region blur',
          Icons.blur_on_rounded,
        ),
        (
          _BottomActionSubgroup.effectsMotion,
          'Motion',
          'Animations and transitions',
          Icons.auto_awesome_motion_rounded,
        ),
      ],
      _BottomActionCategory.audio => [
        (
          _BottomActionSubgroup.audioMix,
          'Mix',
          'Volume, mute and pan',
          Icons.tune_rounded,
        ),
        (
          _BottomActionSubgroup.audioFades,
          'Fades',
          'Audio fade controls',
          Icons.multiline_chart_rounded,
        ),
        (
          _BottomActionSubgroup.audioEnhance,
          'Enhance',
          'Normalize and reset',
          Icons.hearing_rounded,
        ),
      ],
      _BottomActionCategory.canvas => [
        (
          _BottomActionSubgroup.canvasFormat,
          'Format',
          'Aspect and background',
          Icons.aspect_ratio_rounded,
        ),
        (
          _BottomActionSubgroup.canvasGuides,
          'Guides',
          'Grid, safe areas and snapping',
          Icons.grid_4x4_rounded,
        ),
        (
          _BottomActionSubgroup.canvasStudio,
          'Studio',
          'Captions and creator tools',
          Icons.auto_awesome_rounded,
        ),
      ],
    };

    return _buildActionScroller(
      key: ValueKey('subgroups_${category.name}'),
      spread: true,
      actions: [
        for (final subgroup in subgroups)
          _ActionSpec(
            label: subgroup.$2,
            tooltip: subgroup.$3,
            icon: subgroup.$4,
            onTap: _isSubgroupAvailable(subgroup.$1, capabilities)
                ? () => setState(() => _activeBottomSubgroup = subgroup.$1)
                : null,
          ),
        _ActionSpec(
          label: 'Back',
          tooltip: 'Back to editor groups',
          icon: Icons.arrow_back_rounded,
          onTap: () => setState(() {
            _activeBottomCategory = null;
            _activeBottomSubgroup = null;
          }),
        ),
      ],
    );
  }

  Widget _buildToolRow({
    required _BottomActionSubgroup subgroup,
    required TimelineClip? selectedClip,
    required _SelectionCapabilities capabilities,
  }) {
    final isVisual = capabilities.canVisualEffects;
    final isFilterEffect = capabilities.isFilterEffect;
    final isBlurEffect = capabilities.isBlurEffect;
    final actions = switch (subgroup) {
      _BottomActionSubgroup.addMedia => [
        _ActionSpec(
          label: 'Overlay',
          tooltip: 'Add image or video overlay',
          icon: Icons.perm_media_rounded,
          onTap: _pickOverlayMedia,
        ),
        _ActionSpec(
          label: 'GIFs',
          tooltip: 'Add GIF or sticker',
          icon: Icons.emoji_emotions_outlined,
          onTap: _openGiphyPickerSheet,
        ),
        _ActionSpec(
          label: 'Audio',
          tooltip: 'Add music or voice audio',
          icon: Icons.music_note_rounded,
          onTap: _pickAudioMedia,
        ),
      ],
      _BottomActionSubgroup.addText => [
        _ActionSpec(
          label: 'Text',
          tooltip: 'Add text',
          icon: Icons.title_rounded,
          onTap: _addTextClipAtPlayhead,
        ),
        _ActionSpec(
          label: 'Edit',
          tooltip: 'Edit selected text',
          icon: Icons.edit_rounded,
          onTap:
              capabilities.canEdit &&
                  selectedClip?.type == TimelineTrackType.text
              ? () => _editTextClip(selectedClip!)
              : capabilities.canEdit &&
                    selectedClip?.type == TimelineTrackType.subtitle
              ? () {
                  final entry = selectedClip!.toSubtitleEntry();
                  if (entry != null) _openSubtitleTextEditor(entry);
                }
              : null,
        ),
        _ActionSpec(
          label: 'Captions',
          tooltip: 'Generate captions',
          icon: Icons.closed_caption_rounded,
          onTap:
              !_isGeneratingSubtitles &&
                  ref
                      .read(editorProvider)
                      .timeline
                      .tracks
                      .expand((track) => track.clips)
                      .any(ref.read(editorProvider).timeline.clipHasAudio)
              ? _handleGenerateSubtitles
              : null,
        ),
      ],
      _BottomActionSubgroup.addTracks => [
        _ActionSpec(
          label: 'Overlay',
          tooltip: 'Add overlay lane',
          icon: Icons.layers_rounded,
          onTap: () => _addTimelineTrack(
            TimelineTrackSection.overlay,
            TimelineTrackType.video,
          ),
        ),
        _ActionSpec(
          label: 'Text',
          tooltip: 'Add text lane',
          icon: Icons.title_rounded,
          onTap: () => _addTimelineTrack(
            TimelineTrackSection.textSubtitle,
            TimelineTrackType.text,
          ),
        ),
        _ActionSpec(
          label: 'Audio',
          tooltip: 'Add audio lane',
          icon: Icons.graphic_eq_rounded,
          onTap: () => _addTimelineTrack(
            TimelineTrackSection.audio,
            TimelineTrackType.audio,
          ),
        ),
        _ActionSpec(
          label: 'Effects',
          tooltip: 'Add effects lane',
          icon: Icons.auto_fix_high_rounded,
          onTap: () => _addTimelineTrack(
            TimelineTrackSection.overlay,
            TimelineTrackType.effect,
          ),
        ),
      ],
      _BottomActionSubgroup.editTiming => [
        _ActionSpec(
          label: 'Trim/Speed',
          tooltip: selectedClip?.supportsReversePlayback == true
              ? 'Trim source, change speed and reverse'
              : 'Trim source and change speed',
          icon: Icons.av_timer_rounded,
          onTap:
              selectedClip != null &&
                  capabilities.canEdit &&
                  selectedClip.supportsSourceTiming
              ? () => _openTimingSheet(selectedClip)
              : null,
        ),
        _ActionSpec(
          label: 'Split',
          tooltip: 'Split selected clip at playhead',
          icon: Icons.content_cut_rounded,
          onTap: selectedClip == null || !capabilities.canEdit
              ? null
              : () => _splitClipAtPlayhead(selectedClip),
        ),
      ],
      _BottomActionSubgroup.editTransform => [
        _ActionSpec(
          label: 'Crop',
          tooltip: 'Crop with presets or free insets',
          icon: Icons.crop_rounded,
          onTap: isVisual ? () => _openCropSheet(selectedClip!) : null,
        ),
        _ActionSpec(
          label: 'Fill',
          tooltip: 'Fill the frame',
          icon: Icons.fullscreen_rounded,
          onTap: isVisual
              ? () => _setClipFit(selectedClip!, ClipFitMode.cover)
              : null,
        ),
        _ActionSpec(
          label: 'Fit',
          tooltip: 'Fit inside the frame',
          icon: Icons.fit_screen_rounded,
          onTap: isVisual
              ? () => _setClipFit(selectedClip!, ClipFitMode.contain)
              : null,
        ),
        _ActionSpec(
          label: 'Stretch',
          tooltip: 'Stretch to the frame',
          icon: Icons.open_in_full_rounded,
          onTap: isVisual
              ? () => _setClipFit(selectedClip!, ClipFitMode.stretch)
              : null,
        ),
        _ActionSpec(
          label: 'Rotate L',
          tooltip: 'Rotate left 90 degrees',
          icon: Icons.rotate_left_rounded,
          onTap: isVisual
              ? () => _rotateClip(selectedClip!, -math.pi / 2)
              : null,
        ),
        _ActionSpec(
          label: 'Rotate R',
          tooltip: 'Rotate right 90 degrees',
          icon: Icons.rotate_right_rounded,
          onTap: isVisual
              ? () => _rotateClip(selectedClip!, math.pi / 2)
              : null,
        ),
        _ActionSpec(
          label: 'Mirror',
          tooltip: 'Mirror horizontally',
          icon: Icons.flip_rounded,
          onTap: isVisual
              ? () => _toggleClipFlip(selectedClip!, horizontal: true)
              : null,
        ),
        _ActionSpec(
          label: 'Flip V',
          tooltip: 'Flip vertically',
          icon: Icons.flip_camera_android_rounded,
          onTap: isVisual
              ? () => _toggleClipFlip(selectedClip!, horizontal: false)
              : null,
        ),
        _ActionSpec(
          label: 'Reset',
          tooltip: 'Reset transform and crop',
          icon: Icons.restart_alt_rounded,
          onTap: isVisual ? () => _resetClipTransform(selectedClip!) : null,
        ),
      ],
      _BottomActionSubgroup.editArrange => [
        _ActionSpec(
          label: 'Inspector',
          tooltip: 'Opacity, layer and transform controls',
          icon: Icons.tune_rounded,
          onTap: selectedClip == null || !capabilities.canTransform
              ? null
              : () => _openClipInspectorSheet(selectedClip),
        ),
        _ActionSpec(
          label: 'Forward',
          tooltip: 'Bring clip forward one layer',
          icon: Icons.move_up_rounded,
          onTap: selectedClip == null || !capabilities.canChangeLayer
              ? null
              : () => _changeClipLayer(selectedClip, 1),
        ),
        _ActionSpec(
          label: 'Backward',
          tooltip: 'Send clip backward one layer',
          icon: Icons.move_down_rounded,
          onTap: selectedClip == null || !capabilities.canChangeLayer
              ? null
              : () => _changeClipLayer(selectedClip, -1),
        ),
        _ActionSpec(
          label: 'Duplicate',
          tooltip: 'Duplicate selected clip',
          icon: Icons.content_copy_rounded,
          onTap: selectedClip == null || !capabilities.canArrange
              ? null
              : () => _duplicateClip(selectedClip),
        ),
        _ActionSpec(
          label: selectedClip?.enabled == false ? 'Enable' : 'Disable',
          tooltip: 'Toggle clip visibility in preview and export',
          icon: selectedClip?.enabled == false
              ? Icons.visibility_rounded
              : Icons.visibility_off_rounded,
          onTap: selectedClip == null || !capabilities.canArrange
              ? null
              : () => _toggleClipEnabled(selectedClip),
        ),
        _ActionSpec(
          label: 'Delete',
          tooltip: 'Delete selected clip',
          icon: Icons.delete_outline_rounded,
          onTap: selectedClip == null || !capabilities.canEdit
              ? null
              : () => _deleteClip(selectedClip),
        ),
      ],
      _BottomActionSubgroup.effectsLooks => [
        _ActionSpec(
          label: 'Filters',
          tooltip: 'Add a prebuilt filter as a timeline overlay',
          icon: Icons.tonality_rounded,
          onTap: isVisual || isFilterEffect
              ? () => _openFilterSheet(selectedClip!)
              : null,
        ),
        _ActionSpec(
          label: 'Adjust',
          tooltip: 'Brightness, contrast, saturation, temperature and finish',
          icon: Icons.tune_rounded,
          onTap: isVisual || isFilterEffect
              ? () => _openColorAdjustmentsSheet(selectedClip!)
              : null,
        ),
        _ActionSpec(
          label: 'Remove',
          tooltip: 'Remove the selected filter overlay',
          icon: Icons.layers_clear_rounded,
          onTap: isFilterEffect ? () => _deleteClip(selectedClip!) : null,
        ),
      ],
      _BottomActionSubgroup.effectsBlur => [
        _ActionSpec(
          label: 'Whole',
          tooltip: isBlurEffect
              ? 'Change the selected blur to whole-frame'
              : 'Add whole-frame blur as a timeline overlay',
          icon: Icons.blur_circular_rounded,
          onTap: isBlurEffect
              ? () {
                  _setBlurMode(selectedClip!, ClipBlurMode.full);
                  unawaited(_openBlurSheet(selectedClip));
                }
              : isVisual
              ? () => _addEffectOverlay(
                  anchor: selectedClip!,
                  kind: TimelineEffectKind.blur,
                  label: 'Whole blur',
                  blur: const ClipBlurSettings(
                    mode: ClipBlurMode.full,
                    strength: 12,
                  ),
                )
              : null,
        ),
        _ActionSpec(
          label: 'Region',
          tooltip: isBlurEffect
              ? 'Change the selected blur to a movable privacy region'
              : 'Add a blur region you can move on the preview',
          icon: Icons.center_focus_strong_rounded,
          onTap: isBlurEffect
              ? () {
                  _setBlurMode(selectedClip!, ClipBlurMode.region);
                  unawaited(_openBlurSheet(selectedClip));
                }
              : isVisual
              ? () => _addEffectOverlay(
                  anchor: selectedClip!,
                  kind: TimelineEffectKind.blur,
                  label: 'Region blur',
                  blur: const ClipBlurSettings(
                    mode: ClipBlurMode.region,
                    strength: 12,
                  ),
                )
              : null,
        ),
        _ActionSpec(
          label: 'Adjust',
          tooltip: 'Adjust blur mode, strength, and privacy region',
          icon: Icons.tune_rounded,
          onTap: isBlurEffect ? () => _openBlurSheet(selectedClip!) : null,
        ),
        _ActionSpec(
          label: 'Remove',
          tooltip: 'Remove the selected blur overlay',
          icon: Icons.layers_clear_rounded,
          onTap: isBlurEffect ? () => _deleteClip(selectedClip!) : null,
        ),
      ],
      _BottomActionSubgroup.effectsMotion => [
        _ActionSpec(
          label: 'Animate',
          tooltip: 'Clip animation',
          icon: Icons.auto_awesome_motion_rounded,
          onTap: capabilities.canAnimate
              ? () => _openClipAnimationSheetForSelection(selectedClip!)
              : null,
        ),
        _ActionSpec(
          label: 'Transition',
          tooltip: 'Base clip transition',
          icon: Icons.join_inner_rounded,
          onTap: capabilities.canTransition
              ? () => _openTransitionSheet(selectedClip!)
              : null,
        ),
      ],
      _BottomActionSubgroup.audioMix => [
        _ActionSpec(
          label: 'Mixer',
          tooltip: 'Volume, pan, fades and normalize',
          icon: Icons.tune_rounded,
          onTap: capabilities.canAdjustAudio
              ? () => _openAudioControlsSheet(selectedClip!)
              : null,
        ),
        _ActionSpec(
          label: selectedClip?.audioMix.muted == true ? 'Unmute' : 'Mute',
          tooltip: 'Toggle selected clip audio',
          icon: selectedClip?.audioMix.muted == true
              ? Icons.volume_up_rounded
              : Icons.volume_off_rounded,
          onTap: capabilities.canAdjustAudio
              ? () => _toggleClipMute(selectedClip!)
              : null,
        ),
      ],
      _BottomActionSubgroup.audioFades => [
        _ActionSpec(
          label: 'Fade In',
          tooltip: 'Toggle a 500ms audio fade in',
          icon: Icons.trending_up_rounded,
          onTap: capabilities.canAdjustAudio
              ? () => _toggleQuickFade(selectedClip!, fadeIn: true)
              : null,
        ),
        _ActionSpec(
          label: 'Fade Out',
          tooltip: 'Toggle a 500ms audio fade out',
          icon: Icons.trending_down_rounded,
          onTap: capabilities.canAdjustAudio
              ? () => _toggleQuickFade(selectedClip!, fadeIn: false)
              : null,
        ),
        _ActionSpec(
          label: 'Clear',
          tooltip: 'Clear both audio fades',
          icon: Icons.restart_alt_rounded,
          onTap: capabilities.canAdjustAudio
              ? () => _updateTimelineClip(
                  selectedClip!,
                  (current) => current.copyWith(
                    audioMix: current.audioMix.copyWith(
                      fadeInMs: 0,
                      fadeOutMs: 0,
                    ),
                  ),
                )
              : null,
        ),
      ],
      _BottomActionSubgroup.audioEnhance => [
        _ActionSpec(
          label: selectedClip?.audioMix.normalize == true
              ? 'Raw level'
              : 'Normalize',
          tooltip: 'Toggle loudness normalization',
          icon: Icons.hearing_rounded,
          onTap: capabilities.canAdjustAudio
              ? () => _toggleClipNormalize(selectedClip!)
              : null,
        ),
        _ActionSpec(
          label: 'Center Pan',
          tooltip: 'Center the stereo pan',
          icon: Icons.swap_horiz_rounded,
          onTap: capabilities.canAdjustAudio
              ? () => _updateTimelineClip(
                  selectedClip!,
                  (current) => current.copyWith(
                    audioMix: current.audioMix.copyWith(pan: 0),
                  ),
                )
              : null,
        ),
        _ActionSpec(
          label: 'Reset Mix',
          tooltip: 'Reset volume, pan, fades and normalize',
          icon: Icons.restart_alt_rounded,
          onTap: capabilities.canAdjustAudio
              ? () => _updateTimelineClip(
                  selectedClip!,
                  (current) =>
                      current.copyWith(audioMix: const AudioMixSettings()),
                )
              : null,
        ),
      ],
      _BottomActionSubgroup.canvasFormat => [
        _ActionSpec(
          label: 'Canvas',
          tooltip: 'Format and background settings',
          icon: Icons.aspect_ratio_rounded,
          onTap: _openCanvasSettingsSheet,
        ),
        _ActionSpec(
          label: '16:9',
          tooltip: 'Set landscape canvas',
          icon: Icons.crop_16_9_rounded,
          onTap: () {
            _updateCanvasSettings(
              (canvas) => canvas.copyWith(
                aspectRatioPreset: CanvasAspectRatioPreset.ratio16x9,
              ),
            );
            setState(() => _canvasAspectRatio = _CanvasAspectRatio.ratio16x9);
          },
        ),
        _ActionSpec(
          label: '9:16',
          tooltip: 'Set portrait canvas',
          icon: Icons.stay_current_portrait_rounded,
          onTap: () {
            _updateCanvasSettings(
              (canvas) => canvas.copyWith(
                aspectRatioPreset: CanvasAspectRatioPreset.ratio9x16,
              ),
            );
            setState(() => _canvasAspectRatio = _CanvasAspectRatio.ratio9x16);
          },
        ),
        _ActionSpec(
          label: '1:1',
          tooltip: 'Set square canvas',
          icon: Icons.crop_square_rounded,
          onTap: () {
            _updateCanvasSettings(
              (canvas) => canvas.copyWith(
                aspectRatioPreset: CanvasAspectRatioPreset.ratio1x1,
              ),
            );
            setState(() => _canvasAspectRatio = _CanvasAspectRatio.ratio1x1);
          },
        ),
      ],
      _BottomActionSubgroup.canvasGuides => [
        _ActionSpec(
          label: 'Grid',
          tooltip: 'Toggle composition grid',
          icon: Icons.grid_4x4_rounded,
          onTap: () => _updateCanvasSettings(
            (canvas) => canvas.copyWith(showGrid: !canvas.showGrid),
          ),
        ),
        _ActionSpec(
          label: 'Safe Area',
          tooltip: 'Toggle title and action safe areas',
          icon: Icons.border_style_rounded,
          onTap: () => _updateCanvasSettings(
            (canvas) => canvas.copyWith(showSafeAreas: !canvas.showSafeAreas),
          ),
        ),
        _ActionSpec(
          label: 'Snap',
          tooltip: 'Toggle snapping to guides',
          icon: Icons.grid_goldenratio_rounded,
          onTap: () => _updateCanvasSettings(
            (canvas) => canvas.copyWith(snapToGuides: !canvas.snapToGuides),
          ),
        ),
        _ActionSpec(
          label: 'Grid Size',
          tooltip: 'Cycle composition grid divisions',
          icon: Icons.grid_on_rounded,
          onTap: () => _updateCanvasSettings(
            (canvas) => canvas.copyWith(
              showGrid: true,
              gridDivisions: canvas.gridDivisions >= 6
                  ? 2
                  : canvas.gridDivisions + 1,
            ),
          ),
        ),
        _ActionSpec(
          label: 'Clear',
          tooltip: 'Hide guides and turn guide snapping off',
          icon: Icons.layers_clear_rounded,
          onTap: () => _updateCanvasSettings(
            (canvas) => canvas.copyWith(
              showGrid: false,
              showSafeAreas: false,
              snapToGuides: false,
            ),
          ),
        ),
      ],
      _BottomActionSubgroup.canvasStudio => [
        _ActionSpec(
          label: 'Style',
          tooltip: 'Subtitle style',
          icon: Icons.palette_outlined,
          onTap: () => _openStylePanelSheet(context),
        ),
        _ActionSpec(
          label: 'Captions',
          tooltip: 'Find, shift and quality-check captions',
          icon: Icons.fact_check_outlined,
          onTap: _openSubtitleToolsSheet,
        ),
        _ActionSpec(
          label: 'Creator Lab',
          tooltip: 'Open grouped caption and publishing workflows',
          icon: Icons.auto_awesome_rounded,
          onTap: _openCreatorLab,
        ),
      ],
    };

    return _buildActionScroller(
      key: ValueKey('tools_${subgroup.name}'),
      actions: [
        ...actions,
        _ActionSpec(
          label: 'Back',
          tooltip: 'Back to subgroups',
          icon: Icons.arrow_back_rounded,
          onTap: () => setState(() => _activeBottomSubgroup = null),
        ),
      ],
    );
  }

  Widget _buildActionScroller({
    required Key key,
    required List<_ActionSpec> actions,
    bool spread = false,
  }) {
    return LayoutBuilder(
      key: key,
      builder: (context, constraints) {
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: constraints.maxWidth),
            child: Row(
              mainAxisAlignment: spread
                  ? MainAxisAlignment.spaceAround
                  : MainAxisAlignment.start,
              children: [
                for (final action in actions) ...[
                  _buildQuickActionButton(
                    tooltip: action.tooltip,
                    icon: action.icon,
                    label: action.label,
                    onTap: action.onTap,
                  ),
                  if (!spread) const SizedBox(width: 8),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  void _addTimelineTrack(
    TimelineTrackSection section,
    TimelineTrackType trackType,
  ) {
    final timeline = ref.read(editorProvider).timeline;
    final nextTrack = _createOptionalTrack(timeline, section, trackType);
    if (nextTrack == null) return;
    ref
        .read(editorProvider.notifier)
        .setTimeline(
          timeline.copyWith(tracks: [...timeline.tracks, nextTrack]),
        );
    ref.read(editorProvider.notifier).selectTrack(nextTrack.id);
  }

  Future<void> _openAudioControlsSheet(TimelineClip clip) async {
    final editorState = ref.read(editorProvider);
    final liveClip = _clipById(clip.id, editorState) ?? clip;
    final track = _trackForClip(liveClip, editorState);
    if (track == null ||
        track.isLocked ||
        !editorState.timeline.clipHasAudio(liveClip)) {
      return;
    }
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.40,
      ),
      backgroundColor: Colors.transparent,
      builder: (_) => Consumer(
        builder: (context, ref, _) {
          final editorState = ref.watch(editorProvider);
          final liveClip = _clipById(clip.id, editorState) ?? clip;
          return SingleChildScrollView(child: _buildAudioControls(liveClip));
        },
      ),
    );
  }

  Widget _buildQuickActionButton({
    required String tooltip,
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
  }) {
    final isEnabled = onTap != null;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Ink(
          width: 70,
          height: 44,
          decoration: BoxDecoration(
            color: kSurfaceElevated,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isEnabled ? kBorder : kBorder.withValues(alpha: 0.45),
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                color: isEnabled
                    ? kTextPrimary
                    : kTextPrimary.withValues(alpha: 0.32),
                size: 18,
              ),
              const SizedBox(height: 2),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: isEnabled
                      ? kTextPrimary
                      : kTextPrimary.withValues(alpha: 0.32),
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAudioControls(TimelineClip clip) {
    final isVideoClip = clip.type == TimelineTrackType.video;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
      decoration: const BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 44,
              height: 4,
              decoration: BoxDecoration(
                color: kBorder,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            isVideoClip ? 'Video Clip Audio' : 'Audio Clip Controls',
            style: TextStyle(
              color: kTextPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              TextButton.icon(
                onPressed: () => _updateSelectedClipAudioMix(
                  clip,
                  muted: !clip.audioMix.muted,
                ),
                icon: Icon(
                  clip.audioMix.muted
                      ? Icons.volume_off_rounded
                      : Icons.volume_up_rounded,
                  size: 16,
                ),
                label: Text(clip.audioMix.muted ? 'Unmute' : 'Mute'),
              ),
              const SizedBox(width: 8),
              Text(
                clip.audioMix.muted
                    ? 'Muted'
                    : '${(clip.audioMix.volume * 100).round()}%',
                style: TextStyle(color: kTextSecondary, fontSize: 12),
              ),
            ],
          ),
          SliderTheme(
            data: SliderThemeData(
              activeTrackColor: kAccent,
              inactiveTrackColor: kBorder,
              thumbColor: kAccent,
              overlayColor: kAccent.withValues(alpha: 0.14),
            ),
            child: Slider(
              value: clip.audioMix.volume.clamp(0.0, 1.0),
              min: 0,
              max: 1,
              divisions: 20,
              onChangeStart: (_) =>
                  ref.read(editorProvider.notifier).beginTimelineGestureEdit(),
              onChanged: (value) => _updateSelectedClipAudioMix(
                clip,
                volume: value,
                muted: value == 0 ? true : false,
              ),
              onChangeEnd: (_) =>
                  ref.read(editorProvider.notifier).endTimelineGestureEdit(),
            ),
          ),
          Text(
            'Stereo Pan',
            style: TextStyle(color: kTextSecondary, fontSize: 12),
          ),
          Slider(
            value: clip.audioMix.pan.clamp(-1.0, 1.0),
            min: -1,
            max: 1,
            divisions: 20,
            label: clip.audioMix.pan.abs() < 0.05
                ? 'Center'
                : clip.audioMix.pan < 0
                ? 'L ${(clip.audioMix.pan.abs() * 100).round()}'
                : 'R ${(clip.audioMix.pan * 100).round()}',
            onChangeStart: (_) =>
                ref.read(editorProvider.notifier).beginTimelineGestureEdit(),
            onChanged: (value) => _updateSelectedClipAudioMix(clip, pan: value),
            onChangeEnd: (_) =>
                ref.read(editorProvider.notifier).endTimelineGestureEdit(),
          ),
          const Text(
            'Left/right routing is rendered in the export; device preview monitors centered audio.',
            style: TextStyle(color: kTextSecondary, fontSize: 10),
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Normalize loudness'),
            subtitle: const Text('Target a consistent −16 LUFS on export'),
            value: clip.audioMix.normalize,
            onChanged: (value) =>
                _updateSelectedClipAudioMix(clip, normalize: value),
          ),
          const SizedBox(height: 6),
          Text(
            'Fade In',
            style: TextStyle(color: kTextSecondary, fontSize: 12),
          ),
          SliderTheme(
            data: SliderThemeData(
              activeTrackColor: kAccent,
              inactiveTrackColor: kBorder,
              thumbColor: kAccent,
              overlayColor: kAccent.withValues(alpha: 0.14),
            ),
            child: Slider(
              value: clip.audioMix.fadeInMs.toDouble().clamp(0, 1500),
              min: 0,
              max: 1500,
              divisions: 15,
              label: '${clip.audioMix.fadeInMs}ms',
              onChangeStart: (_) =>
                  ref.read(editorProvider.notifier).beginTimelineGestureEdit(),
              onChanged: (value) =>
                  _updateSelectedClipAudioMix(clip, fadeInMs: value.round()),
              onChangeEnd: (_) =>
                  ref.read(editorProvider.notifier).endTimelineGestureEdit(),
            ),
          ),
          Text(
            'Fade Out',
            style: TextStyle(color: kTextSecondary, fontSize: 12),
          ),
          SliderTheme(
            data: SliderThemeData(
              activeTrackColor: kAccent,
              inactiveTrackColor: kBorder,
              thumbColor: kAccent,
              overlayColor: kAccent.withValues(alpha: 0.14),
            ),
            child: Slider(
              value: clip.audioMix.fadeOutMs.toDouble().clamp(0, 1500),
              min: 0,
              max: 1500,
              divisions: 15,
              label: '${clip.audioMix.fadeOutMs}ms',
              onChangeStart: (_) =>
                  ref.read(editorProvider.notifier).beginTimelineGestureEdit(),
              onChanged: (value) =>
                  _updateSelectedClipAudioMix(clip, fadeOutMs: value.round()),
              onChangeEnd: (_) =>
                  ref.read(editorProvider.notifier).endTimelineGestureEdit(),
            ),
          ),
          Text(
            isVideoClip
                ? 'Overlay video audio can be faded in and out here.'
                : 'Audio clips now support volume plus simple fade in and fade out.',
            style: TextStyle(color: kTextSecondary, fontSize: 12, height: 1.35),
          ),
        ],
      ),
    );
  }

  Future<void> _openTransitionSheet(TimelineClip clip) async {
    final editorState = ref.read(editorProvider);
    final track = _trackForClip(clip, editorState);
    if (track == null ||
        track.isLocked ||
        track.section != TimelineTrackSection.baseVideo ||
        clip.type != TimelineTrackType.video) {
      return;
    }
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.40,
      ),
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      builder: (_) => Consumer(
        builder: (context, ref, _) {
          final editorState = ref.watch(editorProvider);
          final liveClip = _clipById(clip.id, editorState) ?? clip;
          return SingleChildScrollView(child: _buildTransitionEditor(liveClip));
        },
      ),
    );
  }

  Future<void> _openClipAnimationSheet(
    TimelineClip clip,
    TimelineTrack track,
  ) async {
    if (track.isLocked || !clip.supportsClipAnimation) return;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.40,
      ),
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      builder: (_) => Consumer(
        builder: (context, ref, _) {
          final editorState = ref.watch(editorProvider);
          final liveClip = _clipById(clip.id, editorState) ?? clip;
          final liveTrack = _trackForClip(liveClip, editorState) ?? track;
          return SingleChildScrollView(
            child: _buildClipAnimationSheet(liveClip, liveTrack),
          );
        },
      ),
    );
  }

  Widget _buildTransitionEditor(TimelineClip clip) {
    const transitionOptions = [
      (TransitionType.cut, 'Cut'),
      (TransitionType.fade, 'Fade'),
      (TransitionType.dissolve, 'Soft fade'),
      (TransitionType.slideLeft, 'Left'),
      (TransitionType.slideRight, 'Right'),
      (TransitionType.slideUp, 'Up'),
      (TransitionType.slideDown, 'Down'),
      (TransitionType.zoom, 'Zoom'),
    ];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
      decoration: const BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 44,
              height: 4,
              decoration: BoxDecoration(
                color: kBorder,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'Transition from ${clip.label}',
            style: TextStyle(
              color: kTextPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: transitionOptions.map((option) {
              final isSelected =
                  clip.outroTransition.type == option.$1 ||
                  (clip.outroTransition.type == TransitionType.none &&
                      option.$1 == TransitionType.cut);
              return ChoiceChip(
                label: Text(option.$2),
                selected: isSelected,
                selectedColor: kAccent.withValues(alpha: 0.18),
                backgroundColor: kSurfaceElevated,
                side: BorderSide(color: isSelected ? kAccent : kBorder),
                labelStyle: TextStyle(
                  color: isSelected ? kAccent : kTextSecondary,
                  fontSize: 12,
                ),
                onSelected: (_) => _updateSelectedClipTransition(
                  clip: clip,
                  type: option.$1,
                  durationMs: option.$1 == TransitionType.cut
                      ? 0
                      : (clip.outroTransition.durationMs == 0
                            ? 400
                            : clip.outroTransition.durationMs),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 10),
          Text(
            'Duration',
            style: TextStyle(color: kTextSecondary, fontSize: 12),
          ),
          SliderTheme(
            data: SliderThemeData(
              activeTrackColor: kAccent,
              inactiveTrackColor: kBorder,
              thumbColor: kAccent,
              overlayColor: kAccent.withValues(alpha: 0.14),
            ),
            child: Slider(
              value: clip.outroTransition.type == TransitionType.cut
                  ? 0
                  : clip.outroTransition.durationMs.toDouble().clamp(100, 1200),
              min: 0,
              max: 1200,
              divisions: 12,
              label:
                  '${clip.outroTransition.type == TransitionType.cut ? 0 : clip.outroTransition.durationMs}ms',
              onChangeStart: (_) =>
                  ref.read(editorProvider.notifier).beginTimelineGestureEdit(),
              onChanged: (value) => _updateSelectedClipTransition(
                clip: clip,
                durationMs: clip.outroTransition.type == TransitionType.cut
                    ? 0
                    : value.round(),
              ),
              onChangeEnd: (_) =>
                  ref.read(editorProvider.notifier).endTimelineGestureEdit(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildClipAnimationSheet(TimelineClip clip, TimelineTrack track) {
    const animationOptions = [
      (TransitionType.none, 'None'),
      (TransitionType.fade, 'Fade'),
      (TransitionType.slideLeft, 'Slide Left'),
      (TransitionType.slideRight, 'Slide Right'),
      (TransitionType.slideUp, 'Slide Up'),
      (TransitionType.slideDown, 'Slide Down'),
      (TransitionType.zoom, 'Zoom'),
    ];
    final isAudioTrack = track.section == TimelineTrackSection.audio;
    final sheetTitle = isAudioTrack
        ? 'Audio Animation'
        : track.section == TimelineTrackSection.baseVideo
        ? 'Clip Animation'
        : 'Overlay Animation';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
      decoration: const BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 44,
              height: 4,
              decoration: BoxDecoration(
                color: kBorder,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            sheetTitle,
            style: TextStyle(
              color: kTextPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          if (!isAudioTrack) ...[
            Text(
              'Animate In',
              style: TextStyle(color: kTextSecondary, fontSize: 12),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: animationOptions.map((option) {
                final isSelected = clip.introTransition.type == option.$1;
                return ChoiceChip(
                  label: Text(option.$2),
                  selected: isSelected,
                  selectedColor: kAccent.withValues(alpha: 0.18),
                  backgroundColor: kSurfaceElevated,
                  side: BorderSide(color: isSelected ? kAccent : kBorder),
                  labelStyle: TextStyle(
                    color: isSelected ? kAccent : kTextSecondary,
                    fontSize: 12,
                  ),
                  onSelected: (_) => _updateSelectedClipTransition(
                    clip: clip,
                    updateIntro: true,
                    updateOutro: false,
                    type: option.$1,
                    durationMs: option.$1 == TransitionType.none ? 0 : 350,
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 12),
            Text(
              'Animate Out',
              style: TextStyle(color: kTextSecondary, fontSize: 12),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: animationOptions.map((option) {
                final isSelected = clip.outroTransition.type == option.$1;
                return ChoiceChip(
                  label: Text(option.$2),
                  selected: isSelected,
                  selectedColor: kAccent.withValues(alpha: 0.18),
                  backgroundColor: kSurfaceElevated,
                  side: BorderSide(color: isSelected ? kAccent : kBorder),
                  labelStyle: TextStyle(
                    color: isSelected ? kAccent : kTextSecondary,
                    fontSize: 12,
                  ),
                  onSelected: (_) => _updateSelectedClipTransition(
                    clip: clip,
                    updateIntro: false,
                    updateOutro: true,
                    type: option.$1,
                    durationMs: option.$1 == TransitionType.none ? 0 : 350,
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 12),
            Text(
              'Animation Length',
              style: TextStyle(color: kTextSecondary, fontSize: 12),
            ),
            SliderTheme(
              data: SliderThemeData(
                activeTrackColor: kAccent,
                inactiveTrackColor: kBorder,
                thumbColor: kAccent,
                overlayColor: kAccent.withValues(alpha: 0.14),
              ),
              child: Slider(
                value:
                    (clip.introTransition.durationMs == 0
                            ? clip.outroTransition.durationMs
                            : clip.introTransition.durationMs)
                        .toDouble()
                        .clamp(150, 1200),
                min: 150,
                max: 1200,
                divisions: 7,
                label:
                    '${(clip.introTransition.durationMs == 0 ? clip.outroTransition.durationMs : clip.introTransition.durationMs)}ms',
                onChangeStart: (_) => ref
                    .read(editorProvider.notifier)
                    .beginTimelineGestureEdit(),
                onChanged: (value) {
                  final rounded = value.round();
                  _updateSelectedClipTransition(
                    clip: clip,
                    updateIntro:
                        clip.introTransition.type != TransitionType.none,
                    updateOutro: false,
                    durationMs: rounded,
                  );
                  _updateSelectedClipTransition(
                    clip: clip,
                    updateIntro: false,
                    updateOutro:
                        clip.outroTransition.type != TransitionType.none,
                    durationMs: rounded,
                  );
                },
                onChangeEnd: (_) =>
                    ref.read(editorProvider.notifier).endTimelineGestureEdit(),
              ),
            ),
          ] else ...[
            Text(
              'Fade In',
              style: TextStyle(color: kTextSecondary, fontSize: 12),
            ),
            SliderTheme(
              data: SliderThemeData(
                activeTrackColor: kAccent,
                inactiveTrackColor: kBorder,
                thumbColor: kAccent,
                overlayColor: kAccent.withValues(alpha: 0.14),
              ),
              child: Slider(
                value: clip.audioMix.fadeInMs.toDouble().clamp(0, 1500),
                min: 0,
                max: 1500,
                divisions: 15,
                label: '${clip.audioMix.fadeInMs}ms',
                onChangeStart: (_) => ref
                    .read(editorProvider.notifier)
                    .beginTimelineGestureEdit(),
                onChanged: (value) =>
                    _updateSelectedClipAudioMix(clip, fadeInMs: value.round()),
                onChangeEnd: (_) =>
                    ref.read(editorProvider.notifier).endTimelineGestureEdit(),
              ),
            ),
            Text(
              'Fade Out',
              style: TextStyle(color: kTextSecondary, fontSize: 12),
            ),
            SliderTheme(
              data: SliderThemeData(
                activeTrackColor: kAccent,
                inactiveTrackColor: kBorder,
                thumbColor: kAccent,
                overlayColor: kAccent.withValues(alpha: 0.14),
              ),
              child: Slider(
                value: clip.audioMix.fadeOutMs.toDouble().clamp(0, 1500),
                min: 0,
                max: 1500,
                divisions: 15,
                label: '${clip.audioMix.fadeOutMs}ms',
                onChangeStart: (_) => ref
                    .read(editorProvider.notifier)
                    .beginTimelineGestureEdit(),
                onChanged: (value) =>
                    _updateSelectedClipAudioMix(clip, fadeOutMs: value.round()),
                onChangeEnd: (_) =>
                    ref.read(editorProvider.notifier).endTimelineGestureEdit(),
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _openStylePanelSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      barrierColor: Colors.black.withValues(alpha: 0.2),
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.38,
        maxChildSize: 0.40,
        minChildSize: 0.22,
        expand: false,
        builder: (_, controller) {
          return Container(
            decoration: const BoxDecoration(
              color: kSurface,
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            ),
            child: Column(
              children: [
                const SizedBox(height: 12),
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: kBorder,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Subtitle Style',
                  style: TextStyle(
                    color: kTextPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  'Keep sheet lower to preview changes on video',
                  style: TextStyle(color: kTextSecondary, fontSize: 11),
                ),
                const SizedBox(height: 8),
                const Expanded(child: SubtitleStylePanel()),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _SelectionCapabilities {
  final bool hasSelection;
  final bool canEdit;
  final bool canAdjustAudio;
  final bool canVisualEffects;
  final bool canTransform;
  final bool canAnimate;
  final bool canTransition;
  final bool canArrange;
  final bool canChangeLayer;
  final bool isFilterEffect;
  final bool isBlurEffect;

  const _SelectionCapabilities({
    required this.hasSelection,
    required this.canEdit,
    required this.canAdjustAudio,
    required this.canVisualEffects,
    required this.canTransform,
    required this.canAnimate,
    required this.canTransition,
    required this.canArrange,
    required this.canChangeLayer,
    required this.isFilterEffect,
    required this.isBlurEffect,
  });

  bool get canUseLooks => canVisualEffects || isFilterEffect;
  bool get canUseBlur => canVisualEffects || isBlurEffect;
  bool get canUseMotion => canAnimate || canTransition;
  bool get canUseEffects => canUseLooks || canUseBlur || canUseMotion;
}

class _ActionSpec {
  final String label;
  final String tooltip;
  final IconData icon;
  final VoidCallback? onTap;

  const _ActionSpec({
    required this.label,
    required this.tooltip,
    required this.icon,
    required this.onTap,
  });
}

class _GiphyPickerSheet extends StatefulWidget {
  final Future<void> Function(GiphyAssetResult result) onSelected;

  const _GiphyPickerSheet({required this.onSelected});

  @override
  State<_GiphyPickerSheet> createState() => _GiphyPickerSheetState();
}

class _GiphyPickerSheetState extends State<_GiphyPickerSheet> {
  final TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounce;
  List<GiphyAssetResult> _results = const [];
  bool _isLoading = false;
  bool _selectionInProgress = false;
  String? _error;
  GiphySearchKind _searchKind = GiphySearchKind.both;
  int _requestGeneration = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_refreshResults());
    });
  }

  @override
  void dispose() {
    _requestGeneration++;
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onQueryChanged(String _) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      unawaited(_refreshResults());
    });
  }

  Future<void> _refreshResults() async {
    final requestGeneration = ++_requestGeneration;
    final query = _searchController.text;
    final searchKind = _searchKind;
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final results = await GiphyService.search(query: query, kind: searchKind);
      if (!mounted || requestGeneration != _requestGeneration) return;
      setState(() {
        _results = results;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted || requestGeneration != _requestGeneration) return;
      setState(() {
        _results = const [];
        _error = e.toString().replaceFirst('Exception: ', '');
        _isLoading = false;
      });
    }
  }

  Future<void> _selectResult(GiphyAssetResult result) async {
    if (_selectionInProgress) return;
    setState(() => _selectionInProgress = true);
    try {
      await widget.onSelected(result);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _selectionInProgress = false;
        _error = error.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.72,
      minChildSize: 0.48,
      maxChildSize: 0.82,
      expand: false,
      builder: (_, scrollController) {
        return Container(
          decoration: const BoxDecoration(
            color: kSurface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: Column(
            children: [
              const SizedBox(height: 12),
              Container(
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                  color: kBorder,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _searchController,
                        onChanged: _onQueryChanged,
                        style: TextStyle(color: kTextPrimary),
                        decoration: InputDecoration(
                          hintText: 'Search GIFs and stickers',
                          prefixIcon: const Icon(
                            Icons.search_rounded,
                            size: 20,
                          ),
                          suffixIcon: _searchController.text.isEmpty
                              ? null
                              : IconButton(
                                  onPressed: () {
                                    _searchController.clear();
                                    _refreshResults();
                                  },
                                  icon: const Icon(
                                    Icons.close_rounded,
                                    size: 18,
                                  ),
                                ),
                          filled: true,
                          fillColor: kSurfaceElevated,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 14,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(18),
                            borderSide: const BorderSide(color: kBorder),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(18),
                            borderSide: const BorderSide(color: kBorder),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(18),
                            borderSide: const BorderSide(color: kAccent),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: _isLoading ? null : _refreshResults,
                      child: Ink(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: kSurfaceElevated,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: kBorder),
                        ),
                        child: const Icon(
                          Icons.refresh_rounded,
                          color: kTextPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        _buildKindChip(
                          label: 'All',
                          kind: GiphySearchKind.both,
                        ),
                        const SizedBox(width: 8),
                        _buildKindChip(
                          label: 'GIFs',
                          kind: GiphySearchKind.gifs,
                        ),
                        const SizedBox(width: 8),
                        _buildKindChip(
                          label: 'Stickers',
                          kind: GiphySearchKind.stickers,
                        ),
                      ],
                    ),
                    const SizedBox(height: 7),
                    const Text(
                      'Powered by GIPHY',
                      style: TextStyle(
                        color: kTextSecondary,
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Builder(
                  builder: (context) {
                    if (_isLoading) {
                      return const Center(
                        child: CircularProgressIndicator(
                          color: kAccent,
                          strokeWidth: 2,
                        ),
                      );
                    }

                    if (_error != null) {
                      return _buildSheetMessage(
                        icon: Icons.key_off_rounded,
                        message: _error!,
                      );
                    }

                    if (_results.isEmpty) {
                      return _buildSheetMessage(
                        icon: Icons.gif_box_outlined,
                        message: _searchController.text.trim().isEmpty
                            ? 'No trending results right now.'
                            : 'No results for this search.',
                      );
                    }

                    return GridView.builder(
                      controller: scrollController,
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            mainAxisSpacing: 10,
                            crossAxisSpacing: 10,
                            childAspectRatio: 0.82,
                          ),
                      itemCount: _results.length,
                      itemBuilder: (_, index) {
                        final result = _results[index];
                        return Material(
                          color: Colors.transparent,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(22),
                            onTap: () => _selectResult(result),
                            child: Ink(
                              decoration: BoxDecoration(
                                color: kSurfaceElevated,
                                borderRadius: BorderRadius.circular(22),
                                border: Border.all(color: kBorder),
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(22),
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    Image.network(
                                      result.previewUrl,
                                      fit: BoxFit.cover,
                                      filterQuality: FilterQuality.low,
                                      errorBuilder: (_, _, _) => Container(
                                        color: kSurfaceElevated,
                                        alignment: Alignment.center,
                                        child: const Icon(
                                          Icons.broken_image_outlined,
                                          color: kTextSecondary,
                                        ),
                                      ),
                                    ),
                                    Positioned(
                                      right: 10,
                                      bottom: 10,
                                      child: Container(
                                        width: 30,
                                        height: 30,
                                        decoration: BoxDecoration(
                                          color: Colors.black.withValues(
                                            alpha: 0.45,
                                          ),
                                          shape: BoxShape.circle,
                                        ),
                                        child: const Icon(
                                          Icons.add_rounded,
                                          color: Colors.white,
                                          size: 18,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildKindChip({
    required String label,
    required GiphySearchKind kind,
  }) {
    final isSelected = _searchKind == kind;
    return ChoiceChip(
      label: Text(label),
      selected: isSelected,
      selectedColor: kAccent.withValues(alpha: 0.18),
      backgroundColor: kSurfaceElevated,
      side: BorderSide(color: isSelected ? kAccent : kBorder),
      labelStyle: TextStyle(
        color: isSelected ? kAccent : kTextSecondary,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
      onSelected: (_) {
        setState(() => _searchKind = kind);
        unawaited(_refreshResults());
      },
    );
  }

  Widget _buildSheetMessage({required IconData icon, required String message}) {
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: kSurfaceElevated,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: kBorder),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: kTextSecondary),
            const SizedBox(height: 10),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: kTextSecondary,
                fontSize: 12,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
