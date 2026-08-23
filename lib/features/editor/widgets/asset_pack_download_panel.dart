import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// Shared destructive action for installed background, overlay, and sound
/// libraries. It owns confirmation and feedback so every pack behaves the same.
class AssetPackRemoveButton extends StatefulWidget {
  const AssetPackRemoveButton({
    super.key,
    required this.packId,
    required this.title,
    required this.onRemove,
    this.isRemoving = false,
  });

  final String packId;
  final String title;
  final Future<void> Function() onRemove;
  final bool isRemoving;

  @override
  State<AssetPackRemoveButton> createState() => _AssetPackRemoveButtonState();
}

class _AssetPackRemoveButtonState extends State<AssetPackRemoveButton> {
  bool _isSubmitting = false;

  bool get _isBusy => widget.isRemoving || _isSubmitting;

  Future<void> _confirmAndRemove() async {
    if (_isBusy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Remove ${widget.title}?'),
        content: const Text(
          'The downloaded library will be removed from this device. '
          'CaptionCraft will refuse to remove it while any current or saved '
          'project still uses one of its assets.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep library'),
          ),
          FilledButton(
            key: ValueKey('asset-pack-confirm-remove-${widget.packId}'),
            style: FilledButton.styleFrom(backgroundColor: kError),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Remove download'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _isSubmitting = true);
    try {
      await widget.onRemove();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text('${widget.title} removed from this device.')),
        );
    } catch (error) {
      if (!mounted) return;
      final message = error
          .toString()
          .replaceFirst(
            RegExp(r'^(?:Exception|AssetPackException|Bad state):\s*'),
            '',
          )
          .trim();
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              message.isEmpty ? 'This library could not be removed.' : message,
            ),
          ),
        );
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Remove downloaded ${widget.title}',
      child: IconButton(
        key: ValueKey('asset-pack-remove-${widget.packId}'),
        onPressed: _isBusy ? null : _confirmAndRemove,
        tooltip: _isBusy ? 'Removing download' : 'Remove download',
        color: kError,
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.all(2),
        constraints: const BoxConstraints.tightFor(width: 24, height: 24),
        style: IconButton.styleFrom(
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          minimumSize: const Size.square(24),
          maximumSize: const Size.square(24),
        ),
        icon: _isBusy
            ? const SizedBox.square(
                dimension: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.delete_outline_rounded, size: 17),
      ),
    );
  }
}

/// Presentation states supported by [AssetPackDownloadPanel].
///
/// This intentionally stays independent of the asset-pack provider. A sheet can
/// map its manager snapshot into this small view model without making the UI
/// responsible for the lifetime of a download.
enum AssetPackPanelStage {
  available,
  queued,
  preparing,
  downloading,
  verifying,
  extracting,
  installing,
  stopping,
  cancelled,
  failed,
  installed,
}

@immutable
class AssetPackDownloadViewModel {
  final String packId;
  final String title;
  final String? description;
  final AssetPackPanelStage stage;
  final String? version;
  final int? assetCount;
  final int? downloadBytes;
  final int? temporarySpaceBytes;
  final int receivedBytes;
  final int? totalBytes;
  final int? queuePosition;
  final int? partIndex;
  final int? partCount;
  final String? errorMessage;
  final IconData icon;

  const AssetPackDownloadViewModel({
    required this.packId,
    required this.title,
    required this.stage,
    this.description,
    this.version,
    this.assetCount,
    this.downloadBytes,
    this.temporarySpaceBytes,
    this.receivedBytes = 0,
    this.totalBytes,
    this.queuePosition,
    this.partIndex,
    this.partCount,
    this.errorMessage,
    this.icon = Icons.collections_bookmark_outlined,
  }) : assert(receivedBytes >= 0),
       assert(assetCount == null || assetCount >= 0),
       assert(downloadBytes == null || downloadBytes >= 0),
       assert(temporarySpaceBytes == null || temporarySpaceBytes >= 0),
       assert(totalBytes == null || totalBytes >= 0),
       assert(queuePosition == null || queuePosition > 0),
       assert(partIndex == null || partIndex >= 0),
       assert(partCount == null || partCount > 0),
       assert(partIndex == null || partCount == null || partIndex < partCount);

  bool get isPostProcessing => switch (stage) {
    AssetPackPanelStage.verifying ||
    AssetPackPanelStage.extracting ||
    AssetPackPanelStage.installing => true,
    _ => false,
  };

  bool get canStop => switch (stage) {
    AssetPackPanelStage.queued ||
    AssetPackPanelStage.preparing ||
    AssetPackPanelStage.downloading ||
    AssetPackPanelStage.verifying ||
    AssetPackPanelStage.extracting ||
    AssetPackPanelStage.installing => true,
    _ => false,
  };

  bool get canRetry =>
      stage == AssetPackPanelStage.cancelled ||
      stage == AssetPackPanelStage.failed;

  int? get resolvedTotalBytes => totalBytes ?? downloadBytes;

  double? get progressFraction {
    final total = resolvedTotalBytes;
    if (total == null || total <= 0) return null;
    return (receivedBytes / total).clamp(0, 1).toDouble();
  }
}

/// A responsive, accessible status surface for an on-demand asset pack.
///
/// Download ownership deliberately lives outside this widget. Dismissing the
/// surrounding sheet therefore has no effect on the job; only [onStop] should
/// request cancellation.
class AssetPackDownloadPanel extends StatelessWidget {
  final AssetPackDownloadViewModel model;
  final VoidCallback? onDownload;
  final VoidCallback? onStop;
  final VoidCallback? onRetry;
  final String continuationNote;

  const AssetPackDownloadPanel({
    super.key,
    required this.model,
    this.onDownload,
    this.onStop,
    this.onRetry,
    this.continuationNote =
        'Downloads continue if you close this sheet, while CaptionCraft remains open.',
  });

  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    const units = ['KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var unitIndex = -1;
    do {
      value /= 1024;
      unitIndex++;
    } while (value >= 1024 && unitIndex < units.length - 1);
    return '${value.toStringAsFixed(1)} ${units[unitIndex]}';
  }

  @override
  Widget build(BuildContext context) {
    final visual = _visualFor(model.stage);
    final facts = _facts();

    return SingleChildScrollView(
      key: ValueKey('asset-pack-panel-scroll-${model.packId}'),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 580),
          child: Semantics(
            key: ValueKey('asset-pack-panel-${model.packId}'),
            container: true,
            explicitChildNodes: true,
            label: '${model.title} asset pack',
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: kSurfaceElevated,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: visual.color.withValues(alpha: 0.36)),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x33000000),
                    blurRadius: 24,
                    offset: Offset(0, 10),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(21),
                child: Stack(
                  children: [
                    Positioned(
                      top: -70,
                      right: -55,
                      child: ExcludeSemantics(
                        child: Container(
                          width: 180,
                          height: 180,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: RadialGradient(
                              colors: [
                                visual.color.withValues(alpha: 0.13),
                                Colors.transparent,
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _Header(model: model, visual: visual),
                          const SizedBox(height: 18),
                          _StatusSummary(model: model),
                          if (facts.isNotEmpty) ...[
                            const SizedBox(height: 16),
                            _FactGrid(facts: facts),
                          ],
                          if (_showsProgress) ...[
                            const SizedBox(height: 18),
                            _ProgressSection(model: model, visual: visual),
                          ],
                          if (model.stage == AssetPackPanelStage.failed &&
                              model.errorMessage?.trim().isNotEmpty ==
                                  true) ...[
                            const SizedBox(height: 14),
                            _ErrorMessage(
                              packId: model.packId,
                              message: model.errorMessage!.trim(),
                            ),
                          ],
                          if (_showsContinuationNote) ...[
                            const SizedBox(height: 14),
                            _ContinuationNote(
                              packId: model.packId,
                              text: continuationNote,
                            ),
                          ],
                          if (_showsActions) ...[
                            const SizedBox(height: 18),
                            _buildActions(),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  bool get _showsProgress => switch (model.stage) {
    AssetPackPanelStage.queued ||
    AssetPackPanelStage.preparing ||
    AssetPackPanelStage.downloading ||
    AssetPackPanelStage.verifying ||
    AssetPackPanelStage.extracting ||
    AssetPackPanelStage.installing ||
    AssetPackPanelStage.stopping => true,
    _ => false,
  };

  bool get _showsContinuationNote => switch (model.stage) {
    AssetPackPanelStage.available ||
    AssetPackPanelStage.queued ||
    AssetPackPanelStage.preparing ||
    AssetPackPanelStage.downloading ||
    AssetPackPanelStage.verifying ||
    AssetPackPanelStage.extracting ||
    AssetPackPanelStage.installing => true,
    _ => false,
  };

  bool get _showsActions =>
      model.stage == AssetPackPanelStage.available ||
      model.canStop ||
      model.stage == AssetPackPanelStage.stopping ||
      model.canRetry;

  List<_Fact> _facts() {
    final facts = <_Fact>[];
    final version = model.version?.trim();
    if (version != null && version.isNotEmpty) {
      facts.add(
        _Fact(
          label: 'Version',
          value: version,
          icon: Icons.new_releases_outlined,
        ),
      );
    }
    final assetCount = model.assetCount;
    if (assetCount != null) {
      facts.add(
        _Fact(
          label: 'Assets',
          value: '$assetCount',
          semanticValue: '$assetCount assets',
          icon: Icons.perm_media_outlined,
        ),
      );
    }
    final downloadBytes = model.downloadBytes ?? model.totalBytes;
    if (downloadBytes != null && downloadBytes > 0) {
      facts.add(
        _Fact(
          label: 'Download',
          value: formatBytes(downloadBytes),
          semanticValue:
              '${formatBytes(downloadBytes)}, ${_formatExactBytes(downloadBytes)} bytes',
          icon: Icons.cloud_download_outlined,
        ),
      );
    }
    final temporarySpaceBytes = model.temporarySpaceBytes;
    if (temporarySpaceBytes != null && temporarySpaceBytes > 0) {
      facts.add(
        _Fact(
          label: 'Free space needed',
          value: formatBytes(temporarySpaceBytes),
          semanticValue:
              '${formatBytes(temporarySpaceBytes)}, ${_formatExactBytes(temporarySpaceBytes)} bytes',
          icon: Icons.sd_storage_outlined,
        ),
      );
    }
    return facts;
  }

  Widget _buildActions() {
    Widget button;
    switch (model.stage) {
      case AssetPackPanelStage.available:
        button = FilledButton.icon(
          key: ValueKey('asset-pack-download-${model.packId}'),
          onPressed: onDownload,
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 48),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
          ),
          icon: const Icon(Icons.download_rounded, size: 20),
          label: const Text('Download pack'),
        );
      case AssetPackPanelStage.queued:
      case AssetPackPanelStage.preparing:
      case AssetPackPanelStage.downloading:
      case AssetPackPanelStage.verifying:
      case AssetPackPanelStage.extracting:
      case AssetPackPanelStage.installing:
        button = OutlinedButton.icon(
          key: ValueKey('asset-pack-stop-${model.packId}'),
          onPressed: onStop,
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, 48),
            foregroundColor: kError,
            side: BorderSide(color: kError.withValues(alpha: 0.65)),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
          ),
          icon: const Icon(Icons.stop_circle_outlined, size: 20),
          label: const Text('Stop download'),
        );
      case AssetPackPanelStage.stopping:
        button = OutlinedButton.icon(
          key: ValueKey('asset-pack-stopping-${model.packId}'),
          onPressed: null,
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, 48),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
          ),
          icon: const SizedBox.square(
            dimension: 17,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          label: const Text('Stopping…'),
        );
      case AssetPackPanelStage.cancelled:
      case AssetPackPanelStage.failed:
        button = FilledButton.icon(
          key: ValueKey('asset-pack-retry-${model.packId}'),
          onPressed: onRetry,
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 48),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
          ),
          icon: const Icon(Icons.refresh_rounded, size: 20),
          label: const Text('Retry download'),
        );
      case AssetPackPanelStage.installed:
        return const SizedBox.shrink();
    }
    return SizedBox(width: double.infinity, child: button);
  }

  static String _formatExactBytes(int bytes) {
    final digits = bytes.toString();
    final buffer = StringBuffer();
    for (var index = 0; index < digits.length; index++) {
      if (index > 0 && (digits.length - index) % 3 == 0) buffer.write(',');
      buffer.write(digits[index]);
    }
    return buffer.toString();
  }
}

class _Header extends StatelessWidget {
  final AssetPackDownloadViewModel model;
  final _PanelVisual visual;

  const _Header({required this.model, required this.visual});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ExcludeSemantics(
          child: Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: visual.color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(15),
              border: Border.all(color: visual.color.withValues(alpha: 0.28)),
            ),
            child: Icon(model.icon, color: visual.color, size: 27),
          ),
        ),
        const SizedBox(width: 13),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                model.title,
                style: const TextStyle(
                  color: kTextPrimary,
                  fontSize: 18,
                  height: 1.15,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.2,
                ),
              ),
              const SizedBox(height: 6),
              Semantics(
                key: ValueKey('asset-pack-status-${model.packId}'),
                liveRegion: true,
                label: '${model.title} download status',
                value: visual.statusLabel,
                child: ExcludeSemantics(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: visual.color.withValues(alpha: 0.11),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: visual.color.withValues(alpha: 0.32),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(visual.statusIcon, color: visual.color, size: 14),
                        const SizedBox(width: 5),
                        Flexible(
                          child: Text(
                            visual.statusLabel,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: visual.color,
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                            ),
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
      ],
    );
  }
}

class _StatusSummary extends StatelessWidget {
  final AssetPackDownloadViewModel model;

  const _StatusSummary({required this.model});

  @override
  Widget build(BuildContext context) {
    final defaultDetail = switch (model.stage) {
      AssetPackPanelStage.available =>
        'Downloaded only when you choose, verified before installation, and stored locally.',
      AssetPackPanelStage.queued =>
        model.queuePosition == null
            ? 'Waiting for the current asset pack to finish.'
            : 'Queue position ${model.queuePosition}. It will start automatically.',
      AssetPackPanelStage.preparing =>
        'Checking the release and preparing a secure transfer.',
      AssetPackPanelStage.downloading =>
        'Keep CaptionCraft open while the pack downloads in the background.',
      AssetPackPanelStage.verifying =>
        'Download complete. Checking file integrity before installation.',
      AssetPackPanelStage.extracting =>
        'Download complete. Unpacking verified assets into local storage.',
      AssetPackPanelStage.installing =>
        'Download complete. Making the library ready inside the editor.',
      AssetPackPanelStage.stopping =>
        'Pausing safely. Verified partial data will be kept for Retry.',
      AssetPackPanelStage.cancelled =>
        'The download was stopped. Retry will continue from reusable partial data.',
      AssetPackPanelStage.failed =>
        'Nothing incomplete was installed. Any existing library is unchanged.',
      AssetPackPanelStage.installed =>
        'Installed on this device and ready to use in the editor.',
    };
    final headline = switch (model.stage) {
      AssetPackPanelStage.available => 'Ready when you are',
      AssetPackPanelStage.queued => 'Waiting to download',
      AssetPackPanelStage.preparing => 'Preparing download',
      AssetPackPanelStage.downloading => 'Downloading assets',
      AssetPackPanelStage.verifying => 'Verifying download',
      AssetPackPanelStage.extracting => 'Extracting files',
      AssetPackPanelStage.installing => 'Finishing installation',
      AssetPackPanelStage.stopping => 'Stopping download',
      AssetPackPanelStage.cancelled => 'Download stopped',
      AssetPackPanelStage.failed => 'Download couldn’t finish',
      AssetPackPanelStage.installed => 'Ready to use',
    };
    final description = model.description?.trim();
    final detail = description == null || description.isEmpty
        ? defaultDetail
        : description;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          headline,
          style: const TextStyle(
            color: kTextPrimary,
            fontSize: 15,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          detail,
          style: const TextStyle(
            color: kTextSecondary,
            fontSize: 12,
            height: 1.45,
          ),
        ),
      ],
    );
  }
}

class _FactGrid extends StatelessWidget {
  final List<_Fact> facts;

  const _FactGrid({required this.facts});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 500
            ? 4
            : constraints.maxWidth >= 250
            ? 2
            : 1;
        const spacing = 8.0;
        final itemWidth =
            (constraints.maxWidth - (spacing * (columns - 1))) / columns;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final fact in facts)
              SizedBox(
                width: itemWidth,
                child: _FactTile(fact: fact),
              ),
          ],
        );
      },
    );
  }
}

class _FactTile extends StatelessWidget {
  final _Fact fact;

  const _FactTile({required this.fact});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: fact.label,
      value: fact.semanticValue ?? fact.value,
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
          decoration: BoxDecoration(
            color: kSurfaceHigh.withValues(alpha: 0.66),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: kBorder),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(fact.icon, color: kTextSecondary, size: 17),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      fact.label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: kTextSecondary,
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      fact.value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: kTextPrimary,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProgressSection extends StatelessWidget {
  final AssetPackDownloadViewModel model;
  final _PanelVisual visual;

  const _ProgressSection({required this.model, required this.visual});

  @override
  Widget build(BuildContext context) {
    if (model.isPostProcessing) return _buildPostProcessing();

    final total = model.resolvedTotalBytes;
    final fraction = model.progressFraction;
    final percent = fraction == null ? null : (fraction * 100).round();
    final part = _partLabel(model);
    final progressText = switch (model.stage) {
      AssetPackPanelStage.queued =>
        model.queuePosition == null
            ? 'Queued'
            : 'Queue position ${model.queuePosition}',
      AssetPackPanelStage.stopping => 'Pausing safely…',
      AssetPackPanelStage.downloading => switch ((
        model.receivedBytes,
        total,
        percent,
      )) {
        (final received, final knownTotal?, final knownPercent?) =>
          '${AssetPackDownloadPanel.formatBytes(received)} of '
              '${AssetPackDownloadPanel.formatBytes(knownTotal)} • $knownPercent%',
        (final received, null, _) when received > 0 =>
          '${AssetPackDownloadPanel.formatBytes(received)} downloaded',
        _ => 'Starting…',
      },
      _ => 'Starting…',
    };
    final byteDetails = [
      if (model.receivedBytes > 0)
        '${AssetPackDownloadPanel._formatExactBytes(model.receivedBytes)} bytes received',
      if (total != null)
        '${AssetPackDownloadPanel._formatExactBytes(total)} bytes total',
      ?part,
    ].join(', ');
    final progressDetails =
        model.stage == AssetPackPanelStage.downloading && byteDetails.isNotEmpty
        ? byteDetails
        : progressText;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LinearProgressIndicator(
          key: ValueKey('asset-pack-progress-${model.packId}'),
          value: model.stage == AssetPackPanelStage.downloading
              ? fraction
              : null,
          minHeight: 8,
          borderRadius: BorderRadius.circular(999),
          color: visual.color,
          semanticsLabel: '${model.title} download progress',
          semanticsValue:
              model.stage == AssetPackPanelStage.downloading && percent != null
              ? '$percent'
              : null,
        ),
        const SizedBox(height: 8),
        Semantics(
          key: ValueKey('asset-pack-progress-details-${model.packId}'),
          label: '${model.title} download details',
          value: progressDetails,
          child: ExcludeSemantics(
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    progressText,
                    key: ValueKey('asset-pack-progress-label-${model.packId}'),
                    style: const TextStyle(
                      color: kTextSecondary,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (part != null) ...[
                  const SizedBox(width: 8),
                  Text(
                    part,
                    style: const TextStyle(color: kTextSecondary, fontSize: 10),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPostProcessing() {
    final phase = switch (model.stage) {
      AssetPackPanelStage.verifying => 'Checking integrity…',
      AssetPackPanelStage.extracting => 'Unpacking assets…',
      AssetPackPanelStage.installing => 'Updating local library…',
      _ => 'Processing…',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LinearProgressIndicator(
          key: ValueKey('asset-pack-progress-${model.packId}'),
          value: 1,
          minHeight: 8,
          borderRadius: BorderRadius.circular(999),
          color: kSuccess,
          semanticsLabel: '${model.title} transfer progress',
          semanticsValue: '100',
        ),
        const SizedBox(height: 10),
        Semantics(
          label: '${model.title} post-processing status',
          value: phase.replaceAll('…', ''),
          child: ExcludeSemantics(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final phaseIndicator = Row(
                  children: [
                    const SizedBox.square(
                      dimension: 17,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        phase,
                        key: ValueKey(
                          'asset-pack-post-processing-${model.packId}',
                        ),
                        style: const TextStyle(
                          color: kTextSecondary,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                );
                const complete = Text(
                  'Download complete',
                  style: TextStyle(
                    color: kSuccess,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                  ),
                );
                if (constraints.maxWidth < 360) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      phaseIndicator,
                      const SizedBox(height: 7),
                      const Align(
                        alignment: Alignment.centerRight,
                        child: complete,
                      ),
                    ],
                  );
                }
                return Row(
                  children: [
                    Expanded(child: phaseIndicator),
                    const SizedBox(width: 8),
                    complete,
                  ],
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _ErrorMessage extends StatelessWidget {
  final String packId;
  final String message;

  const _ErrorMessage({required this.packId, required this.message});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      label: 'Download error',
      value: message,
      child: ExcludeSemantics(
        child: Container(
          key: ValueKey('asset-pack-error-$packId'),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: kError.withValues(alpha: 0.09),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: kError.withValues(alpha: 0.36)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.error_outline_rounded, color: kError, size: 19),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  message,
                  maxLines: 5,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: kError,
                    fontSize: 11,
                    height: 1.35,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ContinuationNote extends StatelessWidget {
  final String packId;
  final String text;

  const _ContinuationNote({required this.packId, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      key: ValueKey('asset-pack-continuation-$packId'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: kInfo.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kInfo.withValues(alpha: 0.23)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const ExcludeSemantics(
            child: Icon(Icons.layers_outlined, color: kInfo, size: 18),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: kTextSecondary,
                fontSize: 10,
                height: 1.4,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Fact {
  final String label;
  final String value;
  final String? semanticValue;
  final IconData icon;

  const _Fact({
    required this.label,
    required this.value,
    required this.icon,
    this.semanticValue,
  });
}

class _PanelVisual {
  final String statusLabel;
  final Color color;
  final IconData statusIcon;

  const _PanelVisual({
    required this.statusLabel,
    required this.color,
    required this.statusIcon,
  });
}

_PanelVisual _visualFor(AssetPackPanelStage stage) {
  return switch (stage) {
    AssetPackPanelStage.available => const _PanelVisual(
      statusLabel: 'Available',
      color: kInfo,
      statusIcon: Icons.cloud_outlined,
    ),
    AssetPackPanelStage.queued => const _PanelVisual(
      statusLabel: 'Queued',
      color: kWarning,
      statusIcon: Icons.schedule_rounded,
    ),
    AssetPackPanelStage.preparing => const _PanelVisual(
      statusLabel: 'Preparing',
      color: kInfo,
      statusIcon: Icons.sync_rounded,
    ),
    AssetPackPanelStage.downloading => const _PanelVisual(
      statusLabel: 'Downloading',
      color: kAccent,
      statusIcon: Icons.downloading_rounded,
    ),
    AssetPackPanelStage.verifying => const _PanelVisual(
      statusLabel: 'Verifying',
      color: kAccentSecondary,
      statusIcon: Icons.verified_user_outlined,
    ),
    AssetPackPanelStage.extracting => const _PanelVisual(
      statusLabel: 'Extracting',
      color: kAccentSecondary,
      statusIcon: Icons.unarchive_outlined,
    ),
    AssetPackPanelStage.installing => const _PanelVisual(
      statusLabel: 'Installing',
      color: kAccentSecondary,
      statusIcon: Icons.install_desktop_outlined,
    ),
    AssetPackPanelStage.stopping => const _PanelVisual(
      statusLabel: 'Stopping',
      color: kWarning,
      statusIcon: Icons.hourglass_bottom_rounded,
    ),
    AssetPackPanelStage.cancelled => const _PanelVisual(
      statusLabel: 'Stopped',
      color: kTextSecondary,
      statusIcon: Icons.stop_circle_outlined,
    ),
    AssetPackPanelStage.failed => const _PanelVisual(
      statusLabel: 'Failed',
      color: kError,
      statusIcon: Icons.error_outline_rounded,
    ),
    AssetPackPanelStage.installed => const _PanelVisual(
      statusLabel: 'Installed',
      color: kSuccess,
      statusIcon: Icons.check_circle_outline_rounded,
    ),
  };
}

String? _partLabel(AssetPackDownloadViewModel model) {
  final index = model.partIndex;
  final count = model.partCount;
  if (index == null || count == null || count <= 1) return null;
  return 'Part ${index + 1} of $count';
}
