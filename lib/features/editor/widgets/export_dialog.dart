import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/app_button.dart';

/// Export dialog with quality/format options.
class ExportDialog extends StatefulWidget {
  final ValueChanged<String> onExport;

  const ExportDialog({super.key, required this.onExport});

  @override
  State<ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<ExportDialog> {
  String _quality = 'Original';
  bool _isExporting = false;

  final _qualities = ['Original', '1080p', '720p', '480p'];

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: kSurface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Export Video',
              style: GoogleFonts.inter(
                color: kTextPrimary,
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Subtitles will be burned into the video permanently.',
              style: GoogleFonts.inter(
                color: kTextSecondary,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 24),

            // Quality selector
            Text(
              'QUALITY',
              style: GoogleFonts.inter(
                color: kTextSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: _qualities.map((q) {
                final isSelected = _quality == q;
                return ChoiceChip(
                  label: Text(q),
                  selected: isSelected,
                  selectedColor: kAccent.withValues(alpha: 0.2),
                  backgroundColor: kSurfaceElevated,
                  side: BorderSide(
                    color: isSelected ? kAccent : kBorder,
                  ),
                  labelStyle: GoogleFonts.inter(
                    color: isSelected ? kAccent : kTextSecondary,
                    fontSize: 13,
                  ),
                  onSelected: (selected) {
                    if (selected) setState(() => _quality = q);
                  },
                );
              }).toList(),
            ),
            const SizedBox(height: 16),

            // Format (fixed for now)
            Row(
              children: [
                Text(
                  'FORMAT',
                  style: GoogleFonts.inter(
                    color: kTextSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(width: 12),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: kSurfaceElevated,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: kBorder),
                  ),
                  child: Text(
                    'MP4 (H.264)',
                    style: GoogleFonts.spaceMono(
                      color: kTextPrimary,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),

            // Actions
            Row(
              children: [
                Expanded(
                  child: AppButton(
                    label: 'Cancel',
                    variant: AppButtonVariant.ghost,
                    onPressed: () => Navigator.pop(context),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: AppButton(
                    label: 'Export',
                    icon: Icons.file_download_rounded,
                    isLoading: _isExporting,
                    onPressed: () {
                      setState(() => _isExporting = true);
                      widget.onExport(_quality);
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
