import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/app_surface.dart';
import '../models/subtitle_entry.dart';
import '../providers/subtitle_provider.dart';

/// Bottom sheet for editing only subtitle text.
class SubtitleEditModal extends ConsumerStatefulWidget {
  final SubtitleEntry entry;

  const SubtitleEditModal({super.key, required this.entry});

  @override
  ConsumerState<SubtitleEditModal> createState() => _SubtitleEditModalState();
}

class _SubtitleEditModalState extends ConsumerState<SubtitleEditModal> {
  late TextEditingController _textController;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(text: widget.entry.text);
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  bool _save() {
    final notifier = ref.read(subtitleProvider.notifier);
    final text = _textController.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Subtitle text cannot be empty. Use delete instead.'),
        ),
      );
      return false;
    }
    if (text != widget.entry.text) {
      notifier.updateText(widget.entry.id, text);
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedPadding(
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: AppSheetSurface(
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppSheetHeader(
                title: 'Edit subtitle',
                subtitle: 'Refine copy and line breaks',
                icon: Icons.closed_caption_rounded,
                onClose: () => Navigator.pop(context),
                trailing: IconButton(
                  tooltip: 'Delete subtitle',
                  style: IconButton.styleFrom(
                    foregroundColor: kError,
                    backgroundColor: kError.withValues(alpha: 0.08),
                    side: BorderSide(color: kError.withValues(alpha: 0.22)),
                    minimumSize: const Size.square(36),
                    maximumSize: const Size.square(36),
                  ),
                  icon: const Icon(Icons.delete_outline_rounded, size: 19),
                  onPressed: () {
                    ref
                        .read(subtitleProvider.notifier)
                        .deleteEntry(widget.entry.id);
                    Navigator.pop(context);
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
                child: TextFormField(
                  controller: _textController,
                  minLines: 3,
                  maxLines: 6,
                  autofocus: true,
                  textCapitalization: TextCapitalization.sentences,
                  style: const TextStyle(
                    color: kTextPrimary,
                    fontSize: 15,
                    height: 1.45,
                  ),
                  decoration: const InputDecoration(
                    hintText: 'Type the subtitle…',
                    alignLabelWithHint: true,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
                decoration: const BoxDecoration(
                  color: Color(0x7A101316),
                  border: Border(top: BorderSide(color: kBorder)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Cancel'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: FilledButton.icon(
                        onPressed: () {
                          if (_save()) Navigator.pop(context);
                        },
                        icon: const Icon(Icons.check_rounded, size: 18),
                        label: const Text('Save subtitle'),
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
