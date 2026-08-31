import 'dart:io';

import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../models/export_settings.dart';

/// Professional delivery settings for the final timeline render.
class ExportDialog extends StatefulWidget {
  final ValueChanged<ExportSettings> onExport;

  const ExportDialog({super.key, required this.onExport});

  @override
  State<ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<ExportDialog> {
  late ExportSettings _settings;
  bool _isExporting = false;

  bool get _supportsGallery => Platform.isAndroid || Platform.isIOS;

  @override
  void initState() {
    super.initState();
    _settings = ExportSettings(saveToGallery: _supportsGallery);
  }

  @override
  Widget build(BuildContext context) {
    final viewport = MediaQuery.sizeOf(context);
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 540,
          maxHeight: viewport.height * 0.9,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _SectionHeading(
                      index: '01',
                      title: 'Frame',
                      description: 'Choose output dimensions and cadence.',
                    ),
                    const SizedBox(height: 13),
                    _sectionLabel('RESOLUTION'),
                    const SizedBox(height: 8),
                    _choiceWrap<ExportResolution>(
                      values: ExportResolution.values,
                      selected: _settings.resolution,
                      label: (value) => switch (value) {
                        ExportResolution.original => 'Original',
                        ExportResolution.p1080 => '1080p',
                        ExportResolution.p720 => '720p',
                        ExportResolution.p480 => '480p',
                      },
                      onSelected: (value) => setState(
                        () => _settings = _settings.copyWith(resolution: value),
                      ),
                    ),
                    const SizedBox(height: 16),
                    _sectionLabel('FRAME RATE'),
                    const SizedBox(height: 8),
                    _choiceWrap<ExportFrameRate>(
                      values: ExportFrameRate.values,
                      selected: _settings.frameRate,
                      label: (value) => switch (value) {
                        ExportFrameRate.source => 'Source',
                        ExportFrameRate.fps24 => '24 fps',
                        ExportFrameRate.fps30 => '30 fps',
                        ExportFrameRate.fps60 => '60 fps',
                      },
                      onSelected: (value) => setState(
                        () => _settings = _settings.copyWith(frameRate: value),
                      ),
                    ),
                    const SizedBox(height: 25),
                    const Divider(),
                    const SizedBox(height: 21),
                    _SectionHeading(
                      index: '02',
                      title: 'Compression',
                      description: 'Balance file size against image detail.',
                    ),
                    const SizedBox(height: 13),
                    _choiceWrap<ExportQuality>(
                      values: ExportQuality.values,
                      selected: _settings.quality,
                      label: (value) => switch (value) {
                        ExportQuality.compact => 'Compact',
                        ExportQuality.balanced => 'Balanced',
                        ExportQuality.high => 'High',
                        ExportQuality.maximum => 'Maximum',
                      },
                      onSelected: (value) => setState(
                        () => _settings = _settings.copyWith(quality: value),
                      ),
                    ),
                    const SizedBox(height: 25),
                    const Divider(),
                    const SizedBox(height: 21),
                    const _SectionHeading(
                      index: '03',
                      title: 'Finishing',
                      description: 'Control what is baked into the file.',
                    ),
                    const SizedBox(height: 12),
                    _toggle(
                      icon: Icons.graphic_eq_rounded,
                      label: 'Timeline audio',
                      description: 'Mix enabled audio and video tracks',
                      value: _settings.includeAudio,
                      onChanged: (value) => setState(
                        () =>
                            _settings = _settings.copyWith(includeAudio: value),
                      ),
                    ),
                    _toggle(
                      icon: Icons.closed_caption_rounded,
                      label: 'Burn captions',
                      description: 'Render styled subtitles into the picture',
                      value: _settings.burnSubtitles,
                      onChanged: (value) => setState(
                        () => _settings = _settings.copyWith(
                          burnSubtitles: value,
                        ),
                      ),
                    ),
                    if (_supportsGallery)
                      _toggle(
                        icon: Icons.photo_library_outlined,
                        label: 'Copy to gallery',
                        description: 'Keep the master in Exports as well',
                        value: _settings.saveToGallery,
                        onChanged: (value) => setState(
                          () => _settings = _settings.copyWith(
                            saveToGallery: value,
                          ),
                        ),
                      ),
                    const SizedBox(height: 16),
                    _buildDeliverySummary(),
                  ],
                ),
              ),
            ),
            _buildFooter(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 17, 12, 17),
      decoration: const BoxDecoration(
        color: kSurfaceElevated,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        border: Border(bottom: BorderSide(color: kBorder)),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: kAccent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: kAccent.withValues(alpha: 0.32)),
            ),
            child: const Icon(
              Icons.ios_share_rounded,
              color: kAccent,
              size: 20,
            ),
          ),
          const SizedBox(width: 13),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Deliver master',
                  style: TextStyle(
                    color: kTextPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.35,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'MP4  /  H.264  /  AAC',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    color: kAccentSecondary,
                    fontSize: 9.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Close',
            onPressed: _isExporting ? null : () => Navigator.pop(context),
            icon: const Icon(Icons.close_rounded, size: 20),
          ),
        ],
      ),
    );
  }

  Widget _buildFooter() {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 17),
      decoration: const BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(20)),
        border: Border(top: BorderSide(color: kBorder)),
      ),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: _isExporting ? null : () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 2,
            child: FilledButton.icon(
              onPressed: _isExporting
                  ? null
                  : () {
                      setState(() => _isExporting = true);
                      widget.onExport(_settings);
                    },
              icon: _isExporting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        color: kOnAccent,
                        strokeWidth: 2,
                      ),
                    )
                  : const Icon(Icons.movie_creation_outlined, size: 18),
              label: Text(_isExporting ? 'Opening renderer…' : 'Render video'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDeliverySummary() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: kBackground,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: kBorder),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.data_usage_rounded,
            color: kAccentSecondary,
            size: 18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '${_settings.resolutionLabel}  ·  '
              '${_settings.frameRateLabel}  ·  ${_settings.qualityLabel}',
              style: const TextStyle(
                fontFamily: 'monospace',
                color: kTextPrimary,
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const Text(
            'READY',
            style: TextStyle(
              color: kSuccess,
              fontSize: 9,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.8,
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(String label) {
    return Text(
      label,
      style: const TextStyle(
        color: kTextSecondary,
        fontSize: 10,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.9,
      ),
    );
  }

  Widget _choiceWrap<T>({
    required List<T> values,
    required T selected,
    required String Function(T value) label,
    required ValueChanged<T> onSelected,
  }) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: values.map((value) {
        final isSelected = value == selected;
        return ChoiceChip(
          label: Text(label(value)),
          selected: isSelected,
          showCheckmark: false,
          side: BorderSide(color: isSelected ? kAccent : kBorder),
          labelStyle: TextStyle(
            color: isSelected ? kTextPrimary : kTextSecondary,
            fontSize: 11.5,
            fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
          ),
          avatar: isSelected
              ? const Icon(Icons.check_rounded, color: kAccent, size: 15)
              : null,
          onSelected: (enabled) {
            if (enabled) onSelected(value);
          },
        );
      }).toList(),
    );
  }

  Widget _toggle({
    required IconData icon,
    required String label,
    required String description,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: value ? kAccent.withValues(alpha: 0.055) : kSurfaceElevated,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: () => onChanged(!value),
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: value ? kAccent.withValues(alpha: 0.32) : kBorder,
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: value
                        ? kAccent.withValues(alpha: 0.12)
                        : kSurfaceHigh,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Icon(
                    icon,
                    color: value ? kAccent : kTextSecondary,
                    size: 17,
                  ),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: const TextStyle(
                          color: kTextPrimary,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        description,
                        style: const TextStyle(
                          color: kTextSecondary,
                          fontSize: 10.5,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch.adaptive(value: value, onChanged: onChanged),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionHeading extends StatelessWidget {
  final String index;
  final String title;
  final String description;

  const _SectionHeading({
    required this.index,
    required this.title,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 30,
          height: 24,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: kSurfaceHigh,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            index,
            style: const TextStyle(
              fontFamily: 'monospace',
              color: kAccent,
              fontSize: 9,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: kTextPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                description,
                style: const TextStyle(
                  color: kTextSecondary,
                  fontSize: 11,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
