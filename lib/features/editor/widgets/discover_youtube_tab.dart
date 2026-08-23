import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../models/discover_models.dart';

typedef InspectYoutubeCallback = Future<void> Function(String url);
typedef EnqueueYoutubeCallback =
    Future<void> Function(
      YoutubeVideoInfo info,
      YoutubeFormatOption format,
      String? outputFileName,
    );

class DiscoverYoutubeTab extends StatefulWidget {
  final YoutubeVideoInfo? videoInfo;
  final List<DiscoverDownloadItem> downloads;
  final bool isInspecting;
  final bool isEnqueuing;
  final bool permittedContentAcknowledged;
  final String? errorMessage;
  final InspectYoutubeCallback onInspect;
  final EnqueueYoutubeCallback onEnqueue;
  final ValueChanged<bool> onAcknowledgementChanged;
  final Future<void> Function(String id) onCancel;

  const DiscoverYoutubeTab({
    super.key,
    required this.videoInfo,
    required this.downloads,
    required this.isInspecting,
    required this.isEnqueuing,
    required this.permittedContentAcknowledged,
    required this.errorMessage,
    required this.onInspect,
    required this.onEnqueue,
    required this.onAcknowledgementChanged,
    required this.onCancel,
  });

  @override
  State<DiscoverYoutubeTab> createState() => _DiscoverYoutubeTabState();
}

class _DiscoverYoutubeTabState extends State<DiscoverYoutubeTab>
    with AutomaticKeepAliveClientMixin {
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _fileNameController = TextEditingController();
  YoutubeDownloadKind? _selectedKind;
  String? _selectedFormatId;
  String? _localError;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _resolveInitialSelection(widget.videoInfo);
    if (widget.videoInfo case final info?) {
      _fileNameController.text = info.title;
    }
  }

  @override
  void didUpdateWidget(covariant DiscoverYoutubeTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoInfo?.videoId != widget.videoInfo?.videoId) {
      _resolveInitialSelection(widget.videoInfo);
      if (widget.videoInfo case final info?) {
        _fileNameController.text = info.title;
      }
    } else {
      _ensureSelectionIsAvailable();
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    _fileNameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final info = widget.videoInfo;
    final error = _localError ?? widget.errorMessage;
    return Column(
      key: const ValueKey('discover-youtube-tab'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('discover-youtube-url'),
                  controller: _urlController,
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.search,
                  autocorrect: false,
                  enableSuggestions: false,
                  onSubmitted: (_) => unawaited(_inspect()),
                  decoration: const InputDecoration(
                    hintText: 'Paste a YouTube video URL',
                    prefixIcon: Icon(Icons.link_rounded, size: 20),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 49,
                child: FilledButton.icon(
                  key: const ValueKey('discover-youtube-inspect'),
                  onPressed: widget.isInspecting
                      ? null
                      : () => unawaited(_inspect()),
                  icon: widget.isInspecting
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: kOnAccent,
                          ),
                        )
                      : const Icon(Icons.search_rounded, size: 18),
                  label: const Text('Inspect'),
                ),
              ),
            ],
          ),
        ),
        if (widget.isInspecting)
          const LinearProgressIndicator(
            key: ValueKey('discover-youtube-inspecting-progress'),
            minHeight: 2,
          ),
        if (error?.trim().isNotEmpty == true) _errorBanner(error!),
        const Divider(height: 1, color: kBorder),
        Expanded(
          child: info == null ? _buildLanding() : _buildDownloadOptions(info),
        ),
      ],
    );
  }

  Widget _buildLanding() {
    return Center(
      key: const ValueKey('discover-youtube-empty'),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(26),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: kAccent.withValues(alpha: 0.11),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: kAccent.withValues(alpha: 0.24)),
                ),
                child: const Icon(
                  Icons.smart_display_outlined,
                  color: kAccent,
                  size: 34,
                ),
              ),
              const SizedBox(height: 15),
              const Text(
                'Inspect a YouTube link',
                style: TextStyle(
                  color: kTextPrimary,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 7),
              const Text(
                'Choose video quality, container, or audio-only output before downloading. High-quality video may require separate audio and video streams to be merged.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: kTextSecondary,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 15),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: kWarning.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: kWarning.withValues(alpha: 0.3)),
                ),
                child: const Padding(
                  padding: EdgeInsets.all(12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.gavel_outlined, color: kWarning, size: 18),
                      SizedBox(width: 9),
                      Expanded(
                        child: Text(
                          'Only download media you own, have permission to use, or are otherwise legally allowed to download.',
                          style: TextStyle(
                            color: kTextPrimary,
                            fontSize: 11,
                            height: 1.35,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDownloadOptions(YoutubeVideoInfo info) {
    final formats = _formatsForSelectedKind(info);
    final selectedFormat = _selectedFormat(info);
    final activeDownload = _latestActiveDownload(info);
    return ListView(
      key: const ValueKey('discover-youtube-options'),
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      children: [
        _videoCard(info),
        const SizedBox(height: 16),
        const Text(
          'Download type',
          style: TextStyle(
            color: kTextPrimary,
            fontSize: 12,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 7,
          runSpacing: 7,
          children: [
            for (final kind in _availableKinds(info))
              ChoiceChip(
                key: ValueKey('discover-youtube-kind-${kind.name}'),
                selected: _selectedKind == kind,
                onSelected: (_) => _selectKind(kind, info),
                avatar: Icon(_kindIcon(kind), size: 16),
                label: Text(_kindLabel(kind)),
              ),
          ],
        ),
        const SizedBox(height: 15),
        DropdownButtonFormField<String>(
          // Recreate the form field when its option group changes; otherwise
          // FormFieldState can retain a value that is absent from the new
          // kind's menu after switching video/audio modes.
          key: ValueKey(
            'discover-youtube-format-${_selectedKind?.name ?? 'all'}',
          ),
          initialValue: formats.any((format) => format.id == _selectedFormatId)
              ? _selectedFormatId
              : null,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Quality and container',
            prefixIcon: Icon(Icons.high_quality_outlined, size: 20),
          ),
          items: [
            for (final format in formats)
              DropdownMenuItem(
                value: format.id,
                child: Text(
                  _formatMenuLabel(format),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: widget.isEnqueuing
              ? null
              : (id) => setState(() => _selectedFormatId = id),
        ),
        if (selectedFormat != null) ...[
          const SizedBox(height: 10),
          _formatDetails(selectedFormat),
        ],
        const SizedBox(height: 15),
        TextField(
          key: const ValueKey('discover-youtube-filename'),
          controller: _fileNameController,
          textInputAction: TextInputAction.done,
          maxLength: 100,
          decoration: const InputDecoration(
            labelText: 'Output name (optional)',
            prefixIcon: Icon(Icons.drive_file_rename_outline_rounded, size: 20),
            counterText: '',
          ),
        ),
        const SizedBox(height: 9),
        CheckboxListTile(
          key: const ValueKey('discover-youtube-permission'),
          value: widget.permittedContentAcknowledged,
          onChanged: widget.isEnqueuing
              ? null
              : (value) => widget.onAcknowledgementChanged(value == true),
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
          title: const Text(
            'I own this media or have permission to download and use it.',
            style: TextStyle(
              color: kTextPrimary,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          subtitle: const Text(
            'Downloads must follow the creator’s rights, YouTube’s terms, and applicable law.',
            style: TextStyle(color: kTextSecondary, fontSize: 10),
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            key: const ValueKey('discover-youtube-download'),
            onPressed:
                widget.isEnqueuing ||
                    selectedFormat == null ||
                    !widget.permittedContentAcknowledged
                ? null
                : () => unawaited(_enqueue(info, selectedFormat)),
            icon: widget.isEnqueuing
                ? const SizedBox.square(
                    dimension: 17,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: kOnAccent,
                    ),
                  )
                : const Icon(Icons.download_rounded, size: 19),
            label: Text(
              widget.isEnqueuing
                  ? 'Adding download…'
                  : 'Download ${selectedFormat == null ? '' : _kindButtonLabel(selectedFormat.kind)}',
            ),
          ),
        ),
        if (activeDownload != null) ...[
          const SizedBox(height: 15),
          _activeDownloadCard(activeDownload),
        ],
      ],
    );
  }

  Widget _videoCard(YoutubeVideoInfo info) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(11),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 124,
                height: 70,
                child: info.thumbnailUrl?.trim().isNotEmpty == true
                    ? Image.network(
                        info.thumbnailUrl!,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => _thumbnailPlaceholder(),
                      )
                    : _thumbnailPlaceholder(),
              ),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    info.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: kTextPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    info.author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: kTextSecondary, fontSize: 10),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${_formatDuration(info.duration)} • ${info.formats.length} options',
                    style: const TextStyle(color: kTextSecondary, fontSize: 10),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _thumbnailPlaceholder() {
    return const ColoredBox(
      color: kSurfaceHigh,
      child: Center(
        child: Icon(
          Icons.smart_display_outlined,
          color: kTextSecondary,
          size: 30,
        ),
      ),
    );
  }

  Widget _formatDetails(YoutubeFormatOption format) {
    final details = <String>[
      format.container.toUpperCase(),
      if (format.resolutionLabel?.trim().isNotEmpty == true)
        format.resolutionLabel!,
      if (format.framesPerSecond case final fps? when fps > 0) '$fps fps',
      if (format.bitrate case final bitrate? when bitrate > 0)
        '${(bitrate / 1000).round()} kbps',
      if (format.estimatedBytes case final bytes? when bytes > 0)
        _formatBytes(bytes),
    ];
    final codecs = <String>[
      if (format.videoCodec?.trim().isNotEmpty == true) format.videoCodec!,
      if (format.audioCodec?.trim().isNotEmpty == true) format.audioCodec!,
    ];
    return Container(
      key: const ValueKey('discover-youtube-format-details'),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
      decoration: BoxDecoration(
        color: kSurfaceElevated,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: kBorder),
      ),
      child: Row(
        children: [
          Icon(_kindIcon(format.kind), color: kAccent, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  details.join(' • '),
                  style: const TextStyle(
                    color: kTextPrimary,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (codecs.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    codecs.join(' + '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: kTextSecondary, fontSize: 9),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _activeDownloadCard(DiscoverDownloadItem item) {
    final indeterminate =
        !item.hasKnownProgress &&
        item.status != DiscoverDownloadStatus.completed;
    return Container(
      key: const ValueKey('discover-youtube-active-download'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: kAccent.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: kAccent.withValues(alpha: 0.24)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _downloadStatusLabel(item.status),
                  style: const TextStyle(
                    color: kTextPrimary,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (!item.isTerminal)
                TextButton.icon(
                  key: ValueKey('discover-youtube-cancel-${item.id}'),
                  onPressed: () => unawaited(widget.onCancel(item.id)),
                  icon: const Icon(Icons.close_rounded, size: 16),
                  label: const Text('Cancel'),
                ),
            ],
          ),
          const SizedBox(height: 7),
          LinearProgressIndicator(
            value: indeterminate ? null : item.progress,
            minHeight: 4,
            borderRadius: BorderRadius.circular(999),
          ),
          const SizedBox(height: 5),
          Text(
            item.hasKnownProgress
                ? '${_formatBytes(item.receivedBytes)} of ${_formatBytes(item.totalBytes!)}'
                : item.receivedBytes > 0
                ? _formatBytes(item.receivedBytes)
                : 'Preparing…',
            style: const TextStyle(color: kTextSecondary, fontSize: 9),
          ),
        ],
      ),
    );
  }

  Widget _errorBanner(String error) {
    return Container(
      key: const ValueKey('discover-youtube-error'),
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 10),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
      decoration: BoxDecoration(
        color: kError.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kError.withValues(alpha: 0.45)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded, color: kError, size: 17),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              error,
              style: const TextStyle(color: kTextPrimary, fontSize: 11),
            ),
          ),
          if (_localError != null)
            IconButton(
              tooltip: 'Dismiss',
              visualDensity: VisualDensity.compact,
              onPressed: () => setState(() => _localError = null),
              icon: const Icon(Icons.close_rounded, size: 17),
            ),
        ],
      ),
    );
  }

  Future<void> _inspect() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      setState(() => _localError = 'Paste a YouTube URL first.');
      return;
    }
    setState(() => _localError = null);
    try {
      await widget.onInspect(url);
    } catch (error) {
      if (!mounted) return;
      setState(() => _localError = _friendlyError(error));
    }
  }

  Future<void> _enqueue(
    YoutubeVideoInfo info,
    YoutubeFormatOption format,
  ) async {
    setState(() => _localError = null);
    try {
      final name = _fileNameController.text.trim();
      await widget.onEnqueue(info, format, name.isEmpty ? null : name);
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text('YouTube download added. Track it in Downloads.'),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _localError = _friendlyError(error));
    }
  }

  void _resolveInitialSelection(YoutubeVideoInfo? info) {
    final formats = info?.formats ?? const <YoutubeFormatOption>[];
    if (formats.isEmpty) {
      _selectedKind = null;
      _selectedFormatId = null;
      return;
    }
    final preferred = formats.where(
      (format) => format.kind == YoutubeDownloadKind.splitVideoAudio,
    );
    final selected = preferred.isNotEmpty ? preferred.first : formats.first;
    _selectedKind = selected.kind;
    _selectedFormatId = selected.id;
  }

  void _ensureSelectionIsAvailable() {
    final info = widget.videoInfo;
    if (info == null || info.formats.isEmpty) return;
    final selected = info.formats.where(
      (format) => format.id == _selectedFormatId,
    );
    if (selected.isNotEmpty) return;
    _resolveInitialSelection(info);
  }

  void _selectKind(YoutubeDownloadKind kind, YoutubeVideoInfo info) {
    final formats = info.formats
        .where((format) => format.kind == kind)
        .toList();
    if (formats.isEmpty) return;
    setState(() {
      _selectedKind = kind;
      _selectedFormatId = formats.first.id;
    });
  }

  List<YoutubeFormatOption> _formatsForSelectedKind(YoutubeVideoInfo info) {
    final kind = _selectedKind;
    if (kind == null) return info.formats;
    return info.formats
        .where((format) => format.kind == kind)
        .toList(growable: false);
  }

  YoutubeFormatOption? _selectedFormat(YoutubeVideoInfo info) {
    for (final format in info.formats) {
      if (format.id == _selectedFormatId) return format;
    }
    return null;
  }

  List<YoutubeDownloadKind> _availableKinds(YoutubeVideoInfo info) {
    return YoutubeDownloadKind.values
        .where((kind) => info.formats.any((format) => format.kind == kind))
        .toList(growable: false);
  }

  DiscoverDownloadItem? _latestActiveDownload(YoutubeVideoInfo info) {
    for (final item in widget.downloads) {
      if (item.source == DiscoverDownloadSource.youtube &&
          item.sourceUrl == info.canonicalUrl &&
          !item.isTerminal) {
        return item;
      }
    }
    return null;
  }

  IconData _kindIcon(YoutubeDownloadKind kind) => switch (kind) {
    YoutubeDownloadKind.muxedVideo => Icons.movie_outlined,
    YoutubeDownloadKind.splitVideoAudio => Icons.high_quality_outlined,
    YoutubeDownloadKind.audioOnly => Icons.audio_file_outlined,
  };

  String _kindLabel(YoutubeDownloadKind kind) => switch (kind) {
    YoutubeDownloadKind.muxedVideo => 'Standard video',
    YoutubeDownloadKind.splitVideoAudio => 'High quality',
    YoutubeDownloadKind.audioOnly => 'Audio only',
  };

  String _kindButtonLabel(YoutubeDownloadKind kind) => switch (kind) {
    YoutubeDownloadKind.muxedVideo ||
    YoutubeDownloadKind.splitVideoAudio => 'video',
    YoutubeDownloadKind.audioOnly => 'audio',
  };

  String _formatMenuLabel(YoutubeFormatOption format) {
    final parts = <String>[format.label];
    if (!format.label.toLowerCase().contains(format.container.toLowerCase())) {
      parts.add(format.container.toUpperCase());
    }
    if (format.estimatedBytes case final bytes? when bytes > 0) {
      parts.add(_formatBytes(bytes));
    }
    return parts.join(' • ');
  }

  String _downloadStatusLabel(DiscoverDownloadStatus status) =>
      switch (status) {
        DiscoverDownloadStatus.queued => 'Waiting to start',
        DiscoverDownloadStatus.downloading => 'Downloading',
        DiscoverDownloadStatus.processing => 'Merging and preparing media',
        DiscoverDownloadStatus.completed => 'Download complete',
        DiscoverDownloadStatus.failed => 'Download failed',
        DiscoverDownloadStatus.cancelled => 'Download cancelled',
      };

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0
        ? '$hours:$minutes:$seconds'
        : '${duration.inMinutes}:$seconds';
  }

  String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '$bytes B';
  }

  String _friendlyError(Object error) => error
      .toString()
      .replaceFirst(RegExp(r'^(Exception|StateError|ArgumentError):\s*'), '')
      .trim();
}
