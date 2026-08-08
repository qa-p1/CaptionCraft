import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/timeline_export_service.dart';
import '../../../shared/models/project_model.dart';
import '../../editor/models/export_settings.dart';
import '../../editor/models/subtitle_entry.dart';
import '../../editor/models/subtitle_style_model.dart';
import '../../editor/models/timeline_models.dart';

class ExportVideoScreen extends StatefulWidget {
  final Project project;
  final EditorTimeline timeline;
  final ExportSettings settings;
  final List<SubtitleEntry> entries;
  final SubtitleStyleModel globalStyle;

  const ExportVideoScreen({
    super.key,
    required this.project,
    required this.timeline,
    required this.settings,
    required this.entries,
    required this.globalStyle,
  });

  @override
  State<ExportVideoScreen> createState() => _ExportVideoScreenState();
}

class _ExportVideoScreenState extends State<ExportVideoScreen> {
  double _progress = 0;
  String _statusText = 'Preparing export...';
  String? _errorText;
  String? _outputPath;
  String? _previewWarningText;
  String? _galleryWarningText;
  String? _projectSaveWarningText;
  bool _savedToGallery = false;
  bool _gallerySaveInProgress = false;
  bool _openInProgress = false;
  bool _isExporting = false;
  bool _isCancelling = false;
  TimelineExportResult? _exportResult;

  VideoPlayerController? _previewController;
  bool _previewReady = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _runExport();
    });
  }

  @override
  void dispose() {
    if (_isExporting) {
      unawaited(TimelineExportService.cancelActiveExport());
    }
    _previewController?.dispose();
    super.dispose();
  }

  Future<void> _runExport() async {
    setState(() {
      _progress = 0.03;
      _statusText = 'Generating subtitle track...';
      _errorText = null;
      _outputPath = null;
      _previewWarningText = null;
      _galleryWarningText = null;
      _projectSaveWarningText = null;
      _savedToGallery = false;
      _gallerySaveInProgress = false;
      _previewReady = false;
      _exportResult = null;
      _isExporting = true;
      _isCancelling = false;
    });

    try {
      final safeProjectName = _safeProjectName();
      final documentsDir = await getApplicationDocumentsDirectory();
      final exportDirectory = Directory(
        path.join(documentsDir.path, 'CaptionCraft', 'Exports'),
      );
      await exportDirectory.create(recursive: true);
      final outputPath = path.join(
        exportDirectory.path,
        '${safeProjectName}_${DateTime.now().millisecondsSinceEpoch}.mp4',
      );

      final exportResult = await TimelineExportService.export(
        project: widget.project,
        timeline: widget.timeline,
        subtitleEntries: widget.entries,
        globalSubtitleStyle: widget.globalStyle,
        settings: widget.settings,
        outputPath: outputPath,
        onProgress: (p) {
          if (!mounted) return;
          setState(() {
            _progress = p;
          });
        },
        onStage: (stage) {
          if (!mounted) return;
          setState(() => _statusText = stage);
        },
      );

      final outputFile = File(outputPath);
      if (!await outputFile.exists() || await outputFile.length() == 0) {
        throw Exception('Export produced an invalid video file.');
      }

      if (!mounted) return;
      setState(() {
        _outputPath = outputPath;
        _exportResult = exportResult;
        _progress = 0.97;
        _statusText = widget.settings.saveToGallery
            ? 'Saving to gallery...'
            : 'Preparing preview...';
      });

      var savedToGallery = false;
      String? galleryWarning;
      if (widget.settings.saveToGallery) {
        try {
          await Gal.putVideo(outputPath);
          savedToGallery = true;
        } catch (_) {
          savedToGallery = false;
          galleryWarning =
              'The video was exported, but CaptionCraft could not add it to '
              'your gallery. Check photo permissions and try again.';
        }
      }

      String? projectSaveWarning;
      try {
        await ProjectLocalStorage.saveProject(
          widget.project.copyWith(
            timeline: widget.timeline,
            subtitles: widget.entries,
            globalStyle: widget.globalStyle,
            lastExportPath: outputPath,
            lastModifiedAt: DateTime.now(),
          ),
        );
      } catch (_) {
        projectSaveWarning =
            'The video is safe, but its export path could not be added to '
            'project history.';
      }

      final previewReady = await _initializePreview(outputPath);
      final previewWarning = previewReady
          ? null
          : 'Video exported, but preview is unavailable on this device.';

      if (!mounted) return;
      setState(() {
        _savedToGallery = savedToGallery;
        _galleryWarningText = galleryWarning;
        _projectSaveWarningText = projectSaveWarning;
        _progress = 1;
        _statusText = previewReady
            ? 'Export complete'
            : 'Export complete (preview unavailable)';
        _previewWarningText = previewWarning;
        _isExporting = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorText = _isCancelling
            ? 'Export cancelled.'
            : e.toString().replaceFirst('Exception: ', '');
        _statusText = _isCancelling ? 'Export cancelled' : 'Export failed';
        _isExporting = false;
      });
    }
  }

  Future<void> _cancelExport() async {
    if (!_isExporting || _isCancelling) return;
    setState(() {
      _isCancelling = true;
      _statusText = 'Cancelling export...';
    });
    await TimelineExportService.cancelActiveExport();
  }

  Future<void> _handleBack() async {
    if (!_isExporting) {
      Navigator.pop(context, _outputPath);
      return;
    }
    final shouldStop = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Stop this render?'),
        content: const Text(
          'Leaving now will cancel the current export and remove its partial file.',
          style: TextStyle(color: kTextSecondary, height: 1.45),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep rendering'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: kError),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Stop render'),
          ),
        ],
      ),
    );
    if (shouldStop != true || !mounted) return;
    await _cancelExport();
    if (mounted) Navigator.pop(context);
  }

  Future<bool> _initializePreview(String videoPath) async {
    VideoPlayerController? createdController;
    try {
      _previewController?.dispose();
      final controller = VideoPlayerController.file(File(videoPath));
      createdController = controller;
      await controller.initialize();
      controller.addListener(() {
        if (!mounted) return;
        setState(() {});
      });

      if (!mounted) {
        await controller.dispose();
        return false;
      }

      setState(() {
        _previewController = controller;
        _previewReady = true;
      });
      return true;
    } catch (_) {
      final controller = createdController;
      if (controller != null && !identical(controller, _previewController)) {
        try {
          await controller.dispose();
        } catch (_) {
          // Failed initialization may already have released the native handle.
        }
      }
      if (!mounted) return false;
      setState(() {
        _previewController = null;
        _previewReady = false;
      });
      return false;
    }
  }

  Future<void> _openGalleryApp() async {
    try {
      await Gal.open();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to open gallery app.')),
      );
    }
  }

  Future<void> _retryGallerySave() async {
    final outputPath = _outputPath;
    if (outputPath == null || _gallerySaveInProgress) return;
    setState(() => _gallerySaveInProgress = true);
    try {
      await Gal.putVideo(outputPath);
      if (!mounted) return;
      setState(() {
        _savedToGallery = true;
        _galleryWarningText = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Video added to your gallery.')),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _galleryWarningText =
            'CaptionCraft still could not add the video to your gallery. '
            'Check photo permissions and available storage.';
      });
    } finally {
      if (mounted) setState(() => _gallerySaveInProgress = false);
    }
  }

  Future<void> _openFileExplorer() async {
    final outputPath = _outputPath;
    if (outputPath == null) return;

    setState(() => _openInProgress = true);
    try {
      final openTarget =
          (Platform.isWindows || Platform.isMacOS || Platform.isLinux)
          ? path.dirname(outputPath)
          : outputPath;

      final result = await OpenFilex.open(openTarget);
      if (!mounted) return;
      if (result.type != ResultType.done) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open path: ${result.message}')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Unable to open the exported video.')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _openInProgress = false);
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

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_isExporting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_handleBack());
      },
      child: Scaffold(
        backgroundColor: kBackground,
        appBar: AppBar(
          leading: BackButton(onPressed: _handleBack),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Delivery',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
              Text(
                widget.project.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: kTextSecondary,
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          actions: [
            if (_isExporting)
              TextButton(
                onPressed: _isCancelling ? null : _cancelExport,
                child: Text(_isCancelling ? 'Cancelling…' : 'Cancel render'),
              ),
            const SizedBox(width: 8),
          ],
        ),
        body: AnimatedSwitcher(
          duration: const Duration(milliseconds: 260),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          child: _errorText != null
              ? _buildError()
              : _outputPath == null
              ? _buildRendering()
              : _buildSuccess(),
        ),
      ),
    );
  }

  Widget _buildRendering() {
    final progress = _progress.clamp(0.0, 1.0);
    return Center(
      key: const ValueKey('rendering'),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 56),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 660),
          child: Column(
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(22, 24, 22, 22),
                decoration: BoxDecoration(
                  color: kSurface,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: kBorder),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.24),
                      blurRadius: 34,
                      offset: const Offset(0, 16),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    SizedBox(
                      width: 138,
                      height: 138,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          SizedBox.expand(
                            child: CircularProgressIndicator(
                              value: progress,
                              strokeWidth: 7,
                              strokeCap: StrokeCap.round,
                              backgroundColor: kSurfaceHigh,
                              color: kAccent,
                            ),
                          ),
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '${(progress * 100).round()}',
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  color: kTextPrimary,
                                  fontSize: 31,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -1.5,
                                ),
                              ),
                              const Text(
                                'PERCENT',
                                style: TextStyle(
                                  color: kTextSecondary,
                                  fontSize: 8.5,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 1.2,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      _statusText,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: kTextPrimary,
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.35,
                      ),
                    ),
                    const SizedBox(height: 7),
                    const Text(
                      'Keep CaptionCraft open while the timeline is encoded.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: kTextSecondary,
                        fontSize: 12,
                        height: 1.45,
                      ),
                    ),
                    const SizedBox(height: 25),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: kBackground,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: kBorder),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.tune_rounded,
                            color: kAccentSecondary,
                            size: 17,
                          ),
                          const SizedBox(width: 9),
                          Expanded(
                            child: Text(
                              '${widget.settings.resolutionLabel}  ·  '
                              '${widget.settings.frameRateLabel}  ·  '
                              '${widget.settings.qualityLabel}',
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                color: kTextPrimary,
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const Text(
                            'H.264',
                            style: TextStyle(
                              color: kTextSecondary,
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 22),
                    _buildRenderPipeline(progress),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              TextButton.icon(
                onPressed: _isCancelling ? null : _cancelExport,
                icon: _isCancelling
                    ? const SizedBox(
                        width: 15,
                        height: 15,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.close_rounded, size: 17),
                label: Text(
                  _isCancelling ? 'Stopping renderer…' : 'Cancel render',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRenderPipeline(double progress) {
    return Row(
      children: [
        Expanded(
          child: _ExportStep(
            label: 'PREP',
            icon: Icons.inventory_2_outlined,
            active: progress < 0.12,
            complete: progress >= 0.12,
          ),
        ),
        const _StepConnector(),
        Expanded(
          child: _ExportStep(
            label: 'RENDER',
            icon: Icons.movie_filter_outlined,
            active: progress >= 0.12 && progress < 0.96,
            complete: progress >= 0.96,
          ),
        ),
        const _StepConnector(),
        Expanded(
          child: _ExportStep(
            label: 'VERIFY',
            icon: Icons.verified_outlined,
            active: progress >= 0.96 && progress < 1,
            complete: progress >= 1,
          ),
        ),
      ],
    );
  }

  Widget _buildSuccess() {
    final controller = _previewController;
    final canPreview =
        _previewReady && controller != null && controller.value.isInitialized;
    return ListView(
      key: const ValueKey('success'),
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 34),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 920),
            child: Column(
              children: [
                _buildSuccessHeader(),
                if (_galleryWarningText != null ||
                    _projectSaveWarningText != null) ...[
                  const SizedBox(height: 10),
                  _buildCompletionWarnings(),
                ],
                const SizedBox(height: 14),
                Container(
                  width: double.infinity,
                  constraints: BoxConstraints(
                    minHeight: canPreview ? 240 : 210,
                    maxHeight: MediaQuery.sizeOf(context).height * 0.52,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: kBorder),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: canPreview
                      ? _buildVideoPreview(controller)
                      : _buildPreviewUnavailable(),
                ),
                if (canPreview) ...[
                  const SizedBox(height: 8),
                  _buildPlaybackStrip(controller),
                ],
                const SizedBox(height: 14),
                _buildExportDetails(),
                const SizedBox(height: 14),
                _buildDeliveryActions(),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSuccessHeader() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: kSuccess.withValues(alpha: 0.065),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kSuccess.withValues(alpha: 0.24)),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: kSuccess.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(11),
            ),
            child: const Icon(Icons.check_rounded, color: kSuccess, size: 23),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Master delivered',
                  style: TextStyle(
                    color: kTextPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _savedToGallery
                      ? 'Saved to Exports and your gallery'
                      : 'Saved safely in CaptionCraft / Exports',
                  style: const TextStyle(color: kTextSecondary, fontSize: 11),
                ),
              ],
            ),
          ),
          const Text(
            'COMPLETE',
            style: TextStyle(
              fontFamily: 'monospace',
              color: kSuccess,
              fontSize: 9,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.9,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompletionWarnings() {
    final warnings = [?_galleryWarningText, ?_projectSaveWarningText];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(13, 11, 10, 11),
      decoration: BoxDecoration(
        color: kWarning.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kWarning.withValues(alpha: 0.28)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Icon(Icons.warning_amber_rounded, color: kWarning, size: 18),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: warnings
                  .map(
                    (warning) => Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Text(
                        warning,
                        style: const TextStyle(
                          color: kTextPrimary,
                          fontSize: 11,
                          height: 1.4,
                        ),
                      ),
                    ),
                  )
                  .toList(growable: false),
            ),
          ),
          if (_galleryWarningText != null)
            TextButton(
              onPressed: _gallerySaveInProgress ? null : _retryGallerySave,
              child: _gallerySaveInProgress
                  ? const SizedBox(
                      width: 15,
                      height: 15,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Retry'),
            ),
        ],
      ),
    );
  }

  Widget _buildVideoPreview(VideoPlayerController controller) {
    return Stack(
      alignment: Alignment.center,
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => controller.value.isPlaying
                ? controller.pause()
                : controller.play(),
            child: Center(
              child: AspectRatio(
                aspectRatio: controller.value.aspectRatio,
                child: VideoPlayer(controller),
              ),
            ),
          ),
        ),
        if (!controller.value.isPlaying)
          IgnorePointer(
            child: Container(
              width: 62,
              height: 62,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.62),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
              ),
              child: const Icon(
                Icons.play_arrow_rounded,
                color: Colors.white,
                size: 36,
              ),
            ),
          ),
        Positioned(
          left: 12,
          top: 12,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.66),
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Text(
              'FINAL MASTER',
              style: TextStyle(
                color: Colors.white,
                fontSize: 8.5,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.8,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPlaybackStrip(VideoPlayerController controller) {
    final duration = controller.value.duration;
    final position = controller.value.position;
    final progress = duration.inMilliseconds == 0
        ? 0.0
        : (position.inMilliseconds / duration.inMilliseconds)
              .clamp(0.0, 1.0)
              .toDouble();
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 7),
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kBorder),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: controller.value.isPlaying ? 'Pause' : 'Play',
            onPressed: () => controller.value.isPlaying
                ? controller.pause()
                : controller.play(),
            icon: Icon(
              controller.value.isPlaying
                  ? Icons.pause_rounded
                  : Icons.play_arrow_rounded,
              size: 20,
            ),
          ),
          Text(
            SubtitleEntry.formatDisplayTime(position),
            style: const TextStyle(
              fontFamily: 'monospace',
              color: kTextSecondary,
              fontSize: 9.5,
            ),
          ),
          Expanded(
            child: Slider(
              value: progress,
              onChanged: (value) => controller.seekTo(
                Duration(
                  milliseconds: (duration.inMilliseconds * value).round(),
                ),
              ),
            ),
          ),
          Text(
            SubtitleEntry.formatDisplayTime(duration),
            style: const TextStyle(
              fontFamily: 'monospace',
              color: kTextSecondary,
              fontSize: 9.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewUnavailable() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: kSurfaceElevated,
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Icon(
                Icons.movie_outlined,
                color: kSuccess,
                size: 31,
              ),
            ),
            const SizedBox(height: 15),
            const Text(
              'The file is ready',
              style: TextStyle(
                color: kTextPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _previewWarningText ??
                  'This device cannot preview the codec, but validation passed.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: kTextSecondary,
                fontSize: 11.5,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildExportDetails() {
    final result = _exportResult;
    final outputPath = _outputPath;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kBorder),
      ),
      child: Column(
        children: [
          Row(
            children: [
              const Icon(
                Icons.insert_drive_file_outlined,
                color: kTextSecondary,
                size: 17,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  outputPath == null
                      ? 'Exported video'
                      : path.basename(outputPath),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: kTextPrimary,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          if (result != null) ...[
            const SizedBox(height: 12),
            const Divider(height: 1),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _DetailBadge(
                  icon: Icons.aspect_ratio_rounded,
                  label: '${result.width} × ${result.height}',
                ),
                _DetailBadge(
                  icon: Icons.storage_rounded,
                  label:
                      '${(result.fileSize / 1024 / 1024).toStringAsFixed(1)} MB',
                ),
                _DetailBadge(
                  icon: result.hasAudio
                      ? Icons.volume_up_outlined
                      : Icons.volume_off_outlined,
                  label: result.hasAudio ? 'Audio mixed' : 'Silent',
                ),
                const _DetailBadge(
                  icon: Icons.movie_filter_outlined,
                  label: 'MP4 / H.264',
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDeliveryActions() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 500;
        final openFiles = FilledButton.icon(
          onPressed: _openInProgress ? null : _openFileExplorer,
          icon: _openInProgress
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    color: kOnAccent,
                    strokeWidth: 2,
                  ),
                )
              : const Icon(Icons.folder_open_rounded, size: 18),
          label: Text(
            Platform.isAndroid || Platform.isIOS
                ? 'Open video'
                : 'Show in files',
          ),
        );
        final gallery = OutlinedButton.icon(
          onPressed: _openGalleryApp,
          icon: const Icon(Icons.photo_library_outlined, size: 18),
          label: const Text('Gallery'),
        );
        final done = TextButton(
          onPressed: () => Navigator.pop(context, _outputPath),
          child: const Text('Done'),
        );
        if (compact) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              openFiles,
              if (_savedToGallery) ...[const SizedBox(height: 9), gallery],
              const SizedBox(height: 5),
              done,
            ],
          );
        }
        return Row(
          children: [
            Expanded(flex: 2, child: openFiles),
            if (_savedToGallery) ...[
              const SizedBox(width: 9),
              Expanded(child: gallery),
            ],
            const SizedBox(width: 4),
            done,
          ],
        );
      },
    );
  }

  Widget _buildError() {
    final wasCancelled = _statusText == 'Export cancelled';
    return Center(
      key: const ValueKey('error'),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 540),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: kSurface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: (wasCancelled ? kWarning : kError).withValues(
                  alpha: 0.34,
                ),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 66,
                  height: 66,
                  decoration: BoxDecoration(
                    color: (wasCancelled ? kWarning : kError).withValues(
                      alpha: 0.1,
                    ),
                    borderRadius: BorderRadius.circular(17),
                  ),
                  child: Icon(
                    wasCancelled
                        ? Icons.stop_circle_outlined
                        : Icons.error_outline_rounded,
                    color: wasCancelled ? kWarning : kError,
                    size: 33,
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  wasCancelled ? 'Render cancelled' : 'Render interrupted',
                  style: const TextStyle(
                    color: kTextPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.4,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _errorText ?? 'The renderer stopped unexpectedly.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: kTextSecondary,
                    fontSize: 12,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 22),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Back to editor'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _runExport,
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: const Text('Try again'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ExportStep extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool active;
  final bool complete;

  const _ExportStep({
    required this.label,
    required this.icon,
    required this.active,
    required this.complete,
  });

  @override
  Widget build(BuildContext context) {
    final color = complete
        ? kSuccess
        : active
        ? kAccent
        : kTextSecondary;
    return Column(
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            shape: BoxShape.circle,
            border: Border.all(color: color.withValues(alpha: 0.45)),
          ),
          child: Icon(
            complete ? Icons.check_rounded : icon,
            color: color,
            size: 16,
          ),
        ),
        const SizedBox(height: 7),
        Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 8.5,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.8,
          ),
        ),
      ],
    );
  }
}

class _StepConnector extends StatelessWidget {
  const _StepConnector();

  @override
  Widget build(BuildContext context) {
    return const Expanded(
      child: Padding(
        padding: EdgeInsets.only(bottom: 22),
        child: Divider(height: 1),
      ),
    );
  }
}

class _DetailBadge extends StatelessWidget {
  final IconData icon;
  final String label;

  const _DetailBadge({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
      decoration: BoxDecoration(
        color: kSurfaceElevated,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: kTextSecondary, size: 13),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              fontFamily: 'monospace',
              color: kTextPrimary,
              fontSize: 9,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
