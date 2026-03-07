import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/firebase_service.dart';
import '../../../core/utils/subtitle_export_service.dart';
import '../../../shared/models/project_model.dart';
import '../../../shared/widgets/snack_bar_helper.dart';
import '../../auth/providers/auth_provider.dart';
import '../models/subtitle_entry.dart';
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
  _CanvasAspectRatio _canvasAspectRatio = _CanvasAspectRatio.original;

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
    });
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final subtitleState = ref.watch(subtitleProvider);
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    ref.listen(subtitleProvider, (prev, next) {
      final entriesChanged = prev?.entries != next.entries;
      final styleChanged = prev?.globalStyle != next.globalStyle;
      if (entriesChanged || styleChanged) {
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
            tooltip: 'Export / Import',
            icon: const Icon(Icons.ios_share_rounded, color: kTextPrimary),
            onPressed: _showExportActions,
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: isLandscape
          ? _buildLandscape(context, subtitleState.selectedEntry)
          : _buildPortrait(context, subtitleState.selectedEntry),
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
    final updatedProject = widget.project.copyWith(
      subtitles: subtitleState.entries,
      globalStyle: subtitleState.globalStyle,
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

  Widget _buildPortrait(BuildContext context, SubtitleEntry? selectedEntry) {
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
        _buildBottomEditorBar(selectedEntry),
        _buildStyleTabButton(context),
      ],
    );
  }

  Widget _buildLandscape(BuildContext context, SubtitleEntry? selectedEntry) {
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
              _buildBottomEditorBar(selectedEntry),
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

  Widget _buildBottomEditorBar(SubtitleEntry? selectedEntry) {
    final subtitleNotifier = ref.read(subtitleProvider.notifier);
    final playbackState = ref.watch(playbackProvider);
    final hasSelection = selectedEntry != null;

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
              color: hasSelection
                  ? kTextPrimary
                  : kTextPrimary.withValues(alpha: 0.3),
            ),
            onPressed: hasSelection
                ? () => _openSubtitleTextEditor(selectedEntry)
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
              color: hasSelection ? kError : kError.withValues(alpha: 0.3),
            ),
            onPressed: hasSelection
                ? () => subtitleNotifier.deleteEntry(selectedEntry.id)
                : null,
          ),
          const Spacer(),
          Text(
            hasSelection ? '1 selected' : 'No selection',
            style: GoogleFonts.inter(color: kTextSecondary, fontSize: 12),
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }

  Widget _buildStyleTabButton(BuildContext context) {
    return GestureDetector(
      onTap: () {
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
                      style: GoogleFonts.inter(
                        color: kTextSecondary,
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Expanded(child: SubtitleStylePanel()),
                  ],
                ),
              );
            },
          ),
        );
      },
      child: Container(
        height: 48,
        color: kSurface,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.palette_rounded, color: kAccent, size: 18),
            const SizedBox(width: 8),
            Text(
              'Subtitle Style',
              style: GoogleFonts.inter(
                color: kAccent,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(width: 4),
            const Icon(
              Icons.keyboard_arrow_up_rounded,
              color: kAccent,
              size: 18,
            ),
          ],
        ),
      ),
    );
  }
}
