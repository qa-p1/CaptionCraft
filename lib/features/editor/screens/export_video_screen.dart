import 'dart:io';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/ffmpeg_service.dart';
import '../../../core/utils/subtitle_export_service.dart';
import '../../../shared/models/project_model.dart';
import '../../editor/models/subtitle_entry.dart';
import '../../editor/models/subtitle_style_model.dart';

class ExportVideoScreen extends StatefulWidget {
  final Project project;
  final String quality;
  final List<SubtitleEntry> entries;
  final SubtitleStyleModel globalStyle;

  const ExportVideoScreen({
    super.key,
    required this.project,
    required this.quality,
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
  bool _savedToGallery = false;
  bool _openInProgress = false;

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
      _savedToGallery = false;
      _previewReady = false;
    });

    try {
      final tempDir = await getTemporaryDirectory();

      final assPath = await SubtitleExportService.generateAss(
        widget.entries,
        widget.globalStyle,
        fileName: 'subtitles_${widget.project.id}.ass',
      );

      final assFile = File(assPath);
      if (!await assFile.exists() || await assFile.length() == 0) {
        throw Exception('Failed to generate subtitle track.');
      }

      final assContent = await assFile.readAsString();
      final dialogueCount = RegExp(
        r'^Dialogue:',
        multiLine: true,
      ).allMatches(assContent).length;
      if (dialogueCount == 0) {
        throw Exception('No subtitle lines were generated.');
      }

      setState(() {
        _progress = 0.1;
        _statusText = 'Rendering video...';
      });

      final safeProjectName = _safeProjectName();
      final outputPath = path.join(
        tempDir.path,
        '${safeProjectName}_exported_${DateTime.now().millisecondsSinceEpoch}.mp4',
      );

      final existingOutput = File(outputPath);
      if (await existingOutput.exists()) {
        await existingOutput.delete();
      }

      await FFmpegService.burnSubtitles(
        videoPath: widget.project.videoPath,
        assFilePath: assPath,
        outputPath: outputPath,
        quality: widget.quality,
        onProgress: (p) {
          if (!mounted) return;
          setState(() {
            _progress = 0.1 + (p * 0.78);
          });
        },
      );

      final outputFile = File(outputPath);
      if (!await outputFile.exists() || await outputFile.length() == 0) {
        throw Exception('Export produced an invalid video file.');
      }

      setState(() {
        _outputPath = outputPath;
        _progress = 0.9;
        _statusText = 'Saving to gallery...';
      });

      var savedToGallery = false;
      try {
        await Gal.putVideo(outputPath);
        savedToGallery = true;
      } catch (_) {
        savedToGallery = false;
      }

      final previewReady = await _initializePreview(outputPath);
      final previewWarning = previewReady
          ? null
          : 'Video exported, but preview is unavailable on this device.';

      if (!mounted) return;
      setState(() {
        _savedToGallery = savedToGallery;
        _progress = 1;
        _statusText = previewReady
            ? 'Export complete'
            : 'Export complete (preview unavailable)';
        _previewWarningText = previewWarning;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorText = e.toString().replaceFirst('Exception: ', '');
        _statusText = 'Export failed';
      });
    }
  }

  Future<bool> _initializePreview(String videoPath) async {
    try {
      _previewController?.dispose();
      final controller = VideoPlayerController.file(File(videoPath));
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
    return Scaffold(
      backgroundColor: kBackground,
      appBar: AppBar(
        backgroundColor: kBackground,
        title: Text(
          'Export Video',
          style: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      body: _errorText != null ? _buildError() : _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_outputPath == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(color: kAccent),
              const SizedBox(height: 20),
              Text(
                _statusText,
                style: GoogleFonts.inter(
                  color: kTextPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: _progress.clamp(0, 1),
                  minHeight: 8,
                  backgroundColor: kSurfaceElevated,
                  color: kAccent,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '${(_progress * 100).round()}%',
                style: GoogleFonts.spaceMono(
                  color: kTextSecondary,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (!_previewReady || _previewController == null) {
      return _buildSuccessWithoutPreview();
    }

    final controller = _previewController!;
    final duration = controller.value.duration;
    final position = controller.value.position;

    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Container(
              decoration: BoxDecoration(
                color: kSurface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: kBorder),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Center(
                      child: AspectRatio(
                        aspectRatio: controller.value.aspectRatio,
                        child: VideoPlayer(controller),
                      ),
                    ),
                    if (!controller.value.isPlaying)
                      GestureDetector(
                        onTap: () => controller.play(),
                        child: const Icon(
                          Icons.play_circle_filled_rounded,
                          color: Colors.white,
                          size: 64,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Slider(
            value: duration.inMilliseconds == 0
                ? 0
                : (position.inMilliseconds / duration.inMilliseconds)
                      .clamp(0, 1)
                      .toDouble(),
            onChanged: (value) {
              final targetMs = (duration.inMilliseconds * value).round();
              controller.seekTo(Duration(milliseconds: targetMs));
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: Row(
            children: [
              Text(
                SubtitleEntry.formatDisplayTime(position),
                style: GoogleFonts.spaceMono(
                  color: kTextSecondary,
                  fontSize: 11,
                ),
              ),
              const Spacer(),
              Text(
                SubtitleEntry.formatDisplayTime(duration),
                style: GoogleFonts.spaceMono(
                  color: kTextSecondary,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _openGalleryApp,
                  icon: const Icon(Icons.photo_library_rounded, size: 18),
                  label: const Text('Open Gallery'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kAccent,
                    foregroundColor: Colors.white,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _openInProgress ? null : _openFileExplorer,
                  icon: const Icon(Icons.folder_open_rounded, size: 18),
                  label: const Text('Open Files'),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: kBorder),
                    foregroundColor: kTextPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        if (_previewWarningText != null)
          Text(
            _previewWarningText!,
            style: GoogleFonts.inter(color: kWarning, fontSize: 12),
          )
        else if (_savedToGallery)
          Text(
            'Saved to gallery successfully',
            style: GoogleFonts.inter(color: kSuccess, fontSize: 12),
          )
        else
          Text(
            'Preview ready. Gallery save was skipped/failed.',
            style: GoogleFonts.inter(color: kWarning, fontSize: 12),
          ),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _buildSuccessWithoutPreview() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: Column(
        children: [
          const SizedBox(height: 24),
          Container(
            width: 76,
            height: 76,
            decoration: const BoxDecoration(
              color: kSurfaceElevated,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.check_circle_rounded,
              color: kSuccess,
              size: 42,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'Video exported',
            style: GoogleFonts.inter(
              color: kTextPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 18,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _previewWarningText ??
                'Preview is not available here, but the file was exported.',
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(color: kTextSecondary, fontSize: 13),
          ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _openGalleryApp,
                    icon: const Icon(Icons.photo_library_rounded, size: 18),
                    label: const Text('Open Gallery'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: kAccent,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _openInProgress ? null : _openFileExplorer,
                    icon: const Icon(Icons.folder_open_rounded, size: 18),
                    label: const Text('Open Files'),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: kBorder),
                      foregroundColor: kTextPrimary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          if (_savedToGallery)
            Text(
              'Saved to gallery successfully',
              style: GoogleFonts.inter(color: kSuccess, fontSize: 12),
            )
          else
            Text(
              'Preview ready. Gallery save was skipped/failed.',
              style: GoogleFonts.inter(color: kWarning, fontSize: 12),
            ),
        ],
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_rounded, color: kError, size: 42),
            const SizedBox(height: 10),
            Text(
              'Export failed',
              style: GoogleFonts.inter(
                color: kTextPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _errorText ?? 'Unknown error',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(color: kTextSecondary, fontSize: 13),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Back'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _runExport,
                    child: const Text('Retry'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
