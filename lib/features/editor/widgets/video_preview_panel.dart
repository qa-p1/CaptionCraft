import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';
import '../../../core/theme/app_theme.dart';
import '../models/subtitle_entry.dart';
import '../models/subtitle_style_model.dart';
import '../models/timeline_models.dart';
import '../providers/editor_provider.dart';
import '../providers/playback_provider.dart';
import '../providers/subtitle_provider.dart';
import '../widgets/animated_subtitle_overlay.dart';

/// Video preview panel with subtitle overlay and playback controls.
class VideoPreviewPanel extends ConsumerStatefulWidget {
  final String videoPath;
  final double? targetAspectRatio;

  const VideoPreviewPanel({
    super.key,
    required this.videoPath,
    this.targetAspectRatio,
  });

  @override
  ConsumerState<VideoPreviewPanel> createState() => _VideoPreviewPanelState();
}

class _VideoPreviewPanelState extends ConsumerState<VideoPreviewPanel> {
  late VideoPlayerController _controller;
  bool _initialized = false;
  bool _playbackSyncQueued = false;
  double _playbackSpeed = 1.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _initializeVideo();
    });
  }

  Future<void> _initializeVideo() async {
    _controller = VideoPlayerController.file(File(widget.videoPath));
    await _controller.initialize();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final playbackNotifier = ref.read(playbackProvider.notifier);
      playbackNotifier.updateDuration(_controller.value.duration);
      playbackNotifier.setReady(true);
    });

    _controller.addListener(_onPlaybackUpdate);
    setState(() => _initialized = true);
  }

  void _onPlaybackUpdate() {
    if (!mounted) return;
    if (_playbackSyncQueued) return;
    _playbackSyncQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _playbackSyncQueued = false;
      if (!mounted) return;
      final playback = ref.read(playbackProvider.notifier);
      playback.updatePosition(_controller.value.position);
      playback.setPlaying(_controller.value.isPlaying);
    });
  }

  @override
  void dispose() {
    _controller.removeListener(_onPlaybackUpdate);
    _controller.dispose();
    super.dispose();
  }

  void _togglePlayPause() {
    if (_controller.value.isPlaying) {
      _controller.pause();
    } else {
      _controller.play();
    }
  }

  void _seekTo(Duration position) {
    if (!_initialized) return;
    ref.read(playbackProvider.notifier).requestSeek(position);
  }

  Future<void> _setPlaybackSpeed(double speed) async {
    if (!_initialized) return;
    await _controller.setPlaybackSpeed(speed);
    if (!mounted) return;
    setState(() => _playbackSpeed = speed);
  }

  SubtitleStyleModel _readEditableStyleFor(
    SubtitleEntry activeEntry,
    bool editPerEntry,
  ) {
    final subtitleState = ref.read(subtitleProvider);
    final latest = subtitleState.entries.where((e) => e.id == activeEntry.id);
    final latestEntry = latest.isNotEmpty ? latest.first : activeEntry;
    if (editPerEntry) {
      return latestEntry.styleOverride ?? subtitleState.globalStyle;
    }
    return subtitleState.globalStyle;
  }

  void _applyStyleLive({
    required SubtitleEntry activeEntry,
    required SubtitleStyleModel style,
    required bool editPerEntry,
  }) {
    final notifier = ref.read(subtitleProvider.notifier);
    if (editPerEntry) {
      notifier.setEntryStyleOverrideLive(activeEntry.id, style);
    } else {
      notifier.updateGlobalStyleLive(style);
    }
  }

  void _beginStyleGesture(SubtitleEntry activeEntry) {
    final notifier = ref.read(subtitleProvider.notifier);
    notifier.selectEntry(activeEntry.id);
    notifier.beginStyleGestureEdit();
  }

  void _endStyleGesture() {
    ref.read(subtitleProvider.notifier).endStyleGestureEdit();
  }

  List<_OverlayCanvasItem> _activeOverlayItems(
    EditorTimeline timeline,
    Duration position,
  ) {
    final items = <_OverlayCanvasItem>[];
    for (
      var trackIndex = 0;
      trackIndex < timeline.tracks.length;
      trackIndex++
    ) {
      final track = timeline.tracks[trackIndex];
      if (track.section != TimelineTrackSection.overlay || track.isHidden) {
        continue;
      }
      for (final clip in track.clips) {
        if (position < clip.startTime || position > clip.endTime) continue;
        EditorAssetReference? asset;
        for (final candidate in timeline.assets) {
          if (candidate.id == clip.assetId) {
            asset = candidate;
            break;
          }
        }
        if (asset == null) continue;
        items.add(
          _OverlayCanvasItem(
            trackIndex: trackIndex,
            trackId: track.id,
            clip: clip,
            asset: asset,
          ),
        );
      }
    }

    items.sort((a, b) {
      final trackCompare = a.trackIndex.compareTo(b.trackIndex);
      if (trackCompare != 0) return trackCompare;
      return a.clip.layer.compareTo(b.clip.layer);
    });
    return items;
  }

  List<_TextCanvasItem> _activeTextItems(
    EditorTimeline timeline,
    Duration position,
  ) {
    final items = <_TextCanvasItem>[];
    for (
      var trackIndex = 0;
      trackIndex < timeline.tracks.length;
      trackIndex++
    ) {
      final track = timeline.tracks[trackIndex];
      if (track.type != TimelineTrackType.text || track.isHidden) continue;
      for (final clip in track.clips) {
        if (position < clip.startTime || position > clip.endTime) continue;
        items.add(
          _TextCanvasItem(
            trackIndex: trackIndex,
            trackId: track.id,
            clip: clip,
          ),
        );
      }
    }

    items.sort((a, b) {
      final trackCompare = a.trackIndex.compareTo(b.trackIndex);
      if (trackCompare != 0) return trackCompare;
      return a.clip.layer.compareTo(b.clip.layer);
    });
    return items;
  }

  TimelineClip? _activeBaseClip(EditorTimeline timeline, Duration position) {
    TimelineClip? activeClip;
    for (final track in timeline.tracks) {
      if (track.section != TimelineTrackSection.baseVideo || track.isHidden) {
        continue;
      }
      for (final clip in track.clips) {
        if (position < clip.startTime || position > clip.endTime) continue;
        activeClip = clip;
        break;
      }
      if (activeClip != null) {
        break;
      }
    }
    return activeClip;
  }

  void _selectOverlayClip(_OverlayCanvasItem item) {
    final editorNotifier = ref.read(editorProvider.notifier);
    editorNotifier.selectTrack(item.trackId);
    editorNotifier.selectClip(item.clip.id);
    ref.read(subtitleProvider.notifier).selectEntry(null);
  }

  void _updateOverlayTransform(
    String clipId,
    TimelineTransform Function(TimelineTransform current) mapper,
  ) {
    final editorState = ref.read(editorProvider);
    final nextTracks = editorState.timeline.tracks.map((track) {
      final updatedClips = track.clips.map((clip) {
        if (clip.id != clipId) return clip;
        return clip.copyWith(transform: mapper(clip.transform));
      }).toList();
      return track.copyWith(clips: updatedClips);
    }).toList();

    ref
        .read(editorProvider.notifier)
        .setTimeline(editorState.timeline.copyWith(tracks: nextTracks));
  }

  Widget _buildOverlayAsset(
    _OverlayCanvasItem item,
    BoxConstraints constraints,
    PlaybackState playbackState,
  ) {
    final baseWidth = (constraints.maxWidth * 0.32).clamp(90.0, 220.0);
    final previewUrl =
        item.asset.metadata['previewUrl'] as String? ?? item.asset.remoteUrl;
    final localPath = item.asset.sourcePath;
    final localFile = localPath == null ? null : File(localPath);
    final hasLocalFile = localFile?.existsSync() ?? false;
    final animation = _resolveOverlayAnimation(
      item.clip,
      constraints,
      playbackState.position,
    );
    final child = switch (item.asset.type) {
      EditorAssetType.image || EditorAssetType.gif => ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: hasLocalFile
            ? Image.file(
                localFile!,
                width: baseWidth,
                fit: BoxFit.contain,
                filterQuality: FilterQuality.medium,
              )
            : previewUrl != null
            ? Image.network(
                previewUrl,
                width: baseWidth,
                fit: BoxFit.contain,
                filterQuality: FilterQuality.medium,
                errorBuilder: (_, _, _) =>
                    _buildMissingOverlay(item.clip.label),
              )
            : _buildMissingOverlay(item.clip.label),
      ),
      EditorAssetType.video =>
        hasLocalFile
            ? _OverlayVideoPreview(
                videoPath: localFile!.path,
                clip: item.clip,
                playbackPosition: playbackState.position,
                isPlaying: playbackState.isPlaying,
                width: baseWidth,
              )
            : _buildMissingOverlay(item.clip.label),
      EditorAssetType.sticker => ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: hasLocalFile
            ? Image.file(
                localFile!,
                width: baseWidth,
                fit: BoxFit.contain,
                filterQuality: FilterQuality.medium,
              )
            : previewUrl != null
            ? Image.network(
                previewUrl,
                width: baseWidth,
                fit: BoxFit.contain,
                filterQuality: FilterQuality.medium,
                errorBuilder: (_, _, _) =>
                    _buildMissingOverlay(item.clip.label),
              )
            : _buildMissingOverlay(item.clip.label),
      ),
      _ => _buildMissingOverlay(item.clip.label),
    };

    return Transform.translate(
      offset: animation.offset,
      child: Opacity(
        opacity: animation.opacity,
        child: Transform.rotate(
          angle: item.clip.transform.rotation,
          child: Transform.scale(scale: animation.scale, child: child),
        ),
      ),
    );
  }

  _OverlayAnimationState _resolveOverlayAnimation(
    TimelineClip clip,
    BoxConstraints constraints,
    Duration position,
  ) {
    var opacity = clip.transform.opacity.clamp(0.1, 1.0).toDouble();
    var scale = clip.transform.scale;
    var offset = Offset.zero;

    final elapsedMs = (position - clip.startTime).inMilliseconds
        .clamp(0, clip.duration.inMilliseconds)
        .toDouble();
    final remainingMs = (clip.endTime - position).inMilliseconds
        .clamp(0, clip.duration.inMilliseconds)
        .toDouble();

    void applyTransition(ClipTransition transition, double hiddenAmount) {
      if (transition.type == TransitionType.none ||
          transition.type == TransitionType.cut ||
          hiddenAmount <= 0) {
        return;
      }

      switch (transition.type) {
        case TransitionType.fade:
        case TransitionType.dissolve:
          opacity *= (1 - hiddenAmount).clamp(0.0, 1.0);
          break;
        case TransitionType.slideLeft:
          offset += Offset(-constraints.maxWidth * 0.18 * hiddenAmount, 0);
          opacity *= (1 - hiddenAmount * 0.15).clamp(0.0, 1.0);
          break;
        case TransitionType.slideRight:
          offset += Offset(constraints.maxWidth * 0.18 * hiddenAmount, 0);
          opacity *= (1 - hiddenAmount * 0.15).clamp(0.0, 1.0);
          break;
        case TransitionType.slideUp:
          offset += Offset(0, -constraints.maxHeight * 0.18 * hiddenAmount);
          opacity *= (1 - hiddenAmount * 0.15).clamp(0.0, 1.0);
          break;
        case TransitionType.slideDown:
          offset += Offset(0, constraints.maxHeight * 0.18 * hiddenAmount);
          opacity *= (1 - hiddenAmount * 0.15).clamp(0.0, 1.0);
          break;
        case TransitionType.zoom:
          scale *= (1 - hiddenAmount * 0.22).clamp(0.6, 1.0);
          opacity *= (1 - hiddenAmount * 0.1).clamp(0.0, 1.0);
          break;
        case TransitionType.none:
        case TransitionType.cut:
          break;
      }
    }

    final introDuration = clip.introTransition.durationMs;
    if (introDuration > 0 && elapsedMs < introDuration) {
      final hiddenAmount = 1 - (elapsedMs / introDuration).clamp(0.0, 1.0);
      applyTransition(clip.introTransition, hiddenAmount);
    }

    final outroDuration = clip.outroTransition.durationMs;
    if (outroDuration > 0 && remainingMs < outroDuration) {
      final hiddenAmount = 1 - (remainingMs / outroDuration).clamp(0.0, 1.0);
      applyTransition(clip.outroTransition, hiddenAmount);
    }

    return _OverlayAnimationState(
      opacity: opacity.clamp(0.0, 1.0),
      scale: scale.clamp(0.2, 4.0),
      offset: offset,
    );
  }

  Widget _buildMissingOverlay(String label) {
    return Container(
      width: 140,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: kSurfaceElevated,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kBorder),
      ),
      child: Text(
        label,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: kTextPrimary, fontSize: 12),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(playbackProvider.select((state) => state.seekRequestId ?? 0), (
      _,
      requestId,
    ) {
      if (!_initialized || !mounted) return;
      final playbackState = ref.read(playbackProvider);
      final target = playbackState.pendingSeekPosition;
      if (target == null) return;

      final clampedMs = target.inMilliseconds
          .clamp(0, _controller.value.duration.inMilliseconds)
          .toInt();
      _controller.seekTo(Duration(milliseconds: clampedMs));
      ref.read(playbackProvider.notifier).acknowledgeSeek(requestId);
    });

    final playbackState = ref.watch(playbackProvider);
    final subtitleState = ref.watch(subtitleProvider);
    final editorState = ref.watch(editorProvider);
    final activeOverlayItems = _activeOverlayItems(
      editorState.timeline,
      playbackState.position,
    );
    final activeTextItems = _activeTextItems(
      editorState.timeline,
      playbackState.position,
    );
    final activeBaseClip = _activeBaseClip(
      editorState.timeline,
      playbackState.position,
    );

    SubtitleEntry? activeSubtitle;
    for (final entry in subtitleState.entries) {
      if (playbackState.position >= entry.startTime &&
          playbackState.position <= entry.endTime) {
        activeSubtitle = entry;
        break;
      }
    }

    return Container(
      color: kBackground,
      child: Column(
        children: [
          // Video with subtitle overlay
          Expanded(
            child: _initialized
                ? Stack(
                    alignment: Alignment.center,
                    children: [
                      Center(
                        child: AspectRatio(
                          aspectRatio:
                              widget.targetAspectRatio ??
                              _controller.value.aspectRatio,
                          child: Container(
                            color: Colors.black,
                            child: LayoutBuilder(
                              builder: (context, constraints) {
                                final animation = activeBaseClip == null
                                    ? const _OverlayAnimationState(
                                        opacity: 1,
                                        scale: 1,
                                        offset: Offset.zero,
                                      )
                                    : _resolveOverlayAnimation(
                                        activeBaseClip,
                                        constraints,
                                        playbackState.position,
                                      );
                                return Center(
                                  child: Transform.translate(
                                    offset: animation.offset,
                                    child: Opacity(
                                      opacity: animation.opacity,
                                      child: Transform.scale(
                                        scale: animation.scale,
                                        child: AspectRatio(
                                          aspectRatio:
                                              _controller.value.aspectRatio,
                                          child: VideoPlayer(_controller),
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                      Positioned.fill(
                        child: GestureDetector(
                          onTap: _togglePlayPause,
                          behavior: HitTestBehavior.translucent,
                          child: AnimatedOpacity(
                            opacity: playbackState.isPlaying ? 0 : 0.7,
                            duration: const Duration(milliseconds: 200),
                            child: const Center(
                              child: Icon(
                                Icons.play_circle_filled_rounded,
                                size: 56,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (activeOverlayItems.isNotEmpty)
                        Positioned.fill(
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              final maxX = (constraints.maxWidth / 2 - 28)
                                  .clamp(0.0, 99999.0);
                              final maxY = (constraints.maxHeight / 2 - 28)
                                  .clamp(0.0, 99999.0);

                              return Stack(
                                children: activeOverlayItems.map((item) {
                                  final isSelected =
                                      editorState.selectedClipId ==
                                      item.clip.id;
                                  final transform = item.clip.transform;
                                  return Align(
                                    child: Transform.translate(
                                      offset: Offset(
                                        transform.offsetX.clamp(-maxX, maxX),
                                        transform.offsetY.clamp(-maxY, maxY),
                                      ),
                                      child: _OverlayTransformBox(
                                        isSelected: isSelected,
                                        onTap: () => _selectOverlayClip(item),
                                        onMoveStart: () =>
                                            _selectOverlayClip(item),
                                        onMoveUpdate: (delta) {
                                          _updateOverlayTransform(
                                            item.clip.id,
                                            (current) => current.copyWith(
                                              offsetX:
                                                  (current.offsetX + delta.dx)
                                                      .clamp(-maxX, maxX)
                                                      .toDouble(),
                                              offsetY:
                                                  (current.offsetY + delta.dy)
                                                      .clamp(-maxY, maxY)
                                                      .toDouble(),
                                            ),
                                          );
                                        },
                                        onMoveEnd: () {},
                                        onWidthResizeStart: () =>
                                            _selectOverlayClip(item),
                                        onWidthResizeUpdate: (delta) {
                                          _updateOverlayTransform(
                                            item.clip.id,
                                            (current) => current.copyWith(
                                              scale:
                                                  (current.scale +
                                                          (delta.dx /
                                                              constraints
                                                                  .maxWidth))
                                                      .clamp(0.2, 4.0)
                                                      .toDouble(),
                                            ),
                                          );
                                        },
                                        onWidthResizeEnd: () {},
                                        onHeightResizeStart: () =>
                                            _selectOverlayClip(item),
                                        onHeightResizeUpdate: (delta) {
                                          _updateOverlayTransform(
                                            item.clip.id,
                                            (current) => current.copyWith(
                                              scale:
                                                  (current.scale +
                                                          (delta.dy /
                                                              constraints
                                                                  .maxHeight))
                                                      .clamp(0.2, 4.0)
                                                      .toDouble(),
                                            ),
                                          );
                                        },
                                        onHeightResizeEnd: () {},
                                        child: _buildOverlayAsset(
                                          item,
                                          constraints,
                                          playbackState,
                                        ),
                                      ),
                                    ),
                                  );
                                }).toList(),
                              );
                            },
                          ),
                        ),
                      if (activeTextItems.isNotEmpty)
                        Positioned.fill(
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              final maxX = (constraints.maxWidth / 2 - 28)
                                  .clamp(0.0, 99999.0);
                              final maxY = (constraints.maxHeight / 2 - 28)
                                  .clamp(0.0, 99999.0);

                              return Stack(
                                children: activeTextItems.map((item) {
                                  final isSelected =
                                      editorState.selectedClipId ==
                                      item.clip.id;
                                  final style =
                                      item.clip.subtitleStyle ??
                                      const SubtitleStyleModel(
                                        position: SubtitlePosition.center,
                                        fontSize: 32,
                                      );
                                  return Align(
                                    child: Transform.translate(
                                      offset: Offset(
                                        item.clip.transform.offsetX.clamp(
                                          -maxX,
                                          maxX,
                                        ),
                                        item.clip.transform.offsetY.clamp(
                                          -maxY,
                                          maxY,
                                        ),
                                      ),
                                      child: _OverlayTransformBox(
                                        isSelected: isSelected,
                                        onTap: () {
                                          ref
                                              .read(editorProvider.notifier)
                                              .selectTrack(item.trackId);
                                          ref
                                              .read(editorProvider.notifier)
                                              .selectClip(item.clip.id);
                                          ref
                                              .read(subtitleProvider.notifier)
                                              .selectEntry(null);
                                        },
                                        onMoveStart: () {
                                          ref
                                              .read(editorProvider.notifier)
                                              .selectTrack(item.trackId);
                                          ref
                                              .read(editorProvider.notifier)
                                              .selectClip(item.clip.id);
                                        },
                                        onMoveUpdate: (delta) {
                                          _updateOverlayTransform(
                                            item.clip.id,
                                            (current) => current.copyWith(
                                              offsetX:
                                                  (current.offsetX + delta.dx)
                                                      .clamp(-maxX, maxX)
                                                      .toDouble(),
                                              offsetY:
                                                  (current.offsetY + delta.dy)
                                                      .clamp(-maxY, maxY)
                                                      .toDouble(),
                                            ),
                                          );
                                        },
                                        onMoveEnd: () {},
                                        onWidthResizeStart: () {
                                          ref
                                              .read(editorProvider.notifier)
                                              .selectTrack(item.trackId);
                                          ref
                                              .read(editorProvider.notifier)
                                              .selectClip(item.clip.id);
                                        },
                                        onWidthResizeUpdate: (delta) {
                                          _updateOverlayTransform(
                                            item.clip.id,
                                            (current) => current.copyWith(
                                              scale:
                                                  (current.scale +
                                                          (delta.dx /
                                                              constraints
                                                                  .maxWidth))
                                                      .clamp(0.25, 4.0)
                                                      .toDouble(),
                                            ),
                                          );
                                        },
                                        onWidthResizeEnd: () {},
                                        onHeightResizeStart: () {
                                          ref
                                              .read(editorProvider.notifier)
                                              .selectTrack(item.trackId);
                                          ref
                                              .read(editorProvider.notifier)
                                              .selectClip(item.clip.id);
                                        },
                                        onHeightResizeUpdate: (delta) {
                                          _updateOverlayTransform(
                                            item.clip.id,
                                            (current) => current.copyWith(
                                              scale:
                                                  (current.scale +
                                                          (delta.dy /
                                                              constraints
                                                                  .maxHeight))
                                                      .clamp(0.25, 4.0)
                                                      .toDouble(),
                                            ),
                                          );
                                        },
                                        onHeightResizeEnd: () {},
                                        child: Transform.scale(
                                          scale: item.clip.transform.scale,
                                          child: ConstrainedBox(
                                            constraints: BoxConstraints(
                                              maxWidth:
                                                  constraints.maxWidth *
                                                  style.maxWidthFactor,
                                            ),
                                            child: Text(
                                              item.clip.text ?? item.clip.label,
                                              textAlign: style.textAlignment,
                                              style: TextStyle(
                                                color: style.textColor,
                                                fontSize: style.fontSize,
                                                fontWeight: style.isBold
                                                    ? FontWeight.w700
                                                    : FontWeight.w500,
                                                fontStyle: style.isItalic
                                                    ? FontStyle.italic
                                                    : FontStyle.normal,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                }).toList(),
                              );
                            },
                          ),
                        ),
                      if (activeSubtitle != null)
                        Positioned.fill(
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              final activeEntry = activeSubtitle!;
                              final isSelected =
                                  subtitleState.selectedEntryId ==
                                  activeEntry.id;
                              // Keep transform edits global so move/resize
                              // applies consistently to all subtitle blocks.
                              const editPerEntry = false;
                              final editableStyle = _readEditableStyleFor(
                                activeEntry,
                                editPerEntry,
                              );

                              final maxX = (constraints.maxWidth / 2 - 24)
                                  .clamp(0.0, 99999.0);
                              final maxY = (constraints.maxHeight / 2 - 24)
                                  .clamp(0.0, 99999.0);
                              final effectiveOffsetY =
                                  editableStyle.verticalOffset +
                                  editableStyle.offsetY;

                              return Align(
                                alignment: _alignmentForPosition(
                                  editableStyle.position,
                                ),
                                child: Transform.translate(
                                  offset: Offset(
                                    editableStyle.offsetX.clamp(-maxX, maxX),
                                    effectiveOffsetY.clamp(-maxY, maxY),
                                  ),
                                  child: _OverlayTransformBox(
                                    isSelected: isSelected,
                                    onTap: () {
                                      ref
                                          .read(subtitleProvider.notifier)
                                          .selectEntry(activeEntry.id);
                                    },
                                    onMoveStart: () =>
                                        _beginStyleGesture(activeEntry),
                                    onMoveUpdate: (delta) {
                                      final style = _readEditableStyleFor(
                                        activeEntry,
                                        editPerEntry,
                                      );
                                      final nextOffsetX =
                                          (style.offsetX + delta.dx)
                                              .clamp(-maxX, maxX)
                                              .toDouble();
                                      final nextOffsetY =
                                          (style.offsetY + delta.dy)
                                              .clamp(-maxY, maxY)
                                              .toDouble();

                                      _applyStyleLive(
                                        activeEntry: activeEntry,
                                        editPerEntry: editPerEntry,
                                        style: style.copyWith(
                                          offsetX: nextOffsetX,
                                          offsetY: nextOffsetY,
                                        ),
                                      );
                                    },
                                    onMoveEnd: _endStyleGesture,
                                    onWidthResizeStart: () =>
                                        _beginStyleGesture(activeEntry),
                                    onWidthResizeUpdate: (delta) {
                                      final style = _readEditableStyleFor(
                                        activeEntry,
                                        editPerEntry,
                                      );
                                      final widthDelta =
                                          delta.dx / constraints.maxWidth;
                                      final nextWidth =
                                          (style.maxWidthFactor + widthDelta)
                                              .clamp(0.25, 1.0)
                                              .toDouble();

                                      _applyStyleLive(
                                        activeEntry: activeEntry,
                                        editPerEntry: editPerEntry,
                                        style: style.copyWith(
                                          maxWidthFactor: nextWidth,
                                        ),
                                      );
                                    },
                                    onWidthResizeEnd: _endStyleGesture,
                                    onHeightResizeStart: () =>
                                        _beginStyleGesture(activeEntry),
                                    onHeightResizeUpdate: (delta) {
                                      final style = _readEditableStyleFor(
                                        activeEntry,
                                        editPerEntry,
                                      );
                                      final nextFontSize =
                                          (style.fontSize + delta.dy * 0.25)
                                              .clamp(1.0, 72.0)
                                              .toDouble();

                                      _applyStyleLive(
                                        activeEntry: activeEntry,
                                        editPerEntry: editPerEntry,
                                        style: style.copyWith(
                                          fontSize: nextFontSize,
                                        ),
                                      );
                                    },
                                    onHeightResizeEnd: _endStyleGesture,
                                    child: AnimatedSubtitleOverlay(
                                      entry: activeEntry,
                                      globalStyle: subtitleState.globalStyle,
                                      currentPosition: playbackState.position,
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                    ],
                  )
                : const Center(
                    child: CircularProgressIndicator(
                      color: kAccent,
                      strokeWidth: 2,
                    ),
                  ),
          ),
          // Playback controls
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            color: kSurface,
            child: Column(
              children: [
                SliderTheme(
                  data: SliderThemeData(
                    activeTrackColor: kAccent,
                    inactiveTrackColor: kBorder,
                    thumbColor: kAccent,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 6,
                    ),
                    trackHeight: 3,
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 12,
                    ),
                  ),
                  child: Slider(
                    value: playbackState.progressPercent.clamp(0, 1).toDouble(),
                    onChanged: (value) {
                      final pos = Duration(
                        milliseconds:
                            (value * playbackState.duration.inMilliseconds)
                                .round(),
                      );
                      _seekTo(pos);
                    },
                  ),
                ),
                LayoutBuilder(
                  builder: (context, constraints) {
                    return SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          minWidth: constraints.maxWidth,
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            IconButton(
                              icon: const Icon(
                                Icons.replay_10_rounded,
                                color: kTextPrimary,
                                size: 22,
                              ),
                              onPressed: () => _seekTo(
                                playbackState.position -
                                    const Duration(seconds: 10),
                              ),
                            ),
                            const SizedBox(width: 8),
                            IconButton(
                              icon: Icon(
                                playbackState.isPlaying
                                    ? Icons.pause_rounded
                                    : Icons.play_arrow_rounded,
                                color: kTextPrimary,
                                size: 32,
                              ),
                              onPressed: _togglePlayPause,
                            ),
                            const SizedBox(width: 8),
                            IconButton(
                              icon: const Icon(
                                Icons.forward_10_rounded,
                                color: kTextPrimary,
                                size: 22,
                              ),
                              onPressed: () => _seekTo(
                                playbackState.position +
                                    const Duration(seconds: 10),
                              ),
                            ),
                            const SizedBox(width: 4),
                            PopupMenuButton<double>(
                              tooltip: 'Playback speed',
                              color: kSurfaceElevated,
                              onSelected: _setPlaybackSpeed,
                              itemBuilder: (_) => const [
                                PopupMenuItem(value: 0.5, child: Text('0.5x')),
                                PopupMenuItem(
                                  value: 0.75,
                                  child: Text('0.75x'),
                                ),
                                PopupMenuItem(value: 1.0, child: Text('1.0x')),
                                PopupMenuItem(
                                  value: 1.25,
                                  child: Text('1.25x'),
                                ),
                                PopupMenuItem(value: 1.5, child: Text('1.5x')),
                                PopupMenuItem(value: 2.0, child: Text('2.0x')),
                              ],
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: kSurfaceElevated,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: kBorder),
                                ),
                                child: Text(
                                  '${_playbackSpeed.toStringAsFixed(_playbackSpeed == 1 ? 0 : 2)}x',
                                  style: const TextStyle(
                                    color: kTextSecondary,
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 16),
                            Text(
                              '${SubtitleEntry.formatDisplayTime(playbackState.position)} / '
                              '${SubtitleEntry.formatDisplayTime(playbackState.duration)}',
                              style: const TextStyle(
                                fontFamily: 'SpaceMono',
                                color: kTextSecondary,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Alignment _alignmentForPosition(SubtitlePosition position) {
    switch (position) {
      case SubtitlePosition.top:
        return Alignment.topCenter;
      case SubtitlePosition.center:
        return Alignment.center;
      case SubtitlePosition.bottom:
        return Alignment.bottomCenter;
    }
  }
}

class _OverlayAnimationState {
  final double opacity;
  final double scale;
  final Offset offset;

  const _OverlayAnimationState({
    required this.opacity,
    required this.scale,
    required this.offset,
  });
}

class _OverlayCanvasItem {
  final int trackIndex;
  final String trackId;
  final TimelineClip clip;
  final EditorAssetReference asset;

  const _OverlayCanvasItem({
    required this.trackIndex,
    required this.trackId,
    required this.clip,
    required this.asset,
  });
}

class _TextCanvasItem {
  final int trackIndex;
  final String trackId;
  final TimelineClip clip;

  const _TextCanvasItem({
    required this.trackIndex,
    required this.trackId,
    required this.clip,
  });
}

class _OverlayVideoPreview extends StatefulWidget {
  final String videoPath;
  final TimelineClip clip;
  final Duration playbackPosition;
  final bool isPlaying;
  final double width;

  const _OverlayVideoPreview({
    required this.videoPath,
    required this.clip,
    required this.playbackPosition,
    required this.isPlaying,
    required this.width,
  });

  @override
  State<_OverlayVideoPreview> createState() => _OverlayVideoPreviewState();
}

class _OverlayVideoPreviewState extends State<_OverlayVideoPreview> {
  VideoPlayerController? _controller;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void didUpdateWidget(covariant _OverlayVideoPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoPath != widget.videoPath) {
      _disposeController();
      _initialize();
      return;
    }
    _syncPlayback();
  }

  Future<void> _initialize() async {
    final controller = VideoPlayerController.file(File(widget.videoPath));
    await controller.initialize();
    await controller.setVolume(0);
    if (!mounted) {
      await controller.dispose();
      return;
    }
    setState(() {
      _controller = controller;
      _ready = true;
    });
    _syncPlayback(forceSeek: true);
  }

  Future<void> _syncPlayback({bool forceSeek = false}) async {
    final controller = _controller;
    if (!_ready || controller == null || !controller.value.isInitialized) {
      return;
    }

    final relative =
        widget.playbackPosition -
        widget.clip.startTime +
        widget.clip.sourceStartTime;
    final targetMs = relative.inMilliseconds
        .clamp(0, controller.value.duration.inMilliseconds)
        .toInt();
    final currentMs = controller.value.position.inMilliseconds;
    if (forceSeek || (currentMs - targetMs).abs() > 200) {
      await controller.seekTo(Duration(milliseconds: targetMs));
    }
    final clipElapsedMs = (widget.playbackPosition - widget.clip.startTime)
        .inMilliseconds
        .clamp(0, widget.clip.duration.inMilliseconds)
        .toDouble();
    final clipRemainingMs = (widget.clip.endTime - widget.playbackPosition)
        .inMilliseconds
        .clamp(0, widget.clip.duration.inMilliseconds)
        .toDouble();
    var volume = widget.clip.audioMix.muted
        ? 0.0
        : widget.clip.audioMix.volume.clamp(0, 1).toDouble();
    if (widget.clip.audioMix.fadeInMs > 0) {
      volume *= (clipElapsedMs / widget.clip.audioMix.fadeInMs)
          .clamp(0.0, 1.0)
          .toDouble();
    }
    if (widget.clip.audioMix.fadeOutMs > 0) {
      volume *= (clipRemainingMs / widget.clip.audioMix.fadeOutMs)
          .clamp(0.0, 1.0)
          .toDouble();
    }
    await controller.setVolume(volume);
    if (!mounted) return;
    if (widget.isPlaying) {
      if (!controller.value.isPlaying) {
        await controller.play();
      }
    } else {
      if (controller.value.isPlaying) {
        await controller.pause();
      }
    }
  }

  Future<void> _disposeController() async {
    final controller = _controller;
    _controller = null;
    _ready = false;
    if (controller != null) {
      await controller.dispose();
    }
  }

  @override
  void dispose() {
    _disposeController();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (!_ready || controller == null || !controller.value.isInitialized) {
      return Container(
        width: widget.width,
        height: widget.width * 0.6,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.65),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: kBorder),
        ),
        child: const Center(
          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: widget.width,
        child: AspectRatio(
          aspectRatio: controller.value.aspectRatio == 0
              ? 16 / 9
              : controller.value.aspectRatio,
          child: VideoPlayer(controller),
        ),
      ),
    );
  }
}

class _OverlayTransformBox extends StatelessWidget {
  final Widget child;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onMoveStart;
  final ValueChanged<Offset> onMoveUpdate;
  final VoidCallback onMoveEnd;
  final VoidCallback onWidthResizeStart;
  final ValueChanged<Offset> onWidthResizeUpdate;
  final VoidCallback onWidthResizeEnd;
  final VoidCallback onHeightResizeStart;
  final ValueChanged<Offset> onHeightResizeUpdate;
  final VoidCallback onHeightResizeEnd;

  const _OverlayTransformBox({
    required this.child,
    required this.isSelected,
    required this.onTap,
    required this.onMoveStart,
    required this.onMoveUpdate,
    required this.onMoveEnd,
    required this.onWidthResizeStart,
    required this.onWidthResizeUpdate,
    required this.onWidthResizeEnd,
    required this.onHeightResizeStart,
    required this.onHeightResizeUpdate,
    required this.onHeightResizeEnd,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: onTap,
      onPanStart: (_) => onMoveStart(),
      onPanUpdate: (details) => onMoveUpdate(details.delta),
      onPanEnd: (_) => onMoveEnd(),
      onPanCancel: onMoveEnd,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            decoration: BoxDecoration(
              border: Border.all(
                color: isSelected
                    ? kAccent.withValues(alpha: 0.8)
                    : Colors.transparent,
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: child,
          ),
          if (isSelected)
            Positioned(
              right: -10,
              top: 0,
              bottom: 0,
              child: Center(
                child: _TransformHandle(
                  icon: Icons.open_in_full_rounded,
                  onPanStart: onWidthResizeStart,
                  onPanUpdate: onWidthResizeUpdate,
                  onPanEnd: onWidthResizeEnd,
                ),
              ),
            ),
          if (isSelected)
            Positioned(
              bottom: -10,
              left: 0,
              right: 0,
              child: Center(
                child: _TransformHandle(
                  icon: Icons.height_rounded,
                  onPanStart: onHeightResizeStart,
                  onPanUpdate: onHeightResizeUpdate,
                  onPanEnd: onHeightResizeEnd,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _TransformHandle extends StatelessWidget {
  final IconData icon;
  final VoidCallback onPanStart;
  final ValueChanged<Offset> onPanUpdate;
  final VoidCallback onPanEnd;

  const _TransformHandle({
    required this.icon,
    required this.onPanStart,
    required this.onPanUpdate,
    required this.onPanEnd,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (_) => onPanStart(),
      onPanUpdate: (details) => onPanUpdate(details.delta),
      onPanEnd: (_) => onPanEnd(),
      onPanCancel: onPanEnd,
      child: Container(
        width: 20,
        height: 20,
        decoration: BoxDecoration(
          color: kAccent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white, width: 1),
        ),
        child: Icon(icon, size: 12, color: Colors.white),
      ),
    );
  }
}
