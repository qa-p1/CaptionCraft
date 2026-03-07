import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shimmer/shimmer.dart';
import 'package:path/path.dart' as path;
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/text_styles.dart';
import '../../../core/utils/device_quota_service.dart';
import '../../../core/utils/firebase_service.dart';
import '../../../core/utils/project_creation_service.dart';
import '../../../shared/widgets/app_button.dart';
import '../../../shared/widgets/snack_bar_helper.dart';
import '../../../shared/models/project_model.dart';
import '../../auth/providers/auth_provider.dart';
import '../../quota/providers/quota_provider.dart';
import '../../editor/screens/editor_screen.dart';
import '../../profile/screens/profile_screen.dart';

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
  int _loadRequestId = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_loadData());
  }

  Future<void> _loadData() async {
    final requestId = ++_loadRequestId;
    final shouldShowBlockingLoader = _projects.isEmpty;

    if (mounted && shouldShowBlockingLoader) {
      setState(() {
        _isLoadingProjects = true;
        _loadWarning = null;
      });
    }

    final user = ref.read(currentUserProvider);
    unawaited(_refreshQuotaAndDeviceNotice(user, requestId));

    final localProjects = await _loadLocalProjects(requestId);
    if (user == null) return;

    unawaited(_syncCloudProjects(user.uid, localProjects, requestId));
  }

  Future<List<Project>> _loadLocalProjects(int requestId) async {
    try {
      final localProjects = await ProjectLocalStorage.loadProjects();
      await _cacheVideoAvailability(localProjects);

      if (!mounted || requestId != _loadRequestId) {
        return localProjects;
      }

      setState(() {
        _projects = localProjects;
        _isLoadingProjects = false;
        _loadWarning = null;
      });

      return localProjects;
    } catch (_) {
      if (mounted && requestId == _loadRequestId) {
        setState(() {
          _projects = [];
          _isLoadingProjects = false;
          _loadWarning = 'Load failed. Please try again.';
        });
      }
      return [];
    }
  }

  Future<void> _syncCloudProjects(
    String uid,
    List<Project> localProjects,
    int requestId,
  ) async {
    try {
      final firestoreData = await FirebaseService.loadProjects(
        uid,
      ).timeout(const Duration(seconds: 4));
      final cloudProjects = firestoreData
          .map((data) => Project.fromFirestore(data))
          .toList();
      await _cacheVideoAvailability(cloudProjects);

      if (!mounted || requestId != _loadRequestId) return;

      setState(() {
        _projects = _mergeProjects(localProjects, cloudProjects);
        _loadWarning = null;
      });
    } catch (_) {
      if (!mounted || requestId != _loadRequestId || localProjects.isNotEmpty) {
        return;
      }

      setState(() {
        _loadWarning = 'Cloud sync is unavailable right now.';
      });
    }
  }

  Future<void> _refreshQuotaAndDeviceNotice(dynamic user, int requestId) async {
    try {
      await ref.read(quotaProvider.notifier).loadQuota();
    } catch (_) {
      // Ignore quota refresh failures and keep the latest known state.
    }

    var showDeviceNotice = false;
    if (user != null) {
      try {
        final boundUid = await DeviceQuotaService.getBoundUid();
        showDeviceNotice = boundUid != null && boundUid != user.uid;
      } catch (_) {
        showDeviceNotice = false;
      }
    }

    if (mounted && requestId == _loadRequestId) {
      setState(() {
        _showDeviceQuotaNotice = showDeviceNotice;
      });
    }
  }

  Future<void> _cacheVideoAvailability(List<Project> projects) async {
    final availability = await Future.wait(
      projects.map((project) => File(project.videoPath).exists()),
    );

    for (var index = 0; index < projects.length; index++) {
      projects[index].cacheVideoAvailability(availability[index]);
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

  Future<void> _importVideos() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.video,
        allowMultiple: true,
      );

      if (result == null || result.files.isEmpty) return;

      final sources = result.files
          .where((file) => file.path != null)
          .map(
            (file) => ImportedVideoSource(
              filePath: file.path!,
              displayName: file.name,
            ),
          )
          .toList();
      if (sources.isEmpty) return;

      if (mounted) {
        _showImportSheet(sources: sources);
      }
    } catch (e) {
      if (mounted) {
        SnackBarHelper.showError(context, 'Failed to pick video: $e');
      }
    }
  }

  void _showImportSheet({required List<ImportedVideoSource> sources}) {
    final baseName = path.basenameWithoutExtension(sources.first.displayName);
    final defaultProjectName = sources.length == 1
        ? baseName
        : '$baseName montage';
    final projectNameController = TextEditingController(
      text: defaultProjectName,
    );

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
                'Create Project',
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
              _infoRow('Clips', '${sources.length} selected'),
              const SizedBox(height: 8),
              _infoRow('First', sources.first.displayName),
              const SizedBox(height: 16),
              Text(
                'Imported Videos',
                style: GoogleFonts.inter(
                  color: kTextSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 180),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: kSurfaceElevated,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: kBorder),
                ),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: sources.length,
                  separatorBuilder: (_, _) => const Divider(color: kBorder),
                  itemBuilder: (_, index) {
                    final source = sources[index];
                    return Text(
                      source.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        color: kTextPrimary,
                        fontSize: 13,
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Subtitle generation happens inside the editor per selected clip.',
                style: GoogleFonts.inter(
                  color: kTextSecondary,
                  fontSize: 12,
                  height: 1.4,
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
                      label: 'Open Editor',
                      icon: Icons.video_settings_rounded,
                      onPressed: () {
                        final name = projectNameController.text.trim();
                        Navigator.pop(sheetContext);
                        _createEditorProject(
                          sources,
                          projectName: name.isNotEmpty
                              ? name
                              : defaultProjectName,
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

  Future<void> _createEditorProject(
    List<ImportedVideoSource> sources, {
    String? projectName,
  }) async {
    final user = ref.read(currentUserProvider);

    try {
      final result = await ProjectCreationService.createProjectFromVideos(
        sources: sources,
        projectName: projectName,
      );

      await ProjectLocalStorage.saveProject(result);
      if (user != null) {
        try {
          await FirebaseService.saveProject(
            user.uid,
            result.id,
            result.toFirestore(),
          );
        } catch (_) {
          // Local save already succeeded.
        }
      }

      if (!mounted) return;
      await _loadData();
      _openEditor(result);
    } catch (e) {
      if (mounted) {
        SnackBarHelper.showError(context, 'Project creation failed: $e');
      }
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
              onPressed: _importVideos,
              backgroundColor: kAccent,
              icon: const Icon(Icons.add_rounded, color: Colors.white),
              label: Text(
                'Import Videos',
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
          'This device has used ${quota.runsUsed} of ${quota.maxRuns} free subtitle generations. Limits apply when generating subtitles from clips.',
          style: GoogleFonts.inter(color: kWarning, fontSize: 12, height: 1.4),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
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
              'Import one or more videos to start editing.\nGenerate subtitles later for selected clips.',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 15,
                color: kTextSecondary,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 32),
            AppButton(
              label: 'Import Videos',
              icon: Icons.file_upload_rounded,
              onPressed: _importVideos,
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
              onPressed: () {
                unawaited(_loadData());
              },
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
    final thumbnailBytes = project.thumbnailBytes;

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
                    child: thumbnailBytes != null
                        ? Image.memory(
                            thumbnailBytes,
                            fit: BoxFit.cover,
                            filterQuality: FilterQuality.low,
                            gaplessPlayback: true,
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
                        '${project.timeline.videoClips.length} clips • ${project.subtitles.length} subtitles',
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
