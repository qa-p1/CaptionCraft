import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../models/timeline_models.dart';

enum DesktopLibrarySection { media, effects, captions }

/// Left side of the Windows workspace.
///
/// The media tab reflects the actual project asset pool and usage counts. The
/// effects and captions tabs keep their actions in context while reusing the
/// editor's existing sheets and providers through callbacks.
class DesktopMediaPanel extends StatefulWidget {
  final EditorTimeline timeline;
  final String? fallbackVideoPath;
  final TimelineClip? selectedClip;
  final ValueChanged<TimelineClip>? onSelectClip;
  final VoidCallback? onImport;
  final VoidCallback? onDiscover;
  final VoidCallback? onOpenEffects;
  final VoidCallback? onOpenCaptions;

  const DesktopMediaPanel({
    super.key,
    required this.timeline,
    this.fallbackVideoPath,
    this.selectedClip,
    this.onSelectClip,
    this.onImport,
    this.onDiscover,
    this.onOpenEffects,
    this.onOpenCaptions,
  });

  @override
  State<DesktopMediaPanel> createState() => _DesktopMediaPanelState();
}

class _DesktopMediaPanelState extends State<DesktopMediaPanel> {
  final TextEditingController _searchController = TextEditingController();
  DesktopLibrarySection _section = DesktopLibrarySection.media;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: kSurface,
      child: Column(
        children: [
          _buildHeader(context),
          _buildSectionTabs(),
          Expanded(child: _buildSectionBody()),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final title = switch (_section) {
      DesktopLibrarySection.media => 'Media pool',
      DesktopLibrarySection.effects => 'Effects library',
      DesktopLibrarySection.captions => 'Captions',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: kTextPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          if (_section == DesktopLibrarySection.media && widget.onImport != null)
            Tooltip(
              message: 'Import media',
              child: IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: widget.onImport,
                icon: const Icon(Icons.add_rounded, size: 18),
              ),
            ),
          if (_section == DesktopLibrarySection.media &&
              widget.onDiscover != null)
            Tooltip(
              message: 'Discover media',
              child: IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: widget.onDiscover,
                icon: const Icon(Icons.travel_explore_rounded, size: 17),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSectionTabs() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: Row(
        children: [
          _tab(
            DesktopLibrarySection.media,
            Icons.video_library_outlined,
            'Media',
          ),
          _tab(
            DesktopLibrarySection.effects,
            Icons.auto_fix_high_rounded,
            'Effects',
          ),
          _tab(
            DesktopLibrarySection.captions,
            Icons.closed_caption_outlined,
            'Captions',
          ),
        ],
      ),
    );
  }

  Widget _tab(DesktopLibrarySection section, IconData icon, String label) {
    final selected = section == _section;
    return Expanded(
      child: Tooltip(
        message: label,
        child: InkWell(
          onTap: () => setState(() => _section = section),
          borderRadius: BorderRadius.circular(7),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 3),
            decoration: BoxDecoration(
              color: selected ? kAccent.withValues(alpha: 0.14) : Colors.transparent,
              borderRadius: BorderRadius.circular(7),
              border: Border.all(color: selected ? kAccent : kBorder),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 16,
                  color: selected ? kAccent : kTextSecondary,
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected ? kTextPrimary : kTextSecondary,
                      fontSize: 11,
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSectionBody() {
    return switch (_section) {
      DesktopLibrarySection.media => _buildMediaBody(),
      DesktopLibrarySection.effects => _buildEffectsBody(),
      DesktopLibrarySection.captions => _buildCaptionsBody(),
    };
  }

  Widget _buildMediaBody() {
    final query = _searchController.text.trim().toLowerCase();
    final assets = widget.timeline.assets
        .where(
          (asset) =>
              query.isEmpty ||
              asset.label.toLowerCase().contains(query) ||
              (asset.sourcePath ?? '').toLowerCase().contains(query),
        )
        .toList(growable: false);
    final hasFallback = assets.isEmpty &&
        widget.fallbackVideoPath?.trim().isNotEmpty == true &&
        query.isEmpty;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
          child: TextField(
            controller: _searchController,
            onChanged: (_) => setState(() {}),
            style: const TextStyle(fontSize: 11),
            decoration: InputDecoration(
              hintText: 'Search assets',
              prefixIcon: const Icon(Icons.search_rounded, size: 17),
              suffixIcon: _searchController.text.isEmpty
                  ? null
                  : IconButton(
                      visualDensity: VisualDensity.compact,
                      onPressed: () {
                        _searchController.clear();
                        setState(() {});
                      },
                      icon: const Icon(Icons.clear_rounded, size: 16),
                    ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 8,
              ),
              isDense: true,
            ),
          ),
        ),
        Expanded(
          child: assets.isEmpty && !hasFallback
              ? _emptyMediaState(query.isEmpty)
              : ListView(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                  children: [
                    if (hasFallback)
                      _buildFallbackAsset(widget.fallbackVideoPath!),
                    for (final asset in assets) _buildAssetTile(asset),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _emptyMediaState(bool emptyProject) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              emptyProject ? Icons.video_library_outlined : Icons.search_off_rounded,
              size: 28,
              color: kTextTertiary,
            ),
            const SizedBox(height: 8),
            Text(
              emptyProject ? 'No media in this project' : 'No matching assets',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: kTextSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (emptyProject && widget.onImport != null) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: widget.onImport,
                icon: const Icon(Icons.add_rounded, size: 16),
                label: const Text('Import media'),
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildFallbackAsset(String sourcePath) {
    final label = sourcePath.split(RegExp(r'[/\\]')).last;
    return _assetCard(
      icon: Icons.movie_outlined,
      title: label.isEmpty ? 'Project source' : label,
      subtitle: 'Project source · base video',
      usage: widget.timeline.videoClips.length,
      selected: widget.selectedClip?.type == TimelineTrackType.video &&
          widget.selectedClip?.assetId == null,
      onTap: () {
        final clip = widget.timeline.videoClips.firstOrNull;
        if (clip != null) widget.onSelectClip?.call(clip);
      },
    );
  }

  Widget _buildAssetTile(EditorAssetReference asset) {
    final usage = widget.timeline.tracks
        .expand((track) => track.clips)
        .where((clip) => clip.assetId == asset.id)
        .length;
    final selected = widget.selectedClip?.assetId == asset.id;
    return _assetCard(
      icon: _iconForAsset(asset.type),
      title: asset.label,
      subtitle: _assetSubtitle(asset),
      usage: usage,
      selected: selected,
      onTap: () {
        final clip = widget.timeline.tracks
            .expand((track) => track.clips)
            .where((candidate) => candidate.assetId == asset.id)
            .firstOrNull;
        if (clip != null) widget.onSelectClip?.call(clip);
      },
    );
  }

  Widget _assetCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required int usage,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: selected ? kAccent.withValues(alpha: 0.12) : kSurfaceElevated,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: selected ? kAccent : kBorder),
          ),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: kBackground,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(icon, size: 18, color: selected ? kAccent : kTextSecondary),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: kTextPrimary,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: kTextSecondary, fontSize: 10.5),
                    ),
                  ],
                ),
              ),
              if (usage > 0)
                Text(
                  '$usage×',
                  style: const TextStyle(
                    color: kTextTertiary,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEffectsBody() {
    final selected = widget.selectedClip;
    final effectCount = selected?.effectStack.effects
            .where((effect) => effect.domain.name == 'visual')
            .length ??
        0;
    return ListView(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
      children: [
        _contextCard(
          icon: Icons.auto_fix_high_rounded,
          title: selected == null ? 'Select a clip' : 'Selected clip',
          subtitle: selected == null
              ? 'Choose a clip to apply effects in context.'
              : '${selected.label} · $effectCount visual effect${effectCount == 1 ? '' : 's'}',
        ),
        const SizedBox(height: 8),
        _libraryAction(
          icon: Icons.layers_rounded,
          title: 'Effect stack',
          subtitle: 'Add, reorder or disable effects',
          onTap: selected == null ? null : widget.onOpenEffects,
        ),
        _libraryAction(
          icon: Icons.auto_awesome_motion_rounded,
          title: 'Motion and animation',
          subtitle: 'Open clip animation controls',
          onTap: selected == null ? null : widget.onOpenEffects,
        ),
        _libraryAction(
          icon: Icons.tonality_rounded,
          title: 'Color and LUTs',
          subtitle: 'Adjust the selected visual layer',
          onTap: selected == null ? null : widget.onOpenEffects,
        ),
      ],
    );
  }

  Widget _buildCaptionsBody() {
    final tracks = widget.timeline.tracks
        .where((track) => track.type == TimelineTrackType.subtitle)
        .toList(growable: false);
    return ListView(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
      children: [
        _contextCard(
          icon: Icons.closed_caption_outlined,
          title: tracks.isEmpty ? 'No caption track' : '${tracks.length} caption track${tracks.length == 1 ? '' : 's'}',
          subtitle: 'Select a cue in the timeline to edit its text and style.',
        ),
        const SizedBox(height: 8),
        _libraryAction(
          icon: Icons.auto_awesome_rounded,
          title: 'Generate or replace captions',
          subtitle: 'Choose the source clip and language',
          onTap: widget.onOpenCaptions,
        ),
        const SizedBox(height: 8),
        for (final track in tracks) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 5, 2, 4),
            child: Text(
              track.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: kTextSecondary,
                fontSize: 10.5,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.5,
              ),
            ),
          ),
          for (final clip in track.clips.take(20))
            _captionCueTile(clip),
        ],
      ],
    );
  }

  Widget _captionCueTile(TimelineClip clip) {
    final selected = widget.selectedClip?.id == clip.id;
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: ListTile(
        dense: true,
        visualDensity: const VisualDensity(vertical: -3),
        contentPadding: const EdgeInsets.symmetric(horizontal: 8),
        tileColor: selected ? kAccent.withValues(alpha: 0.12) : kSurfaceElevated,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(7),
          side: BorderSide(color: selected ? kAccent : kBorder),
        ),
        leading: const Icon(Icons.subtitles_outlined, size: 16, color: kTextSecondary),
        title: Text(
          clip.text ?? clip.label,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700),
        ),
        subtitle: Text(_formatCueTime(clip.startTime), style: const TextStyle(fontSize: 10)),
        onTap: () => widget.onSelectClip?.call(clip),
      ),
    );
  }

  Widget _contextCard({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: kSurfaceElevated,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: kAccent),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800)),
                const SizedBox(height: 3),
                Text(subtitle, style: const TextStyle(color: kTextSecondary, fontSize: 10.5, height: 1.25)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _libraryAction({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback? onTap,
  }) {
    final enabled = onTap != null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        dense: true,
        visualDensity: const VisualDensity(vertical: -2),
        contentPadding: const EdgeInsets.symmetric(horizontal: 8),
        tileColor: kSurfaceElevated,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: kBorder),
        ),
        leading: Icon(icon, size: 18, color: enabled ? kTextPrimary : kTextTertiary),
        title: Text(title, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: enabled ? kTextPrimary : kTextTertiary)),
        subtitle: Text(subtitle, style: const TextStyle(fontSize: 10.5)),
        trailing: const Icon(Icons.chevron_right_rounded, size: 17),
        onTap: onTap,
      ),
    );
  }

  String _assetSubtitle(EditorAssetReference asset) {
    final type = switch (asset.type) {
      EditorAssetType.video => 'Video',
      EditorAssetType.audio => 'Audio',
      EditorAssetType.image => 'Image',
      EditorAssetType.gif => 'GIF',
      EditorAssetType.sticker => 'Sticker',
      EditorAssetType.unknown => 'Media',
    };
    final duration = asset.metadata['durationMs'];
    if (duration is num && duration > 0) {
      return '$type · ${_formatCueTime(Duration(milliseconds: duration.toInt()))}';
    }
    final dimensions = [asset.metadata['width'], asset.metadata['height']]
        .whereType<num>()
        .map((value) => value.toInt())
        .toList(growable: false);
    if (dimensions.length == 2) return '$type · ${dimensions[0]}×${dimensions[1]}';
    return type;
  }

  IconData _iconForAsset(EditorAssetType type) => switch (type) {
    EditorAssetType.video => Icons.movie_outlined,
    EditorAssetType.audio => Icons.audiotrack_rounded,
    EditorAssetType.image => Icons.image_outlined,
    EditorAssetType.gif => Icons.gif_box_outlined,
    EditorAssetType.sticker => Icons.emoji_emotions_outlined,
    EditorAssetType.unknown => Icons.insert_drive_file_outlined,
  };

  String _formatCueTime(Duration value) {
    final totalSeconds = value.inSeconds;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
}
