import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_theme.dart';
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

  void _save() {
    final notifier = ref.read(subtitleProvider.notifier);
    final text = _textController.text.trim();
    if (text.isNotEmpty && text != widget.entry.text) {
      notifier.updateText(widget.entry.id, text);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      decoration: const BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Drag handle
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: kBorder,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),

            // Header
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Edit Subtitle Text',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: kTextPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(
                    Icons.delete_rounded,
                    color: kError,
                    size: 20,
                  ),
                  onPressed: () {
                    ref
                        .read(subtitleProvider.notifier)
                        .deleteEntry(widget.entry.id);
                    Navigator.pop(context);
                  },
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Text field
            TextFormField(
              controller: _textController,
              minLines: 3,
              maxLines: 6,
              autofocus: true,
              style: const TextStyle(color: kTextPrimary, fontSize: 15),
              decoration: InputDecoration(
                hintText: 'Subtitle text...',
                filled: true,
                fillColor: kSurfaceElevated,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: kBorder),
                ),
              ),
            ),
            const SizedBox(height: 20),

            // Actions row
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () {
                    Navigator.pop(context);
                  },
                  child: Text(
                    'Cancel',
                    style: TextStyle(color: kTextSecondary),
                  ),
                ),
                const SizedBox(width: 16),
                ElevatedButton(
                  onPressed: () {
                    _save();
                    Navigator.pop(context);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kAccent,
                    foregroundColor: Colors.white,
                  ),
                  child: Text(
                    'Save',
                    style: TextStyle(fontWeight: FontWeight.w600),
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
