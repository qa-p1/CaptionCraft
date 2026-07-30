import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../models/subtitle_entry.dart';

class TeleprompterScreen extends StatefulWidget {
  final String projectName;
  final List<SubtitleEntry> entries;

  const TeleprompterScreen({
    super.key,
    required this.projectName,
    required this.entries,
  });

  @override
  State<TeleprompterScreen> createState() => _TeleprompterScreenState();
}

class _TeleprompterScreenState extends State<TeleprompterScreen> {
  static const double _itemExtent = 168;

  final ScrollController _scrollController = ScrollController();
  Timer? _ticker;
  DateTime? _lastTickAt;
  Duration _position = Duration.zero;
  bool _isRunning = false;
  bool _isMirrored = false;
  double _speed = 1;
  double _fontSize = 38;
  int _currentIndex = 0;

  List<SubtitleEntry> get _entries {
    return List<SubtitleEntry>.from(widget.entries)
      ..sort((a, b) => a.startTime.compareTo(b.startTime));
  }

  Duration get _endPosition {
    final entries = _entries;
    return entries.isEmpty ? Duration.zero : entries.last.endTime;
  }

  @override
  void initState() {
    super.initState();
    final entries = _entries;
    _position = entries.isEmpty ? Duration.zero : entries.first.startTime;
    _ticker = Timer.periodic(
      const Duration(milliseconds: 50),
      (_) => _onTick(),
    );
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  void _onTick() {
    if (!_isRunning || !mounted) {
      _lastTickAt = null;
      return;
    }
    final now = DateTime.now();
    final previous = _lastTickAt ?? now;
    _lastTickAt = now;
    final elapsedMicros = now.difference(previous).inMicroseconds;
    final next =
        _position + Duration(microseconds: (elapsedMicros * _speed).round());
    if (next >= _endPosition) {
      setState(() {
        _position = _endPosition;
        _isRunning = false;
      });
    } else {
      setState(() => _position = next);
    }
    _syncCurrentCaption();
  }

  void _syncCurrentCaption() {
    final entries = _entries;
    if (entries.isEmpty) return;
    var nextIndex = _currentIndex;
    for (var index = 0; index < entries.length; index++) {
      if (_position >= entries[index].startTime) {
        nextIndex = index;
      } else {
        break;
      }
    }
    if (nextIndex == _currentIndex) return;
    _currentIndex = nextIndex;
    _scrollToCurrent();
  }

  void _scrollToCurrent() {
    if (!_scrollController.hasClients) return;
    final viewport = _scrollController.position.viewportDimension;
    final target = (_currentIndex * _itemExtent - viewport * 0.34).clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );
    _scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
    );
  }

  void _togglePlayback() {
    if (_entries.isEmpty) return;
    setState(() {
      if (_position >= _endPosition) {
        _position = _entries.first.startTime;
        _currentIndex = 0;
      }
      _isRunning = !_isRunning;
      _lastTickAt = null;
    });
  }

  void _reset() {
    if (_entries.isEmpty) return;
    setState(() {
      _isRunning = false;
      _position = _entries.first.startTime;
      _currentIndex = 0;
      _lastTickAt = null;
    });
    _scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  void _skip(int direction) {
    final entries = _entries;
    if (entries.isEmpty) return;
    final nextIndex = (_currentIndex + direction).clamp(0, entries.length - 1);
    setState(() {
      _currentIndex = nextIndex;
      _position = entries[nextIndex].startTime;
      _lastTickAt = null;
    });
    _scrollToCurrent();
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Teleprompter Stage'),
            Text(
              widget.projectName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: kTextSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: _isMirrored ? 'Disable mirror' : 'Mirror for glass rig',
            onPressed: () => setState(() => _isMirrored = !_isMirrored),
            icon: Icon(
              _isMirrored ? Icons.flip_rounded : Icons.flip_to_front_rounded,
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: entries.isEmpty
          ? const Center(
              child: Text(
                'Add captions before opening the teleprompter.',
                style: TextStyle(color: kTextSecondary),
              ),
            )
          : Column(
              children: [
                _buildProgressHeader(entries),
                Expanded(
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: Transform(
                          alignment: Alignment.center,
                          transform: _isMirrored
                              ? Matrix4.rotationY(math.pi)
                              : Matrix4.identity(),
                          child: ListView.builder(
                            controller: _scrollController,
                            padding: EdgeInsets.symmetric(
                              horizontal: MediaQuery.sizeOf(context).width < 700
                                  ? 22
                                  : 96,
                              vertical:
                                  MediaQuery.sizeOf(context).height * 0.25,
                            ),
                            itemExtent: _itemExtent,
                            itemCount: entries.length,
                            itemBuilder: (context, index) {
                              return _TeleprompterLine(
                                entry: entries[index],
                                active: index == _currentIndex,
                                fontSize: _fontSize,
                              );
                            },
                          ),
                        ),
                      ),
                      IgnorePointer(
                        child: Align(
                          alignment: Alignment.center,
                          child: Container(
                            height: _itemExtent,
                            decoration: BoxDecoration(
                              border: Border.symmetric(
                                horizontal: BorderSide(
                                  color: kAccent.withValues(alpha: 0.32),
                                ),
                              ),
                              gradient: LinearGradient(
                                colors: [
                                  kAccent.withValues(alpha: 0.025),
                                  kAccent.withValues(alpha: 0.075),
                                  kAccent.withValues(alpha: 0.025),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                _buildControls(),
              ],
            ),
    );
  }

  Widget _buildProgressHeader(List<SubtitleEntry> entries) {
    final totalMs = math.max(1, _endPosition.inMilliseconds);
    final progress = (_position.inMilliseconds / totalMs).clamp(0.0, 1.0);
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
      decoration: const BoxDecoration(
        color: Color(0xFF070807),
        border: Border(bottom: BorderSide(color: kBorder)),
      ),
      child: Row(
        children: [
          Text(
            _formatTime(_position),
            style: const TextStyle(
              color: kAccentSecondary,
              fontFamily: 'monospace',
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 4,
              borderRadius: BorderRadius.circular(999),
              backgroundColor: kSurfaceHigh,
            ),
          ),
          const SizedBox(width: 12),
          Text(
            '${_currentIndex + 1} / ${entries.length}',
            style: const TextStyle(color: kTextSecondary, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _buildControls() {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        decoration: const BoxDecoration(
          color: Color(0xFF0D0F0E),
          border: Border(top: BorderSide(color: kBorder)),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 680;
            final playback = Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton.filledTonal(
                  tooltip: 'Previous cue',
                  onPressed: () => _skip(-1),
                  icon: const Icon(Icons.skip_previous_rounded),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _togglePlayback,
                  icon: Icon(
                    _isRunning ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  ),
                  label: Text(_isRunning ? 'Pause' : 'Rehearse'),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  tooltip: 'Next cue',
                  onPressed: () => _skip(1),
                  icon: const Icon(Icons.skip_next_rounded),
                ),
                IconButton(
                  tooltip: 'Reset',
                  onPressed: _reset,
                  icon: const Icon(Icons.replay_rounded),
                ),
              ],
            );
            final settings = Row(
              children: [
                const Icon(
                  Icons.speed_rounded,
                  size: 17,
                  color: kTextSecondary,
                ),
                Expanded(
                  child: Slider(
                    value: _speed,
                    min: 0.5,
                    max: 2,
                    divisions: 6,
                    label: '${_speed.toStringAsFixed(2)}×',
                    onChanged: (value) => setState(() => _speed = value),
                  ),
                ),
                Text(
                  '${_speed.toStringAsFixed(2)}×',
                  style: const TextStyle(
                    color: kTextPrimary,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 12),
                const Icon(
                  Icons.text_fields_rounded,
                  size: 17,
                  color: kTextSecondary,
                ),
                SizedBox(
                  width: compact ? 100 : 150,
                  child: Slider(
                    value: _fontSize,
                    min: 26,
                    max: 58,
                    divisions: 8,
                    label: '${_fontSize.round()}',
                    onChanged: (value) => setState(() => _fontSize = value),
                  ),
                ),
              ],
            );

            if (compact) {
              return Column(
                children: [playback, const SizedBox(height: 8), settings],
              );
            }
            return Row(
              children: [
                playback,
                const SizedBox(width: 20),
                Expanded(child: settings),
              ],
            );
          },
        ),
      ),
    );
  }

  String _formatTime(Duration value) {
    final minutes = value.inMinutes.toString().padLeft(2, '0');
    final seconds = (value.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

class _TeleprompterLine extends StatelessWidget {
  final SubtitleEntry entry;
  final bool active;
  final double fontSize;

  const _TeleprompterLine({
    required this.entry,
    required this.active,
    required this.fontSize,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 180),
      opacity: active ? 1 : 0.28,
      child: Align(
        alignment: Alignment.center,
        child: Text(
          entry.text,
          textAlign: TextAlign.center,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: active ? Colors.white : kTextSecondary,
            fontSize: active ? fontSize : fontSize * 0.72,
            height: 1.18,
            fontWeight: active ? FontWeight.w800 : FontWeight.w500,
            letterSpacing: active ? -0.6 : -0.2,
          ),
        ),
      ),
    );
  }
}
