import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as path;
import 'package:shimmer/shimmer.dart';
import 'package:uuid/uuid.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/theme/text_styles.dart';
import '../../../core/utils/device_quota_service.dart';
import '../../../core/utils/ffmpeg_service.dart';
import '../../../core/utils/firebase_service.dart';
import '../../../core/utils/project_creation_service.dart';
import '../../../shared/models/project_model.dart';
import '../../../shared/widgets/app_button.dart';
import '../../../shared/widgets/snack_bar_helper.dart';
import '../../auth/providers/auth_provider.dart';
import '../../editor/models/timeline_models.dart';
import '../../editor/screens/editor_screen.dart';
import '../../profile/screens/profile_screen.dart';
import '../../quota/providers/quota_provider.dart';

enum _ProjectSort { recent, name, duration }

enum _ProjectView { grid, list }

enum _ProjectAction { favorite, rename, duplicate, relink, openExport, delete }

class HomeScreen extends ConsumerStatefulWidget {
  final List<Project>? initialProjects;

  const HomeScreen({super.key, this.initialProjects});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final TextEditingController _searchController = TextEditingController();

  List<Project> _projects = [];
  bool _isLoadingProjects = true;
  bool _isCreatingProject = false;
  bool _isOpeningEditor = false;
  bool _showDeviceQuotaNotice = false;
  String? _loadWarning;
  String _query = '';
  _ProjectSort _sort = _ProjectSort.recent;
  _ProjectView _view = _ProjectView.grid;
  int _loadRequestId = 0;

  @override
  void initState() {
    super.initState();
    final initialProjects = widget.initialProjects;
    if (initialProjects != null) {
      _projects = [...initialProjects];
      _isLoadingProjects = false;
    } else {
      unawaited(_loadData());
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<Project> get _visibleProjects {
    final normalizedQuery = _query.trim().toLowerCase();
    final projects = _projects.where((project) {
      if (normalizedQuery.isEmpty) return true;
      return project.name.toLowerCase().contains(normalizedQuery);
    }).toList();

    projects.sort((a, b) {
      if (a.isFavorite != b.isFavorite) {
        return a.isFavorite ? -1 : 1;
      }
      return switch (_sort) {
        _ProjectSort.recent => b.lastModifiedAt.compareTo(a.lastModifiedAt),
        _ProjectSort.name => a.name.toLowerCase().compareTo(
          b.name.toLowerCase(),
        ),
        _ProjectSort.duration => b.durationMs.compareTo(a.durationMs),
      };
    });
    return projects;
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

      if (!mounted || requestId != _loadRequestId) return localProjects;
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
          _loadWarning = 'Your local project library could not be loaded.';
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
      final pendingDeletionIds =
          await ProjectLocalStorage.loadDeletedProjectIds(uid);
      final cloudProjects = firestoreData
          .map((data) => Project.fromFirestore(data))
          .where((project) => !pendingDeletionIds.contains(project.id))
          .toList();
      await _cacheVideoAvailability(cloudProjects);

      for (final projectId in pendingDeletionIds) {
        try {
          await FirebaseService.deleteProject(
            uid,
            projectId,
          ).timeout(const Duration(seconds: 8));
          await ProjectLocalStorage.clearProjectDeletion(projectId);
        } catch (_) {
          // Keep the tombstone so an offline delete cannot be resurrected.
        }
      }

      if (!mounted || requestId != _loadRequestId) return;
      final mergedProjects = _mergeProjects(localProjects, cloudProjects);
      setState(() {
        _projects = mergedProjects;
        _loadWarning = null;
      });
      unawaited(
        _reconcileProjectCopies(
          uid: uid,
          localProjects: localProjects,
          cloudProjects: cloudProjects,
          mergedProjects: mergedProjects,
        ),
      );
    } catch (_) {
      if (!mounted || requestId != _loadRequestId || localProjects.isNotEmpty) {
        return;
      }
      setState(() {
        _loadWarning = 'Cloud sync is offline. Local editing still works.';
      });
    }
  }

  Future<void> _refreshQuotaAndDeviceNotice(dynamic user, int requestId) async {
    try {
      await ref.read(quotaProvider.notifier).loadQuota();
    } catch (_) {
      // Keep the most recent quota state while offline.
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
      setState(() => _showDeviceQuotaNotice = showDeviceNotice);
    }
  }

  Future<void> _cacheVideoAvailability(List<Project> projects) async {
    final availability = await Future.wait(
      projects.map((project) async {
        for (final mediaPath in project.mediaPaths) {
          if (await File(mediaPath).exists()) return true;
        }
        return false;
      }),
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
      merged[project.id] = existing == null
          ? project
          : Project.mergePersistedCopies(local: existing, remote: project);
    }
    return merged.values.toList()
      ..sort((a, b) => b.lastModifiedAt.compareTo(a.lastModifiedAt));
  }

  Future<void> _reconcileProjectCopies({
    required String uid,
    required List<Project> localProjects,
    required List<Project> cloudProjects,
    required List<Project> mergedProjects,
  }) async {
    final localById = {
      for (final project in localProjects) project.id: project,
    };
    final cloudById = {
      for (final project in cloudProjects) project.id: project,
    };

    for (final project in mergedProjects) {
      final local = localById[project.id];
      if (local == null ||
          project.lastModifiedAt.isAfter(local.lastModifiedAt) ||
          project.captionsModifiedAt.isAfter(local.captionsModifiedAt)) {
        try {
          await ProjectLocalStorage.saveProject(project);
        } catch (_) {
          // The in-memory cloud copy remains usable for this session.
        }
      }

      final cloud = cloudById[project.id];
      if (cloud == null ||
          project.lastModifiedAt.isAfter(cloud.lastModifiedAt) ||
          project.captionsModifiedAt.isAfter(cloud.captionsModifiedAt)) {
        try {
          await FirebaseService.saveProject(
            uid,
            project.id,
            project.toFirestore(),
          ).timeout(const Duration(seconds: 8));
        } catch (_) {
          // Offline-created edits will retry during the next library refresh.
        }
      }
    }
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
      if (sources.isNotEmpty && mounted) {
        _showImportSheet(sources: sources);
      }
    } catch (error) {
      if (mounted) {
        SnackBarHelper.showError(context, 'Could not import video: $error');
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

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) {
        return FractionallySizedBox(
          heightFactor: 0.82,
          child: Container(
            decoration: const BoxDecoration(
              color: kSurface,
              borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
              border: Border(top: BorderSide(color: kBorder)),
            ),
            child: Column(
              children: [
                const _SheetHandle(),
                Expanded(
                  child: SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(
                      24,
                      8,
                      24,
                      MediaQuery.viewInsetsOf(sheetContext).bottom + 24,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: kAccent.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: kAccent.withValues(alpha: 0.35),
                                ),
                              ),
                              child: const Icon(
                                Icons.movie_creation_outlined,
                                color: kAccent,
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Start a new cut',
                                    style: TextStyle(
                                      color: kTextPrimary,
                                      fontSize: 21,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: -0.5,
                                    ),
                                  ),
                                  Text(
                                    '${sources.length} source ${sources.length == 1 ? 'clip' : 'clips'} ready',
                                    style: AppTextStyles.bodySmall,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 24),
                        Text('PROJECT NAME', style: AppTextStyles.label),
                        const SizedBox(height: 8),
                        TextField(
                          controller: projectNameController,
                          autofocus: true,
                          textInputAction: TextInputAction.done,
                          decoration: const InputDecoration(
                            hintText: 'Give this edit a name',
                            prefixIcon: Icon(Icons.edit_outlined, size: 19),
                          ),
                        ),
                        const SizedBox(height: 22),
                        Row(
                          children: [
                            Text('IMPORT ORDER', style: AppTextStyles.label),
                            const Spacer(),
                            Text(
                              'Clips are placed back-to-back',
                              style: AppTextStyles.bodySmall,
                            ),
                          ],
                        ),
                        const SizedBox(height: 9),
                        Container(
                          constraints: const BoxConstraints(maxHeight: 235),
                          decoration: BoxDecoration(
                            color: kSurfaceElevated,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: kBorder),
                          ),
                          child: ListView.separated(
                            shrinkWrap: true,
                            padding: const EdgeInsets.symmetric(vertical: 7),
                            itemCount: sources.length,
                            separatorBuilder: (_, _) =>
                                const Divider(height: 1, indent: 54),
                            itemBuilder: (_, index) {
                              final source = sources[index];
                              return ListTile(
                                dense: true,
                                leading: Container(
                                  width: 30,
                                  height: 30,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: kSurfaceHigh,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    '${index + 1}'.padLeft(2, '0'),
                                    style: TextStyle(
                                      fontFamily: 'monospace',
                                      color: kAccentSecondary,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                title: Text(
                                  source.displayName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: kTextPrimary,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                        const SizedBox(height: 16),
                        const _InfoCallout(
                          icon: Icons.closed_caption_outlined,
                          text:
                              'Subtitle generation stays optional and can be run per clip inside the editor.',
                        ),
                        const SizedBox(height: 24),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () => Navigator.pop(sheetContext),
                                child: const Text('Cancel'),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              flex: 2,
                              child: FilledButton.icon(
                                onPressed: () {
                                  final name = projectNameController.text
                                      .trim();
                                  Navigator.pop(sheetContext);
                                  unawaited(
                                    _createEditorProject(
                                      sources,
                                      projectName: name.isEmpty
                                          ? defaultProjectName
                                          : name,
                                    ),
                                  );
                                },
                                icon: const Icon(
                                  Icons.arrow_forward_rounded,
                                  size: 19,
                                ),
                                label: const Text('Build timeline'),
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
          ),
        );
      },
    ).whenComplete(projectNameController.dispose);
  }

  Future<void> _createEditorProject(
    List<ImportedVideoSource> sources, {
    String? projectName,
  }) async {
    if (_isCreatingProject) return;
    setState(() => _isCreatingProject = true);
    final user = ref.read(currentUserProvider);
    try {
      SnackBarHelper.showInfo(context, 'Building your local timeline…');
      final result = await ProjectCreationService.createProjectFromVideos(
        sources: sources,
        projectName: projectName,
        generateThumbnail: false,
      );
      await ProjectLocalStorage.saveProject(result);
      if (user != null) {
        unawaited(_syncProjectToCloud(user.uid, result));
      }
      if (!mounted) return;
      result.cacheVideoAvailability(true);
      setState(() => _projects = [result, ..._projects]);
      await _openEditor(result);
    } catch (error) {
      if (mounted) {
        SnackBarHelper.showError(context, 'Project creation failed: $error');
      }
    } finally {
      if (mounted) {
        setState(() => _isCreatingProject = false);
      }
    }
  }

  Future<void> _syncProjectToCloud(String uid, Project project) async {
    try {
      await FirebaseService.saveProject(
        uid,
        project.id,
        project.toFirestore(),
      ).timeout(const Duration(seconds: 8));
    } catch (_) {
      // The local project remains authoritative and library refresh retries.
    }
  }

  Future<void> _openEditor(Project project) async {
    if (_isOpeningEditor) return;
    _isOpeningEditor = true;
    try {
      var projectToOpen = project;
      if (!project.isVideoAvailable) {
        final relinked = await _pickAndRelinkProject(project);
        if (relinked == null || !mounted) {
          if (mounted) {
            SnackBarHelper.showInfo(
              context,
              'Relink the source video to open this project.',
            );
          }
          return;
        }
        projectToOpen = relinked;
      }
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => EditorScreen(project: projectToOpen)),
      );
      if (mounted) await _loadData();
    } catch (error) {
      if (mounted) {
        SnackBarHelper.showError(context, 'Could not open editor: $error');
      }
    } finally {
      _isOpeningEditor = false;
    }
  }

  Future<void> _persistProject(Project project) async {
    await ProjectLocalStorage.saveProject(project);
    final user = ref.read(currentUserProvider);
    if (user != null) {
      try {
        await FirebaseService.saveProject(
          user.uid,
          project.id,
          project.toFirestore(),
        );
      } catch (_) {
        // Local changes remain available and will win on the next sync.
      }
    }
    if (!mounted) return;
    setState(() {
      final index = _projects.indexWhere((item) => item.id == project.id);
      if (index == -1) {
        _projects = [project, ..._projects];
      } else {
        final updated = [..._projects];
        updated[index] = project;
        _projects = updated;
      }
    });
  }

  Future<void> _toggleFavorite(Project project) async {
    final updated = project.copyWith(
      isFavorite: !project.isFavorite,
      lastModifiedAt: DateTime.now(),
    );
    await _persistProject(updated);
  }

  Future<void> _renameProject(Project project) async {
    final controller = TextEditingController(text: project.name);
    final nextName = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rename project'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(hintText: 'Project name'),
          onSubmitted: (value) {
            if (value.trim().isNotEmpty) {
              Navigator.pop(dialogContext, value.trim());
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final value = controller.text.trim();
              if (value.isNotEmpty) Navigator.pop(dialogContext, value);
            },
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (nextName == null || nextName == project.name) return;
    await _persistProject(
      project.copyWith(name: nextName, lastModifiedAt: DateTime.now()),
    );
  }

  Future<void> _duplicateProject(Project project) async {
    final now = DateTime.now();
    final duplicate = Project(
      id: const Uuid().v4(),
      name: '${project.name} copy',
      videoPath: project.videoPath,
      thumbnailBase64: project.thumbnailBase64,
      durationMs: project.durationMs,
      subtitles: project.subtitles,
      timeline: EditorTimeline.fromJson(project.timeline.toJson()),
      globalStyle: project.globalStyle,
      isFavorite: false,
      lastExportPath: project.lastExportPath,
      createdAt: now,
      lastModifiedAt: now,
    );
    duplicate.cacheVideoAvailability(project.isVideoAvailable);
    await _persistProject(duplicate);
    if (mounted) {
      SnackBarHelper.showInfo(context, 'Project duplicated');
    }
  }

  Future<void> _relinkProject(Project project) async {
    await _pickAndRelinkProject(project);
  }

  Future<Project?> _pickAndRelinkProject(Project project) async {
    final picked = await FilePicker.platform.pickFiles(type: FileType.video);
    final nextPath = picked?.files.single.path;
    if (nextPath == null) return null;

    try {
      final info = await FFmpegService.getMediaInfo(nextPath);
      final oldPath = project.videoPath;
      var replacedAsset = false;
      final assets = project.timeline.assets.map((asset) {
        final isTarget =
            asset.sourcePath == oldPath ||
            (!replacedAsset && asset.type == EditorAssetType.video);
        if (!isTarget) return asset;
        replacedAsset = true;
        return asset.copyWith(
          label: path.basename(nextPath),
          sourcePath: nextPath,
          clearRemoteUrl: true,
          isNetworkBacked: false,
          metadata: {
            ...asset.metadata,
            'durationMs': info['durationMs'],
            'width': info['width'],
            'height': info['height'],
            'hasAudio': info['hasAudio'],
            'frameRate': info['frameRate'],
          },
        );
      }).toList();

      final updated = project.copyWith(
        videoPath: nextPath,
        timeline: project.timeline.copyWith(assets: assets),
        lastModifiedAt: DateTime.now(),
      );
      updated.cacheVideoAvailability(true);
      await _persistProject(updated);
      if (mounted) {
        SnackBarHelper.showInfo(context, 'Media relinked successfully');
      }
      return updated;
    } catch (error) {
      if (mounted) {
        SnackBarHelper.showError(context, 'Could not relink media: $error');
      }
      return null;
    }
  }

  Future<void> _openLastExport(Project project) async {
    final exportPath = project.lastExportPath;
    if (exportPath == null || !await File(exportPath).exists()) {
      if (mounted) {
        SnackBarHelper.showError(context, 'The last export is no longer here.');
      }
      return;
    }
    final result = await OpenFilex.open(exportPath);
    if (result.type != ResultType.done && mounted) {
      SnackBarHelper.showError(context, result.message);
    }
  }

  Future<void> _confirmDelete(Project project) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete project?'),
        content: Text(
          '“${project.name}” will be removed from this device and your synced project library. Source videos and exported files are not deleted.',
          style: const TextStyle(color: kTextSecondary, height: 1.45),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep project'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: kError),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final user = ref.read(currentUserProvider);
    await ProjectLocalStorage.deleteProject(project.id, ownerUid: user?.uid);
    if (user != null) {
      try {
        await FirebaseService.deleteProject(user.uid, project.id);
        await ProjectLocalStorage.clearProjectDeletion(project.id);
      } catch (_) {
        // A local tombstone will retry the remote delete on the next sync.
      }
    }
    if (!mounted) return;
    setState(
      () => _projects = _projects
          .where((candidate) => candidate.id != project.id)
          .toList(),
    );
    SnackBarHelper.showInfo(context, 'Project deleted');
  }

  void _handleProjectAction(Project project, _ProjectAction action) {
    switch (action) {
      case _ProjectAction.favorite:
        unawaited(_toggleFavorite(project));
      case _ProjectAction.rename:
        unawaited(_renameProject(project));
      case _ProjectAction.duplicate:
        unawaited(_duplicateProject(project));
      case _ProjectAction.relink:
        unawaited(_relinkProject(project));
      case _ProjectAction.openExport:
        unawaited(_openLastExport(project));
      case _ProjectAction.delete:
        unawaited(_confirmDelete(project));
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(currentUserProvider);
    final quota = ref.watch(quotaProvider);

    return Scaffold(
      backgroundColor: kBackground,
      body: SafeArea(
        bottom: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final horizontalPadding = constraints.maxWidth >= 900 ? 34.0 : 18.0;
            final projects = _visibleProjects;
            return RefreshIndicator(
              onRefresh: _loadData,
              color: kAccent,
              backgroundColor: kSurfaceHigh,
              edgeOffset: 76,
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(
                  parent: BouncingScrollPhysics(),
                ),
                slivers: [
                  SliverToBoxAdapter(
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1320),
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(
                            horizontalPadding,
                            16,
                            horizontalPadding,
                            0,
                          ),
                          child: Column(
                            children: [
                              _buildTopBar(user),
                              const SizedBox(height: 20),
                              _buildStudioHero(constraints.maxWidth),
                              if (_showDeviceQuotaNotice) ...[
                                const SizedBox(height: 12),
                                _buildDeviceQuotaNotice(quota),
                              ],
                              if (_loadWarning != null) ...[
                                const SizedBox(height: 12),
                                _buildLoadWarning(),
                              ],
                              const SizedBox(height: 24),
                              _buildLibraryHeader(),
                              const SizedBox(height: 13),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (_isLoadingProjects)
                    _buildLoadingSliver(constraints.maxWidth, horizontalPadding)
                  else if (_projects.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: _buildEmptyState(),
                    )
                  else if (projects.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: _buildNoResults(),
                    )
                  else
                    _buildProjectsSliver(
                      projects,
                      constraints.maxWidth,
                      horizontalPadding,
                    ),
                  const SliverToBoxAdapter(child: SizedBox(height: 110)),
                ],
              ),
            );
          },
        ),
      ),
      floatingActionButton: _projects.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: _importVideos,
              backgroundColor: kAccent,
              foregroundColor: kOnAccent,
              elevation: 4,
              icon: const Icon(Icons.add_rounded),
              label: const Text(
                'New edit',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
    );
  }

  Widget _buildTopBar(dynamic user) {
    final displayName = (user?.displayName as String?)?.trim();
    return Row(
      children: [
        const _BrandLockup(),
        const Spacer(),
        if (MediaQuery.sizeOf(context).width >= 650)
          Padding(
            padding: const EdgeInsets.only(right: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  displayName?.isNotEmpty == true ? displayName! : 'Creator',
                  style: TextStyle(
                    color: kTextPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
                Text('LOCAL STUDIO', style: AppTextStyles.label),
              ],
            ),
          ),
        Tooltip(
          message: 'Profile and account',
          child: InkWell(
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ProfileScreen()),
            ),
            customBorder: const CircleBorder(),
            child: Container(
              width: 42,
              height: 42,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: kSurfaceHigh,
                shape: BoxShape.circle,
                border: Border.all(color: kBorder),
              ),
              child: Text(
                displayName?.isNotEmpty == true
                    ? displayName![0].toUpperCase()
                    : 'C',
                style: TextStyle(
                  color: kAccentSecondary,
                  fontWeight: FontWeight.w800,
                  fontSize: 15,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStudioHero(double width) {
    final compact = width < 620;
    final totalCaptions = _projects.fold<int>(
      0,
      (count, project) => count + project.subtitles.length,
    );
    final totalMs = _projects.fold<int>(
      0,
      (duration, project) => duration + project.durationMs,
    );
    final missing = _projects
        .where((project) => !project.isVideoAvailable)
        .length;

    return Container(
      width: double.infinity,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: kBorder),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.24),
            blurRadius: 34,
            offset: const Offset(0, 16),
          ),
        ],
      ),
      child: Stack(
        children: [
          const Positioned.fill(
            child: CustomPaint(painter: _StudioGridPainter()),
          ),
          Positioned(
            top: 0,
            bottom: 0,
            left: 0,
            child: Container(width: 5, color: kAccent),
          ),
          Padding(
            padding: EdgeInsets.all(compact ? 22 : 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: kAccentSecondary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: kAccentSecondary.withValues(alpha: 0.28),
                    ),
                  ),
                  child: Text(
                    'READY TO CUT',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      color: kAccentSecondary,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.1,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: compact ? 330 : 520),
                  child: Text(
                    compact
                        ? 'Make the cut.\nOwn the frame.'
                        : 'Make the cut. Own the frame.',
                    style: TextStyle(
                      color: kTextPrimary,
                      fontSize: compact ? 31 : 42,
                      height: 1.02,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -1.8,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 490),
                  child: Text(
                    'A focused timeline for fast edits, precise captions, layered sound, and exports that are ready to publish.',
                    style: TextStyle(
                      color: kTextSecondary,
                      fontSize: compact ? 13 : 14,
                      height: 1.55,
                    ),
                  ),
                ),
                const SizedBox(height: 22),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    FilledButton.icon(
                      onPressed: _importVideos,
                      icon: const Icon(Icons.add_rounded, size: 19),
                      label: const Text('Start new edit'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _projects.isEmpty
                          ? null
                          : () => _openEditor(_visibleProjects.first),
                      icon: const Icon(Icons.play_arrow_rounded, size: 19),
                      label: const Text('Resume latest'),
                    ),
                  ],
                ),
                const SizedBox(height: 27),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _MetricPill(
                      value: '${_projects.length}',
                      label: 'projects',
                    ),
                    _MetricPill(
                      value: _formatCompactDuration(totalMs),
                      label: 'footage',
                    ),
                    _MetricPill(value: '$totalCaptions', label: 'captions'),
                    if (missing > 0)
                      _MetricPill(
                        value: '$missing',
                        label: 'offline',
                        warning: true,
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLibraryHeader() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Your cuts',
                    style: TextStyle(
                      color: kTextPrimary,
                      fontSize: 21,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.5,
                    ),
                  ),
                  Text(
                    '${_visibleProjects.length} of ${_projects.length} projects',
                    style: AppTextStyles.bodySmall,
                  ),
                ],
              ),
            ),
            if (MediaQuery.sizeOf(context).width >= 560) _buildViewToggle(),
          ],
        ),
        const SizedBox(height: 13),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _searchController,
                onChanged: (value) => setState(() => _query = value),
                decoration: InputDecoration(
                  hintText: 'Search projects',
                  prefixIcon: const Icon(Icons.search_rounded, size: 20),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear search',
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _query = '');
                          },
                          icon: const Icon(Icons.close_rounded, size: 18),
                        ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            PopupMenuButton<_ProjectSort>(
              tooltip: 'Sort projects',
              initialValue: _sort,
              onSelected: (value) => setState(() => _sort = value),
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: _ProjectSort.recent,
                  child: Text('Recently edited'),
                ),
                PopupMenuItem(
                  value: _ProjectSort.name,
                  child: Text('Project name'),
                ),
                PopupMenuItem(
                  value: _ProjectSort.duration,
                  child: Text('Longest first'),
                ),
              ],
              child: Container(
                height: 49,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: kSurfaceElevated,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: kBorder),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.swap_vert_rounded,
                      color: kTextSecondary,
                      size: 20,
                    ),
                    if (MediaQuery.sizeOf(context).width >= 700) ...[
                      const SizedBox(width: 7),
                      Text(
                        switch (_sort) {
                          _ProjectSort.recent => 'Recent',
                          _ProjectSort.name => 'Name',
                          _ProjectSort.duration => 'Duration',
                        },
                        style: const TextStyle(
                          color: kTextPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (MediaQuery.sizeOf(context).width < 560) ...[
              const SizedBox(width: 8),
              _buildViewToggle(),
            ],
          ],
        ),
      ],
    );
  }

  Widget _buildViewToggle() {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: kSurfaceElevated,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ViewButton(
            icon: Icons.grid_view_rounded,
            selected: _view == _ProjectView.grid,
            tooltip: 'Grid view',
            onTap: () => setState(() => _view = _ProjectView.grid),
          ),
          _ViewButton(
            icon: Icons.view_agenda_outlined,
            selected: _view == _ProjectView.list,
            tooltip: 'List view',
            onTap: () => setState(() => _view = _ProjectView.list),
          ),
        ],
      ),
    );
  }

  SliverPadding _buildProjectsSliver(
    List<Project> projects,
    double width,
    double horizontalPadding,
  ) {
    final contentWidth = math.min(1320.0, width) - (horizontalPadding * 2);
    final columns = _view == _ProjectView.list
        ? 1
        : contentWidth >= 1120
        ? 4
        : contentWidth >= 790
        ? 3
        : contentWidth >= 520
        ? 2
        : 1;
    final extent = _view == _ProjectView.list ? 134.0 : 268.0;

    return SliverPadding(
      padding: EdgeInsets.fromLTRB(horizontalPadding, 0, horizontalPadding, 0),
      sliver: SliverLayoutBuilder(
        builder: (context, constraints) {
          final sideInset = math.max(
            0.0,
            (constraints.crossAxisExtent - math.min(1320.0, width)) / 2,
          );
          return SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: sideInset),
            sliver: SliverGrid(
              delegate: SliverChildBuilderDelegate(
                (context, index) => _buildProjectCard(
                  projects[index],
                  isList: _view == _ProjectView.list,
                ),
                childCount: projects.length,
              ),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                mainAxisSpacing: 14,
                crossAxisSpacing: 14,
                mainAxisExtent: extent,
              ),
            ),
          );
        },
      ),
    );
  }

  SliverPadding _buildLoadingSliver(double width, double horizontalPadding) {
    final columns = width >= 1120
        ? 4
        : width >= 790
        ? 3
        : width >= 520
        ? 2
        : 1;
    return SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
      sliver: SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          mainAxisSpacing: 14,
          crossAxisSpacing: 14,
          mainAxisExtent: 268,
        ),
        delegate: SliverChildBuilderDelegate(
          (_, _) => Shimmer.fromColors(
            baseColor: kSurface,
            highlightColor: kSurfaceHigh,
            child: Container(
              decoration: BoxDecoration(
                color: kSurface,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: kBorder),
              ),
            ),
          ),
          childCount: math.max(columns * 2, 4),
        ),
      ),
    );
  }

  Widget _buildProjectCard(Project project, {required bool isList}) {
    final isVideoMissing = !project.isVideoAvailable;
    final thumbnailBytes = project.thumbnailBytes;
    final hasExport = project.lastExportPath != null;

    final thumbnail = Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(
          color: kSurfaceElevated,
          child: thumbnailBytes != null
              ? Image.memory(
                  thumbnailBytes,
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.medium,
                  gaplessPlayback: true,
                )
              : const _ThumbnailPlaceholder(),
        ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.transparent, Color(0xA6000000)],
              stops: [0.48, 1],
            ),
          ),
        ),
        Positioned(
          left: 10,
          bottom: 9,
          child: _TinyBadge(
            icon: Icons.movie_outlined,
            label: _formatDuration(project.durationMs),
          ),
        ),
        if (isVideoMissing)
          Positioned.fill(
            child: ColoredBox(
              color: kBackground.withValues(alpha: 0.84),
              child: Center(
                child: OutlinedButton.icon(
                  onPressed: () => _relinkProject(project),
                  icon: const Icon(
                    Icons.link_off_rounded,
                    color: kWarning,
                    size: 17,
                  ),
                  label: const Text(
                    'Relink media',
                    style: TextStyle(color: kWarning),
                  ),
                ),
              ),
            ),
          ),
      ],
    );

    final information = Padding(
      padding: EdgeInsets.all(isList ? 15 : 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  project.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: kTextPrimary,
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                    letterSpacing: -0.2,
                  ),
                ),
              ),
              if (project.isFavorite)
                const Padding(
                  padding: EdgeInsets.only(left: 5),
                  child: Icon(
                    Icons.star_rounded,
                    color: kAccentSecondary,
                    size: 16,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 7),
          Text(
            '${project.timeline.videoClips.length} clips  ·  ${project.subtitles.length} captions',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.bodySmall,
          ),
          const SizedBox(height: 9),
          Row(
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: isVideoMissing ? kWarning : kSuccess,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  isVideoMissing
                      ? 'Media offline'
                      : 'Edited ${_relativeDate(project.lastModifiedAt)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: isVideoMissing ? kWarning : kTextSecondary,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (hasExport)
                const Icon(
                  Icons.check_circle_outline_rounded,
                  size: 14,
                  color: kSuccess,
                ),
            ],
          ),
        ],
      ),
    );

    return Material(
      color: kSurface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: kBorder),
      ),
      child: InkWell(
        onTap: () => _openEditor(project),
        child: Stack(
          children: [
            if (isList)
              Row(
                children: [
                  SizedBox(width: 188, child: thumbnail),
                  Expanded(child: information),
                ],
              )
            else
              Column(
                children: [
                  Expanded(child: thumbnail),
                  SizedBox(height: 100, child: information),
                ],
              ),
            Positioned(
              top: 8,
              right: 8,
              child: PopupMenuButton<_ProjectAction>(
                tooltip: 'Project actions',
                onSelected: (action) => _handleProjectAction(project, action),
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: _ProjectAction.favorite,
                    child: _MenuLabel(
                      icon: project.isFavorite
                          ? Icons.star_outline_rounded
                          : Icons.star_rounded,
                      label: project.isFavorite
                          ? 'Remove favorite'
                          : 'Add to favorites',
                    ),
                  ),
                  const PopupMenuItem(
                    value: _ProjectAction.rename,
                    child: _MenuLabel(
                      icon: Icons.edit_outlined,
                      label: 'Rename',
                    ),
                  ),
                  const PopupMenuItem(
                    value: _ProjectAction.duplicate,
                    child: _MenuLabel(
                      icon: Icons.copy_rounded,
                      label: 'Duplicate',
                    ),
                  ),
                  if (isVideoMissing)
                    const PopupMenuItem(
                      value: _ProjectAction.relink,
                      child: _MenuLabel(
                        icon: Icons.link_rounded,
                        label: 'Relink media',
                      ),
                    ),
                  if (hasExport)
                    const PopupMenuItem(
                      value: _ProjectAction.openExport,
                      child: _MenuLabel(
                        icon: Icons.play_circle_outline_rounded,
                        label: 'Open last export',
                      ),
                    ),
                  const PopupMenuDivider(),
                  const PopupMenuItem(
                    value: _ProjectAction.delete,
                    child: _MenuLabel(
                      icon: Icons.delete_outline_rounded,
                      label: 'Delete',
                      destructive: true,
                    ),
                  ),
                ],
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: kBackground.withValues(alpha: 0.78),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.09),
                    ),
                  ),
                  child: const Icon(
                    Icons.more_horiz_rounded,
                    color: kTextPrimary,
                    size: 20,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(30, 36, 30, 90),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const _EmptyFilmFrame(),
              const SizedBox(height: 25),
              Text(
                'Your first frame starts here',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: kTextPrimary,
                  fontSize: 24,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.7,
                ),
              ),
              const SizedBox(height: 9),
              Text(
                'Bring in one clip or an entire sequence. CaptionCraft builds an editable multi-track timeline and leaves every creative choice to you.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: kTextSecondary,
                  fontSize: 14,
                  height: 1.55,
                ),
              ),
              const SizedBox(height: 24),
              AppButton(
                label: 'Import your footage',
                icon: Icons.add_rounded,
                onPressed: _importVideos,
                width: 220,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNoResults() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 100),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.search_off_rounded,
              color: kTextSecondary,
              size: 42,
            ),
            const SizedBox(height: 14),
            const Text(
              'No matching cuts',
              style: TextStyle(
                color: kTextPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 5),
            TextButton(
              onPressed: () {
                _searchController.clear();
                setState(() => _query = '');
              },
              child: const Text('Clear search'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDeviceQuotaNotice(QuotaState quota) {
    return _NoticeBanner(
      icon: Icons.speed_rounded,
      color: kWarning,
      message:
          'This device has used ${quota.runsUsed} of ${quota.maxRuns} free subtitle generations. Editing and exporting are unaffected.',
    );
  }

  Widget _buildLoadWarning() {
    return _NoticeBanner(
      icon: Icons.cloud_off_outlined,
      color: kWarning,
      message: _loadWarning!,
      action: TextButton(
        onPressed: () => unawaited(_loadData()),
        child: const Text('Retry'),
      ),
    );
  }

  static String _formatDuration(int durationMs) {
    final totalSeconds = (durationMs / 1000).round();
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:'
          '${minutes.toString().padLeft(2, '0')}:'
          '${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }

  static String _formatCompactDuration(int durationMs) {
    if (durationMs <= 0) return '0m';
    final minutes = (durationMs / Duration.millisecondsPerMinute).ceil();
    if (minutes < 60) return '${minutes}m';
    final hours = minutes / 60;
    return '${hours.toStringAsFixed(hours >= 10 ? 0 : 1)}h';
  }

  static String _relativeDate(DateTime date) {
    final difference = DateTime.now().difference(date);
    if (difference.inMinutes < 1) return 'just now';
    if (difference.inHours < 1) return '${difference.inMinutes}m ago';
    if (difference.inDays < 1) return '${difference.inHours}h ago';
    if (difference.inDays < 7) return '${difference.inDays}d ago';
    return '${date.day.toString().padLeft(2, '0')}/'
        '${date.month.toString().padLeft(2, '0')}/${date.year}';
  }
}

class _BrandLockup extends StatelessWidget {
  const _BrandLockup();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: kAccent,
            borderRadius: BorderRadius.circular(11),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              const Icon(Icons.play_arrow_rounded, color: kOnAccent, size: 25),
              Positioned(
                left: 7,
                top: 7,
                bottom: 7,
                child: Container(width: 2, color: kAccentSecondary),
              ),
            ],
          ),
        ),
        const SizedBox(width: 11),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'CAPTIONCRAFT',
              style: TextStyle(
                color: kTextPrimary,
                fontWeight: FontWeight.w900,
                fontSize: 14,
                letterSpacing: 0.35,
              ),
            ),
            Text(
              'EDITING STUDIO',
              style: TextStyle(
                fontFamily: 'monospace',
                color: kAccent,
                fontWeight: FontWeight.w700,
                fontSize: 8.5,
                letterSpacing: 1.7,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _StudioGridPainter extends CustomPainter {
  const _StudioGridPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = kBorder.withValues(alpha: 0.42)
      ..strokeWidth = 1;
    for (double x = size.width * 0.58; x < size.width; x += 32) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }
    for (double y = 18; y < size.height; y += 32) {
      canvas.drawLine(
        Offset(size.width * 0.58, y),
        Offset(size.width, y),
        gridPaint,
      );
    }

    final barPaint = Paint()..color = kAccent.withValues(alpha: 0.12);
    canvas.drawRect(
      Rect.fromLTWH(size.width * 0.72, 42, size.width * 0.24, 18),
      barPaint,
    );
    canvas.drawRect(
      Rect.fromLTWH(size.width * 0.64, 76, size.width * 0.20, 18),
      barPaint,
    );
    canvas.drawRect(
      Rect.fromLTWH(size.width * 0.79, 110, size.width * 0.16, 18),
      Paint()..color = kAccentSecondary.withValues(alpha: 0.1),
    );

    final playhead = Paint()
      ..color = kAccent.withValues(alpha: 0.48)
      ..strokeWidth = 1.5;
    canvas.drawLine(
      Offset(size.width * 0.83, 20),
      Offset(size.width * 0.83, size.height - 20),
      playhead,
    );
    final markerPath = Path()
      ..moveTo(size.width * 0.83 - 5, 20)
      ..lineTo(size.width * 0.83 + 5, 20)
      ..lineTo(size.width * 0.83, 27)
      ..close();
    canvas.drawPath(markerPath, Paint()..color = kAccent);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _MetricPill extends StatelessWidget {
  final String value;
  final String label;
  final bool warning;

  const _MetricPill({
    required this.value,
    required this.label,
    this.warning = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = warning ? kWarning : kTextPrimary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
      decoration: BoxDecoration(
        color: kBackground.withValues(alpha: 0.64),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: warning ? kWarning : kBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value,
            style: TextStyle(
              fontFamily: 'monospace',
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            label.toUpperCase(),
            style: TextStyle(
              color: kTextSecondary,
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.7,
            ),
          ),
        ],
      ),
    );
  }
}

class _ViewButton extends StatelessWidget {
  final IconData icon;
  final bool selected;
  final String tooltip;
  final VoidCallback onTap;

  const _ViewButton({
    required this.icon,
    required this.selected,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(7),
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: selected ? kSurfaceHigh : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Icon(
            icon,
            size: 17,
            color: selected ? kAccent : kTextSecondary,
          ),
        ),
      ),
    );
  }
}

class _TinyBadge extends StatelessWidget {
  final IconData icon;
  final String label;

  const _TinyBadge({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.68),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white70, size: 11),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontFamily: 'monospace',
              color: Colors.white,
              fontSize: 9.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _MenuLabel extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool destructive;

  const _MenuLabel({
    required this.icon,
    required this.label,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = destructive ? kError : kTextPrimary;
    return Row(
      children: [
        Icon(icon, color: color, size: 18),
        const SizedBox(width: 11),
        Text(label, style: TextStyle(color: color)),
      ],
    );
  }
}

class _ThumbnailPlaceholder extends StatelessWidget {
  const _ThumbnailPlaceholder();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: const _PlaceholderPainter(),
      child: const Center(
        child: Icon(
          Icons.play_circle_outline_rounded,
          color: kTextSecondary,
          size: 37,
        ),
      ),
    );
  }
}

class _PlaceholderPainter extends CustomPainter {
  const _PlaceholderPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = kBorder.withValues(alpha: 0.6)
      ..strokeWidth = 1;
    for (double x = -size.height; x < size.width; x += 28) {
      canvas.drawLine(
        Offset(x, size.height),
        Offset(x + size.height, 0),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _EmptyFilmFrame extends StatelessWidget {
  const _EmptyFilmFrame();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 148,
      height: 102,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: kBorder),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.28),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Row(
        children: [
          _FilmPerforations(),
          Expanded(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 9),
              decoration: BoxDecoration(
                color: kSurfaceElevated,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Center(
                child: Icon(Icons.add_rounded, color: kAccent, size: 32),
              ),
            ),
          ),
          _FilmPerforations(),
        ],
      ),
    );
  }
}

class _FilmPerforations extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: List.generate(
        4,
        (_) => Container(
          width: 7,
          height: 10,
          decoration: BoxDecoration(
            color: kBackground,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }
}

class _SheetHandle extends StatelessWidget {
  const _SheetHandle();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Container(
        width: 38,
        height: 4,
        decoration: BoxDecoration(
          color: kBorder,
          borderRadius: BorderRadius.circular(99),
        ),
      ),
    );
  }
}

class _InfoCallout extends StatelessWidget {
  final IconData icon;
  final String text;

  const _InfoCallout({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: kInfo.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: kInfo.withValues(alpha: 0.18)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: kInfo, size: 17),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: kTextSecondary,
                fontSize: 11.5,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NoticeBanner extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String message;
  final Widget? action;

  const _NoticeBanner({
    required this.icon,
    required this.color,
    required this.message,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: color, fontSize: 11.5, height: 1.4),
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}
