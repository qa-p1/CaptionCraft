import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/models/processing_state.dart';

/// Full-screen progress view used while speech is converted into editable cues.
class ProcessingScreen extends ConsumerStatefulWidget {
  const ProcessingScreen({
    super.key,
    required this.progressStream,
    required this.onCancel,
  });

  final Stream<ProcessingProgress> progressStream;
  final VoidCallback onCancel;

  @override
  ConsumerState<ProcessingScreen> createState() => _ProcessingScreenState();
}

class _ProcessingScreenState extends ConsumerState<ProcessingScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _signalController;
  StreamSubscription<ProcessingProgress>? _progressSubscription;
  ProcessingProgress _currentProgress = ProcessingProgress.initial();
  bool _cancelDialogOpen = false;

  @override
  void initState() {
    super.initState();
    _signalController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();
    _progressSubscription = widget.progressStream.listen(
      (progress) {
        if (mounted) setState(() => _currentProgress = progress);
      },
      onError: (Object error) {
        if (!mounted) return;
        setState(() {
          _currentProgress = ProcessingProgress(
            stage: ProcessingStage.error,
            progress: _currentProgress.progress,
            message: error.toString().replaceFirst('Exception: ', ''),
          );
        });
      },
    );
  }

  @override
  void dispose() {
    _progressSubscription?.cancel();
    _signalController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isError = _currentProgress.stage == ProcessingStage.error;
    final compactHeader = MediaQuery.sizeOf(context).width < 480;
    final progress = _currentProgress.stage == ProcessingStage.done
        ? 1.0
        : _currentProgress.progress.clamp(0, 1).toDouble();

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_confirmCancel());
      },
      child: Scaffold(
        backgroundColor: kBackground,
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 14, 8),
                child: Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: isError ? kError : kAccentSecondary,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: (isError ? kError : kAccentSecondary)
                                .withValues(alpha: 0.35),
                            blurRadius: 12,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 9),
                    const Expanded(
                      child: Text(
                        'CAPTION LAB / LIVE PROCESS',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: kTextSecondary,
                          fontSize: 10,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 1.3,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (compactHeader)
                      IconButton(
                        tooltip: isError ? 'Close' : 'Cancel',
                        onPressed: _confirmCancel,
                        color: isError ? kError : kTextSecondary,
                        icon: const Icon(Icons.close_rounded, size: 19),
                      )
                    else
                      TextButton.icon(
                        onPressed: _confirmCancel,
                        icon: const Icon(Icons.close_rounded, size: 17),
                        label: Text(isError ? 'Close' : 'Cancel'),
                        style: TextButton.styleFrom(
                          foregroundColor: isError ? kError : kTextSecondary,
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final wide = constraints.maxWidth >= 720;
                    final mainPanel = _buildMainPanel(
                      progress: progress,
                      isError: isError,
                    );
                    final stagePanel = _buildStagePanel(isError: isError);

                    return SingleChildScrollView(
                      padding: EdgeInsets.fromLTRB(
                        wide ? 34 : 18,
                        14,
                        wide ? 34 : 18,
                        28,
                      ),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 980),
                          child: wide
                              ? Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(flex: 7, child: mainPanel),
                                    const SizedBox(width: 18),
                                    Expanded(flex: 4, child: stagePanel),
                                  ],
                                )
                              : Column(
                                  children: [
                                    mainPanel,
                                    const SizedBox(height: 14),
                                    stagePanel,
                                  ],
                                ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMainPanel({required double progress, required bool isError}) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 26),
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(26),
        border: Border.all(
          color: isError ? kError.withValues(alpha: 0.4) : kBorder,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: (isError ? kError : kAccent).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(
                    color: (isError ? kError : kAccent).withValues(alpha: 0.28),
                  ),
                ),
                child: Text(
                  isError ? 'PROCESS HALTED' : 'ANALYZING SPEECH',
                  style: TextStyle(
                    color: isError ? kError : kAccent,
                    fontSize: 9,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.15,
                  ),
                ),
              ),
              const Spacer(),
              Text(
                '${(progress * 100).round().clamp(0, 100)}%',
                style: TextStyle(
                  fontFamily: 'monospace',
                  color: isError ? kError : kAccentSecondary,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 30),
          SizedBox(
            height: 136,
            child: AnimatedBuilder(
              animation: _signalController,
              builder: (context, _) => CustomPaint(
                size: const Size(double.infinity, 136),
                painter: _SignalPainter(
                  animationValue: _signalController.value,
                  progress: progress,
                  color: isError ? kError : kAccent,
                ),
              ),
            ),
          ),
          const SizedBox(height: 26),
          Text(
            isError
                ? 'Transcription needs attention'
                : 'Building editable captions',
            style: const TextStyle(
              color: kTextPrimary,
              fontSize: 27,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.7,
            ),
          ),
          const SizedBox(height: 10),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            child: Text(
              _currentProgress.message,
              key: ValueKey(_currentProgress.message),
              style: TextStyle(
                color: isError ? kError : kTextSecondary,
                fontSize: 14,
                height: 1.5,
              ),
            ),
          ),
          const SizedBox(height: 24),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              minHeight: 8,
              value: progress,
              color: isError ? kError : kAccent,
              backgroundColor: kSurfaceHigh,
            ),
          ),
          if (_currentProgress.currentChunk != null) ...[
            const SizedBox(height: 13),
            Row(
              children: [
                const Icon(
                  Icons.segment_rounded,
                  color: kTextSecondary,
                  size: 16,
                ),
                const SizedBox(width: 7),
                Text(
                  'Segment ${_currentProgress.currentChunk! + 1} of '
                  '${_currentProgress.totalChunks ?? '—'}',
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    color: kTextSecondary,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStagePanel({required bool isError}) {
    const stages = [
      ('Extract source', 'Separate a clean working audio stream'),
      ('Prepare audio', 'Optimize speech for reliable recognition'),
      ('Transcribe', 'Convert speech into timed words'),
      ('Align captions', 'Build readable subtitle cues'),
    ];
    final activeIndex = _activeStageIndex(_currentProgress.stage);
    final allDone = _currentProgress.stage == ProcessingStage.done;

    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: kBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'PROCESS MAP',
            style: TextStyle(
              color: kTextSecondary,
              fontSize: 10,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.25,
            ),
          ),
          const SizedBox(height: 20),
          for (var index = 0; index < stages.length; index++)
            _ProcessStep(
              label: stages[index].$1,
              detail: stages[index].$2,
              isLast: index == stages.length - 1,
              isActive: !isError && !allDone && index == activeIndex,
              isComplete: allDone || (!isError && index < activeIndex),
              isFailed: isError && index == activeIndex,
            ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              color: kBackground,
              borderRadius: BorderRadius.circular(13),
              border: Border.all(color: kBorder),
            ),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.lock_outline_rounded,
                  color: kAccentSecondary,
                  size: 17,
                ),
                SizedBox(width: 9),
                Expanded(
                  child: Text(
                    'Your source media stays on this device. Only the prepared '
                    'audio needed for transcription is processed.',
                    style: TextStyle(
                      color: kTextSecondary,
                      fontSize: 11,
                      height: 1.45,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  int _activeStageIndex(ProcessingStage stage) {
    return switch (stage) {
      ProcessingStage.idle || ProcessingStage.extractingAudio => 0,
      ProcessingStage.compressing => 1,
      ProcessingStage.transcribing => 2,
      ProcessingStage.assemblingSubtitles || ProcessingStage.done => 3,
      ProcessingStage.error => _stageFromProgress(_currentProgress.progress),
    };
  }

  int _stageFromProgress(double progress) {
    if (progress < 0.2) return 0;
    if (progress < 0.4) return 1;
    if (progress < 0.86) return 2;
    return 3;
  }

  Future<void> _confirmCancel() async {
    if (_cancelDialogOpen) return;
    if (_currentProgress.stage == ProcessingStage.error) {
      widget.onCancel();
      return;
    }
    _cancelDialogOpen = true;
    try {
      final shouldCancel = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Stop transcription?'),
          content: const Text(
            'The current analysis will stop. Your video and existing timeline '
            'edits are not affected.',
            style: TextStyle(color: kTextSecondary, height: 1.45),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Keep processing'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: kError),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Stop'),
            ),
          ],
        ),
      );
      if (shouldCancel == true) widget.onCancel();
    } finally {
      _cancelDialogOpen = false;
    }
  }
}

class _ProcessStep extends StatelessWidget {
  const _ProcessStep({
    required this.label,
    required this.detail,
    required this.isLast,
    required this.isActive,
    required this.isComplete,
    required this.isFailed,
  });

  final String label;
  final String detail;
  final bool isLast;
  final bool isActive;
  final bool isComplete;
  final bool isFailed;

  @override
  Widget build(BuildContext context) {
    final color = isFailed
        ? kError
        : isComplete
        ? kSuccess
        : isActive
        ? kAccent
        : kBorder;

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 26,
            child: Column(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    color: color.withValues(
                      alpha: (isComplete || isActive || isFailed) ? 0.16 : 1,
                    ),
                    shape: BoxShape.circle,
                    border: Border.all(color: color),
                  ),
                  child: isComplete
                      ? const Icon(
                          Icons.check_rounded,
                          size: 13,
                          color: kSuccess,
                        )
                      : isFailed
                      ? const Icon(Icons.close_rounded, size: 13, color: kError)
                      : isActive
                      ? const Center(
                          child: SizedBox(
                            width: 7,
                            height: 7,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: kAccent,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                        )
                      : null,
                ),
                if (!isLast)
                  Expanded(
                    child: Container(
                      width: 1,
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      color: isComplete
                          ? kSuccess.withValues(alpha: 0.4)
                          : kBorder,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 4 : 22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      color: isActive || isComplete || isFailed
                          ? kTextPrimary
                          : kTextSecondary,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    detail,
                    style: const TextStyle(
                      color: kTextSecondary,
                      fontSize: 10,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SignalPainter extends CustomPainter {
  const _SignalPainter({
    required this.animationValue,
    required this.progress,
    required this.color,
  });

  final double animationValue;
  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final baseline = Paint()
      ..color = kBorder
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(0, size.height / 2),
      Offset(size.width, size.height / 2),
      baseline,
    );

    const barWidth = 4.0;
    const gap = 5.0;
    final bars = max(1, (size.width / (barWidth + gap)).floor());
    final activeBars = (bars * progress).round();

    for (var index = 0; index < bars; index++) {
      final x = index * (barWidth + gap);
      final phase = animationValue * pi * 2 + index * 0.43;
      final organic = (sin(phase) + sin(phase * 0.47 + 1.2)) * 0.5;
      final envelope = 0.36 + 0.64 * sin((index / bars) * pi).abs();
      final height =
          10 + (size.height * 0.68 * envelope * (0.56 + organic.abs() * 0.44));
      final active = index <= activeBars;
      final paint = Paint()
        ..color = active
            ? color.withValues(alpha: 0.35 + 0.55 * envelope)
            : kSurfaceHigh
        ..strokeWidth = barWidth
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(
        Offset(x + barWidth / 2, size.height / 2 - height / 2),
        Offset(x + barWidth / 2, size.height / 2 + height / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SignalPainter oldDelegate) =>
      oldDelegate.animationValue != animationValue ||
      oldDelegate.progress != progress ||
      oldDelegate.color != color;
}
