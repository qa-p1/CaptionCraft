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

class _EditorScreenState extends ConsumerState<EditorScreen> {
  Timer? _saveDebounce;
  Timer? _giphySearchDebounce;
  _CanvasAspectRatio _canvasAspectRatio = _CanvasAspectRatio.original;
  final TextEditingController _giphySearchController = TextEditingController();
  List<GiphyAssetResult> _giphyResults = const [];
  bool _isLoadingGiphy = false;
  bool _hasLoadedInitialGiphyResults = false;
  String? _giphyError;
  GiphySearchKind _giphySearchKind = GiphySearchKind.both;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
          .read(subtitleProvider.notifier)
          .initializeFromProject(
            entries: widget.project.subtitles,
            globalStyle: widget.project.globalStyle,
          );
      ref
          .read(editorProvider.notifier)
          .loadProject(
            videoPath: widget.project.videoPath,
            projectId: widget.project.id,
            projectName: widget.project.name,
            timeline: widget.project.timeline,
          );
    });
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    _giphySearchDebounce?.cancel();
    _giphySearchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final subtitleState = ref.watch(subtitleProvider);
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

    return Scaffold(
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
            tooltip: 'Generate subtitles',
            icon: const Icon(Icons.subtitles_rounded, color: kTextPrimary),
            onPressed: _handleGenerateSubtitles,
          ),
          IconButton(
            tooltip: 'Export / Import',
            icon: const Icon(Icons.ios_share_rounded, color: kTextPrimary),
            onPressed: _showExportActions,
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: isLandscape
          ? _buildLandscape(
              context,
              subtitleState.selectedEntry,
              selectedClip,
              editorState,
            )
          : _buildPortrait(
              context,
              subtitleState.selectedEntry,
              selectedClip,
              editorState,
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
    final targetClip = await _resolveTargetVideoClip(timeline);
    if (targetClip == null || !mounted) return;

    await _generateSubtitlesForClip(targetClip, timeline);
  }

  Future<TimelineClip?> _resolveTargetVideoClip(EditorTimeline timeline) async {
    final videoClips = timeline.videoClips;
    if (videoClips.isEmpty) {
      SnackBarHelper.showInfo(context, 'Import a video clip first.');
      return null;
    }

    final selectedClipId = ref.read(editorProvider).selectedClipId;
    if (selectedClipId != null) {
      for (final clip in videoClips) {
        if (clip.id == selectedClipId) {
          return clip;
        }
      }
    }

    if (videoClips.length == 1) {
      return videoClips.first;
    }

    return showModalBottomSheet<TimelineClip>(
      context: context,
      backgroundColor: kSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Text(
              'Choose Video Clip',
              style: GoogleFonts.inter(
                color: kTextPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            ...videoClips.map((clip) {
              return ListTile(
                leading: const Icon(Icons.movie_creation_outlined),
                title: Text(
                  clip.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${SubtitleEntry.formatDisplayTime(clip.startTime)} - ${SubtitleEntry.formatDisplayTime(clip.endTime)}',
                ),
                onTap: () => Navigator.pop(context, clip),
              );
            }),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }

  Future<void> _generateSubtitlesForClip(
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
    final videoPath = sourceAsset?.sourcePath ?? widget.project.videoPath;
    if (videoPath.isEmpty) {
      SnackBarHelper.showError(
        context,
        'Video source is missing for this clip.',
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
        videoPath: videoPath,
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
          'Generated ${shiftedEntries.length} subtitles for ${targetClip.label}',
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

  Future<void> _saveProjectState() async {
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

    final user = ref.read(currentUserProvider);
    if (user == null) return;

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

  Widget _buildPortrait(
    BuildContext context,
    SubtitleEntry? selectedEntry,
    TimelineClip? selectedClip,
    EditorState editorState,
  ) {
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
          child: TimelinePanel(onEditRequested: _openSubtitleTextEditor),
        ),
        _buildBottomEditorBar(selectedEntry, selectedClip),
        _buildBottomToolTabs(editorState),
        _buildBottomPanelSummary(context, editorState, selectedClip),
      ],
    );
  }

  Widget _buildLandscape(
    BuildContext context,
    SubtitleEntry? selectedEntry,
    TimelineClip? selectedClip,
    EditorState editorState,
  ) {
    return Row(
      children: [
        Expanded(
          flex: 3,
          child: Column(
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
                child: TimelinePanel(onEditRequested: _openSubtitleTextEditor),
              ),
              _buildBottomEditorBar(selectedEntry, selectedClip),
              _buildBottomToolTabs(editorState),
              _buildBottomPanelSummary(context, editorState, selectedClip),
            ],
          ),
        ),
        Container(
          width: 260,
          decoration: const BoxDecoration(
            border: Border(left: BorderSide(color: kBorder)),
          ),
          child: const SubtitleStylePanel(),
        ),
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

  void _onGiphyQueryChanged(String value) {
    setState(() {});
    _giphySearchDebounce?.cancel();
    _giphySearchDebounce = Timer(const Duration(milliseconds: 350), () {
      unawaited(_refreshGiphyResults());
    });
  }

  Future<void> _refreshGiphyResults() async {
    setState(() {
      _isLoadingGiphy = true;
      _giphyError = null;
    });

    try {
      final results = await GiphyService.search(
        query: _giphySearchController.text,
        kind: _giphySearchKind,
      );
      if (!mounted) return;
      setState(() {
        _giphyResults = results;
        _isLoadingGiphy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _giphyResults = const [];
        _giphyError = e.toString().replaceFirst('Exception: ', '');
        _isLoadingGiphy = false;
      });
    }
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

  Future<String?> _showTextClipDialog({String initialValue = ''}) async {
    final controller = TextEditingController(text: initialValue);
    final result = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: kSurface,
        title: Text(
          initialValue.isEmpty ? 'Add Text Clip' : 'Edit Text Clip',
          style: GoogleFonts.inter(
            color: kTextPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 4,
          minLines: 2,
          style: GoogleFonts.inter(color: kTextPrimary),
          decoration: InputDecoration(
            hintText: 'Type your text',
            hintStyle: GoogleFonts.inter(color: kTextSecondary),
            filled: true,
            fillColor: kSurfaceElevated,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: kBorder),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  void _deleteSelectedClip(TimelineClip clip) {
    final editorState = ref.read(editorProvider);
    final nextTracks = editorState.timeline.tracks
        .map(
          (track) => track.copyWith(
            clips: track.clips
                .where((candidate) => candidate.id != clip.id)
                .toList(),
          ),
        )
        .toList();

    ref
        .read(editorProvider.notifier)
        .setTimeline(editorState.timeline.copyWith(tracks: nextTracks));
    ref.read(editorProvider.notifier).selectClip(null);
  }

  void _updateSelectedClipTransition({
    required TimelineClip clip,
    TransitionType? type,
    int? durationMs,
  }) {
    final editorState = ref.read(editorProvider);
    final nextTracks = editorState.timeline.tracks.map((track) {
      final nextClips = track.clips
          .map(
            (candidate) => candidate.id == clip.id
                ? candidate.copyWith(
                    outroTransition: candidate.outroTransition.copyWith(
                      type: type ?? candidate.outroTransition.type,
                      durationMs:
                          durationMs ?? candidate.outroTransition.durationMs,
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

  void _updateSelectedClipAudioMix(
    TimelineClip clip, {
    bool? muted,
    double? volume,
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

  Widget _buildBottomEditorBar(
    SubtitleEntry? selectedEntry,
    TimelineClip? selectedClip,
  ) {
    final subtitleNotifier = ref.read(subtitleProvider.notifier);
    final playbackState = ref.watch(playbackProvider);
    final editorNotifier = ref.read(editorProvider.notifier);
    final hasSelection = selectedEntry != null;
    final hasVideoSelection = selectedClip?.type == TimelineTrackType.video;
    final hasTextClipSelection = selectedClip?.type == TimelineTrackType.text;
    final canDeleteClip = selectedClip != null && !hasSelection;

    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: const BoxDecoration(
        color: kSurface,
        border: Border(top: BorderSide(color: kBorder)),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Undo',
            icon: Icon(
              Icons.undo_rounded,
              color: subtitleNotifier.canUndo
                  ? kTextPrimary
                  : kTextPrimary.withValues(alpha: 0.3),
            ),
            onPressed: subtitleNotifier.canUndo
                ? () => subtitleNotifier.undo()
                : null,
          ),
          IconButton(
            tooltip: 'Redo',
            icon: Icon(
              Icons.redo_rounded,
              color: subtitleNotifier.canRedo
                  ? kTextPrimary
                  : kTextPrimary.withValues(alpha: 0.3),
            ),
            onPressed: subtitleNotifier.canRedo
                ? () => subtitleNotifier.redo()
                : null,
          ),
          const VerticalDivider(color: kBorder),
          IconButton(
            tooltip: 'Edit text',
            icon: Icon(
              Icons.edit_note_rounded,
              color: (hasSelection || hasTextClipSelection)
                  ? kTextPrimary
                  : kTextPrimary.withValues(alpha: 0.3),
            ),
            onPressed: hasSelection
                ? () => _openSubtitleTextEditor(selectedEntry)
                : hasTextClipSelection
                ? () => _editTextClip(selectedClip!)
                : null,
          ),
          IconButton(
            tooltip: 'Split at playhead',
            icon: Icon(
              Icons.call_split_rounded,
              color: hasSelection
                  ? kTextPrimary
                  : kTextPrimary.withValues(alpha: 0.3),
            ),
            onPressed: hasSelection
                ? () {
                    final entry = selectedEntry;
                    final splitPoint = playbackState.position;
                    if (splitPoint <= entry.startTime ||
                        splitPoint >= entry.endTime) {
                      SnackBarHelper.showInfo(
                        context,
                        'Move playhead inside the selected subtitle to split it.',
                      );
                      return;
                    }
                    subtitleNotifier.splitEntry(entry.id, splitPoint);
                  }
                : null,
          ),
          IconButton(
            tooltip: 'Duplicate',
            icon: Icon(
              Icons.copy_rounded,
              color: hasSelection
                  ? kTextPrimary
                  : kTextPrimary.withValues(alpha: 0.3),
            ),
            onPressed: hasSelection
                ? () => subtitleNotifier.duplicateEntry(selectedEntry.id)
                : null,
          ),
          IconButton(
            tooltip: 'Delete',
            icon: Icon(
              Icons.delete_rounded,
              color: (hasSelection || canDeleteClip)
                  ? kError
                  : kError.withValues(alpha: 0.3),
            ),
            onPressed: hasSelection
                ? () => subtitleNotifier.deleteEntry(selectedEntry.id)
                : canDeleteClip
                ? () => _deleteSelectedClip(selectedClip)
                : null,
          ),
          IconButton(
            tooltip: 'Transitions',
            icon: Icon(
              Icons.auto_awesome_motion_rounded,
              color: hasVideoSelection
                  ? kTextPrimary
                  : kTextPrimary.withValues(alpha: 0.3),
            ),
            onPressed: hasVideoSelection
                ? () => editorNotifier.setActivePanel(
                    EditorBottomPanel.transitions,
                  )
                : null,
          ),
          const Spacer(),
          Text(
            hasSelection
                ? 'Subtitle selected'
                : hasVideoSelection
                ? selectedClip!.label
                : 'No selection',
            style: GoogleFonts.inter(color: kTextSecondary, fontSize: 12),
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }

  Widget _buildBottomToolTabs(EditorState editorState) {
    const tabs = [
      (EditorBottomPanel.timeline, 'Edit', Icons.tune_rounded),
      (EditorBottomPanel.media, 'Media', Icons.perm_media_rounded),
      (EditorBottomPanel.text, 'Text', Icons.text_fields_rounded),
      (EditorBottomPanel.audio, 'Audio', Icons.graphic_eq_rounded),
      (EditorBottomPanel.stickers, 'Sticker', Icons.emoji_emotions_outlined),
      (
        EditorBottomPanel.transitions,
        'Transitions',
        Icons.auto_awesome_motion_rounded,
      ),
      (EditorBottomPanel.style, 'Style', Icons.palette_rounded),
    ];

    return Container(
      height: 54,
      decoration: const BoxDecoration(
        color: kSurface,
        border: Border(top: BorderSide(color: kBorder)),
      ),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: tabs.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, index) {
          final tab = tabs[index];
          final isActive = editorState.activePanel == tab.$1;
          return InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () =>
                ref.read(editorProvider.notifier).setActivePanel(tab.$1),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: isActive ? kAccent.withValues(alpha: 0.16) : kSurface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: isActive ? kAccent : kBorder),
              ),
              child: Row(
                children: [
                  Icon(
                    tab.$3,
                    size: 16,
                    color: isActive ? kAccent : kTextSecondary,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    tab.$2,
                    style: GoogleFonts.inter(
                      color: isActive ? kAccent : kTextSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildBottomPanelSummary(
    BuildContext context,
    EditorState editorState,
    TimelineClip? selectedClip,
  ) {
    if (editorState.activePanel == EditorBottomPanel.stickers) {
      return _buildStickerPanel();
    }
    if (editorState.activePanel == EditorBottomPanel.transitions &&
        selectedClip?.type == TimelineTrackType.video) {
      return _buildTransitionEditor(selectedClip!);
    }
    if (editorState.activePanel == EditorBottomPanel.audio &&
        selectedClip != null &&
        (selectedClip.type == TimelineTrackType.audio ||
            selectedClip.type == TimelineTrackType.video)) {
      return _buildAudioControls(selectedClip);
    }

    final summary = switch (editorState.activePanel) {
      EditorBottomPanel.timeline =>
        'Use the timeline to select clips, trim flow later, and place transitions between base videos.',
      EditorBottomPanel.media =>
        'Media panel will add overlay video, image, gif, and sticker assets onto overlay tracks.',
      EditorBottomPanel.text =>
        'Text panel manages title clips on text tracks and selected subtitle clips.',
      EditorBottomPanel.audio =>
        'Audio panel will add music, voiceover, and effects onto bottom audio tracks.',
      EditorBottomPanel.stickers =>
        'Search Giphy GIFs and stickers, then add them directly to overlay tracks at the playhead.',
      EditorBottomPanel.transitions =>
        selectedClip == null
            ? 'Tap the marker between base video clips to set a transition for that cut.'
            : 'Transition editing is focused on ${selectedClip.label}.',
      EditorBottomPanel.style =>
        'Style panel controls subtitle/text appearance and canvas look.',
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
      decoration: const BoxDecoration(
        color: kSurface,
        border: Border(top: BorderSide(color: kBorder)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              summary,
              style: GoogleFonts.inter(
                color: kTextSecondary,
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ),
          if (editorState.activePanel == EditorBottomPanel.media)
            TextButton.icon(
              onPressed: _pickOverlayMedia,
              icon: const Icon(Icons.add_photo_alternate_outlined, size: 16),
              label: const Text('Add'),
            ),
          if (editorState.activePanel == EditorBottomPanel.text)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton.icon(
                  onPressed: _addTextClipAtPlayhead,
                  icon: const Icon(Icons.title_rounded, size: 16),
                  label: const Text('Add'),
                ),
                if (selectedClip?.type == TimelineTrackType.text)
                  TextButton.icon(
                    onPressed: () => _editTextClip(selectedClip!),
                    icon: const Icon(Icons.edit_rounded, size: 16),
                    label: const Text('Edit'),
                  ),
              ],
            ),
          if (editorState.activePanel == EditorBottomPanel.audio)
            TextButton.icon(
              onPressed: _pickAudioMedia,
              icon: const Icon(Icons.library_music_rounded, size: 16),
              label: const Text('Add'),
            ),
          if (editorState.activePanel == EditorBottomPanel.style)
            TextButton.icon(
              onPressed: () => _openStylePanelSheet(context),
              icon: const Icon(Icons.open_in_new_rounded, size: 16),
              label: const Text('Open'),
            ),
        ],
      ),
    );
  }

  Widget _buildStickerPanel() {
    if (!_hasLoadedInitialGiphyResults && !_isLoadingGiphy) {
      _hasLoadedInitialGiphyResults = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_refreshGiphyResults());
      });
    }

    return Container(
      width: double.infinity,
      height: 250,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
      decoration: const BoxDecoration(
        color: kSurface,
        border: Border(top: BorderSide(color: kBorder)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _giphySearchController,
                  onChanged: _onGiphyQueryChanged,
                  style: GoogleFonts.inter(color: kTextPrimary),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'Search Giphy GIFs and stickers',
                    prefixIcon: const Icon(Icons.search_rounded, size: 18),
                    suffixIcon: _giphySearchController.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear',
                            icon: const Icon(Icons.close_rounded, size: 18),
                            onPressed: () {
                              _giphySearchController.clear();
                              _refreshGiphyResults();
                            },
                          ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Refresh',
                onPressed: _isLoadingGiphy ? null : _refreshGiphyResults,
                icon: const Icon(Icons.refresh_rounded, color: kTextSecondary),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            children: [
              _buildGiphyKindChip(
                label: 'GIFs + Stickers',
                kind: GiphySearchKind.both,
              ),
              _buildGiphyKindChip(label: 'GIFs', kind: GiphySearchKind.gifs),
              _buildGiphyKindChip(
                label: 'Stickers',
                kind: GiphySearchKind.stickers,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: Builder(
              builder: (context) {
                if (_isLoadingGiphy) {
                  return const Center(
                    child: CircularProgressIndicator(
                      color: kAccent,
                      strokeWidth: 2,
                    ),
                  );
                }
                if (_giphyError != null) {
                  return _buildGiphyMessage(
                    icon: Icons.key_off_rounded,
                    message: _giphyError!,
                  );
                }
                if (_giphyResults.isEmpty) {
                  return _buildGiphyMessage(
                    icon: Icons.gif_box_outlined,
                    message: _giphySearchController.text.trim().isEmpty
                        ? 'No trending items available right now.'
                        : 'No Giphy results for this search.',
                  );
                }

                return GridView.builder(
                  padding: EdgeInsets.zero,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 0.8,
                  ),
                  itemCount: _giphyResults.length,
                  itemBuilder: (context, index) {
                    final result = _giphyResults[index];
                    return InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => _insertGiphyAsset(result),
                      child: Ink(
                        decoration: BoxDecoration(
                          color: kSurfaceElevated,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: kBorder),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              child: ClipRRect(
                                borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(12),
                                ),
                                child: Image.network(
                                  result.previewUrl,
                                  fit: BoxFit.cover,
                                  filterQuality: FilterQuality.low,
                                  errorBuilder: (_, _, _) => Container(
                                    color: kSurface,
                                    child: const Center(
                                      child: Icon(
                                        Icons.broken_image_outlined,
                                        color: kTextSecondary,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    result.isSticker ? 'Sticker' : 'GIF',
                                    style: GoogleFonts.inter(
                                      color: kAccent,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    result.title,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: GoogleFonts.inter(
                                      color: kTextPrimary,
                                      fontSize: 11,
                                      height: 1.25,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
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
  }

  Widget _buildGiphyKindChip({
    required String label,
    required GiphySearchKind kind,
  }) {
    final isSelected = _giphySearchKind == kind;
    return ChoiceChip(
      label: Text(label),
      selected: isSelected,
      selectedColor: kAccent.withValues(alpha: 0.18),
      backgroundColor: kSurfaceElevated,
      side: BorderSide(color: isSelected ? kAccent : kBorder),
      labelStyle: GoogleFonts.inter(
        color: isSelected ? kAccent : kTextSecondary,
        fontSize: 12,
      ),
      onSelected: (_) {
        setState(() => _giphySearchKind = kind);
        unawaited(_refreshGiphyResults());
      },
    );
  }

  Widget _buildGiphyMessage({required IconData icon, required String message}) {
    return Container(
      decoration: BoxDecoration(
        color: kSurfaceElevated,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kBorder),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: kTextSecondary),
              const SizedBox(height: 8),
              Text(
                message,
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  color: kTextSecondary,
                  fontSize: 12,
                  height: 1.4,
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
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
      decoration: const BoxDecoration(
        color: kSurface,
        border: Border(top: BorderSide(color: kBorder)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
          Text(
            isVideoClip
                ? 'Overlay videos start muted by default. Use mute/unmute and volume here.'
                : 'Basic clip audio controls are active now. Deeper mixing will come in the advanced audio pass.',
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

  Widget _buildTransitionEditor(TimelineClip clip) {
    const transitionOptions = [
      (TransitionType.cut, 'Cut'),
      (TransitionType.fade, 'Fade'),
      (TransitionType.dissolve, 'Dissolve'),
      (TransitionType.slideLeft, 'Slide'),
      (TransitionType.zoom, 'Zoom'),
    ];
    const durationOptions = [0, 200, 400, 600, 800];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
      decoration: const BoxDecoration(
        color: kSurface,
        border: Border(top: BorderSide(color: kBorder)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: durationOptions.map((duration) {
              final isSelected = clip.outroTransition.durationMs == duration;
              return ChoiceChip(
                label: Text('${duration}ms'),
                selected: isSelected,
                selectedColor: kAccent.withValues(alpha: 0.18),
                backgroundColor: kSurfaceElevated,
                side: BorderSide(color: isSelected ? kAccent : kBorder),
                labelStyle: GoogleFonts.inter(
                  color: isSelected ? kAccent : kTextSecondary,
                  fontSize: 12,
                ),
                onSelected:
                    clip.outroTransition.type == TransitionType.cut &&
                        duration > 0
                    ? null
                    : (_) => _updateSelectedClipTransition(
                        clip: clip,
                        durationMs: duration,
                      ),
              );
            }).toList(),
          ),
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
