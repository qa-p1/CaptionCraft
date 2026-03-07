import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shimmer/shimmer.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/text_styles.dart';
import '../../../core/constants/groq_constants.dart';
import '../../../core/utils/device_quota_service.dart';
import '../../../core/utils/ffmpeg_service.dart';
import '../../../core/utils/firebase_service.dart';
import '../../../shared/widgets/app_button.dart';
import '../../../shared/widgets/snack_bar_helper.dart';
import '../../../shared/models/project_model.dart';
import '../../auth/providers/auth_provider.dart';
import '../../quota/providers/quota_provider.dart';
import '../../quota/screens/quota_exhausted_screen.dart';
import '../../editor/screens/editor_screen.dart';
import '../../profile/screens/profile_screen.dart';
import '../providers/transcription_pipeline.dart';
import 'processing_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  List<Project> _projects = [];
  bool _isLoadingProjects = true;
  bool _showDeviceQuotaNotice = false;
  String? _loadWarning;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _loadData();
    });
  }

  Future<void> _loadData() async {
    if (mounted) {
      setState(() {
        _isLoadingProjects = true;
        _loadWarning = null;
      });
    }

    final user = ref.read(currentUserProvider);
    var showDeviceNotice = false;
    String? warning;
    List<Project> projects = [];
    List<Project> localProjects = [];

    try {
      await ref
          .read(quotaProvider.notifier)
          .loadQuota()
          .timeout(const Duration(seconds: 8), onTimeout: () {});

      if (user != null) {
        try {
          final boundUid = await DeviceQuotaService.getBoundUid();
          showDeviceNotice = boundUid != null && boundUid != user.uid;
        } catch (_) {
          showDeviceNotice = false;
        }
      }

      localProjects = await ProjectLocalStorage.loadProjects();
      projects = localProjects;

      // Merge cloud projects on top when available, but keep local access as the
      // primary experience so transient Firestore issues do not block the home
      // screen or produce a misleading warning for local-only usage.
      if (user != null) {
        try {
          final firestoreData = await FirebaseService.loadProjects(
            user.uid,
          ).timeout(const Duration(seconds: 10));
          final cloudProjects = firestoreData
              .map((d) => Project.fromFirestore(d))
              .toList();
          projects = _mergeProjects(localProjects, cloudProjects);
        } catch (_) {
          projects = localProjects;
          if (localProjects.isEmpty) {
            warning = 'Cloud sync is unavailable right now.';
          }
        }
      }
    } catch (_) {
      warning = localProjects.isEmpty ? 'Load failed. Please try again.' : null;
      try {
        projects = localProjects.isNotEmpty
            ? localProjects
            : await ProjectLocalStorage.loadProjects();
      } catch (_) {
        projects = [];
      }
    }

    if (mounted) {
      setState(() {
        _projects = projects;
        _isLoadingProjects = false;
        _showDeviceQuotaNotice = showDeviceNotice;
        _loadWarning = warning;
      });
    }
  }

  List<Project> _mergeProjects(
    List<Project> localProjects,
    List<Project> cloudProjects,
  ) {
    final merged = <String, Project>{};

    for (final project in localProjects) {
      merged[project.id] = project;
    }

    for (final project in cloudProjects) {
      final existing = merged[project.id];
      if (existing == null ||
          project.lastModifiedAt.isAfter(existing.lastModifiedAt)) {
        merged[project.id] = project;
      }
    }

    final result = merged.values.toList()
      ..sort((a, b) => b.lastModifiedAt.compareTo(a.lastModifiedAt));
    return result;
  }

  Future<void> _importVideo() async {
    final quota = ref.read(quotaProvider);
    if (!quota.canRun) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const QuotaExhaustedScreen()),
      );
      return;
    }

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.video,
        allowMultiple: false,
      );

      if (result == null || result.files.isEmpty) return;
      final filePath = result.files.first.path;
      if (filePath == null) return;

      final mediaInfo = await FFmpegService.getMediaInfo(filePath);
      if (!(mediaInfo['hasAudio'] as bool)) {
        if (mounted) {
          SnackBarHelper.showError(
            context,
            'This video has no audio track. Subtitles require audio.',
          );
        }
        return;
      }

      final durationMs = mediaInfo['durationMs'] as int? ?? 0;
      final maxDurationMs = GroqConstants.maxVideoDurationMinutes * 60 * 1000;
      if (durationMs > maxDurationMs) {
        if (mounted) {
          SnackBarHelper.showError(
            context,
            'Maximum supported video length is ${GroqConstants.maxVideoDurationMinutes} minutes.',
          );
        }
        return;
      }

      if (mounted) {
        _showImportSheet(
          videoPath: filePath,
          fileName: result.files.first.name,
          mediaInfo: mediaInfo,
        );
      }
    } catch (e) {
      if (mounted) {
        SnackBarHelper.showError(context, 'Failed to pick video: $e');
      }
    }
  }

  void _showImportSheet({
    required String videoPath,
    required String fileName,
    required Map<String, dynamic> mediaInfo,
  }) {
    const languageOptions = <MapEntry<String, String>>[
      MapEntry('', 'Auto Detect'),
      MapEntry('en', 'English'),
      MapEntry('es', 'Spanish'),
      MapEntry('fr', 'French'),
      MapEntry('de', 'German'),
      MapEntry('hi', 'Hindi'),
      MapEntry('ja', 'Japanese'),
    ];

    var selectedLanguage = '';
    final durationMs = mediaInfo['durationMs'] as int? ?? 0;
    final width = mediaInfo['width'] as int? ?? 0;
    final height = mediaInfo['height'] as int? ?? 0;
    final fileSize = mediaInfo['fileSize'] as int? ?? 0;

    // Pre-fill project name from filename without extension
    final baseName = fileName.contains('.')
        ? fileName.substring(0, fileName.lastIndexOf('.'))
        : fileName;
    final projectNameController = TextEditingController(text: baseName);

    showModalBottomSheet(
      context: context,
      backgroundColor: kSurface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => Padding(
          padding: EdgeInsets.only(
            left: 24,
            right: 24,
            top: 24,
            bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: kBorder,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Import Video',
                style: GoogleFonts.inter(
                  color: kTextPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 16),
              // Project Name field
              Text(
                'Project Name',
                style: GoogleFonts.inter(
                  color: kTextSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 6),
              TextField(
                controller: projectNameController,
                style: GoogleFonts.inter(color: kTextPrimary, fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'Enter project name',
                  hintStyle: GoogleFonts.inter(color: kTextSecondary),
                  filled: true,
                  fillColor: kSurfaceElevated,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: kBorder),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: kBorder),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: kAccent, width: 1.5),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _infoRow('File', fileName),
              const SizedBox(height: 8),
              _infoRow('Duration', _formatDuration(durationMs)),
              const SizedBox(height: 8),
              _infoRow('Resolution', '${width}x$height'),
              const SizedBox(height: 8),
              _infoRow('Size', _formatBytes(fileSize)),
              const SizedBox(height: 16),
              Text(
                'Language',
                style: GoogleFonts.inter(
                  color: kTextSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: kSurfaceElevated,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: kBorder),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: selectedLanguage,
                    isExpanded: true,
                    dropdownColor: kSurfaceElevated,
                    style: GoogleFonts.inter(color: kTextPrimary),
                    items: languageOptions
                        .map(
                          (entry) => DropdownMenuItem<String>(
                            value: entry.key,
                            child: Text(entry.value),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      setSheetState(() => selectedLanguage = value ?? '');
                    },
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: AppButton(
                      label: 'Cancel',
                      variant: AppButtonVariant.ghost,
                      onPressed: () => Navigator.pop(sheetContext),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: AppButton(
                      label: 'Transcribe',
                      icon: Icons.auto_awesome_rounded,
                      onPressed: () {
                        final name = projectNameController.text.trim();
                        Navigator.pop(sheetContext);
                        _startTranscription(
                          videoPath,
                          language: selectedLanguage,
                          projectName: name.isNotEmpty ? name : baseName,
                        );
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 50,
          child: Text(
            label,
            style: GoogleFonts.inter(
              color: kTextSecondary,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.inter(color: kTextPrimary, fontSize: 13),
          ),
        ),
      ],
    );
  }

  String _formatDuration(int durationMs) {
    final duration = Duration(milliseconds: durationMs);
    final hours = duration.inHours;
    final minutes = (duration.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    if (hours > 0) {
      return '$hours:$minutes:$seconds';
    }
    return '${duration.inMinutes}:$seconds';
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const kb = 1024;
    const mb = kb * 1024;
    const gb = mb * 1024;
    if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(2)} GB';
    if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
    if (bytes >= kb) return '${(bytes / kb).toStringAsFixed(1)} KB';
    return '$bytes B';
  }

  Future<void> _startTranscription(
    String videoPath, {
    String language = '',
    String? projectName,
  }) async {
    final user = ref.read(currentUserProvider);
    if (user == null) return;

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
      final consumed = await ref
          .read(quotaProvider.notifier)
          .consumeRun(user.uid);
      if (!consumed) {
        pipeline.cancel();
        if (!processingClosed && mounted) {
          Navigator.of(context).pop();
        }
        if (mounted) {
          SnackBarHelper.showError(context, 'No free runs remaining.');
        }
        return;
      }

      final result = await pipeline.run(
        videoPath: videoPath,
        language: language,
        uid: user.uid,
        projectName: projectName,
      );

      if (result != null && mounted) {
        if (!processingClosed && Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }

        // Save project locally and to Firestore
        await ProjectLocalStorage.saveProject(result);
        try {
          await FirebaseService.saveProject(
            user.uid,
            result.id,
            result.toFirestore(),
          );
        } catch (e) {
          // Firestore save failed — local copy exists as fallback
        }

        // Reload projects
        await _loadData();

        // Navigate to editor
        _openEditor(result);
      } else if (!processingClosed &&
          mounted &&
          Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        if (!processingClosed && Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
        SnackBarHelper.showError(
          context,
          e.toString().replaceFirst('Exception: ', ''),
        );
      }
    } finally {
      pipeline.dispose();
    }
  }

  void _openEditor(Project project) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => EditorScreen(project: project)),
    );
  }

  Future<void> _deleteProject(Project project) async {
    final user = ref.read(currentUserProvider);
    await ProjectLocalStorage.deleteProject(project.id);
    if (user != null) {
      try {
        await FirebaseService.deleteProject(user.uid, project.id);
      } catch (e) {
        // Ignore Firestore delete failures
      }
    }
    await _loadData();
    if (mounted) {
      SnackBarHelper.showInfo(context, 'Project deleted');
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(currentUserProvider);
    final quota = ref.watch(quotaProvider);

    return Scaffold(
      backgroundColor: kBackground,
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(user),
            if (_showDeviceQuotaNotice) _buildDeviceQuotaNotice(quota),
            if (_loadWarning != null) _buildLoadWarning(),
            Expanded(
              child: _isLoadingProjects
                  ? _buildLoadingState()
                  : _projects.isEmpty
                  ? _buildEmptyState()
                  : _buildProjectGrid(),
            ),
          ],
        ),
      ),
      floatingActionButton: _projects.isNotEmpty
          ? FloatingActionButton.extended(
              onPressed: quota.canRun
                  ? _importVideo
                  : () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const QuotaExhaustedScreen(),
                        ),
                      );
                    },
              backgroundColor: quota.canRun ? kAccent : kWarning,
              icon: Icon(
                quota.canRun ? Icons.add_rounded : Icons.rocket_launch_rounded,
                color: Colors.white,
              ),
              label: Text(
                quota.canRun ? 'Import Video' : 'Upgrade',
                style: GoogleFonts.inter(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            )
          : null,
    );
  }

  Widget _buildTopBar(dynamic user) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [kAccent, kAccentSecondary],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.subtitles_rounded,
              color: Colors.white,
              size: 20,
            ),
          ),
          const Spacer(),
          InkWell(
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ProfileScreen()),
              );
            },
            borderRadius: BorderRadius.circular(24),
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: CircleAvatar(
                radius: 18,
                backgroundColor: kSurfaceElevated,
                child: Text(
                  (user?.displayName?.isNotEmpty == true)
                      ? user!.displayName![0].toUpperCase()
                      : '?',
                  style: GoogleFonts.inter(
                    color: kTextPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceQuotaNotice(QuotaState quota) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: kWarning.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: kWarning.withValues(alpha: 0.25)),
        ),
        child: Text(
          'This device has used ${quota.runsUsed} of ${quota.maxRuns} free transcriptions. Free runs are device-limited.',
          style: GoogleFonts.inter(color: kWarning, fontSize: 12, height: 1.4),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    final quota = ref.watch(quotaProvider);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                color: kSurfaceElevated,
                borderRadius: BorderRadius.circular(24),
              ),
              child: const Icon(
                Icons.video_library_rounded,
                size: 48,
                color: kTextSecondary,
              ),
            ),
            const SizedBox(height: 24),
            Text('No projects yet', style: AppTextStyles.heading3),
            const SizedBox(height: 8),
            Text(
              'Import a video to get started with\nautomatic subtitle generation',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 15,
                color: kTextSecondary,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 32),
            AppButton(
              label: quota.canRun ? 'Import Video' : 'Upgrade',
              icon: quota.canRun
                  ? Icons.file_upload_rounded
                  : Icons.rocket_launch_rounded,
              onPressed: quota.canRun
                  ? _importVideo
                  : () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const QuotaExhaustedScreen(),
                        ),
                      );
                    },
              width: 200,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProjectGrid() {
    return RefreshIndicator(
      onRefresh: _loadData,
      color: kAccent,
      backgroundColor: kSurface,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: GridView.builder(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: 16,
            crossAxisSpacing: 16,
            childAspectRatio: 0.75,
          ),
          itemCount: _projects.length,
          itemBuilder: (context, index) {
            return _buildProjectCard(_projects[index]);
          },
        ),
      ),
    );
  }

  Widget _buildLoadingState() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: GridView.builder(
        itemCount: 4,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 16,
          crossAxisSpacing: 16,
          childAspectRatio: 0.75,
        ),
        itemBuilder: (context, index) {
          return Shimmer.fromColors(
            baseColor: kSurface,
            highlightColor: kSurfaceElevated,
            child: Container(
              decoration: BoxDecoration(
                color: kSurface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: kBorder),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildLoadWarning() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 2),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: kWarning.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: kWarning.withValues(alpha: 0.25)),
        ),
        child: Row(
          children: [
            const Icon(Icons.sync_problem_rounded, color: kWarning, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _loadWarning!,
                style: GoogleFonts.inter(color: kWarning, fontSize: 12),
              ),
            ),
            TextButton(
              onPressed: _loadData,
              child: Text(
                'Retry',
                style: GoogleFonts.inter(
                  color: kWarning,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProjectCard(Project project) {
    final isVideoMissing = !project.isVideoAvailable;

    return GestureDetector(
      onTap: isVideoMissing ? null : () => _openEditor(project),
      onLongPress: () {
        showModalBottomSheet(
          context: context,
          backgroundColor: kSurface,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          ),
          builder: (ctx) => Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.delete_rounded, color: kError),
                  title: Text(
                    'Delete Project',
                    style: GoogleFonts.inter(color: kTextPrimary),
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    _deleteProject(project);
                  },
                ),
              ],
            ),
          ),
        );
      },
      child: Container(
        decoration: BoxDecoration(
          color: kSurface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: kBorder),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Thumbnail
                Expanded(
                  child: Container(
                    width: double.infinity,
                    color: kSurfaceElevated,
                    child: project.thumbnailBase64 != null
                        ? Image.memory(
                            base64Decode(project.thumbnailBase64!),
                            fit: BoxFit.cover,
                          )
                        : const Center(
                            child: Icon(
                              Icons.videocam_rounded,
                              color: kTextSecondary,
                              size: 32,
                            ),
                          ),
                  ),
                ),
                // Info
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        project.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.inter(
                          color: kTextPrimary,
                          fontWeight: FontWeight.w500,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${project.subtitles.length} subtitles',
                        style: AppTextStyles.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            // Video missing overlay
            if (isVideoMissing)
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    color: kBackground.withValues(alpha: 0.8),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.error_outline_rounded,
                          color: kWarning,
                          size: 28,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Video missing',
                          style: GoogleFonts.inter(
                            color: kWarning,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
