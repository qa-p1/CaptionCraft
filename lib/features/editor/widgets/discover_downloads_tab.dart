import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../models/discover_models.dart';

typedef DiscoverDownloadItemCallback =
    Future<void> Function(DiscoverDownloadItem item);
typedef DiscoverDownloadIdCallback = Future<void> Function(String id);
typedef DiscoverDownloadOpenCallback = Future<bool> Function(String id);

/// Persistent download queue used by Discover.
///
/// Navigation remains owned by [DiscoverSheet], which closes only after a
/// completed item has been inserted successfully.
class DiscoverDownloadsTab extends StatefulWidget {
  final List<DiscoverDownloadItem> downloads;
  final bool isInitialized;
  final String? errorMessage;
  final DiscoverDownloadItemCallback onAddToTimeline;
  final DiscoverDownloadIdCallback onCancel;
  final DiscoverDownloadIdCallback onRetry;
  final DiscoverDownloadIdCallback onDelete;
  final DiscoverDownloadOpenCallback onOpen;

  const DiscoverDownloadsTab({
    super.key,
    required this.downloads,
    required this.isInitialized,
    required this.onAddToTimeline,
    required this.onCancel,
    required this.onRetry,
    required this.onDelete,
    required this.onOpen,
    this.errorMessage,
  });

  @override
  State<DiscoverDownloadsTab> createState() => _DiscoverDownloadsTabState();
}

class _DiscoverDownloadsTabState extends State<DiscoverDownloadsTab>
    with AutomaticKeepAliveClientMixin {
  final Set<String> _busyItems = <String>{};
  String? _localError;

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final error = _localError ?? widget.errorMessage;
    return Column(
      key: const ValueKey('discover-downloads-tab'),
      children: [
        _buildSummary(),
        if (error?.trim().isNotEmpty == true) _buildError(error!),
        const Divider(height: 1, color: kBorder),
        Expanded(child: _buildBody()),
      ],
    );
  }

  Widget _buildSummary() {
    final active = widget.downloads.where((item) => !item.isTerminal).length;
    final ready = widget.downloads.where((item) => item.canImport).length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      child: Row(
        children: [
          const Icon(Icons.download_for_offline_outlined, color: kAccent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Download manager',
                  style: TextStyle(
                    color: kTextPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  active > 0
                      ? '$active active • $ready ready to add'
                      : '$ready ready to add • ${widget.downloads.length} total',
                  style: const TextStyle(color: kTextSecondary, fontSize: 10),
                ),
              ],
            ),
          ),
          if (active > 0)
            Badge(
              key: const ValueKey('discover-downloads-active-badge'),
              label: Text('$active'),
              backgroundColor: kAccent,
              child: const Icon(Icons.downloading_rounded, color: kTextPrimary),
            ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (!widget.isInitialized && widget.downloads.isEmpty) {
      return const Center(
        key: ValueKey('discover-downloads-loading'),
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    if (widget.downloads.isEmpty) {
      return const Center(
        key: ValueKey('discover-downloads-empty'),
        child: Padding(
          padding: EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.cloud_download_outlined,
                size: 48,
                color: kTextSecondary,
              ),
              SizedBox(height: 12),
              Text(
                'No downloads yet',
                style: TextStyle(
                  color: kTextPrimary,
                  fontWeight: FontWeight.w800,
                ),
              ),
              SizedBox(height: 5),
              Text(
                'Save media from Browser, YouTube, or Instagram, then add completed items directly to the timeline here.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: kTextSecondary,
                  fontSize: 11,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final ordered = [...widget.downloads]
      ..sort((a, b) {
        final aActive = !a.isTerminal;
        final bActive = !b.isTerminal;
        if (aActive != bActive) return aActive ? -1 : 1;
        return b.updatedAt.compareTo(a.updatedAt);
      });
    return ListView.separated(
      key: const ValueKey('discover-download-list'),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      itemCount: ordered.length,
      separatorBuilder: (_, _) => const SizedBox(height: 9),
      itemBuilder: (context, index) => _buildDownloadCard(ordered[index]),
    );
  }

  Widget _buildDownloadCard(DiscoverDownloadItem item) {
    final busy = _busyItems.contains(item.id);
    final showProgress = const <DiscoverDownloadStatus>{
      DiscoverDownloadStatus.queued,
      DiscoverDownloadStatus.downloading,
      DiscoverDownloadStatus.processing,
    }.contains(item.status);
    return Card(
      key: ValueKey('discover-download-${item.id}'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _mediaIcon(item),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.displayName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: kTextPrimary,
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${_sourceLabel(item.source)} • ${item.fileName}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: kTextSecondary,
                          fontSize: 9,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _statusPill(item.status),
              ],
            ),
            if (showProgress) ...[
              const SizedBox(height: 11),
              LinearProgressIndicator(
                key: ValueKey('discover-download-progress-${item.id}'),
                value: item.hasKnownProgress ? item.progress : null,
                minHeight: 4,
                borderRadius: BorderRadius.circular(999),
              ),
              const SizedBox(height: 5),
              Text(
                _progressLabel(item),
                style: const TextStyle(color: kTextSecondary, fontSize: 9),
              ),
            ],
            if (item.errorMessage?.trim().isNotEmpty == true) ...[
              const SizedBox(height: 9),
              Text(
                item.errorMessage!,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: kError,
                  fontSize: 10,
                  height: 1.3,
                ),
              ),
            ],
            const SizedBox(height: 9),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              alignment: WrapAlignment.end,
              children: [
                if (!item.isTerminal)
                  _smallAction(
                    key: ValueKey('discover-download-cancel-${item.id}'),
                    label: 'Cancel',
                    icon: Icons.close_rounded,
                    onPressed: busy
                        ? null
                        : () => _run(item.id, widget.onCancel),
                  ),
                if (item.canRetry)
                  _smallAction(
                    key: ValueKey('discover-download-retry-${item.id}'),
                    label: 'Retry',
                    icon: Icons.refresh_rounded,
                    onPressed: busy
                        ? null
                        : () => _run(item.id, widget.onRetry),
                  ),
                if (item.canImport)
                  _smallAction(
                    key: ValueKey('discover-download-open-${item.id}'),
                    label: 'Open',
                    icon: Icons.open_in_new_rounded,
                    onPressed: busy ? null : () => _open(item.id),
                  ),
                _smallAction(
                  key: ValueKey('discover-download-delete-${item.id}'),
                  label: 'Delete',
                  icon: Icons.delete_outline_rounded,
                  foregroundColor: kError,
                  onPressed: busy ? null : () => _confirmDelete(item),
                ),
                if (item.canImport)
                  FilledButton.icon(
                    key: ValueKey('discover-download-add-${item.id}'),
                    onPressed: busy ? null : () => _addToTimeline(item),
                    icon: busy
                        ? const SizedBox.square(
                            dimension: 15,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: kOnAccent,
                            ),
                          )
                        : const Icon(Icons.add_rounded, size: 17),
                    label: const Text('Add to timeline'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _mediaIcon(DiscoverDownloadItem item) {
    final (icon, color) = switch (item.kind) {
      DiscoverMediaKind.image => (Icons.image_outlined, kInfo),
      DiscoverMediaKind.video => (Icons.movie_outlined, kAccent),
      DiscoverMediaKind.audio => (Icons.audio_file_outlined, kAccentSecondary),
      DiscoverMediaKind.unknown => (
        Icons.insert_drive_file_outlined,
        kTextSecondary,
      ),
    };
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Icon(icon, color: color, size: 20),
    );
  }

  Widget _statusPill(DiscoverDownloadStatus status) {
    final (label, color) = switch (status) {
      DiscoverDownloadStatus.queued => ('Queued', kTextSecondary),
      DiscoverDownloadStatus.downloading => ('Downloading', kInfo),
      DiscoverDownloadStatus.processing => ('Processing', kWarning),
      DiscoverDownloadStatus.completed => ('Ready', kSuccess),
      DiscoverDownloadStatus.failed => ('Failed', kError),
      DiscoverDownloadStatus.cancelled => ('Cancelled', kTextSecondary),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.32)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 8,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  Widget _smallAction({
    required Key key,
    required String label,
    required IconData icon,
    required VoidCallback? onPressed,
    Color? foregroundColor,
  }) {
    return TextButton.icon(
      key: key,
      onPressed: onPressed,
      style: foregroundColor == null
          ? null
          : TextButton.styleFrom(foregroundColor: foregroundColor),
      icon: Icon(icon, size: 16),
      label: Text(label),
    );
  }

  Widget _buildError(String error) {
    return Container(
      key: const ValueKey('discover-downloads-error'),
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 10),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
      decoration: BoxDecoration(
        color: kError.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kError.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded, color: kError, size: 17),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              error,
              style: const TextStyle(color: kTextPrimary, fontSize: 10),
            ),
          ),
          if (_localError != null)
            IconButton(
              tooltip: 'Dismiss',
              visualDensity: VisualDensity.compact,
              onPressed: () => setState(() => _localError = null),
              icon: const Icon(Icons.close_rounded, size: 16),
            ),
        ],
      ),
    );
  }

  Future<void> _run(String id, DiscoverDownloadIdCallback callback) async {
    setState(() {
      _busyItems.add(id);
      _localError = null;
    });
    try {
      await callback(id);
    } catch (error) {
      if (mounted) setState(() => _localError = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _busyItems.remove(id));
    }
  }

  Future<void> _open(String id) async {
    setState(() {
      _busyItems.add(id);
      _localError = null;
    });
    try {
      final opened = await widget.onOpen(id);
      if (!opened && mounted) {
        setState(
          () => _localError = 'The downloaded file could not be opened.',
        );
      }
    } catch (error) {
      if (mounted) setState(() => _localError = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _busyItems.remove(id));
    }
  }

  Future<void> _addToTimeline(DiscoverDownloadItem item) async {
    setState(() {
      _busyItems.add(item.id);
      _localError = null;
    });
    try {
      await widget.onAddToTimeline(item);
    } catch (error) {
      if (mounted) setState(() => _localError = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _busyItems.remove(item.id));
    }
  }

  Future<void> _confirmDelete(DiscoverDownloadItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete download?'),
        content: Text(
          item.canImport
              ? 'This removes ${item.fileName} from this device.'
              : 'This removes the download from the queue.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep'),
          ),
          FilledButton(
            key: const ValueKey('discover-confirm-delete'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(backgroundColor: kError),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) await _run(item.id, widget.onDelete);
  }

  String _progressLabel(DiscoverDownloadItem item) {
    if (item.status == DiscoverDownloadStatus.processing) {
      return 'Preparing the final media file…';
    }
    if (item.hasKnownProgress) {
      return '${_formatBytes(item.receivedBytes)} of ${_formatBytes(item.totalBytes!)} • ${(item.progress * 100).round()}%';
    }
    return item.receivedBytes > 0
        ? '${_formatBytes(item.receivedBytes)} downloaded'
        : 'Waiting for size information…';
  }

  String _sourceLabel(DiscoverDownloadSource source) => switch (source) {
    DiscoverDownloadSource.direct => 'Browser',
    DiscoverDownloadSource.youtube => 'YouTube',
    DiscoverDownloadSource.instagram => 'Instagram',
  };

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
