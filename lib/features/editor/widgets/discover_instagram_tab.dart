import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../models/discover_models.dart';

typedef InspectInstagramCallback = Future<void> Function(String url);
typedef EnqueueInstagramCallback =
    Future<void> Function(
      InstagramPostInfo info,
      InstagramMediaOption media,
      String? outputFileName,
    );

class DiscoverInstagramTab extends StatefulWidget {
  const DiscoverInstagramTab({
    super.key,
    required this.postInfo,
    required this.downloads,
    required this.isInspecting,
    required this.isEnqueuing,
    required this.permittedContentAcknowledged,
    required this.onInspect,
    required this.onEnqueue,
    required this.onAcknowledgementChanged,
    required this.onCancel,
    this.errorMessage,
  });

  final InstagramPostInfo? postInfo;
  final List<DiscoverDownloadItem> downloads;
  final bool isInspecting;
  final bool isEnqueuing;
  final bool permittedContentAcknowledged;
  final String? errorMessage;
  final InspectInstagramCallback onInspect;
  final EnqueueInstagramCallback onEnqueue;
  final ValueChanged<bool> onAcknowledgementChanged;
  final Future<void> Function(String id) onCancel;

  @override
  State<DiscoverInstagramTab> createState() => _DiscoverInstagramTabState();
}

class _DiscoverInstagramTabState extends State<DiscoverInstagramTab>
    with AutomaticKeepAliveClientMixin {
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _fileNameController = TextEditingController();
  String? _selectedMediaId;
  String? _localError;

  @override
  bool get wantKeepAlive => true;

  @override
  void didUpdateWidget(covariant DiscoverInstagramTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    final current = widget.postInfo;
    if (current?.shortcode != oldWidget.postInfo?.shortcode) {
      _selectedMediaId = current?.media.firstOrNull?.id;
      if (current != null) {
        _fileNameController.text = current.title;
      }
    } else if (current != null &&
        !current.media.any((media) => media.id == _selectedMediaId)) {
      _selectedMediaId = current.media.firstOrNull?.id;
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
    final info = widget.postInfo;
    final activeDownload = info == null
        ? null
        : widget.downloads
              .where(
                (item) =>
                    item.source == DiscoverDownloadSource.instagram &&
                    item.sourceUrl == info.canonicalUrl &&
                    !item.isTerminal,
              )
              .firstOrNull;
    return ListView(
      key: const ValueKey('discover-instagram-tab'),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
      children: [
        const Text(
          'Instagram',
          style: TextStyle(
            color: kTextPrimary,
            fontSize: 20,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 5),
        const Text(
          'Inspect a supported public Reel or post, choose its media, and send it to Downloads.',
          style: TextStyle(color: kTextSecondary, fontSize: 12, height: 1.35),
        ),
        const SizedBox(height: 14),
        TextField(
          key: const ValueKey('discover-instagram-url'),
          controller: _urlController,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.go,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: 'Instagram link',
            hintText: 'https://www.instagram.com/reel/…',
            prefixIcon: const Icon(Icons.link_rounded),
            suffixIcon: _urlController.text.isEmpty
                ? null
                : IconButton(
                    onPressed: () => setState(_urlController.clear),
                    icon: const Icon(Icons.clear_rounded),
                  ),
          ),
          onChanged: (_) => setState(() => _localError = null),
          onSubmitted: (_) => unawaited(_inspect()),
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            key: const ValueKey('discover-instagram-inspect'),
            onPressed: widget.isInspecting ? null : _inspect,
            icon: widget.isInspecting
                ? const SizedBox.square(
                    dimension: 17,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.search_rounded),
            label: Text(widget.isInspecting ? 'Inspecting…' : 'Inspect link'),
          ),
        ),
        if (widget.isInspecting) ...[
          const SizedBox(height: 10),
          const LinearProgressIndicator(
            key: ValueKey('discover-instagram-inspecting-progress'),
          ),
        ],
        const SizedBox(height: 18),
        if (info == null && !widget.isInspecting) _emptyState(),
        if (info != null) ...[
          _postCard(info),
          const SizedBox(height: 14),
          _mediaPicker(info),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('discover-instagram-filename'),
            controller: _fileNameController,
            maxLength: 120,
            decoration: const InputDecoration(
              labelText: 'File name',
              counterText: '',
            ),
          ),
          CheckboxListTile(
            key: const ValueKey('discover-instagram-permission'),
            contentPadding: EdgeInsets.zero,
            value: widget.permittedContentAcknowledged,
            onChanged: (value) =>
                widget.onAcknowledgementChanged(value ?? false),
            title: const Text(
              'I own this media or have permission to download it',
              style: TextStyle(color: kTextPrimary, fontSize: 12),
            ),
            subtitle: const Text(
              'Downloads must follow the creator’s rights, Instagram’s terms, and applicable law.',
              style: TextStyle(color: kTextSecondary, fontSize: 10),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: const ValueKey('discover-instagram-download'),
              onPressed:
                  widget.isEnqueuing ||
                      !widget.permittedContentAcknowledged ||
                      _selectedMedia(info) == null
                  ? null
                  : () => _enqueue(info),
              icon: widget.isEnqueuing
                  ? const SizedBox.square(
                      dimension: 17,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.download_rounded),
              label: Text(
                widget.isEnqueuing ? 'Adding to Downloads…' : 'Download media',
              ),
            ),
          ),
        ],
        if (activeDownload != null) ...[
          const SizedBox(height: 14),
          _activeDownload(activeDownload),
        ],
        if ((_localError ?? widget.errorMessage)?.isNotEmpty == true) ...[
          const SizedBox(height: 12),
          _errorCard(_localError ?? widget.errorMessage!),
        ],
      ],
    );
  }

  Widget _emptyState() {
    return Container(
      key: const ValueKey('discover-instagram-empty'),
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: kSurfaceElevated,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: kBorder),
      ),
      child: const Column(
        children: [
          Icon(Icons.camera_alt_outlined, color: kTextSecondary, size: 34),
          SizedBox(height: 10),
          Text(
            'Paste an Instagram Reel or post link',
            textAlign: TextAlign.center,
            style: TextStyle(color: kTextPrimary, fontWeight: FontWeight.w700),
          ),
          SizedBox(height: 5),
          Text(
            'Public media exposed by Instagram can be inspected without leaving the editor.',
            textAlign: TextAlign.center,
            style: TextStyle(color: kTextSecondary, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _postCard(InstagramPostInfo info) {
    return Container(
      key: const ValueKey('discover-instagram-info'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: kSurfaceElevated,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: kBorder),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox.square(
              dimension: 72,
              child: info.thumbnailUrl == null
                  ? const ColoredBox(
                      color: kSurface,
                      child: Icon(Icons.photo_outlined, color: kTextSecondary),
                    )
                  : Image.network(
                      info.thumbnailUrl!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const ColoredBox(
                        color: kSurface,
                        child: Icon(
                          Icons.broken_image_outlined,
                          color: kTextSecondary,
                        ),
                      ),
                    ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  info.title,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: kTextPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  '${info.isReel ? 'Reel' : 'Post'} • ${info.author} • ${info.media.length} media item${info.media.length == 1 ? '' : 's'}',
                  style: const TextStyle(color: kTextSecondary, fontSize: 10),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _mediaPicker(InstagramPostInfo info) {
    return Container(
      key: const ValueKey('discover-instagram-options'),
      decoration: BoxDecoration(
        color: kSurfaceElevated,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kBorder),
      ),
      child: RadioGroup<String>(
        groupValue: _selectedMediaId,
        onChanged: (value) => setState(() => _selectedMediaId = value),
        child: Column(
          children: [
            for (final entry in info.media.indexed)
              RadioListTile<String>(
                key: ValueKey('discover-instagram-media-${entry.$2.id}'),
                value: entry.$2.id,
                secondary: Icon(
                  entry.$2.kind == DiscoverMediaKind.video
                      ? Icons.movie_outlined
                      : Icons.image_outlined,
                  color: kAccent,
                ),
                title: Text(
                  entry.$2.kind == DiscoverMediaKind.video
                      ? 'Video ${entry.$1 + 1}'
                      : 'Image ${entry.$1 + 1}',
                  style: const TextStyle(color: kTextPrimary, fontSize: 12),
                ),
                subtitle: Text(
                  entry.$2.mimeType ?? entry.$2.kind.name,
                  style: const TextStyle(color: kTextSecondary, fontSize: 10),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _activeDownload(DiscoverDownloadItem item) {
    return Container(
      key: const ValueKey('discover-instagram-active-download'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: kAccent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kAccent.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              item.hasKnownProgress
                  ? 'Downloading • ${(item.progress * 100).round()}%'
                  : 'Downloading Instagram media…',
              style: const TextStyle(color: kTextPrimary, fontSize: 11),
            ),
          ),
          IconButton(
            key: ValueKey('discover-instagram-cancel-${item.id}'),
            tooltip: 'Cancel download',
            onPressed: () => widget.onCancel(item.id),
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
    );
  }

  Widget _errorCard(String message) {
    return Container(
      key: const ValueKey('discover-instagram-error'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: kError.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kError.withValues(alpha: 0.35)),
      ),
      child: Text(message, style: const TextStyle(color: kError, fontSize: 11)),
    );
  }

  Future<void> _inspect() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      setState(() => _localError = 'Paste an Instagram URL first.');
      return;
    }
    setState(() => _localError = null);
    try {
      await widget.onInspect(url);
    } catch (error) {
      if (mounted) setState(() => _localError = _friendlyError(error));
    }
  }

  Future<void> _enqueue(InstagramPostInfo info) async {
    final media = _selectedMedia(info);
    if (media == null) return;
    setState(() => _localError = null);
    try {
      final fileName = _fileNameController.text.trim();
      await widget.onEnqueue(info, media, fileName.isEmpty ? null : fileName);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Instagram download added. Track it in Downloads.'),
          ),
        );
      }
    } catch (error) {
      if (mounted) setState(() => _localError = _friendlyError(error));
    }
  }

  InstagramMediaOption? _selectedMedia(InstagramPostInfo info) {
    return info.media
        .where((media) => media.id == _selectedMediaId)
        .firstOrNull;
  }

  String _friendlyError(Object error) => error
      .toString()
      .replaceFirst(RegExp(r'^(Exception|StateError|FormatException):\s*'), '')
      .trim();
}
