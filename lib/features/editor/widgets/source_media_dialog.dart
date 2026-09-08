import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../models/timeline_models.dart';

class SourceMediaSelection {
  const SourceMediaSelection({
    required this.start,
    required this.end,
    this.append = false,
  });
  final Duration start;
  final Duration end;
  final bool append;
  Duration get duration => end - start;
}

/// Independent source playback never moves the timeline playhead.
class SourceMediaDialog extends StatefulWidget {
  const SourceMediaDialog({super.key, required this.asset});
  final EditorAssetReference asset;

  @override
  State<SourceMediaDialog> createState() => _SourceMediaDialogState();
}

class _SourceMediaDialogState extends State<SourceMediaDialog> {
  VideoPlayerController? _controller;
  String? _error;
  bool _ready = false;
  late double _durationMs;
  late RangeValues _range;

  bool get _still =>
      widget.asset.type == EditorAssetType.image ||
      widget.asset.type == EditorAssetType.sticker;

  @override
  void initState() {
    super.initState();
    final declared =
        (widget.asset.metadata['durationMs'] as num?)?.toDouble() ?? 0;
    _durationMs = declared.isFinite && declared > 0 ? declared : 4000;
    _range = RangeValues(0, _durationMs);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      final source = widget.asset.sourcePath;
      if (source == null || !await File(source).exists()) {
        throw StateError('Source is offline. Relink it from the media pool.');
      }
      if (!mounted) return;
      if (_still) {
        setState(() => _ready = true);
        return;
      }
      final controller = VideoPlayerController.file(File(source));
      _controller = controller;
      await controller.initialize().timeout(const Duration(seconds: 20));
      if (!mounted) return;
      final duration = controller.value.duration.inMilliseconds.toDouble();
      if (duration <= 0) {
        throw StateError('This source has no readable duration.');
      }
      controller.addListener(_onPlaybackChanged);
      setState(() {
        _durationMs = duration;
        _range = RangeValues(0, duration);
        _ready = true;
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Source preview unavailable. Relink offline media or use a supported source format.',
        );
      }
    }
  }

  void _onPlaybackChanged() {
    final controller = _controller;
    if (!mounted || controller == null) return;
    if (controller.value.isPlaying &&
        controller.value.position.inMilliseconds >= _range.end) {
      unawaited(_pauseSource());
    }
    setState(() {});
  }

  Future<void> _pauseSource() async {
    try {
      await _controller?.pause();
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Source playback stopped. Reopen it to retry.');
      }
    }
  }

  Future<void> _togglePlayback() async {
    final controller = _controller;
    if (controller == null || !_ready) return;
    try {
      if (controller.value.isPlaying) {
        await controller.pause();
      } else {
        if (controller.value.position.inMilliseconds < _range.start ||
            controller.value.position.inMilliseconds >= _range.end) {
          await controller.seekTo(Duration(milliseconds: _range.start.round()));
        }
        if (mounted) await controller.play();
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Could not play this source. Close and reopen it to retry.',
        );
      }
    }
  }

  @override
  void dispose() {
    final controller = _controller;
    controller?.removeListener(_onPlaybackChanged);
    if (controller != null) unawaited(controller.dispose());
    super.dispose();
  }

  void _submit(bool append) => Navigator.pop(
    context,
    SourceMediaSelection(
      start: Duration(milliseconds: _range.start.round()),
      end: Duration(milliseconds: _range.end.round()),
      append: append,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final canInsert =
        _ready && _error == null && _range.end - _range.start >= 1;
    return AlertDialog(
      title: Text(
        widget.asset.label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      content: SizedBox(
        width: 700,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 240,
                child: Center(
                  child: _error != null
                      ? Text(_error!)
                      : !_ready
                      ? const CircularProgressIndicator()
                      : _still
                      ? Image.file(
                          File(widget.asset.sourcePath!),
                          fit: BoxFit.contain,
                          errorBuilder: (_, _, _) =>
                              const Text('Image preview unavailable'),
                        )
                      : widget.asset.type == EditorAssetType.audio
                      ? const Icon(Icons.audiotrack, size: 64)
                      : AspectRatio(
                          aspectRatio: controller!.value.aspectRatio > 0
                              ? controller.value.aspectRatio
                              : 16 / 9,
                          child: VideoPlayer(controller),
                        ),
                ),
              ),
              if (!_still)
                IconButton(
                  tooltip: controller?.value.isPlaying == true
                      ? 'Pause source'
                      : 'Play source range',
                  onPressed: _ready ? _togglePlayback : null,
                  icon: Icon(
                    controller?.value.isPlaying == true
                        ? Icons.pause
                        : Icons.play_arrow,
                  ),
                ),
              Text(
                'In ${(_range.start / 1000).toStringAsFixed(3)} s  ·  Out ${(_range.end / 1000).toStringAsFixed(3)} s',
              ),
              RangeSlider(
                min: 0,
                max: _durationMs,
                values: _range,
                labels: RangeLabels(
                  '${(_range.start / 1000).toStringAsFixed(2)} s',
                  '${(_range.end / 1000).toStringAsFixed(2)} s',
                ),
                onChanged: _ready
                    ? (range) {
                        if (range.end - range.start >= 1) {
                          setState(() => _range = range);
                        }
                      }
                    : null,
                onChangeEnd: _ready && controller != null
                    ? (range) async {
                        try {
                          await controller.pause();
                          await controller.seekTo(
                            Duration(milliseconds: range.start.round()),
                          );
                        } catch (_) {
                          if (mounted) {
                            setState(
                              () => _error = 'Could not seek this source.',
                            );
                          }
                        }
                      }
                    : null,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        OutlinedButton(
          onPressed: canInsert ? () => _submit(true) : null,
          child: const Text('Append'),
        ),
        FilledButton(
          onPressed: canInsert ? () => _submit(false) : null,
          child: const Text('Insert at playhead'),
        ),
      ],
    );
  }
}
