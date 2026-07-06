// ignore_for_file: use_build_context_synchronously

import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/ffmpeg_service.dart';
import '../../../core/utils/firebase_service.dart';
import '../../../core/utils/giphy_service.dart';
import '../../../core/utils/subtitle_export_service.dart';
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
import '../providers/editor_provider.dart';
import '../providers/playback_provider.dart';
import '../providers/subtitle_provider.dart';
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

enum _BottomActionCategory { overlay, text, audio, motion }

class _EditorScreenState extends ConsumerState<EditorScreen>
    with WidgetsBindingObserver {
  Timer? _saveDebounce;
  bool _isSavingProject = false;
  bool _queuedProjectSave = false;
  bool _queuedRemoteSync = false;
  _CanvasAspectRatio _canvasAspectRatio = _CanvasAspectRatio.original;
  _BottomActionCategory? _activeBottomCategory;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final initialStyle = _normalizedInitialSubtitleStyle(
        widget.project.globalStyle,
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
            timeline: widget.project.timeline.mergeSubtitleEntries(
              subtitles: widget.project.subtitles,
              globalStyle: initialStyle,
            ),
          );
    });
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_saveProjectState(syncRemote: false));
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_flushProjectSave(syncRemote: false));
    }
  }

  SubtitleStyleModel _normalizedInitialSubtitleStyle(SubtitleStyleModel style) {
    if (style.fontSize == 24 && style.maxWidthFactor == 0.85) {
      return style.copyWith(fontSize: 10, maxWidthFactor: 1);
    }
    return style;
  }

  @override
  Widget build(BuildContext context) {
    final editorState = ref.watch(editorProvider);
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final selectedClip = _selectedClipFromState(editorState);

    ref.listen(subtitleProvider, (prev, next) {
      final entriesChanged = prev?.entries != next.entries;
      final styleChanged = prev?.globalStyle != next.globalStyle;
      if (entriesChanged || styleChanged) {
        _scheduleProjectSave();
      }
    });
    ref.listen(editorProvider.select((state) => state.timeline), (prev, next) {
      if (prev != null && prev != next) {
        _scheduleProjectSave();
      }
    });

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          unawaited(_flushProjectSave(syncRemote: false));
        }
      },
      child: Scaffold(
        backgroundColor: kBackground,
        appBar: AppBar(
          backgroundColor: kBackground,
          title: Text(
            widget.project.name,
            style: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          actions: [
            _buildAspectRatioPicker(),
            IconButton(
              tooltip: 'Export / Import',
              icon: const Icon(Icons.ios_share_rounded, color: kTextPrimary),
              onPressed: _showExportActions,
            ),
            const SizedBox(width: 6),
          ],
        ),
        body: isLandscape
            ? _buildLandscape(context, selectedClip)
            : _buildPortrait(context, selectedClip),
      ),
    );
  }

  void _showExportActions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: kSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) {
        final state = ref.read(subtitleProvider);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
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

  Future<void> _exportSubtitleFile(String format) async {
    final state = ref.read(subtitleProvider);
    try {
      final generatedPath = format == 'srt'
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

      final lowerPath = filePath.toLowerCase();
      final entries = lowerPath.endsWith('.vtt')
          ? await SubtitleExportService.importVtt(filePath)
          : await SubtitleExportService.importSrt(filePath);

      if (entries.isEmpty) {
        if (!mounted) return;
        SnackBarHelper.showWarning(context, 'No subtitles found in file');
        return;
      }

      ref.read(subtitleProvider.notifier).loadSubtitles(entries);
      _scheduleProjectSave(immediate: true);
      if (!mounted) return;
      SnackBarHelper.showSuccess(
        context,
        'Imported ${entries.length} subtitles',
      );
    } catch (e) {
      if (!mounted) return;
      SnackBarHelper.showError(context, 'Import failed: $e');
    }
  }

  void _showExportDialog() {
    final state = ref.read(subtitleProvider);
    if (state.entries.isEmpty) {
      SnackBarHelper.showInfo(context, 'Add subtitles before exporting');
      return;
    }

    showDialog(
      context: context,
      builder: (_) => ExportDialog(
        onExport: (quality) {
          Navigator.pop(context);
          _openExportVideoScreen(quality);
        },
      ),
    );
  }

  void _openExportVideoScreen(String quality) {
    final state = ref.read(subtitleProvider);
    if (state.entries.isEmpty) {
      SnackBarHelper.showInfo(context, 'Add subtitles before exporting');
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ExportVideoScreen(
          project: widget.project,
          quality: quality,
          entries: List<SubtitleEntry>.from(state.entries),
          globalStyle: state.globalStyle,
        ),
      ),
    );
  }

  Future<void> _handleGenerateSubtitles() async {
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
  }

  Future<TimelineClip?> _chooseCaptionSourceClip(
    EditorTimeline timeline,
  ) async {
    final captionSources =
        timeline.tracks
            .expand((track) => track.clips)
            .where(
              (clip) =>
                  clip.type == TimelineTrackType.video ||
                  clip.type == TimelineTrackType.audio,
            )
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
            maxHeight: MediaQuery.of(context).size.height * 0.72,
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
                style: GoogleFonts.inter(
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
                        style: GoogleFonts.inter(color: kTextPrimary),
                      ),
                      subtitle: Text(
                        '${isAudio ? 'Audio' : 'Video'} • '
                        '${SubtitleEntry.formatDisplayTime(clip.startTime)} - '
                        '${SubtitleEntry.formatDisplayTime(clip.endTime)}',
                        style: GoogleFonts.inter(
                          color: kTextSecondary,
                          fontSize: 12,
                        ),
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

    final consumed = await ref
        .read(quotaProvider.notifier)
        .consumeRun(user.uid);
    if (!consumed) {
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const QuotaExhaustedScreen()),
      );
      return;
    }

    if (!mounted) return;
    final pipeline = TranscriptionPipeline();
    var processingClosed = false;

    unawaited(
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (processingContext) => ProcessingScreen(
            progressStream: pipeline.progressStream,
            onCancel: () {
              pipeline.cancel();
              if (Navigator.of(processingContext).canPop()) {
                Navigator.of(processingContext).pop();
              }
            },
          ),
        ),
      ).then((_) {
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
        if (!processingClosed && mounted && Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
        if (mounted) {
          SnackBarHelper.showInfo(
            context,
            'No subtitles detected for this clip.',
          );
        }
        return;
      }

      final shiftedEntries =
          generatedEntries
              .map(
                (entry) => entry.copyWith(
                  startTime: entry.startTime + targetClip.startTime,
                  endTime: entry.endTime + targetClip.startTime,
                ),
              )
              .toList()
            ..sort((a, b) => a.startTime.compareTo(b.startTime));

      final existingLinkedSubtitleIds = timeline
          .subtitleClipsForLinkedClip(targetClip.id)
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
        generatedEntries: shiftedEntries,
      );

      ref.read(subtitleProvider.notifier).loadSubtitles(mergedEntries);
      ref.read(editorProvider.notifier).setTimeline(nextTimeline);
      _scheduleProjectSave(immediate: true);

      if (!processingClosed && mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
      if (mounted) {
        SnackBarHelper.showSuccess(
          context,
          'Generated ${shiftedEntries.length} captions for ${targetClip.label}',
        );
      }
    } catch (e) {
      if (!processingClosed && mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
      if (mounted) {
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
    required List<SubtitleEntry> generatedEntries,
  }) {
    final subtitleTrack = timeline.primarySubtitleTrack;
    final subtitleTrackId = subtitleTrack?.id ?? 'track_subtitles';
    final existingSubtitleClips = timeline.tracks
        .where((track) => track.type == TimelineTrackType.subtitle)
        .expand((track) => track.clips)
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

    final mergedTrack = TimelineTrack(
      id: subtitleTrackId,
      name: subtitleTrack?.name ?? 'Subtitles',
      type: TimelineTrackType.subtitle,
      section: TimelineTrackSection.textSubtitle,
      clips: [...existingSubtitleClips, ...generatedSubtitleClips]
        ..sort((a, b) => a.startTime.compareTo(b.startTime)),
    );

    return timeline.copyWith(
      tracks: [
        ...timeline.tracks.where(
          (track) => track.type != TimelineTrackType.subtitle,
        ),
        mergedTrack,
      ],
    );
  }

  void _scheduleProjectSave({bool immediate = false}) {
    _saveDebounce?.cancel();
    if (immediate) {
      unawaited(_saveProjectState());
      return;
    }
    _saveDebounce = Timer(const Duration(seconds: 2), () {
      unawaited(_saveProjectState());
    });
  }

  Future<void> _flushProjectSave({bool syncRemote = true}) async {
    _saveDebounce?.cancel();
    await _saveProjectState(syncRemote: syncRemote);
  }

  Future<void> _saveProjectState({bool syncRemote = true}) async {
    if (_isSavingProject) {
      _queuedProjectSave = true;
      _queuedRemoteSync = _queuedRemoteSync || syncRemote;
      return;
    }

    _isSavingProject = true;
    var shouldSyncRemote = syncRemote;

    try {
      while (true) {
        _queuedProjectSave = false;
        _queuedRemoteSync = false;

        final subtitleState = ref.read(subtitleProvider);
        final editorState = ref.read(editorProvider);
        final mergedTimeline = editorState.timeline.mergeSubtitleEntries(
          subtitles: subtitleState.entries,
          globalStyle: subtitleState.globalStyle,
        );
        final updatedProject = widget.project.copyWith(
          subtitles: subtitleState.entries,
          globalStyle: subtitleState.globalStyle,
          timeline: mergedTimeline,
          lastModifiedAt: DateTime.now(),
        );

        await ProjectLocalStorage.saveProject(updatedProject);

        if (shouldSyncRemote) {
          final user = ref.read(currentUserProvider);
          if (user != null) {
            try {
              await FirebaseService.saveProject(
                user.uid,
                updatedProject.id,
                updatedProject.toFirestore(),
              );
            } catch (_) {
              // Local persistence remains the fallback when Firestore sync fails.
            }
          }
        }

        if (!_queuedProjectSave) {
          break;
        }

        shouldSyncRemote = _queuedRemoteSync;
      }
    } finally {
      _isSavingProject = false;
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

  Widget _buildPortrait(BuildContext context, TimelineClip? selectedClip) {
    return Column(
      children: [
        SizedBox(
          height: MediaQuery.of(context).size.height * 0.35,
          child: VideoPreviewPanel(
            videoPath: widget.project.videoPath,
            targetAspectRatio: _selectedAspectRatioValue,
          ),
        ),
        Expanded(
          flex: 2,
          child: TimelinePanel(
            onEditRequested: _openSubtitleTextEditor,
            onTextClipEditRequested: _editTextClip,
            onTransitionRequested: _openTransitionSheet,
            onOverlayAddRequested: _pickOverlayMediaForTrack,
          ),
        ),
        _buildBottomQuickActions(context, selectedClip),
      ],
    );
  }

  Widget _buildLandscape(BuildContext context, TimelineClip? selectedClip) {
    return Column(
      children: [
        Expanded(
          flex: 3,
          child: VideoPreviewPanel(
            videoPath: widget.project.videoPath,
            targetAspectRatio: _selectedAspectRatioValue,
          ),
        ),
        Expanded(
          flex: 2,
          child: TimelinePanel(
            onEditRequested: _openSubtitleTextEditor,
            onTextClipEditRequested: _editTextClip,
            onTransitionRequested: _openTransitionSheet,
            onOverlayAddRequested: _pickOverlayMediaForTrack,
          ),
        ),
        _buildBottomQuickActions(context, selectedClip),
      ],
    );
  }

  PopupMenuButton<_CanvasAspectRatio> _buildAspectRatioPicker() {
    return PopupMenuButton<_CanvasAspectRatio>(
      tooltip: 'Aspect ratio',
      color: kSurface,
      onSelected: (value) {
        setState(() => _canvasAspectRatio = value);
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
              style: GoogleFonts.inter(
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
          Text(label, style: GoogleFonts.inter(color: kTextPrimary)),
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
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => SubtitleEditModal(entry: entry),
    );
  }

  Future<void> _pickOverlayMedia() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      type: FileType.custom,
      allowedExtensions: ['png', 'jpg', 'jpeg', 'webp', 'gif', 'mp4', 'mov'],
    );
    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;
    final filePath = file.path;
    if (filePath == null) return;

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
      metadata = {
        'durationMs': mediaInfo['durationMs'],
        'width': mediaInfo['width'],
        'height': mediaInfo['height'],
      };
    }

    _insertClipIntoTimeline(
      section: TimelineTrackSection.overlay,
      assetType: assetType,
      clipType: clipType,
      sourcePath: filePath,
      label: file.name,
      sourceDuration: sourceDuration,
      metadata: metadata,
    );
  }

  Future<void> _pickOverlayMediaForTrack(TimelineTrack track) async {
    ref.read(editorProvider.notifier).selectTrack(track.id);
    await _pickOverlayMedia();
  }

  Future<void> _pickAudioMedia() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      type: FileType.audio,
    );
    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;
    final filePath = file.path;
    if (filePath == null) return;

    final mediaInfo = await FFmpegService.getMediaInfo(filePath);
    final duration = Duration(
      milliseconds: (mediaInfo['durationMs'] as int?) ?? 0,
    );

    _insertClipIntoTimeline(
      section: TimelineTrackSection.audio,
      assetType: EditorAssetType.audio,
      clipType: TimelineTrackType.audio,
      sourcePath: filePath,
      label: file.name,
      sourceDuration: duration,
      metadata: {'durationMs': mediaInfo['durationMs']},
    );
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
    final targetTrack = _resolveInsertionTrack(timeline, section);
    if (targetTrack == null) {
      SnackBarHelper.showError(
        context,
        'No ${section == TimelineTrackSection.audio ? 'audio' : 'overlay'} track available.',
      );
      return;
    }

    final playhead = ref.read(playbackProvider).position;
    final maxDuration = Duration(milliseconds: widget.project.durationMs);
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

    final nextTracks = timeline.tracks.map((track) {
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
    final targetTrack = _resolveInsertionTrack(
      timeline,
      TimelineTrackSection.textSubtitle,
    );
    if (targetTrack == null) {
      SnackBarHelper.showError(context, 'No text track available.');
      return;
    }

    final playhead = ref.read(playbackProvider).position;
    final maxDuration = Duration(milliseconds: widget.project.durationMs);
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

    final nextTracks = timeline.tracks.map((track) {
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
    final enteredText = await _showTextClipDialog(
      initialValue: clip.text ?? '',
    );
    if (enteredText == null || enteredText.trim().isEmpty) return;

    final editorState = ref.read(editorProvider);
    final nextTracks = editorState.timeline.tracks.map((track) {
      final nextClips = track.clips
          .map(
            (candidate) => candidate.id == clip.id
                ? candidate.copyWith(
                    label: enteredText.trim(),
                    text: enteredText.trim(),
                  )
                : candidate,
          )
          .toList();
      return track.copyWith(clips: nextClips);
    }).toList();

    ref
        .read(editorProvider.notifier)
        .setTimeline(editorState.timeline.copyWith(tracks: nextTracks));
    SnackBarHelper.showSuccess(context, 'Text updated');
  }

  Future<void> _openClipAnimationSheetForSelection(TimelineClip clip) async {
    final editorState = ref.read(editorProvider);
    final track = _trackForClip(clip, editorState);
    if (track == null) return;
    await _openClipAnimationSheet(clip, track);
  }

  Future<String?> _showTextClipDialog({String initialValue = ''}) async {
    final controller = TextEditingController(text: initialValue);
    final focusNode = FocusNode();
    final result = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
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
                  style: GoogleFonts.inter(
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
                  style: GoogleFonts.inter(color: kTextPrimary),
                  decoration: InputDecoration(
                    hintText: 'Type your text',
                    hintStyle: GoogleFonts.inter(color: kTextSecondary),
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
    final nextTracks = editorState.timeline.tracks.map((track) {
      final nextClips = track.clips
          .map(
            (candidate) => candidate.id == clip.id
                ? candidate.copyWith(
                    introTransition: updateIntro
                        ? candidate.introTransition.copyWith(
                            type: type ?? candidate.introTransition.type,
                            durationMs:
                                durationMs ??
                                candidate.introTransition.durationMs,
                          )
                        : candidate.introTransition,
                    outroTransition: updateOutro
                        ? candidate.outroTransition.copyWith(
                            type: type ?? candidate.outroTransition.type,
                            durationMs:
                                durationMs ??
                                candidate.outroTransition.durationMs,
                          )
                        : candidate.outroTransition,
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

  void _updateSelectedClipAudioMix(
    TimelineClip clip, {
    bool? muted,
    double? volume,
    int? fadeInMs,
    int? fadeOutMs,
  }) {
    final editorState = ref.read(editorProvider);
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
  ) {
    final editorState = ref.read(editorProvider);
    if (editorState.selectedTrackId != null) {
      for (final track in timeline.tracks) {
        if (track.id == editorState.selectedTrackId &&
            track.section == section) {
          return track;
        }
      }
    }

    final sectionTracks = timeline.tracksForSection(section);
    if (section == TimelineTrackSection.overlay) {
      for (final track in sectionTracks) {
        if (track.name == 'Overlay 1') {
          return track;
        }
      }
    }
    if (section == TimelineTrackSection.audio) {
      for (final track in sectionTracks) {
        if (track.name == 'Audio 1') {
          return track;
        }
      }
    }
    if (section == TimelineTrackSection.textSubtitle) {
      for (final track in sectionTracks) {
        if (track.type == TimelineTrackType.text && track.name == 'Text 1') {
          return track;
        }
      }
      for (final track in sectionTracks) {
        if (track.type == TimelineTrackType.text) {
          return track;
        }
      }
    }
    return sectionTracks.isEmpty ? null : sectionTracks.first;
  }

  Widget _buildBottomQuickActions(
    BuildContext context,
    TimelineClip? selectedClip,
  ) {
    final editorState = ref.read(editorProvider);
    final selectedTrack = _trackForClip(selectedClip, editorState);
    final canAdjustAudio =
        selectedClip != null &&
        (selectedClip.type == TimelineTrackType.audio ||
            selectedClip.type == TimelineTrackType.video);
    final canAnimateClip =
        selectedClip != null &&
        selectedTrack != null &&
        (selectedTrack.section == TimelineTrackSection.overlay ||
            selectedTrack.section == TimelineTrackSection.baseVideo);
    final canTransition =
        selectedClip != null &&
        selectedTrack?.section == TimelineTrackSection.baseVideo;

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
        child: _activeBottomCategory == null
            ? _buildCategoryRow()
            : _buildToolRow(
                category: _activeBottomCategory!,
                selectedClip: selectedClip,
                canAdjustAudio: canAdjustAudio,
                canAnimateClip: canAnimateClip,
                canTransition: canTransition,
              ),
      ),
    );
  }

  Widget _buildCategoryRow() {
    final categories = [
      _ActionSpec(
        label: 'Overlay',
        tooltip: 'Overlay tools',
        icon: Icons.layers_rounded,
        onTap: () => setState(
          () => _activeBottomCategory = _BottomActionCategory.overlay,
        ),
      ),
      _ActionSpec(
        label: 'Text',
        tooltip: 'Text tools',
        icon: Icons.title_rounded,
        onTap: () =>
            setState(() => _activeBottomCategory = _BottomActionCategory.text),
      ),
      _ActionSpec(
        label: 'Audio',
        tooltip: 'Audio tools',
        icon: Icons.graphic_eq_rounded,
        onTap: () =>
            setState(() => _activeBottomCategory = _BottomActionCategory.audio),
      ),
      _ActionSpec(
        label: 'Motion',
        tooltip: 'Motion tools',
        icon: Icons.auto_awesome_motion_rounded,
        onTap: () => setState(
          () => _activeBottomCategory = _BottomActionCategory.motion,
        ),
      ),
    ];
    return _buildActionScroller(
      key: const ValueKey('categories'),
      actions: categories,
      spread: true,
    );
  }

  Widget _buildToolRow({
    required _BottomActionCategory category,
    required TimelineClip? selectedClip,
    required bool canAdjustAudio,
    required bool canAnimateClip,
    required bool canTransition,
  }) {
    final actions = switch (category) {
      _BottomActionCategory.overlay => [
        _ActionSpec(
          label: 'Media',
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
          label: 'Lane',
          tooltip: 'Add overlay lane',
          icon: Icons.playlist_add_rounded,
          onTap: () => _addTimelineTrack(TimelineTrackSection.overlay),
        ),
      ],
      _BottomActionCategory.text => [
        _ActionSpec(
          label: 'Add',
          tooltip: 'Add text',
          icon: Icons.title_rounded,
          onTap: _addTextClipAtPlayhead,
        ),
        _ActionSpec(
          label: 'Edit',
          tooltip: 'Edit selected text',
          icon: Icons.edit_rounded,
          onTap: selectedClip?.type == TimelineTrackType.text
              ? () => _editTextClip(selectedClip!)
              : selectedClip?.type == TimelineTrackType.subtitle
              ? () {
                  final entry = selectedClip!.toSubtitleEntry();
                  if (entry != null) _openSubtitleTextEditor(entry);
                }
              : null,
        ),
        _ActionSpec(
          label: 'Style',
          tooltip: 'Subtitle style',
          icon: Icons.palette_outlined,
          onTap: () => _openStylePanelSheet(context),
        ),
        _ActionSpec(
          label: 'Captions',
          tooltip: 'Generate captions',
          icon: Icons.closed_caption_rounded,
          onTap: _handleGenerateSubtitles,
        ),
      ],
      _BottomActionCategory.audio => [
        _ActionSpec(
          label: 'Add',
          tooltip: 'Add audio',
          icon: Icons.music_note_rounded,
          onTap: _pickAudioMedia,
        ),
        _ActionSpec(
          label: 'Mix',
          tooltip: 'Volume and fades',
          icon: Icons.tune_rounded,
          onTap: canAdjustAudio
              ? () => _openAudioControlsSheet(selectedClip!)
              : null,
        ),
      ],
      _BottomActionCategory.motion => [
        _ActionSpec(
          label: 'Animate',
          tooltip: 'Clip animation',
          icon: Icons.auto_awesome_motion_rounded,
          onTap: canAnimateClip
              ? () => _openClipAnimationSheetForSelection(selectedClip!)
              : null,
        ),
        _ActionSpec(
          label: 'Transition',
          tooltip: 'Base clip transition',
          icon: Icons.join_inner_rounded,
          onTap: canTransition
              ? () => _openTransitionSheet(selectedClip!)
              : null,
        ),
      ],
    };

    return _buildActionScroller(
      key: ValueKey('tools_${category.name}'),
      actions: [
        ...actions,
        _ActionSpec(
          label: 'Back',
          tooltip: 'Back to categories',
          icon: Icons.arrow_back_rounded,
          onTap: () => setState(() => _activeBottomCategory = null),
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

  void _addTimelineTrack(TimelineTrackSection section) {
    final timeline = ref.read(editorProvider).timeline;
    final nextTrack = switch (section) {
      TimelineTrackSection.overlay => TimelineTrack(
        name: timeline.nextTrackNameForSection(section),
        type: TimelineTrackType.video,
        section: TimelineTrackSection.overlay,
      ),
      TimelineTrackSection.textSubtitle => TimelineTrack(
        name: timeline.nextTrackNameForSection(section),
        type: TimelineTrackType.text,
        section: TimelineTrackSection.textSubtitle,
      ),
      TimelineTrackSection.audio => TimelineTrack(
        name: timeline.nextTrackNameForSection(section),
        type: TimelineTrackType.audio,
        section: TimelineTrackSection.audio,
      ),
      TimelineTrackSection.baseVideo => null,
    };
    if (nextTrack == null) return;
    ref
        .read(editorProvider.notifier)
        .setTimeline(
          timeline.copyWith(tracks: [...timeline.tracks, nextTrack]),
        );
    ref.read(editorProvider.notifier).selectTrack(nextTrack.id);
  }

  Future<void> _openAudioControlsSheet(TimelineClip clip) async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Consumer(
        builder: (context, ref, _) {
          final editorState = ref.watch(editorProvider);
          final liveClip = _clipById(clip.id, editorState) ?? clip;
          return _buildAudioControls(liveClip);
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
                style: GoogleFonts.inter(
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
            style: GoogleFonts.inter(
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
                style: GoogleFonts.inter(color: kTextSecondary, fontSize: 12),
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
              onChanged: (value) => _updateSelectedClipAudioMix(
                clip,
                volume: value,
                muted: value == 0 ? true : false,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Fade In',
            style: GoogleFonts.inter(color: kTextSecondary, fontSize: 12),
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
              onChanged: (value) =>
                  _updateSelectedClipAudioMix(clip, fadeInMs: value.round()),
            ),
          ),
          Text(
            'Fade Out',
            style: GoogleFonts.inter(color: kTextSecondary, fontSize: 12),
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
              onChanged: (value) =>
                  _updateSelectedClipAudioMix(clip, fadeOutMs: value.round()),
            ),
          ),
          Text(
            isVideoClip
                ? 'Overlay video audio can be faded in and out here.'
                : 'Audio clips now support volume plus simple fade in and fade out.',
            style: GoogleFonts.inter(
              color: kTextSecondary,
              fontSize: 12,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openTransitionSheet(TimelineClip clip) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      builder: (_) => Consumer(
        builder: (context, ref, _) {
          final editorState = ref.watch(editorProvider);
          final liveClip = _clipById(clip.id, editorState) ?? clip;
          return _buildTransitionEditor(liveClip);
        },
      ),
    );
  }

  Future<void> _openClipAnimationSheet(
    TimelineClip clip,
    TimelineTrack track,
  ) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      builder: (_) => Consumer(
        builder: (context, ref, _) {
          final editorState = ref.watch(editorProvider);
          final liveClip = _clipById(clip.id, editorState) ?? clip;
          final liveTrack = _trackForClip(liveClip, editorState) ?? track;
          return _buildClipAnimationSheet(liveClip, liveTrack);
        },
      ),
    );
  }

  Widget _buildTransitionEditor(TimelineClip clip) {
    const transitionOptions = [
      (TransitionType.cut, 'Cut'),
      (TransitionType.fade, 'Fade'),
      (TransitionType.dissolve, 'Dissolve'),
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
            style: GoogleFonts.inter(
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
                labelStyle: GoogleFonts.inter(
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
            style: GoogleFonts.inter(color: kTextSecondary, fontSize: 12),
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
              onChanged: (value) => _updateSelectedClipTransition(
                clip: clip,
                durationMs: clip.outroTransition.type == TransitionType.cut
                    ? 0
                    : value.round(),
              ),
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
            style: GoogleFonts.inter(
              color: kTextPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          if (!isAudioTrack) ...[
            Text(
              'Animate In',
              style: GoogleFonts.inter(color: kTextSecondary, fontSize: 12),
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
                  labelStyle: GoogleFonts.inter(
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
              style: GoogleFonts.inter(color: kTextSecondary, fontSize: 12),
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
                  labelStyle: GoogleFonts.inter(
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
              style: GoogleFonts.inter(color: kTextSecondary, fontSize: 12),
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
              ),
            ),
          ] else ...[
            Text(
              'Fade In',
              style: GoogleFonts.inter(color: kTextSecondary, fontSize: 12),
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
                onChanged: (value) =>
                    _updateSelectedClipAudioMix(clip, fadeInMs: value.round()),
              ),
            ),
            Text(
              'Fade Out',
              style: GoogleFonts.inter(color: kTextSecondary, fontSize: 12),
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
                onChanged: (value) =>
                    _updateSelectedClipAudioMix(clip, fadeOutMs: value.round()),
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
        initialChildSize: 0.45,
        maxChildSize: 0.85,
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
                  style: GoogleFonts.inter(
                    color: kTextPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  'Keep sheet lower to preview changes on video',
                  style: GoogleFonts.inter(color: kTextSecondary, fontSize: 11),
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
  String? _error;
  GiphySearchKind _searchKind = GiphySearchKind.both;

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
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final results = await GiphyService.search(
        query: _searchController.text,
        kind: _searchKind,
      );
      if (!mounted) return;
      setState(() {
        _results = results;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _results = const [];
        _error = e.toString().replaceFirst('Exception: ', '');
        _isLoading = false;
      });
    }
  }

  Future<void> _selectResult(GiphyAssetResult result) async {
    await widget.onSelected(result);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.82,
      minChildSize: 0.5,
      maxChildSize: 0.94,
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
                        style: GoogleFonts.inter(color: kTextPrimary),
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
                child: Row(
                  children: [
                    _buildKindChip(label: 'All', kind: GiphySearchKind.both),
                    const SizedBox(width: 8),
                    _buildKindChip(label: 'GIFs', kind: GiphySearchKind.gifs),
                    const SizedBox(width: 8),
                    _buildKindChip(
                      label: 'Stickers',
                      kind: GiphySearchKind.stickers,
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
      labelStyle: GoogleFonts.inter(
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
              style: GoogleFonts.inter(
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
